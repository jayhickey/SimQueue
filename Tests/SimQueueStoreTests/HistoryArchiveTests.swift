// SPDX-License-Identifier: MIT
import Foundation
import SimQueueCore
import XCTest

@testable import SimQueueStore

final class HistoryArchiveTests: XCTestCase {
    private var root: URL!
    private var path: String { root.appendingPathComponent("state.sqlite").path }
    private var artifacts: String { root.appendingPathComponent("artifacts").path }
    private let now = 40 * 86_400.0
    private enum Injected: Error { case interrupted }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("simq-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func terminal(_ store: JobStore) throws -> Job {
        let job = try store.submit(JobSubmission(project: "test", submitter: "test"), now: 1).job
        _ = try store.cancel(jobID: job.id, now: 2)
        return try XCTUnwrap(store.job(id: job.id))
    }
    private func archive(keepJobs: Int = 0, keepAudits: Int = 0) throws -> HistoryArchiveResult? {
        try JobStore.archiveHistory(
            path: path, artifactsRoot: artifacts, now: now,
            keepJobs: keepJobs, keepAudits: keepAudits)
    }

    func testSnapshotIsSelfContainedAndRawAuditMutationStillFails() throws {
        let store = try JobStore(path: path)
        let old = try terminal(store)
        let result = try XCTUnwrap(archive())
        XCTAssertEqual(result.jobsRemoved, 1)
        XCTAssertNil(try store.job(id: old.id))
        let snapshot = try Database(path: result.archive, readOnly: true)
        XCTAssertEqual(try snapshot.query("PRAGMA integrity_check;").first?.string("integrity_check"), "ok")
        XCTAssertEqual(try snapshot.query("SELECT COUNT(*) AS n FROM jobs;").first?.int("n"), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.archive + "-wal"))
        XCTAssertThrowsError(try store.database.execute("DELETE FROM audit_log;"))
        XCTAssertThrowsError(try store.database.execute("UPDATE audit_log SET detail='tampered';"))
        _ = try store.submit(JobSubmission(project: "test", submitter: "test"), now: now + 1)
    }

    func testInterruptedBeforePruneKeepsHistoryAndRetryContinues() throws {
        let store = try JobStore(path: path)
        let old = try terminal(store)
        XCTAssertThrowsError(
            try JobStore.archiveHistory(
                path: path, artifactsRoot: artifacts, now: now, keepJobs: 0, keepAudits: 0,
                beforePrune: { throw Injected.interrupted }))
        XCTAssertNotNil(try store.job(id: old.id))
        XCTAssertFalse(try store.auditEntries(jobID: old.id).isEmpty)
        XCTAssertEqual(try XCTUnwrap(archive()).jobsRemoved, 1)
        XCTAssertNil(try store.job(id: old.id))
        XCTAssertEqual(try XCTUnwrap(archive()).jobsRemoved, 0)
        XCTAssertThrowsError(try store.database.execute("DELETE FROM audit_log;"))
    }

    func testInterruptedPruneRollsBackJobsOwnershipAndAudits() throws {
        let store = try JobStore(path: path)
        let job = try terminal(store)
        let auditCount = try store.auditEntries().count
        XCTAssertThrowsError(
            try JobStore.archiveHistory(
                path: path, artifactsRoot: artifacts, now: now, keepJobs: 0, keepAudits: 0,
                duringPrune: { throw Injected.interrupted }))
        XCTAssertNotNil(try store.job(id: job.id))
        XCTAssertEqual(try store.auditEntries().count, auditCount)
        XCTAssertThrowsError(try store.database.execute("DELETE FROM audit_log;"))
        XCTAssertEqual(try XCTUnwrap(archive()).jobsRemoved, 1)
    }

    func testPinsArtifactsIntentsAndActiveOwnershipRemainLive() throws {
        let store = try JobStore(path: path)
        let epoch = try store.acquireDaemonLease(ownerID: "test", pid: 1, now: 0)
        let pinned = try terminal(store)
        try store.audit("artifact_keep", jobID: pinned.id, now: 2)
        let retained = try terminal(store)
        let artifactPath = artifacts + "/1970-01-01/" + retained.id
        try FileManager.default.createDirectory(atPath: artifactPath, withIntermediateDirectories: true)
        let pending = try terminal(store)
        _ = try store.recordActionIntent(
            ActionIntent(
                target: .path("/owned/test"), auditType: "cleanup_executed", detail: "test", jobID: pending.id), now: 3)
        let active = try store.submit(JobSubmission(project: "test", submitter: "test"), now: 4).job
        _ = try store.claim(jobID: active.id, grantedSims: 0, epoch: epoch, now: 5)
        let resource = try store.acquireResource(
            kind: .sim, externalID: "owned", owner: .job(active.id), epoch: epoch, now: 5)
        let removed = try terminal(store)
        XCTAssertEqual(try XCTUnwrap(archive()).jobsRemoved, 1)
        for id in [pinned.id, retained.id, pending.id, active.id] {
            XCTAssertNotNil(try store.job(id: id))
            XCTAssertFalse(try store.auditEntries(jobID: id).isEmpty)
        }
        XCTAssertNil(try store.job(id: removed.id))
        XCTAssertEqual(try store.resource(id: resource.id)?.state, .active)
        XCTAssertEqual(try store.pendingActionIntents().count, 1)
    }

    func testOutcomeWrittenAfterSnapshotIsNotPruned() throws {
        let store = try JobStore(path: path)
        _ = try terminal(store)
        let queued = try store.submit(JobSubmission(project: "test", submitter: "test"), now: 3).job
        let result = try XCTUnwrap(
            JobStore.archiveHistory(
                path: path, artifactsRoot: artifacts, now: now, keepJobs: 0, keepAudits: 0,
                beforePrune: { _ = try store.cancel(jobID: queued.id, now: self.now) }))
        XCTAssertEqual(result.jobsRemoved, 1)
        XCTAssertEqual(try store.job(id: queued.id)?.state, .canceled)
        XCTAssertFalse(try store.auditEntries(jobID: queued.id).isEmpty)
    }

    func testArchiveRotationAndCrashPartialsAreBounded() throws {
        let store = try JobStore(path: path)
        let directory = root.appendingPathComponent("history-archives")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent("history-crashed.sqlite.partial")
        try Data("incomplete".utf8).write(to: stale)
        for _ in 0..<5 {
            _ = try terminal(store)
            XCTAssertThrowsError(
                try JobStore.archiveHistory(
                    path: path, artifactsRoot: artifacts, now: now, keepJobs: 0, keepAudits: 0,
                    beforePrune: { throw Injected.interrupted }))
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertLessThanOrEqual(names.filter { $0.hasSuffix(".sqlite") }.count, 3)
            XCTAssertFalse(names.contains { $0.contains(".partial") })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(try XCTUnwrap(archive()).jobsRemoved, 5)
    }

    func testAuditCountLimitPrunesRecentUnreferencedEventsButNotRetainedJobReferences() throws {
        let store = try JobStore(path: path)
        let retained = try terminal(store)
        for _ in 0..<12 { try store.audit("diagnostic", now: now - 7200) }
        let before = try store.auditEntries(jobID: retained.id)
        let result = try XCTUnwrap(archive(keepJobs: 10, keepAudits: 3))
        XCTAssertGreaterThan(result.auditsRemoved, 0)
        XCTAssertEqual(try store.auditEntries(jobID: retained.id), before)
        XCTAssertLessThanOrEqual(try store.auditEntries().filter { $0.type == "diagnostic" }.count, 3)
    }

    func testLegacyRefusalPrecedesJournalChangesAndMigration() throws {
        do {
            let database = try Database(path: path)
            try Migrator.migrate(database, migrations: SchemaMigrations.all.filter { $0.version <= 13 })
            for (id, parent) in [("parent", SQLValue.null), ("child", .text("parent"))] {
                try database.run(
                    "INSERT INTO jobs(id,project,kind,submitter,state,queue_time,created_at,parent_id) VALUES(?,'test','test','test','queued',1,1,?);",
                    [.text(id), parent])
            }
            _ = try database.query("PRAGMA journal_mode=DELETE;")
        }
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try JobStore(path: path)) { error in
            XCTAssertTrue(String(describing: error).contains("previous SimQueue version"))
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-wal"))
        let readOnly = try Database(path: path, readOnly: true)
        XCTAssertEqual(try readOnly.userVersion, 13)
        XCTAssertEqual(try readOnly.query("PRAGMA journal_mode;").first?.string("journal_mode"), "delete")
    }

    func testCompletedLegacyGroupHistoryEventuallyPrunesWithoutStrandingChildren() throws {
        let store = try JobStore(path: path)
        let parent = try terminal(store)
        let child = try terminal(store)
        try store.database.run("UPDATE jobs SET parent_id=? WHERE id=?;", [.text(parent.id), .text(child.id)])
        XCTAssertEqual(try XCTUnwrap(archive()).jobsRemoved, 1)
        XCTAssertNotNil(try store.job(id: parent.id))
        XCTAssertNil(try store.job(id: child.id))
        XCTAssertEqual(try XCTUnwrap(archive()).jobsRemoved, 1)
        XCTAssertNil(try store.job(id: parent.id))
    }

    func testSnapshotSizeLimitRefusesCopyBeforeCreatingDestinationAndStoragePressureIsActionable() throws {
        let store = try JobStore(path: path)
        _ = try terminal(store)
        let destination = root.appendingPathComponent("oversized.sqlite").path
        XCTAssertThrowsError(try Database.snapshot(source: path, destination: destination, maxBytes: 4096))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
        XCTAssertThrowsError(try store.checkHistoryStoragePressure(limit: 1)) { error in
            XCTAssertTrue(String(describing: error).contains("storage_pressure"))
        }
        // Pressure applies to admission only, never cancellation/recovery writes.
        let job = try store.submit(JobSubmission(project: "test", submitter: "test"), now: now).job
        XCTAssertTrue(try store.cancel(jobID: job.id, now: now + 1))
    }
    func testSnapshotAllowsContinuedWritesBetweenBackupSteps() throws {
        let store = try JobStore(path: path)
        // More than one 100-page backup step, with ordinary job writes interleaved.
        try store.audit("large_diagnostic", detail: String(repeating: "x", count: 1_000_000), now: 1)
        var writes = 0
        let destination = root.appendingPathComponent("concurrent.sqlite").path
        try Database.snapshot(
            source: path, destination: destination,
            afterStep: {
                if writes == 0 {
                    _ = try store.submit(JobSubmission(project: "during-backup", submitter: "test"), now: 2)
                    writes += 1
                }
            })
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(try store.allJobs().count, 1)
        let snapshot = try Database(path: destination, readOnly: true)
        XCTAssertEqual(try snapshot.query("PRAGMA integrity_check;").first?.string("integrity_check"), "ok")
    }

    func testArchivalSQLDeadlineRollsBackAndReleasesWriterForContinuedWork() throws {
        let store = try JobStore(path: path)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(
            try store.database.withStatementDeadline(seconds: 0.02) {
                try store.database.immediateTransaction {
                    try store.audit("must_rollback", now: 1)
                    _ = try store.database.query(
                        "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<10000000) SELECT SUM(x) FROM n;"
                    )
                }
            })
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        XCTAssertTrue(try store.auditEntries().isEmpty)
        _ = try store.submit(JobSubmission(project: "after-deadline", submitter: "test"), now: 2)
        XCTAssertEqual(try store.allJobs().count, 1)
    }

    func testReleasedPoolOwnershipReferencedByRetainedJobAndPathIntentSurvive() throws {
        let store = try JobStore(path: path)
        let epoch = try store.acquireDaemonLease(ownerID: "test", pid: 1, now: 0)
        let retained = try terminal(store)
        let resource = try store.acquireResource(
            kind: .sim, externalID: "old-clone", owner: .pool, epoch: epoch, now: 1)
        _ = try store.releaseResource(id: resource.id, generation: resource.generation, now: 2)
        try store.audit("job_lease", jobID: retained.id, resourceID: resource.id, now: 2)
        try store.audit("artifact_keep", jobID: retained.id, now: 2)
        let pending = try terminal(store)
        _ = try terminal(store)
        let artifact = artifacts + "/1970-01-01/" + pending.id
        _ = try store.recordActionIntent(
            ActionIntent(target: .path(artifact), auditType: "artifact_removed", detail: "test"), now: 3)
        let result = try XCTUnwrap(archive(keepJobs: 1))
        XCTAssertEqual(result.jobsRemoved, 1)
        XCTAssertNotNil(try store.job(id: pending.id))
        XCTAssertNotNil(try store.job(id: retained.id))
        XCTAssertNotNil(try store.resource(id: resource.id))
        XCTAssertEqual(try store.pendingActionIntents().count, 1)
    }

    func testRecentCleanupRateLimitAuditsAreNeverRemovedByCountRetention() throws {
        let store = try JobStore(path: path)
        for _ in 0..<12 { try store.audit("cleanup_executed", now: now - 1) }
        _ = try archive(keepJobs: 0, keepAudits: 0)
        XCTAssertEqual(try store.auditCount(type: "cleanup_executed", since: now - 3600), 12)
    }

    func testOnlyOldResolvedHealthHistoryIsPrunedAndCurrentStateIsPreserved() throws {
        let store = try JobStore(path: path)
        let event = AlertEvent(key: "old-resolved", level: .warn, title: "test", detail: "test")
        var resolved = AlertRecord(event: event, now: 1)
        resolved.resolvedAt = 2
        try store.saveAlert(resolved)
        let current = AlertRecord(
            event: AlertEvent(
                key: "active", level: .page, title: "current", detail: "needs inspection", needsHuman: true), now: 1)
        try store.saveAlert(current)
        var recent = AlertRecord(
            event: AlertEvent(key: "recently-resolved", level: .warn, title: "test", detail: "test"), now: 1)
        recent.resolvedAt = now - 1
        try store.saveAlert(recent)
        _ = try XCTUnwrap(archive(keepJobs: 10, keepAudits: 10))
        XCTAssertNil(try store.alert(key: resolved.key))
        XCTAssertEqual(try store.alert(key: current.key), current)
        XCTAssertEqual(try store.alert(key: recent.key), recent)
        XCTAssertTrue(try store.anomalies().isEmpty)
    }

    func testOutputHoldWithoutArtifactsSurvivesReopenAndReleaseAfterSnapshotDefersPruning() throws {
        let id = "01234567-89ab-4cde-8fab-0123456789ab"
        let store = try JobStore(path: path)
        try store.createOutputHold(id: id, label: "evidence", now: 0)
        let held = try store.submitHeld(
            JobSubmission(project: "test", submitter: "test"), holdID: id, artifactsRoot: artifacts, now: 1
        ).job
        _ = try store.cancel(jobID: held.id, now: 2)
        XCTAssertTrue(try JobStore(path: path).hasActiveOutputHold(jobID: held.id))
        XCTAssertEqual(try XCTUnwrap(archive()).jobsRemoved, 0)
        let raced = try XCTUnwrap(
            JobStore.archiveHistory(
                path: path, artifactsRoot: artifacts, now: now, keepJobs: 0, keepAudits: 0,
                beforePrune: { try store.releaseOutputHold(id: id, now: 3) }))
        XCTAssertEqual(raced.jobsRemoved, 0, "release/membership state differs from the durable snapshot")
        XCTAssertNotNil(try store.job(id: held.id))
        let pruned = try XCTUnwrap(archive())
        XCTAssertEqual(pruned.jobsRemoved, 1)
        XCTAssertTrue(try store.outputHoldJobs(id: id).isEmpty)
        XCTAssertNotNil(try store.outputHold(id: id)?.releasedAt, "UUID tombstone survives history pruning")
        let saved = try Database(path: pruned.archive, readOnly: true)
        XCTAssertEqual(try saved.query("SELECT COUNT(*) AS n FROM output_hold_jobs;").first?.int("n"), 1)
        XCTAssertThrowsError(try store.createOutputHold(id: id, label: "evidence", now: now))
    }

    func testOutputHoldAttachedAndReleasedAfterSnapshotIsNotLost() throws {
        let store = try JobStore(path: path)
        let queued = try store.submit(JobSubmission(project: "test", submitter: "test", dedupeKey: "same"), now: 1).job
        let id = "01234567-89ab-4cde-8fab-0123456789ab"
        let result = try XCTUnwrap(
            JobStore.archiveHistory(
                path: path, artifactsRoot: artifacts, now: now, keepJobs: 0, keepAudits: 0,
                beforePrune: {
                    try store.createOutputHold(id: id, label: "evidence", now: 2)
                    _ = try store.submitHeld(
                        JobSubmission(project: "test", submitter: "test", dedupeKey: "same"),
                        holdID: id, artifactsRoot: self.artifacts, now: 3)
                    _ = try store.cancel(jobID: queued.id, now: 4)
                    try store.releaseOutputHold(id: id, now: 5)
                }))
        XCTAssertEqual(result.jobsRemoved, 0)
        XCTAssertNotNil(try store.job(id: queued.id))
        XCTAssertEqual(try store.outputHoldJobs(id: id).count, 1)
    }

    func testReleasedHoldHistoryUsesTheRegisteredRoundedDayForArtifactExistence() throws {
        let store = try JobStore(path: path)
        let id = "01234567-89ab-4cde-8fab-0123456789ab"
        try store.createOutputHold(id: id, label: "evidence", now: 0)
        let job = try store.submitHeld(
            JobSubmission(project: "test", submitter: "test"), holdID: id, artifactsRoot: artifacts,
            now: 86_399.9999
        ).job
        _ = try store.cancel(jobID: job.id, now: 86_400)
        try store.releaseOutputHold(id: id, now: 86_401)
        try FileManager.default.createDirectory(
            atPath: artifacts + "/1970-01-02/" + job.id, withIntermediateDirectories: true)
        XCTAssertEqual(try XCTUnwrap(archive()).jobsRemoved, 0)
        XCTAssertNotNil(try store.job(id: job.id))
        XCTAssertEqual(try store.outputHoldJobs(id: id).count, 1)
    }

}
