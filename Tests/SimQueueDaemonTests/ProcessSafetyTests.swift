// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueProtocol
import SimQueueStore
import XCTest

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The real process table, except that groups a test marks as reused report a different
/// leader identity (as if the pgid now led someone else's process).
final class ReusedPIDTable: ProcessTable, @unchecked Sendable {
    let base = SystemProcessTable()
    private let lock = NSLock()
    private var reused: Set<Int32> = []

    func markReused(_ pgid: Int32) { lock.withLock { _ = reused.insert(pgid) } }

    func liveProcessGroups() throws -> Set<Int32> { try base.liveProcessGroups() }
    func terminateGroup(_ pgid: Int32, graceSeconds: Double) throws {
        try base.terminateGroup(pgid, graceSeconds: graceSeconds)
    }
    func signalGroup(_ pgid: Int32, _ signal: ProcessSignal) throws { try base.signalGroup(pgid, signal) }
    func processIdentity(_ pid: Int32) throws -> String? {
        if lock.withLock({ reused.contains(pid) }) { return "someone-else" }
        return try base.processIdentity(pid)
    }
    var supportsEnvironmentScan: Bool { base.supportsEnvironmentScan }
    func processes(withEnvironmentEntry entry: String) throws -> [ProcessMatch] {
        try base.processes(withEnvironmentEntry: entry)
    }
}

/// #38 (no signal to a reused pgid on drain or cancel) and #40 (the alert token never
/// reaches jobs). Real `sh` commands in temp dirs only.
final class ProcessSafetyTests: XCTestCase {
    private func eventually(_ what: String, timeout: Double = 10, _ condition: () throws -> Bool) rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func start(_ table: ReusedPIDTable) throws -> TestDaemon {
        var config = DaemonConfig()
        config.timeouts.killGraceSeconds = 0.3
        let daemon = try TestDaemon(config: config, realProcesses: true, processTable: table)
        addTeardownBlock { daemon.destroy() }
        return daemon
    }

    private func group(_ daemon: TestDaemon, _ jobID: String) throws -> (OwnedResource, Int32) {
        let resource = try XCTUnwrap(try daemon.side.resources(jobID: jobID).first { $0.kind == .processGroup })
        return (resource, try XCTUnwrap(Int32(resource.externalID)))
    }

    private func params(_ script: String, environment: [String: String]? = nil) -> SubmitParams {
        SubmitParams(project: "app", submitter: "dev", command: ["/bin/sh", "-c", script], environment: environment)
    }

    func testDrainNeverSignalsAReusedProcessGroup() throws {
        let table = ReusedPIDTable()
        let daemon = try start(table)
        let id = try daemon.submit(params("(exec sleep 30) & sleep 1")).job.id
        try eventually("running") { try daemon.job(id).state == .running }
        let (resource, pgid) = try group(daemon, id)
        defer { kill(-pgid, SIGKILL) }  // the test's own leftover
        table.markReused(pgid)
        try eventually("job ended") { try daemon.job(id).state.isTerminal }
        try eventually("resource released") { try daemon.side.resource(id: resource.id)?.state == .released }
        Thread.sleep(forTimeInterval: 0.8)  // past the grace: a signal would have gone by now
        XCTAssertTrue(try SystemProcessTable().isGroupLive(pgid), "the reused group was signalled")
        let audit = try daemon.side.auditEntries().filter { $0.resourceID == resource.id }.map(\.type)
        XCTAssertTrue(audit.contains("leftover_skipped"), "\(audit)")
        XCTAssertFalse(audit.contains { $0 == "leftover_term" || $0 == "leftover_kill" }, "\(audit)")
    }

    func testCancelNeverSignalsAReusedProcessGroup() throws {
        let table = ReusedPIDTable()
        let daemon = try start(table)
        let id = try daemon.submit(params("sleep 30")).job.id
        try eventually("running") { try daemon.job(id).state == .running }
        let (resource, pgid) = try group(daemon, id)
        defer { kill(-pgid, SIGKILL) }
        table.markReused(pgid)
        _ = try daemon.result(.cancel(CancelParams(jobID: id)))
        XCTAssertEqual(try daemon.job(id).state, .canceled)
        try eventually("resource released") { try daemon.side.resource(id: resource.id)?.state == .released }
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(try SystemProcessTable().isGroupLive(pgid), "the reused group was signalled")
        let audit = try daemon.side.auditEntries().filter { $0.resourceID == resource.id }.map(\.type)
        XCTAssertFalse(audit.contains { $0 == "leftover_term" || $0 == "leftover_kill" }, "\(audit)")
    }

    func testTheAlertTokenNeverReachesAJob() throws {
        let dir = "/tmp/sqd-" + UUID().uuidString.prefix(8)
        let executor = ProcessExecutor(
            artifacts: JobArtifacts(root: SimQueuePaths(stateDir: dir).jobsRoot), processes: SystemProcessTable(),
            baseEnvironment: ["PATH": "/usr/bin:/bin", "ALERT_TOKEN": "daemon-secret", "KEEP": "kept"],
            graceSeconds: 0.3, secretEnvironmentKeys: ["ALERT_TOKEN"])
        let daemon = try TestDaemon(stateDir: dir, realProcesses: true, executorOverride: executor)
        addTeardownBlock { daemon.destroy() }
        let id = try daemon.submit(
            params(#"echo "token=[${ALERT_TOKEN:-}] keep=[$KEEP]""#, environment: ["ALERT_TOKEN": "job-copy"])
        ).job.id
        let job = try daemon.wait(id)
        XCTAssertEqual(job.state, .succeeded)
        let log = try String(contentsOfFile: try XCTUnwrap(job.logPath), encoding: .utf8)
        XCTAssertTrue(log.contains("token=[] keep=[kept]"), log)
    }
}
