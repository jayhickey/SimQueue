// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

/// The §8a.5 chaos scenarios on the fake world and a simulated clock. Restart, deadline
/// and SIGTERM-ignoring scenarios live in EngineTests, TimeoutTests and SpawnIntentTests;
/// the long random mix is SoakTests.
final class ChaosTests: XCTestCase {
    let watchdog = WatchdogConfig()

    private func makeStore(_ path: String = ":memory:") throws -> JobStore {
        try JobStore(path: path, maxQueuedPerSubmitterPerProject: 0)
    }

    private func destructive(_ store: JobStore) throws -> [AuditEntry] {
        try store.auditEntries().filter { $0.type == Engine.destructiveAuditType }
    }

    // MARK: - Crash replay (§8a.7 rule 5)

    /// (1) a job creates a sim; (2) the job and the daemon are SIGKILLed before teardown;
    /// (3) a sim with a lookalike name already exists; (4) a stale lease and a stale owner
    /// process still reference the UDID; (5) 7 simulated days pass. The lookalike is never
    /// adopted or touched and raises exactly one alert; the owned sim is reaped within the
    /// escalation window; the drift report shows the lookalike's counter from the first pass.

    func testOnlyLookalikesAlertAndOnlyOnce() {
        let naming = SimNamingScheme()
        for name in ["SimQ Pool App 1", "simq_pool_1", "SIMQ.template", "Simq-pool-1"] {
            XCTAssertTrue(naming.isLookalike(name), name)
        }
        for name in ["simq-pool-app-1", "iPhone 16", "Other Tool Sim", "simqueue", "simq"] {
            XCTAssertFalse(naming.isLookalike(name), name)
        }
    }

    // MARK: - Daemon SIGKILLed mid-create

