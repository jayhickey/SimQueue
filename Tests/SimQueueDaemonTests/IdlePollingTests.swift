// SPDX-License-Identifier: MIT
import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueProtocol
import SimQueueStore
import XCTest

final class IdlePollingTests: XCTestCase {
    /// Completes a zero-cost fake workload in its admission tick so the wake assertion
    /// measures the socket/semaphore path, independently of child-process polling.
    private final class ImmediateExecutor: JobExecutor {
        var requiresCommand = false
        var drainsProcessGroups = false
        var heldJobIDs: Set<String> = []
        func step(store: JobStore, epoch: Int64, now: Double) throws {
            for job in try store.activeJobs() where job.state == .admitted && !heldJobIDs.contains(job.id) {
                guard try store.markRunning(jobID: job.id, pid: nil, epoch: epoch, now: now) else { continue }
                _ = try store.finish(jobID: job.id, result: .success, now: now)
            }
        }
    }

    func testIdleTicksBackOffAndSubmissionWakesBeforeTheIdleDeadline() throws {
        let daemon = try TestDaemon(executorOverride: ImmediateExecutor(), tickIntervalOverride: 1)
        defer { daemon.destroy() }
        let firstDeadline = ProcessInfo.processInfo.systemUptime + 3
        var observed: Timestamp?
        while observed == nil && ProcessInfo.processInfo.systemUptime < firstDeadline {
            guard case .status(let status) = try daemon.result(.status) else { return XCTFail("no status") }
            observed = status.lastTickAt
            if observed == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        let firstTick = try XCTUnwrap(observed)
        XCTAssertEqual(daemon.service.nextTickInterval, 5)
        Thread.sleep(forTimeInterval: 0.25)
        guard case .status(let idle) = try daemon.result(.status) else { return XCTFail("no status") }
        XCTAssertEqual(idle.lastTickAt, firstTick, "an idle service must not keep its active polling cadence")

        let submittedAt = ProcessInfo.processInfo.systemUptime
        let job = try daemon.submit(SubmitParams(project: "idle-wake", submitter: "test", minSims: 0)).job
        var completed = try daemon.job(job.id)
        while !completed.state.isTerminal && ProcessInfo.processInfo.systemUptime - submittedAt < 1 {
            Thread.sleep(forTimeInterval: 0.01)
            completed = try daemon.job(job.id)
        }
        XCTAssertEqual(completed.state, .succeeded, "submission must wake the five-second idle wait within one second")
        XCTAssertNotNil(completed.startedAt)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - submittedAt, 1)
        guard case .status(let after) = try daemon.result(.status) else { return XCTFail("no status") }
        XCTAssertGreaterThan(try XCTUnwrap(after.lastTickAt), firstTick)
    }

    func testTerminalJobWithLiveProcessOwnershipKeepsTheSupervisionInterval() throws {
        let daemon = try TestDaemon(tickIntervalOverride: 0.02)
        defer { daemon.destroy() }
        // Freeze the server threads; use a separate store connection to model a process
        // whose job ended before its owned process group finished cleanup.
        daemon.stop()
        XCTAssertEqual(daemon.service.nextTickInterval, 1)
        let now = Date().timeIntervalSince1970
        var resource: OwnedResource!
        try daemon.side.database.immediateTransaction {
            let job = try daemon.side.submit(JobSubmission(project: "cleanup", submitter: "test"), now: now).job
            _ = try daemon.side.claim(jobID: job.id, grantedSims: 0, epoch: daemon.engine.epoch, now: now)
            resource = try daemon.side.acquireResource(
                kind: .processGroup, externalID: "4242", owner: .job(job.id), epoch: daemon.engine.epoch, now: now)
            _ = try daemon.side.cancel(jobID: job.id, now: now)
        }
        daemon.processes.spawn(4242)
        XCTAssertTrue(try daemon.side.activeJobs().isEmpty)
        XCTAssertTrue(try daemon.side.queuedJobs().isEmpty)
        XCTAssertEqual(
            daemon.service.nextTickInterval, 0.02, "terminal ownership still needs prompt process supervision")
        daemon.processes.exit(4242)
        try daemon.side.markResourceReleased(id: resource.id, reason: "verified exited", now: now + 1)
        XCTAssertEqual(
            daemon.service.nextTickInterval, 1, "idle backoff is safe only after the ownership row is released")
    }
}
