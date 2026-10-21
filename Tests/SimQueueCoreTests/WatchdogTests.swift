// SPDX-License-Identifier: MIT

import SimQueueCore
import XCTest

final class BreakerTests: XCTestCase {
    let policy = BreakerPolicy()

    func testSameTargetTwiceWithinAnHourOpensTheBreaker() {
        var (state, transition) = Breaker.record(
            BreakerPassOutcome(executedTargets: ["sim:A"]), state: BreakerState(), now: 0, policy: policy)
        XCTAssertNil(transition)
        XCTAssertEqual(state.phase, .closed)
        (state, transition) = Breaker.record(
            BreakerPassOutcome(executedTargets: ["sim:A"]), state: state, now: 1800, policy: policy)
        XCTAssertEqual(state.phase, .open)
        XCTAssertEqual(transition, .opened(reason: "acted on sim:A twice within 60 min"))
        XCTAssertEqual(state.openedAt, 1800)
    }

    func testTheSameTargetAfterTheWindowIsFine() {
        var (state, _) = Breaker.record(
            BreakerPassOutcome(executedTargets: ["sim:A"]), state: BreakerState(), now: 0, policy: policy)
        (state, _) = Breaker.advance(state, now: 3600, policy: policy)
        XCTAssertTrue(state.recentActions.isEmpty, "pruned after the window")
        (state, _) = Breaker.record(
            BreakerPassOutcome(executedTargets: ["sim:A"]), state: state, now: 3600, policy: policy)
        XCTAssertEqual(state.phase, .closed)
    }

    func testThreeFailuresInARowOpenItAndASuccessResetsTheCount() {
        var state = BreakerState()
        (state, _) = Breaker.record(BreakerPassOutcome(failures: 2), state: state, now: 0, policy: policy)
        (state, _) = Breaker.record(
            BreakerPassOutcome(executedTargets: ["dir:/x"]), state: state, now: 1, policy: policy)
        XCTAssertEqual(state.consecutiveFailures, 0)
        (state, _) = Breaker.record(BreakerPassOutcome(failures: 1), state: state, now: 2, policy: policy)
        let (opened, transition) = Breaker.record(BreakerPassOutcome(failures: 2), state: state, now: 3, policy: policy)
        XCTAssertEqual(opened.phase, .open)
        XCTAssertEqual(transition, .opened(reason: "3 cleanup failures in a row"))
    }

    func testOpenGoesReportOnlyThenHalfOpensAfterAnHourAndASuccessCloses() {
        let open = BreakerState(phase: .open, reason: "x", openedAt: 0)
        let config = ReliabilityConfig(cleanupMode: .enforce)
        XCTAssertEqual(Breaker.limit(config, phase: .open).cleanupMode, .reportOnly)
        XCTAssertEqual(Breaker.advance(open, now: 3599, policy: policy).0.phase, .open)
        let (half, transition) = Breaker.advance(open, now: 3600, policy: policy)
        XCTAssertEqual(half.phase, .halfOpen)
        XCTAssertEqual(transition, .halfOpened)
        let limited = Breaker.limit(config, phase: .halfOpen)
        XCTAssertEqual(limited.cleanupMode, .enforce)
        XCTAssertEqual(limited.maxDestructiveActionsPerPass, 1)

        let (idle, none) = Breaker.record(BreakerPassOutcome(), state: half, now: 3601, policy: policy)
        XCTAssertEqual(idle.phase, .halfOpen, "nothing to try yet")
        XCTAssertNil(none)
        let (closed, closing) = Breaker.record(
            BreakerPassOutcome(executedTargets: ["sim:B"]), state: half, now: 3602, policy: policy)
        XCTAssertEqual(closed.phase, .closed)
        XCTAssertEqual(closing, .closed)
        XCTAssertNil(closed.reason)
    }

