// SPDX-License-Identifier: MIT

import Foundation

#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

/// Foreground, loopback-only server. Ephemeral capability URLs and an exact Host check
/// prevent other websites (including DNS rebinding) from reading local queue data.
public final class DashboardServer {
    private let listener: Int32
    private let token = UUID().uuidString
    private let api: DashboardAPI
    private let authority: String
    public var url: String { "http://\(authority)/\(token)/" }

    public init(port: UInt16 = 0, socketPath: String) throws {
        #if canImport(Glibc)
            let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard descriptor >= 0 else { throw DashboardError.unavailable }
        do {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(descriptor, 16) == 0 else { throw DashboardError.unavailable }
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
            }
            guard named == 0 else { throw DashboardError.unavailable }
            authority = "127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        } catch {
            _ = close(descriptor)
            throw error
        }
        listener = descriptor
        api = DashboardAPI(socketPath: socketPath)
    }

    deinit { _ = close(listener) }

    public func run() throws {
        while true {
            let peer = accept(listener, nil, nil)
            if peer < 0 {
                if errno == EINTR { continue }
                throw DashboardError.unavailable
            }
            serve(peer)
            _ = close(peer)
        }
    }

    private func serve(_ peer: Int32) {
        _ = fcntl(peer, F_SETFD, FD_CLOEXEC)
        // Nonblocking I/O plus one absolute deadline bounds slow/incomplete requests
        // and peers that stop reading a response. No unbounded connection workers.
        _ = fcntl(peer, F_SETFL, O_NONBLOCK)
        #if canImport(Darwin)
            var on: Int32 = 1
            guard setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                return
            }
        #endif
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var request = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard request.count < 8192, ready(peer, events: Int16(POLLIN), until: deadline) else { return }
            let count = recv(peer, &bytes, min(bytes.count, 8192 - request.count), 0)
            guard count > 0 else { return }
            request.append(contentsOf: bytes.prefix(count))
        }
        let reply = Self.route(
            request: String(decoding: request, as: UTF8.self), authority: authority, token: token, api: api)
        let data = Self.wireResponse(reply)
        let sendDeadline = ProcessInfo.processInfo.systemUptime + 2
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                guard ready(peer, events: Int16(POLLOUT), until: sendDeadline) else { return }
                #if canImport(Glibc)
                    let flags = Int32(MSG_NOSIGNAL)
                #else
                    let flags: Int32 = 0
                #endif
                let count = send(peer, base + offset, buffer.count - offset, flags)
                guard count > 0 else { return }
                offset += count
            }
        }
    }

    static func wireResponse(_ reply: Reply) -> Data {
        let headers = """
            HTTP/1.1 \(reply.status)\r
            Content-Type: \(reply.type)\r
            Content-Length: \(reply.body.count)\r
            Connection: close\r
            Cache-Control: no-store\r
            Referrer-Policy: no-referrer\r
            X-Content-Type-Options: nosniff\r
            X-Frame-Options: DENY\r
            Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'\r
            \r
            """
        var data = Data((headers + "\n").utf8)
        data.append(reply.body)
        return data
    }

    private func ready(_ peer: Int32, events: Int16, until deadline: Double) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        var descriptor = pollfd(fd: peer, events: events, revents: 0)
        return poll(&descriptor, 1, Int32(remaining * 1000)) > 0 && descriptor.revents & events != 0
    }

    struct Reply {
        let status: String
        let type: String
        let body: Data
        init(_ status: String, _ type: String = "text/plain; charset=utf-8", _ body: Data = Data()) {
            self.status = status
            self.type = type
            self.body = body
        }
    }

    static func route(request: String, authority: String, token: String, api: DashboardAPI) -> Reply {
        let lines = request.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ").map(String.init)
        let hosts = lines.dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "host" else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1", hosts == [authority],
            first[1].hasPrefix("/\(token)/")
        else { return Reply("403 Forbidden") }
        let path = String(first[1].dropFirst(token.count + 2))
        if let asset = DashboardAssets.files[path] {
            return Reply("200 OK", asset.type + "; charset=utf-8", Data(asset.text.utf8))
        }
        guard path.hasPrefix("api/") else { return Reply("404 Not Found") }
        do {
            return Reply("200 OK", "application/json", try api.response(path: String(path.dropFirst(4))))
        } catch DashboardError.notFound {
            return Reply("404 Not Found")
        } catch {
            return Reply(
                "503 Service Unavailable", "text/plain", Data("Daemon unavailable; retrying automatically.".utf8))
        }
    }
}
