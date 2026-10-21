// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import XCTest

final class SimPoolPlannerTests: XCTestCase {
    private func sim(
        _ udid: String, _ phase: PoolSimPhase, created: Double = 0, used: Double? = nil, since: Double? = nil,
        prewarm: Bool = false, tainted: Bool = false
    ) -> PoolSim {
        PoolSim(
            udid: udid, name: "simq-pool-\(udid)", phase: phase, createdAt: created, lastUsedAt: used,
            phaseSince: since, prewarmPending: prewarm, tainted: tainted)
    }

    private func plan(
        _ sims: [PoolSim], demand: Int = 0, signals: [String: SettleSignals] = [:], unleased: Set<String> = [],
        now: Double = 1000, config: SimPoolConfig = SimPoolConfig()
    ) -> [SimPoolAction] {
        SimPoolPlanner.plan(
            SimPoolInput(sims: sims, demand: demand, signals: signals, unleasedUsers: unleased, now: now),
            config: config)
    }

    // MARK: settle gate

    func testSettleGateModes() {
        let config = SettleConfig()
        XCTAssertEqual(SettleGate.evaluate(config, signals: SettleSignals(load5: 19.9), waitedSeconds: 0), .settled)
        XCTAssertEqual(SettleGate.evaluate(config, signals: SettleSignals(load5: 20), waitedSeconds: 10), .wait)
        XCTAssertEqual(SettleGate.evaluate(config, signals: SettleSignals(), waitedSeconds: 10), .wait, "unknown load")
        XCTAssertEqual(SettleGate.evaluate(config, signals: SettleSignals(load5: 50), waitedSeconds: 180), .capHit)
        XCTAssertEqual(
            SettleGate.evaluate(SettleConfig(mode: .off), signals: SettleSignals(), waitedSeconds: 0), .settled)
    }

    func testDefaultDerivedLoadRecoveryPreservesBoundariesAndCaps() {
        var config = SettleConfig(onCap: .fail)
        config.load1RecoveryBelow = 20
        for waited in [0.0, 179, 180] {
            XCTAssertEqual(
                SettleGate.evaluate(config, signals: SettleSignals(load5: 31, load1: 20), waitedSeconds: waited),
                .settled, "recovered current load takes precedence over the cap, like recovered load5")
        }
        for signals in [SettleSignals(load5: 31, load1: 20.01), SettleSignals(load5: 31), SettleSignals()] {
            XCTAssertEqual(SettleGate.evaluate(config, signals: signals, waitedSeconds: 179), .wait)
            XCTAssertEqual(SettleGate.evaluate(config, signals: signals, waitedSeconds: 180), .capHit)
        }
        config.load1RecoveryBelow = nil
        XCTAssertEqual(
            SettleGate.evaluate(config, signals: SettleSignals(load5: 31, load1: 1), waitedSeconds: 10), .wait,
            "explicit historical-load settling has no short-average bypass")
        XCTAssertEqual(
            SettleGate.evaluate(config, signals: SettleSignals(load5: 19.9), waitedSeconds: 10), .settled,
            "the original strict load5 threshold still works without load1")
    }

