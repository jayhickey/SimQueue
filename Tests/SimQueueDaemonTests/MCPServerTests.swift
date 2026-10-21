// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueMCP
import SimQueueProtocol
import XCTest

/// `simq mcp` against a real daemon socket (fakes behind it).
final class MCPServerTests: XCTestCase {
    private func server(_ daemon: TestDaemon) -> MCPServer {
        MCPServer(
            version: "test", holderPID: getpid(), pollSeconds: 0.02,
            transport: MCPServer.socketTransport(daemon.paths.socketPath))
    }

    private func rpc(_ server: MCPServer, _ method: String, _ params: [String: Any] = [:], id: Int = 1) throws
        -> [String: Any]
    {
        let line = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ])
        let reply = try XCTUnwrap(server.handle(line: line))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    /// Calls a tool; returns (isError, parsed JSON text).
    private func tool(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) throws -> (
        Bool, [String: Any]
    ) {
        let reply = try rpc(server, "tools/call", ["name": name, "arguments": arguments])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let content = try XCTUnwrap((result["content"] as? [[String: Any]])?.first)
        let text = try XCTUnwrap(content["text"] as? String)
        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? ["text": text]
        return (result["isError"] as? Bool ?? false, json)
    }

    func testHandshakeToolListAndJSONRPCErrors() throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let mcp = server(daemon)
        let initialized = try rpc(mcp, "initialize", ["protocolVersion": "2025-03-26"])
        let result = try XCTUnwrap(initialized["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertNil(mcp.handle(line: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)))
        let tools = try XCTUnwrap(
            (try rpc(mcp, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(
            Set(tools.compactMap { $0["name"] as? String }),
            [
                "simq_submit", "simq_status", "simq_jobs", "simq_explain", "simq_cancel", "simq_wait", "simq_logs",
                "simq_lease_acquire", "simq_lease_release", "simq_doctor",
            ])
        XCTAssertTrue(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
        XCTAssertEqual((try rpc(mcp, "nope")["error"] as? [String: Any])?["code"] as? Int, -32601)
        let bad = try XCTUnwrap(mcp.handle(line: Data("not json".utf8)))
        XCTAssertTrue(String(decoding: bad, as: UTF8.self).contains("-32700"))
    }

    func testJobToolsWrapTheSocket() throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let mcp = server(daemon)
        let (submitError, submitted) = try tool(mcp, "simq_submit", ["project": "demo", "kind": "unit"])
        XCTAssertFalse(submitError, "\(submitted)")
        XCTAssertEqual(submitted["result_kind"] as? String, "submit")
        let job = try XCTUnwrap((submitted["result"] as? [String: Any])?["job"] as? [String: Any])
        let jobID = try XCTUnwrap(job["id"] as? String)
        XCTAssertEqual(job["submitter"] as? String, "mcp", "default submitter")

        let (_, explained) = try tool(mcp, "simq_explain", ["job_id": jobID])
        XCTAssertEqual((explained["result"] as? [String: Any])?["id"] as? String, jobID)
        let (_, waited) = try tool(mcp, "simq_wait", ["job_id": jobID, "timeout_seconds": 10])
        let finished = try XCTUnwrap(waited["result"] as? [String: Any])
        XCTAssertEqual(finished["timed_out"] as? Bool, false)
        XCTAssertEqual(finished["state"] as? String, "succeeded")
        let (_, jobs) = try tool(mcp, "simq_jobs", ["project": "demo"])
        XCTAssertEqual((jobs["result"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(try tool(mcp, "simq_status").1["result_kind"] as? String, "status")
        XCTAssertEqual(try tool(mcp, "simq_doctor").1["result_kind"] as? String, "doctor")

        let (missingError, missing) = try tool(mcp, "simq_cancel", ["job_id": "nope"])
        XCTAssertTrue(missingError)
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? String, "not_found")
        let (argError, _) = try tool(mcp, "simq_explain", [:])
        XCTAssertTrue(argError, "missing job_id is a tool error")
        XCTAssertTrue(try tool(mcp, "simq_lease_acquire", ["holder": "a"]).0, "pool off: refused")
    }

    func testLeaseToolsHoldTheSimForTheServerProcess() throws {
        var config = DaemonConfig()
        var pool = SimPoolConfig()
        pool.maxSims = 1
        pool.settle.mode = .load
        pool.settle.loadBelow = 1000
        config.pool = pool
        config.reliability.cleanupMode = .enforce  // the pool takes no host action in report-only
        let daemon = try TestDaemon(config: config)
        defer { daemon.stop() }
        daemon.processes.reuse(getpid(), identity: "fake:mcp")
        let mcp = server(daemon)
        let (error, acquired) = try tool(mcp, "simq_lease_acquire", ["holder": "agent-1", "timeout_seconds": 10])
        XCTAssertFalse(error, "\(acquired)")
        let lease = try XCTUnwrap(acquired["result"] as? [String: Any])
        XCTAssertEqual(lease["state"] as? String, "granted")
        let udid = try XCTUnwrap(lease["udid"] as? String)
        XCTAssertEqual(try daemon.side.poolSims().first?.holderPID, getpid(), "held by the MCP server process")
        let (releaseError, released) = try tool(mcp, "simq_lease_release", ["holder": "agent-1", "udid": udid])
        XCTAssertFalse(releaseError, "\(released)")
        XCTAssertEqual((released["result"] as? [String: Any])?["state"] as? String, "released")
    }
}
