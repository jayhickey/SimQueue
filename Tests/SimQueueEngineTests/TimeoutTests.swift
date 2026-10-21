// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

final class TimeoutTests: XCTestCase {
    private var dbPath = ""

    override func setUp() {
        dbPath = NSTemporaryDirectory() + "simq-timeout-\(UUID().uuidString).sqlite"
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
    }

    private struct Running {
        let job: Job
        let pgid: Int32
        let simUDID: String
        let runDir: String
    }

    /// Admits a script job with a run timeout and gives it a process group, a clone sim
    /// and a run directory, the way an executor will.
    private func startJob(
        _ harness: Harness, _ store: JobStore, _ engine: Engine, runTimeout: Double = 60, pgid: Int32 = 4242,
        retryable: Bool = false
    ) throws -> Running {
        let job = try harness.submit(store, retryable: retryable, resources: ResourceRequest(), runTimeout: runTimeout)
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        XCTAssertTrue(try store.markRunning(jobID: job.id, pid: pgid, epoch: engine.epoch, now: harness.clock.now()))
        let now = harness.clock.now()
        harness.processes.spawn(pgid)
        _ = try store.acquireResource(
            kind: .processGroup, externalID: "\(pgid)", owner: .job(job.id), epoch: engine.epoch,
            identity: try harness.processes.processIdentity(pgid), now: now)
        let udid = "CLONE-\(job.id)"
        harness.sims.setDevices(
            try harness.sims.listDevices() + [SimDevice(udid: udid, name: "simq-clone-\(job.id)", isBooted: true)])
        _ = try store.acquireResource(kind: .sim, externalID: udid, owner: .job(job.id), epoch: engine.epoch, now: now)
        let dir = harness.layout.runDir(jobID: job.id)
        try harness.fileSystem.createDirectory(dir)
        _ = try store.acquireResource(
            kind: .runDir, externalID: dir, owner: .job(job.id), epoch: engine.epoch, now: now)
        return Running(job: try XCTUnwrap(store.job(id: job.id)), pgid: pgid, simUDID: udid, runDir: dir)
    }

    private func liveRows(_ store: JobStore, _ jobID: String) throws -> [OwnedResource] {
        try store.resources(jobID: jobID).filter { $0.state != .released }
    }

