// SPDX-License-Identifier: MIT

import Foundation
import SimQueueProtocol

/// Sends one request and collects responses until the final one.
public struct SimQueueClient: Sendable {
    public var socketPath: String
    /// Receive timeout per line. Waits use 0 (none) because the daemon streams.
    public var timeoutSeconds: Double

    public init(socketPath: String, timeoutSeconds: Double = 10) {
        self.socketPath = socketPath
        self.timeoutSeconds = timeoutSeconds
    }

    /// Returns the final response. `onEvent` sees each streamed event; return false to stop
    /// reading (the connection is closed and `nil` is returned). With `deadline` (seconds
    /// since 1970), throws `SocketError.timedOut` once it passes, even mid-stream.
    public func send(
        _ request: Request, deadline: Double? = nil, onEvent: (JobInfo) -> Bool = { _ in true }
    ) throws -> Response? {
        let connection = try UnixConnection.connect(path: socketPath, timeoutSeconds: timeoutSeconds)
        defer { connection.close() }
        try connection.write(try LineCodec.encode(request))
        while true {
            let lineTimeout = timeoutSeconds > 0 ? Date().timeIntervalSince1970 + timeoutSeconds : nil
            let lineDeadline = [deadline, lineTimeout].compactMap { $0 }.min()
            guard let line = try connection.readLine(maxBytes: LineCodec.maxLineBytes, deadline: lineDeadline) else {
                break
            }
            let response = try LineCodec.decode(Response.self, from: line)
            if case .event(let job) = response.body {
                if !onEvent(job) { return nil }
                continue
            }
            return response
        }
        throw SocketError.closed
    }
}
