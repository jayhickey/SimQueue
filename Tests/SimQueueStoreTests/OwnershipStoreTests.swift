// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import XCTest

@testable import SimQueueStore

final class OwnershipStoreTests: XCTestCase {
    private func activeJob() throws -> (JobStore, Int64, Job) {
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let epoch = try store.acquireDaemonLease(ownerID: "test", pid: 1, now: 0)
        let job = try store.submit(
            JobSubmission(project: "app", submitter: "bot", retryable: true), now: 1
        ).job
        _ = try store.claim(jobID: job.id, grantedSims: 1, epoch: epoch, now: 2)
        return (store, epoch, job)
    }

    func testAcquireStampsEpochAndIncreasingGeneration() throws {
        let (store, epoch, job) = try activeJob()
        let jobToken = try XCTUnwrap(try store.job(id: job.id)?.fenceToken)
        let sim = try store.acquireResource(kind: .sim, externalID: "U1", owner: .job(job.id), epoch: epoch, now: 3)
        let pgid = try store.acquireResource(
            kind: .processGroup, externalID: "500", owner: .job(job.id), epoch: epoch, now: 3)
        XCTAssertEqual(sim.epoch, epoch)
        XCTAssertEqual(sim.state, .active)
        XCTAssertGreaterThan(sim.generation, jobToken, "resources and jobs share one fencing counter")
        XCTAssertGreaterThan(pgid.generation, sim.generation)
        XCTAssertEqual(try store.resources(jobID: job.id).map(\.id), [sim.id, pgid.id])
    }

    func testOnlyOneLiveOwnerPerThing() throws {
        let (store, epoch, job) = try activeJob()
        let first = try store.acquireResource(kind: .sim, externalID: "U1", owner: .job(job.id), epoch: epoch, now: 3)
        XCTAssertThrowsError(
            try store.acquireResource(kind: .sim, externalID: "U1", owner: .pool, epoch: epoch, now: 3)
        ) { error in
            XCTAssertEqual(error as? JobStoreError, .alreadyOwned(kind: .sim, externalID: "U1"))
        }
        XCTAssertNoThrow(
            try store.acquireResource(kind: .runDir, externalID: "U1", owner: .pool, epoch: epoch, now: 3),
            "kinds are separate")
        try store.releaseResource(id: first.id, generation: first.generation, now: 4)
        XCTAssertNoThrow(
            try store.acquireResource(kind: .sim, externalID: "U1", owner: .pool, epoch: epoch, now: 5),
            "released rows free the thing")
    }

    func testAcquireIsFencedByEpochAndJobState() throws {
        let (store, epoch, job) = try activeJob()
        XCTAssertThrowsError(
            try store.acquireResource(kind: .sim, externalID: "U1", owner: .pool, epoch: epoch - 1, now: 3)
        ) { error in
            XCTAssertEqual(error as? JobStoreError, .staleEpoch(presented: epoch - 1, current: epoch))
        }
        try store.finish(jobID: job.id, result: .success, now: 3)
        XCTAssertThrowsError(
            try store.acquireResource(kind: .sim, externalID: "U1", owner: .job(job.id), epoch: epoch, now: 4))
        XCTAssertThrowsError(
            try store.acquireResource(kind: .sim, externalID: "U1", owner: .job("J-9999"), epoch: epoch, now: 4))
    }

    func testReleaseRequiresCurrentGeneration() throws {
        let (store, epoch, job) = try activeJob()
        let lease = try store.acquireResource(
            kind: .lease, externalID: job.id, owner: .job(job.id), epoch: epoch, now: 3)
        XCTAssertThrowsError(try store.releaseResource(id: lease.id, generation: lease.generation - 1, now: 4))
        XCTAssertEqual(try store.resource(id: lease.id)?.state, .active)
        XCTAssertTrue(try store.releaseResource(id: lease.id, generation: lease.generation, now: 4))
        XCTAssertFalse(
            try store.releaseResource(id: lease.id, generation: lease.generation, now: 5), "double release is a no-op")
        XCTAssertEqual(try store.resource(id: lease.id)?.releasedAt, 4)
    }

    func testAdoptionIssuesNewGenerationAndEpoch() throws {
        let store = try JobStore(path: ":memory:")
        let first = try store.acquireDaemonLease(ownerID: "a", pid: 1, now: 0)
        let sim = try store.acquireResource(kind: .sim, externalID: "U1", owner: .pool, epoch: first, now: 1)
        let second = try store.acquireDaemonLease(ownerID: "b", pid: 2, now: 2)
        try store.adoptResource(id: sim.id, epoch: second, now: 2)
        let adopted = try XCTUnwrap(try store.resource(id: sim.id))
        XCTAssertEqual(adopted.epoch, second)
        XCTAssertGreaterThan(adopted.generation, sim.generation)
        XCTAssertThrowsError(
            try store.releaseResource(id: sim.id, generation: sim.generation, now: 3), "the old holder is fenced out")
    }

