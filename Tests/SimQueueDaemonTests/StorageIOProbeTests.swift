// SPDX-License-Identifier: MIT

import Dispatch
import Foundation
import SimQueueDaemon
import SimQueueHost
import SimQueueProtocol
import XCTest

final class StorageIOProbeTests: XCTestCase {
    /// An I/O operation that blocks until released, counting how often it starts.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var started = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return started }
        func operation(_ root: String) throws {
            lock.lock(); started += 1; lock.unlock()
            release.wait()
        }
        func open() { release.signal() }
    }

    private func scratch() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func eventually(timeout: Double = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    func testRealProbeWritesReadsAndRemovesItsFile() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(atPath: root) }
        let probe = StorageIOProbe(intervalSeconds: 0, inlineWaitSeconds: 2)
        XCTAssertNil(probe.check(root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), [], "probe file must be removed")
    }

    func testMissingRootIsSkippedAndNotCreated() throws {
        let state = try scratch(); defer { try? FileManager.default.removeItem(atPath: state) }
        XCTAssertNoThrow(try StorageIOProbe.writeReadRemove(state + "/jobs"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state + "/jobs"))
    }

    func testFailedOperationIsReported() {
        let probe = StorageIOProbe(intervalSeconds: 0, inlineWaitSeconds: 2) { _ in
            throw JobStorage.Failure("read failed")
        }
        XCTAssertEqual(probe.check("/jobs"), "read failed")
    }

    func testHungOperationReportsUnhealthyWithoutBlockingOrStackingProbes() {
        let gate = Gate()
        let probe = StorageIOProbe(
            timeoutSeconds: 0.3, intervalSeconds: 0, inlineWaitSeconds: 0.05, operation: gate.operation)
        let started = Date()
        XCTAssertNil(probe.check("/jobs"), "a probe within its limit keeps the last known result")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25, "callers wait only the inline bound")
        Thread.sleep(forTimeInterval: 0.35)
        let blocked = Date()
        let failure = probe.check("/jobs")
        XCTAssertLessThan(Date().timeIntervalSince(blocked), 0.1, "a hung probe is reported without waiting")
        XCTAssertTrue(failure?.contains("has not finished") == true, failure ?? "nil")
        XCTAssertTrue(failure?.contains("/jobs") == true, failure ?? "nil")
        XCTAssertNotNil(probe.check("/jobs"))
        XCTAssertEqual(gate.calls, 1, "no second probe starts while the first is pending")

        gate.open()
        XCTAssertTrue(eventually { probe.check("/jobs") == nil }, "recovers once I/O completes")
    }

    func testCompletedResultIsReusedWithinInterval() {
        let gate = Gate()
        let probe = StorageIOProbe(intervalSeconds: 3600, inlineWaitSeconds: 2, operation: gate.operation)
        gate.open(); gate.open()
        XCTAssertNil(probe.check("/jobs"))
        XCTAssertNil(probe.check("/jobs"))
        XCTAssertEqual(gate.calls, 1)
    }

    func testStatusAndDoctorReportHungJobOutput() throws {
        let daemon = try TestDaemon()
        defer { daemon.destroy() }
        daemon.stop()
        let gate = Gate()
        defer { gate.open() }
        daemon.service.ioProbe = StorageIOProbe(
            timeoutSeconds: 0.2, intervalSeconds: 0, inlineWaitSeconds: 0.01, operation: gate.operation)
        _ = daemon.service.handle(Request(params: .status))
        Thread.sleep(forTimeInterval: 0.25)

        guard case .result(.status(let status)) = daemon.service.handle(Request(params: .status)).body,
            let storage = status.storage
        else { return XCTFail("status failed") }
        XCTAssertFalse(storage.available)
        XCTAssertTrue(storage.failure?.contains("has not finished") == true, storage.failure ?? "nil")

        guard case .result(.doctor(let report)) = daemon.service.handle(Request(params: .doctor)).body,
            let check = report.checks.first(where: { $0.name == "job_storage" })
        else { return XCTFail("doctor failed") }
        XCTAssertEqual(check.level, .fail)
        XCTAssertTrue(check.detail.contains("has not finished"), check.detail)
    }
}
