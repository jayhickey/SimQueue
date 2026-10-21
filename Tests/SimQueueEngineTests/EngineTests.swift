// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueProtocol
import SimQueueSim
import SimQueueStore
import XCTest

final class EngineTests: XCTestCase {
    func testCleanupHoldsConcurrencyAndPreventsRetryBesideAnOldProcess() throws {
        let harness = Harness()
        harness.config.maxRunningPerProject = 1
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let first = try harness.submit(store, resources: ResourceRequest(minSims: 0))
        XCTAssertEqual(try engine.tick().admitted, [first.id])
        harness.processes.spawn(951)
        let resource = try store.acquireResource(
            kind: .processGroup, externalID: "951", owner: .job(first.id),
            epoch: engine.epoch, identity: FakeProcessTable.defaultIdentity(951), now: harness.clock.now())
        _ = try store.finish(jobID: first.id, result: .runnerBootstrapFailure, now: harness.clock.now())
        XCTAssertEqual(try store.job(id: first.id)?.state, .queued)
        try store.markResourceOrphaned(id: resource.id, reason: "cleanup pending", now: harness.clock.now())
        let next = try harness.submit(store, resources: ResourceRequest(minSims: 0))
        let held = try engine.tick()
        XCTAssertTrue(held.admitted.isEmpty)
        XCTAssertEqual(held.plan.waiting.first { $0.jobID == first.id }?.reasons.map(\.code), ["cleanup_pending"])
        XCTAssertEqual(held.plan.waiting.first { $0.jobID == next.id }?.reasons.map(\.code), ["project_cap"])
        harness.processes.exit(951)
        XCTAssertEqual(try engine.tick().admitted, [first.id])
    }

    func testFastCompletedAdmissionPacingSurvivesDaemonRestart() throws {
        let harness = Harness()
        harness.config.minAdmissionIntervalSeconds = 1
        harness.config.maxAdmissionsPerPass = 1
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let first = try harness.submit(store, resources: ResourceRequest(minSims: 0))
        let second = try harness.submit(store, resources: ResourceRequest(minSims: 0))
        XCTAssertEqual(try engine.tick().admitted, [first.id])
        _ = try store.finish(jobID: first.id, result: .success, now: harness.clock.now())
        harness.clock.advance(by: 0.25)
        XCTAssertTrue(try engine.tick().admitted.isEmpty)
        let (restarted, _, _) = try harness.start(store: store)
        XCTAssertTrue(try restarted.tick().admitted.isEmpty, "durable admission audit prevents a restart burst")
        harness.clock.advance(by: 0.75)
        XCTAssertEqual(try restarted.tick().admitted, [second.id])
    }

    // MARK: - Tick

    func testTickAdmitsAndExplainsWaiters() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let first = try harness.submit(store)
        let second = try harness.submit(store)
        let result = try engine.tick()
        XCTAssertEqual(result.admitted, [first.id])
        XCTAssertEqual(try store.job(id: first.id)?.state, .admitted)
        XCTAssertNotNil(try store.job(id: first.id)?.fenceToken)
        XCTAssertEqual(try store.explanation(jobID: second.id)?.reasons.map(\.code), ["boot_capacity"])

