// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueIPC
import SimQueueProtocol
import SimQueueSim
import SimQueueStore
import XCTest

/// §8a.5 chaos scenarios against the running daemon (real socket; fake sims; real
/// processes only for jobs the test itself starts).
final class DaemonChaosTests: XCTestCase {
    var daemon: TestDaemon?

    override func tearDown() {
        daemon?.destroy()
    }

    private func eventually(
        _ what: String, timeout: Double = 10, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () throws -> Bool
    ) rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    func testAHungSimBackendDegradesHealthAndIsRetriedAtTheIntervalNotEveryTick() throws {
        var config = DaemonConfig()
        config.watchdog.lightIntervalSeconds = 0.2
        config.watchdog.fullIntervalSeconds = 0.2
        let made = try TestDaemon(config: config)
        daemon = made
        made.sims.listFailure = .timedOut("simctl list devices")
        try eventually("a failed pass") {
            try made.side.auditEntries().contains { $0.type == "watchdog_pass_failed" }
        }
        guard case .status(let status) = try made.result(.status) else { return XCTFail("not status") }
        let health = try XCTUnwrap(status.health)
        XCTAssertEqual(health.health, "degraded")
        XCTAssertTrue(health.reasons.contains { $0.hasPrefix("last watchdog pass failed: ") }, "\(health.reasons)")
        XCTAssertNotNil(health.lastPassError)
        let job = try made.submit(SubmitParams(project: "app", submitter: "dev")).job
        XCTAssertEqual(try made.wait(job.id).state, .succeeded, "scheduling carries on")

        Thread.sleep(forTimeInterval: 0.5)
        let failures = try made.side.auditEntries().filter { $0.type == "watchdog_pass_failed" }.count
        XCTAssertLessThanOrEqual(failures, 6, "one attempt per interval (~0.7 s / 0.2 s), not one per 20 ms tick")

        made.sims.listFailure = nil
        try eventually("recovered") { try made.side.watchdogState().lastPassError == nil }
        // health.json is rewritten right after the pass that recorded it.
        try eventually("health.json recovered") {
            let healthFile = try JSONDecoder().decode(
                HealthInfo.self, from: Data(contentsOf: URL(fileURLWithPath: made.paths.healthPath)))
            return healthFile.lastPassError == nil
        }
    }

    func testAStreamingWaitClientThatVanishesDoesNotHurtTheDaemonOrTheJob() throws {
        let made = try TestDaemon()
        daemon = made
        try made.side.setPaused(true)
        let job = try made.submit(SubmitParams(project: "app", submitter: "dev")).job
        // Take the first event, then hang up mid-stream.
        let response = try SimQueueClientForTests.waitAndHangUp(made.paths.socketPath, jobID: job.id)
        XCTAssertNil(response)
        try made.side.resume(now: Date().timeIntervalSince1970)
        XCTAssertEqual(try made.wait(job.id).state, .succeeded, "the job never noticed")
        guard case .status = try made.result(.status) else { return XCTFail("daemon stopped answering") }
    }

    func testAJobKilledMidRunEndsFailedWithTheSignalAndItsGroupIsReleased() throws {
        var config = DaemonConfig()
        config.timeouts.killGraceSeconds = 0.5
        let made = try TestDaemon(config: config, realProcesses: true)
        daemon = made
        let id = try made.submit(
            SubmitParams(project: "app", submitter: "dev", command: ["/bin/sh", "-c", "sleep 30"])
        ).job.id
        try eventually("running") { try made.job(id).state == .running }
        let resource = try XCTUnwrap(try made.side.resources(jobID: id).first { $0.kind == .processGroup })
        let pgid = try XCTUnwrap(Int32(resource.externalID))
        XCTAssertEqual(killpg(pgid, SIGKILL), 0)  // killed from outside SimQueue
        let job = try made.wait(id)
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.commandExitCode, 128 + SIGKILL)
        try eventually("group released") {
            try made.side.resources(jobID: id).allSatisfy { $0.state == .released }
        }
    }
}

/// A raw client that reads one streamed event and closes the connection.
enum SimQueueClientForTests {
    static func waitAndHangUp(_ socketPath: String, jobID: String) throws -> Response? {
        try SimQueueClient(socketPath: socketPath, timeoutSeconds: 0).send(
            Request(params: .wait(WaitParams(jobID: jobID, stream: true))),
            deadline: Date().timeIntervalSince1970 + 5
        ) { _ in false }
    }
}
