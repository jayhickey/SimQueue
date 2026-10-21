// SPDX-License-Identifier: MIT

import Foundation
import SimQueueHost
import XCTest

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// #39: a tool that times out is killed with everything it forked.
final class ToolRunnerTests: XCTestCase {
    private func tool(_ body: String) throws -> (bin: URL, pidFile: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("simq-toolrunner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("faketool")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (root, root.appendingPathComponent("child.pid"))
    }

    private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    func testTimeoutKillsTheToolsChildrenToo() throws {
        let (bin, pidFile) = try tool(
            // A child that ignores SIGTERM, like a tool's helper, then a parent that waits.
            "trap '' TERM; sleep 300 & echo $! > \"$PIDFILE\"; wait")
        let runner = ToolRunner(
            environment: ["PATH": bin.path + ":/usr/bin:/bin", "PIDFILE": pidFile.path], killGraceSeconds: 0.3)
        XCTAssertThrowsError(try runner.run("faketool", [], timeoutSeconds: 0.5)) {
            guard case .timedOut = $0 as? ToolError else { return XCTFail("\($0)") }
        }
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let child = try XCTUnwrap(Int32(text))
        let deadline = Date().addingTimeInterval(3)
        while isAlive(child), Date() < deadline { usleep(20_000) }
        XCTAssertFalse(isAlive(child), "the forked child outlived the timeout")
    }

    func testOutputAndStatusStillCome() throws {
        let (bin, _) = try tool("echo out; echo err >&2; exit 3")
        let runner = ToolRunner(environment: ["PATH": bin.path + ":/usr/bin:/bin"])
        let result = try runner.run("faketool", [], timeoutSeconds: 5)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stderr, "err\n")
        XCTAssertThrowsError(try runner.run("no-such-tool-\(UUID().uuidString)", [], timeoutSeconds: 1))
    }
}
