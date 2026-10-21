// SPDX-License-Identifier: MIT

import SimQueueCore
import XCTest

final class SimPoolStateMachineTests: XCTestCase {
    private let fresh = PoolSim(udid: "A", name: "simq-pool-A", phase: .shutdown, createdAt: 0)

    func testTheLifecycleGoesThroughSettlingBeforeReady() throws {
        var sim = try fresh.applying(.bootStarted, now: 10)
        XCTAssertEqual(sim.phase, .booting)
        XCTAssertTrue(sim.holdsBootSlot)
        sim = try sim.applying(.bootFinished, now: 40)
        XCTAssertEqual(sim.phase, .settling)
        XCTAssertTrue(sim.holdsBootSlot, "settling counts as a boot")
        XCTAssertEqual(sim.phaseSince, 40, "the settle timer starts when the boot finishes")
        XCTAssertThrowsError(try sim.applying(.leased(leaseID: "L1"), now: 41), "no handoff before the gate")
        sim = try sim.applying(.settled, now: 90)
        XCTAssertEqual(sim.phase, .ready)
        XCTAssertFalse(sim.holdsBootSlot)
        sim = try sim.applying(.leased(leaseID: "L1"), now: 100)
        XCTAssertEqual(sim.leaseID, "L1")
        XCTAssertThrowsError(try sim.applying(.recycleStarted, now: 101), "never recycled under a lease")
        sim = try sim.applying(.released(prewarm: true), now: 200)
        XCTAssertEqual(sim.phase, .shutdown)
        XCTAssertNil(sim.leaseID)
        XCTAssertEqual(sim.lastUsedAt, 200)
        XCTAssertTrue(sim.prewarmPending)
        sim = try sim.applying(.bootStarted, now: 201)
        XCTAssertFalse(sim.prewarmPending)
    }

    func testCapFailShutsDownAndABootFailureRecycles() throws {
        let settling = try fresh.applying(.bootStarted, now: 0).applying(.bootFinished, now: 1)
        XCTAssertEqual(try settling.applying(.settleFailed, now: 181).phase, .shutdown)
        let recycling = try fresh.applying(.bootStarted, now: 0).applying(.bootFailed, now: 300)
        XCTAssertEqual(recycling.phase, .recycling)
        let recreated = try recycling.applying(.recreated(udid: "A2"), now: 310)
        XCTAssertEqual(recreated.udid, "A2")
        XCTAssertEqual(recreated.phase, .shutdown)
        XCTAssertEqual(recreated.createdAt, 310)
    }

    func testATaintedSimIsNeverBootedOrHandedOutUntilRecreated() throws {
        let ready = try fresh.applying(.bootStarted, now: 0).applying(.bootFinished, now: 1).applying(.settled, now: 2)
        let tainted = try ready.applying(.unleasedUseSeen, now: 3)
        XCTAssertEqual(tainted.phase, .ready)
        XCTAssertThrowsError(try tainted.applying(.leased(leaseID: "L"), now: 4))
        let off = try tainted.applying(.shutDown, now: 5)
        XCTAssertThrowsError(try off.applying(.bootStarted, now: 6))
        let clean = try off.applying(.recycleStarted, now: 7).applying(.recreated(udid: "B"), now: 8)
        XCTAssertFalse(clean.tainted)
    }

    func testInvalidTransitionsName() {
        XCTAssertThrowsError(try fresh.applying(.settled, now: 1)) { error in
            XCTAssertEqual("\(error)", "pool sim A: settled isn't allowed while shutdown")
        }
    }

    func testSettleCapHitIsLoggedWithSignalsAndOutcome() {
        let sims = [
            PoolSim(udid: "A", name: "a", phase: .settling, createdAt: 0, phaseSince: 0),
            PoolSim(udid: "B", name: "b", phase: .settling, createdAt: 0, phaseSince: 100),
        ]
        let input = SimPoolInput(
            sims: sims, demand: 1, signals: ["A": SettleSignals(load5: 42.5), "B": SettleSignals(load5: 3)], now: 200)
        var config = SimPoolConfig()
        config.maxConcurrentBoots = 2
        let handoff = SimPoolPlanner.plan(input, config: config)
        XCTAssertEqual(
            SimPoolPlanner.logEntries(for: handoff, input: input, config: config),
            [
                SimPoolLogEntry(
                    type: "settle_cap_hit", udid: "A",
                    detail: "mode=load load1=unknown load5=42.5 waited=200s max_wait=180s on_cap=handoff")
            ], "B settled normally: no log")
        config.settle.onCap = .fail
        let failed = SimPoolPlanner.plan(input, config: config)
        XCTAssertEqual(
            SimPoolPlanner.logEntries(for: failed, input: input, config: config).map(\.detail),
            [
                "mode=load load1=unknown load5=42.5 waited=200s max_wait=180s on_cap=fail"
            ])
    }

    /// A fake boot storm: each finished boot spikes the fake host's load5, which then decays.
    /// Driving the planner and state machine together must never have more than one sim
    /// booting or settling, and never hand out a sim before its gate passes.
    func testAFakeBootStormStaysSerialAndGated() throws {
        var config = SimPoolConfig()
        config.maxSims = 4
        var sims: [PoolSim] = []
        var load5 = 1.0
        var handedOut: [String] = []
        var created = 0
        var settledAt: [String: Double] = [:]
        for step in 0..<200 {
            let now = Double(step) * 10
            // Fake host: a boot that finishes this step spikes load; load decays otherwise.
            for index in sims.indices where sims[index].phase == .booting && now - sims[index].phaseSince >= 20 {
                sims[index] = try sims[index].applying(.bootFinished, now: now)
                load5 += 40
            }
            load5 = max(1, load5 * 0.8)
            XCTAssertLessThanOrEqual(sims.filter(\.holdsBootSlot).count, 1, "step \(step)")
            let signals = Dictionary(
                uniqueKeysWithValues: sims.filter { $0.phase == .settling }.map {
                    ($0.udid, SettleSignals(load5: load5))
                })
            let input = SimPoolInput(sims: sims, demand: 4 - handedOut.count, signals: signals, now: now)
            for action in SimPoolPlanner.plan(input, config: config) {
                switch action {
                case .create:
                    created += 1
                    sims.append(
                        PoolSim(udid: "S\(created)", name: "simq-pool-\(created)", phase: .shutdown, createdAt: now))
                case .boot(let udid, _):
                    let index = try XCTUnwrap(sims.firstIndex { $0.udid == udid })
                    sims[index] = try sims[index].applying(.bootStarted, now: now)
                case .settled(let udid, let capHit, _):
                    XCTAssertFalse(capHit, "load decays below 20 well inside 180 s")
                    XCTAssertLessThan(load5, config.settle.loadBelow)
                    let index = try XCTUnwrap(sims.firstIndex { $0.udid == udid })
                    sims[index] = try sims[index].applying(.settled, now: now)
                    settledAt[udid] = now
                default: XCTFail("unexpected \(action)")
                }
            }
            for sim in SimPoolPlanner.handoffCandidates(sims, unleasedUsers: []) where handedOut.count < 4 {
                let index = try XCTUnwrap(sims.firstIndex { $0.udid == sim.udid })
                sims[index] = try sims[index].applying(.leased(leaseID: "L\(handedOut.count)"), now: now)
                handedOut.append(sim.udid)
            }
        }
        XCTAssertEqual(handedOut.count, 4)
        XCTAssertEqual(Set(settledAt.keys), Set(handedOut))
    }
}