    func testOwnedUDIDsIncludeOrphanedButNotReleased() throws {
        let store = try JobStore(path: ":memory:")
        let epoch = try store.acquireDaemonLease(ownerID: "a", pid: 1, now: 0)
        let b = try store.acquireResource(kind: .sim, externalID: "B", owner: .pool, epoch: epoch, now: 1)
        let a = try store.acquireResource(kind: .sim, externalID: "A", owner: .pool, epoch: epoch, now: 1)
        let c = try store.acquireResource(kind: .sim, externalID: "C", owner: .pool, epoch: epoch, now: 1)
        _ = try store.acquireResource(kind: .runDir, externalID: "/x", owner: .pool, epoch: epoch, now: 1)
        try store.markResourceOrphaned(id: b.id, reason: "test", now: 2)
        try store.releaseResource(id: c.id, generation: c.generation, now: 2)
        XCTAssertEqual(try store.ownedSimUDIDs(), ["A", "B"])
        _ = a
    }

    func testAuditLogIsAppendOnly() throws {
        let (store, _, job) = try activeJob()
        let entries = try store.auditEntries()
        XCTAssertEqual(entries.map(\.type), ["daemon_lease_acquired", "queued", "admitted"])
        XCTAssertEqual(entries.last?.jobID, job.id)
        XCTAssertEqual(entries.last?.epoch, 1)
        XCTAssertThrowsError(try store.database.execute("UPDATE audit_log SET type = 'x';"))
        XCTAssertThrowsError(try store.database.execute("DELETE FROM audit_log;"))
        XCTAssertEqual(try store.auditEntries().count, entries.count)
        XCTAssertEqual(try store.auditEntries(afterSeq: entries[1].seq).map(\.type), ["admitted"])
    }

    func testResourceTransitionsAreAudited() throws {
        let (store, epoch, job) = try activeJob()
        let sim = try store.acquireResource(kind: .sim, externalID: "U1", owner: .job(job.id), epoch: epoch, now: 3)
        try store.markResourceOrphaned(id: sim.id, reason: "owner gone", now: 4)
        try store.markResourceReleased(id: sim.id, reason: "deleted", now: 5)
        let types = try store.auditEntries().filter { $0.resourceID == sim.id }.map(\.type)
        XCTAssertEqual(types, ["resource_acquired", "resource_orphaned", "resource_released"])
    }

    func testSightingsTrackFirstSeenAndResetWhenTargetRecovers() throws {
        let store = try JobStore(path: ":memory:")
        var sightings = try store.syncSightings(["sim:A", "sim:B"], now: 10)
        XCTAssertEqual(sightings["sim:A"]?.firstSeenAt, 10)
        sightings = try store.syncSightings(["sim:A"], now: 20)
        XCTAssertEqual(sightings["sim:A"]?.firstSeenAt, 10, "first-seen survives")
        XCTAssertNil(sightings["sim:B"])
        sightings = try store.syncSightings(["sim:A", "sim:B"], now: 30)
        XCTAssertEqual(sightings["sim:B"]?.firstSeenAt, 30, "a target that came back gets a fresh grace period")
        try store.markSightingReported("sim:A")
        XCTAssertEqual(try store.syncSightings(["sim:A"], now: 40)["sim:A"]?.reported, true)
        XCTAssertEqual(try store.auditCount(type: "cleanup_candidate", since: 0), 3)
    }

    func testLivenessReportForWatchdog() throws {
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let epoch = try store.acquireDaemonLease(ownerID: "a", pid: 77, now: 0)
        var sub = JobSubmission(project: "app", submitter: "bot", retryable: true)
        sub.runTimeoutSeconds = 60
        let job = try store.submit(sub, now: 1).job
        _ = try store.claim(jobID: job.id, grantedSims: 1, epoch: epoch, now: 10)
        _ = try store.markRunning(jobID: job.id, pid: 5, epoch: epoch, now: 15)
        let orphan = try store.acquireResource(kind: .sim, externalID: "U1", owner: .pool, epoch: epoch, now: 10)
        _ = try store.acquireResource(kind: .sim, externalID: "U2", owner: .pool, epoch: epoch, now: 10)
        try store.markResourceOrphaned(id: orphan.id, reason: "test", now: 11)
        try store.heartbeat(epoch: epoch, now: 50)
        let report = try store.livenessReport(now: 80)
        XCTAssertEqual(report.epoch, epoch)
        XCTAssertEqual(report.daemonPID, 77)
        XCTAssertEqual(report.heartbeatAgeSeconds, 30)
        XCTAssertEqual(report.overdueJobs, [job.id])
        XCTAssertEqual(report.orphanedResources, 1)
        XCTAssertEqual(report.activeResources, 1)
    }

    func testSchemaRejectsInconsistentOwnerRows() throws {
        let store = try JobStore(path: ":memory:")
        XCTAssertThrowsError(
            try store.database.execute(
                """
                INSERT INTO owned_resources (kind, external_id, owner_job_id, owner_kind, epoch, generation, state, acquired_at)
                VALUES ('sim', 'U', NULL, 'job', 1, 1, 'active', 0);
                """
            )
        )
        XCTAssertThrowsError(
            try store.database.execute(
                """
                INSERT INTO owned_resources (kind, external_id, owner_job_id, owner_kind, epoch, generation, state, acquired_at)
                VALUES ('sim', 'U', NULL, 'pool', 1, 1, 'bogus', 0);
                """
            )
        )
    }
}
