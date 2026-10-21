// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueProtocol
import XCTest

final class TimestampTests: XCTestCase {
    func testFormatsUTCWithOptionalMilliseconds() {
        // 2026-10-20T04:45:00Z is 9:45 PM PDT on Oct 19.
        XCTAssertEqual(Timestamp(1_792_471_500).rfc3339, "2026-10-20T04:45:00Z")
        XCTAssertEqual(Timestamp(1_792_471_500.25).rfc3339, "2026-10-20T04:45:00.250Z")
        XCTAssertEqual(Timestamp(1_792_471_500.0004).rfc3339, "2026-10-20T04:45:00Z", "rounded to the millisecond")
        XCTAssertEqual(Timestamp(1_792_471_500.9996).rfc3339, "2026-10-20T04:45:01Z")
        XCTAssertEqual(Timestamp(0).rfc3339, "1970-01-01T00:00:00Z")
        XCTAssertEqual(Timestamp(-1).rfc3339, "1969-12-31T23:59:59Z")
        XCTAssertEqual(Timestamp(951_782_400).rfc3339, "2000-02-29T00:00:00Z", "leap day")
        XCTAssertEqual(Timestamp(4_102_444_800).rfc3339, "2100-01-01T00:00:00Z")
    }

    func testMatchesFoundationForManyInstants() {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let seconds = Double(Int64.random(in: -2_000_000_000...4_000_000_000, using: &generator))
            XCTAssertEqual(Timestamp(seconds).rfc3339, formatter.string(from: Date(timeIntervalSince1970: seconds)))
            XCTAssertEqual(Timestamp(rfc3339: Timestamp(seconds).rfc3339)?.epochSeconds, seconds)
        }
    }

    func testParsesRFC3339Variants() {
        XCTAssertEqual(Timestamp(rfc3339: "2026-10-20T04:45:00Z")?.epochSeconds, 1_792_471_500)
        XCTAssertEqual(Timestamp(rfc3339: "2026-10-19T21:45:00-07:00")?.epochSeconds, 1_792_471_500)
        XCTAssertEqual(Timestamp(rfc3339: "2026-10-20t04:45:00.5z")?.epochSeconds, 1_792_471_500.5)
        XCTAssertEqual(Timestamp(rfc3339: "2026-10-20 05:45:00+01:00")?.epochSeconds, 1_792_471_500)
        for bad in [
            "", "2026-10-20", "2026-10-20T04:45:00", "2026-13-01T00:00:00Z", "2026-02-30T00:00:00Z",
            "2026-10-20T24:00:00Z", "2026-10-20T04:45:00.Z", "2026-10-20T04:45:00Zjunk", "1792471500",
        ] {
            XCTAssertNil(Timestamp(rfc3339: bad), bad)
        }
    }

    func testCodableIsAStringAndAcceptsLegacyNumbers() throws {
        struct Box: Codable, Equatable { var at: Timestamp; var maybe: Timestamp? }
        let data = try JSONEncoder().encode(Box(at: Timestamp(1_792_471_500), maybe: nil))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"at":"2026-10-20T04:45:00Z"}"#)
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: data), Box(at: Timestamp(1_792_471_500), maybe: nil))
        let legacy = try JSONDecoder().decode(Box.self, from: Data(#"{"at": 1792471500.5}"#.utf8))
        XCTAssertEqual(legacy.at.epochSeconds, 1_792_471_500.5)
        XCTAssertThrowsError(try JSONDecoder().decode(Box.self, from: Data(#"{"at": "yesterday"}"#.utf8)))
    }

    func testJobInfoEncodesEveryTimestampAsRFC3339() throws {
        let job = Job(
            id: "J-0001", sequence: 1, project: "app", submitter: "dev", runTimeoutSeconds: 60,
            queueTimeoutSeconds: 600,
            queueTime: 1_792_471_500, createdAt: 1_792_471_500, admittedAt: 1_792_471_510, startedAt: 1_792_471_520,
            state: .running, termSentAt: 1_792_471_580, killSentAt: 1_792_471_590)
        let json = String(decoding: try LineCodec.encode(JobInfo(job: job, explanation: nil)), as: UTF8.self)
        for (key, value) in [
            ("queue_time", "2026-10-20T04:45:00Z"), ("admitted_at", "2026-10-20T04:45:10Z"),
            ("started_at", "2026-10-20T04:45:20Z"), ("run_deadline_at", "2026-10-20T04:46:20Z"),
            ("term_sent_at", "2026-10-20T04:46:20Z"), ("kill_sent_at", "2026-10-20T04:46:30Z"),
        ] {
            XCTAssertTrue(json.contains("\"\(key)\":\"\(value)\""), "\(key) in \(json)")
        }
        XCTAssertTrue(json.contains("\"run_timeout_seconds\":60"), "durations stay numbers: \(json)")
    }
}
