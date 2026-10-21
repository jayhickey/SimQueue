// SPDX-License-Identifier: MIT

import SimQueueCore
import XCTest

final class AlertBookTests: XCTestCase {
    let policy = AlertPolicy()
    let event = AlertEvent(key: "anomaly:sim:A", level: .warn, title: "Sustained anomaly: sim:A", detail: "d1")

    func testRecurrenceRemainsLocalWithoutEscalation() {
        var record = AlertBook.record(event, into: nil, now: 0, policy: policy)
        for n in 1...100 { record = AlertBook.record(event, into: record, now: Double(n), policy: policy) }
        XCTAssertEqual(record.count, 101)
        XCTAssertFalse(record.needsHuman)
        XCTAssertNil(AlertBook.clearance(record, active: true, now: 101, policy: policy))
        let clearing = AlertBook.clearance(record, active: false, now: 102, policy: policy)!
        XCTAssertNotNil(AlertBook.clearance(clearing, active: false, now: 103, policy: policy)?.resolvedAt)
    }

    func testLevelOnlyRisesAndNeedsHumanEventsEscalateAtOnce() {
        let page = AlertEvent(key: event.key, level: .page, title: "t", detail: "d", needsHuman: true)
        var record = AlertBook.record(event, into: nil, now: 0, policy: policy)
        record = AlertBook.record(page, into: record, now: 1, policy: policy)
        XCTAssertEqual(record.level, .page)
        XCTAssertTrue(record.needsHuman)
        record = AlertBook.record(event, into: record, now: 2, policy: policy)
        XCTAssertEqual(record.level, .page)
    }

}
