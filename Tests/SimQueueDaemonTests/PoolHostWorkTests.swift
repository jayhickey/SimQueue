// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueEngine
import SimQueueProtocol
import SimQueueSim
import XCTest

/// Slow pool host work must not block lease requests or supervision. Create and boot
/// run without the service lock; delayed fake backends stand in for simulator tools.
final class PoolHostWorkTests: XCTestCase {
    private func slowPoolDaemon(createDelay: Double, bootDelay: Double) throws -> TestDaemon {
        var config = DaemonConfig()
        var pool = SimPoolConfig()
        pool.maxSims = 1
        pool.maxConcurrentBoots = 1
        pool.settle.mode = .off
        config.pool = pool
        config.reliability.cleanupMode = .enforce  // the pool takes no host action in report-only
        let daemon = try TestDaemon(config: config)
        daemon.sims.createDelaySeconds = createDelay
        daemon.sims.bootDelaySeconds = bootDelay
        return daemon
    }

    private func lease(_ daemon: TestDaemon, _ holder: String) throws -> LeaseResult {
        guard case .lease(let result) = try daemon.result(.leaseAcquire(LeaseAcquireParams(holder: holder))) else {
            throw TestFailure("not a lease result")
        }
        return result
    }

    /// Milliseconds in a `duration_ms=<n>` audit detail.
    private func durationMS(_ detail: String?) -> Int? {
        guard let detail, let range = detail.range(of: "duration_ms=") else { return nil }
        return Int(detail[range.upperBound...].prefix { $0.isNumber })
    }

