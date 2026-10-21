// SPDX-License-Identifier: MIT
import SimQueueCore
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

@testable import SimQueueEngine

/// Re-enters the serialized engine at exactly the points where the daemon's pool
/// worker drops its lock. No real simulator work or timing-sensitive threads are needed.
final class ActionIntentConcurrencyTests: XCTestCase {
    private func makeEngine() throws -> (Harness, JobStore, Engine) {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce, orphanGraceSeconds: 0))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        return (harness, store, engine)
    }

    func testWatchdogCannotSettleAnInFlightCreateOrDeleteItsUnregisteredClone() throws {
        let (harness, store, engine) = try makeEngine()
        var config = SimPoolConfig()
        config.maxSims = 1
        var protectedID: Int64?
        var cloneUDID: String?
        let report = try engine.poolPass(config: config, demand: 1) { body in
            let intent = try XCTUnwrap(try store.pendingActionIntents().first)
            protectedID = intent.id
            XCTAssertTrue(engine.hostActionIntentsInFlight.contains(intent.id))
            let before = try engine.watchdogPass(.full, config: WatchdogConfig())
            XCTAssertTrue(
                before.reconcile.intents.abandoned.isEmpty, "no clone yet does not mean the live action failed")
            XCTAssertEqual(try store.pendingActionIntents().map(\.id), [intent.id])

            let operation = try Engine.poolCloneOperation(intent)
            try body()
            guard operation.phase == .started else {
                XCTAssertTrue(try harness.sims.listDevices().isEmpty, "read-only preflight cannot create a clone")
                return
            }
            let clone = try XCTUnwrap(try harness.sims.listDevices().first { $0.name.hasPrefix("simq-pool-") })
            cloneUDID = clone.udid
            XCTAssertTrue(try store.poolSims().isEmpty, "host returned before the worker registered its clone")
            let during = try engine.watchdogPass(.full, config: WatchdogConfig())
            XCTAssertTrue(during.reconcile.intents.confirmed.isEmpty, "the live worker owns confirmation")
            XCTAssertEqual(try store.pendingActionIntents().map(\.id), [intent.id])
            XCTAssertFalse(harness.sims.deletedUDIDs.contains(clone.udid), "an in-flight clone is not a namespace leak")
            XCTAssertFalse(
                during.reconcile.actions.contains { action in
                    if case .deleteSim(let udid, _) = action { return udid == clone.udid }
                    return false
                })
        }
        XCTAssertEqual(report.actions, [.create])
        XCTAssertEqual(try store.poolSims().map(\.udid), [try XCTUnwrap(cloneUDID)])
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
        XCTAssertFalse(engine.hostActionIntentsInFlight.contains(try XCTUnwrap(protectedID)))
        XCTAssertEqual(try store.auditEntries().filter { $0.type == Engine.poolCreatedAuditType }.count, 1)
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
    }

    func testWatchdogDoesNotAbandonOrPrematurelyConfirmAnInFlightRecycle() throws {
        let (harness, store, engine) = try makeEngine()
        let sim = try engine.createPoolSim(slot: 1, now: harness.clock.now())
        var protectedID: Int64?
        try engine.recyclePoolSim(sim, reason: "test recycle", now: harness.clock.now()) { body in
            let intent = try XCTUnwrap(try store.pendingActionIntents().first)
            protectedID = intent.id
            XCTAssertTrue(engine.hostActionIntentsInFlight.contains(intent.id))
            let before = try engine.resolveActionIntents()
            XCTAssertTrue(before.abandoned.isEmpty)
            XCTAssertEqual(try store.pendingActionIntents().map(\.id), [intent.id])
            try body()
            let after = try engine.resolveActionIntents()
            XCTAssertTrue(after.confirmed.isEmpty)
            XCTAssertEqual(try store.pendingActionIntents().map(\.id), [intent.id])
        }
        XCTAssertEqual(harness.sims.deletedUDIDs, [sim.udid])
        XCTAssertTrue(try store.poolSims().isEmpty)
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
        XCTAssertFalse(engine.hostActionIntentsInFlight.contains(try XCTUnwrap(protectedID)))
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "pool_recycled" }.count, 1)
    }

    func testFailedLiveActionRemovesItsInFlightMarkerAndLeavesRecoveryAvailable() throws {
        enum Injected: Error { case failed }
        let (_, store, engine) = try makeEngine()
        let intent = ActionIntent(target: .path("/owned/not-created"), auditType: "test_action", detail: "test")
        XCTAssertThrowsError(
            try engine.performUnderIntent(intent, now: 1) {
                XCTAssertEqual(engine.hostActionIntentsInFlight.count, 1)
                XCTAssertTrue(try engine.resolveActionIntents().confirmed.isEmpty)
                throw Injected.failed
            })
        XCTAssertTrue(engine.hostActionIntentsInFlight.isEmpty)
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "action_intent_abandoned" }.count, 1)
    }
}