    func testSimulatorFreeTeardownNeverListsDevices() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store, resources: ResourceRequest(minSims: 0))
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        // A broken simulator service must not become a dependency of sims=0 cleanup.
        harness.sims.listFailure = .timedOut("simctl list devices")
        XCTAssertTrue(try engine.teardown(job, now: harness.clock.now()).isEmpty)
    }

    func testTeardownAndWatchdogRetainDependentResourcesForLiveUnverifiableGroups() throws {
        for orphaned in [false, true] {
            let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce, orphanGraceSeconds: 0))
            let store = try JobStore(path: ":memory:")
            let (engine, _, _) = try harness.start(store: store)
            let running = try startJob(harness, store, engine)
            let lease = try store.acquireResource(
                kind: .lease, externalID: "lease-test", owner: .job(running.job.id),
                epoch: engine.epoch, now: harness.clock.now())
            let group = try XCTUnwrap(store.resources(jobID: running.job.id).first { $0.kind == .processGroup })
            harness.processes.leaderExited(running.pgid)
            if orphaned {
                try store.markResourceOrphaned(id: group.id, reason: "unknown child identity", now: harness.clock.now())
            }
            _ = try store.finish(jobID: running.job.id, result: .runTimeout, now: harness.clock.now())
            _ = try engine.teardown(running.job, now: harness.clock.now())
            _ = try engine.reconcile()
            XCTAssertEqual(try store.resource(id: lease.id)?.state, .active)
            XCTAssertTrue(harness.fileSystem.fileExists(running.runDir))
            XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
            XCTAssertTrue(harness.processes.signals.isEmpty)
            harness.processes.exit(running.pgid)
            _ = try engine.reconcile()
            XCTAssertEqual(try store.resource(id: lease.id)?.state, .released)
            XCTAssertTrue(harness.sims.deletedUDIDs.contains(running.simUDID))
            XCTAssertTrue(
                harness.fileSystem.fileExists(running.runDir),
                "work-directory retention still applies after process cleanup")
            harness.clock.advance(by: harness.reliability.ageRules.workDirAfterJobSeconds + 1)
            _ = try engine.reconcile()
            XCTAssertFalse(
                harness.fileSystem.fileExists(running.runDir),
                "dependent cleanup resumes after verified exit and its configured retention")
        }
    }

    // MARK: - Run timeout

    func testRunTimeoutTerminatesTearsDownAndRecordsTimedOut() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let running = try startJob(harness, store, engine)

        harness.clock.advance(by: 59)
        XCTAssertEqual(try engine.tick().timeouts, TimeoutReport(), "not yet")
        harness.clock.advance(by: 1)
        let report = try engine.tick().timeouts
        XCTAssertEqual(report.termSent, [running.job.id])
        XCTAssertEqual(report.timedOut, [running.job.id], "the group exited on SIGTERM, so teardown ran at once")
        XCTAssertEqual(harness.processes.signals.map(\.signal), [.term])
        XCTAssertEqual(harness.sims.deletedUDIDs, [running.simUDID])
        XCTAssertFalse(harness.fileSystem.fileExists(running.runDir))
        let job = try XCTUnwrap(store.job(id: running.job.id))
        XCTAssertEqual(job.state, .timedOut)
        XCTAssertEqual(job.resultClass, .runTimeout)
        XCTAssertEqual(job.termSentAt, harness.clock.now())
        XCTAssertTrue(try liveRows(store, job.id).isEmpty, "every resource released")
        XCTAssertEqual(try store.auditCount(type: Engine.teardownAuditType, since: 0), 2)
        XCTAssertEqual(
            try store.auditCount(type: Engine.destructiveAuditType, since: 0), 0, "teardown isn't orphan cleanup")
    }

    func testJobThatIgnoresSIGTERMIsKilledAfterGrace() throws {
        let harness = Harness()
        harness.timeouts = TimeoutConfig(killGraceSeconds: 10)
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let running = try startJob(harness, store, engine)
        harness.processes.ignoresTerm = [running.pgid]

        harness.clock.advance(by: 60)
        XCTAssertEqual(try engine.tick().timeouts.termSent, [running.job.id])
        XCTAssertEqual(try store.job(id: running.job.id)?.state, .running, "still waiting out the grace period")
        harness.clock.advance(by: 9)
        let early = try engine.tick().timeouts
        XCTAssertTrue(early.killSent.isEmpty)
        XCTAssertTrue(early.timedOut.isEmpty)
        harness.clock.advance(by: 1)
        let report = try engine.tick().timeouts
        XCTAssertEqual(report.killSent, [running.job.id])
        XCTAssertEqual(report.timedOut, [running.job.id])
        XCTAssertEqual(harness.processes.signals.map(\.signal), [.term, .kill])
        let job = try XCTUnwrap(store.job(id: running.job.id))
        XCTAssertEqual(job.state, .timedOut)
        XCTAssertEqual(job.killSentAt, harness.clock.now())
        XCTAssertTrue(try liveRows(store, job.id).isEmpty)
    }

    func testGroupThatSurvivesSIGKILLIsLeftOrphanedAndJobStillTimesOut() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let running = try startJob(harness, store, engine)
        harness.processes.unkillable = [running.pgid]
        harness.clock.advance(by: 60)
        try engine.tick()
        harness.clock.advance(by: 10)
        XCTAssertEqual(try engine.tick().timeouts.killSent, [running.job.id])
        harness.clock.advance(by: 10)
        let report = try engine.tick().timeouts
        XCTAssertEqual(report.timedOut, [running.job.id])
        XCTAssertEqual(try store.job(id: running.job.id)?.state, .timedOut)
        let rows = try liveRows(store, running.job.id)
        XCTAssertEqual(Set(rows.map(\.kind)), [.processGroup, .sim, .runDir])
        XCTAssertEqual(
            rows.first { $0.kind == .processGroup }?.state, .orphaned, "reconcile and the watchdog keep retrying it")
        XCTAssertTrue(harness.fileSystem.fileExists(running.runDir), "live descendants retain their working files")
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty, "a still-used simulator cannot be deleted")
        XCTAssertGreaterThan(try store.auditCount(type: "cleanup_failed", since: 0), 0)
    }

    func testTimeoutDuringCleanupLeavesFailedResourcesOrphanedNeverLoggedAsDone() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let running = try startJob(harness, store, engine)
        // The job is part-way through its own cleanup when the deadline hits: the process
        // has exited, but its sim delete fails and its directory removal silently no-ops.
        harness.processes.exit(running.pgid)
        harness.sims.deleteFails = [running.simUDID]
        harness.fileSystem.removeHasNoEffect = [running.runDir]
        harness.clock.advance(by: 60)
        let report = try engine.tick().timeouts
        XCTAssertEqual(report.timedOut, [running.job.id])
        XCTAssertEqual(report.failures.count, 2)
        XCTAssertEqual(try store.job(id: running.job.id)?.state, .timedOut)
        let orphaned = try liveRows(store, running.job.id)
        XCTAssertEqual(Set(orphaned.map(\.kind)), [.sim, .runDir])
        XCTAssertTrue(orphaned.allSatisfy { $0.state == .orphaned })
        XCTAssertEqual(try store.auditCount(type: Engine.teardownAuditType, since: 0), 0, "nothing logged as done")
        XCTAssertEqual(try store.auditCount(type: "cleanup_failed", since: 0), 2)

        // Reconcile picks them up later under its normal rules (report-only by default).
        harness.sims.deleteFails = []
        harness.fileSystem.removeHasNoEffect = []
        harness.reliability.cleanupMode = .enforce
        let (restarted, _, _) = try harness.start(store: store)
        harness.clock.advance(by: harness.reliability.ageRules.workDirAfterJobSeconds)
        let cleanup = try restarted.reconcile()
        XCTAssertEqual(cleanup.executed.count, 2)
        XCTAssertTrue(try liveRows(store, running.job.id).isEmpty)
    }

    func testDaemonRestartMidJobEnforcesDeadlineFromPersistedStartTime() throws {
        let harness = Harness(path: dbPath)
        var store: JobStore? = try JobStore(path: dbPath, maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store!)
        let running = try startJob(harness, store!, engine, runTimeout: 300)
        let startedAt = try XCTUnwrap(store!.job(id: running.job.id)?.startedAt)
        harness.clock.advance(by: 120)
        try engine.tick()
        store = nil  // daemon dies

        // Down for 10 minutes; the deadline (start + 300 s) passes meanwhile.
        harness.clock.advance(by: 600)
        let reopened = try JobStore(path: dbPath, maxQueuedPerSubmitterPerProject: 0)
        let (second, recovery, reconcile) = try harness.start(store: reopened)
        XCTAssertEqual(recovery.timeoutPending, [running.job.id])
        XCTAssertTrue(recovery.requeued.isEmpty)
        XCTAssertTrue(recovery.interrupted.isEmpty)
        XCTAssertTrue(reconcile.wouldExecute.isEmpty, "reconcile never treats the job's resources as orphans")
        XCTAssertEqual(second.startupTimeouts.termSent, [running.job.id], "enforced at startup, before any tick")
        XCTAssertEqual(second.startupTimeouts.timedOut, [running.job.id])
        XCTAssertEqual(harness.processes.signals.map(\.signal), [.term])
        let job = try XCTUnwrap(reopened.job(id: running.job.id))
        XCTAssertEqual(job.state, .timedOut)
        XCTAssertEqual(job.startedAt, startedAt, "deadline measured from the persisted start")
        XCTAssertTrue(try liveRows(reopened, job.id).isEmpty)
    }

    func testRestartBeforeDeadlineRequeuesExplicitlyRetryableWorkWithoutTimeout() throws {
        let harness = Harness(path: dbPath)
        let store = try JobStore(path: dbPath, maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let running = try startJob(harness, store, engine, runTimeout: 3_600, retryable: true)
        harness.clock.advance(by: 60)
        let (second, recovery, _) = try harness.start(store: store)
        XCTAssertTrue(recovery.timeoutPending.isEmpty)
        XCTAssertTrue(recovery.interrupted.isEmpty)
        XCTAssertEqual(recovery.requeued, [running.job.id])
        XCTAssertEqual(second.startupTimeouts, TimeoutReport())
        let recovered = try XCTUnwrap(store.job(id: running.job.id))
        XCTAssertEqual(recovered.state, .queued)
        XCTAssertEqual(recovered.restartRequeues, 1)
        XCTAssertNil(recovered.termSentAt)
    }

    func testRestartBeforeDeadlineInterruptsNonRetryableWorkWithoutTimeoutOrReplay() throws {
        let harness = Harness(path: dbPath)
        let store = try JobStore(path: dbPath, maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let running = try startJob(harness, store, engine, runTimeout: 3_600)
        harness.clock.advance(by: 60)
        let (second, recovery, _) = try harness.start(store: store)
        XCTAssertTrue(recovery.timeoutPending.isEmpty)
        XCTAssertTrue(recovery.requeued.isEmpty)
        XCTAssertEqual(recovery.interrupted, [running.job.id])
        XCTAssertEqual(second.startupTimeouts, TimeoutReport())
        XCTAssertTrue(try second.tick().admitted.isEmpty, "a started non-retryable command must not be replayed")
        let recovered = try XCTUnwrap(store.job(id: running.job.id))
        XCTAssertEqual(recovered.state, .interrupted)
        XCTAssertEqual(recovered.startedAt, running.job.startedAt)
        XCTAssertEqual(recovered.restartRequeues, 0)
        XCTAssertNil(recovered.termSentAt, "interruption must not be mislabeled as a run timeout")
        XCTAssertTrue(recovered.message?.contains("side effects") == true)
    }

    func testRestartDuringGraceKeepsThePersistedKillSchedule() throws {
        let harness = Harness(path: dbPath)
        harness.timeouts = TimeoutConfig(killGraceSeconds: 10)
        let store = try JobStore(path: dbPath, maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let running = try startJob(harness, store, engine)
        harness.processes.ignoresTerm = [running.pgid]
        harness.clock.advance(by: 60)
        XCTAssertEqual(try engine.tick().timeouts.termSent, [running.job.id])
        let termAt = harness.clock.now()

        harness.clock.advance(by: 4)
        let (second, recovery, _) = try harness.start(store: store)
        XCTAssertEqual(recovery.timeoutPending, [running.job.id])
        XCTAssertEqual(second.startupTimeouts, TimeoutReport())
        let early = try second.tick().timeouts
        XCTAssertTrue(early.termSent.isEmpty, "SIGTERM is not resent after a restart")
        XCTAssertTrue(early.killSent.isEmpty, "grace runs from the persisted SIGTERM time, not the restart")
        harness.clock.advance(by: 6)
        XCTAssertEqual(try second.tick().timeouts.killSent, [running.job.id])
        let job = try XCTUnwrap(store.job(id: running.job.id))
        XCTAssertEqual(job.termSentAt, termAt)
        XCTAssertEqual(job.state, .timedOut)
    }

    func testJobsWithoutRunTimeoutNeverTimeOut() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store, retryable: false, resources: ResourceRequest())
        try engine.tick()
        harness.clock.advance(by: 30 * 24 * 3_600)
        XCTAssertEqual(try engine.tick().timeouts, TimeoutReport())
        XCTAssertEqual(try store.job(id: job.id)?.state, .admitted)
    }

    // MARK: - Queue timeout

    func testQueueTimeoutExpiresUnstartedJobsBeforePlanning() throws {
        let harness = Harness()
        harness.sims.setPool(PoolSnapshot(busyRunning: 4))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let short = try harness.submit(store, queueTimeout: 60)
        let unlimited = try harness.submit(store)
        harness.clock.advance(by: 59)
        XCTAssertTrue(try engine.tick().timeouts.expired.isEmpty)
        harness.clock.advance(by: 1)
        harness.sims.setPool(PoolSnapshot(idleRunning: 1, busyRunning: 3))
        let tick = try engine.tick()
        XCTAssertEqual(tick.timeouts.expired, [short.id])
        XCTAssertEqual(tick.admitted, [unlimited.id], "an expired job is never admitted")
        let expired = try XCTUnwrap(store.job(id: short.id))
        XCTAssertEqual(expired.state, .expired)
        XCTAssertEqual(expired.resultClass, .queueTimeout)
    }

    func testQueueTimeoutPassedWhileDaemonWasDownExpiresOnFirstTick() throws {
        let harness = Harness(path: dbPath)
        harness.sims.setPool(PoolSnapshot(busyRunning: 4))
        let store = try JobStore(path: dbPath, maxQueuedPerSubmitterPerProject: 0)
        _ = try harness.start(store: store)
        let job = try harness.submit(store, queueTimeout: 600)
        harness.clock.advance(by: 3_600)
        let (second, _, _) = try harness.start(store: store)
        XCTAssertEqual(second.startupTimeouts.expired, [job.id], "expired at startup, never admitted")
        XCTAssertEqual(try store.job(id: job.id)?.state, .expired)
    }

    func testJobRequeuedAfterCrashIsNotExpiredForTimeAlreadyWaited() throws {
        let harness = Harness(path: dbPath)
        let store = try JobStore(path: dbPath, maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        harness.sims.setPool(PoolSnapshot(idleRunning: 1))
        let job = try harness.submit(store, queueTimeout: 600)
        harness.clock.advance(by: 500)
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        harness.sims.setPool(PoolSnapshot(busyRunning: 4))
        harness.clock.advance(by: 3_600)  // crash; long outage
        let (second, recovery, _) = try harness.start(store: store)
        XCTAssertEqual(recovery.requeued, [job.id])
        XCTAssertTrue(second.startupTimeouts.expired.isEmpty)
        harness.clock.advance(by: 3_600)
        XCTAssertTrue(try second.tick().timeouts.expired.isEmpty)
        XCTAssertEqual(try store.job(id: job.id)?.state, .queued)
    }

    func testTimeAdmittedCountsTowardNeitherLimit() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(
            store, retryable: false, resources: ResourceRequest(), runTimeout: 60, queueTimeout: 60)
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        harness.clock.advance(by: 600)  // a long sim boot
        XCTAssertEqual(try engine.tick().timeouts, TimeoutReport())
        XCTAssertEqual(try store.job(id: job.id)?.state, .admitted)
        XCTAssertTrue(try store.markRunning(jobID: job.id, pid: 1, epoch: engine.epoch, now: harness.clock.now()))
        harness.clock.advance(by: 59)
        XCTAssertEqual(try engine.tick().timeouts, TimeoutReport())
        harness.clock.advance(by: 1)
        XCTAssertEqual(try engine.tick().timeouts.timedOut, [job.id])
    }
}