    func testDerivedRecoveryDoesNotBecomeAConfigSetting() throws {
        var config = SettleConfig()
        config.load1RecoveryBelow = 20
        let data = try JSONEncoder().encode(config)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), ["mode", "load_below", "max_wait_seconds", "on_cap"])
        let decoded = try JSONDecoder().decode(SettleConfig.self, from: data)
        XCTAssertNil(decoded.load1RecoveryBelow, "host sizing must derive policy again after decode")
        XCTAssertEqual(decoded.loadBelow, config.loadBelow)
        let oldSignals = try JSONDecoder().decode(SettleSignals.self, from: Data(#"{"load5":31}"#.utf8))
        XCTAssertNil(oldSignals.load1, "old signal data remains conservative")
        XCTAssertEqual(oldSignals.load5, 31)
    }

    func testSettlingSimsSettleHitTheCapOrFail() {
        let sims = [sim("A", .settling, since: 900), sim("B", .settling, since: 700)]
        XCTAssertEqual(
            plan(sims, signals: ["A": SettleSignals(load5: 5), "B": SettleSignals(load5: 40)]),
            [
                .settled(udid: "A", capHit: false, waitedSeconds: 100),
                .settled(udid: "B", capHit: true, waitedSeconds: 300),
            ])
        var failing = SimPoolConfig()
        failing.settle.onCap = .fail
        XCTAssertEqual(
            plan(sims, signals: ["A": SettleSignals(load5: 40), "B": SettleSignals(load5: 40)], config: failing),
            [.settleFailed(udid: "B", waitedSeconds: 300)])
    }

    func testUnfinishedRecycleIsRetriedInsteadOfStranded() {
        let actions = plan([sim("A", .recycling)], demand: 0)
        XCTAssertEqual(actions, [.recycle(udid: "A", reason: "unfinished recycle or failed boot")])
    }

    // MARK: boots

    func testDemandCreatesThenBootsOneAtATime() {
        XCTAssertEqual(plan([], demand: 3), [.create, .create], "max_sims = 2")
        let two = [sim("A", .shutdown), sim("B", .shutdown, used: 50)]
        XCTAssertEqual(
            plan(two, demand: 2), [.boot(udid: "B", reason: .demand)], "one boot slot; most recently used first")
        // A settling sim still holds the boot slot.
        XCTAssertEqual(plan([sim("A", .shutdown), sim("B", .settling, since: 990)], demand: 2), [])
        XCTAssertEqual(plan([sim("A", .shutdown), sim("B", .booting, since: 990)], demand: 2), [])
        var wide = SimPoolConfig()
        wide.maxConcurrentBoots = 2
        XCTAssertEqual(
            plan(two, demand: 2, config: wide), [.boot(udid: "B", reason: .demand), .boot(udid: "A", reason: .demand)])
    }

    func testDemandMetByReadyOrComingSimsBootsNothing() {
        XCTAssertEqual(plan([sim("A", .ready), sim("B", .shutdown)], demand: 1), [])
        XCTAssertEqual(plan([sim("A", .settling, since: 999), sim("B", .shutdown)], demand: 1), [])
    }

    func testWarmMinBootsWithoutDemand() {
        var config = SimPoolConfig()
        config.warmMin = 1
        XCTAssertEqual(plan([sim("A", .shutdown)], config: config), [.boot(udid: "A", reason: .warmMin)])
        XCTAssertEqual(plan([], config: config), [.create])
        XCTAssertEqual(plan([sim("A", .ready, used: 0)], now: 100_000, config: config), [], "warm_min isn't shut down")
    }

    func testPrewarmYieldsToDemand() {
        let sims = [sim("P", .shutdown, used: 10, prewarm: true)]
        XCTAssertEqual(plan(sims), [.boot(udid: "P", reason: .prewarm)])
        // Someone waiting: the boot is for them (same sim), not a pre-warm.
        XCTAssertEqual(plan(sims, demand: 1), [.boot(udid: "P", reason: .demand)])
        // The only boot slot is taken by a demand boot; the pre-warm waits.
        let busy = [sim("P", .shutdown, used: 10, prewarm: true), sim("D", .shutdown, used: 20)]
        XCTAssertEqual(plan(busy, demand: 1), [.boot(udid: "P", reason: .demand)])
        XCTAssertEqual(plan([sim("P", .shutdown, prewarm: true), sim("B", .settling, since: 999)]), [])
    }

    // MARK: idle shutdown and recycle

    func testIdleShutdownAfterThirtyMinutes() {
        let ready = [sim("A", .ready, used: 0, since: 0)]
        XCTAssertEqual(plan(ready, now: 1799), [])
        XCTAssertEqual(plan(ready, now: 1800), [.shutdown(udid: "A")])
        XCTAssertEqual(plan(ready, demand: 1, now: 5000), [], "never while someone is waiting")
        XCTAssertEqual(plan([sim("L", .leased, used: 0, since: 0)], now: 100_000), [], "leased sims aren't idle")
    }

    func testRecycleAfterSevenDaysOrAStuckBoot() {
        let week = 7 * 24 * 3600.0
        XCTAssertEqual(
            plan([sim("old", .ready, used: week, since: week), sim("leased", .leased)], now: week),
            [.recycle(udid: "old", reason: "older than 604800 s")])
        XCTAssertEqual(
            plan([sim("stuck", .booting, since: 0)], now: 300),
            [.recycle(udid: "stuck", reason: "boot didn't finish in 300 s")])
    }

    // MARK: unleased users

    func testASimInUseWithoutALeaseIsNeverHandedOutThenRecycled() {
        let sims = [sim("A", .ready, tainted: true), sim("B", .shutdown)]
        XCTAssertTrue(SimPoolPlanner.handoffCandidates(sims, unleasedUsers: ["A"]).isEmpty)
        // While the user is alive: no handoff, and demand boots the other sim instead.
        XCTAssertEqual(plan(sims, demand: 1, unleased: ["A"]), [.boot(udid: "B", reason: .demand)])
        // Once it's gone: recycled, never reused as is.
        XCTAssertEqual(plan(sims, unleased: []), [.recycle(udid: "A", reason: "used without a lease")])
    }
}
