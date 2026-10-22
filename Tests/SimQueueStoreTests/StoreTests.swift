// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import XCTest

@testable import SimQueueStore

final class StoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("simq-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var dbPath: String { directory.appendingPathComponent("state.sqlite").path }

    private func submission(
        _ project: String = "app",
        exclusive: Bool = false,
        retryable: Bool = true,
        priority: Int = Priority.defaultValue,
        submitter: String = "bot",
        key: String? = nil,
        resources: ResourceRequest = ResourceRequest(minSims: 1)
    ) -> JobSubmission {
        JobSubmission(
            project: project, priority: priority, submitter: submitter, dedupeKey: key,
            resources: resources, exclusive: exclusive, retryable: retryable)
    }

    private func leasedStore(path: String = ":memory:") throws -> (JobStore, Int64) {
        let store = try JobStore(path: path, maxQueuedPerSubmitterPerProject: 0)
        let epoch = try store.acquireDaemonLease(ownerID: "test", pid: 1, now: 0)
        return (store, epoch)
    }

    // MARK: - Migrations

    func testFileDatabasesUseWALWithFullSync() throws {
        let store = try JobStore(path: dbPath)
        XCTAssertEqual(try store.database.query("PRAGMA journal_mode;").first?.string("journal_mode"), "wal")
        XCTAssertEqual(try store.database.query("PRAGMA synchronous;").first?.int("synchronous"), 2, "FULL")
    }

    func testFreshDatabaseMigratesToLatest() throws {
        let store = try JobStore(path: dbPath)
        XCTAssertEqual(try store.database.userVersion, SchemaMigrations.latestVersion)
        let tables = Set(
            try store.database.query("SELECT name FROM sqlite_master WHERE type = 'table';").compactMap {
                $0.string("name")
            })
        for table in [
            "jobs", "daemon_lease", "queue_control", "audit_log", "owned_resources", "fence_counter",
            "cleanup_sightings", "explanations",
        ] {
            XCTAssertTrue(tables.contains(table), table)
        }
    }

    func testMigrationIsIdempotentAcrossReopen() throws {
        do {
            let store = try JobStore(path: dbPath)
            _ = try store.submit(submission(), now: 1)
        }
        let reopened = try JobStore(path: dbPath)
        XCTAssertEqual(try reopened.allJobs().count, 1)
        XCTAssertEqual(try reopened.database.userVersion, SchemaMigrations.latestVersion)
    }

    func testNewerSchemaIsRefused() throws {
        do {
            let database = try Database(path: dbPath)
            try database.execute("PRAGMA user_version = 99;")
        }
        XCTAssertThrowsError(try JobStore(path: dbPath)) { error in
            XCTAssertEqual(error as? DatabaseError, .schemaTooNew(found: 99, supported: SchemaMigrations.latestVersion))
        }
    }

    func testAppendedMigrationRunsOnceInOrder() throws {
        let database = try Database(path: dbPath)
        let extra =
            SchemaMigrations.all + [
                Migration(version: SchemaMigrations.latestVersion + 1, sql: "CREATE TABLE extra (x INTEGER);")
            ]
        try Migrator.migrate(database, migrations: extra)
        try Migrator.migrate(database, migrations: extra)
        XCTAssertEqual(try database.userVersion, SchemaMigrations.latestVersion + 1)
    }

    func testFailedMigrationRollsBack() throws {
        let database = try Database(path: dbPath)
        let broken =
            SchemaMigrations.all + [
                Migration(version: SchemaMigrations.latestVersion + 1, sql: "CREATE TABLE ok (x); NOT SQL;")
            ]
        XCTAssertThrowsError(try Migrator.migrate(database, migrations: broken))
        XCTAssertEqual(try database.userVersion, SchemaMigrations.latestVersion)
        XCTAssertTrue(try database.query("SELECT name FROM sqlite_master WHERE name = 'ok';").isEmpty)
    }

    func testV1DatabaseUpgradesToIntegerPriorityAndDedupeKey() throws {
        do {
            let database = try Database(path: dbPath)
            try Migrator.migrate(database, migrations: SchemaMigrations.all.filter { $0.version == 1 })
            try database.run(
                """
                INSERT INTO jobs (id, project, kind, priority_class, submitter, request_key, state, queue_time,
                    created_at, min_sims, max_sims, memory_bytes, memory_bytes_per_sim)
                VALUES ('J-0001', 'app', 'label', 'whatever', 'bot', 'k1', 'queued', 1, 1, 0, 0, 0, 0);
                """)
        }
        let store = try JobStore(path: dbPath)
        let job = try XCTUnwrap(store.job(id: "J-0001"))
        XCTAssertEqual(job.priority, Priority.defaultValue)
        XCTAssertEqual(job.dedupeKey, "k1")
        let columns = try store.database.query("PRAGMA table_info(jobs);").compactMap { $0.string("name") }
        XCTAssertFalse(columns.contains("priority_class"))
        XCTAssertFalse(columns.contains("request_key"))
        XCTAssertEqual(try store.submit(submission(key: "k1"), now: 2), .deduplicated(job))
    }

    func testV2RowsGetTheFlagsTheirOldKindImplied() throws {
        // Rows written before kinds became labels: the v3 migration maps each old kind to
        // the flags it used to imply and keeps the text as a label.
        let old: [(kind: String, exclusive: Bool, retryable: Bool)] = [
            ("build", true, true), ("unit-test", false, true), ("ui-test", true, true), ("ui-test-shard", false, true),
            ("screenshots", false, true), ("proof-video", false, false), ("lease", false, false),
            ("script", false, false),
        ]
        do {
            let database = try Database(path: dbPath)
            try Migrator.migrate(database, migrations: SchemaMigrations.all.filter { $0.version <= 2 })
            for (index, row) in old.enumerated() {
                try database.run(
                    """
                    INSERT INTO jobs (id, project, kind, submitter, state, queue_time, created_at, min_sims, max_sims,
                        memory_bytes, memory_bytes_per_sim)
                    VALUES (?, 'app', ?, 'bot', 'queued', 1, 1, 0, 0, 0, 0);
                    """,
                    [.text(String(format: "J-%04d", index + 1)), .text(row.kind)])
            }
        }
        let store = try JobStore(path: dbPath)
        XCTAssertEqual(try store.database.userVersion, SchemaMigrations.latestVersion)
        for (index, row) in old.enumerated() {
            let job = try XCTUnwrap(store.job(id: String(format: "J-%04d", index + 1)))
            XCTAssertEqual(job.kind, row.kind, "the old kind stays as a label")
            XCTAssertEqual(job.exclusive, row.exclusive, row.kind)
            XCTAssertEqual(job.retryable, row.retryable, row.kind)
            XCTAssertNil(job.maxRetries)
        }
    }

    func testOutOfRangePriorityIsRejected() throws {
        let store = try JobStore(path: ":memory:")
        for bad in [-1, 101] {
            XCTAssertThrowsError(try store.submit(submission(priority: bad), now: 1)) { error in
                XCTAssertEqual(error as? JobStoreError, .invalidPriority(bad))
            }
        }
        let job = try store.submit(submission(priority: 0), now: 1).job
        XCTAssertThrowsError(try store.bump(jobID: job.id, to: 500, now: 2))
        XCTAssertEqual(try store.job(id: job.id)?.priority, 0)
    }

    func testFileDatabaseUsesWAL() throws {
        let store = try JobStore(path: dbPath)
        XCTAssertEqual(try store.database.query("PRAGMA journal_mode;").first?.string("journal_mode"), "wal")
    }

    // MARK: - Submit

    func testSubmitAssignsSequentialIDsAndQueueTime() throws {
        let store = try JobStore(path: ":memory:")
        let first = try store.submit(submission(), now: 10).job
        let second = try store.submit(submission("other"), now: 11).job
        XCTAssertEqual(first.id, "J-0001")
        XCTAssertEqual(second.id, "J-0002")
        XCTAssertLessThan(first.sequence, second.sequence)
        XCTAssertEqual(first.queueTime, 10)
        XCTAssertEqual(first.state, .queued)
        XCTAssertEqual(try store.events(jobID: first.id), ["queued"])
    }

    func testDedupeKeyDeduplicatesWhileActiveOnly() throws {
        let (store, epoch) = try leasedStore()
        let first = try store.submit(submission(key: "build-abc123"), now: 1)
        guard case .created(let job) = first else { return XCTFail("expected created") }
        XCTAssertEqual(try store.submit(submission(key: "build-abc123"), now: 2), .deduplicated(job))
        XCTAssertNotNil(try store.claim(jobID: job.id, grantedSims: 1, epoch: epoch, now: 3))
        try store.finish(jobID: job.id, result: .success, now: 4)
        guard case .created(let again) = try store.submit(submission(key: "build-abc123"), now: 5) else {
            return XCTFail("a finished job must not absorb a new request")
        }
        XCTAssertNotEqual(again.id, job.id)
    }

    func testQueueFullPerSubmitterAndProject() throws {
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 2)
        _ = try store.submit(submission(), now: 1)
        _ = try store.submit(submission(), now: 2)
        XCTAssertThrowsError(try store.submit(submission(), now: 3)) { error in
            XCTAssertEqual(error as? JobStoreError, .queueFull(submitter: "bot", project: "app", limit: 2))
        }
        XCTAssertNoThrow(try store.submit(submission(submitter: "other"), now: 3))
        XCTAssertNoThrow(try store.submit(submission("lib"), now: 3))
    }

    // MARK: - Shards

    // MARK: - Claim and fencing

    func testClaimIsFencedByEpochAndIssuesIncreasingTokens() throws {
        let (store, epoch) = try leasedStore()
        let a = try store.submit(submission(), now: 1).job
        let b = try store.submit(submission(), now: 1).job
        XCTAssertNil(try store.claim(jobID: a.id, grantedSims: 1, epoch: epoch - 1, now: 2), "stale epoch")
        let tokenA = try XCTUnwrap(try store.claim(jobID: a.id, grantedSims: 1, epoch: epoch, now: 2))
        XCTAssertNil(try store.claim(jobID: a.id, grantedSims: 1, epoch: epoch, now: 2), "already admitted")
        let tokenB = try XCTUnwrap(try store.claim(jobID: b.id, grantedSims: 1, epoch: epoch, now: 2))
        XCTAssertGreaterThan(tokenB, tokenA)
        let claimed = try XCTUnwrap(try store.job(id: a.id))
        XCTAssertEqual(claimed.state, .admitted)
        XCTAssertEqual(claimed.fenceToken, tokenA)
        XCTAssertEqual(claimed.ownerEpoch, epoch)
        XCTAssertEqual(claimed.admittedAt, 2)
    }

    func testNewDaemonEpochFencesOutOldClaims() throws {
        let (store, oldEpoch) = try leasedStore()
        let job = try store.submit(submission(), now: 1).job
        let newEpoch = try store.acquireDaemonLease(ownerID: "new", pid: 2, now: 2)
        XCTAssertEqual(newEpoch, oldEpoch + 1)
        XCTAssertNil(try store.claim(jobID: job.id, grantedSims: 1, epoch: oldEpoch, now: 3))
        XCTAssertFalse(try store.heartbeat(epoch: oldEpoch, now: 3))
        XCTAssertTrue(try store.heartbeat(epoch: newEpoch, now: 3))
    }

    func testStaleFenceTokenCannotFinishJob() throws {
        let (store, epoch) = try leasedStore()
        let job = try store.submit(submission(retryable: false), now: 1).job
        let token = try XCTUnwrap(try store.claim(jobID: job.id, grantedSims: 1, epoch: epoch, now: 2))
        XCTAssertTrue(try store.isFenceValid(jobID: job.id, token: token))
        XCTAssertFalse(try store.isFenceValid(jobID: job.id, token: token - 1))
        XCTAssertThrowsError(try store.finish(jobID: job.id, result: .success, fenceToken: token - 1, now: 3)) {
            error in
            XCTAssertEqual(error as? JobStoreError, .staleFence(jobID: job.id, presented: token - 1, current: token))
        }
        XCTAssertEqual(try store.job(id: job.id)?.state, .admitted)
        try store.finish(jobID: job.id, result: .success, fenceToken: token, now: 3)
        XCTAssertFalse(try store.isFenceValid(jobID: job.id, token: token), "tokens die with the job")
    }

    func testConcurrentClaimsFromTwoConnectionsAdmitExactlyOnce() throws {
        let setup = try JobStore(path: dbPath, maxQueuedPerSubmitterPerProject: 0)
        let epoch = try setup.acquireDaemonLease(ownerID: "test", pid: 1, now: 0)
        let ids = try (0..<40).map { _ in try setup.submit(submission(), now: 1).job.id }
        let results = ClaimResults()
        let path = dbPath
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            do {
                let store = try JobStore(path: path, maxQueuedPerSubmitterPerProject: 0)
                for id in ids where try store.claim(jobID: id, grantedSims: 1, epoch: epoch, now: 2) != nil {
                    results.win(id)
                }
            } catch {
                results.fail("\(error)")
            }
        }
        XCTAssertEqual(results.errors, [])
        XCTAssertEqual(results.wins.count, ids.count)
        XCTAssertTrue(results.wins.values.allSatisfy { $0 == 1 })
        let tokens = try setup.allJobs().compactMap(\.fenceToken)
        XCTAssertEqual(Set(tokens).count, ids.count, "every grant got a unique token")
    }

    // MARK: - Transitions

    func testMarkRunningRequiresAdmittedAndCurrentEpoch() throws {
        let (store, epoch) = try leasedStore()
        let job = try store.submit(submission(), now: 1).job
        XCTAssertFalse(try store.markRunning(jobID: job.id, pid: 10, epoch: epoch, now: 2))
        _ = try store.claim(jobID: job.id, grantedSims: 1, epoch: epoch, now: 2)
        XCTAssertFalse(try store.markRunning(jobID: job.id, pid: 10, epoch: epoch + 1, now: 3))
        XCTAssertTrue(try store.markRunning(jobID: job.id, pid: 10, epoch: epoch, now: 3))
        let running = try XCTUnwrap(try store.job(id: job.id))
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.ownerPID, 10)
    }

    func testRetryableJobRetriesInfraFailureOnceAtSamePosition() throws {
        let (store, epoch) = try leasedStore()
        let job = try store.submit(submission(), now: 5).job
        _ = try store.claim(jobID: job.id, grantedSims: 1, epoch: epoch, now: 6)
        let retried = try store.finish(jobID: job.id, result: .runnerBootstrapFailure, now: 7)
        XCTAssertEqual(retried.state, .queued)
        XCTAssertEqual(retried.attempt, 1)
        XCTAssertEqual(retried.queueTime, 5)
        XCTAssertEqual(retried.sequence, job.sequence)
        XCTAssertNil(retried.fenceToken)
        XCTAssertEqual(
            try store.allInfraFailureTimes(since: 0), [7], "the retried failure still counts toward the drain")

        _ = try store.claim(jobID: job.id, grantedSims: 1, epoch: epoch, now: 8)
        let final = try store.finish(jobID: job.id, result: .runnerBootstrapFailure, now: 9)
        XCTAssertEqual(final.state, .infraFailed)
        XCTAssertEqual(try store.allInfraFailureTimes(since: 0), [7, 9])
    }

    func testRetryCountIsPerJobAndCoversEveryInfraFailure() throws {
        let (store, epoch) = try leasedStore()
        var sub = submission()
        sub.maxRetries = 3
        let job = try store.submit(sub, now: 1).job
        XCTAssertEqual(job.maxRetries, 3)
        for (attempt, result) in [ResultClass.artifactFailure, .internalError, .runnerBootstrapFailure].enumerated() {
            _ = try store.claim(jobID: job.id, grantedSims: 1, epoch: epoch, now: 2)
            let retried = try store.finish(jobID: job.id, result: result, now: 3)
            XCTAssertEqual(retried.state, .queued, "retry \(attempt + 1) of 3")
            XCTAssertEqual(retried.attempt, attempt + 1)
        }
        _ = try store.claim(jobID: job.id, grantedSims: 1, epoch: epoch, now: 4)
        XCTAssertEqual(try store.finish(jobID: job.id, result: .artifactFailure, now: 5).state, .infraFailed)

        sub.maxRetries = 0
        let none = try store.submit(sub, now: 6).job
        _ = try store.claim(jobID: none.id, grantedSims: 1, epoch: epoch, now: 7)
        XCTAssertEqual(try store.finish(jobID: none.id, result: .artifactFailure, now: 8).state, .infraFailed)
    }

    func testDefaultRetryCountComesFromTheStore() throws {
        let store = try JobStore(path: ":memory:", maxInfraRetries: 2, maxQueuedPerSubmitterPerProject: 0)
        let epoch = try store.acquireDaemonLease(ownerID: "t", pid: 1, now: 0)
        let job = try store.submit(submission(), now: 1).job
        for _ in 0..<2 {
            _ = try store.claim(jobID: job.id, grantedSims: 1, epoch: epoch, now: 2)
            XCTAssertEqual(try store.finish(jobID: job.id, result: .internalError, now: 3).state, .queued)
        }
        _ = try store.claim(jobID: job.id, grantedSims: 1, epoch: epoch, now: 4)
        XCTAssertEqual(try store.finish(jobID: job.id, result: .internalError, now: 5).state, .infraFailed)
    }

    func testKindIsAFreeFormLabelWithNoBehavior() throws {
        let (store, epoch) = try leasedStore()
        var sub = submission(retryable: false)
        sub.kind = "nightly-e2e:ios/v2"
        let job = try store.submit(sub, now: 1).job
        XCTAssertEqual(job.kind, "nightly-e2e:ios/v2")
        XCTAssertFalse(job.exclusive)
        XCTAssertFalse(job.retryable)
        _ = try store.claim(jobID: job.id, grantedSims: 1, epoch: epoch, now: 2)
        XCTAssertEqual(try store.finish(jobID: job.id, result: .runnerBootstrapFailure, now: 3).state, .infraFailed)
        sub.kind = ""
        XCTAssertEqual(try store.submit(sub, now: 4).job.kind, "")
        sub.kind = "Quotify PR #134 · Unit tests"
        XCTAssertEqual(try store.submit(sub, now: 5).job.kind, "Quotify PR #134 · Unit tests", "stored as given")
    }

    func testInvalidKindAndRetryCountAreRejected() throws {
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        for bad in ["new\nline", String(repeating: "k", count: 101), "tab\there", " untrimmed", "   "] {
            var sub = submission()
            sub.kind = bad
            XCTAssertThrowsError(try store.submit(sub, now: 1)) { error in
                XCTAssertEqual(error as? JobStoreError, .invalidKind(bad))
            }
        }
        for bad in [-1, 11] {
            var sub = submission()
            sub.maxRetries = bad
            XCTAssertThrowsError(try store.submit(sub, now: 1)) { error in
                XCTAssertEqual(error as? JobStoreError, .invalidRetries(bad))
            }
        }
    }

    func testFlagsPersistAcrossReopen() throws {
        do {
            let store = try JobStore(path: dbPath)
            var sub = submission(exclusive: true, retryable: true)
            sub.maxRetries = 4
            sub.kind = "label"
            _ = try store.submit(sub, now: 1)
        }
        let job = try XCTUnwrap(try JobStore(path: dbPath).queuedJobs().first)
        XCTAssertEqual(job.kind, "label")
        XCTAssertTrue(job.exclusive)
        XCTAssertTrue(job.retryable)
        XCTAssertEqual(job.maxRetries, 4)
    }

    func testExpireOnlyAffectsQueuedJobs() throws {
        let (store, epoch) = try leasedStore()
        let queued = try store.submit(submission("a"), now: 1).job
        XCTAssertTrue(try store.expire(jobID: queued.id, now: 5))
        let expired = try XCTUnwrap(store.job(id: queued.id))
        XCTAssertEqual(expired.state, .expired)
        XCTAssertEqual(expired.resultClass, .queueTimeout)
        XCTAssertEqual(expired.finishedAt, 5)
        XCTAssertFalse(try store.expire(jobID: queued.id, now: 6), "already terminal")
        let running = try store.submit(submission("b"), now: 1).job
        _ = try store.claim(jobID: running.id, grantedSims: 0, epoch: epoch, now: 2)
        XCTAssertFalse(try store.expire(jobID: running.id, now: 7), "a started job never expires")
    }

    func testTimeoutsArePersistedAndValidated() throws {
        let store = try JobStore(path: ":memory:")
        var sub = submission()
        sub.runTimeoutSeconds = 90
        sub.queueTimeoutSeconds = 600
        let job = try store.submit(sub, now: 1).job
        XCTAssertEqual(job.runTimeoutSeconds, 90)
        XCTAssertEqual(job.queueTimeoutSeconds, 600)
        for bad in [0.0, -5, .infinity, .nan] {
            var invalid = submission("x")
            invalid.queueTimeoutSeconds = bad
            XCTAssertThrowsError(try store.submit(invalid, now: 1), "\(bad)")
        }
    }

    func testTerminationSignalsArePersistedOnceAndFencedByEpoch() throws {
        let (store, epoch) = try leasedStore()
        let job = try store.submit(submission(), now: 1).job
        _ = try store.claim(jobID: job.id, grantedSims: 0, epoch: epoch, now: 2)
        XCTAssertFalse(try store.markTerminationSignal(jobID: job.id, signal: .term, epoch: epoch + 1, now: 3))
        XCTAssertTrue(try store.markTerminationSignal(jobID: job.id, signal: .term, epoch: epoch, now: 3))
        XCTAssertFalse(try store.markTerminationSignal(jobID: job.id, signal: .term, epoch: epoch, now: 4), "once")
        XCTAssertTrue(try store.markTerminationSignal(jobID: job.id, signal: .kill, epoch: epoch, now: 13))
        let stored = try XCTUnwrap(store.job(id: job.id))
        XCTAssertEqual(stored.termSentAt, 3)
        XCTAssertEqual(stored.killSentAt, 13)
        XCTAssertEqual(try store.events(jobID: job.id).suffix(2), ["timeout_sigterm", "timeout_sigkill"])
    }

    func testRecoveryKeepsJobsPastTheirRunDeadlineForTheTimeoutPath() throws {
        let store = try JobStore(path: dbPath)
        let first = try store.acquireDaemonLease(ownerID: "a", pid: 1, now: 0)
        var sub = submission("late")
        sub.runTimeoutSeconds = 60
        let late = try store.submit(sub, now: 0).job
        sub = submission("fine")
        sub.runTimeoutSeconds = 6_000
        let fine = try store.submit(sub, now: 0).job
        for job in [late, fine] {
            _ = try store.claim(jobID: job.id, grantedSims: 0, epoch: first, now: 10)
            _ = try store.markRunning(jobID: job.id, pid: 42, epoch: first, now: 20)
        }
        let second = try store.acquireDaemonLease(ownerID: "b", pid: 2, now: 500)
        let report = try store.recoverAfterRestart(epoch: second, now: 500)
        XCTAssertEqual(report.timeoutPending, [late.id], "deadline 20 + 60 passed while down")
        let kept = try XCTUnwrap(store.job(id: late.id))
        XCTAssertEqual(kept.state, .running)
        XCTAssertEqual(kept.ownerEpoch, second)
        XCTAssertEqual(kept.startedAt, 20, "start time is kept, so the deadline is unchanged")
        XCTAssertEqual(report.requeued, [fine.id])
    }

    func testNonRetryableResultsAreTerminal() throws {
        let (store, epoch) = try leasedStore()
        for (result, state, retryable) in [
            (ResultClass.testFailure, JobState.failed, true), (.success, .succeeded, true),
            (.artifactFailure, .infraFailed, false), (.runnerBootstrapFailure, .infraFailed, false),
            (.runTimeout, .timedOut, true),
        ] {
            let job = try store.submit(submission(retryable: retryable), now: 1).job
            _ = try store.claim(jobID: job.id, grantedSims: 1, epoch: epoch, now: 2)
            let finished = try store.finish(jobID: job.id, result: result, now: 3)
            XCTAssertEqual(finished.state, state)
            XCTAssertEqual(finished.resultClass, result)
            XCTAssertThrowsError(
                try store.finish(jobID: job.id, result: .success, now: 4), "a finished job can't finish again")
        }
    }

    func testCancelAndBump() throws {
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let job = try store.submit(submission(), now: 1).job
        XCTAssertTrue(try store.bump(jobID: job.id, to: 90, now: 2))
        let bumped = try XCTUnwrap(try store.job(id: job.id))
        XCTAssertEqual(bumped.priority, 90)
        XCTAssertEqual(bumped.queueTime, 1)
        XCTAssertTrue(try store.cancel(jobID: job.id, now: 3))
        XCTAssertFalse(try store.cancel(jobID: job.id, now: 4))
        XCTAssertFalse(try store.bump(jobID: job.id, to: 50, now: 5))
        XCTAssertEqual(try store.job(id: job.id)?.state, .canceled)
    }

    // MARK: - Recovery

    func testRecoveryRequeuesEveryJobRetryableOrNot() throws {
        let (store, epoch) = try leasedStore()
        let test = try store.submit(submission(), now: 10).job
        let video = try store.submit(submission(retryable: false), now: 11).job
        let waiting = try store.submit(submission(), now: 12).job
        _ = try store.claim(jobID: test.id, grantedSims: 1, epoch: epoch, now: 13)
        _ = try store.markRunning(jobID: test.id, pid: 4242, epoch: epoch, now: 14)
        _ = try store.claim(jobID: video.id, grantedSims: 1, epoch: epoch, now: 13)

        let newEpoch = try store.acquireDaemonLease(ownerID: "restart", pid: 2, now: 20)
        let report = try store.recoverAfterRestart(epoch: newEpoch, now: 20)
        XCTAssertEqual(report.requeued, [test.id, video.id], "a restart is infra: retryable or not")
        XCTAssertEqual(report.interrupted, [])
        XCTAssertEqual(report.orphanPIDs, [4242])

        for (id, queueTime) in [(test.id, 10.0), (video.id, 11.0)] {
            let requeued = try XCTUnwrap(try store.job(id: id))
            XCTAssertEqual(requeued.state, .queued)
            XCTAssertEqual(requeued.queueTime, queueTime, "keeps its place")
            XCTAssertEqual(requeued.attempt, 1)
            XCTAssertEqual(requeued.restartRequeues, 1)
            XCTAssertNil(requeued.ownerEpoch)
        }
        XCTAssertEqual(try store.job(id: waiting.id)?.state, .queued)
        XCTAssertEqual(try store.job(id: waiting.id)?.restartRequeues, 0)
        XCTAssertEqual(
            try store.recoverAfterRestart(epoch: newEpoch, now: 21), RecoveryReport(), "recovery is idempotent")
    }

    func testRestartRequeuesStopAtTheirCapAndEndInfraFailed() throws {
        let (store, firstEpoch) = try leasedStore()
        let job = try store.submit(submission(retryable: false), now: 10).job
        var epoch = firstEpoch
        for restart in 1...(JobStore.defaultMaxRestartRequeues + 1) {
            _ = try XCTUnwrap(try store.claim(jobID: job.id, grantedSims: 1, epoch: epoch, now: Double(10 + restart)))
            epoch = try store.acquireDaemonLease(ownerID: "restart", pid: 2, now: Double(10 + restart))
            let report = try store.recoverAfterRestart(epoch: epoch, now: Double(10 + restart))
            if restart <= JobStore.defaultMaxRestartRequeues {
                XCTAssertEqual(report.requeued, [job.id], "restart \(restart)")
                XCTAssertEqual(try store.job(id: job.id)?.restartRequeues, restart)
            } else {
                XCTAssertEqual(report.requeued, [])
                XCTAssertEqual(report.restartCapReached, [job.id])
            }
        }
        let ended = try XCTUnwrap(try store.job(id: job.id))
        XCTAssertEqual(ended.state, .infraFailed)
        XCTAssertEqual(ended.resultClass, .internalError)
        XCTAssertTrue(ended.message?.hasPrefix("daemon_restart:") == true, ended.message ?? "")
    }

    func testRestartBeforeClaimCountsOnlyMarkedQueuedJobsAndStopsAtTheCap() throws {
        let (store, firstEpoch) = try leasedStore()
        let bad = try store.submit(submission(retryable: false), now: 10).job
        var other = submission(retryable: false)
        other.submitter = "other"
        let waiting = try store.submit(other, now: 11).job
        var epoch = firstEpoch
        for restart in 1...(JobStore.defaultMaxRestartRequeues + 1) {
            XCTAssertTrue(try store.recordAdmissionAttempt(jobID: bad.id, epoch: epoch, now: Double(11 + restart)))
            XCTAssertEqual(try store.job(id: bad.id)?.state, .queued)
            let oldEpoch = epoch
            epoch = try store.acquireDaemonLease(ownerID: "restart", pid: 2, now: Double(12 + restart))
            XCTAssertFalse(try store.recordAdmissionAttempt(jobID: waiting.id, epoch: oldEpoch, now: 20))
            let report = try store.recoverAfterRestart(epoch: epoch, now: Double(12 + restart))
            if restart <= JobStore.defaultMaxRestartRequeues {
                XCTAssertEqual(report.requeued, [bad.id])
                XCTAssertNil(try store.job(id: bad.id)?.ownerEpoch)
            } else {
                XCTAssertEqual(report.restartCapReached, [bad.id])
            }
            XCTAssertEqual(try store.job(id: waiting.id)?.restartRequeues, 0)
            XCTAssertEqual(try store.recoverAfterRestart(epoch: epoch, now: 30), RecoveryReport())
        }
        XCTAssertEqual(try store.job(id: bad.id)?.state, .infraFailed)
        XCTAssertEqual(try store.job(id: bad.id)?.resultClass, .internalError)
        XCTAssertEqual(try store.job(id: waiting.id)?.state, .queued)
    }

    func testRestartRequeuesNeverUseUpInfraRetries() throws {
        let (store, firstEpoch) = try leasedStore()
        let job = try store.submit(submission(), now: 10).job  // retryable, default 1 infra retry
        _ = try store.claim(jobID: job.id, grantedSims: 1, epoch: firstEpoch, now: 11)
        let epoch = try store.acquireDaemonLease(ownerID: "restart", pid: 2, now: 12)
        _ = try store.recoverAfterRestart(epoch: epoch, now: 12)
        XCTAssertEqual(try store.job(id: job.id)?.attempt, 1)

        _ = try store.claim(jobID: job.id, grantedSims: 1, epoch: epoch, now: 13)
        let retried = try store.finish(jobID: job.id, result: .runnerBootstrapFailure, now: 14)
        XCTAssertEqual(retried.state, .queued, "its one infra retry is still there after a restart requeue")
        XCTAssertEqual(retried.attempt, 2)

        _ = try store.claim(jobID: job.id, grantedSims: 1, epoch: epoch, now: 15)
        XCTAssertEqual(try store.finish(jobID: job.id, result: .runnerBootstrapFailure, now: 16).state, .infraFailed)
    }

    // MARK: - Queue control and explanations

    func testPauseResumeAndDrainClear() throws {
        let store = try JobStore(path: ":memory:")
        XCTAssertEqual(try store.queueControl(), QueueControl())
        try store.setPaused(true)
        XCTAssertTrue(try store.queueControl().paused)
        try store.resume(now: 50)
        XCTAssertEqual(try store.queueControl(), QueueControl(paused: false, drainClearedAt: 50))
    }

    func testExplanationsReplaceEachPass() throws {
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let a = try store.submit(submission(), now: 1).job
        let b = try store.submit(submission(), now: 1).job
        try store.saveExplanations(
            [
                QueueExplanation(
                    jobID: a.id, position: 1, effectiveScore: 50,
                    reasons: [.bootCapacity(bootsNeeded: 1, inProgress: 1, max: 1)]),
                QueueExplanation(
                    jobID: b.id, position: 2, effectiveScore: 50, reasons: [.reservedForHigherPriority(jobID: a.id)]),
            ],
            at: 2
        )
        XCTAssertEqual(try store.explanation(jobID: b.id)?.reasons, [.reservedForHigherPriority(jobID: a.id)])
        try store.saveExplanations(
            [QueueExplanation(jobID: a.id, position: 1, effectiveScore: 51, reasons: [.paused])], at: 3)
        XCTAssertNil(try store.explanation(jobID: b.id))
        XCTAssertEqual(try store.explanation(jobID: a.id)?.reasons, [.paused])
    }
}

