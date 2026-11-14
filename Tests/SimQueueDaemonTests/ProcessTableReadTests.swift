// SPDX-License-Identifier: MIT

import Foundation
import SimQueueHost
import XCTest

/// The process table read behind every liveness, cleanup and recovery decision. The
/// kernel table is replaced by a fake whose size changes between the size probe and the
/// read, which is what a burst of new processes does to the real one.
final class ProcessTableReadTests: XCTestCase {
    /// A table of `UInt64` entries that grows by `growth[n]` entries before read `n`.
    private final class GrowingTable {
        var entries: Int
        var growth: [Int]
        var probes = 0
        var reads = 0
        var capacities: [Int] = []
        init(entries: Int, growth: [Int] = []) {
            self.entries = entries
            self.growth = growth
        }

        func read(_ buffer: UnsafeMutableRawBufferPointer?) -> ProcessTableRead.Outcome {
            let stride = MemoryLayout<UInt64>.stride
            guard let buffer else {
                probes += 1
                return .bytes(entries * stride)
            }
            if reads < growth.count { entries += growth[reads] }
            reads += 1
            capacities.append(buffer.count / stride)
            guard entries * stride <= buffer.count else { return .failed(ENOMEM) }
            for index in 0..<entries {
                buffer.storeBytes(of: UInt64(index), toByteOffset: index * stride, as: UInt64.self)
            }
            return .bytes(entries * stride)
        }
    }

    private func read(_ table: GrowingTable, maxAttempts: Int = ProcessTableRead.maxAttempts) throws -> [UInt64] {
        try ProcessTableRead.entries(of: UInt64.self, empty: 0, call: "fake", maxAttempts: maxAttempts) {
            table.read($0)
        }
    }

    func testAStableTableIsReadOnce() throws {
        let table = GrowingTable(entries: 1_000)
        XCTAssertEqual(try read(table), (0..<1_000).map(UInt64.init))
        XCTAssertEqual(table.reads, 1)
        XCTAssertEqual(table.capacities, [1_250], "a quarter of slack, not a fixed 64 entries")
    }

    func testSmallTablesKeepAMinimumOfSlack() throws {
        let table = GrowingTable(entries: 10, growth: [60])
        XCTAssertEqual(try read(table).count, 70, "sixty new processes still fit the first read")
        XCTAssertEqual(table.reads, 1)
    }

    func testATableThatOutgrowsTheBufferIsRetriedWithALargerOne() throws {
        // 1,300 processes, then a boot storm adds 600 before the first read: the old
        // fixed margin (and one attempt) failed here with "Cannot allocate memory".
        let table = GrowingTable(entries: 1_300, growth: [600])
        XCTAssertEqual(try read(table).count, 1_900)
        XCTAssertEqual(table.reads, 2)
        XCTAssertEqual(table.probes, 2, "the size is asked again: the table that did not fit is larger now")
        XCTAssertGreaterThan(table.capacities[1], table.capacities[0] * 2 - 1)
    }

    func testATableThatKeepsGrowingGivesUpWithTheKernelError() {
        let table = GrowingTable(entries: 100, growth: Array(repeating: 1_000_000, count: 8))
        XCTAssertThrowsError(try read(table, maxAttempts: 3)) { error in
            XCTAssertEqual(error as? ProcessControlError, .system(call: "fake", errno: ENOMEM))
        }
        XCTAssertEqual(table.reads, 3, "bounded: never an endless loop inside a tick")
    }

    func testOtherErrorsAreNotRetried() {
        var calls = 0
        XCTAssertThrowsError(
            try ProcessTableRead.entries(of: UInt64.self, empty: 0, call: "fake") { buffer in
                calls += 1
                return buffer == nil ? .bytes(64) : .failed(EPERM)
            }
        ) { error in
            XCTAssertEqual(error as? ProcessControlError, .system(call: "fake", errno: EPERM))
        }
        XCTAssertEqual(calls, 2)
    }

    func testAnInterruptedReadIsRetried() throws {
        var fills = 0
        let entries = try ProcessTableRead.entries(of: UInt64.self, empty: 7, call: "fake") { buffer in
            guard buffer != nil else { return .bytes(16) }
            fills += 1
            return fills == 1 ? .failed(EINTR) : .bytes(16)
        }
        XCTAssertEqual(entries, [7, 7])
        XCTAssertEqual(fills, 2)
    }

    #if canImport(Darwin)
        /// The real table, including the one-group read `terminateGroup` polls.
        func testRealProcessTableSeesThisProcessAndOneGroupAtATime() throws {
            let table = SystemProcessTable()
            XCTAssertTrue(try table.liveProcessGroups().contains(getpgrp()))
            XCTAssertTrue(try table.isGroupLive(getpgrp()))
            let pid = try ProcessSpawner.spawn(
                executable: "/bin/sleep", argv: ["/bin/sleep", "30"], environment: [:], cwd: nil,
                outputPath: "/dev/null")
            XCTAssertTrue(try table.isGroupLive(pid), "a spawned job leads its own live group")
            try table.terminateGroup(pid, graceSeconds: 5)
            XCTAssertFalse(try table.isGroupLive(pid), "an exited, unreaped leader is a zombie: not live")
            _ = try ProcessSpawner.reap(pid)
            XCTAssertFalse(try table.isGroupLive(pid))
        }
    #endif
}
