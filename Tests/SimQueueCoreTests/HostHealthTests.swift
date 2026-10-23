// SPDX-License-Identifier: MIT
import XCTest

@testable import SimQueueHost

final class HostHealthTests: XCTestCase {
    func testCPUUsesTickDeltasInsteadOfLoadAverage() {
        XCTAssertNil(CPUSampler.percent(previous: nil, current: [10, 20, 30, 40]))
        XCTAssertNil(CPUSampler.percent(previous: [1, 2, 3, 4], current: [1, 2, 3, 4]))
        XCTAssertEqual(CPUSampler.percent(previous: [10, 10, 50, 0], current: [20, 20, 80, 0]), 40)
        XCTAssertEqual(CPUSampler.percent(previous: [UInt32.max, 0, 0, 0], current: [1, 0, 2, 0]), 50)
    }
    func testOutputDiskGateFailsClosedAndCanBeDisabled() {
        XCTAssertNoThrow(try JobStorage.ensureFreeSpace(20, minimum: 20))
        XCTAssertThrowsError(try JobStorage.ensureFreeSpace(19, minimum: 20))
        XCTAssertThrowsError(try JobStorage.ensureFreeSpace(nil, minimum: 20))
        XCTAssertNoThrow(try JobStorage.ensureFreeSpace(nil, minimum: 0))
    }
}