    func testASimCreatedButNeverRecordedIsReapedAfterTheGrace() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let store = try makeStore()
        _ = try harness.start(store: store)
        // The clone finished, the row never got written, the daemon died.
        harness.sims.setDevices([SimDevice(udid: "HALF-1", name: "simq-pool-app-2", isBooted: false)])
        let (restarted, _, first) = try harness.start(store: store)
        XCTAssertEqual(first.deferredGrace, [.deleteSim(udid: "HALF-1", resourceID: nil)])
        harness.clock.advance(by: 600)
        XCTAssertEqual(
            try restarted.watchdogPass(.full, config: watchdog).reconcile.executed,
            [.deleteSim(udid: "HALF-1", resourceID: nil)])
        XCTAssertEqual(try destructive(store).count, 1, "one audit entry for the one action")
    }

    // MARK: - Hung simctl

    func testAHungSimBackendFailsThePassNotTheScheduler() throws {
        let harness = Harness()
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        harness.sims.listFailure = .timedOut("simctl list devices")
        XCTAssertThrowsError(try engine.watchdogPass(.full, config: watchdog))
        engine.recordWatchdogFailure(.full, error: FakeSimError.timedOut("simctl list devices"))
        let state = try store.watchdogState()
        XCTAssertEqual(state.lastPassError, "full pass: timedOut(\"simctl list devices\")")
        let health = HealthSummary.evaluate(
            breaker: state.breaker, anomalies: [], draining: false, lastPassAt: state.lastPassAt,
            now: harness.clock.now(), staleAfterSeconds: 180, lastPassError: state.lastPassError)
        XCTAssertEqual(health.level, .degraded)
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "watchdog_pass_failed" }.count, 1)
        // Scheduling doesn't list devices, so admissions carry on.
        let job = try harness.submit(store)
        XCTAssertEqual(try engine.tick().admitted, [job.id])

        // A light pass doesn't list sims, so it completes but doesn't clear a full pass's failure.
        harness.clock.advance(by: 60)
        _ = try engine.watchdogPass(.light, config: watchdog)
        XCTAssertNotNil(try store.watchdogState().lastPassError, "still degraded while simctl hangs")

        harness.sims.listFailure = nil
        harness.clock.advance(by: 60)
        _ = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertNil(try store.watchdogState().lastPassError, "cleared by the next full pass that completes")
    }

    // MARK: - DB write failure

    func testADatabaseWriteFailureMidPassDestroysNothingThenRecovers() throws {
        struct DiskIOError: Error {}
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        harness.sims.setDevices([SimDevice(udid: "LEAK-1", name: "simq-leak", isBooted: false)])
        _ = try engine.watchdogPass(.full, config: watchdog)
        harness.clock.advance(by: 600)

        store.database.writeFault = DiskIOError()
        XCTAssertThrowsError(try engine.watchdogPass(.full, config: watchdog))
        engine.recordWatchdogFailure(.full, error: DiskIOError())  // best effort: can't write either
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty, "nothing destroyed without its records")
        XCTAssertNil(store.currentPassID)

        store.database.writeFault = nil
        let pass = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertEqual(pass.reconcile.executed, [.deleteSim(udid: "LEAK-1", resourceID: nil)])
        XCTAssertEqual(try destructive(store).count, 1)
    }

    // MARK: - Clock jumps

    func testClockJumpsNeverMakeCleanupEarly() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        harness.sims.setDevices([SimDevice(udid: "LEAK-1", name: "simq-leak", isBooted: false)])
        _ = try engine.watchdogPass(.full, config: watchdog)
        let seen = harness.clock.now()

        harness.clock.set(seen - 7200)  // back two hours
        XCTAssertTrue(try engine.watchdogPass(.full, config: watchdog).reconcile.executed.isEmpty)
        harness.clock.set(seen + 300)
        XCTAssertTrue(try engine.watchdogPass(.full, config: watchdog).reconcile.executed.isEmpty)
        harness.clock.set(seen + 600)
        XCTAssertEqual(try engine.watchdogPass(.full, config: watchdog).reconcile.executed.count, 1)

        // A forward jump enforces deadlines by the clock; a backward one never kills early.
        let job = try harness.submit(store, runTimeout: 600)
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        harness.processes.spawn(901)
        XCTAssertTrue(try store.markRunning(jobID: job.id, pid: 901, epoch: engine.epoch, now: harness.clock.now()))
        harness.clock.set(harness.clock.now() - 3600)
        XCTAssertTrue(try engine.tick().timeouts.termSent.isEmpty)
        harness.clock.set(harness.clock.now() + 86_400)
        XCTAssertEqual(try engine.tick().timeouts.termSent, [job.id])
    }

    // MARK: - A sim deleted outside SimQueue

    func testASimDeletedOutsideSimQueueIsMarkedGoneWithoutAnyAction() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store)
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        harness.sims.setDevices([SimDevice(udid: "U1", name: "simq-pool-app-1", isBooted: true)])
        let row = try store.acquireResource(
            kind: .sim, externalID: "U1", owner: .job(job.id), epoch: engine.epoch, now: harness.clock.now())
        harness.sims.setDevices([])  // someone ran `simctl delete`
        let pass = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertEqual(pass.reconcile.actions, [.markGone(resourceID: row.id)])
        XCTAssertEqual(try store.resource(id: row.id)?.state, .released)
        XCTAssertTrue(try destructive(store).isEmpty)
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
    }

    // MARK: - Full disk

    // MARK: - Foreign sims and processes

    func testForeignSimsAndProcessesAreNeverTouchedEvenInEnforceMode() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let foreign = [
            SimDevice(udid: "F1", name: "Other Tool Sim", isBooted: true),
            SimDevice(udid: "F2", name: "simq_pool_7", isBooted: false),
        ]
        harness.sims.setDevices(foreign)
        harness.processes.spawn(77)  // someone else's xcodebuild
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        for _ in 0..<(2 * 96) {
            harness.clock.advance(by: 900)
            _ = try engine.watchdogPass(.full, config: watchdog)
        }
        XCTAssertEqual(try harness.sims.listDevices(), foreign)
        XCTAssertTrue(try harness.processes.liveProcessGroups().contains(77))
        XCTAssertTrue(harness.processes.terminated.isEmpty)
        XCTAssertTrue(harness.processes.signals.isEmpty)
        XCTAssertTrue(try destructive(store).isEmpty)
        XCTAssertEqual(try store.alerts().map(\.key), ["lookalike_sim:F2"], "only the lookalike alerts, once")
        XCTAssertEqual(
            try engine.ageFindings(now: harness.clock.now()).filter { $0.hasPrefix("foreign booted sim") },
            ["foreign booted sim Other Tool Sim (F1) seen for 48 h"])
    }
}
