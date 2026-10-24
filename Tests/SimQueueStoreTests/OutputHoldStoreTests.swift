// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import XCTest

@testable import SimQueueStore

private final class ConcurrentHoldStore: @unchecked Sendable {
    let store: JobStore
    private let lock = NSLock()
    private var errorDescription: String?
    init(path: String) throws { store = try JobStore(path: path) }
    func record(_ error: Error) { lock.withLock { errorDescription = String(describing: error) } }
    var failure: String? { lock.withLock { errorDescription } }
}

final class OutputHoldStoreTests: XCTestCase {
    private let id = "01234567-89ab-4cde-8fab-0123456789ab"
    private let secondID = "11234567-89ab-4cde-8fab-0123456789ab"
    private var submission: JobSubmission {
        JobSubmission(project: "output", submitter: "test", dedupeKey: "same", resources: .init(minSims: 0))
    }

    func testMigrationIsAppendOnlyAndMembershipForeignKeysAreRestrictive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sqoh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.sqlite").path
        let old = try Database(path: path)
        try Migrator.migrate(old, migrations: SchemaMigrations.all.filter { $0.version <= 14 })
        XCTAssertThrowsError(try JobStore(readOnlyPath: path))
        XCTAssertEqual(try old.userVersion, 14)
        let store = try JobStore(path: path)
        XCTAssertEqual(try store.database.userVersion, 15)
        XCTAssertTrue(try store.outputHolds().isEmpty)
        try store.createOutputHold(id: id, label: "test", now: 0)
        let job = try store.submitHeld(submission, holdID: id, artifactsRoot: "/fake/jobs", now: 1).job
        XCTAssertThrowsError(try store.database.run("DELETE FROM output_holds WHERE id=?;", [.text(id)]))
        XCTAssertThrowsError(try store.database.run("DELETE FROM jobs WHERE id=?;", [.text(job.id)]))
        XCTAssertThrowsError(try store.database.run("UPDATE output_holds SET released_at=-1 WHERE id=?;", [.text(id)]))
        XCTAssertTrue(try JobStore(readOnlyPath: path).hasActiveOutputHold(jobID: job.id))
    }

    func testIdentityValidationPaginationAndPermanentIdempotentRelease() throws {
        let store = try JobStore(path: ":memory:")
        let hold = try store.createOutputHold(id: id.uppercased(), label: "upload", now: 1)
        XCTAssertEqual(hold.id, id)
        XCTAssertEqual(try store.createOutputHold(id: id, label: "upload", now: 2), hold)
        XCTAssertThrowsError(try store.createOutputHold(id: id, label: "changed", now: 2))
        for invalid in ["", "not-a-uuid", "0123456789ab4cde8fab0123456789ab"] {
            XCTAssertThrowsError(try store.createOutputHold(id: invalid, label: "upload", now: 1))
            XCTAssertThrowsError(try store.outputHold(id: invalid))
            XCTAssertThrowsError(try store.releaseOutputHold(id: invalid, now: 3))
        }
        for label in [
            "", " spaced ", "new\nline", String(repeating: "a", count: 101), String(repeating: "界", count: 100),
        ] {
            XCTAssertThrowsError(try store.createOutputHold(id: secondID, label: label, now: 1))
        }
        XCTAssertThrowsError(try store.createOutputHold(id: secondID, label: "test", now: .infinity))
        XCTAssertThrowsError(try store.releaseOutputHold(id: secondID, now: 3))
        try store.createOutputHold(id: secondID, label: "second", now: 2)
        XCTAssertEqual(try store.outputHolds(limit: 1).map(\.id), [id])
        XCTAssertEqual(try store.outputHolds(afterID: id.uppercased(), limit: 1).map(\.id), [secondID])
        XCTAssertThrowsError(try store.outputHolds(limit: 201))
        XCTAssertThrowsError(try store.outputHoldJobs(id: id, limit: 0))
        let released = try store.releaseOutputHold(id: id, now: 4)
        XCTAssertEqual(try store.releaseOutputHold(id: id.uppercased(), now: 5), released)
        XCTAssertThrowsError(try store.createOutputHold(id: id, label: "upload", now: 6))
        XCTAssertThrowsError(try store.submitHeld(submission, holdID: id, artifactsRoot: "/fake/jobs", now: 6))
        XCTAssertTrue(try store.allJobs().isEmpty)
    }

    func testAtomicSubmissionDedupeMultipleHoldsAndNoTerminalAdoption() throws {
        let store = try JobStore(path: ":memory:")
        XCTAssertThrowsError(try store.submitHeld(submission, holdID: id, artifactsRoot: "/fake/jobs", now: 1))
        XCTAssertTrue(try store.allJobs().isEmpty)
        for id in [id, secondID] { try store.createOutputHold(id: id, label: "upload", now: 0) }
        let created = try store.submitHeld(submission, holdID: id.uppercased(), artifactsRoot: "/fake/jobs", now: 1)
        let deduped = try store.submitHeld(submission, holdID: secondID, artifactsRoot: "/fake/jobs", now: 2)
        XCTAssertEqual(deduped, .deduplicated(created.job))
        _ = try store.submitHeld(submission, holdID: secondID, artifactsRoot: "/fake/jobs", now: 3)
        XCTAssertEqual(try store.auditEntries(jobID: created.job.id, type: "output_hold_attached").count, 2)
        XCTAssertEqual(try store.outputHoldJobs(id: id).map(\.jobID), [created.job.id])
        XCTAssertThrowsError(try store.releaseOutputHold(id: id, now: 4), "queued members block release")
        _ = try store.cancel(jobID: created.job.id, now: 4)
        try store.releaseOutputHold(id: id, now: 5)
        XCTAssertTrue(try store.hasActiveOutputHold(jobID: created.job.id))
        let next = try store.submitHeld(submission, holdID: secondID, artifactsRoot: "/fake/jobs", now: 6).job
        XCTAssertNotEqual(next.id, created.job.id, "terminal history is never adopted")
        XCTAssertEqual(try store.outputHoldJobs(id: secondID, limit: 1).count, 1)
        let first = try XCTUnwrap(store.outputHoldJobs(id: secondID, limit: 1).first)
        XCTAssertEqual(try store.outputHoldJobs(id: secondID, afterJobID: first.jobID, limit: 1).count, 1)
        _ = try store.cancel(jobID: next.id, now: 7)
        try store.releaseOutputHold(id: secondID, now: 8)
        XCTAssertFalse(try store.hasActiveOutputHold(jobID: created.job.id))
    }

    func testMembershipOrAuditFailureRollsBackBothNewJobsAndDedupeAttachments() throws {
        let store = try JobStore(path: ":memory:")
        try store.createOutputHold(id: id, label: "upload", now: 0)
        try store.database.execute(
            """
            CREATE TRIGGER fail_hold_audit BEFORE INSERT ON audit_log WHEN NEW.type='output_hold_attached'
            BEGIN SELECT RAISE(ABORT,'injected'); END;
            """)
        XCTAssertThrowsError(try store.submitHeld(submission, holdID: id, artifactsRoot: "/fake/jobs", now: 1))
        XCTAssertTrue(try store.allJobs().isEmpty)
        XCTAssertTrue(try store.outputHoldJobs(id: id).isEmpty)
        let job = try store.submit(submission, now: 2).job
        XCTAssertThrowsError(try store.submitHeld(submission, holdID: id, artifactsRoot: "/fake/jobs", now: 3))
        XCTAssertFalse(try store.hasActiveOutputHold(jobID: job.id))
        XCTAssertEqual(try store.events(jobID: job.id), ["queued"])
        try store.database.execute("DROP TRIGGER fail_hold_audit;")
        _ = try store.submitHeld(submission, holdID: id, artifactsRoot: "/fake/jobs", now: 4)
        _ = try store.cancel(jobID: job.id, now: 5)
        try store.database.execute(
            """
            CREATE TRIGGER fail_release BEFORE INSERT ON audit_log WHEN NEW.type='output_hold_released'
            BEGIN SELECT RAISE(ABORT,'injected'); END;
            """)
        XCTAssertThrowsError(try store.releaseOutputHold(id: id, now: 6))
        XCTAssertTrue(try store.hasActiveOutputHold(jobID: job.id))
    }

    func testOverlappingRemovalIntentsIncludingRecoveryAndUnlabelledAncestorsRejectAttachment() throws {
        for targetSuffix in ["", "/DerivedData", "/evidence"] {
            let store = try JobStore(path: ":memory:")
            try store.createOutputHold(id: id, label: "upload", now: 0)
            var request = submission
            request.command = JobCommand(argv: ["true"])
            request.command?.artifactsRoot = "/actual/jobs"
            let job = try store.submit(request, now: 1).job
            let path = "/actual/jobs/1970-01-01/" + job.id
            let intent = try store.recordActionIntent(
                ActionIntent(target: .path(path + targetSuffix), auditType: "artifact_removed", detail: "pending"),
                now: 2)
            XCTAssertThrowsError(try store.submitHeld(request, holdID: id, artifactsRoot: "/wrong/jobs", now: 3))
            XCTAssertFalse(try store.hasActiveOutputHold(jobID: job.id))
            try store.abandonActionIntent(intent, reason: "test", now: 4)
            _ = try store.recordActionIntent(
                ActionIntent(target: .path("/actual/jobs/"), auditType: "artifact_removed", detail: "interrupted"),
                now: 4)
            XCTAssertThrowsError(try store.submitHeld(request, holdID: id, artifactsRoot: "/wrong/jobs", now: 5))
            XCTAssertFalse(try store.hasActiveOutputHold(jobID: job.id))
        }
        let store = try JobStore(path: ":memory:")
        try store.createOutputHold(id: id, label: "upload", now: 0)
        _ = try store.recordActionIntent(
            ActionIntent(target: .path("/fake/jobs"), auditType: "artifact_removed", detail: "pending"), now: 0)
        XCTAssertThrowsError(try store.submitHeld(submission, holdID: id, artifactsRoot: "/fake/jobs", now: 1))
        XCTAssertTrue(try store.allJobs().isEmpty, "a newly created job must roll back too")
    }

    func testReleaseRefusesAdmittedRunningUnresolvedProcessesAndPreparationWriters() throws {
        let store = try JobStore(path: ":memory:")
        try store.createOutputHold(id: id, label: "upload", now: 0)
        let job = try store.submitHeld(submission, holdID: id, artifactsRoot: "/fake/jobs", now: 1).job
        let epoch = try store.acquireDaemonLease(ownerID: "test", pid: 1, now: 1)
        _ = try store.claim(jobID: job.id, grantedSims: 0, epoch: epoch, now: 2)
        XCTAssertThrowsError(try store.releaseOutputHold(id: id, now: 3))
        _ = try store.markRunning(jobID: job.id, pid: 123, epoch: epoch, now: 3)
        XCTAssertThrowsError(try store.releaseOutputHold(id: id, now: 4))
        let process = try store.recordSpawnIntent(jobID: job.id, token: "unresolved", epoch: epoch, detail: nil, now: 4)
        _ = try store.finish(jobID: job.id, result: .success, now: 5)
        XCTAssertThrowsError(try store.releaseOutputHold(id: id, now: 6))
        _ = try store.releaseResource(id: process.id, generation: process.generation, now: 7)
        let recoveryIntent = try store.recordActionIntent(
            ActionIntent(
                target: .processGroup(123), auditType: "cleanup_executed", detail: "unresolved",
                resourceID: process.id), now: 7)
        XCTAssertThrowsError(
            try store.releaseOutputHold(id: id, now: 8), "resource-linked recovery intent remains unresolved")
        try store.abandonActionIntent(recoveryIntent, reason: "test", now: 8)
        XCTAssertThrowsError(try store.releaseOutputHold(id: id, writersInFlight: [job.id], now: 8))
        try store.releaseOutputHold(id: id, now: 9)
        XCTAssertFalse(try store.hasActiveOutputHold(jobID: job.id))
        XCTAssertThrowsError(try store.submitHeld(submission, holdID: id, artifactsRoot: "/fake/jobs", now: 10))
    }
    func testConcurrentReleaseAndAttachmentSerializeInBothOrders() throws {
        for releaseWins in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "sqoh-race-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("state.sqlite").path
            let first = try JobStore(path: path)
            let second = try ConcurrentHoldStore(path: path)
            let id = self.id
            let request = submission
            try first.createOutputHold(id: id, label: "evidence", now: 0)
            let entered = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            try first.database.immediateTransaction {
                if releaseWins {
                    try first.releaseOutputHold(id: id, now: 1)
                } else {
                    _ = try first.submitHeld(request, holdID: id, artifactsRoot: "/fake/jobs", now: 1)
                }
                DispatchQueue.global().async {
                    defer { finished.signal() }
                    entered.signal()
                    do {
                        if releaseWins {
                            _ = try second.store.submitHeld(request, holdID: id, artifactsRoot: "/fake/jobs", now: 2)
                        } else {
                            try second.store.releaseOutputHold(id: id, now: 2)
                        }
                    } catch { second.record(error) }
                }
                XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
            }
            XCTAssertEqual(finished.wait(timeout: .now() + 8), .success)
            XCTAssertNotNil(second.failure, "the serialized losing operation must be rejected")
            XCTAssertEqual(try first.allJobs().count, releaseWins ? 0 : 1)
            XCTAssertEqual(try first.outputHold(id: id)?.releasedAt != nil, releaseWins)
        }
    }

    func testProtectedSubmissionRollsBackIfItsOptionalLegacyPinFails() throws {
        let store = try JobStore(path: ":memory:")
        try store.createOutputHold(id: id, label: "evidence", now: 0)
        try store.database.execute(
            """
            CREATE TRIGGER fail_pin BEFORE INSERT ON audit_log WHEN NEW.type='artifact_keep'
            BEGIN SELECT RAISE(ABORT,'injected'); END;
            """)
        XCTAssertThrowsError(
            try store.submitHeld(
                submission, holdID: id, artifactsRoot: "/fake/jobs", keepArtifacts: true, now: 1))
        XCTAssertTrue(try store.allJobs().isEmpty)
        XCTAssertTrue(try store.outputHoldJobs(id: id).isEmpty)
        XCTAssertTrue(try store.auditEntries().filter { $0.type == "output_hold_attached" }.isEmpty)
        try store.database.execute("DROP TRIGGER fail_pin;")
        let job = try store.submitHeld(
            submission, holdID: id, artifactsRoot: "/fake/jobs", keepArtifacts: true, now: 2
        ).job
        _ = try store.cancel(jobID: job.id, now: 3)
        try store.releaseOutputHold(id: id, now: 4)
        XCTAssertEqual(try store.auditEntries(jobID: job.id, type: "artifact_keep").count, 1)
    }

    func testRemovalOverlapUsesTheRegisteredMillisecondRoundedUTCDay() throws {
        let store = try JobStore(path: ":memory:")
        try store.createOutputHold(id: id, label: "evidence", now: 0)
        let job = try store.submit(submission, now: 86_399.9999).job
        _ = try store.recordActionIntent(
            ActionIntent(target: .path("/fake/jobs/1970-01-02"), auditType: "artifact_removed", detail: "pending"),
            now: 86_400)
        XCTAssertThrowsError(try store.submitHeld(submission, holdID: id, artifactsRoot: "/fake/jobs", now: 86_401))
        XCTAssertFalse(try store.hasActiveOutputHold(jobID: job.id))
    }

}
