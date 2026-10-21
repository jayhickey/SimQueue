// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

/// `pool.mode`: the pool can act on its own `simq-*` sims while the watchdog's cleanup of
/// everything else stays report-only. Fakes only.
final class PoolModeTests: XCTestCase {
    private func setUp(_ cleanup: CleanupMode, perHour: Int = 10) throws -> (Harness, JobStore, Engine) {
        let harness = Harness()
        harness.reliability.cleanupMode = cleanup
        harness.reliability.maxDestructiveActionsPerHour = perHour
        harness.probe.update { host in
            host.cpuCount = 8
            host.load1 = 1
            host.load5 = 3
        }
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        return (harness, store, engine)
    }

    private func config(_ mode: PoolMode) -> SimPoolConfig {
        var config = SimPoolConfig()
        config.mode = mode
        config.settle.mode = .load
        return config
    }

    private func audits(_ store: JobStore, _ type: String) throws -> [String] {
        try store.auditEntries().filter { $0.type == type }.compactMap(\.detail)
    }

    func testModeDecidesWhetherThePoolActs() {
        XCTAssertFalse(PoolMode.followCleanup.actsOnHost(cleanupMode: .reportOnly))
        XCTAssertTrue(PoolMode.followCleanup.actsOnHost(cleanupMode: .enforce))
        XCTAssertTrue(PoolMode.active.actsOnHost(cleanupMode: .reportOnly))
        XCTAssertTrue(PoolMode.active.actsOnHost(cleanupMode: .enforce))
        XCTAssertFalse(PoolMode.reportOnly.actsOnHost(cleanupMode: .reportOnly))
        XCTAssertFalse(PoolMode.reportOnly.actsOnHost(cleanupMode: .enforce))
        XCTAssertEqual(SimPoolConfig().mode, .followCleanup, "the default keeps the old behavior")
    }

    func testActivePoolCreatesBootsAndReleasesItsOwnSimsUnderReportOnlyCleanup() throws {
        let (harness, store, engine) = try setUp(.reportOnly)
        let config = config(.active)
        for _ in 0..<6 where try store.poolSims().first?.phase != .ready {
            let report = try engine.poolPass(config: config, demand: 1)
            XCTAssertTrue(report.wouldExecute.isEmpty, "an active pool acts instead of reporting")
            harness.clock.advance(by: 30)
        }
        var sim = try XCTUnwrap(try store.poolSims().first)
        XCTAssertEqual(sim.phase, .ready)
        XCTAssertTrue(sim.name.hasPrefix("simq-"), sim.name)
        XCTAssertEqual(harness.sims.bootedUDIDs, [sim.udid])
        sim = try XCTUnwrap(try engine.acquirePoolSim(leaseID: "job:J-ENDED"))  // no such active job
        let report = try engine.poolPass(config: config, demand: 0)
        XCTAssertEqual(report.releasedFromJobs, [sim.udid], "an ended job's sim is returned warm")
        XCTAssertEqual(try store.poolSims().first?.phase, .ready, "release preserves warm state")
        XCTAssertEqual(try harness.sims.listDevices().first { $0.udid == sim.udid }?.isBooted, true)
        harness.clock.advance(by: config.idleShutdownSeconds + 1)
        _ = try engine.poolPass(config: config, demand: 0)
        XCTAssertEqual(try harness.sims.listDevices().first { $0.udid == sim.udid }?.isBooted, false)
        XCTAssertEqual(try store.poolSims().first?.phase, .shutdown)
        XCTAssertTrue(try store.liveResources(kinds: [.sim]).contains { $0.externalID == sim.udid })
        XCTAssertTrue(try audits(store, "pool_would_execute").isEmpty)
    }

    func testActivePoolRecyclesStillCountAgainstTheDestructiveLimits() throws {
        let (harness, store, engine) = try setUp(.reportOnly, perHour: 1)
        let config = config(.active)
        _ = try engine.poolPass(config: config, demand: 1)
        harness.clock.advance(by: 8 * 86_400)
        try store.audit(Engine.destructiveAuditType, detail: "earlier cleanup", now: harness.clock.now())
        let held = try engine.poolPass(config: config, demand: 0)
        XCTAssertEqual(held.recyclesPostponed.count, 1, "the hourly limit holds the recycle")
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
        harness.clock.advance(by: 3601)
        let done = try engine.poolPass(config: config, demand: 0)
        XCTAssertTrue(done.recyclesPostponed.isEmpty)
        XCTAssertEqual(harness.sims.deletedUDIDs.count, 1)
    }

    func testActivePoolStillWaitsForAnotherToolsBootedSim() throws {
        let (harness, _, engine) = try setUp(.reportOnly)
        var config = config(.active)
        config.externalSimPatterns = ["Other Tool *"]
        harness.sims.setDevices([SimDevice(udid: "EXT-1", name: "Other Tool 1", isBooted: true)])
        let report = try engine.poolPass(config: config, demand: 1)
        XCTAssertEqual(report.createsDeferredForExternal, 1)
        XCTAssertEqual(try harness.sims.listDevices().map(\.udid), ["EXT-1"], "nothing created, nothing touched")
    }

    /// The watchdog keeps following cleanup_mode: a foreign sim and a stale manual lease are
    /// only reported, even with an active pool.
    func testActivePoolLeavesWatchdogCleanupReportOnly() throws {
        let (harness, store, engine) = try setUp(.reportOnly)
        let config = config(.active)
        engine.pool = config
        for _ in 0..<6 where try store.poolSims().first?.phase != .ready {
            _ = try engine.poolPass(config: config, demand: 1)
            harness.clock.advance(by: 30)
        }
        let sim = try XCTUnwrap(try engine.acquireManualLease(leaseID: "lease:gone", pid: nil))
        harness.clock.advance(by: 3600)
        let stale = try engine.reclaimStaleManualLeases(limits: harness.reliability)
        XCTAssertEqual(stale.reported, [sim.udid])
        XCTAssertTrue(stale.reclaimed.isEmpty, "stale-lease reclaim follows cleanup_mode, not pool.mode")
        XCTAssertEqual(try store.poolSims().first?.phase, .leased)
    }

    func testReportOnlyPoolModeTouchesNothingEvenUnderEnforce() throws {
        let (harness, store, engine) = try setUp(.enforce)
        let report = try engine.poolPass(config: config(.reportOnly), demand: 1)
        XCTAssertEqual(report.wouldExecute, [.create])
        XCTAssertTrue(try harness.sims.listDevices().isEmpty)
        XCTAssertEqual(try audits(store, "pool_would_execute"), ["create"])
    }
}
