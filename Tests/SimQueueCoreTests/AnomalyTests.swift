// SPDX-License-Identifier: MIT

import XCTest

@testable import SimQueueCore

final class AnomalyTests: XCTestCase {
    let policy = AnomalyPolicy()

    private func run(_ passes: [(now: Double, seen: Bool)]) -> [AnomalyUpdate] {
        var records: [AnomalyRecord] = []
        var updates: [AnomalyUpdate] = []
        for pass in passes {
            let update = AnomalyTracker.step(
                previous: records, seen: pass.seen ? ["sim:X": "failed"] : [:], now: pass.now, policy: policy)
            records = update.records
            updates.append(update)
        }
        return updates
    }

    func testDefaults() {
        XCTAssertEqual(policy.sustainedAfterPasses, 4)
        XCTAssertEqual(policy.sustainedAfterSeconds, 3_600)
        XCTAssertEqual(policy.needsHumanAfterSeconds, 86_400)
        XCTAssertEqual(policy.clearAfterCleanPasses, 2)
    }

    func testSustainedAfterFourPasses() {
        let updates = run((0..<4).map { (Double($0) * 60, true) })
        XCTAssertEqual(updates[2].records.first?.level, .observed)
        XCTAssertEqual(updates[3].records.first?.level, .sustained)
        XCTAssertEqual(updates[3].escalated.map(\.key), ["sim:X"])
        XCTAssertTrue(run((0..<5).map { (Double($0) * 60, true) })[4].escalated.isEmpty, "escalates once")
    }

    func testSustainedAfterAnHourEvenWithFewPasses() {
        let updates = run([(0, true), (3_600, true)])
        XCTAssertEqual(updates[1].records.first?.level, .sustained)
    }

    func testNeedsHumanAfterADay() {
        let updates = run([(0, true), (600, true), (86_400, true)])
        XCTAssertEqual(updates[2].records.first?.level, .needsHuman)
        XCTAssertEqual(updates[2].escalated.first?.level, .needsHuman)
    }

    func testOneCleanPassDoesNotResetTwoDo() {
        let updates = run([(0, true), (60, true), (120, true), (180, false), (240, true)])
        XCTAssertEqual(updates[4].records.first?.consecutivePasses, 4, "a single clean pass doesn't reset")
        XCTAssertEqual(updates[4].records.first?.level, .sustained)
        let cleared = run([(0, true), (60, false), (120, false)])
        XCTAssertEqual(cleared[2].cleared.map(\.key), ["sim:X"])
        XCTAssertTrue(cleared[2].records.isEmpty)
        let again = run([(0, true), (60, false), (120, false), (180, true)])
        XCTAssertEqual(again[3].records.first?.firstSeenAt, 180, "starts over after clearing")
    }

    func testLevelsAreOrdered() {
        XCTAssertLessThan(AnomalyLevel.observed, .sustained)
        XCTAssertLessThan(AnomalyLevel.sustained, .needsHuman)
    }
}
