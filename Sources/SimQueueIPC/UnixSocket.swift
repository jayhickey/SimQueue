// SPDX-License-Identifier: MIT

import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

public enum SocketError: Error, Equatable, CustomStringConvertible {
    case pathTooLong(String, max: Int)
    case system(call: String, errno: Int32)
    case alreadyRunning(String)
    case notASocket(String)
    case insecureDirectory(String)
    case lineTooLong
    case closed
    case peerRejected(uid: UInt32)
    /// No data before the receive timeout.
    case timedOut

    public var description: String {
        switch self {
        case .pathTooLong(let path, let max): return "socket path is longer than \(max) bytes: \(path)"
        case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code))) (errno \(code))"
        case .alreadyRunning(let path): return "another simqd is already listening on \(path)"
        case .notASocket(let path): return "\(path) exists and is not a socket; refusing to replace it"
        case .insecureDirectory(let path): return "socket directory \(path) is writable by other users"
        case .lineTooLong: return "message exceeds the maximum line length"
        case .closed: return "connection closed"
        case .peerRejected(let uid): return "rejected connection from uid \(uid)"
        case .timedOut: return "timed out waiting for the daemon"
        }
    }
}

private func makeAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    let bytes = Array(path.utf8)
    guard bytes.count < capacity else {
        throw SocketError.pathTooLong(path, max: capacity - 1)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for (index, byte) in bytes.enumerated() {
            buffer[index] = byte
        }
        buffer[bytes.count] = 0
    }
    return address
}

/// Stream sockets are close-on-exec, so job commands the daemon spawns never inherit the
/// listener or a client connection.
private func socketStreamType() -> Int32 {
    #if canImport(Glibc)
        return Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
    #else
        return SOCK_STREAM
    #endif
}

/// One connected stream with newline framing. Not thread-safe; one owner at a time.
public final class UnixConnection: @unchecked Sendable {
    private var descriptor: Int32
    private var buffer = Data()

