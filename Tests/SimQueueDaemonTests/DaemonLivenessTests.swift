// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueIPC
import SimQueueProtocol
import SimQueueSim
import SimQueueStore
import XCTest

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

final class DaemonLivenessTests: XCTestCase {
    private func hangingTool() throws -> (ToolRunner, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("simq-hang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("xcrun")
        try "#!/bin/sh\necho $$ > \"$PIDFILE\"\ntrap '' TERM\nwhile :; do sleep 1; done\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let pid = root.appendingPathComponent("leader.pid")
        return (
            ToolRunner(
                environment: ["PATH": root.path + ":/usr/bin:/bin", "PIDFILE": pid.path],
                killGraceSeconds: 0.05), pid
        )
    }

    func testHangingDevicectlNeverBlocksStatusOrSubmit() throws {
        let (runner, pid) = try hangingTool()
        let probe = Devicectl(runner: runner, timeoutSeconds: 1)
        let probed = DispatchSemaphore(value: 0)
        let falseRestart = expectation(description: "slow device probe does not trigger liveness")
        falseRestart.isInverted = true
        var config = DaemonConfig()
        config.devices = [PhysicalDevice(udid: "FAKE-PHONE", name: "Fake")]
        let daemon = try TestDaemon(
            config: config,
            deviceHealth: {
                defer { probed.signal() }
                return probe.health(udid: $0)
            },
            configureServer: {
                $0.livenessIntervalSeconds = 0.05
                $0.livenessTimeoutSeconds = 0.1
                $0.livenessFailureSeconds = 0.5
                $0.livenessFailure = { falseRestart.fulfill() }
            })
        defer { daemon.destroy() }
        _ = try daemon.result(.status)
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: pid.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pid.path), "fake devicectl started")
        for index in 0..<10 {
            let start = ProcessInfo.processInfo.systemUptime
            guard case .status(let status) = try daemon.result(.status) else { return XCTFail("no status") }
            XCTAssertEqual(status.devices?.first?.health.state, "device_unavailable")
            _ = try daemon.submit(SubmitParams(project: "responsive", submitter: "test-\(index)", minSims: 0))
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.8)
        }
        let job = try daemon.submit(SubmitParams(project: "responsive", submitter: "final", minSims: 0)).job
        XCTAssertEqual(try daemon.wait(job.id).state, .succeeded)
        XCTAssertEqual(probed.wait(timeout: .now() + 3), .success)
        wait(for: [falseRestart], timeout: 0.2)
        let leader = try XCTUnwrap(
            Int32(
                String(contentsOf: pid, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
        var status: Int32 = 0
        XCTAssertEqual(waitpid(leader, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    private final class HangingInventory: SimBackend, @unchecked Sendable {
        let kind: BackendKind = .fake
        let runner: ToolRunner
        let timeout: Double
        let entered = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var armed = false
        init(_ runner: ToolRunner, timeout: Double = 1) { self.runner = runner; self.timeout = timeout }
        func arm() { lock.withLock { armed = true } }
        func listDevices() throws -> [SimDevice] {
            if lock.withLock({ armed }) {
                entered.signal()
                _ = try runner.run("xcrun", ["simctl", "list", "--json"], timeoutSeconds: timeout)
            }
            return []
        }
        func poolSnapshot() throws -> PoolSnapshot { _ = try listDevices(); return PoolSnapshot() }
        func deleteDevice(udid: String) throws {}
    }

    func testHangingSimctlInventoryDropsServiceLock() throws {
        let (runner, _) = try hangingTool()
        let sims = HangingInventory(runner)
        let daemon = try TestDaemon(simsOverride: sims)
        defer { daemon.destroy() }
        sims.arm()
        _ = try daemon.submit(SubmitParams(project: "needs-sim", submitter: "test", minSims: 1))
        XCTAssertEqual(sims.entered.wait(timeout: .now() + 3), .success)
        let start = ProcessInfo.processInfo.systemUptime
        _ = try daemon.result(.status)
        _ = try daemon.submit(SubmitParams(project: "no-sim", submitter: "test", minSims: 0))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.8)
    }

    func testWaitLaneIsBoundedAndControlsStillAnswer() throws {
        let daemon = try TestDaemon()
        defer { daemon.destroy() }
        try daemon.side.setPaused(true)
        let job = try daemon.submit(SubmitParams(project: "paused", submitter: "test", minSims: 0)).job
        var connections: [UnixConnection] = []
        defer { for connection in connections { connection.close() } }
        for _ in 0..<16 {
            let connection = try UnixConnection.connect(path: daemon.paths.socketPath, timeoutSeconds: 2)
            connections.append(connection)
            try connection.write(LineCodec.encode(Request(params: .wait(WaitParams(jobID: job.id, stream: true)))))
            let line = try XCTUnwrap(connection.readLine(maxBytes: LineCodec.maxLineBytes))
            guard case .event = try LineCodec.decode(Response.self, from: line).body else { return XCTFail("no event") }
        }
        let start = ProcessInfo.processInfo.systemUptime
        let error = try daemon.protocolError(.wait(WaitParams(jobID: job.id)))
        XCTAssertEqual(error.code, .queueFull)
        XCTAssertTrue(error.message.contains("daemon busy"))
        _ = try daemon.result(.status)
        _ = try daemon.submit(SubmitParams(project: "control", submitter: "test", minSims: 0))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func testSlowAdministrativeLaneFailsFastWithoutTakingControlCapacity() throws {
        let (runner, _) = try hangingTool()
        let sims = HangingInventory(runner, timeout: 3)
        let daemon = try TestDaemon(simsOverride: sims)
        defer { daemon.destroy() }
        sims.arm()
        var connections: [UnixConnection] = []
        defer { for connection in connections { connection.close() } }
        for _ in 0..<8 {
            let connection = try UnixConnection.connect(path: daemon.paths.socketPath, timeoutSeconds: 2)
            connections.append(connection)
            try connection.write(LineCodec.encode(Request(params: .doctor)))
            XCTAssertEqual(sims.entered.wait(timeout: .now() + 1), .success)
        }
        let start = ProcessInfo.processInfo.systemUptime
        let error = try daemon.protocolError(.doctor)
        XCTAssertEqual(error.code, .queueFull)
        XCTAssertTrue(error.message.contains("daemon busy"))
        _ = try daemon.result(.status)
        _ = try daemon.submit(SubmitParams(project: "control", submitter: "test", minSims: 0))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func testSilentClientsCannotConsumeUnboundedRequestThreads() throws {
        let daemon = try TestDaemon()
        defer { daemon.destroy() }
        var connections: [UnixConnection] = []
        defer { for connection in connections { connection.close() } }
        for _ in 0..<12 {
            connections.append(try UnixConnection.connect(path: daemon.paths.socketPath, timeoutSeconds: 3))
        }
        // Slow readers expire after a total two-second input deadline. The accept
        // loop rejects excess clients instead of growing a queue of blocked tasks.
        Thread.sleep(forTimeInterval: 2.2)
        let start = ProcessInfo.processInfo.systemUptime
        _ = try daemon.result(.status)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    private final class StalledExecutor: JobExecutor {
        var requiresCommand = false
        var drainsProcessGroups = false
        var heldJobIDs: Set<String> = []
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private var stalled = false
        func step(store: JobStore, epoch: Int64, now: Double) throws {
            if !stalled {
                stalled = true
                entered.signal()
                release.wait()
            }
        }
    }

    func testSocketLivenessDetectsAStuckServiceDespiteLiveProcess() throws {
        let executor = StalledExecutor()
        let failed = expectation(description: "liveness triggers process exit")
        let daemon = try TestDaemon(
            executorOverride: executor,
            configureServer: {
                $0.livenessIntervalSeconds = 0.05
                $0.livenessTimeoutSeconds = 0.05
                $0.livenessFailureSeconds = 0.3
                $0.livenessFailure = { failed.fulfill() }
            })
        defer { executor.release.signal(); daemon.destroy() }
        XCTAssertEqual(executor.entered.wait(timeout: .now() + 2), .success)
        wait(for: [failed], timeout: 3)
    }

    func testDoctorIncludesRoundTripAndProcessCounts() throws {
        let daemon = try TestDaemon()
        defer { daemon.destroy() }
        let checks = DoctorBuilder.runtimeChecks(paths: daemon.paths, daemonPID: nil)
        XCTAssertEqual(checks.first { $0.name == "socket_round_trip" }?.level, .ok)
        XCTAssertNotNil(checks.first { $0.name == "daemon_threads" })
        XCTAssertNotNil(checks.first { $0.name == "daemon_zombies" })
    }
}