    func testDaemonAnswersRequestsDuringASlowCreateAndBoot() throws {
        let daemon = try slowPoolDaemon(createDelay: 4, bootDelay: 4)
        defer { daemon.destroy() }
        XCTAssertEqual(try lease(daemon, "ci-1").state, "pending", "no sim yet: the request becomes demand")

        // Poll status over the socket through the whole create and boot (8 s of host work).
        // Margins sized for a loaded CI Mac: with the lock held, every request in a phase
        // waits up to 4 s and only a handful get through; unlocked, answers are immediate.
        var slowest = 0.0
        var answered = 0
        var sawBooting = false
        var granted: LeaseResult?
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            let start = Date()
            guard case .status = try daemon.result(.status) else { throw TestFailure("not a status result") }
            slowest = max(slowest, Date().timeIntervalSince(start))
            answered += 1
            if try daemon.side.poolSims().contains(where: { $0.phase == .booting }) { sawBooting = true }
            let result = try lease(daemon, "ci-1")
            if result.state == "granted" {
                granted = result
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertNotNil(granted, "the sim was created, booted and leased")
        XCTAssertTrue(sawBooting, "a status answer arrived while the boot was running")
        XCTAssertGreaterThanOrEqual(answered, 4, "requests kept being answered during 8 s of host work")
        XCTAssertLessThan(slowest, 3, "no request waited out the 4 s create or boot")

        // Real durations in the audit.
        let entries = try daemon.side.auditEntries()
        let created = try XCTUnwrap(entries.first { $0.type == "pool_created" })
        let booted = try XCTUnwrap(entries.first { $0.type == "pool_booted" })
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(durationMS(created.detail), created.detail ?? ""), 3900)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(durationMS(booted.detail), booted.detail ?? ""), 3900)
    }

    /// The worker may block for six seconds; all unrelated supervision must progress
    /// inside three seconds, including SIGKILL escalation and queued admission.
    func testSlowBootDoesNotStallCompletionTimeoutCancellationOrBuildAdmission() throws {
        var config = DaemonConfig()
        config.scheduler.maxRunningPerProject = 3
        config.timeouts.killGraceSeconds = 0.15
        var pool = SimPoolConfig()
        pool.maxSims = 1
        pool.settle.mode = .off
        config.pool = pool
        config.reliability.cleanupMode = .enforce
        let daemon = try TestDaemon(config: config, realProcesses: true)
        defer { daemon.destroy() }
        daemon.sims.bootDelaySeconds = 6
        func submit(_ shell: String, timeout: Double? = nil) throws -> JobInfo {
            try daemon.submit(
                SubmitParams(
                    project: "supervision", submitter: "test", minSims: 0,
                    runTimeoutSeconds: timeout, command: ["/bin/sh", "-c", shell])
            ).job
        }
        let completed = try submit("sleep 1.2")
        let timed = try submit("trap '' TERM; while :; do sleep 0.1; done", timeout: 1.5)
        let cancellationReady = daemon.paths.stateDir + "/cancel-ready"
        let cancelled = try submit("trap '' TERM; touch '\(cancellationReady)'; while :; do sleep 0.1; done")
        let setupDeadline = Date().addingTimeInterval(5)
        while try [completed, timed, cancelled].contains(where: { try daemon.job($0.id).state != .running }) {
            guard Date() < setupDeadline else { return XCTFail("commands did not start") }
            Thread.sleep(forTimeInterval: 0.01)
        }
        while !FileManager.default.fileExists(atPath: cancellationReady) {
            guard Date() < setupDeadline else { return XCTFail("cancellation trap did not install") }
            Thread.sleep(forTimeInterval: 0.01)
        }
        _ = try lease(daemon, "slow-boot")
        while try !daemon.side.poolSims().contains(where: { $0.phase == .booting }) {
            guard Date() < setupDeadline else { return XCTFail("slow boot did not start") }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let cancelledGroup = try XCTUnwrap(
            daemon.side.resources(jobID: cancelled.id).first { $0.kind == .processGroup })
        let cancelledPGID = try XCTUnwrap(Int32(cancelledGroup.externalID))
        let started = Date()
        let build = try submit("exit 0")
        XCTAssertEqual(build.state, .queued, "three active commands fill the explicit project cap")
        _ = try daemon.result(.cancel(CancelParams(jobID: cancelled.id)))
        let deadline = started.addingTimeInterval(3)
        while try [completed, timed, cancelled, build].contains(where: { try !daemon.job($0.id).state.isTerminal })
            || daemon.engine.environment.processes.liveProcessGroups().contains(cancelledPGID)
        {
            guard Date() < deadline else {
                return XCTFail("supervision or admission stalled behind the six-second boot")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(try daemon.job(completed.id).state, .succeeded)
        XCTAssertEqual(try daemon.job(timed.id).state, .timedOut)
        XCTAssertNotNil(try daemon.job(timed.id).killSentAt, "timeout escalated while boot remained blocked")
        XCTAssertEqual(try daemon.job(cancelled.id).state, .canceled)
        XCTAssertTrue(
            try daemon.side.auditEntries().contains {
                $0.type == "leftover_kill" && $0.resourceID == cancelledGroup.id
            }, "cancellation escalated and its process group stopped while boot remained blocked")
        XCTAssertEqual(try daemon.job(build.id).state, .succeeded)
        XCTAssertTrue(try daemon.side.poolSims().contains { $0.phase == .booting })
        XCTAssertFalse(try daemon.side.auditEntries().contains { $0.type == "pool_booted" })
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testLeaseRequestsDuringABootStayPendingAndNoSecondCreateStarts() throws {
        let daemon = try slowPoolDaemon(createDelay: 0, bootDelay: 3)
        defer { daemon.destroy() }
        _ = try lease(daemon, "ci-1")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, try !daemon.side.poolSims().contains(where: { $0.phase == .booting }) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        // While the tick thread is inside the unlocked boot, a second holder asks: it waits,
        // and max_sims=1 keeps the pool at one sim.
        let second = try lease(daemon, "ci-2")
        XCTAssertEqual(second.state, "pending")
        XCTAssertEqual(second.poolState, "booting")
        XCTAssertEqual(try daemon.side.poolSims().count, 1)
    }
}