final class VerifiedCleanupTests: XCTestCase {
    private func leakedSim(_ harness: Harness) {
        harness.sims.setDevices([SimDevice(udid: "LEAK", name: "simq-clone-leak", isBooted: false)])
    }

    func testDeleteThatSilentlyFailsIsNeverLoggedAsSuccess() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce, orphanGraceSeconds: 0))
        leakedSim(harness)
        harness.sims.deleteHasNoEffect = ["LEAK"]
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        let report = try engine.reconcile()
        XCTAssertTrue(report.executed.isEmpty)
        XCTAssertTrue(report.failures.contains { $0.contains("still exists") })
        XCTAssertEqual(try store.auditCount(type: Engine.destructiveAuditType, since: 0), 0)
        XCTAssertGreaterThan(try store.auditCount(type: "cleanup_failed", since: 0), 0)
    }

    func testDeleteThatThrowsIsNeverLoggedAsSuccess() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce, orphanGraceSeconds: 0))
        leakedSim(harness)
        harness.sims.deleteFails = ["LEAK"]
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        XCTAssertTrue(try engine.reconcile().executed.isEmpty)
        XCTAssertEqual(try store.auditCount(type: Engine.destructiveAuditType, since: 0), 0)
    }

    func testPersistentFailureEscalatesThenClearsAfterTwoCleanPasses() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce, orphanGraceSeconds: 0))
        leakedSim(harness)
        harness.sims.deleteFails = ["LEAK"]
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)  // pass 1 (startup reconcile)
        for _ in 0..<3 {
            harness.clock.advance(by: 60)
            try engine.reconcile()
        }
        XCTAssertEqual(try store.anomalies().map(\.level), [.sustained])
        XCTAssertEqual(try store.auditCount(type: "anomaly_sustained", since: 0), 1)

        harness.clock.advance(by: 86_400)
        try engine.reconcile()
        XCTAssertEqual(try store.anomalies().map(\.level), [.needsHuman])
        XCTAssertEqual(try store.auditCount(type: "anomaly_needs_human", since: 0), 1)

        harness.sims.deleteFails = []
        harness.clock.advance(by: 60)
        try engine.reconcile()  // deletes it: first clean pass
        XCTAssertEqual(try store.anomalies().count, 1, "one clean pass is not enough")
        harness.clock.advance(by: 60)
        let report = try engine.reconcile()
        XCTAssertTrue(report.anomalies.isEmpty)
        XCTAssertEqual(try store.auditCount(type: "anomaly_cleared", since: 0), 1)
    }

    func testReportOnlyLeakEscalatesSoTheShadowWeekSurfacesIt() throws {
        let harness = Harness()
        leakedSim(harness)
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        harness.clock.advance(by: harness.reliability.orphanGraceSeconds)
        for _ in 0..<4 {
            try engine.reconcile()
            harness.clock.advance(by: 60)
        }
        XCTAssertEqual(try store.anomalies().first?.level, .sustained)
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty, "report-only still destroys nothing")
    }
}
