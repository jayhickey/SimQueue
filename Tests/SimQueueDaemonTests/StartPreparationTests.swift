// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueIPC
import SimQueueProtocol
import SimQueueStore
import XCTest

@testable import SimQueueDaemon

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Tiny real commands and deterministic filesystem boundaries; no simulator or SDK work.
final class StartPreparationTests: XCTestCase {
    private final class Gate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var used = false
        let stage: ProcessExecutor.PreparationStage

        init(_ stage: ProcessExecutor.PreparationStage) { self.stage = stage }

        func pause(_ stage: ProcessExecutor.PreparationStage) {
            lock.lock()
            let block = stage == self.stage && !used
            if block { used = true }
            lock.unlock()
            if block {
                entered.signal()
                _ = resume.wait(timeout: .now() + 15)
            }
        }
    }

    private func eventually(
        _ description: String, timeout: Double = 3, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () throws -> Bool
    ) rethrows {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.02)
        } while ProcessInfo.processInfo.systemUptime < deadline
        XCTFail("timed out waiting for \(description)", file: file, line: line)
    }

    private func result(_ daemon: TestDaemon, _ params: RequestParams) throws -> ResultPayload {
        let client = SimQueueClient(socketPath: daemon.paths.socketPath, timeoutSeconds: 1)
        let response = try XCTUnwrap(client.send(Request(params: params)))
        guard case .result(let result) = response.body else { throw TestFailure("unexpected \(response.body)") }
        return result
    }

    private func status(_ daemon: TestDaemon) throws -> StatusResult {
        guard case .status(let status) = try result(daemon, .status) else { throw TestFailure("not status") }
        return status
    }

    private func checkBlockedPreparation(_ stage: ProcessExecutor.PreparationStage) throws {
        var config = DaemonConfig()
        config.reliability.cleanupMode = .enforce
        config.reliability.ageRules.artifactRetention.budgetBytes = 1
        let fs = FakeFileSystem()
        let daemon = try TestDaemon(config: config, realProcesses: true, fileSystemOverride: fs)
        let gate = Gate(stage)
        defer { gate.resume.signal(); daemon.destroy() }
        try XCTUnwrap(daemon.processExecutor).beforePreparationStage = { gate.pause($0) }
        let marker = daemon.paths.stateDir + "/command-started"
        let job = try daemon.submit(
            SubmitParams(
                project: "prepare", submitter: "test", minSims: 0,
                command: ["/bin/sh", "-c", "echo started > '\(marker)'"])
        ).job
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        let before = try XCTUnwrap(status(daemon).lastTickAt)
        try eventually("ticks while preparation is blocked") {
            try XCTUnwrap(status(daemon).lastTickAt) > before
        }
        XCTAssertEqual(try daemon.job(job.id).state, .admitted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
        XCTAssertTrue(try daemon.side.resources(jobID: job.id).isEmpty, "no spawn intent before preparation finishes")

        // Cancel remains a socket operation, even though the worker cannot yet return.
        _ = try result(daemon, .cancel(CancelParams(jobID: job.id)))
        XCTAssertEqual(try daemon.job(job.id).state, .canceled)
        let directory = JobArtifacts(root: daemon.paths.jobsRoot).directory(
            jobID: job.id, createdAt: job.queueTime.epochSeconds)
        let logPath = directory + "/combined.log"
        if stage == .logOpen {
            XCTAssertEqual(mkfifo(logPath, 0o600), 0)
        }
        defer {
            if stage == .logOpen {
                // Also unblock an accidental FIFO reader if this regression fails.
                let writer = open(logPath, O_WRONLY | O_NONBLOCK)
                if writer >= 0 { close(writer) }
                _ = unlink(logPath)
            }
        }
        guard case .logs(let logs) = try result(daemon, .logs(LogsParams(jobID: job.id, offset: 7))) else {
            return XCTFail("not logs")
        }
        XCTAssertFalse(logs.jobFinished, "the canceled job still has a live artifact writer")
        XCTAssertEqual(logs.offset, 7)
        XCTAssertEqual(logs.nextOffset, 7)
        XCTAssertEqual(logs.data, "")
        try fs.createDirectory(directory)
        fs.sizes[directory] = 100
        guard case .gc(let gc) = try result(daemon, .gc(GCParams(apply: true))) else {
            return XCTFail("not GC")
        }
        XCTAssertFalse(gc.removed.contains(directory), "GC must protect a terminal job's live writer")
        XCTAssertTrue(fs.fileExists(directory))
        guard case .status(let draining) = try result(daemon, .drain) else { return XCTFail("not drain") }
        XCTAssertEqual(draining.drainComplete, false)

        let joined = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            daemon.service.waitForBackgroundWork(); joined.signal()
        }
        XCTAssertEqual(joined.wait(timeout: .now() + 0.1), .timedOut, "shutdown must join unfinished preparation")
        if stage == .logOpen { XCTAssertEqual(unlink(logPath), 0) }
        gate.resume.signal()
        XCTAssertEqual(joined.wait(timeout: .now() + 3), .success)
        try eventually("canceled preparation discarded") {
            try self.status(daemon).drainComplete == true
        }
        guard case .logs(let finished) = try result(daemon, .logs(LogsParams(jobID: job.id))) else {
            return XCTFail("not logs")
        }
        XCTAssertTrue(finished.jobFinished)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "canceled preparation must never spawn later")
        XCTAssertTrue(try daemon.side.resources(jobID: job.id).isEmpty)
    }

    func testBlockedDirectoryCreationKeepsAPIAndTicksResponsiveAndProtectsCanceledWriter() throws {
        try checkBlockedPreparation(.directories)
    }

    func testBlockedLogOpenKeepsAPIAndTicksResponsiveAndProtectsCanceledWriter() throws {
        try checkBlockedPreparation(.logOpen)
    }

    func testUnblockedPreparationStartsItsCommandExactlyOnce() throws {
        let daemon = try TestDaemon(realProcesses: true)
        let gate = Gate(.logOpen)
        defer { gate.resume.signal(); daemon.destroy() }
        try XCTUnwrap(daemon.processExecutor).beforePreparationStage = { gate.pause($0) }
        let marker = daemon.paths.stateDir + "/starts"
        let job = try daemon.submit(
            SubmitParams(
                project: "prepare", submitter: "test", minSims: 0,
                command: ["/bin/sh", "-c", "echo started >> '\(marker)'"])
        ).job
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        _ = try status(daemon)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
        gate.resume.signal()
        XCTAssertEqual(try daemon.wait(job.id).state, .succeeded)
        try eventually("process ownership released") {
            try daemon.side.resources(jobID: job.id).allSatisfy { $0.state == .released }
        }
        XCTAssertEqual(try String(contentsOfFile: marker, encoding: .utf8), "started\n")
        XCTAssertEqual(try daemon.job(job.id).attempt, 0)
    }

    func testServerStopJoinsBlockedPreparationWithoutStartingCanceledCommand() throws {
        let daemon = try TestDaemon(realProcesses: true)
        let gate = Gate(.directories)
        defer { gate.resume.signal(); daemon.destroy() }
        try XCTUnwrap(daemon.processExecutor).beforePreparationStage = { gate.pause($0) }
        let marker = daemon.paths.stateDir + "/never-started"
        let job = try daemon.submit(
            SubmitParams(
                project: "prepare", submitter: "test", minSims: 0,
                command: ["/bin/sh", "-c", "echo started > '\(marker)'"])
        ).job
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        _ = try result(daemon, .cancel(CancelParams(jobID: job.id)))
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            daemon.stop(); stopped.signal()
        }
        XCTAssertEqual(stopped.wait(timeout: .now() + 0.1), .timedOut)
        gate.resume.signal()
        XCTAssertEqual(stopped.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(try daemon.side.job(id: job.id)?.state, .canceled)
        XCTAssertNil(try daemon.side.job(id: job.id)?.startedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
        XCTAssertTrue(try daemon.side.resources(jobID: job.id).isEmpty)
    }

    func testRunningCommandIsReapedWhileAnotherJobsDirectoryPreparationIsBlocked() throws {
        let daemon = try TestDaemon(realProcesses: true)
        let gate = Gate(.directories)
        let release = daemon.paths.stateDir + "/release-first"
        defer {
            try? Data().write(to: URL(fileURLWithPath: release))
            gate.resume.signal()
            daemon.destroy()
        }
        let first = try daemon.submit(
            SubmitParams(
                project: "supervised", submitter: "test", minSims: 0,
                command: ["/bin/sh", "-c", "while [ ! -e '\(release)' ]; do sleep 0.02; done; echo completed"])
        ).job
        try eventually("first command running") { try daemon.job(first.id).state == .running }
        XCTAssertTrue(try daemon.side.resources(jobID: first.id).contains { $0.kind == .processGroup })
        // Install the fault only after the first command crossed its real spawn barrier.
        try XCTUnwrap(daemon.processExecutor).beforePreparationStage = { gate.pause($0) }
        let second = try daemon.submit(
            SubmitParams(project: "blocked", submitter: "test", minSims: 0, command: ["/bin/true"])
        ).job
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(try daemon.job(first.id).state, .running)
        let before = try XCTUnwrap(status(daemon).lastTickAt)
        try Data().write(to: URL(fileURLWithPath: release))
        try eventually("first command reaped during another preparation") {
            try daemon.job(first.id).state == .succeeded
                && daemon.side.resources(jobID: first.id).allSatisfy { $0.state == .released }
        }
        XCTAssertGreaterThan(try XCTUnwrap(status(daemon).lastTickAt), before)
        XCTAssertEqual(try daemon.job(second.id).state, .admitted)
        XCTAssertTrue(try daemon.side.resources(jobID: second.id).isEmpty)
        let logPath = try XCTUnwrap(try daemon.job(first.id).logPath)
        XCTAssertTrue(try String(contentsOfFile: logPath, encoding: .utf8).contains("completed\n"))
        _ = try result(daemon, .cancel(CancelParams(jobID: second.id)))
        gate.resume.signal()
        daemon.service.waitForBackgroundWork()
        XCTAssertEqual(try daemon.job(second.id).state, .canceled)
        XCTAssertNil(try daemon.side.job(id: second.id)?.startedAt)
    }

    private struct ExecutorFixture {
        let root: String
        let store: JobStore
        let executor: ProcessExecutor
        let epoch: Int64
        let job: Job
        let work: ProcessExecutor.PreparationWork
        var marker: String { root + "/attempts" }

        init(retryable: Bool = false, storageCheck: @escaping @Sendable (String) throws -> Void = JobStorage.check)
            throws
        {
            root = testScratchRoot() + "/prep-" + UUID().uuidString.prefix(8)
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            store = try JobStore(path: ":memory:")
            epoch = try store.acquireDaemonLease(ownerID: "first", pid: 1, now: 0)
            executor = ProcessExecutor(artifacts: JobArtifacts(root: root), processes: SystemProcessTable())
            executor.asynchronousPreparation = true
            executor.storageCheck = storageCheck
            let submitted = try store.submit(
                JobSubmission(
                    project: "prepare", submitter: "test", retryable: retryable, maxRetries: 1,
                    command: JobCommand(argv: ["/bin/sh", "-c", "echo $SIMQ_ATTEMPT >> '\(root)/attempts'"])),
                now: 1
            ).job
            _ = try XCTUnwrap(store.claim(jobID: submitted.id, grantedSims: 0, epoch: epoch, now: 2))
            job = try XCTUnwrap(store.job(id: submitted.id))
            try executor.step(store: store, epoch: epoch, now: 2)
            work = try XCTUnwrap(executor.takePreparationWork().first)
        }

        func remove() { try? FileManager.default.removeItem(atPath: root) }
    }

    private func preparedDescriptor(
        _ result: Result<ProcessExecutor.PreparedStart, ProcessExecutor.PreparationFailure>?
    ) throws
        -> Int32
    {
        guard case .success(let prepared) = try XCTUnwrap(result) else { throw TestFailure("preparation failed") }
        XCTAssertNotEqual(fcntl(prepared.descriptor, F_GETFD), -1)
        return prepared.descriptor
    }

    func testDisconnectAfterPreparationClosesDescriptorAndKeepsUnstartedJobForRecovery() throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        var prepared: Result<ProcessExecutor.PreparedStart, ProcessExecutor.PreparationFailure>? = fixture.executor
            .prepareStart(fixture.work)
        let descriptor = try preparedDescriptor(prepared)
        fixture.executor.finishPreparation(fixture.work, result: try XCTUnwrap(prepared))
        prepared = nil
        fixture.executor.storageCheck = { _ in throw JobStorage.Failure("disconnected") }
        try fixture.executor.step(store: fixture.store, epoch: fixture.epoch, now: 3)
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(try fixture.store.job(id: fixture.job.id)?.state, .admitted)
        XCTAssertNil(try fixture.store.job(id: fixture.job.id)?.startedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker))
        fixture.executor.storageCheck = JobStorage.check
        try fixture.executor.step(store: fixture.store, epoch: fixture.epoch, now: 4)
        XCTAssertEqual(fixture.executor.takePreparationWork().count, 1, "reconnection prepares a fresh descriptor")
    }

    private final class TransientStorage: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        func check(_ root: String) throws {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            if calls == 2 { throw JobStorage.Failure("drive disconnected during preparation") }
        }
    }

    func testRecoveredDriveDoesNotTurnAnEarlierPreparationFailureIntoAFailedAttempt() throws {
        let storage = TransientStorage()
        let fixture = try ExecutorFixture(storageCheck: storage.check)
        defer { fixture.remove() }
        let outcome = fixture.executor.prepareStart(fixture.work)
        guard case .failure(let failure) = outcome else { return XCTFail("expected transient storage failure") }
        XCTAssertTrue(failure.storageUnavailable)
        fixture.executor.finishPreparation(fixture.work, result: outcome)
        // All subsequent checks succeed: reconnection preceded result consumption.
        try fixture.executor.step(store: fixture.store, epoch: fixture.epoch, now: 3)
        XCTAssertEqual(try fixture.store.job(id: fixture.job.id)?.state, .admitted)
        XCTAssertEqual(try fixture.store.job(id: fixture.job.id)?.attempt, fixture.job.attempt)
        XCTAssertNil(try fixture.store.job(id: fixture.job.id)?.startedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker))
        try fixture.executor.step(store: fixture.store, epoch: fixture.epoch, now: 4)
        let fresh = try XCTUnwrap(fixture.executor.takePreparationWork().first)
        if case .failure = fixture.executor.prepareStart(fresh) {
            XCTFail("recovered storage should prepare successfully")
        }
    }

    func testCanceledCompletedPreparationClosesDescriptorWithoutSpawn() throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        var prepared: Result<ProcessExecutor.PreparedStart, ProcessExecutor.PreparationFailure>? =
            fixture.executor.prepareStart(fixture.work)
        let descriptor = try preparedDescriptor(prepared)
        XCTAssertTrue(try fixture.store.cancel(jobID: fixture.job.id, now: 3))
        fixture.executor.finishPreparation(fixture.work, result: try XCTUnwrap(prepared))
        prepared = nil
        try fixture.executor.step(store: fixture.store, epoch: fixture.epoch, now: 4)
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1, "discarding a canceled result closes its owned log FD")
        XCTAssertEqual(errno, EBADF)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker))
        XCTAssertTrue(try fixture.store.resources(jobID: fixture.job.id).isEmpty)
    }

    func testNewEpochDiscardsCompletedPreparationWithoutSpawnAndClosesDescriptor() throws {
        let fixture = try ExecutorFixture()
        defer { fixture.remove() }
        var prepared: Result<ProcessExecutor.PreparedStart, ProcessExecutor.PreparationFailure>? =
            fixture.executor.prepareStart(fixture.work)
        let descriptor = try preparedDescriptor(prepared)
        let epoch = try fixture.store.acquireDaemonLease(ownerID: "replacement", pid: 2, now: 3)
        fixture.executor.finishPreparation(fixture.work, result: try XCTUnwrap(prepared))
        prepared = nil
        try fixture.executor.step(store: fixture.store, epoch: epoch, now: 4)
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker))
        XCTAssertTrue(try fixture.store.resources(jobID: fixture.job.id).isEmpty)
        XCTAssertNil(try fixture.store.job(id: fixture.job.id)?.startedAt)
    }

    func testLatePreparationFailureCannotOverwriteCancellationOrReplacementEpoch() throws {
        for replacementEpoch in [false, true] {
            let fixture = try ExecutorFixture()
            defer { fixture.remove() }
            let epoch: Int64
            if replacementEpoch {
                epoch = try fixture.store.acquireDaemonLease(ownerID: "replacement", pid: 2, now: 3)
                _ = try fixture.store.recoverAfterRestart(epoch: epoch, now: 3)
                _ = try XCTUnwrap(fixture.store.claim(jobID: fixture.job.id, grantedSims: 0, epoch: epoch, now: 4))
            } else {
                epoch = fixture.epoch
                XCTAssertTrue(try fixture.store.cancel(jobID: fixture.job.id, now: 3))
            }
            let expected = try XCTUnwrap(fixture.store.job(id: fixture.job.id))
            fixture.executor.finishPreparation(
                fixture.work, result: .failure(.init(result: .artifactFailure, message: "obsolete preparation failed")))
            try fixture.executor.step(store: fixture.store, epoch: epoch, now: 5)
            let actual = try XCTUnwrap(fixture.store.job(id: fixture.job.id))
            XCTAssertEqual(actual.state, expected.state)
            XCTAssertEqual(actual.attempt, expected.attempt)
            XCTAssertEqual(actual.ownerEpoch, expected.ownerEpoch)
            XCTAssertEqual(actual.fenceToken, expected.fenceToken)
            XCTAssertEqual(actual.resultClass, expected.resultClass)
            XCTAssertEqual(actual.message, expected.message)
            XCTAssertNil(actual.startedAt)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker))
            XCTAssertTrue(try fixture.store.resources(jobID: fixture.job.id).isEmpty)
        }
    }

    func testRetryGetsFreshPreparationAndOldAttemptCannotStart() throws {
        let fixture = try ExecutorFixture(retryable: true)
        defer { fixture.remove() }
        var old: Result<ProcessExecutor.PreparedStart, ProcessExecutor.PreparationFailure>? =
            fixture.executor.prepareStart(fixture.work)
        let oldDescriptor = try preparedDescriptor(old)
        _ = try fixture.store.finish(jobID: fixture.job.id, result: .artifactFailure, now: 3)
        _ = try XCTUnwrap(fixture.store.claim(jobID: fixture.job.id, grantedSims: 0, epoch: fixture.epoch, now: 4))
        let current = try XCTUnwrap(fixture.store.job(id: fixture.job.id))
        XCTAssertEqual(current.attempt, 1)
        XCTAssertNotEqual(current.fenceToken, fixture.job.fenceToken)
        fixture.executor.finishPreparation(fixture.work, result: try XCTUnwrap(old))
        old = nil
        try fixture.executor.step(store: fixture.store, epoch: fixture.epoch, now: 4)
        XCTAssertEqual(fcntl(oldDescriptor, F_GETFD), -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker))
        let fresh = try XCTUnwrap(fixture.executor.takePreparationWork().first)
        XCTAssertEqual(fresh.job.attempt, 1)
        let prepared = fixture.executor.prepareStart(fresh)
        // A delayed completion for attempt zero cannot overwrite attempt one's work.
        fixture.executor.finishPreparation(
            fixture.work, result: .failure(.init(result: .artifactFailure, message: "late")))
        fixture.executor.finishPreparation(fresh, result: prepared)
        try eventually("only current attempt completes") {
            try fixture.executor.step(store: fixture.store, epoch: fixture.epoch, now: 5)
            return try fixture.store.job(id: fixture.job.id)?.state == .succeeded
        }
        XCTAssertEqual(try String(contentsOfFile: fixture.marker, encoding: .utf8), "1\n")
        XCTAssertEqual(try fixture.store.events(jobID: fixture.job.id).filter { $0 == "running" }.count, 1)
    }
}
