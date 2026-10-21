// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

/// Write-ahead intents for destructive actions: an action never runs without its intent,
/// and an action whose audit entry couldn't be written is audited by recovery, once.
final class ActionIntentTests: XCTestCase {
    struct DiskIOError: Error {}
    let watchdog = WatchdogConfig()

    private func executed(_ store: JobStore) throws -> [AuditEntry] {
        try store.auditEntries().filter { $0.type == Engine.destructiveAuditType }
    }

    func testADatabaseFailureRightAfterTheActionIsAuditedByTheNextPass() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        harness.sims.setDevices([SimDevice(udid: "LEAK-1", name: "simq-leak", isBooted: false)])
        _ = try engine.watchdogPass(.full, config: watchdog)
        harness.clock.advance(by: 600)

        // The sim is deleted, then the database stops taking writes before the audit entry.
        harness.sims.afterDelete = { _ in store.database.writeFault = DiskIOError() }
        XCTAssertThrowsError(try engine.watchdogPass(.full, config: watchdog))
        harness.sims.afterDelete = nil
        XCTAssertEqual(harness.sims.deletedUDIDs, ["LEAK-1"])
        XCTAssertTrue(try executed(store).isEmpty, "the audit write failed")
        XCTAssertEqual(try store.pendingActionIntents().map(\.target), [.sim(udid: "LEAK-1")])

        store.database.writeFault = nil
        let pass = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertEqual(pass.reconcile.intents.confirmed.map(\.target), [.sim(udid: "LEAK-1")])
        XCTAssertTrue(pass.reconcile.executed.isEmpty, "not acted on twice")
        let audits = try executed(store)
        XCTAssertEqual(audits.count, 1, "audited exactly once")
        XCTAssertEqual(audits.first?.detail, "deleted sim LEAK-1 (confirmed by recovery)")
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
        XCTAssertEqual(harness.sims.deletedUDIDs, ["LEAK-1"])
    }

    func testAnOwnedRowIsReleasedWhenRecoveryConfirmsAfterARestart() throws {
        let path = NSTemporaryDirectory() + "simq-intent-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let harness = Harness(path: path, reliability: ReliabilityConfig(cleanupMode: .enforce))
        var store = try JobStore(path: path, maxQueuedPerSubmitterPerProject: 0)
        var (engine, _, _) = try harness.start(store: store)
        harness.sims.setDevices([SimDevice(udid: "SIM-1", name: "simq-pool-1", isBooted: false)])
        let row = try store.acquireResource(
            kind: .sim, externalID: "SIM-1", owner: .pool, epoch: engine.epoch, now: harness.clock.now())

        // The daemon wrote the intent and deleted the sim, then died before the confirmation.
        try store.recordActionIntent(
            ActionIntent(
                target: .sim(udid: "SIM-1"), auditType: Engine.destructiveAuditType, detail: "deleted sim SIM-1",
                resourceID: row.id, releaseReason: "sim deleted"),
            now: harness.clock.now())
        try harness.sims.deleteDevice(udid: "SIM-1")

        store = try JobStore(path: path, maxQueuedPerSubmitterPerProject: 0)
        let reconcile: ReconcileReport
        (engine, _, reconcile) = try harness.start(store: store)
        XCTAssertEqual(reconcile.intents.confirmed.map(\.resourceID), [row.id])
        XCTAssertEqual(try store.resource(id: row.id)?.state, .released)
        XCTAssertEqual(try executed(store).map(\.resourceID), [row.id])
        XCTAssertFalse(reconcile.actions.contains(.markGone(resourceID: row.id)), "settled before planning")
        _ = engine
    }

    func testAnIntentWhoseTargetIsStillThereIsAbandonedAndCleanedNormallyLater() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let dir = harness.layout.runDir(jobID: "J-left")
        try harness.fileSystem.createDirectory(dir)
        // Died after the intent, before the removal.
        try store.recordActionIntent(
            ActionIntent(target: .path(dir), auditType: Engine.destructiveAuditType, detail: "removed \(dir)"),
            now: harness.clock.now())

        let first = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertEqual(first.reconcile.intents.abandoned.map(\.target), [.path(dir)])
        XCTAssertTrue(harness.fileSystem.fileExists(dir), "recovery never performs an action itself")
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "action_intent_abandoned" }.count, 1)
        XCTAssertTrue(try executed(store).isEmpty)

        harness.clock.advance(by: 3601)  // the work-dir grace
        let later = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertEqual(later.reconcile.executed, [.removeDirectory(path: dir, resourceID: nil)])
        XCTAssertEqual(try executed(store).count, 1)
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
    }

    func testNoIntentNoAction() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        harness.sims.setDevices([SimDevice(udid: "LEAK-1", name: "simq-leak", isBooted: false)])
        _ = try engine.watchdogPass(.full, config: watchdog)
        harness.clock.advance(by: 600)
        // Reads work, writes don't: the intent can't be written, so nothing is deleted.
        store.database.writeFault = DiskIOError()
        XCTAssertThrowsError(try engine.reconcile())
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
        store.database.writeFault = nil
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
    }
}