    func testAFailureWhileHalfOpenReopens() {
        let half = BreakerState(phase: .halfOpen, reason: "x", openedAt: 0)
        let (state, transition) = Breaker.record(
            BreakerPassOutcome(failures: 1), state: half, now: 4000, policy: policy)
        XCTAssertEqual(state.phase, .open)
        XCTAssertEqual(state.openedAt, 4000)
        XCTAssertEqual(transition, .opened(reason: "cleanup failed while half-open"))
    }

    func testStateRoundTripsAsJSON() throws {
        let state = WatchdogState(
            breaker: BreakerState(phase: .halfOpen, reason: "r", openedAt: 5, recentActions: ["sim:A": 4]),
            passCount: 7, lastPassID: "light-2-7", lastPassKind: .light, lastPassAt: 9)
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(WatchdogState.self, from: data), state)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""phase":"half-open""#))
    }
}

final class WatchdogScheduleTests: XCTestCase {
    func testFullPassFirstThenLightEveryMinuteAndFullEveryFifteen() {
        let config = WatchdogConfig()
        XCTAssertEqual(config.due(lastLightAt: nil, lastFullAt: nil, now: 0), .full)
        XCTAssertNil(config.due(lastLightAt: nil, lastFullAt: 0, now: 59))
        XCTAssertEqual(config.due(lastLightAt: nil, lastFullAt: 0, now: 60), .light)
        XCTAssertNil(config.due(lastLightAt: 60, lastFullAt: 0, now: 119))
        XCTAssertEqual(config.due(lastLightAt: 840, lastFullAt: 0, now: 900), .full)
    }

    func testLightPassesOnlyCoverProcessGroups() {
        XCTAssertTrue(WatchdogPassKind.light.covers(targetKey: "process_group:5"))
        XCTAssertFalse(WatchdogPassKind.light.covers(targetKey: "sim:A"))
        XCTAssertFalse(WatchdogPassKind.light.covers(targetKey: "foreign_sim:A"))
        XCTAssertTrue(WatchdogPassKind.full.covers(targetKey: "sim:A"))
    }
}

final class HealthSummaryTests: XCTestCase {
    func anomaly(_ level: AnomalyLevel) -> AnomalyRecord {
        AnomalyRecord(key: "k\(level)", detail: "", firstSeenAt: 0, lastSeenAt: 0, consecutivePasses: 1, level: level)
    }

    func testOkDegradedAndBreakerOpen() {
        let ok = HealthSummary.evaluate(
            breaker: BreakerState(), anomalies: [anomaly(.observed)], draining: false, lastPassAt: 100, now: 110,
            staleAfterSeconds: 180)
        XCTAssertEqual(ok, HealthSummary(level: .ok, reasons: []))
        let backlog = HealthSummary.evaluate(
            breaker: BreakerState(), anomalies: [], draining: false, lastPassAt: 100, now: 110, staleAfterSeconds: 180,
            postponed: 4)
        XCTAssertEqual(
            backlog, HealthSummary(level: .ok, reasons: [], notes: ["4 cleanups postponed to the next window"]),
            "a backlog is not a problem")

        let degraded = HealthSummary.evaluate(
            breaker: BreakerState(), anomalies: [anomaly(.sustained), anomaly(.needsHuman)], draining: true,
            lastPassAt: 0, now: 500, staleAfterSeconds: 180)
        XCTAssertEqual(degraded.level, .degraded)
        XCTAssertEqual(
            degraded.reasons,
            ["1 anomaly needs a human", "1 sustained anomaly", "infra drain active", "no watchdog pass for 500s"])

        let open = HealthSummary.evaluate(
            breaker: BreakerState(phase: .open, reason: "thrash", openedAt: 0), anomalies: [], draining: false,
            lastPassAt: 10, now: 10, staleAfterSeconds: 180)
        XCTAssertEqual(open, HealthSummary(level: .breakerOpen, reasons: ["breaker open: thrash"]))

        let fresh = HealthSummary.evaluate(
            breaker: BreakerState(), anomalies: [], draining: false, lastPassAt: nil, now: 0, staleAfterSeconds: 180)
        XCTAssertEqual(fresh, HealthSummary(level: .degraded, reasons: ["no watchdog pass yet"]))
    }
}
