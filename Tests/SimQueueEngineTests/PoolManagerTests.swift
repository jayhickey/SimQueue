// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

final class PoolManagerTests: XCTestCase {
    private func setUp(load1: Double = 1, load5: Double = 1) throws -> (Harness, JobStore, Engine) {
        let harness = Harness()
        harness.reliability.cleanupMode = .enforce  // the pool takes no host action in report-only
        harness.probe.update { host in
            host.cpuCount = 8
            host.load1 = load1
            host.load5 = load5
        }
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        return (harness, store, engine)
    }

    private func audits(_ store: JobStore, _ type: String) throws -> [String] {
        try store.auditEntries().filter { $0.type == type }.compactMap(\.detail)
    }

    func testDemandCreatesBootsSettlesAndWarmReleaseAllowsConsecutiveReuse() throws {
        let (harness, store, engine) = try setUp(load5: 40)
        var config = SimPoolConfig()
        XCTAssertEqual(try engine.poolPass(config: config, demand: 1).actions, [.create])
        let udid = try XCTUnwrap(try store.poolSims().first?.udid)
        XCTAssertEqual(try store.liveResources(kinds: [.sim]).map(\.externalID), [udid], "owned by the pool")
        _ = try engine.poolPass(config: config, demand: 1)
        XCTAssertEqual(try store.poolSims().first?.phase, .settling)
        XCTAssertNil(try engine.acquirePoolSim(leaseID: "L1"), "never handed out while settling")

        harness.clock.advance(by: 30)
        harness.probe.update { $0.load5 = 3 }
        _ = try engine.poolPass(config: config, demand: 1)
        XCTAssertEqual(try store.poolSims().first?.phase, .ready)
        let leased = try XCTUnwrap(try engine.acquirePoolSim(leaseID: "L1"))
        XCTAssertEqual(leased.leaseID, "L1")

        let released = try engine.releasePoolSim(udid: udid, config: config)
        XCTAssertEqual(released.phase, .ready)
        XCTAssertFalse(released.prewarmPending)
        XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty)
        let second = try XCTUnwrap(engine.acquirePoolSim(leaseID: "L2"))
        XCTAssertEqual(second.udid, udid, "a warm lease reuses state unless the caller requests reset/fresh")
        XCTAssertEqual(second.leaseID, "L2")
    }

    /// Session 3: `pool_boot_deferred` was written every tick (662 rows). Now: once when
    /// the deferral starts or its sims change, a reminder every 5 minutes, and
    /// `pool_boot_resumed` when it clears.
    func testALoadDeferralIsAuditedOnChangeAndEveryFiveMinutesNotEveryPass() throws {
        let (harness, store, engine) = try setUp(load1: 30)
        let config = SimPoolConfig()
        _ = try engine.poolPass(config: config, demand: 1)  // create
        for _ in 0..<120 {
            harness.clock.advance(by: 1)
            XCTAssertEqual(try engine.poolPass(config: config, demand: 1).bootsDeferredForLoad.count, 1)
        }
        XCTAssertEqual(try audits(store, "pool_boot_deferred").count, 1, "unchanged: no row per pass")
        harness.clock.advance(by: Engine.bootDeferralReminderSeconds)
        _ = try engine.poolPass(config: config, demand: 1)
        let rows = try audits(store, "pool_boot_deferred")
        XCTAssertEqual(rows.count, 2, "a reminder after 5 minutes")
        XCTAssertTrue(rows[1].contains("still deferred after 419s, 121 passes"), rows[1])
        harness.probe.update { $0.load1 = 1 }
        _ = try engine.poolPass(config: config, demand: 1)
        let resumed = try audits(store, "pool_boot_resumed")
        XCTAssertEqual(resumed.count, 1)
        XCTAssertTrue(resumed[0].contains("after 419s (121 passes"), resumed[0])
        _ = try engine.poolPass(config: config, demand: 1)
        XCTAssertEqual(try audits(store, "pool_boot_resumed").count, 1, "once")
    }

    /// #90 follow-ups: a change in which sims wait keeps both the start and the pass count,
    /// and `pool_boot_resumed` means load is really back under the gate.
    func testADeferralThatEndsUnderLoadIsNotCalledResumed() throws {
        let (harness, store, engine) = try setUp(load1: 30)
        let config = SimPoolConfig()
        _ = try engine.poolPass(config: config, demand: 1)  // create
        harness.clock.advance(by: 1)
        _ = try engine.poolPass(config: config, demand: 1)  // pass 1: one sim deferred
        harness.clock.advance(by: 1)
        _ = try engine.poolPass(config: config, demand: 2)  // creates the second sim
        harness.clock.advance(by: 1)
        XCTAssertEqual(try engine.poolPass(config: config, demand: 2).bootsDeferredForLoad.count, 1)
        let rows = try audits(store, "pool_boot_deferred")
        XCTAssertEqual(rows.count, 2, "the set changed")
        XCTAssertTrue(rows[1].contains("above 24.0 (3.0x 8 cores)"), rows[1])
        harness.clock.advance(by: 1)
        XCTAssertEqual(try engine.poolPass(config: config, demand: 0).bootsDeferredForLoad, [])
        XCTAssertEqual(try audits(store, "pool_boot_resumed"), [], "load is still above the gate")
        let ended = try audits(store, "pool_boot_deferral_ended")
        XCTAssertEqual(ended.count, 1)
        XCTAssertTrue(ended[0].hasSuffix("load still high: after 3s (3 passes; load1 30.0)"), ended[0])
    }

    func testAChangeInWhichSimsWaitKeepsTheStartAndThePassCount() throws {
        let (harness, store, engine) = try setUp(load1: 30)
        let config = SimPoolConfig()
        _ = try engine.poolPass(config: config, demand: 1)
        for _ in 0..<3 {
            harness.clock.advance(by: 1)
            _ = try engine.poolPass(config: config, demand: 1)
        }
        harness.clock.advance(by: 1)
        _ = try engine.poolPass(config: config, demand: 2)
        harness.clock.advance(by: 1)
        _ = try engine.poolPass(config: config, demand: 2)
        harness.probe.update { $0.load1 = 1 }
        harness.clock.advance(by: 1)
        _ = try engine.poolPass(config: config, demand: 2)
        let resumed = try audits(store, "pool_boot_resumed")
        XCTAssertEqual(resumed.count, 1)
        // Deferred from t=1 to t=6 over 5 passes, though the waiting sim changed at t=4.
        XCTAssertEqual(resumed, ["load1 back under 24.0: after 5s (5 passes; load1 1.0)"])
        XCTAssertEqual(try audits(store, "pool_boot_deferred").count, 2, "start, then the change")
    }

    func testNoBootWhileLoad1IsAboveThreeTimesTheCores() throws {
        let (harness, store, engine) = try setUp(load1: 25)
        let config = SimPoolConfig()
        _ = try engine.poolPass(config: config, demand: 1)
        let report = try engine.poolPass(config: config, demand: 1)
        XCTAssertEqual(report.bootsDeferredForLoad.count, 1)
        XCTAssertEqual(try store.poolSims().first?.phase, .shutdown)
        XCTAssertEqual(try audits(store, "pool_boot_deferred").count, 1)
        harness.probe.update { $0.load1 = 24 }
        _ = try engine.poolPass(config: config, demand: 1)
        XCTAssertEqual(try store.poolSims().first?.phase, .settling)
    }

    func testThePoolBootGateUsesBootLoadFactor() throws {
        let harness = Harness()
        harness.reliability.cleanupMode = .enforce
        harness.config.bootLoadFactor = 2
        harness.probe.update { host in
            host.cpuCount = 8
            host.load1 = 20  // above 2x8, under 3x8
        }
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let config = SimPoolConfig()
        _ = try engine.poolPass(config: config, demand: 1)
        XCTAssertEqual(try engine.poolPass(config: config, demand: 1).bootsDeferredForLoad.count, 1)
        XCTAssertEqual(try store.poolSims().first?.phase, .shutdown)
        harness.probe.update { $0.load1 = 16 }
        _ = try engine.poolPass(config: config, demand: 1)
        XCTAssertEqual(try store.poolSims().first?.phase, .settling)
    }

    func testSettleCapHitIsAuditedAndHandsOffOrFails() throws {
        let (harness, store, engine) = try setUp(load5: 50)
        var config = SimPoolConfig()
        _ = try engine.poolPass(config: config, demand: 1)
        _ = try engine.poolPass(config: config, demand: 1)
        harness.clock.advance(by: 180)
        _ = try engine.poolPass(config: config, demand: 1)
        XCTAssertEqual(try store.poolSims().first?.phase, .ready)
        let hits = try audits(store, "settle_cap_hit")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].contains("load5=50.0") && hits[0].contains("on_cap=handoff"), hits[0])

        config.settle.onCap = .fail
        let (harness2, store2, engine2) = try setUp(load5: 50)
        _ = try engine2.poolPass(config: config, demand: 1)
        _ = try engine2.poolPass(config: config, demand: 1)
        harness2.clock.advance(by: 180)
        _ = try engine2.poolPass(config: config, demand: 1)
        XCTAssertEqual(try store2.poolSims().first?.phase, .shutdown)
        XCTAssertTrue(try audits(store2, "settle_cap_hit").first?.contains("on_cap=fail") == true)
    }

    func testRecurringSettleCapHitsReachTheSustainedAlertAndSurviveRewrites() throws {
        let (harness, store, engine) = try setUp(load5: 50)
        let watchdog = WatchdogConfig()
        let key = Engine.settleCapAnomalyKey
        func hit() throws { try store.audit("settle_cap_hit", detail: "udid=X waited=120", now: harness.clock.now()) }
        func record() throws -> AnomalyRecord? { try store.anomalies().first { $0.key == key } }

        // A real cap hit from the pool counts.
        let config = SimPoolConfig()
        _ = try engine.poolPass(config: config, demand: 1)
        _ = try engine.poolPass(config: config, demand: 1)
        harness.clock.advance(by: 180)
        _ = try engine.poolPass(config: config, demand: 1)
        harness.clock.advance(by: 1)
        _ = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertEqual(try record()?.level, .observed)
        XCTAssertEqual(try record()?.detail, "1 pool settle cap hit since the previous full pass")

        // Light passes leave it alone; full passes keep it while hits recur.
        for _ in 0..<3 {
            harness.clock.advance(by: 60)
            _ = try engine.watchdogPass(.light, config: watchdog)
            XCTAssertNotNil(try record(), "a light pass doesn't drop the pool entry")
            harness.clock.advance(by: 60)
            try hit()
            harness.clock.advance(by: 1)
            _ = try engine.watchdogPass(.full, config: watchdog)
            XCTAssertNotNil(try record(), "the full pass rewrite keeps the pool entry")
        }
        XCTAssertEqual(try record()?.level, .sustained, "4 full passes in a row with cap hits")
        XCTAssertTrue(try store.alerts().contains { $0.key.contains(key) }, "sustained raises the alert")

        // Two clean full passes clear it.
        for _ in 0..<2 {
            harness.clock.advance(by: 900)
            _ = try engine.watchdogPass(.full, config: watchdog)
        }
        XCTAssertNil(try record())
    }

    func testStartupReconcileResettlesDropsVanishedAndResets() throws {
        let (harness, store, engine) = try setUp(load5: 50)
        let config = SimPoolConfig()
        _ = try engine.poolPass(config: config, demand: 1)
        _ = try engine.poolPass(config: config, demand: 1)  // settling
        let settling = try XCTUnwrap(try store.poolSims().first)
        let ghost = PoolSim(udid: "GONE", name: "simq-pool-gone", phase: .ready, createdAt: 0)
        try store.savePoolSim(ghost)
        let notBooted = try harness.sims.createDevice(name: "simq-pool-x")
        try store.savePoolSim(PoolSim(udid: notBooted.udid, name: notBooted.name, phase: .booting, createdAt: 1))
        harness.clock.advance(by: 100)
        let report = try engine.reconcilePool()
        XCTAssertEqual(report.vanished, ["GONE"])
        XCTAssertEqual(report.resettled, [settling.udid])
        XCTAssertEqual(report.resetToShutdown, [notBooted.udid])
        XCTAssertEqual(
            try store.poolSims().first { $0.udid == settling.udid }?.phaseSince, harness.clock.now(),
            "the settle gate restarts")
    }

    func testAnUnleasedUserBlocksHandoutAndTheSimIsRecycledOnceItsGone() throws {
        let (harness, store, engine) = try setUp(load5: 3)
        let config = SimPoolConfig()
        _ = try engine.poolPass(config: config, demand: 1)
        _ = try engine.poolPass(config: config, demand: 1)
        harness.clock.advance(by: 5)
        _ = try engine.poolPass(config: config, demand: 0)
        let udid = try XCTUnwrap(try store.poolSims().first { $0.phase == .ready }?.udid)
        _ = try engine.poolPass(config: config, demand: 0, unleasedUsers: [udid])
        XCTAssertNil(try engine.acquirePoolSim(leaseID: "L", unleasedUsers: [udid]))
        XCTAssertNil(try engine.acquirePoolSim(leaseID: "L"), "tainted: never handed out")
        _ = try engine.poolPass(config: config, demand: 0)
        XCTAssertFalse(try store.poolSims().contains { $0.udid == udid })
        XCTAssertFalse(try harness.sims.listDevices().contains { $0.udid == udid })
        XCTAssertEqual(try audits(store, "pool_recycled").count, 1)
        XCTAssertTrue(try store.liveResources(kinds: [.sim]).isEmpty, "ownership released with the delete")
    }

    func testIdleShutdownAfterThirtyMinutesAndRecycleAfterSevenDays() throws {
        let (harness, store, engine) = try setUp(load5: 3)
        let config = SimPoolConfig()
        _ = try engine.poolPass(config: config, demand: 1)
        _ = try engine.poolPass(config: config, demand: 1)
        harness.clock.advance(by: 5)
        _ = try engine.poolPass(config: config, demand: 0)
        harness.clock.advance(by: 30 * 60)
        _ = try engine.poolPass(config: config, demand: 0)
        XCTAssertEqual(try store.poolSims().first?.phase, .shutdown)
        XCTAssertEqual(try audits(store, "pool_idle_shutdown").count, 1)
        harness.clock.advance(by: 7 * 86_400)
        _ = try engine.poolPass(config: config, demand: 0)
        XCTAssertTrue(try store.poolSims().isEmpty)
        XCTAssertEqual(try audits(store, "pool_recycled").count, 1)
    }

    func testPoolRowsSurviveAReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("simq-pool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.sqlite").path
        let store = try JobStore(path: path)
        let sim = PoolSim(udid: "U1", name: "simq-pool-1", phase: .ready, createdAt: 5, prewarmPending: true)
        try store.savePoolSim(sim)
        XCTAssertEqual(try JobStore(path: path).poolSims(), [sim])
    }

    func testEveryCreatedSimIsNamedSimqPoolSlotIntentID() throws {
        let (harness, store, engine) = try setUp(load5: 3)
        var config = SimPoolConfig()
        config.maxSims = 3
        config.maxConcurrentBoots = 3
        _ = try engine.poolPass(config: config, demand: 3)
        let names = try harness.sims.listDevices().map(\.name)
        XCTAssertEqual(names.count, 3)
        let pattern = try NSRegularExpression(pattern: "^simq-pool-([0-9]+)-([0-9]+)$")
        var slots: [Int] = []
        for name in names {
            XCTAssertTrue(name.hasPrefix("simq-"), name)
            let match = try XCTUnwrap(
                pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                "\(name) isn't simq-pool-<n>-<intent id>")
            slots.append(Int((name as NSString).substring(with: match.range(at: 1)))!)
        }
        XCTAssertEqual(slots.sorted(), [1, 2, 3])
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "pool_created" }.count, 3)
        XCTAssertTrue(try store.pendingActionIntents().isEmpty, "every create intent confirmed")
    }

    func testACreateIntentLeftBehindIsSettledByRecovery() throws {
        let (harness, store, engine) = try setUp()
        let done = try store.recordActionIntent(
            ActionIntent(target: .simCreate(name: ""), auditType: "pool_created", detail: "slot 1"), now: 1
        ) { .simCreate(name: "simq-pool-1-\($0)") }
        let notDone = try store.recordActionIntent(
            ActionIntent(target: .simCreate(name: ""), auditType: "pool_created", detail: "slot 2"), now: 1
        ) { .simCreate(name: "simq-pool-2-\($0)") }
        guard case .simCreate(let name) = done.target else { return XCTFail() }
        _ = try harness.sims.createDevice(name: name)
        let recovery = try engine.resolveActionIntents()
        XCTAssertEqual(recovery.confirmed.map(\.id), [done.id])
        XCTAssertEqual(recovery.abandoned.map(\.id), [notDone.id])
    }
}
