// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueProtocol
import SimQueueSim
import XCTest

/// Records every call; a write reaching it would be a host action.
final class SpySimBackend: SimBackend, @unchecked Sendable {
    let kind: BackendKind = .simctl
    private let lock = NSLock()
    private(set) var writes: [String] = []
    private(set) var reads = 0
    func listDevices() throws -> [SimDevice] {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return [SimDevice(udid: "SPY-1", name: "iPhone 16", isBooted: true)]
    }
    func poolSnapshot() throws -> PoolSnapshot { PoolSnapshot(idleRunning: 4) }
    private func write(_ call: String) {
        lock.lock()
        writes.append(call)
        lock.unlock()
    }
    func deleteDevice(udid: String) throws { write("delete \(udid)") }
    func createDevice(name: String) throws -> SimDevice {
        write("create \(name)")
        return SimDevice(udid: "SPY-NEW", name: name, isBooted: false)
    }
    func bootDevice(udid: String) throws { write("boot \(udid)") }
    func shutdownDevice(udid: String) throws { write("shutdown \(udid)") }
}

final class SpyProcessTable: ProcessTable, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var writes: [String] = []
    var supportsEnvironmentScan: Bool { false }
    func liveProcessGroups() throws -> Set<Int32> { [] }
    func processIdentity(_ pid: Int32) throws -> String? { nil }
    func processes(withEnvironmentEntry entry: String) throws -> [ProcessMatch] { [] }
    func terminateGroup(_ pgid: Int32, graceSeconds: Double) throws {
        lock.lock()
        writes.append("terminate \(pgid)")
        lock.unlock()
    }
    func signalGroup(_ pgid: Int32, _ signal: ProcessSignal) throws {
        lock.lock()
        writes.append("signal \(pgid)")
        lock.unlock()
    }
}

final class DryRunTests: XCTestCase {
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    func testDecoratorsLogEveryHostWriteAndPassNothingThrough() throws {
        let sims = SpySimBackend()
        let processes = SpyProcessTable()
        let lines = Lines()
        let drySims = DryRunSimBackend(sims, log: { lines.append($0) })
        let dryProcesses = DryRunProcessTable(processes, log: { lines.append($0) })
        XCTAssertEqual(try drySims.listDevices().count, 1, "reads pass through")
        XCTAssertThrowsError(try drySims.createDevice(name: "simq-pool-1-1")) {
            XCTAssertEqual($0 as? DryRunError, .skipped("create sim simq-pool-1-1"))
        }
        XCTAssertThrowsError(try drySims.bootDevice(udid: "U"))
        XCTAssertThrowsError(try drySims.shutdownDevice(udid: "U"))
        XCTAssertThrowsError(try drySims.deleteDevice(udid: "U"))
        XCTAssertThrowsError(try dryProcesses.terminateGroup(42, graceSeconds: 1))
        XCTAssertThrowsError(try dryProcesses.signalGroup(42, .term))
        XCTAssertEqual(sims.writes, [])
        XCTAssertEqual(processes.writes, [])
        XCTAssertEqual(
            lines.all,
            [
                "dry-run: would create sim simq-pool-1-1", "dry-run: would boot sim U",
                "dry-run: would shut down sim U",
                "dry-run: would delete sim U", "dry-run: would terminate process group 42",
                "dry-run: would send term to process group 42",
            ])
    }

    func testADryRunDaemonPlansPoolAndJobsButCallsNothing() throws {
        let sims = SpySimBackend()
        let processes = SpyProcessTable()
        let lines = Lines()
        var config = DaemonConfig()
        config.reliability.cleanupMode = .enforce
        var pool = SimPoolConfig()
        pool.warmMin = 1
        config.pool = pool
        DryRun.apply(to: &config)
        XCTAssertEqual(config.reliability.cleanupMode, .reportOnly, "dry run forces report-only cleanup")
        XCTAssertEqual(config.pool?.mode, .reportOnly, "and a report-only pool")
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("simq-dry-\(UUID().uuidString)")
        let daemon = try TestDaemon(
            config: config, simsOverride: DryRunSimBackend(sims, log: { lines.append($0) }),
            processesOverride: DryRunProcessTable(processes, log: { lines.append($0) }),
            executorOverride: DryRunExecutor(log: { lines.append($0) }))
        defer { daemon.stop() }

        var params = SubmitParams(project: "demo", submitter: "t")
        params.command = ["/usr/bin/touch", marker.path]
        let submitted = daemon.service.handle(Request(params: .submit(params)))
        guard case .result(.submit(let response)) = submitted.body else { return XCTFail("\(submitted.body)") }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let job = try daemon.service.jobInfo(response.job.id)
            let poolReported = try daemon.side.auditEntries().contains { $0.type == "pool_would_execute" }
            if job?.state == .succeeded, poolReported { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(try daemon.service.jobInfo(response.job.id)?.state, .succeeded)
        XCTAssertTrue(lines.all.contains("dry-run: would run \(response.job.id): /usr/bin/touch \(marker.path)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the job's command never ran")
        // Report-only (forced by dry run): the pool plans its create and reports it, and
        // never even asks the backend.
        XCTAssertTrue(
            try daemon.side.auditEntries().contains { $0.type == "pool_would_execute" && $0.detail == "create" })
        XCTAssertGreaterThan(sims.reads, 0, "it still plans from the real listing")
        XCTAssertEqual(sims.writes, [], "no sim was created, booted, shut down or deleted")
        XCTAssertEqual(processes.writes, [], "no process group was signalled")
    }

    /// CR's #52 follow-up: `pool.mode: active` would make the pool act under report-only
    /// cleanup. A dry run forces the pool to report-only too, so it reports its creates
    /// instead of attempting them (and logging `would create` from the decorator).
    func testADryRunForcesAnActivePoolToReportOnly() throws {
        let sims = SpySimBackend()
        let lines = Lines()
        var config = DaemonConfig()
        var pool = SimPoolConfig()
        pool.warmMin = 1
        pool.mode = .active
        config.pool = pool
        DryRun.apply(to: &config)
        XCTAssertEqual(config.pool?.mode, .reportOnly)
        XCTAssertEqual(config.reliability.cleanupMode, .reportOnly)
        let daemon = try TestDaemon(
            config: config, simsOverride: DryRunSimBackend(sims, log: { lines.append($0) }),
            processesOverride: DryRunProcessTable(SpyProcessTable(), log: { lines.append($0) }),
            executorOverride: DryRunExecutor(log: { lines.append($0) }))
        defer { daemon.stop() }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if try daemon.side.auditEntries().contains(where: { $0.type == "pool_would_execute" }) { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(
            try daemon.side.auditEntries().contains { $0.type == "pool_would_execute" && $0.detail == "create" })
        XCTAssertFalse(lines.all.contains { $0.hasPrefix("dry-run: would create sim") }, "\(lines.all)")
        XCTAssertEqual(sims.writes, [])
    }

    /// Without a pool section there's nothing to force.
    func testADryRunLeavesAMissingPoolMissing() {
        var config = DaemonConfig()
        config.pool = nil
        DryRun.apply(to: &config)
        XCTAssertNil(config.pool)
    }
}
