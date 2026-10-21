// SPDX-License-Identifier: MIT

import XCTest

@testable import SimQueueCore

final class PriorityPolicyTests: XCTestCase {
    let policy = PriorityPolicy()

    func testDefaultsAreGeneric() {
        XCTAssertEqual(policy.agingPointsPerMinute, 0.5)
        XCTAssertEqual(policy.maxBoost, 25)
        XCTAssertEqual(PriorityAliases().values, [:], "no named priorities ship by default")
    }

    func testRangeValidation() {
        XCTAssertTrue(Priority.isValid(0))
        XCTAssertTrue(Priority.isValid(100))
        XCTAssertFalse(Priority.isValid(-1))
        XCTAssertFalse(Priority.isValid(101))
    }

    func testScoreIsPriorityPlusCappedAging() {
        let job = makeJob("J-1", seq: 1, priority: 40, queueTime: 0)
        XCTAssertEqual(policy.effectiveScore(of: job, now: 0), 40)
        XCTAssertEqual(policy.effectiveScore(of: job, now: 600), 45, accuracy: 1e-9)
        XCTAssertEqual(policy.effectiveScore(of: job, now: 6_000), 65, "capped at +25")
    }

    func testAgingCanBeDisabled() {
        let flat = PriorityPolicy(agingPointsPerMinute: 0, maxBoost: 25)
        let job = makeJob("J-1", seq: 1, priority: 40, queueTime: 0)
        XCTAssertEqual(flat.effectiveScore(of: job, now: 86_400), 40)
        XCTAssertNil(flat.overtakeSeconds(lower: 40, higher: 41))
    }

    func testFutureQueueTimeGivesNoNegativeBoost() {
        XCTAssertEqual(policy.agingBoost(queueTime: 100, now: 50), 0)
    }

    func testHigherPriorityFirst() {
        let low = makeJob("J-low", seq: 1, priority: 10)
        let high = makeJob("J-high", seq: 2, priority: 90)
        XCTAssertEqual(policy.order([low, high], now: 0).map(\.id), ["J-high", "J-low"])
    }

    func testFIFOWithinEqualPriority() {
        let jobs = (1...5).map { makeJob("J-\($0)", seq: Int64($0), priority: 50, queueTime: 0) }
        XCTAssertEqual(policy.order(jobs.reversed(), now: 100).map(\.id), ["J-1", "J-2", "J-3", "J-4", "J-5"])
    }

    func testEqualScoreGoesToOlderQueueTime() {
        let older = makeJob("J-old", seq: 9, priority: 50, queueTime: 0)
        let newer = makeJob("J-new", seq: 1, priority: 50, queueTime: 10)
        XCTAssertEqual(policy.order([newer, older], now: 10).map(\.id), ["J-old", "J-new"])
    }

    func testOvertakeTime() {
        XCTAssertEqual(policy.overtakeSeconds(lower: 50, higher: 50), 0)
        XCTAssertEqual(policy.overtakeSeconds(lower: 40, higher: 50), 1_200)
        XCTAssertEqual(policy.overtakeSeconds(lower: 50, higher: 75), 3_000)
        XCTAssertNil(policy.overtakeSeconds(lower: 10, higher: 90), "gap larger than the aging cap")
    }

    func testAgedLowPriorityOvertakesFreshHigherPriority() {
        let aged = makeJob("J-aged", seq: 1, priority: 40, queueTime: 0)
        let fresh = makeJob("J-fresh", seq: 2, priority: 50, queueTime: 1_200)
        XCTAssertEqual(policy.order([fresh, aged], now: 1_200).first?.id, "J-aged")
        XCTAssertEqual(policy.order([fresh, aged], now: 1_199).first?.id, "J-fresh")
    }

    func testStreamOfHigherPriorityCannotStarveLowerWithinCap() {
        // One fresh priority-70 job arrives every minute; a priority-50 job still reaches
        // the front after the 40-minute overtake time.
        let waiting = makeJob("J-50", seq: 0, priority: 50, queueTime: 0)
        var firstWin: Double?
        for minute in 1...120 {
            let now = Double(minute) * 60
            let fresh = makeJob("J-70-\(minute)", seq: Int64(minute), priority: 70, queueTime: now)
            if policy.order([fresh, waiting], now: now).first?.id == "J-50" {
                firstWin = now
                break
            }
        }
        XCTAssertEqual(firstWin, 2_400)
    }

    func testAliasesResolveNumbersAndUserNames() {
        let none = PriorityAliases()
        XCTAssertEqual(none.resolve("75"), 75)
        XCTAssertEqual(none.resolve(" 0 "), 0)
        XCTAssertNil(none.resolve("101"))
        XCTAssertNil(none.resolve("urgent"), "no built-in names")
        let custom = PriorityAliases(["urgent": 90, "low": 10, "bad": 500])
        XCTAssertEqual(custom.resolve("urgent"), 90)
        XCTAssertEqual(custom.resolve("URGENT"), 90)
        XCTAssertEqual(custom.resolve("low"), 10)
        XCTAssertNil(custom.resolve("bad"), "out-of-range alias is rejected")
    }

    func testPolicyRoundTripsAsJSON() throws {
        let custom = PriorityPolicy(agingPointsPerMinute: 1, maxBoost: 10)
        let data = try JSONEncoder().encode(custom)
        XCTAssertEqual(try JSONDecoder().decode(PriorityPolicy.self, from: data), custom)
    }
}