private final class ClaimResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var wins: [String: Int] = [:]
    private(set) var errors: [String] = []

    func win(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        wins[id, default: 0] += 1
    }

    func fail(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        errors.append(message)
    }
}

final class CommandStoreTests: XCTestCase {
    private func makeStore() throws -> (JobStore, String) {
        let path = NSTemporaryDirectory() + "simq-cmd-\(UUID().uuidString).sqlite"
        return (try JobStore(path: path), path)
    }

    func testInvalidCommandsAreRejected() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        for command in [
            JobCommand(argv: []), JobCommand(argv: [""]), JobCommand(argv: ["x"], environment: ["SIMQ_X": "1"]),
            JobCommand(argv: ["x"], environment: ["BAD NAME": "1"]), JobCommand(argv: ["a\u{0}b"]),
            JobCommand(argv: ["x"], cwd: "relative"),
        ] {
            XCTAssertThrowsError(
                try store.submit(JobSubmission(project: "app", submitter: "dev", command: command), now: 1)
            ) { error in
                guard case JobStoreError.invalidCommand = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testFinishAndLateExitRecordTheCommandStatus() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let epoch = try store.acquireDaemonLease(ownerID: "t", pid: 1, now: 0)
        let command = JobCommand(argv: ["x"])
        let first = try store.submit(JobSubmission(project: "app", submitter: "a", command: command), now: 1).job
        let second = try store.submit(JobSubmission(project: "app", submitter: "b", command: command), now: 1).job
        for job in [first, second] {
            _ = try store.claim(jobID: job.id, grantedSims: 0, epoch: epoch, now: 2)
            _ = try store.markRunning(jobID: job.id, pid: 4242, epoch: epoch, now: 3)
        }
        let failed = try store.finish(jobID: first.id, result: .commandFailure, commandExitCode: 3, now: 4)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.commandExitCode, 3)

        XCTAssertTrue(try store.cancel(jobID: second.id, now: 4))
        try store.recordCommandExit(jobID: second.id, code: 143, now: 5)
        try store.recordCommandExit(jobID: second.id, code: 1, now: 6)
        let canceled = try XCTUnwrap(store.job(id: second.id))
        XCTAssertEqual(canceled.state, .canceled, "a late exit never changes the state")
        XCTAssertEqual(canceled.commandExitCode, 143, "the first recorded status wins")
    }

