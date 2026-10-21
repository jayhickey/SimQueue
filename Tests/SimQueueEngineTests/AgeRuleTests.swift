// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

/// Artifact retention and current age diagnostics on the fake world.
final class AgeRuleTests: XCTestCase {
    let watchdog = WatchdogConfig()

    private func makeStore() throws -> JobStore {
        try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
    }

    func testAnOwnedProcessGroupWithNoRunningJobIsStoppedAfterTwoMinutes() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store, retryable: false)
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        harness.processes.spawn(900)
        XCTAssertTrue(try store.markRunning(jobID: job.id, pid: 900, epoch: engine.epoch, now: harness.clock.now()))
        let group = try store.acquireResource(
            kind: .processGroup, externalID: "900", owner: .job(job.id), epoch: engine.epoch,
            identity: FakeProcessTable.defaultIdentity(900), now: harness.clock.now())
        _ = try store.finish(jobID: job.id, result: .success, now: harness.clock.now())

        XCTAssertEqual(try engine.watchdogPass(.light, config: watchdog).reconcile.deferredGrace.count, 1)
        harness.clock.advance(by: 119)
        XCTAssertTrue(try engine.watchdogPass(.light, config: watchdog).reconcile.executed.isEmpty)
        harness.clock.advance(by: 1)
        XCTAssertEqual(
            try engine.watchdogPass(.light, config: watchdog).reconcile.executed,
            [.killProcessGroup(pgid: 900, resourceID: group.id)], "2 min, not the 10 min sim grace")
        XCTAssertEqual(harness.processes.terminated, [900])
    }

    func testALeaseOlderThanItsMaxAgeIsRevokedEvenWithALiveHolder() throws {
        let harness = Harness()
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store)
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        let lease = try store.acquireResource(
            kind: .lease, externalID: job.id, owner: .job(job.id), epoch: engine.epoch, now: harness.clock.now())
        harness.clock.advance(by: 2699)
        _ = try engine.watchdogPass(.light, config: watchdog)
        XCTAssertEqual(try store.resource(id: lease.id)?.state, .active)
        harness.clock.advance(by: 1)
        _ = try engine.watchdogPass(.light, config: watchdog)
        XCTAssertEqual(try store.resource(id: lease.id)?.state, .released, "revoked at 2700 s")
        XCTAssertEqual(try store.job(id: job.id)?.state, .admitted, "the job itself is left alone")
    }

    func testAJobQueuedOverSixHoursRaisesOneAlertAndIsNeverCanceled() throws {
        let harness = Harness()
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store)
        harness.clock.advance(by: 6 * 3600 - 1)
        XCTAssertTrue(try engine.watchdogPass(.full, config: watchdog).alerts.isEmpty)
        harness.clock.advance(by: 1)
        let pass = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertEqual(pass.alerts.map(\.key), ["queued:\(job.id)"])
        XCTAssertEqual(pass.alerts.first?.level, .warn)
        XCTAssertEqual(pass.age.longQueuedAlerted, [job.id])
        harness.clock.advance(by: 900)
        XCTAssertTrue(try engine.watchdogPass(.full, config: watchdog).alerts.isEmpty, "raised once per job")
        XCTAssertEqual(try store.alert(key: "queued:\(job.id)")?.count, 1)
        XCTAssertEqual(try store.job(id: job.id)?.state, .queued)
        XCTAssertEqual(try engine.ageFindings(now: harness.clock.now()), ["job \(job.id) queued for 6.3 h"])
    }

    func testJobArtifactsAreKeptByOutcomeAndRemovedOnlyInEnforceMode() throws {
        for mode in [CleanupMode.reportOnly, .enforce] {
            let harness = Harness(reliability: ReliabilityConfig(cleanupMode: mode))
            let root = "/fake/jobs"
            harness.artifactsRoot = root
            let store = try makeStore()
            let (engine, _, _) = try harness.start(store: store)
            let passed = try harness.submit(store)
            XCTAssertEqual(try engine.tick().admitted, [passed.id])
            _ = try store.finish(jobID: passed.id, result: .success, now: harness.clock.now())
            let canceled = try harness.submit(store)
            XCTAssertTrue(try store.cancel(jobID: canceled.id, now: harness.clock.now()))
            let queued = try harness.submit(store)
            let day = "\(root)/2027-01-15"
            let unknown = "\(root)/2020-01-01/J-gone"
            let kept = ["\(day)/\(queued.id)", "\(root)/notes/J-x", "\(day)/.cache", "\(root)/2027-1-1/J-y"]
            for dir in ["\(day)/\(passed.id)", "\(day)/\(canceled.id)", unknown] + kept {
                try harness.fileSystem.createDirectory(dir)
            }

            harness.clock.advance(by: 7 * 86_400)
            let week = try engine.watchdogPass(.full, config: watchdog).age
            if mode == .reportOnly {
                XCTAssertEqual(week.artifactsWouldRemove, [unknown, "\(day)/\(passed.id)"])
                XCTAssertTrue(harness.fileSystem.removed.isEmpty, "report-only removes nothing")
                continue
            }
            XCTAssertEqual(week.artifactsRemoved, [unknown, "\(day)/\(passed.id)"], "unknown 30 d, passed 7 d")
            XCTAssertFalse(harness.fileSystem.fileExists("\(root)/2020-01-01"), "an emptied date dir goes too")
            XCTAssertTrue(harness.fileSystem.fileExists("\(day)/\(canceled.id)"), "other outcomes are kept 14 d")
            harness.clock.advance(by: 7 * 86_400)
            XCTAssertEqual(
                try engine.watchdogPass(.full, config: watchdog).age.artifactsRemoved, ["\(day)/\(canceled.id)"])
            for dir in kept {
                XCTAssertTrue(harness.fileSystem.fileExists(dir), "never touched: \(dir)")
            }
            XCTAssertEqual(try store.auditEntries().filter { $0.type == Engine.artifactRemovedAuditType }.count, 4)
        }
    }

    /// DerivedData goes after `derived_data` (1 day by default), before the rest of the job
    /// directory; a running job's DerivedData is never touched. Report-only reports it.
    func testDerivedDataOfEndedJobsIsRemovedFirstAndNeverForARunningJob() throws {
        for mode in [CleanupMode.reportOnly, .enforce] {
            let harness = Harness(reliability: ReliabilityConfig(cleanupMode: mode))
            let root = "/fake/jobs"
            harness.artifactsRoot = root
            let store = try makeStore()
            let (engine, _, _) = try harness.start(store: store)
            let done = try harness.submit(store, resources: ResourceRequest(minSims: 0))
            let running = try harness.submit(store, resources: ResourceRequest(minSims: 0))
            XCTAssertEqual(try engine.tick().admitted, [done.id, running.id])
            _ = try store.finish(jobID: done.id, result: .success, now: harness.clock.now())
            let day = "\(root)/2027-01-15"
            for dir in ["\(day)/\(done.id)/DerivedData", "\(day)/\(done.id)/shots", "\(day)/\(running.id)/DerivedData"]
            {
                try harness.fileSystem.createDirectory(dir)
            }
            harness.clock.advance(by: 86_400 - 1)
            XCTAssertTrue(try engine.watchdogPass(.full, config: watchdog).age.artifactsWouldRemove.isEmpty)
            harness.clock.advance(by: 1)
            let pass = try engine.watchdogPass(.full, config: watchdog).age
            if mode == .reportOnly {
                XCTAssertEqual(pass.artifactsWouldRemove, ["\(day)/\(done.id)/DerivedData"])
                XCTAssertTrue(harness.fileSystem.removed.isEmpty)
                continue
            }
            XCTAssertEqual(pass.artifactsRemoved, ["\(day)/\(done.id)/DerivedData"])
            XCTAssertTrue(harness.fileSystem.fileExists("\(day)/\(done.id)/shots"), "the results stay")
            XCTAssertTrue(harness.fileSystem.fileExists("\(day)/\(running.id)/DerivedData"), "running: kept")
            let audit = try store.auditEntries().filter { $0.type == Engine.artifactRemovedAuditType }
            XCTAssertEqual(
                audit.compactMap(\.detail), ["removed \(day)/\(done.id)/DerivedData (DerivedData past retention)"])
        }
    }

    func testArtifactRemovalsAreCappedPerPassAndHeldWhileTheBreakerIsOpen() throws {
        var reliability = ReliabilityConfig(cleanupMode: .enforce)
        reliability.ageRules.artifactRetention.maxRemovalsPerPass = 2
        let harness = Harness(reliability: reliability)
        harness.artifactsRoot = "/fake/jobs"
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        let dirs = (1...3).map { "/fake/jobs/2020-01-0\($0)/J-\($0)" }
        for dir in dirs { try harness.fileSystem.createDirectory(dir) }
        var state = try store.watchdogState()
        state.breaker = BreakerState(phase: .open, reason: "test", openedAt: harness.clock.now())
        try store.saveWatchdogState(state, now: harness.clock.now())
        let held = try engine.watchdogPass(.full, config: watchdog).age
        XCTAssertEqual(held.artifactsWouldRemove, dirs, "an open breaker is report-only for retention too")
        XCTAssertTrue(harness.fileSystem.removed.isEmpty)

        state = try store.watchdogState()
        state.breaker = BreakerState()
        try store.saveWatchdogState(state, now: harness.clock.now())
        let pass = try engine.watchdogPass(.full, config: watchdog).age
        XCTAssertEqual(pass.artifactsRemoved, Array(dirs.prefix(2)))
        XCTAssertEqual(pass.artifactsPostponed, [dirs[2]])
        XCTAssertEqual(try engine.watchdogPass(.full, config: watchdog).age.artifactsRemoved, [dirs[2]])
    }

    /// Over `artifact_budget_gib`: the oldest ended run dirs go, succeeded before failed,
    /// until it fits. Never a running job's, never a `--keep` job's.
    func testTheSizeBudgetRemovesOldestSucceededFirstAndNeverPinnedOrRunning() throws {
        var reliability = ReliabilityConfig(cleanupMode: .enforce)
        reliability.ageRules.artifactRetention.budgetBytes = 10
        reliability.ageRules.artifactRetention.maxRemovalsPerPass = 100
        let harness = Harness(reliability: reliability)
        let root = "/fake/jobs"
        harness.artifactsRoot = root
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        func ended(_ result: ResultClass) throws -> Job {
            let job = try harness.submit(store, resources: ResourceRequest(minSims: 0))
            XCTAssertEqual(try engine.tick().admitted, [job.id])
            _ = try store.finish(jobID: job.id, result: result, now: harness.clock.now())
            harness.clock.advance(by: 60)
            return job
        }
        let failedOld = try ended(.commandFailure)
        let pinned = try ended(.success)
        try store.audit(Engine.artifactKeepAuditType, jobID: pinned.id, detail: "--keep", now: harness.clock.now())
        let passedOld = try ended(.success)
        let passedNew = try ended(.success)
        let running = try harness.submit(store, resources: ResourceRequest(minSims: 0))
        XCTAssertEqual(try engine.tick().admitted, [running.id])
        let day = "\(root)/2027-01-15"
        for (job, size) in [(failedOld, 4), (pinned, 4), (passedOld, 4), (passedNew, 4), (running, 4)]
            as [(Job, UInt64)]
        {
            try harness.fileSystem.createDirectory("\(day)/\(job.id)")
            harness.fileSystem.sizes["\(day)/\(job.id)"] = size
        }
        // 20 used, budget 10: 20 -> 16 -> 12 -> 8.
        let dry = try engine.garbageCollect(apply: false, now: harness.clock.now())
        XCTAssertEqual(
            dry.candidates.map(\.path), ["\(day)/\(passedOld.id)", "\(day)/\(passedNew.id)", "\(day)/\(failedOld.id)"],
            "succeeded oldest first, then failed, until 8 <= 10")
        XCTAssertTrue(harness.fileSystem.removed.isEmpty, "a dry run removes nothing")
        XCTAssertTrue(dry.candidates.allSatisfy { $0.reason.contains("artifact budget") })
        XCTAssertFalse(dry.candidates.contains { $0.path.hasSuffix(pinned.id) || $0.path.hasSuffix(running.id) })

        let applied = try engine.garbageCollect(apply: true, now: harness.clock.now())
        XCTAssertEqual(applied.removed, dry.candidates.map(\.path))
        XCTAssertTrue(harness.fileSystem.fileExists("\(day)/\(pinned.id)"))
        XCTAssertTrue(harness.fileSystem.fileExists("\(day)/\(running.id)"))
        XCTAssertEqual(
            try store.auditEntries().filter { $0.type == Engine.artifactRemovedAuditType }.count, applied.removed.count)
    }

    func testArtifactRetentionHoldsTerminalJobsUntilOwnedProcessCleanupIsVerified() throws {
        var reliability = ReliabilityConfig(cleanupMode: .enforce)
        reliability.ageRules.artifactRetention.budgetBytes = 1
        let harness = Harness(reliability: reliability)
        let root = "/fake/jobs"
        harness.artifactsRoot = root
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store, resources: ResourceRequest(minSims: 0))
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        let group = try store.acquireResource(
            kind: .processGroup, externalID: "900", owner: .job(job.id), epoch: engine.epoch,
            identity: FakeProcessTable.defaultIdentity(900), now: harness.clock.now())
        _ = try store.finish(jobID: job.id, result: .success, now: harness.clock.now())
        let dir = "\(root)/2027-01-15/\(job.id)"
        try harness.fileSystem.createDirectory(dir + "/DerivedData")
        harness.fileSystem.sizes[dir] = 100
        harness.clock.advance(by: 100 * 86_400)
        XCTAssertTrue(try engine.garbageCollect(apply: false, now: harness.clock.now()).candidates.isEmpty)
        try store.markResourceOrphaned(id: group.id, reason: "identity uncertain", now: harness.clock.now())
        XCTAssertTrue(try engine.garbageCollect(apply: false, now: harness.clock.now()).candidates.isEmpty)
        try store.markResourceReleased(id: group.id, reason: "verified gone", now: harness.clock.now())
        XCTAssertTrue(
            try engine.garbageCollect(apply: false, now: harness.clock.now()).candidates.contains { $0.path == dir })
    }

    /// `gc` re-checks each candidate right before removing it: a job pinned after the plan
    /// was made is skipped.
    func testACandidatePinnedAfterThePlanIsNotRemoved() throws {
        var reliability = ReliabilityConfig(cleanupMode: .enforce)
        reliability.ageRules.artifactRetention.budgetBytes = 1
        let harness = Harness(reliability: reliability)
        let root = "/fake/jobs"
        harness.artifactsRoot = root
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store, resources: ResourceRequest(minSims: 0))
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        _ = try store.finish(jobID: job.id, result: .success, now: harness.clock.now())
        let dir = "\(root)/2027-01-15/\(job.id)"
        try harness.fileSystem.createDirectory(dir)
        harness.fileSystem.sizes[dir] = 100
        let candidates = engine.gcCandidates(try engine.gcPlan(now: harness.clock.now()))
        XCTAssertEqual(candidates.map(\.path), [dir])
        XCTAssertTrue(try engine.stillRemovable(dir))
        try store.audit(Engine.artifactKeepAuditType, jobID: job.id, detail: "--keep", now: harness.clock.now())
        XCTAssertFalse(try engine.stillRemovable(dir), "pinned since the plan")
        XCTAssertFalse(try engine.stillRemovable(dir + "/DerivedData"), "nor its DerivedData")
    }

    /// A `--keep` job's run dir is kept for `kept` (90 days by default), not 7 or 14.
    func testAPinnedJobIsKeptForTheKeptRetention() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let root = "/fake/jobs"
        harness.artifactsRoot = root
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store)
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        _ = try store.finish(jobID: job.id, result: .success, now: harness.clock.now())
        try store.audit(Engine.artifactKeepAuditType, jobID: job.id, detail: "--keep", now: harness.clock.now())
        let dir = "\(root)/2027-01-15/\(job.id)"
        try harness.fileSystem.createDirectory(dir)
        harness.clock.advance(by: 89 * 86_400)
        XCTAssertTrue(try engine.garbageCollect(apply: false, now: harness.clock.now()).candidates.isEmpty)
        harness.clock.advance(by: 86_400)
        XCTAssertEqual(try engine.garbageCollect(apply: false, now: harness.clock.now()).candidates.map(\.path), [dir])
    }

    func testAForeignBootedSimSeenADayIsAFindingAndNeverTouched() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        harness.sims.setDevices([SimDevice(udid: "F1", name: "Other Tool Sim", isBooted: true)])
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        harness.clock.advance(by: 86_399)
        _ = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertTrue(try engine.ageFindings(now: harness.clock.now()).isEmpty)
        harness.clock.advance(by: 1)
        _ = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertEqual(
            try engine.ageFindings(now: harness.clock.now()), ["foreign booted sim Other Tool Sim (F1) seen for 24 h"])
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
    }

}
