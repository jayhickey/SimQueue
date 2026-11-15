// SPDX-License-Identifier: MIT

import XCTest

@testable import SimQueueHost

final class DiskCapacityTests: XCTestCase {
    func testAvailableCapacityIncludesReclaimableSpace() throws {
        let gib: UInt64 = 1 << 30
        XCTAssertEqual(
            try JobStorage.availableBytes(important: { Int64(70 * gib) }, raw: { 12 * gib }), 70 * gib)
        XCTAssertEqual(try JobStorage.availableBytes(important: { 0 }, raw: { 12 * gib }), 0)
    }

    func testUnavailableCapacityFallsBackToRawSpace() throws {
        XCTAssertEqual(try JobStorage.availableBytes(important: { nil }, raw: { 12 }), 12)
        XCTAssertEqual(try JobStorage.availableBytes(important: { -1 }, raw: { 12 }), 12)
        XCTAssertEqual(
            try JobStorage.availableBytes(important: { throw JobStorage.Failure("unsupported") }, raw: { 12 }), 12)
        XCTAssertThrowsError(
            try JobStorage.availableBytes(important: { nil }, raw: { throw JobStorage.Failure("unreadable") }))
    }

    func testSystemVolumeFailureIdentifiesTheVolume() {
        XCTAssertThrowsError(try JobStorage.ensureFreeSpace(12, minimum: 20, volume: "system")) {
            XCTAssertEqual(String(describing: $0), "system volume has 12 bytes free; requires 20 bytes")
        }
    }
}
