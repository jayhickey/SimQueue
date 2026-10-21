// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

/// Watchdog passes over the fake world: pass ids on audit entries, light vs full scope,
/// and the circuit breaker.
final class WatchdogPassTests: XCTestCase {
    let watchdog = WatchdogConfig()

    private func makeStore() throws -> JobStore {
        try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
    }

    func testPassIDsAreStampedOnAuditEntriesAndPersisted() throws {
        let harness = Harness()
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        XCTAssertEqual(try store.watchdogState().lastPassID, "full-1-1", "startup reconcile is the first full pass")

        let stray = harness.layout.runDir(jobID: "J-stray")
        try harness.fileSystem.createDirectory(stray)
        harness.clock.advance(by: 60)
        let light = try engine.watchdogPass(.light, config: watchdog)
        XCTAssertEqual(light.passID, "light-1-2")
        XCTAssertTrue(light.reconcile.actions.isEmpty, "a light pass doesn't look at directories")
        let full = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertEqual(full.passID, "full-1-3")
        XCTAssertEqual(full.reconcile.deferredGrace, [.removeDirectory(path: stray, resourceID: nil)])

        let candidates = try store.auditEntries().filter { $0.type == "cleanup_candidate" }
        XCTAssertEqual(candidates.map(\.passID), ["full-1-3"])
        XCTAssertNil(store.currentPassID, "cleared after the pass")
        try store.audit("manual", now: harness.clock.now())
        XCTAssertNil(try store.auditEntries().last?.passID)

        let state = try store.watchdogState()
        XCTAssertEqual(state.passCount, 3)
        XCTAssertEqual(state.lastPassKind, .full)
        XCTAssertEqual(state.lastLightPassAt, harness.clock.now())
        XCTAssertEqual(state.lastFullPassAt, harness.clock.now())
        XCTAssertEqual(full.health.level, .ok)
    }

