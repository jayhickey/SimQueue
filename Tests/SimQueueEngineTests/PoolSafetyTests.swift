// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

/// #37: pool host actions respect report-only mode and the destructive-action limits,
/// and the boot gate waits for other tools' booted sims (`external_sim_patterns`).
final class PoolSafetyTests: XCTestCase {
    private func setUp(_ mode: CleanupMode, perHour: Int = 10) throws -> (Harness, JobStore, Engine) {
        let harness = Harness()
        harness.reliability.cleanupMode = mode
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

    private func audits(_ store: JobStore, _ type: String) throws -> [String] {
        try store.auditEntries().filter { $0.type == type }.compactMap(\.detail)
    }

    func testReportOnlyPlansButNeverTouchesASimAndReportsOnce() throws {
        let (harness, store, engine) = try setUp(.reportOnly)
        let config = SimPoolConfig()
        for _ in 0..<5 {
            let report = try engine.poolPass(config: config, demand: 1)
            XCTAssertEqual(report.actions, [.create])
            XCTAssertEqual(report.wouldExecute, [.create])
            harness.clock.advance(by: 30)
        }
        XCTAssertTrue(try harness.sims.listDevices().isEmpty, "nothing created")
        XCTAssertTrue(try store.poolSims().isEmpty)
        XCTAssertEqual(try audits(store, "pool_would_execute"), ["create"], "an unchanged plan is reported once")
    }

    func testReportOnlyNeitherBootsShutsDownNorRecyclesExistingPoolSims() throws {
        // Sims made in enforce, then the daemon restarts in report-only.
        let (harness, store, enforced) = try setUp(.enforce)
        let config = SimPoolConfig()
        _ = try enforced.poolPass(config: config, demand: 1)
        let udid = try XCTUnwrap(try store.poolSims().first?.udid)
        harness.reliability.cleanupMode = .reportOnly
        let (engine, _, _) = try harness.start(store: store)
        let boot = try engine.poolPass(config: config, demand: 1)
        XCTAssertEqual(boot.wouldExecute, [.boot(udid: udid, reason: .demand)])
        XCTAssertTrue(harness.sims.bootedUDIDs.isEmpty)
        harness.clock.advance(by: 8 * 86_400)
        let recycle = try engine.poolPass(config: config, demand: 0)
        XCTAssertTrue(recycle.wouldExecute.contains { if case .recycle = $0 { return true } else { return false } })
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty, "no recycle delete in report-only")
        XCTAssertEqual(try store.poolSims().map(\.udid), [udid])
    }

    func testRecyclesCountAgainstTheHourlyLimit() throws {
        let (harness, store, engine) = try setUp(.enforce, perHour: 1)
        let config = SimPoolConfig()
        _ = try engine.poolPass(config: config, demand: 1)
        harness.clock.advance(by: 8 * 86_400)
        // The hour's one destructive action is already used.
        try store.audit(Engine.destructiveAuditType, detail: "earlier cleanup", now: harness.clock.now())
        let held = try engine.poolPass(config: config, demand: 0)
        XCTAssertEqual(held.recyclesPostponed.count, 1)
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
        _ = try engine.poolPass(config: config, demand: 0)
        XCTAssertEqual(try audits(store, "pool_recycle_postponed").count, 1, "reported once while held")
        harness.clock.advance(by: 3601)  // the earlier action leaves the hour window
        let done = try engine.poolPass(config: config, demand: 0)
        XCTAssertTrue(done.recyclesPostponed.isEmpty)
        XCTAssertEqual(harness.sims.deletedUDIDs.count, 1)
        XCTAssertEqual(
            try audits(store, Engine.destructiveAuditType).filter { $0.hasPrefix("recycled pool sim") }.count, 1)
    }

    func testBootsWaitWhileAnotherToolsSimIsBooted() throws {
        let (harness, store, engine) = try setUp(.enforce)
        var config = SimPoolConfig()
        config.externalSimPatterns = ["Other Tool Smoke *", "slot-?"]
        _ = try engine.poolPass(config: config, demand: 1)
        let udid = try XCTUnwrap(try store.poolSims().first?.udid)
        let ours = try harness.sims.listDevices()
        let external = SimDevice(udid: "EXT-1", name: "Other Tool Smoke 42", isBooted: true)
        let idle = SimDevice(udid: "EXT-2", name: "slot-1", isBooted: false)
        harness.sims.setDevices(ours + [external, idle])
        for _ in 0..<3 {
            let report = try engine.poolPass(config: config, demand: 1)
            XCTAssertEqual(report.bootsDeferredForExternal, [udid])
        }
        XCTAssertTrue(harness.sims.bootedUDIDs.isEmpty)
        XCTAssertEqual(try audits(store, "pool_boot_deferred_external").count, 1, "reported once while it lasts")
        try harness.sims.shutdownDevice(udid: "EXT-1")
        let report = try engine.poolPass(config: config, demand: 1)
        XCTAssertTrue(report.bootsDeferredForExternal.isEmpty)
        XCTAssertEqual(harness.sims.bootedUDIDs, [udid], "a shut-down external sim doesn't hold boots")
    }

