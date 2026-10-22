// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueProtocol
import XCTest

/// Readable job names (`kind`) and the local start/queue times shown by `simq jobs`,
/// `simq explain` and the dashboard.
final class JobLabelAndTimeTests: XCTestCase {
    static let names = ["Quotify PR #134 · Unit tests", "Quotify main · Unit + UI tests (full)"]

    func testReadableNamesWithSpacesAndPunctuationAreValidAndKeptAsIs() {
        for name in Self.names + ["Quotify UI Tests", "日本語 テスト ✅", "a"] {
            XCTAssertTrue(JobKindLabel.isValid(name), name)
            XCTAssertEqual(JobKindLabel.normalized(name), name)
        }
    }

    func testLabelsFromTheOldCharsetStillWork() {
        for old in ["", "build", "nightly-e2e:ios/v2", "unit-test", "ui_test.shard", String(repeating: "k", count: 64)]
        {
            XCTAssertTrue(JobKindLabel.isValid(old), old)
            XCTAssertEqual(JobKindLabel.normalized(old), old)
        }
    }

    func testControlCharactersLineBreaksAndBlankNamesAreRejected() {
        for bad in [
            "Quotify\nUnit tests", "Quotify\r\nUnit", "tab\there", "bell\u{07}", "esc\u{1B}[31m", "nul\u{0}",
            "next\u{85}line", "line\u{2028}sep", "para\u{2029}sep", "rtl\u{202E}override", "isolate\u{2066}x",
        ] {
            XCTAssertFalse(JobKindLabel.isValid(bad), bad.debugDescription)
            XCTAssertNil(JobKindLabel.normalized(bad), bad.debugDescription)
        }
        for blank in [" ", "   ", "\t"] {
            XCTAssertNil(JobKindLabel.normalized(blank), "whitespace-only: \(blank.debugDescription)")
        }
    }

    func testSurroundingSpacesAreTrimmedAndTheStoredFormMustBeTrimmed() {
        XCTAssertEqual(JobKindLabel.normalized("  Quotify PR #134 · Unit tests "), Self.names[0])
        XCTAssertFalse(JobKindLabel.isValid(" leading"))
        XCTAssertFalse(JobKindLabel.isValid("trailing "))
    }

    func testTheLimitIs100CharactersNotBytes() {
        let hundred = String(repeating: "·", count: 100)  // 200 UTF-8 bytes
        XCTAssertTrue(JobKindLabel.isValid(hundred))
        XCTAssertTrue(JobKindLabel.isValid(String(repeating: "✅", count: 100)))
        XCTAssertFalse(JobKindLabel.isValid(hundred + "x"))
        XCTAssertNil(JobKindLabel.normalized(String(repeating: "k", count: 101)))
    }

    // MARK: - Local times

    private func zone(_ identifier: String) throws -> TimeZone { try XCTUnwrap(TimeZone(identifier: identifier)) }

    func testShortLocalTimeUsesTheGivenZone() throws {
        let at = try XCTUnwrap(Timestamp(rfc3339: "2026-10-22T19:43:00Z"))
        XCTAssertEqual(at.shortLocal(timeZone: try zone("America/Los_Angeles")), "Oct 22, 12:43 PM")
        XCTAssertEqual(at.shortLocal(timeZone: try zone("UTC")), "Oct 22, 7:43 PM")
        XCTAssertEqual(at.shortLocal(timeZone: try zone("Asia/Tokyo")), "Oct 23, 4:43 AM", "the date follows the zone")
        let midnight = try XCTUnwrap(Timestamp(rfc3339: "2026-01-05T08:05:30.250Z"))
        XCTAssertEqual(midnight.shortLocal(timeZone: try zone("America/Los_Angeles")), "Jan 5, 12:05 AM")
    }

    func testAMissingTimeIsADash() throws {
        XCTAssertEqual(Timestamp.shortLocalOrDash(nil, timeZone: try zone("UTC")), "-")
        XCTAssertEqual(Timestamp.shortLocalOrDash(Timestamp(0), timeZone: try zone("UTC")), "Jan 1, 12:00 AM")
    }
}
