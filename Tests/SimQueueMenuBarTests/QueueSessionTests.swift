// SPDX-License-Identifier: MIT

import Foundation
import SimQueueMenuBar
import SimQueueProtocol
import XCTest

final class QueueSessionTests: XCTestCase {
    private final class Stub: @unchecked Sendable {
        var calls: [RequestParams] = []
        var epoch: Int64 = 7
        var complete = false
        var serviceStopped = false
        var status: StatusResult {
            StatusResult(
                daemon: DaemonInfo(
                    version: "test", pid: 123, epoch: epoch, backend: "fake", startedAt: 0,
                    statePath: "/isolated", socketPath: "/isolated/socket", cleanupMode: "fake"),
                queued: 2, admitted: 0, running: complete ? 0 : 1, paused: false, draining: true,
                loadThrottled: false, globalWaitReasons: [], lastTickAt: nil, drainComplete: complete)
        }
        func send(_ params: RequestParams) throws -> ResultPayload {
            calls.append(params)
            switch params {
            case .jobs: return .jobs([])
            default: return .status(status)
            }
        }
    }

    func testFinishModeGatesWithoutCancelingAndWaitsForCleanup() throws {
        let stub = Stub()
        let session = QueueSession(request: stub.send)
        _ = try session.beginStop(cancelActive: false, expectedEpoch: 7)
        XCTAssertEqual(stub.calls, [.status, .drain])
        XCTAssertFalse(try session.finishStop(expectedEpoch: 7))
        XCTAssertFalse(stub.calls.contains { if case .stop = $0 { true } else { false } })
        stub.complete = true
        XCTAssertTrue(try session.finishStop(expectedEpoch: 7))
        XCTAssertEqual(stub.calls.last, .stop(StopParams(epoch: 7)))
    }

    func testCancelModeOnlyQueriesActiveJobsAfterDrain() throws {
        let stub = Stub()
        _ = try QueueSession(request: stub.send).beginStop(cancelActive: true, expectedEpoch: 7)
        XCTAssertEqual(stub.calls, [.status, .drain, .jobs(JobsParams(states: [.admitted, .running], limit: 10_000))])
    }

    func testEpochMismatchDoesNotMutateAndManagedStopSealsBeforeBootout() throws {
        let stub = Stub()
        let session = QueueSession(request: stub.send)
        XCTAssertThrowsError(try session.beginStop(cancelActive: true, expectedEpoch: 8))
        XCTAssertEqual(stub.calls, [.status])
        stub.complete = true
        XCTAssertTrue(
            try session.finishStop(
                expectedEpoch: 7,
                service: { _ in
                    return {
                        XCTAssertEqual(stub.calls.last, .stop(StopParams(epoch: 7, exitDaemon: false)))
                        stub.serviceStopped = true
                    }
                }))
        XCTAssertTrue(stub.serviceStopped)
    }
}
