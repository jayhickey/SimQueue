// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueDaemon
import SimQueueSim
import SimQueueStore
import XCTest

final class UninstallPoolStateTests: XCTestCase {
    private func fixture() throws -> (JobStore, FakeSimBackend) {
        let store = try JobStore(path: ":memory:")
        _ = try store.acquireDaemonLease(ownerID: "uninstall-test", pid: 1, now: 1)
        let backend = FakeSimBackend()
        for id in ["A", "B", "C"] {
            var sim = PoolSim(udid: id, name: "simq-pool-\(id)", phase: .ready, createdAt: 1)
            sim.clonedFrom = TemplateRef(udid: "old-template", name: nil)
            try store.savePoolSim(sim)
            _ = try store.acquireResource(kind: .sim, externalID: id, owner: .pool, epoch: 1, now: 1)
        }
        backend.setDevices(try store.poolSims().map { SimDevice(udid: $0.udid, name: $0.name, isBooted: true) })
        return (store, backend)
    }

    func testOnlyVerifiedDeletionsRetirePoolAndOwnershipRows() throws {
        let (store, backend) = try fixture()
        backend.deleteFails = ["B"]
        var limits = ReliabilityConfig(cleanupMode: .enforce)
        limits.maxDestructiveActionsPerPass = 2
        let result = try Uninstaller.deleteOwnedSimsAndRecord(
            udids: ["A", "B", "C"], backend: backend, store: store, reliability: limits,
            executedLastHour: 0, force: false, now: 2)
        XCTAssertEqual(result.outcome.deleted, ["A"])
        XCTAssertEqual(result.outcome.rateLimited, ["C"])
        XCTAssertNotNil(result.outcome.failed["B"])
        XCTAssertEqual(try store.poolSims().map(\.udid), ["B", "C"])
        XCTAssertEqual(try store.ownedSimUDIDs(), ["B", "C"])
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "pool_removed_by_uninstall" }.count, 1)
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "cleanup_executed" }.count, 1)
    }

    func testReportOnlyAndUnconfirmedDeletionRetainPoolState() throws {
        let (store, backend) = try fixture()
        let limits = ReliabilityConfig(cleanupMode: .reportOnly)
        let reported = try Uninstaller.deleteOwnedSimsAndRecord(
            udids: ["A"], backend: backend, store: store, reliability: limits,
            executedLastHour: 0, force: false, now: 2)
        XCTAssertEqual(reported.outcome.wouldDelete, ["A"])
        XCTAssertEqual(try store.poolSims().count, 3)
        backend.deleteHasNoEffect = ["A"]
        let unconfirmed = try Uninstaller.deleteOwnedSimsAndRecord(
            udids: ["A"], backend: backend, store: store, reliability: limits,
            executedLastHour: 0, force: true, now: 3)
        XCTAssertTrue(unconfirmed.outcome.deleted.isEmpty)
        XCTAssertNotNil(unconfirmed.outcome.failed["A"])
        XCTAssertEqual(try store.ownedSimUDIDs(), ["A", "B", "C"])
    }

    func testFailedInventoryPreservesRowsForAnExplicitRetry() throws {
        let (store, backend) = try fixture()
        backend.listFailure = .timedOut("inventory unavailable")
        XCTAssertThrowsError(
            try Uninstaller.deleteOwnedSimsAndRecord(
                udids: ["A"], backend: backend, store: store, reliability: ReliabilityConfig(),
                executedLastHour: 0, force: true, now: 2))
        XCTAssertEqual(try store.poolSims().count, 3)
        XCTAssertEqual(try store.ownedSimUDIDs(), ["A", "B", "C"])
        backend.listFailure = nil
        let retried = try Uninstaller.deleteOwnedSimsAndRecord(
            udids: ["A"], backend: backend, store: store, reliability: ReliabilityConfig(),
            executedLastHour: 0, force: true, now: 3)
        XCTAssertEqual(retried.outcome.deleted, ["A"], "already absent is verified on retry")
        XCTAssertEqual(try store.poolSims().map(\.udid), ["B", "C"])
    }

    func testAnOfflineLeaseCannotBeDiscardedEvenWithForce() throws {
        let (store, backend) = try fixture()
        var leased = try XCTUnwrap(try store.poolSims().first)
        leased.phase = .leased
        leased.leaseID = "lease:holder"
        try store.savePoolSim(leased)
        XCTAssertThrowsError(
            try Uninstaller.deleteOwnedSimsAndRecord(
                udids: ["A", "B", "C"], backend: backend, store: store, reliability: ReliabilityConfig(),
                executedLastHour: 0, force: true, now: 2))
        XCTAssertTrue(backend.deletedUDIDs.isEmpty)
        XCTAssertEqual(try store.poolSims().count, 3)
        XCTAssertEqual(try store.ownedSimUDIDs(), ["A", "B", "C"])
    }
}