    init(descriptor: Int32) throws {
        self.descriptor = descriptor
        // No SOCK_CLOEXEC on Darwin (posix_spawn there closes everything anyway via
        // POSIX_SPAWN_CLOEXEC_DEFAULT); accepted sockets on Linux need it set too.
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        #if canImport(Darwin)
            var on: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                // A peer can close before accept returns. Darwin then rejects this
                // option with EINVAL; sending anyway would deliver SIGPIPE to the
                // entire daemon. Never expose an unprotected connection.
                let code = errno
                close()
                throw SocketError.system(call: "setsockopt(SO_NOSIGPIPE)", errno: code)
            }
        #endif
    }

    deinit {
        close()
    }

    /// Connects to a listening socket.
    public static func connect(path: String, timeoutSeconds: Double = 5) throws -> UnixConnection {
        var address = try makeAddress(path)
        let descriptor = socket(AF_UNIX, socketStreamType(), 0)
        guard descriptor >= 0 else {
            throw SocketError.system(call: "socket", errno: errno)
        }
        // Protect a fresh socket before connecting: a server that immediately closes
        // must not turn the option setup into a disconnected-socket EINVAL.
        let connection = try UnixConnection(descriptor: descriptor)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            connection.close()
            throw SocketError.system(call: "connect", errno: code)
        }
        connection.setReceiveTimeout(timeoutSeconds)
        return connection
    }

    /// 0 disables the timeout (block until data or close).
    public func setReceiveTimeout(_ seconds: Double) {
        var value = timeval()
        value.tv_sec = Int(seconds)
        value.tv_usec = .init(Int((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// The connecting process's uid, if the platform reports it.
    public func peerUID() -> UInt32? {
        #if canImport(Darwin)
            var uid: uid_t = 0
            var gid: gid_t = 0
            return getpeereid(descriptor, &uid, &gid) == 0 ? uid : nil
        #elseif canImport(Glibc)
            // `struct ucred` (pid, uid, gid) isn't exported without _GNU_SOURCE; mirror it.
            var credentials: (pid: Int32, uid: UInt32, gid: UInt32) = (0, 0, 0)
            var length = socklen_t(MemoryLayout<(Int32, UInt32, UInt32)>.size)
            return getsockopt(descriptor, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0 ? credentials.uid : nil
        #else
            return nil
        #endif
    }

    public func write(_ data: Data) throws {
        guard descriptor >= 0 else { throw SocketError.closed }
        var flags: Int32 = 0
        #if canImport(Glibc)
            flags = Int32(MSG_NOSIGNAL)
        #endif
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let sent = send(descriptor, base + offset, raw.count - offset, flags)
                if sent < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.system(call: "send", errno: errno)
                }
                offset += sent
            }
        }
    }

    /// Reads one line (without the newline). Nil on clean end of stream.
    /// An absolute deadline bounds the whole line, including peers that send partial
    /// bytes often enough to avoid an ordinary per-receive timeout.
    public func readLine(maxBytes: Int, deadline: Double? = nil) throws -> Data? {
        while true {
            if let deadline {
                let remaining = deadline - Date().timeIntervalSince1970
                guard remaining > 0 else { throw SocketError.timedOut }
                setReceiveTimeout(max(0.001, remaining))
            }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            guard buffer.count <= maxBytes else {
                throw SocketError.lineTooLong
            }
            guard descriptor >= 0 else { throw SocketError.closed }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = recv(descriptor, &chunk, chunk.count, 0)
            if count == 0 {
                if buffer.isEmpty { return nil }
                throw SocketError.closed
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.timedOut }
                throw SocketError.system(call: "recv", errno: errno)
            }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    public func close() {
        if descriptor >= 0 {
            _ = Foundation.close(descriptor)
            descriptor = -1
        }
    }
}

/// A listening Unix socket, created owner-only (0600) in an owner-only directory.
public final class UnixListener: @unchecked Sendable {
    public let path: String
    private var descriptor: Int32
    private let lock = NSLock()

    /// Binds and listens. Refuses to replace a live socket (another daemon) or a
    /// non-socket file; removes a stale socket left by a crashed daemon.
    public init(path: String, backlog: Int32 = 64) throws {
        self.path = path
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        // st_mode is mode_t: UInt16 on Darwin, UInt32 on Linux. Widen before masking.
        if stat(directory, &info) == 0, UInt32(info.st_mode) & 0o022 != 0, UInt32(info.st_mode) & UInt32(S_ISVTX) == 0 {
            throw SocketError.insecureDirectory(directory)
        }
        if lstat(path, &info) == 0 {
            guard UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFSOCK) else {
                throw SocketError.notASocket(path)
            }
            if (try? UnixConnection.connect(path: path, timeoutSeconds: 1)) != nil {
                throw SocketError.alreadyRunning(path)
            }
            unlink(path)
        }
        var address = try makeAddress(path)
        let descriptor = socket(AF_UNIX, socketStreamType(), 0)
        guard descriptor >= 0 else {
            throw SocketError.system(call: "socket", errno: errno)
        }
        // Create the socket file with 0600 from the start: no window where it is wider.
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bound == 0 else {
            let code = errno
            _ = Foundation.close(descriptor)
            throw SocketError.system(call: "bind", errno: code)
        }
        chmod(path, 0o600)
        guard listen(descriptor, backlog) == 0 else {
            let code = errno
            _ = Foundation.close(descriptor)
            unlink(path)
            throw SocketError.system(call: "listen", errno: code)
        }
        self.descriptor = descriptor
    }

    deinit {
        close()
    }

    /// Blocks until a client connects. Throws `closed` after `close()`.
    public func accept() throws -> UnixConnection {
        while true {
            let current = lock.withLock { descriptor }
            guard current >= 0 else { throw SocketError.closed }
            let client = Foundation.accept(current, nil, nil)
            if client >= 0 {
                return try UnixConnection(descriptor: client)
            }
            if errno == EINTR { continue }
            if lock.withLock({ descriptor }) < 0 { throw SocketError.closed }
            throw SocketError.system(call: "accept", errno: errno)
        }
    }

    /// Stops listening and removes the socket file.
    public func close() {
        let current: Int32 = lock.withLock {
            let value = descriptor
            descriptor = -1
            return value
        }
        if current >= 0 {
            shutdown(current, Int32(SHUT_RDWR))
            _ = Foundation.close(current)
            unlink(path)
        }
    }

    /// Permission bits of the socket file (for tests and doctor).
    public static func permissions(of path: String) -> UInt32? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt32(info.st_mode) & 0o777
    }
}
