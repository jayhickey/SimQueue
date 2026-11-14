// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueEngine
import SimQueueHost
import SimQueueIPC
import SimQueueProtocol
import SimQueueStore
import XCTest

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The daemon stays up through conditions that are the host's, not its own: status that
/// answers late, a cleanup that could not be confirmed yet. When it does stop, the reason
/// is on disk before the process is gone.
final class DaemonSurvivalTests: XCTestCase {
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        @discardableResult func next() -> Int {
            lock.withLock {
                value += 1; return value
            }
        }
        var count: Int { lock.withLock { value } }
    }

    /// Blocks inside `step`, which runs with the service lock held: a wedged daemon.
    private final class StalledExecutor: JobExecutor {
        var requiresCommand = false
        var drainsProcessGroups = false
        var heldJobIDs: Set<String> = []
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private var stalled = false
        func step(store: JobStore, epoch: Int64, now: Double) throws {
            if !stalled {
                stalled = true
                entered.signal()
                release.wait()
            }
        }
    }

    /// Holds the service lock for a long step while reporting progress through the
    /// engine, the way a reconcile pass working through a list does. After `release` is
    /// signalled once it goes quiet (still holding the lock): a stuck step.
    private final class WorkingExecutor: JobExecutor {
        var requiresCommand = false
        var drainsProcessGroups = false
        var heldJobIDs: Set<String> = []
        private let engineLock = NSLock()
        private var boundEngine: Engine?
        var engine: Engine? {
            get { engineLock.withLock { boundEngine } }
            set { engineLock.withLock { boundEngine = newValue } }
        }
        let entered = DispatchSemaphore(value: 0)
        let goQuiet = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private var ran = false
        func step(store: JobStore, epoch: Int64, now: Double) throws {
            guard !ran else { return }
            ran = true
            entered.signal()
            var item = 0
            while goQuiet.wait(timeout: .now() + 0.02) == .timedOut {
                item += 1
                engine?.noteProgress("directory removal \(item)")
            }
            release.wait()
        }
    }

    /// Fails its first `failures` steps with `error`, then does nothing.
    private final class FailingExecutor: JobExecutor {
        var requiresCommand = false
        var drainsProcessGroups = false
        var heldJobIDs: Set<String> = []
        let steps = Counter()
        let failures: Int
        let error: any Error
        init(failures: Int, error: any Error) {
            self.failures = failures
            self.error = error
        }
        func step(store: JobStore, epoch: Int64, now: Double) throws {
            if steps.next() <= failures { throw error }
        }
    }

    private func scratch(_ prefix: String) -> String {
        testScratchRoot() + "/\(prefix)-" + UUID().uuidString.prefix(8)
    }

    private func eventually(_ what: String, timeout: Double = 5, _ condition: () throws -> Bool) rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Keeps the daemon doing real work (each request takes the service lock) for `seconds`.
    private func keepBusy(_ daemon: TestDaemon, seconds: Double, until done: () -> Bool = { false }) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            _ = try daemon.result(.status)
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    // MARK: - Liveness

    func testUnansweredStatusDoesNotExitADaemonThatIsStillWorking() throws {
        let exits = Counter()
        let lines = Lines()
        let daemon = try TestDaemon(configureServer: {
            $0.livenessIntervalSeconds = 0.02
            $0.livenessTimeoutSeconds = 0.02
            $0.livenessFailureSeconds = 0.5
            $0.livenessStarvedSeconds = 600
            // Every probe times out, as it does when the host is far over its CPU capacity.
            $0.livenessProbe = { false }
            $0.livenessFailure = { _ in exits.next() }
            $0.livenessLog = { lines.append($0) }
        })
        defer { daemon.destroy() }
        let job = try daemon.submit(SubmitParams(project: "busy", submitter: "test", minSims: 0)).job
        try keepBusy(daemon, seconds: 2)
        XCTAssertEqual(exits.count, 0, "four times the failure window passed; the daemon was working throughout")
        XCTAssertEqual(try daemon.wait(job.id).state, .succeeded, "and its jobs were never interrupted")
        XCTAssertEqual(
            lines.all.filter { $0.contains("not restarting") }.count, 1, "said once, not on every probe: \(lines.all)")
    }

    func testASocketThatStaysUnusableEventuallyExitsWithItsReason() throws {
        let reasons = Lines()
        let daemon = try TestDaemon(configureServer: {
            $0.livenessIntervalSeconds = 0.02
            $0.livenessTimeoutSeconds = 0.02
            $0.livenessFailureSeconds = 0.5
            $0.livenessStarvedSeconds = 1.5
            $0.livenessProbe = { false }
            $0.livenessFailure = { reasons.append($0) }
            $0.livenessLog = { _ in }
        })
        defer { daemon.destroy() }
        try keepBusy(daemon, seconds: 10) { !reasons.all.isEmpty }
        let reason = try XCTUnwrap(reasons.all.first)
        XCTAssertTrue(reason.contains("the socket is unusable"), reason)
        XCTAssertFalse(reason.contains("wedged"), reason)
    }

    func testAStuckServiceLockIsStillAWedgeAndSaysSo() throws {
        let executor = StalledExecutor()
        let reasons = Lines()
        let daemon = try TestDaemon(
            executorOverride: executor,
            configureServer: {
                $0.livenessIntervalSeconds = 0.05
                $0.livenessTimeoutSeconds = 0.05
                $0.livenessFailureSeconds = 0.3
                $0.livenessFailure = { reasons.append($0) }
            })
        defer { executor.release.signal(); daemon.destroy() }
        XCTAssertEqual(executor.entered.wait(timeout: .now() + 2), .success)
        eventually("the wedge is detected") { !reasons.all.isEmpty }
        let reason = try XCTUnwrap(reasons.all.first)
        XCTAssertTrue(reason.contains("the daemon is wedged"), reason)
        XCTAssertTrue(reason.contains("service lock idle"), reason)
        // The reason names what was holding the lock: the fact a post-mortem needs.
        XCTAssertTrue(reason.contains("service lock held by tick(), executor step, for "), reason)
    }

    func testAStepThatHoldsTheLockButKeepsMovingIsNotAWedgeUntilItStops() throws {
        let executor = WorkingExecutor()
        let reasons = Lines()
        let daemon = try TestDaemon(
            executorOverride: executor,
            configureServer: {
                $0.livenessIntervalSeconds = 0.05
                $0.livenessTimeoutSeconds = 0.05
                $0.livenessFailureSeconds = 0.4
                $0.livenessStarvedSeconds = 600
                $0.livenessFailure = { reasons.append($0) }
                $0.livenessLog = { _ in }
            })
        executor.engine = daemon.engine
        defer { executor.goQuiet.signal(); executor.release.signal(); daemon.destroy() }
        XCTAssertEqual(executor.entered.wait(timeout: .now() + 2), .success)
        // Status cannot be answered (the lock is held throughout), but the holder keeps
        // reaching its next item: slow, not stuck.
        Thread.sleep(forTimeInterval: 1.6)
        XCTAssertEqual(reasons.all, [], "four failure windows of honest work")
        // It stops moving while still holding the lock: now it is a wedge.
        executor.goQuiet.signal()
        eventually("the stuck step is detected") { !reasons.all.isEmpty }
        let reason = try XCTUnwrap(reasons.all.first)
        XCTAssertTrue(reason.contains("the daemon is wedged"), reason)
        XCTAssertTrue(reason.contains("service lock held by tick(), directory removal "), reason)
    }

    func testTheDaemonGivesUpOnItsSocketWellBeforeItsClientsGiveUpOnIt() {
        // A client whose socket went quiet when the starvation began must still be
        // reconnecting when the restarted daemon answers, or it abandons a job that is
        // about to be requeued.
        XCTAssertLessThanOrEqual(
            DaemonServer.defaultLivenessStarvedSeconds + DaemonServer.restartAllowanceSeconds,
            ClientReconnect.defaultSeconds - 120,
            "the daemon's limit plus a restart must end at least two minutes inside the clients' window")
        XCTAssertGreaterThanOrEqual(DaemonServer.restartAllowanceSeconds, 60)
    }

    func testTheLastWordsDeadlineFiresEvenIfRecordingNeverReturns() {
        let fired = expectation(description: "hard exit")
        let blocked = DispatchSemaphore(value: 0)
        HardExit.arm(after: 0.05) { fired.fulfill() }
        // The stand-in for a log flush or a state file write on a stalled disk.
        _ = blocked.wait(timeout: .now() + 0.5)
        wait(for: [fired], timeout: 2)
        XCTAssertLessThanOrEqual(HardExit.lastWordsSeconds, 10, "a wedged daemon is not kept waiting long")
    }

    func testTimeTheDaemonWasNotRunningIsNotCountedAsAWedge() throws {
        let exits = Counter()
        let probes = Counter()
        let start = ProcessInfo.processInfo.systemUptime
        let daemon = try TestDaemon(configureServer: {
            $0.livenessIntervalSeconds = 0.02
            $0.livenessTimeoutSeconds = 0.02
            $0.livenessFailureSeconds = 5
            // One probe fails just as the clock jumps an hour: the process was not
            // scheduled (or the host slept). Nothing was observed standing still.
            $0.livenessProbe = { probes.next() != 3 }
            $0.livenessUptime = {
                ProcessInfo.processInfo.systemUptime - start + (probes.count >= 3 ? 3_600 : 0)
            }
            $0.livenessFailure = { _ in exits.next() }
        })
        defer { daemon.destroy() }
        eventually("probes continue past the jump") { probes.count >= 8 }
        XCTAssertEqual(exits.count, 0)
    }

    // MARK: - Tick errors

    func testACleanupThatCouldNotBeVerifiedDoesNotStopTheDaemon() throws {
        let executor = FailingExecutor(failures: 3, error: EngineError.cleanupNotVerified("process group 4242"))
        let daemon = try TestDaemon(executorOverride: executor)
        defer { daemon.destroy() }
        // An active job keeps the tick loop at its working cadence.
        _ = try daemon.submit(SubmitParams(project: "active", submitter: "test", minSims: 0))
        eventually("ticks continue after the failures") { executor.steps.count >= 6 }
        XCTAssertFalse(daemon.server.isStopped)
        XCTAssertNil(daemon.server.failure)
        _ = try daemon.result(.status)
    }

    func testAProcessTableThatCannotBeReadDoesNotStopTheDaemon() throws {
        let executor = FailingExecutor(
            failures: 3, error: ProcessControlError.system(call: "sysctl(KERN_PROC)", errno: ENOMEM))
        let daemon = try TestDaemon(executorOverride: executor)
        defer { daemon.destroy() }
        _ = try daemon.submit(SubmitParams(project: "active", submitter: "test", minSims: 0))
        eventually("ticks continue after the failures") { executor.steps.count >= 6 }
        XCTAssertFalse(daemon.server.isStopped)
    }

    func testALostLeaseStillStopsTheDaemonAndNamesTheReason() throws {
        let daemon = try TestDaemon()
        defer { daemon.destroy() }
        _ = try daemon.side.acquireDaemonLease(ownerID: "another daemon", pid: 2, now: Date().timeIntervalSince1970)
        eventually("the daemon stops") { daemon.server.isStopped }
        let failure = try XCTUnwrap(daemon.server.failure)
        XCTAssertTrue(failure.contains("daemon lease lost"), failure)
    }

    func testOnlyALostLeaseIsADaemonStoppingEngineError() {
        XCTAssertTrue(EngineError.lostLease(epoch: 3).stopsDaemon)
        XCTAssertFalse(EngineError.cleanupNotVerified("sim X").stopsDaemon)
    }

    // MARK: - Stop records

    private func eventLines(_ daemon: TestDaemon) -> [[String: Any]] {
        let text = (try? String(contentsOfFile: daemon.paths.stateDir + "/events.jsonl", encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    private func audits(_ daemon: TestDaemon, _ type: String) throws -> [AuditEntry] {
        try daemon.side.auditEntries().filter { $0.type == type }
    }

    func testAStopIsRecordedOnDiskInTheAuditLogAndInTheEventLog() throws {
        let daemon = try TestDaemon()
        defer { daemon.destroy() }
        let record = daemon.service.recordStop(reason: "daemon lease lost (epoch 1 is no longer current)", exitCode: 70)
        XCTAssertTrue(record.audited)
        XCTAssertEqual(record.epoch, daemon.engine.epoch)
        XCTAssertEqual(DaemonStopRecord.read(stateDirectory: daemon.paths.stateDir), record)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: DaemonStopRecord.path(stateDirectory: daemon.paths.stateDir))
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let audited = try audits(daemon, DaemonStopRecord.auditType)
        XCTAssertEqual(audited.count, 1)
        XCTAssertTrue(audited[0].detail?.contains("with status 70: daemon lease lost") == true, audited[0].detail ?? "")
        let events = eventLines(daemon).filter { $0["type"] as? String == DaemonStopRecord.auditType }
        XCTAssertEqual(events.count, 1, "written to events.jsonl before the process ends, not at the next tick")
        XCTAssertNil(events[0]["job_id"])
        XCTAssertEqual(events[0]["detail"] as? String, record.summary)
    }

    func testADaemonThatLostItsLeaseWritesNothingToStateItNoLongerOwns() throws {
        let daemon = try TestDaemon()
        defer { daemon.destroy() }
        _ = try daemon.side.acquireDaemonLease(ownerID: "another daemon", pid: 2, now: Date().timeIntervalSince1970)
        eventually("the daemon stops") { daemon.server.isStopped }
        let before = try daemon.side.auditEntries().count
        let events = eventLines(daemon).count
        let record = daemon.service.recordStop(reason: try XCTUnwrap(daemon.server.failure), exitCode: 70)
        XCTAssertFalse(record.audited)
        XCTAssertEqual(try daemon.side.auditEntries().count, before, "no audit row on another daemon's database")
        XCTAssertEqual(eventLines(daemon).count, events, "and nothing appended to its event log")
        XCTAssertEqual(
            DaemonStopRecord.read(stateDirectory: daemon.paths.stateDir)?.reason, record.reason,
            "its own stop record is still written")
    }

    // MARK: - Restart-loop breaker

    func testTheRestartBreakerCountsOnlyUnplannedStartsInsideItsWindow() {
        let policy = RestartBreakerPolicy(limit: 3, windowSeconds: 900)
        XCTAssertEqual(policy.status(restartTimes: [100, 200], clearedAt: nil, now: 300), .normal)
        XCTAssertEqual(
            policy.status(restartTimes: [100, 200, 300], clearedAt: nil, now: 300),
            .tripped(restarts: 3, windowSeconds: 900))
        XCTAssertEqual(
            policy.status(restartTimes: [100, 200, 300], clearedAt: nil, now: 1_050), .normal,
            "the oldest start aged out")
        XCTAssertEqual(
            policy.status(restartTimes: [100, 200, 300], clearedAt: 250, now: 300), .normal,
            "simq resume forgets earlier starts")
        XCTAssertEqual(
            RestartBreakerPolicy(limit: 0).status(restartTimes: [1, 2, 3, 4], clearedAt: nil, now: 5), .normal,
            "0 turns it off")
        XCTAssertEqual(RestartBreakerPolicy().limit, 3)
        XCTAssertEqual(RestartBreakerPolicy().windowSeconds, 900)
    }

    func testUnplannedRestartsHoldAdmissionsAndPlannedOnesDoNot() throws {
        let dir = scratch("sqb")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Three clean stop-and-start cycles: nothing is counted.
        var daemon = try TestDaemon(stateDir: dir)
        for _ in 0..<3 {
            daemon.service.recordStop(reason: "requested (SIGTERM)", exitCode: 0)
            daemon.stop()
            daemon = try TestDaemon(stateDir: dir)
            daemon.service.reportPreviousStop(previousPID: 1, heartbeatAgeSeconds: 1)
        }
        XCTAssertTrue(try audits(daemon, RestartBreakerPolicy.auditType).isEmpty)
        let fine = try daemon.submit(SubmitParams(project: "ok", submitter: "test", minSims: 0)).job
        XCTAssertEqual(try daemon.wait(fine.id).state, .succeeded)

        // Three starts after a daemon that failed or vanished: admissions are held.
        for cycle in 0..<3 {
            if cycle == 0 { daemon.service.recordStop(reason: "socket liveness: the daemon is wedged", exitCode: 70) }
            daemon.stop()
            daemon = try TestDaemon(stateDir: dir)
            daemon.service.reportPreviousStop(previousPID: 1, heartbeatAgeSeconds: 40)
        }
        defer { daemon.destroy() }
        XCTAssertEqual(try audits(daemon, RestartBreakerPolicy.auditType).count, 3)
        let held = try daemon.submit(SubmitParams(project: "held", submitter: "test", minSims: 0)).job
        try eventually("the breaker shows in status") {
            guard case .status(let status) = try daemon.result(.status) else { return false }
            return status.globalWaitReasons.contains { $0.code == "restart_loop" }
        }
        XCTAssertEqual(try daemon.job(held.id).state, .queued)
        XCTAssertEqual(try daemon.job(held.id).waitReasons.first?.code, "restart_loop")

        _ = try daemon.result(.resume)
        XCTAssertEqual(try daemon.wait(held.id).state, .succeeded, "simq resume clears it")
    }

    func testAWedgedDaemonStillLeavesItsReasonAndTheNextDaemonAuditsIt() throws {
        let dir = scratch("sqw")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let executor = StalledExecutor()
        let wedged = try TestDaemon(stateDir: dir, executorOverride: executor)
        XCTAssertEqual(executor.entered.wait(timeout: .now() + 2), .success)
        // The tick holds the service lock and will not let go: no audit entry is possible.
        let reason =
            "socket liveness: status unanswered for 30s and the service lock idle for 30s; the daemon is wedged"
        let started = ProcessInfo.processInfo.systemUptime
        let record = wedged.service.recordStop(reason: reason, exitCode: 70, lockTimeout: 0.2)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2, "never waits on the wedged lock")
        XCTAssertFalse(record.audited)
        XCTAssertEqual(DaemonStopRecord.read(stateDirectory: dir)?.reason, reason)
        XCTAssertTrue(try audits(wedged, DaemonStopRecord.auditType).isEmpty)
        executor.release.signal()
        wedged.stop()

        let next = try TestDaemon(stateDir: dir)
        defer { next.destroy() }
        let line = try XCTUnwrap(next.service.reportPreviousStop(previousPID: 1, heartbeatAgeSeconds: 31))
        XCTAssertTrue(line.hasPrefix("previous daemon: epoch \(wedged.engine.epoch) pid 1 stopped at "), line)
        XCTAssertTrue(line.hasSuffix("with status 70: \(reason)"), line)
        let audited = try audits(next, DaemonStopRecord.auditType)
        XCTAssertEqual(audited.count, 1)
        XCTAssertTrue(audited[0].detail?.hasSuffix("(audited by the next daemon)") == true, audited[0].detail ?? "")
        XCTAssertEqual(DaemonStopRecord.read(stateDirectory: dir)?.audited, true)
        eventually("the stop reaches events.jsonl") {
            eventLines(next).contains { $0["type"] as? String == DaemonStopRecord.auditType }
        }
        _ = next.service.reportPreviousStop(previousPID: 1, heartbeatAgeSeconds: 31)
        XCTAssertEqual(try audits(next, DaemonStopRecord.auditType).count, 1, "audited once")
    }

    func testAPreviousDaemonThatLeftNoRecordIsReportedAsAnUnrecordedExit() throws {
        let dir = scratch("squ")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let first = try TestDaemon(stateDir: dir)
        XCTAssertNil(
            first.service.reportPreviousStop(previousPID: nil, heartbeatAgeSeconds: nil),
            "the first daemon of a state directory has no predecessor")
        first.service.recordStop(reason: "requested (SIGTERM)", exitCode: 0)
        first.stop()

        // The second daemon is killed: it never gets to record anything.
        let killed = try TestDaemon(stateDir: dir)
        let clean = try XCTUnwrap(killed.service.reportPreviousStop(previousPID: 1, heartbeatAgeSeconds: 2))
        XCTAssertTrue(clean.hasSuffix("with status 0: requested (SIGTERM)"), clean)
        killed.stop()

        let third = try TestDaemon(stateDir: dir)
        defer { third.destroy() }
        let line = try XCTUnwrap(third.service.reportPreviousStop(previousPID: 4242, heartbeatAgeSeconds: 61.6))
        XCTAssertTrue(line.contains("epoch \(killed.engine.epoch) pid 4242 left no stop record"), line)
        XCTAssertTrue(line.contains("last heartbeat was 62s before this start"), line)
        XCTAssertEqual(
            try audits(third, DaemonStopRecord.unrecordedAuditType).count, 1,
            "the older daemon's record is not mistaken for this one's")
        eventually("the unrecorded exit reaches events.jsonl") {
            eventLines(third).contains { $0["type"] as? String == DaemonStopRecord.unrecordedAuditType }
        }
    }

    // MARK: - Daemon log

    func testOutputStillInThePipeAndTheFinalLineBothReachTheLog() throws {
        let dir = scratch("sql")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/simqd.log"
        let logger = try RotatingDaemonLog(path: path)
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        let finished = logger.pump(from: descriptors[0])
        // The final line is written straight to the file and is there at once, whether
        // or not the reader thread has run.
        XCTAssertTrue(logger.appendDurably(Data("simqd: stopped: daemon lease lost\n".utf8)))
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains("simqd: stopped: daemon lease lost"))
        let earlier = Array("simqd: tick failed: example\n".utf8)
        XCTAssertEqual(write(descriptors[1], earlier, earlier.count), earlier.count)
        // Draining: close the writer, wait for the reader to finish what was in the pipe.
        close(descriptors[1])
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("simqd: tick failed: example"), text)
    }
}
