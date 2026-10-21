// SPDX-License-Identifier: MIT

import Foundation
import SimQueueIPC
import SimQueueProtocol

/// `simq mcp`: an opt-in Model Context Protocol server (JSON-RPC 2.0, one message per
/// line on stdio) that wraps the daemon's socket protocol. Each tool maps to one socket
/// method; tool arguments use the socket's snake_case params and results are the socket's
/// JSON. It has no state of its own. Manual leases it takes name this server's process as
/// the holder, so they end when the MCP session does.
public final class MCPServer {
    /// Sends one socket request; `deadline` (seconds since 1970) bounds a wait.
    public typealias Transport = (Request, Double?) throws -> Response?

    public static let protocolVersion = "2025-06-18"
    let transport: Transport
    let version: String
    let holderPID: Int32
    let defaultSubmitter: String
    let pollSeconds: Double

    /// The daemon's socket at `socketPath` (waits have no per-line timeout).
    public static func socketTransport(_ socketPath: String) -> Transport {
        { request, deadline in
            try SimQueueClient(socketPath: socketPath, timeoutSeconds: deadline == nil ? 10 : 0).send(
                request, deadline: deadline)
        }
    }

    public init(
        version: String, holderPID: Int32, defaultSubmitter: String = "mcp", pollSeconds: Double = 1,
        transport: @escaping Transport
    ) {
        self.version = version
        self.holderPID = holderPID
        self.defaultSubmitter = defaultSubmitter
        self.pollSeconds = pollSeconds
        self.transport = transport
    }

    /// Reads requests from `input` until EOF and writes one response line per request.
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                if let reply = handle(line: Data(line)) { output.write(reply + Data([0x0A])) }
            }
        }
    }

    /// One JSON-RPC message in, at most one out (nil for notifications).
    public func handle(line: Data) -> Data? {
        guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) else { return nil }
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
        }
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id else { return nil }  // a notification (e.g. notifications/initialized)
        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": params["protocolVersion"] as? String ?? Self.protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "simq", "version": version],
                "instructions":
                    "SimQueue: a local queue for simulator build/test jobs. Submit jobs, wait, read logs, lease a settled pool sim.",
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": MCPTools.all.map(\.descriptor)]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            result = callTool(name, arguments)
        default:
            return Self.encode([
                "jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found: \(method)"],
            ])
        }
        return Self.encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
    }

    // MARK: - Tools

    struct ToolError: Error {
        var message: String
    }

    func callTool(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        do {
            let text = try runTool(name, arguments)
            return ["content": [["type": "text", "text": text]], "isError": false]
        } catch let error as ToolError {
            return ["content": [["type": "text", "text": error.message]], "isError": true]
        } catch {
            return ["content": [["type": "text", "text": "\(error)"]], "isError": true]
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ arguments: [String: Any]) throws -> T {
        do {
            let data = try JSONSerialization.data(withJSONObject: arguments)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ToolError(message: "invalid arguments: \(error)")
        }
    }

    func runTool(_ name: String, _ arguments: [String: Any]) throws -> String {
        switch name {
        case "simq_submit":
            var filled = arguments
            if filled["submitter"] == nil { filled["submitter"] = defaultSubmitter }
            for key in ["min_sims", "memory_bytes", "memory_bytes_per_sim"] where filled[key] == nil { filled[key] = 0 }
            return try render(try send(.submit(decode(SubmitParams.self, filled))))
        case "simq_status": return try render(try send(.status))
        case "simq_jobs": return try render(try send(.jobs(decode(JobsParams.self, arguments))))
        case "simq_explain": return try render(try send(.explain(decode(JobRef.self, arguments))))
        case "simq_cancel": return try render(try send(.cancel(decode(CancelParams.self, arguments))))
        case "simq_logs": return try render(try send(.logs(decode(LogsParams.self, arguments))))
        case "simq_doctor": return try render(try send(.doctor))
        case "simq_lease_release":
            return try render(try send(.leaseRelease(decode(LeaseReleaseParams.self, arguments))))
        case "simq_wait": return try wait(arguments)
        case "simq_lease_acquire": return try leaseAcquire(arguments)
        default: throw ToolError(message: "unknown tool \(name)")
        }
    }

    static func timeout(_ arguments: [String: Any]) -> Double {
        let value = (arguments["timeout_seconds"] as? NSNumber)?.doubleValue ?? 60
        return min(max(value, 0), 600)
    }

    func wait(_ arguments: [String: Any]) throws -> String {
        guard let jobID = arguments["job_id"] as? String else { throw ToolError(message: "job_id is required") }
        let untilAdmitted = arguments["until_admitted"] as? Bool ?? false
        let deadline = Date().timeIntervalSince1970 + Self.timeout(arguments)
        do {
            let payload = try send(.wait(WaitParams(jobID: jobID, untilAdmitted: untilAdmitted)), deadline: deadline)
            return try render(payload, extra: ["timed_out": false])
        } catch is WaitTimedOut {
            return try render(try send(.explain(JobRef(jobID: jobID))), extra: ["timed_out": true])
        }
    }

    func leaseAcquire(_ arguments: [String: Any]) throws -> String {
        guard let holder = arguments["holder"] as? String else { throw ToolError(message: "holder is required") }
        let deadline = Date().addingTimeInterval(Self.timeout(arguments))
        while true {
            let payload = try send(.leaseAcquire(LeaseAcquireParams(holder: holder, pid: holderPID)))
            guard case .lease(let result) = payload else { return try render(payload) }
            if result.state == "granted" || Date() >= deadline { return try render(payload) }
            Thread.sleep(forTimeInterval: max(0.01, pollSeconds))
        }
    }

    struct WaitTimedOut: Error {}

    func send(_ params: RequestParams, deadline: Double? = nil) throws -> ResultPayload {
        let response: Response?
        do {
            response = try transport(Request(params: params), deadline)
        } catch SocketError.timedOut where deadline != nil {
            throw WaitTimedOut()
        } catch {
            throw ToolError(message: "daemon unavailable: \(error)")
        }
        guard let response else { throw WaitTimedOut() }
        switch response.body {
        case .result(let payload): return payload
        case .error(let failure):
            throw ToolError(message: Self.json(["error": ["code": failure.code.rawValue, "message": failure.message]]))
        case .event: throw ToolError(message: "unexpected event")
        }
    }

    static func json(_ object: [String: Any]) -> String {
        String(decoding: encode(object), as: UTF8.self)
    }

    /// The socket's own JSON for a result, plus optional extra top-level fields.
    func render(_ payload: ResultPayload, extra: [String: Any] = [:]) throws -> String {
        let response = Response(id: "mcp", body: .result(payload))
        let data = try JSONEncoder().encode(response)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError(message: "unencodable result")
        }
        var result: Any = object["result"] ?? NSNull()
        if !extra.isEmpty {
            if var dict = result as? [String: Any] {
                for (key, value) in extra { dict[key] = value }
                result = dict
            } else {
                result = ["value": result].merging(extra) { $1 }
            }
        }
        object = ["result_kind": object["result_kind"] ?? NSNull(), "result": result]
        return Self.json(object)
    }
}
