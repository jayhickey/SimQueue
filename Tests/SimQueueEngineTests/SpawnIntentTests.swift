// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueStore
import XCTest

/// Write-ahead spawn intents: the daemon dies after spawning a job command but before
/// recording its pid. The restarted daemon finds the group by its token.
final class SpawnIntentTests: XCTestCase {
    private let token = "1-J-0001-0-abcd1234"
    private var entry: String { "\(JobStore.spawnTokenEnvironmentKey)=\(token)" }

    /// Admits a job, records its intent and "spawns" group 900 carrying the token (plus a
    /// child in the same group), then the daemon dies.
    private func crashAfterSpawn(_ harness: Harness, retryable: Bool = true, spawn: Bool = true) throws -> (
        JobStore, Job, OwnedResource
    ) {
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store, retryable: retryable)
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        let intent = try store.recordSpawnIntent(
            jobID: job.id, token: token, epoch: engine.epoch, detail: "/bin/sh", now: harness.clock.now())
        XCTAssertEqual(try store.unresolvedSpawnIntents().map(\.id), [intent.id])
        if spawn {
            harness.processes.spawn(900)
            harness.processes.tag(pid: 900, pgid: 900, entries: ["PATH=/bin", entry])
            harness.processes.tag(pid: 901, pgid: 900, entries: [entry])
        }
        harness.clock.advance(by: 5)
        return (store, job, intent)
    }

    func testEnforceModeFindsTheGroupStopsItAndRequeuesTheJob() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let (store, job, intent) = try crashAfterSpawn(harness)
        let (_, recovery, _) = try harness.start(store: store)
        XCTAssertEqual(recovery.resolvedSpawnIntents, [900])
        XCTAssertEqual(recovery.killedProcessGroups, [900], "verified by the leader's identity, then stopped")
        XCTAssertEqual(harness.processes.terminated, [900])
        XCTAssertEqual(recovery.requeued, [job.id], "safe to rerun: the first copy is stopped")
        let row = try XCTUnwrap(try store.resource(id: intent.id))
        XCTAssertEqual(row.externalID, "900")
        XCTAssertEqual(row.state, .released)
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "spawn_intent_found" }.count, 1)
        XCTAssertTrue(try store.unresolvedSpawnIntents().isEmpty)
    }

    func testAFoundStartedNonRetryableCommandIsStoppedButNotReplayed() throws {
        let harness = Harness()
        let (store, job, intent) = try crashAfterSpawn(harness, retryable: false)
        let (_, recovery, _) = try harness.start(store: store)
        XCTAssertEqual(recovery.resolvedSpawnIntents, [900])
        XCTAssertEqual(recovery.killedProcessGroups, [900], "SimQueue's own job group: stopped in any cleanup mode")
        XCTAssertEqual(harness.processes.terminated, [900])
        XCTAssertTrue(recovery.requeued.isEmpty)
        XCTAssertEqual(try store.job(id: job.id)?.state, .interrupted)
        XCTAssertEqual(try store.job(id: job.id)?.restartRequeues, 0)
        XCTAssertEqual(try store.resource(id: intent.id)?.state, .released)
        XCTAssertEqual(try store.auditCount(type: "restart_kill_would_execute", since: 0), 0)
    }

    func testAGroupWhoseStopFailsIsLeftAloneAndNeverRunsASecondCopy() throws {
        let harness = Harness()
        let (store, job, intent) = try crashAfterSpawn(harness)
        harness.processes.signalFails = [900]
        let (_, recovery, _) = try harness.start(store: store)
        XCTAssertEqual(recovery.resolvedSpawnIntents, [900])
        XCTAssertEqual(recovery.killedProcessGroups, [])
        XCTAssertEqual(recovery.stillRunning, [job.id])
        XCTAssertTrue(recovery.requeued.isEmpty, "never requeued beside its running command")
        XCTAssertEqual(try store.job(id: job.id)?.state, .interrupted)
        let row = try XCTUnwrap(try store.resource(id: intent.id))
        XCTAssertEqual(row.externalID, "900")
        XCTAssertEqual(row.identity, FakeProcessTable.defaultIdentity(900))
        XCTAssertEqual(
            try store.auditEntries().filter { $0.type == "restart_kill_skipped" }.count, 1, "the failed stop is audited"
        )
    }

    func testNoTokenDoesNotProveTheCommandNeverStarted() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let (store, job, intent) = try crashAfterSpawn(harness, spawn: false)
        let (_, recovery, _) = try harness.start(store: store)
        XCTAssertTrue(recovery.resolvedSpawnIntents.isEmpty)
        XCTAssertTrue(recovery.requeued.isEmpty)
        XCTAssertEqual(try store.job(id: job.id)?.state, .interrupted)
        XCTAssertEqual(try store.resource(id: intent.id)?.state, .released)
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "spawn_intent_not_found" }.count, 1)
    }

    func testAHostThatCannotScanInterruptsTheJobInsteadOfGuessing() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let (store, job, intent) = try crashAfterSpawn(harness)
        harness.processes.supportsEnvironmentScan = false
        let (engine, recovery, _) = try harness.start(store: store)
        XCTAssertTrue(recovery.requeued.isEmpty, "can't tell whether it started: never requeued")
        XCTAssertEqual(try store.job(id: job.id)?.state, .interrupted)
        XCTAssertEqual(try store.resource(id: intent.id)?.state, .orphaned)
        XCTAssertTrue(
            try engine.jobsWithLiveProcessGroups().contains(job.id),
            "unknown command retains capacity and simulator leases")
        XCTAssertTrue(
            try store.auditEntries().contains {
                $0.resourceID == intent.id && $0.type == "resource_orphaned" && ($0.detail?.contains("verify") == true)
            })
        XCTAssertTrue(harness.processes.terminated.isEmpty, "nothing unverified is ever signalled")
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "spawn_intent_unresolved" }.count, 1)
    }

    func testALeaderlessGroupIsRecordedButNeverSignalled() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let (store, job, intent) = try crashAfterSpawn(harness)
        harness.processes.leaderExited(900)
        harness.processes.tag(pid: 900, pgid: 900, entries: [])  // the leader is gone; 901 remains
        let (_, recovery, _) = try harness.start(store: store)
        XCTAssertEqual(recovery.resolvedSpawnIntents, [900])
        XCTAssertTrue(recovery.killedProcessGroups.isEmpty)
        XCTAssertTrue(harness.processes.terminated.isEmpty)
        XCTAssertEqual(recovery.stillRunning, [job.id])
        XCTAssertNil(try store.resource(id: intent.id)?.identity)
        XCTAssertEqual(try store.auditCount(type: "restart_kill_skipped", since: 0), 1)
    }

    func testResolvingOntoAPgidThatIsAlreadyOwnedFails() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store)
        _ = try engine.tick()
        try store.acquireResource(
            kind: .processGroup, externalID: "900", owner: .job(job.id), epoch: engine.epoch, now: harness.clock.now())
        let intent = try store.recordSpawnIntent(
            jobID: job.id, token: token, epoch: engine.epoch, detail: nil, now: harness.clock.now())
        XCTAssertThrowsError(try store.resolveSpawnIntent(id: intent.id, pgid: 900, identity: nil, now: 0))
        XCTAssertEqual(try store.unresolvedSpawnIntents().map(\.id), [intent.id])
    }
}
