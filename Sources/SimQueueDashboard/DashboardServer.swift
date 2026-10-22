// SPDX-License-Identifier: MIT

import Foundation
import SimQueueProtocol

#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

/// Foreground, loopback-only server. A private capability URL grants access, including
/// through a reverse proxy. Job controls also require a matching HTTP(S) Origin.
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
            request: String(decoding: request, as: UTF8.self), token: token, api: api)
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
            Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; manifest-src 'self'; worker-src 'self'; frame-ancestors 'none'; base-uri 'none'\r
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

    private static func validAuthority(_ value: String) -> Bool {
        // Host is one authority, never a URL, userinfo, path or forwarded header.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]")
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ allowed.contains($0) }),
            let url = URLComponents(string: "http://\(value)"),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
            url.path.isEmpty, url.query == nil, url.fragment == nil
        else { return false }
        return true
    }

    static func route(request: String, token: String, api: DashboardAPI) -> Reply {
        let lines = request.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ").map(String.init)
        let hosts = lines.dropFirst().prefix(while: { !$0.isEmpty }).compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "host" else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard first.count == 3, ["GET", "POST"].contains(first[0]), first[2] == "HTTP/1.1",
            hosts.count == 1, let host = hosts.first, Self.validAuthority(host),
            first[1].hasPrefix("/\(token)/")
        else { return Reply("403 Forbidden") }
        let path = String(first[1].dropFirst(token.count + 2))
        if first[0] == "POST" {
            func header(_ name: String) -> [String] {
                lines.dropFirst().prefix(while: { !$0.isEmpty }).compactMap { line in
                    guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == name else { return nil }
                    return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            let origins = header("origin")
            guard origins == ["http://\(host)"] || origins == ["https://\(host)"],
                header("x-simqueue-action") == ["1"],
                header("transfer-encoding").isEmpty,
                header("content-length").isEmpty || header("content-length") == ["0"],
                request.components(separatedBy: "\r\n\r\n").dropFirst().allSatisfy(\.isEmpty),
                path.hasPrefix("api/")
            else { return Reply("403 Forbidden") }
        }
        if first[0] == "GET", let icon = DashboardIcons.files[path] {
            return Reply("200 OK", "image/png", icon)
        }
        if first[0] == "GET", let asset = DashboardAssets.files[path] {
            return Reply("200 OK", asset.type + "; charset=utf-8", Data(asset.text.utf8))
        }
        guard path.hasPrefix("api/") else { return Reply("404 Not Found") }
        do {
            let route = String(path.dropFirst(4))
            let body = try first[0] == "POST" ? api.mutate(path: route) : api.response(path: route)
            return Reply("200 OK", "application/json", body)
        } catch let error as ProtocolError {
            let status: String
            switch error.code {
            case .notFound: status = "404 Not Found"
            case .invalidArgument, .badRequest: status = "400 Bad Request"
            case .invalidState: status = "409 Conflict"
            default: status = "503 Service Unavailable"
            }
            return Reply(status, "text/plain; charset=utf-8", Data(error.message.utf8))
        } catch DashboardError.notFound {
            return Reply("404 Not Found")
        } catch {
            return Reply(
                "503 Service Unavailable", "text/plain",
                Data("No confirmed daemon response. Refresh the job state before retrying an action.".utf8))
        }
    }
}