    func testRestartNeverRequeuesAJobWhoseProcessGroupIsStillAlive() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let epoch = try store.acquireDaemonLease(ownerID: "t", pid: 1, now: 0)
        var ids: [String] = []
        for (submitter, pid) in [("a", Int32(5001)), ("b", Int32(5002))] {
            let job = try store.submit(
                JobSubmission(project: "app", submitter: submitter, retryable: true, command: JobCommand(argv: ["x"])),
                now: 1
            ).job
            _ = try store.claim(jobID: job.id, grantedSims: 0, epoch: epoch, now: 2)
            _ = try store.markRunning(jobID: job.id, pid: pid, epoch: epoch, now: 3)
            ids.append(job.id)
        }
        let next = try store.acquireDaemonLease(ownerID: "t2", pid: 2, now: 10)
        let report = try store.recoverAfterRestart(epoch: next, now: 10, liveProcessGroups: [5001])
        XCTAssertEqual(report.stillRunning, [ids[0]])
        XCTAssertEqual(report.interrupted, [ids[0]])
        XCTAssertEqual(report.requeued, [ids[1]], "a retryable job whose group is gone is requeued as before")
        let interrupted = try XCTUnwrap(store.job(id: ids[0]))
        XCTAssertEqual(interrupted.state, .interrupted)
        XCTAssertEqual(interrupted.message, "daemon restarted; process group 5001 was still running and was left alone")
    }

    func testMigrationV4AddsCommandColumnsToExistingRows() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertGreaterThanOrEqual(try store.database.userVersion, 4)
        let old = try store.submit(JobSubmission(project: "app", submitter: "dev"), now: 1).job
        XCTAssertNil(old.command)
        XCTAssertNil(old.commandExitCode)
    }
}
