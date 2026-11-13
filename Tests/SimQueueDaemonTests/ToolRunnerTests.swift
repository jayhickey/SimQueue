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
        XCTAssertThrowsError(try runner.run("faketool", [], timeoutSeconds: 2)) {
            guard case .timedOut = $0 as? ToolError else { return XCTFail("\($0)") }
        }
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let child = try XCTUnwrap(Int32(text))
        let deadline = Date().addingTimeInterval(3)
        while isAlive(child), Date() < deadline { usleep(20_000) }
        XCTAssertFalse(isAlive(child), "the forked child outlived the timeout")
    }

    func testRepeatedTimeoutsAndExitsReapTheirOwnLeaders() throws {
        for hangs in [false, true] {
            let (bin, pidFile) = try tool(
                "echo $$ > \"$PIDFILE\"; " + (hangs ? "trap '' TERM; while :; do sleep 1; done" : "exit 0"))
            let runner = ToolRunner(
                environment: ["PATH": bin.path + ":/usr/bin:/bin", "PIDFILE": pidFile.path],
                killGraceSeconds: 0.02)
            for _ in 0..<12 {
                if hangs {
                    XCTAssertThrowsError(try runner.run("faketool", [], timeoutSeconds: 0.3))
                } else {
                    XCTAssertEqual(try runner.run("faketool", [], timeoutSeconds: 1).status, 0)
                }
                let pid = try XCTUnwrap(
                    Int32(
                        String(contentsOf: pidFile, encoding: .utf8)
                            .trimmingCharacters(in: .whitespacesAndNewlines)))
                var status: Int32 = 0
                XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1, "leader must already be reaped")
                XCTAssertEqual(errno, ECHILD)
            }
        }
    }

    func testLeaderExitDoesNotLeavePipeHoldingDescendantsBehind() throws {
        let (bin, _) = try tool("sleep 300 & exit 0")
        let runner = ToolRunner(environment: ["PATH": bin.path + ":/usr/bin:/bin"], killGraceSeconds: 0.02)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try runner.run("faketool", [], timeoutSeconds: 0.1))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func testReapingDoesNotDependOnAvailableDispatchWorkers() throws {
        let (bin, _) = try tool("echo output")
        let runner = ToolRunner(environment: ["PATH": bin.path + ":/usr/bin:/bin"], killGraceSeconds: 0.02)
        // Occupy the shared pool inside this isolated test process. The calling
        // thread must still drain/reap a tool; old async readers/waiters starve.
        let release = DispatchSemaphore(value: 0)
        let workers = DispatchGroup()
        for _ in 0..<80 {
            workers.enter()
            DispatchQueue.global().async {
                release.wait(); workers.leave()
            }
        }
        defer {
            for _ in 0..<80 { release.signal() }
            workers.wait()
        }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(try runner.run("faketool", [], timeoutSeconds: 2).stdout, "output\n")
    }

    func testExcessiveToolOutputFailsExplicitlyInsteadOfReturningTruncatedSuccess() throws {
        let (bin, _) = try tool("head -c 17000000 /dev/zero")
        let runner = ToolRunner(environment: ["PATH": bin.path + ":/usr/bin:/bin"], killGraceSeconds: 0.02)
        XCTAssertThrowsError(try runner.run("faketool", [], timeoutSeconds: 5)) {
            guard case .outputLimitExceeded = $0 as? ToolError else { return XCTFail("\($0)") }
        }
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
