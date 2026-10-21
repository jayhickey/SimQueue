// SPDX-License-Identifier: MIT

import Foundation
import SimQueueMenuBar
import SimQueueProtocol
import XCTest

final class DrainTests: XCTestCase {
    func testDrainLetsRunningWorkFinishHoldsQueuedWorkAndResumeReleasesIt() throws {
        let daemon = try TestDaemon(realProcesses: true)
        defer { daemon.destroy() }
        let go = daemon.paths.stateDir + "/go"
        let first = try daemon.submit(
            SubmitParams(
                project: "app", submitter: "test", exclusive: true, runTimeoutSeconds: 10,
                command: ["/bin/sh", "-c", "while [ ! -f '\(go)' ]; do sleep 0.02; done"])
        ).job.id
        let second = try daemon.submit(
            SubmitParams(
                project: "app", submitter: "test", exclusive: true, command: ["/bin/sh", "-c", "true"])
        ).job.id
        try eventually { try daemon.job(first).state == .running }
        guard case .status(let draining) = try daemon.result(.drain) else { return XCTFail("no status") }
        XCTAssertTrue(draining.draining)
        XCTAssertEqual(draining.drainComplete, false)
        let refused = try daemon.protocolError(.templateBuild(TemplateBuildParams(project: "drain-check")))
        XCTAssertEqual(refused.code, .invalidState)
        XCTAssertTrue(refused.message.contains("draining"), refused.message)
        XCTAssertFalse(try daemon.side.queueControl().paused, "planned drain must not persist across restart")
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(try daemon.job(first).state, .running)
        XCTAssertEqual(try daemon.job(second).state, .queued)
        FileManager.default.createFile(atPath: go, contents: nil)
        XCTAssertEqual(try daemon.wait(first).state, .succeeded)
        try eventually {
            guard case .status(let status) = try daemon.result(.status) else { return false }
            return status.drainComplete == true
        }
        XCTAssertEqual(try daemon.job(second).state, .queued)
        guard case .status(let resumed) = try daemon.result(.resume) else { return XCTFail("no status") }
        XCTAssertFalse(resumed.draining)
        XCTAssertEqual(resumed.drainComplete, false)
        XCTAssertEqual(try daemon.wait(second).state, .succeeded)
    }

    func testDrainAndResumeRoundTripThroughTheWire() throws {
        for params in [
            RequestParams.drain, .resume, .stop(StopParams(epoch: 1)), .stop(StopParams(epoch: 1, exitDaemon: false)),
        ] {
            let request = Request(params: params)
            let copy = try JSONDecoder().decode(Request.self, from: JSONEncoder().encode(request))
            XCTAssertEqual(copy, request)
        }
    }

    func testStopRequiresCompletedDrainAndMatchingEpochAndSealsResume() throws {
        let daemon = try TestDaemon()
        defer { daemon.destroy() }
        guard case .status(let initial) = try daemon.result(.status) else { return XCTFail("no status") }
        let epoch = initial.daemon.epoch
        XCTAssertEqual(try daemon.protocolError(.stop(StopParams(epoch: epoch))).code, .invalidState)
        _ = try daemon.result(.drain)
        try eventually {
            guard case .status(let status) = try daemon.result(.status) else { return false }
            return status.drainComplete == true
        }
        XCTAssertEqual(try daemon.protocolError(.stop(StopParams(epoch: epoch + 1))).code, .invalidState)
        _ = try daemon.result(.stop(StopParams(epoch: epoch, exitDaemon: false)))
        XCTAssertEqual(try daemon.protocolError(.resume).code, .invalidState)
        XCTAssertEqual(try daemon.protocolError(.gc(GCParams())).code, .invalidState)
        XCTAssertEqual(
            try daemon.protocolError(
                .submit(
                    SubmitParams(
                        project: "app", submitter: "test", command: ["/usr/bin/true"]))
            ).code, .invalidState)
        _ = try daemon.result(.stop(StopParams(epoch: epoch)))
        // A final stop acknowledgement is written before the server closes its listener.
    }

    func testAppCancelAndStopPreservesQueuedJob() throws {
        let daemon = try TestDaemon(realProcesses: true)
        defer { daemon.destroy() }
        let active = try daemon.submit(
            SubmitParams(
                project: "app", submitter: "test", exclusive: true, runTimeoutSeconds: 20,
                command: ["/bin/sh", "-c", "while :; do sleep 0.1; done"])
        ).job.id
        let queued = try daemon.submit(
            SubmitParams(
                project: "app", submitter: "test", exclusive: true, command: ["/usr/bin/true"])
        ).job.id
        try eventually { try daemon.job(active).state == .running }
        let session = QueueSession(socketPath: daemon.paths.socketPath)
        let epoch = try session.status().daemon.epoch
        _ = try session.beginStop(cancelActive: true, expectedEpoch: epoch)
        try eventually { try session.status().drainComplete == true }
        XCTAssertEqual(try daemon.job(active).state, .canceled)
        XCTAssertEqual(try daemon.job(queued).state, .queued)
        XCTAssertTrue(try session.finishStop(expectedEpoch: epoch))
        try eventually { daemon.server.isStopped }
        XCTAssertEqual(try daemon.side.job(id: queued)?.state, .queued)
    }

    private func eventually(_ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("condition did not become true")
    }
}