    /// Report-only: a sim whose job ended is not shut down. It stays leased (booted, never
    /// handed out), the shutdown is reported once, and enforce mode releases it.
    func testReportOnlyNeverShutsDownTheSimOfAnEndedJob() throws {
        let (harness, store, engine) = try setUp(.enforce)
        var config = SimPoolConfig()
        config.settle.mode = .load
        for _ in 0..<6 where try store.poolSims().first?.phase != .ready {
            _ = try engine.poolPass(config: config, demand: 1)
            harness.clock.advance(by: 30)
        }
        var sim = try XCTUnwrap(try store.poolSims().first)
        XCTAssertEqual(sim.phase, .ready)
        sim = try sim.applying(.leased(leaseID: "job:J-ENDED"), now: harness.clock.now())  // no such active job
        try store.savePoolSim(sim)
        harness.reliability.cleanupMode = .reportOnly
        let (reportOnly, _, _) = try harness.start(store: store)
        for _ in 0..<3 {
            let report = try reportOnly.poolPass(config: config, demand: 0)
            XCTAssertTrue(report.releasedFromJobs.isEmpty)
            harness.clock.advance(by: 30)
        }
        XCTAssertEqual(try store.poolSims().first?.phase, .leased, "not handed out, not shut down")
        XCTAssertEqual(try harness.sims.listDevices().first { $0.udid == sim.udid }?.isBooted, true)
        XCTAssertEqual(
            try audits(store, "pool_would_execute").filter { $0.hasPrefix("shutdown \(sim.udid)") }.count, 1,
            "reported once")
        harness.reliability.cleanupMode = .enforce
        let (enforcing, _, _) = try harness.start(store: store)
        let report = try enforcing.poolPass(config: config, demand: 0)
        XCTAssertEqual(report.releasedFromJobs, [sim.udid])
        XCTAssertEqual(try store.poolSims().first?.phase, .ready, "release preserves warm state")
        XCTAssertEqual(try harness.sims.listDevices().first { $0.udid == sim.udid }?.isBooted, true)
        harness.clock.advance(by: config.idleShutdownSeconds + 1)
        _ = try enforcing.poolPass(config: config, demand: 0)
        XCTAssertEqual(try harness.sims.listDevices().first { $0.udid == sim.udid }?.isBooted, false)
        XCTAssertEqual(try store.poolSims().first?.phase, .shutdown)
        XCTAssertTrue(try store.liveResources(kinds: [.sim]).contains { $0.externalID == sim.udid })
    }

    func testCreatesWaitWhileAnotherToolsSimIsBooted() throws {
        let (harness, store, engine) = try setUp(.enforce)
        var config = SimPoolConfig()
        config.externalSimPatterns = ["Other Tool Slot *"]
        harness.sims.setDevices([SimDevice(udid: "EXT-1", name: "Other Tool Slot 1", isBooted: true)])
        for _ in 0..<3 {
            let report = try engine.poolPass(config: config, demand: 1)
            XCTAssertEqual(report.createsDeferredForExternal, 1)
        }
        XCTAssertTrue(try store.poolSims().isEmpty, "nothing created")
        XCTAssertEqual(try audits(store, "pool_boot_deferred_external").count, 1, "reported once while it lasts")
        try harness.sims.shutdownDevice(udid: "EXT-1")
        let report = try engine.poolPass(config: config, demand: 1)
        XCTAssertEqual(report.createsDeferredForExternal, 0)
        XCTAssertEqual(try store.poolSims().count, 1)
    }

    func testGlob() {
        XCTAssertTrue(Glob.matches(pattern: "Other Tool Smoke *", "Other Tool Smoke 21050"))
        XCTAssertTrue(Glob.matches(pattern: "slot-?", "slot-0"))
        XCTAssertTrue(Glob.matches(pattern: "*smoke*", "a smoke b"))
        XCTAssertFalse(Glob.matches(pattern: "slot-?", "slot-10"))
        XCTAssertFalse(Glob.matches(pattern: "Other*", "other tool"), "case-sensitive")
        XCTAssertTrue(Glob.matches(pattern: "a*b*c", "aXbYc"))
        XCTAssertFalse(Glob.matches(pattern: "a*b*c", "aXbY"))
    }
}
