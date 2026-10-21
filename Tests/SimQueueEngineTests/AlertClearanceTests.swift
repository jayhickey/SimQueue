// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

/// Alerts resolve once their condition has been clear for 2 full passes in a row, and
/// reopen when it recurs.
final class AlertClearanceTests: XCTestCase {
    let watchdog = WatchdogConfig()

    func testALookalikeAlertClosesTwoFullPassesAfterTheSimGoesAndReopensIfItReturns() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let lookalike = SimDevice(udid: "LOOK-1", name: "SimQ Pool 1", isBooted: false)
        harness.sims.setDevices([lookalike])
        _ = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertNotNil(try store.alert(key: "lookalike_sim:LOOK-1"))

        _ = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertNil(try store.alert(key: "lookalike_sim:LOOK-1")?.resolvedAt, "still there")

        harness.sims.setDevices([])
        let first = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertTrue(first.alertsCleared.isEmpty)
        XCTAssertEqual(try store.alert(key: "lookalike_sim:LOOK-1")?.cleanPasses, 1)
        _ = try engine.watchdogPass(.light, config: watchdog)
        XCTAssertEqual(try store.alert(key: "lookalike_sim:LOOK-1")?.cleanPasses, 1, "light passes don't count")
        let second = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertEqual(second.alertsCleared, ["lookalike_sim:LOOK-1"])
        let resolved = try XCTUnwrap(store.alert(key: "lookalike_sim:LOOK-1"))
        XCTAssertNotNil(resolved.resolvedAt)
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "alert_cleared" }.count, 1)

        // Back again: a new sighting raises it again on the same key, reopened.
        harness.sims.setDevices([lookalike])
        _ = try engine.watchdogPass(.full, config: watchdog)
        let reopened = try XCTUnwrap(store.alert(key: "lookalike_sim:LOOK-1"))
        XCTAssertNil(reopened.resolvedAt)
        XCTAssertEqual(reopened.count, 2)
    }

    func testAClearThatComesBackBeforeTheSecondPassResetsTheCount() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let lookalike = SimDevice(udid: "LOOK-1", name: "simq lookalike", isBooted: false)
        harness.sims.setDevices([lookalike])
        _ = try engine.watchdogPass(.full, config: watchdog)
        harness.sims.setDevices([])
        _ = try engine.watchdogPass(.full, config: watchdog)
        harness.sims.setDevices([lookalike])
        _ = try engine.watchdogPass(.full, config: watchdog)
        XCTAssertEqual(try store.alert(key: "lookalike_sim:LOOK-1")?.cleanPasses, 0)
        XCTAssertNil(try store.alert(key: "lookalike_sim:LOOK-1")?.resolvedAt)
    }

    func testTheBreakerAlertClosesAfterTheBreakerCloses() throws {
        let harness = Harness(
            reliability: ReliabilityConfig(cleanupMode: .enforce, ageRules: AgeRules(workDirAfterJobSeconds: 600)))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let thrash = harness.layout.runDir(jobID: "J-thrash")
        for _ in 0..<2 {
            try harness.fileSystem.createDirectory(thrash)
            _ = try engine.watchdogPass(.full, config: watchdog)
            harness.clock.advance(by: 600)
            _ = try engine.watchdogPass(.full, config: watchdog)
        }
        XCTAssertNil(try store.alert(key: "breaker")?.resolvedAt)
        let other = harness.layout.runDir(jobID: "J-other")
        try harness.fileSystem.createDirectory(other)
        _ = try engine.watchdogPass(.full, config: watchdog)
        harness.clock.advance(by: 3600)
        let probe = try engine.watchdogPass(.full, config: watchdog)  // half-opens; the one action closes it
        XCTAssertEqual(probe.breaker.phase, .closed)
        XCTAssertEqual(try store.alert(key: "breaker")?.cleanPasses, 1)
        XCTAssertEqual(try engine.watchdogPass(.full, config: watchdog).alertsCleared, ["breaker"])
    }

    func testAlertsWhoseConditionCantBeCheckedNeverAutoClose() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        try store.recordAlerts(
            [AlertEvent(key: "custom:thing", level: .warn, title: "t", detail: "d")], now: harness.clock.now(),
            policy: AlertPolicy())
        for _ in 0..<5 { _ = try engine.watchdogPass(.full, config: watchdog) }
        XCTAssertNil(try store.alert(key: "custom:thing")?.resolvedAt)
    }
}