        // Next tick: the first grant is still pending a boot, so the second keeps waiting.
        harness.clock.advance(by: 5)
        XCTAssertEqual(try engine.tick().admitted, [])
    }

    func testTickRefreshesHeartbeatAndStopsWhenLeaseIsLost() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        harness.clock.advance(by: 30)
        try engine.tick()
        XCTAssertEqual(try store.livenessReport(now: harness.clock.now()).heartbeatAgeSeconds, 0)
        _ = try store.acquireDaemonLease(ownerID: "usurper", pid: 2, now: harness.clock.now())
        XCTAssertThrowsError(try engine.tick()) { error in
            XCTAssertEqual(error as? EngineError, .lostLease(epoch: engine.epoch))
        }
    }

    func testLoadThrottleHysteresisCarriesAcrossTicks() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        _ = try harness.submit(store, retryable: false, resources: ResourceRequest())
        harness.probe.update {
            $0.load1 = 25
            $0.load5 = 31
        }
        XCTAssertTrue(try engine.tick().plan.loadThrottled)
        harness.probe.update { $0.load5 = 25 }
        harness.clock.advance(by: 5)
        let still = try engine.tick()
        XCTAssertTrue(still.plan.loadThrottled, "both averages remain above recovery thresholds")
        XCTAssertTrue(still.admitted.isEmpty)
        harness.probe.update { $0.load5 = 19 }
        harness.clock.advance(by: 5)
        let cleared = try engine.tick()
        XCTAssertFalse(cleared.plan.loadThrottled)
        XCTAssertEqual(cleared.admitted.count, 1)
    }

    func testLoadThrottleStateSurvivesRestart() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        harness.probe.update {
            $0.load1 = 25
            $0.load5 = 31
        }
        try engine.tick()
        XCTAssertTrue(try store.loadThrottled())
        // Restart while load5 is between the clear threshold and the trigger.
        harness.probe.update { $0.load5 = 25 }
        harness.clock.advance(by: 5)
        let (restarted, _, _) = try harness.start(store: store)
        XCTAssertTrue(restarted.loadThrottled)
        let job = try harness.submit(store, retryable: false, resources: ResourceRequest())
        XCTAssertTrue(try restarted.tick().admitted.isEmpty, "hysteresis is not lost on restart")
        harness.probe.update {
            $0.load1 = 20
            $0.load5 = 40.55
        }
        harness.clock.advance(by: 5)
        XCTAssertEqual(try restarted.tick().admitted, [job.id])
        XCTAssertFalse(try store.loadThrottled())
        harness.clock.advance(by: 5)
        XCTAssertFalse(
            try restarted.tick().plan.loadThrottled, "historical load cannot re-trigger after restart recovery")
        XCTAssertEqual(try store.auditCount(type: "load_throttle_on", since: 0), 1)
        XCTAssertEqual(try store.auditCount(type: "load_throttle_off", since: 0), 1)
    }

    func testSwapGrowthAcrossTicksStopsAdmission() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        try engine.tick()
        let job = try harness.submit(store, retryable: false, resources: ResourceRequest())
        harness.clock.advance(by: 30)
        harness.probe.update { $0.swapUsedBytes = 100 * ByteSize.mebibyte }
        let result = try engine.tick()
        XCTAssertTrue(result.admitted.isEmpty)
        XCTAssertEqual(try store.explanation(jobID: job.id)?.reasons.map(\.code), ["swap_growing"])
    }

    func testInfraFailuresDrainUntilResume() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxInfraRetries: 0, maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        for _ in 0..<3 {
            let job = try harness.submit(store, retryable: false, resources: ResourceRequest())
            XCTAssertEqual(try engine.tick().admitted, [job.id])
            try store.finish(jobID: job.id, result: .runnerBootstrapFailure, now: harness.clock.now())
            harness.clock.advance(by: 10)
        }
        let blocked = try harness.submit(store, retryable: false, resources: ResourceRequest())
        let drained = try engine.tick()
        XCTAssertEqual(drained.drain, .draining(recentInfraFailures: 3))
        XCTAssertTrue(drained.admitted.isEmpty)
        XCTAssertEqual(try store.explanation(jobID: blocked.id)?.reasons.map(\.code), ["draining"])
        try store.resume(now: harness.clock.now())
        harness.clock.advance(by: 1)
        XCTAssertEqual(try engine.tick().admitted, [blocked.id])
    }

    func testHighPriorityJobJumpsAnEqualPriorityQueue() throws {
        let harness = Harness()
        harness.sims.setPool(PoolSnapshot(idleRunning: 1))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        var queued: [Job] = []
        for index in 0..<3 {
            queued.append(try harness.submit(store, exclusive: true, priority: 50, submitter: "dev-\(index)"))
            harness.clock.advance(by: 60)
        }
        let urgent = try harness.submit(store, exclusive: true, priority: 90, submitter: "release")
        XCTAssertEqual(try engine.tick().admitted, [urgent.id])
        let order = try store.queuedJobs().compactMap { try store.explanation(jobID: $0.id) }.sorted {
            $0.position < $1.position
        }
        XCTAssertEqual(order.map(\.jobID), queued.map(\.id), "equal-priority jobs keep FIFO order")
    }

    // MARK: - Restart recovery and reconcile

    func testRestartRequeuesAndReconcilesInReportOnlyMode() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store)
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        // A fake executor sets up the job's resources.
        let runDir = harness.layout.runDir(jobID: job.id)
        try harness.fileSystem.createDirectory(runDir)
        harness.processes.spawn(900)
        harness.sims.setDevices([SimDevice(udid: "U1", name: "simq-pool-1", isBooted: true)])
        for (kind, id) in [(OwnedResourceKind.sim, "U1"), (.processGroup, "900"), (.runDir, runDir)] {
            try store.acquireResource(
                kind: kind, externalID: id, owner: .job(job.id), epoch: engine.epoch,
                identity: kind == .processGroup ? FakeProcessTable.defaultIdentity(900) : nil,
                now: harness.clock.now())
        }

        // Crash and restart. Report-only mode still stops our own verified job group (it's
        // SimQueue's command, not a sim or a directory), so the job can requeue safely.
        harness.clock.advance(by: 60)
        let (restarted, recovery, reconcile) = try harness.start(store: store)
        XCTAssertEqual(restarted.epoch, engine.epoch + 1)
        XCTAssertEqual(recovery.killedProcessGroups, [900])
        XCTAssertEqual(try store.auditCount(type: Engine.restartKillAuditType, since: 0), 1)
        XCTAssertEqual(recovery.requeued, [job.id])
        XCTAssertEqual(reconcile.deferredGrace.count, 2, "nothing else destructive inside the orphan grace period")
        XCTAssertTrue(reconcile.executed.isEmpty)
        XCTAssertEqual(try store.liveResources().map(\.state), [.orphaned, .orphaned])
        XCTAssertEqual(try store.ownedSimUDIDs(), ["U1"], "orphaned sims stay listed as owned until gone")

        // Past every age rule (sim 10 min, work dir 1 h).
        harness.clock.advance(by: 3600)
        let later = try restarted.reconcile()
        XCTAssertEqual(later.wouldExecute.count, 2)
        XCTAssertTrue(later.executed.isEmpty)
        XCTAssertEqual(harness.processes.terminated, [900], "only the restart stop")
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
        XCTAssertTrue(harness.fileSystem.removed.isEmpty)
        XCTAssertEqual(try store.auditCount(type: "cleanup_would_execute", since: 0), 2)
        // Reported once, not on every pass.
        harness.clock.advance(by: 60)
        try restarted.reconcile()
        XCTAssertEqual(try store.auditCount(type: "cleanup_would_execute", since: 0), 2)
    }

    func testEnforceRestartStopsVerifiedGroupSoARetryableJobIsRequeued() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store, resources: ResourceRequest())
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        XCTAssertTrue(try store.markRunning(jobID: job.id, pid: 930, epoch: engine.epoch, now: harness.clock.now()))
        harness.processes.spawn(930)
        try store.acquireResource(
            kind: .processGroup, externalID: "930", owner: .job(job.id), epoch: engine.epoch,
            identity: FakeProcessTable.defaultIdentity(930), now: harness.clock.now())
        harness.clock.advance(by: 60)
        let (_, recovery, _) = try harness.start(store: store)
        XCTAssertEqual(recovery.killedProcessGroups, [930])
        XCTAssertEqual(harness.processes.terminated, [930])
        XCTAssertEqual(recovery.requeued, [job.id], "its group is gone, so it is safe to run again")
        XCTAssertEqual(try store.auditCount(type: Engine.restartKillAuditType, since: 0), 1)
        XCTAssertTrue(try store.liveResources().isEmpty)
    }

    func testRestartLeavesUnverifiableGroupsAloneAndReleasesReusedOnes() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store, resources: ResourceRequest())
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        XCTAssertTrue(try store.markRunning(jobID: job.id, pid: 911, epoch: engine.epoch, now: harness.clock.now()))
        for pgid: Int32 in [910, 911, 912] {
            harness.processes.spawn(pgid)
            try store.acquireResource(
                kind: .processGroup, externalID: "\(pgid)", owner: .job(job.id), epoch: engine.epoch,
                identity: pgid == 912 ? nil : FakeProcessTable.defaultIdentity(pgid), now: harness.clock.now())
        }
        harness.processes.reuse(910, identity: "fake:someone-else")  // pgid reused
        harness.processes.leaderExited(911)  // only other members remain
        // 912: no identity recorded (a row from before identities existed)

        let (_, recovery, _) = try harness.start(store: store)
        XCTAssertEqual(recovery.killedProcessGroups, [])
        XCTAssertTrue(harness.processes.terminated.isEmpty, "nothing unverified is ever signalled")
        XCTAssertEqual(try store.auditCount(type: "restart_kill_skipped", since: 0), 3)
        XCTAssertEqual(recovery.interrupted, [job.id], "live unverified groups: interrupted, as before")
        let rows = try store.resources(jobID: job.id).sorted { $0.externalID < $1.externalID }
        XCTAssertEqual(rows.map(\.state), [.released, .orphaned, .orphaned], "the reused pgid is not ours")
    }

    func testRestartLeavesJobsPastTheirDeadlineToTheTimeoutPath() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store, retryable: false, resources: ResourceRequest(), runTimeout: 30)
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        XCTAssertTrue(try store.markRunning(jobID: job.id, pid: 920, epoch: engine.epoch, now: harness.clock.now()))
        harness.processes.spawn(920)
        try store.acquireResource(
            kind: .processGroup, externalID: "920", owner: .job(job.id), epoch: engine.epoch,
            identity: FakeProcessTable.defaultIdentity(920), now: harness.clock.now())
        harness.clock.advance(by: 120)
        let (_, recovery, _) = try harness.start(store: store)
        XCTAssertEqual(recovery.killedProcessGroups, [], "not a restart kill")
        XCTAssertEqual(try store.auditCount(type: Engine.restartKillAuditType, since: 0), 0)
    }

    func testReconcileStopsLeftoverGroupsOnlyWhenTheLeaderIdentityMatches() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store, resources: ResourceRequest())
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        for pgid: Int32 in [901, 902, 903] {
            harness.processes.spawn(pgid)
            try store.acquireResource(
                kind: .processGroup, externalID: "\(pgid)", owner: .job(job.id), epoch: engine.epoch,
                identity: pgid == 903 ? nil : FakeProcessTable.defaultIdentity(pgid), now: harness.clock.now())
        }
        // The job ends but its groups linger (e.g. a daemonized child).
        _ = try store.finish(jobID: job.id, result: .success, now: harness.clock.now())
        harness.processes.reuse(902, identity: "fake:someone-else")

        let first = try engine.reconcile()
        XCTAssertTrue(first.executed.isEmpty)
        XCTAssertEqual(try store.auditCount(type: "pgid_reused", since: 0), 1)
        XCTAssertEqual(try store.auditCount(type: "cleanup_refused", since: 0), 1)
        harness.clock.advance(by: 600)
        let report = try engine.reconcile()
        XCTAssertEqual(report.executed, [.killProcessGroup(pgid: 901, resourceID: 1)])
        XCTAssertEqual(harness.processes.terminated, [901], "never the reused or unverifiable group")
        XCTAssertTrue(report.failures.contains { $0.contains("903") })
        XCTAssertEqual(try store.auditCount(type: "cleanup_refused", since: 0), 1, "refusal audited once")
        let rows = try store.resources(jobID: job.id).sorted { $0.externalID < $1.externalID }
        XCTAssertEqual(rows.map(\.state), [.released, .released, .orphaned])
    }

    func testEnforceModeCleansUpAfterGraceInSafeOrder() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store, retryable: false)
        _ = try engine.tick()
        let runDir = harness.layout.runDir(jobID: job.id)
        try harness.fileSystem.createDirectory(runDir)
        harness.processes.spawn(900)
        harness.sims.setDevices([SimDevice(udid: "U1", name: "simq-pool-1", isBooted: true)])
        for (kind, id) in [(OwnedResourceKind.runDir, runDir), (.sim, "U1"), (.processGroup, "900")] {
            try store.acquireResource(
                kind: kind, externalID: id, owner: .job(job.id), epoch: engine.epoch,
                identity: kind == .processGroup ? FakeProcessTable.defaultIdentity(900) : nil,
                now: harness.clock.now())
        }
        let (restarted, recovery, first) = try harness.start(store: store)
        XCTAssertEqual(recovery.killedProcessGroups, [900], "our own group is stopped at startup")
        XCTAssertEqual(recovery.requeued, [job.id], "requeued (daemon_restart) though it isn't retryable")
        XCTAssertTrue(first.executed.isEmpty)
        harness.clock.advance(by: 600)
        let report = try restarted.reconcile()
        XCTAssertEqual(report.executed, [.deleteSim(udid: "U1", resourceID: 2)], "sims after the orphan grace")
        XCTAssertTrue(harness.fileSystem.fileExists(runDir), "a work dir is kept 1 h after its job ends")
        harness.clock.advance(by: 3000)
        XCTAssertEqual(try restarted.reconcile().executed, [.removeDirectory(path: runDir, resourceID: 1)])
        XCTAssertEqual(harness.processes.terminated, [900])
        XCTAssertEqual(harness.sims.deletedUDIDs, ["U1"])
        XCTAssertFalse(harness.fileSystem.fileExists(runDir))
        XCTAssertTrue(try store.liveResources().isEmpty)
        XCTAssertEqual(try store.ownedSimUDIDs(), [])
        XCTAssertEqual(try restarted.reconcile().actions, [], "converged")
    }

    func testDestructiveRateLimitsHoldAcrossPassesAndHours() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        harness.sims.setDevices(
            (0..<12).map { SimDevice(udid: String(format: "U%02d", $0), name: "simq-leak-\($0)", isBooted: false) })
        let store = try JobStore(path: ":memory:")
        let (engine, _, startup) = try harness.start(store: store)
        XCTAssertEqual(startup.deferredGrace.count, 12)
        harness.clock.advance(by: 600)
        var executed: [Int] = []
        for _ in 0..<5 {
            executed.append(try engine.reconcile().executed.count)
            harness.clock.advance(by: 60)
        }
        XCTAssertEqual(executed, [3, 3, 3, 1, 0], "3 per pass, 10 per hour")
        harness.clock.advance(by: 3600)
        XCTAssertEqual(try engine.reconcile().executed.count, 2)
        XCTAssertEqual(harness.sims.deletedUDIDs.count, 12)
    }

    func testForeignSimsAreNeverTouchedAndReportedOnce() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        harness.sims.setDevices([SimDevice(udid: "Q1", name: "My Phone Sim", isBooted: true)])
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        harness.clock.advance(by: 3600)
        try engine.reconcile()
        try engine.reconcile()
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
        XCTAssertEqual(try store.auditCount(type: "foreign_sim_seen", since: 0), 1)
    }

    func testCorruptRowCannotDeleteForeignSimOrUnmanagedPath() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        harness.sims.setDevices([SimDevice(udid: "Q1", name: "My Phone Sim", isBooted: true)])
        try harness.fileSystem.createDirectory("/Users/jay/Developer/important")
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        // Bad rows: a job "owns" a foreign sim and a directory outside the managed roots.
        let job = try harness.submit(store, retryable: false, resources: ResourceRequest())
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        let now = harness.clock.now()
        try store.acquireResource(kind: .sim, externalID: "Q1", owner: .job(job.id), epoch: engine.epoch, now: now)
        try store.acquireResource(
            kind: .runDir, externalID: "/Users/jay/Developer/important", owner: .job(job.id), epoch: engine.epoch,
            now: now)
        try store.finish(jobID: job.id, result: .success, now: now)
        harness.clock.advance(by: 3600)
        let report = try engine.reconcile()
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures.first?.contains("refused to delete sim Q1") ?? false)
        XCTAssertTrue(report.executed.isEmpty)
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
        XCTAssertTrue(harness.fileSystem.fileExists("/Users/jay/Developer/important"))
        // The sim row stays orphaned and visible for a human. The directory is outside the
        // managed roots, so it is never even observed: its row is just marked gone.
        XCTAssertEqual(try store.liveResources().map(\.externalID), ["Q1"])
        XCTAssertEqual(try store.liveResources().map(\.state), [.orphaned])
        XCTAssertEqual(try store.auditCount(type: "cleanup_refused", since: 0), 1)
        harness.clock.advance(by: 60)
        XCTAssertEqual(try engine.reconcile().failures.count, 1)
        XCTAssertEqual(
            try store.auditCount(type: "cleanup_refused", since: 0), 1, "refusals are audited once, not every pass")
    }

    func testPoolSimsSurviveRestartByAdoption() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        harness.sims.setDevices([SimDevice(udid: "P1", name: "simq-pool-1", isBooted: true)])
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        let row = try store.acquireResource(
            kind: .sim, externalID: "P1", owner: .pool, epoch: engine.epoch, now: harness.clock.now())
        let (restarted, _, report) = try harness.start(store: store)
        XCTAssertEqual(report.actions, [.adopt(resourceID: row.id)])
        XCTAssertEqual(try store.resource(id: row.id)?.epoch, restarted.epoch)
        harness.clock.advance(by: 7200)
        XCTAssertEqual(try restarted.reconcile().actions, [])
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
    }

    func testDoctorOwnershipJSONHasStableOwnedUDIDsField() throws {
        let harness = Harness()
        harness.sims.setDevices([
            SimDevice(udid: "B", name: "simq-pool-2", isBooted: false),
            SimDevice(udid: "A", name: "simq-pool-1", isBooted: false),
        ])
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        for udid in ["B", "A"] {
            try store.acquireResource(
                kind: .sim, externalID: udid, owner: .pool, epoch: engine.epoch, now: harness.clock.now())
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(
            decoding: try encoder.encode(DoctorOwnership(ownedUDIDs: try store.ownedSimUDIDs())), as: UTF8.self)
        XCTAssertEqual(json, #"{"owned_udids":["A","B"],"schema_version":1}"#)
    }
}
