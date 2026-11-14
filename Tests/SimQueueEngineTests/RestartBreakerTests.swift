// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueEngine
import SimQueueStore
import XCTest

/// The restart-loop breaker as the scheduler sees it, on an injected clock: it holds
/// admissions while enough unplanned daemon starts fall inside its window, lifts by
/// itself when the oldest ages out, and lifts at once on `simq resume`.
final class RestartBreakerTests: XCTestCase {
    private func recordUnplannedStarts(_ store: JobStore, at times: [Double]) throws {
        for time in times {
            try store.audit(RestartBreakerPolicy.auditType, detail: "after a previous epoch: test", now: time)
        }
    }

    func testTheDefaultsLetThePerJobCapEndADaemonCrashingJobBeforeTheBreakerHoldsEveryone() {
        // A job that takes the daemon down each time it is admitted is capped by its
        // fourth restart. The breaker must need more unplanned starts than that.
        let startsToCapOneJob = JobStore.defaultMaxRestartRequeues + 1
        XCTAssertEqual(RestartBreakerPolicy().limit, 5)
        XCTAssertGreaterThan(RestartBreakerPolicy().limit, startsToCapOneJob)
        XCTAssertEqual(RestartBreakerPolicy().windowSeconds, 900)
    }

    func testTheHoldLiftsByItselfOnceTheOldestStartIsOlderThanTheWindow() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store, resources: ResourceRequest())
        let first = harness.clock.now()
        // Five unplanned starts, one a minute.
        try recordUnplannedStarts(store, at: (0..<5).map { first + Double($0) * 60 })
        harness.clock.advance(by: 300)

        let held = try engine.tick()
        XCTAssertTrue(held.admitted.isEmpty)
        XCTAssertEqual(held.globalReasons, [.restartLoop(restarts: 5, windowSeconds: 900)])
        XCTAssertEqual(
            try engine.restartBreakerStatus(now: harness.clock.now()), .tripped(restarts: 5, windowSeconds: 900))

        harness.clock.advance(by: 9 * 60)  // 14 minutes after the first start: all five still count
        XCTAssertTrue(try engine.tick().admitted.isEmpty)

        harness.clock.advance(by: 61)  // the first start has aged out: four left
        XCTAssertEqual(try engine.restartBreakerStatus(now: harness.clock.now()), .normal)
        XCTAssertEqual(try engine.tick().admitted, [job.id], "nobody resumed anything: the daemon stayed up")
    }

    func testResumeLiftsTheHoldAtOnceAndForgetsTheStartsSoFar() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store, resources: ResourceRequest())
        let first = harness.clock.now()
        try recordUnplannedStarts(store, at: (0..<5).map { first + Double($0) })
        harness.clock.advance(by: 10)
        XCTAssertTrue(try engine.tick().admitted.isEmpty)

        try store.resume(now: harness.clock.now())
        XCTAssertEqual(try engine.tick().admitted, [job.id], "well inside the window, but resumed")

        // One more unplanned start does not bring the hold back: the five before the
        // resume no longer count. Five new ones would.
        harness.clock.advance(by: 1)
        try recordUnplannedStarts(store, at: [harness.clock.now()])
        let next = try harness.submit(store, submitter: "second", resources: ResourceRequest())
        harness.clock.advance(by: 1)
        XCTAssertEqual(try engine.tick().admitted, [next.id])
        try recordUnplannedStarts(store, at: (0..<4).map { harness.clock.now() + Double($0) * 0.1 })
        harness.clock.advance(by: 1)
        XCTAssertEqual(
            try engine.restartBreakerStatus(now: harness.clock.now()), .tripped(restarts: 5, windowSeconds: 900))
    }

    func testAHeldQueueShowsInHealth() {
        let healthy = HealthSummary.evaluate(
            breaker: BreakerState(), anomalies: [], draining: false, lastPassAt: 0, now: 1, staleAfterSeconds: 60)
        XCTAssertEqual(healthy.level, .ok)
        let held = HealthSummary.evaluate(
            breaker: BreakerState(), anomalies: [], draining: false, lastPassAt: 0, now: 1, staleAfterSeconds: 60,
            restartLoop: .tripped(restarts: 5, windowSeconds: 900))
        XCTAssertEqual(held.level, .degraded)
        XCTAssertEqual(held.reasons, ["restart loop: 5 unplanned daemon restarts in 15 min, admissions held"])
    }
}