    func testLightPassesKeepOtherTargetsGraceAndAnomalies() throws {
        let harness = Harness()
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        harness.sims.setDevices([SimDevice(udid: "S1", name: "simq-stray", isBooted: false)])
        _ = try engine.watchdogPass(.full, config: watchdog)
        harness.clock.advance(by: 300)
        _ = try engine.watchdogPass(.light, config: watchdog)
        harness.clock.advance(by: 300)
        let full = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertEqual(
            full.reconcile.wouldExecute, [.deleteSim(udid: "S1", resourceID: nil)], "grace kept across light")
        XCTAssertEqual(try store.anomalies().map(\.key), ["sim:S1"])
        for _ in 0..<3 {
            harness.clock.advance(by: 60)
            _ = try engine.watchdogPass(.light, config: watchdog)
        }
        XCTAssertEqual(try store.anomalies().map(\.key), ["sim:S1"], "light passes don't count as clean for sims")
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty, "report-only")
    }

    func testBreakerOpensOnThrashGoesReportOnlyThenHalfOpensAndCloses() throws {
        // Work dirs on the sim grace (10 min) so a dir can be cleaned twice within the hour.
        let harness = Harness(
            reliability: ReliabilityConfig(cleanupMode: .enforce, ageRules: AgeRules(workDirAfterJobSeconds: 600)))
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        let thrash = harness.layout.runDir(jobID: "J-thrash")

        // Something keeps recreating the same leftover: removed, back, removed again.
        for round in 0..<2 {
            try harness.fileSystem.createDirectory(thrash)
            _ = try engine.watchdogPass(.full, config: watchdog)
            harness.clock.advance(by: 600)
            let pass = try engine.watchdogPass(.full, config: watchdog)
            XCTAssertEqual(pass.reconcile.executed, [.removeDirectory(path: thrash, resourceID: nil)])
            if round == 0 {
                XCTAssertEqual(pass.breaker.phase, .closed)
            } else {
                XCTAssertEqual(pass.breaker.phase, .open)
                XCTAssertEqual(pass.transitions, [.opened(reason: "acted on dir:\(thrash) twice within 60 min")])
                XCTAssertEqual(pass.health.level, .breakerOpen)
                XCTAssertEqual(pass.alerts.map(\.key), ["breaker"])
                let alert = try XCTUnwrap(store.alert(key: "breaker"))
                XCTAssertEqual(alert.level, .page)
                XCTAssertTrue(alert.needsHuman, "a breaker trip needs a human")
            }
        }

        let other = harness.layout.runDir(jobID: "J-other")
        try harness.fileSystem.createDirectory(other)
        _ = try engine.watchdogPass(.full, config: watchdog)
        harness.clock.advance(by: 600)
        let held = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertTrue(held.reconcile.executed.isEmpty, "open breaker: report-only")
        XCTAssertEqual(held.reconcile.wouldExecute, [.removeDirectory(path: other, resourceID: nil)])
        XCTAssertTrue(harness.fileSystem.fileExists(other))

        harness.clock.advance(by: 3600)
        let probe = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertEqual(probe.transitions, [.halfOpened, .closed])
        XCTAssertEqual(probe.reconcile.executed, [.removeDirectory(path: other, resourceID: nil)])
        XCTAssertEqual(probe.breaker.phase, .closed)

        let breakerAudits = try store.auditEntries().filter { $0.type.hasPrefix("breaker_") }
        XCTAssertEqual(breakerAudits.map(\.type), ["breaker_opened", "breaker_half_open", "breaker_closed"])
        XCTAssertTrue(breakerAudits.allSatisfy { $0.passID?.hasPrefix("full-1-") == true })
    }

    func testSustainedAnomaliesRaiseOneDedupedAlertThatEscalates() throws {
        let harness = Harness()
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        harness.sims.setDevices([SimDevice(udid: "S1", name: "simq-stray", isBooted: false)])
        for _ in 0..<6 {
            harness.clock.advance(by: 900)
            _ = try engine.watchdogPass(.full, config: watchdog)
        }
        var alerts = try store.alerts()
        XCTAssertEqual(alerts.map(\.key), ["anomaly:sim:S1"], "one alert per key")
        XCTAssertEqual(alerts.first?.level, .warn)
        XCTAssertEqual(alerts.first?.count, 1, "raised on escalation, not on every pass")
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "alert_raised" }.count, 1)

        harness.clock.advance(by: 86_400)
        _ = try engine.watchdogPass(.full, config: watchdog)
        alerts = try store.alerts()
        XCTAssertEqual(alerts.map(\.key), ["anomaly:sim:S1"])
        XCTAssertEqual(alerts.first?.level, .page, "needs a human after 24 h")
        XCTAssertEqual(alerts.first?.count, 2)
        XCTAssertTrue(alerts.first?.needsHuman == true)
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty, "report-only")
    }

    /// A report-only leftover sim that later disappears (deleted by someone else, and never
    /// in the registry) must not keep health degraded: once full passes stop finding it, its
    /// anomaly clears after `clearAfterCleanPasses` clean full passes and its alert resolves.
    /// Light passes don't judge sims, so they neither clear it early nor keep it alive.
    func testAnAnomalyForASimThatIsGoneClearsAndHealthRecovers() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .reportOnly))
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        harness.sims.setDevices([SimDevice(udid: "GONE-1", name: "simq-pool-1-9", isBooted: false)])
        var pass = try engine.watchdogPass(.full, config: watchdog)
        for _ in 0..<5 {
            harness.clock.advance(by: 900)
            pass = try engine.watchdogPass(.full, config: watchdog)
        }
        XCTAssertEqual(pass.reconcile.wouldExecute, [.deleteSim(udid: "GONE-1", resourceID: nil)])
        XCTAssertEqual(try store.anomalies().map(\.key), ["sim:GONE-1"])
        XCTAssertEqual(try store.anomalies().first?.level, .sustained)
        XCTAssertEqual(pass.health.level, .degraded)
        XCTAssertEqual(try store.alerts().map(\.key), ["anomaly:sim:GONE-1"])
        XCTAssertFalse(try XCTUnwrap(store.alerts().first).isResolved)

        // The sim is deleted outside SimQueue: gone from simctl, and it never had a row.
        harness.sims.setDevices([])
        XCTAssertTrue(try store.liveResources().filter { $0.externalID == "GONE-1" }.isEmpty)
        harness.clock.advance(by: 900)
        pass = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertTrue(pass.reconcile.actions.isEmpty)
        XCTAssertEqual(try store.anomalies().map(\.key), ["sim:GONE-1"], "one clean pass doesn't clear it")
        for _ in 0..<5 {
            harness.clock.advance(by: 60)
            _ = try engine.watchdogPass(.light, config: watchdog)
        }
        XCTAssertEqual(try store.anomalies().map(\.key), ["sim:GONE-1"], "light passes don't judge sims")

        harness.clock.advance(by: 900)
        pass = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertTrue(try store.anomalies().isEmpty, "cleared after two clean full passes")
        XCTAssertEqual(pass.health.level, .ok)
        XCTAssertTrue(try XCTUnwrap(store.alerts().first).isResolved)
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty, "report-only")
    }

    func testBreakerOpensAfterThreeFailuresInARow() throws {
        // Work dirs on the sim grace (10 min) so a dir can be cleaned twice within the hour.
        let harness = Harness(
            reliability: ReliabilityConfig(cleanupMode: .enforce, ageRules: AgeRules(workDirAfterJobSeconds: 600)))
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        for name in ["J-a", "J-b", "J-c"] {
            let path = harness.layout.runDir(jobID: name)
            try harness.fileSystem.createDirectory(path)
            harness.fileSystem.removeFails.insert(path)
        }
        _ = try engine.watchdogPass(.full, config: watchdog)
        harness.clock.advance(by: 600)
        let pass = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertEqual(pass.reconcile.failedActions, 3)
        XCTAssertEqual(pass.breaker.phase, .open)
        XCTAssertEqual(pass.transitions, [.opened(reason: "3 cleanup failures in a row")])
        XCTAssertEqual(try store.watchdogState().breaker.phase, .open, "persisted")
    }

    func testABacklogAtTheLimitsIsPostponedNotATrip() throws {
        var reliability = ReliabilityConfig(cleanupMode: .enforce)
        reliability.maxDestructiveActionsPerHour = 2
        let harness = Harness(reliability: reliability)
        let store = try makeStore()
        let (engine, _, _) = try harness.start(store: store)
        let dirs = ["J-a", "J-b", "J-c", "J-d"].map { harness.layout.runDir(jobID: $0) }
        for dir in dirs { try harness.fileSystem.createDirectory(dir) }
        _ = try engine.watchdogPass(.full, config: watchdog)
        harness.clock.advance(by: 3600)
        let pass = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertEqual(pass.reconcile.executed.count, 2)
        XCTAssertTrue(pass.reconcile.hourlyLimitHit)
        XCTAssertEqual(pass.breaker.phase, .closed, "a backlog is not thrash")
        XCTAssertTrue(pass.transitions.isEmpty)
        XCTAssertEqual(pass.health.level, .ok)
        XCTAssertEqual(pass.health.notes, ["2 cleanups postponed to the next window"])
        XCTAssertEqual(try store.watchdogState().postponedTargets.count, 2)
        let logged = try store.auditEntries().filter { $0.type == "cleanup_postponed" }
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].detail?.hasPrefix("2 held by the hourly limit: dir:") == true, "\(logged)")

        // Still held on the next pass: not logged again.
        harness.clock.advance(by: 60)
        _ = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "cleanup_postponed" }.count, 1)
        // A light pass doesn't forget postponed dirs it doesn't check.
        _ = try engine.watchdogPass(.light, config: watchdog)
        XCTAssertEqual(try store.watchdogState().postponedTargets.count, 2)

        // The next hour's window finishes the work.
        harness.clock.advance(by: 3600)
        let next = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertEqual(next.reconcile.executed.count, 2)
        XCTAssertTrue(try store.watchdogState().postponedTargets.isEmpty)
        XCTAssertTrue(next.health.notes.isEmpty)
        XCTAssertTrue(dirs.allSatisfy { !harness.fileSystem.fileExists($0) })
    }
}
