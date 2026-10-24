// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueEngine
import SimQueueProtocol
import SimQueueStore
import XCTest

final class OutputHoldRetentionTests: XCTestCase {
    private let id = "01234567-89ab-4cde-8fab-0123456789ab"

    func testWholeAgeDerivedDataBudgetAndExpiredPinsAreVetoedUntilExplicitRelease() throws {
        for pinned in [false, true] {
            var reliability = ReliabilityConfig(cleanupMode: .enforce)
            reliability.ageRules.artifactRetention.budgetBytes = 1
            let harness = Harness(reliability: reliability)
            harness.artifactsRoot = "/fake/jobs"
            let store = try JobStore(path: ":memory:")
            let (engine, _, _) = try harness.start(store: store)
            try store.createOutputHold(id: id, label: "evidence", now: harness.clock.now())
            let job = try store.submitHeld(
                JobSubmission(project: "test", submitter: "test"), holdID: id, artifactsRoot: "/fake/jobs",
                now: harness.clock.now()
            ).job
            _ = try store.cancel(jobID: job.id, now: harness.clock.now())
            if pinned { try store.audit(Engine.artifactKeepAuditType, jobID: job.id, now: harness.clock.now()) }
            let path = JobArtifacts(root: "/fake/jobs").directory(for: job)
            try harness.fileSystem.createDirectory(path + "/DerivedData")
            harness.fileSystem.sizes[path] = 100
            harness.fileSystem.sizes[path + "/DerivedData"] = 80
            for age in [2.0, 15.0, 91.0] {
                harness.clock.advance(by: age * 86_400)
                let now = harness.clock.now()
                let plan = try engine.gcPlan(
                    now: now, inventory: Engine.gcInventory(roots: ["/fake/jobs"], fileSystem: harness.fileSystem),
                    includeStorageAccounting: true)
                XCTAssertTrue(plan.aged.isEmpty)
                XCTAssertEqual(plan.entries.count, 1, "held bytes still count against the total budget")
                XCTAssertFalse(try XCTUnwrap(plan.entries.first).removable)
                XCTAssertEqual(plan.storageEntries.first?.category, "Held")
                XCTAssertTrue(engine.gcCandidates(plan).isEmpty)
                XCTAssertFalse(try engine.stillRemovable(path, now: now), "hold veto precedes expired-pin handling")
                XCTAssertFalse(try engine.stillRemovable(path + "/DerivedData", now: now))
                XCTAssertTrue(try engine.garbageCollect(apply: true, now: now).removed.isEmpty)
                XCTAssertTrue(try engine.watchdogPass(.full, config: WatchdogConfig()).age.artifactsRemoved.isEmpty)
            }
            try store.releaseOutputHold(id: id, now: harness.clock.now())
            XCTAssertTrue(try engine.stillRemovable(path, now: harness.clock.now()))
            XCTAssertEqual(try engine.garbageCollect(apply: true, now: harness.clock.now()).removed, [path])
            XCTAssertEqual(
                try store.auditEntries(jobID: job.id, type: Engine.artifactKeepAuditType).count, pinned ? 1 : 0)
        }
    }

    func testReleaseKeepsOriginalAgeAndDoesNotClearALegacyPin() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        harness.artifactsRoot = "/fake/jobs"
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        try store.createOutputHold(id: id, label: "test", now: harness.clock.now())
        let job = try store.submitHeld(
            JobSubmission(project: "test", submitter: "test"), holdID: id, artifactsRoot: "/fake/jobs",
            now: harness.clock.now()
        ).job
        _ = try store.cancel(jobID: job.id, now: harness.clock.now())
        let finished = try store.job(id: job.id)?.finishedAt
        try store.audit(Engine.artifactKeepAuditType, jobID: job.id, now: harness.clock.now())
        let path = JobArtifacts(root: "/fake/jobs").directory(for: job)
        try harness.fileSystem.createDirectory(path + "/DerivedData")
        harness.clock.advance(by: 15 * 86_400)
        try store.releaseOutputHold(id: id, now: harness.clock.now())
        XCTAssertFalse(
            try engine.stillRemovable(path, now: harness.clock.now()), "legacy pin remains within its original 90 days")
        XCTAssertFalse(try engine.stillRemovable(path + "/DerivedData", now: harness.clock.now()))
        XCTAssertEqual(try store.job(id: job.id)?.finishedAt, finished)
        harness.clock.advance(by: 76 * 86_400)
        XCTAssertEqual(try engine.garbageCollect(apply: true, now: harness.clock.now()).removed, [path])
    }

    func testPlanRechecksLiveHoldBeforeApplyAndLookupErrorsFailClosed() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        harness.artifactsRoot = "/fake/jobs"
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        let submission = JobSubmission(project: "test", submitter: "test", dedupeKey: "same")
        let job = try store.submit(submission, now: harness.clock.now()).job
        let path = JobArtifacts(root: "/fake/jobs").directory(for: job)
        try harness.fileSystem.createDirectory(path)
        // A stale candidate cannot become a deletion after a live active-job attachment.
        try store.createOutputHold(id: id, label: "test", now: harness.clock.now())
        _ = try store.submitHeld(submission, holdID: id, artifactsRoot: "/fake/jobs", now: harness.clock.now())
        _ = try store.cancel(jobID: job.id, now: harness.clock.now())
        harness.clock.advance(by: 100 * 86_400)
        XCTAssertNil(try engine.beginArtifactRemoval(path: path, reason: "stale plan", now: harness.clock.now()))
        try store.database.execute("DROP TABLE output_hold_jobs;")
        XCTAssertThrowsError(try engine.stillRemovable(path, now: harness.clock.now()))
        XCTAssertThrowsError(try engine.gcPlan(now: harness.clock.now()))
        XCTAssertTrue(harness.fileSystem.fileExists(path))
    }

    func testHoldsSurviveRetryCancellationAndRestartRecovery() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        try store.createOutputHold(id: id, label: "test", now: harness.clock.now())
        let job = try store.submitHeld(
            JobSubmission(project: "test", submitter: "test", retryable: true, maxRetries: 1),
            holdID: id, artifactsRoot: "/fake/jobs", now: harness.clock.now()
        ).job
        _ = try engine.tick()
        _ = try store.finish(jobID: job.id, result: .runnerBootstrapFailure, now: harness.clock.now())
        XCTAssertTrue(try store.hasActiveOutputHold(jobID: job.id))
        XCTAssertEqual(try store.job(id: job.id)?.state, .queued)
        _ = try engine.tick()
        let (_, recovered, _) = try harness.start(store: store)
        XCTAssertTrue(recovered.requeued.contains(job.id))
        _ = try store.cancel(jobID: job.id, now: harness.clock.now())
        XCTAssertTrue(try store.hasActiveOutputHold(jobID: job.id))
    }
}
