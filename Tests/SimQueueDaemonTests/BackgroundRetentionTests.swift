// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueEngine
import SimQueueHost
import SimQueueProtocol
import SimQueueStore
import XCTest

final class BackgroundRetentionTests: XCTestCase {
    /// Block an actual filesystem boundary, rather than delaying the daemon's clock.
    private final class BlockingFileSystem: FileSystem, @unchecked Sendable {
        enum Operation: Equatable { case children, exists, size, remove, empty }
        let base = FakeFileSystem()
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var operation: Operation?
        private var path: String?

        func block(_ operation: Operation, path: String) {
            lock.lock(); defer { lock.unlock() }
            self.operation = operation; self.path = path
        }
        private func pause(_ operation: Operation, path: String) {
            lock.lock()
            let shouldBlock = self.operation == operation && self.path == path
            if shouldBlock { self.operation = nil }
            lock.unlock()
            if shouldBlock {
                entered.signal()
                _ = resume.wait(timeout: .now() + 15)
            }
        }
        func fileExists(_ path: String) -> Bool {
            pause(.exists, path: path)
            return base.fileExists(path)
        }
        func children(of path: String) throws -> [String] {
            pause(.children, path: path)
            return try base.children(of: path)
        }
        func createDirectory(_ path: String) throws { try base.createDirectory(path) }
        func sizeOfItem(_ path: String) -> UInt64? {
            pause(.size, path: path)
            return base.sizeOfItem(path)
        }
        func removeItem(_ path: String) throws {
            pause(.remove, path: path)
            try base.removeItem(path)
        }
        func removeEmptyDirectory(_ path: String) throws -> Bool {
            pause(.empty, path: path)
            return try base.removeEmptyDirectory(path)
        }
    }

    private func config() -> DaemonConfig {
        var config = DaemonConfig()
        config.reliability.cleanupMode = .enforce
        config.reliability.ageRules.artifactRetention.budgetBytes = 1
        config.watchdog.fullIntervalSeconds = 0.05
        config.watchdog.lightIntervalSeconds = 0.02
        return config
    }

    private func status(_ daemon: TestDaemon) throws -> StatusResult {
        guard case .status(let status) = try daemon.result(.status) else { throw TestFailure("no status") }
        return status
    }

    private func endedJob(_ daemon: TestDaemon) throws -> JobInfo {
        let params = SubmitParams(project: "retention", submitter: "test", dedupeKey: UUID().uuidString, minSims: 0)
        let job = try daemon.submit(params).job
        XCTAssertEqual(try daemon.wait(job.id).state, .succeeded)
        return job
    }

    func testDashboardCleanupIsCappedAndRecordsResults() throws {
        let fs = FakeFileSystem()
        var settings = config()
        settings.watchdog.fullIntervalSeconds = 3600
        settings.watchdog.lightIntervalSeconds = 3600
        settings.reliability.ageRules.artifactRetention.maxRemovalsPerPass = 100
        let daemon = try TestDaemon(config: settings, fileSystemOverride: fs)
        defer { daemon.destroy() }
        _ = try daemon.service.tick()
        daemon.service.waitForBackgroundWork()
        let directories = (1...21).map { daemon.paths.jobsRoot + "/2020-01-01/J-\($0)" }
        for directory in directories { try fs.createDirectory(directory) }
        guard case .gc(let result) = try daemon.result(.gc(GCParams(apply: true, background: true))) else {
            return XCTFail()
        }
        XCTAssertEqual(result.scheduled, true)
        daemon.service.waitForBackgroundWork()
        XCTAssertEqual(directories.filter { !fs.fileExists($0) }.count, 20)
        let report = try XCTUnwrap(status(daemon).artifactStorage)
        XCTAssertEqual(report.removedCount, 20)
        XCTAssertEqual(report.candidateCount, 21)
        XCTAssertNotNil(report.cleanupAt)
    }

    func testDashboardCannotApplyInReportOnlyMode() throws {
        var settings = config()
        settings.reliability.cleanupMode = .reportOnly
        let daemon = try TestDaemon(config: settings)
        defer { daemon.destroy() }
        XCTAssertThrowsError(try daemon.result(.gc(GCParams(apply: true, background: true))))
    }

    func testBackgroundStorageReviewReturnsImmediatelyWhileScanIsBlocked() throws {
        let fs = BlockingFileSystem()
        var settings = config()
        settings.watchdog.fullIntervalSeconds = 3600
        settings.watchdog.lightIntervalSeconds = 3600
        let daemon = try TestDaemon(config: settings, fileSystemOverride: fs)
        defer { fs.resume.signal(); daemon.destroy() }
        _ = try daemon.service.tick()
        daemon.service.waitForBackgroundWork()
        fs.block(.children, path: daemon.paths.jobsRoot)
        guard case .gc(let accepted) = try daemon.result(.gc(GCParams(background: true))) else { return XCTFail() }
        XCTAssertEqual(accepted.scheduled, true)
        XCTAssertEqual(fs.entered.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(try status(daemon).storageReviewRunning, true)
        XCTAssertNotNil(try status(daemon).host)
        _ = try endedJob(daemon)
        fs.resume.signal()
        daemon.service.waitForBackgroundWork()
        XCTAssertEqual(try status(daemon).storageReviewRunning, false)
        XCTAssertNotNil(try status(daemon).artifactStorage)
    }

    func testStartupDefersBlockedInventoryAndKeepsStatusTicksAndAdmissionResponsive() throws {
        let fs = BlockingFileSystem()
        let state = testScratchRoot() + "/retention-" + UUID().uuidString.prefix(8)
        fs.block(.children, path: state + "/jobs")
        let started = ProcessInfo.processInfo.systemUptime
        let daemon = try TestDaemon(config: config(), stateDir: state, fileSystemOverride: fs)
        defer { fs.resume.signal(); daemon.destroy() }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3, "startup must not walk artifacts")
        XCTAssertEqual(fs.entered.wait(timeout: .now() + 3), .success)
        let before = try XCTUnwrap(status(daemon).lastTickAt)
        let submitted = ProcessInfo.processInfo.systemUptime
        _ = try endedJob(daemon)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - submitted, 1)
        XCTAssertGreaterThan(try XCTUnwrap(status(daemon).lastTickAt), before)
        fs.resume.signal()
        daemon.service.waitForBackgroundWork()
    }

    func testDrainingDoesNotStartAnotherInventoryWorker() throws {
        let fs = BlockingFileSystem()
        let daemon = try TestDaemon(config: config(), fileSystemOverride: fs)
        defer { fs.resume.signal(); daemon.destroy() }
        daemon.stop()
        _ = daemon.service.handle(Request(params: .drain))
        fs.block(.children, path: daemon.paths.jobsRoot)
        Thread.sleep(forTimeInterval: 0.06)
        _ = try daemon.service.tick()
        XCTAssertEqual(fs.entered.wait(timeout: .now() + 0.1), .timedOut)
        daemon.service.waitForBackgroundWork()
    }

    func testBlockedExistenceInventoryUsesFreshPinsAndProtectsActiveJobs() throws {
        let fs = BlockingFileSystem()
        let daemon = try TestDaemon(config: config(), fileSystemOverride: fs)
        defer { fs.resume.signal(); daemon.destroy() }
        let ended = try endedJob(daemon)
        let active = try daemon.submit(
            SubmitParams(
                project: "retention", submitter: "test", minSims: 0,
                payloadJSON: #"{"fake":{"run_seconds":60}}"#)
        ).job
        let directory = daemon.paths.jobsRoot + "/2020-01-01/" + ended.id
        let activeDirectory = daemon.paths.jobsRoot + "/2020-01-01/" + active.id
        fs.base.sizes[directory] = 100
        fs.base.sizes[activeDirectory] = 100
        fs.block(.exists, path: directory + "/DerivedData")
        try fs.createDirectory(directory + "/DerivedData")
        try fs.createDirectory(activeDirectory)
        _ = try daemon.service.tick()
        XCTAssertEqual(fs.entered.wait(timeout: .now() + 3), .success)
        try daemon.side.audit(
            Engine.artifactKeepAuditType, jobID: ended.id, detail: "--keep", now: Date().timeIntervalSince1970)
        _ = try endedJob(daemon)
        fs.resume.signal()
        daemon.service.waitForBackgroundWork()
        XCTAssertTrue(fs.fileExists(directory + "/DerivedData"), "fresh pin applies after disk discovery")
        XCTAssertTrue(fs.fileExists(activeDirectory), "active directories are not budget candidates")
        XCTAssertTrue(fs.base.removed.isEmpty)
    }

    func testEmptyDayRemovalIsUnlockedAndCannotDeleteANewJobInThatDay() throws {
        let fs = BlockingFileSystem()
        let daemon = try TestDaemon(config: config(), fileSystemOverride: fs)
        defer { fs.resume.signal(); daemon.destroy() }
        let ended = try endedJob(daemon)
        let day = daemon.paths.jobsRoot + "/2020-01-01"
        let directory = day + "/" + ended.id
        fs.base.sizes[directory] = 100
        fs.block(.empty, path: day)
        try fs.createDirectory(directory)
        _ = try daemon.service.tick()
        XCTAssertEqual(fs.entered.wait(timeout: .now() + 3), .success)
        XCTAssertFalse(fs.fileExists(directory))
        let submitted = ProcessInfo.processInfo.systemUptime
        let active = try daemon.submit(
            SubmitParams(
                project: "retention", submitter: "test", minSims: 0,
                payloadJSON: #"{"fake":{"run_seconds":60}}"#)
        ).job
        let newDirectory = day + "/" + active.id
        try fs.createDirectory(newDirectory)
        _ = try status(daemon)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - submitted, 1)
        fs.resume.signal()
        daemon.service.waitForBackgroundWork()
        XCTAssertTrue(fs.fileExists(newDirectory), "atomic empty-only removal must keep a newly populated day")
        XCTAssertFalse(fs.base.removed.contains(day))
        XCTAssertFalse(try daemon.side.auditEntries().contains { $0.detail == "removed empty \(day)" })
    }

    func testSlowSizingDoesNotBlockTicksOrNewJobsAndRechecksNewPins() throws {
        let fs = BlockingFileSystem()
        let daemon = try TestDaemon(config: config(), fileSystemOverride: fs)
        defer { fs.resume.signal(); daemon.destroy() }
        let job = try endedJob(daemon)
        let directory = daemon.paths.jobsRoot + "/2020-01-01/" + job.id
        fs.base.sizes[directory] = 100
        fs.block(.size, path: directory)
        try fs.createDirectory(directory)
        _ = try daemon.service.tick()
        XCTAssertEqual(fs.entered.wait(timeout: .now() + 3), .success)
        let before = try XCTUnwrap(status(daemon).lastTickAt)
        // Model a pin committed after the store plan, before the disk walk ends.
        try daemon.side.audit(
            Engine.artifactKeepAuditType, jobID: job.id, detail: "--keep", now: Date().timeIntervalSince1970)
        let submittedAt = ProcessInfo.processInfo.systemUptime
        let newJob = try daemon.submit(SubmitParams(project: "retention", submitter: "test", minSims: 0)).job
        XCTAssertEqual(try daemon.wait(newJob.id).state, .succeeded)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - submittedAt, 1)
        XCTAssertGreaterThan(try XCTUnwrap(status(daemon).lastTickAt), before)
        fs.resume.signal()
        daemon.service.waitForBackgroundWork()
        XCTAssertTrue(fs.fileExists(directory), "a pin added during sizing must be rechecked before removal")
        XCTAssertTrue(fs.base.removed.isEmpty)
    }

    func testSlowRemovalKeepsItsIntentAndQueuedManualGCBlocksDrainAndStop() throws {
        let fs = BlockingFileSystem()
        let daemon = try TestDaemon(config: config(), fileSystemOverride: fs)
        defer { fs.resume.signal(); daemon.destroy() }
        let pinned = try endedJob(daemon)
        let job = try endedJob(daemon)
        let directory = daemon.paths.jobsRoot + "/2020-01-01/" + job.id
        let pinnedDirectory = daemon.paths.jobsRoot + "/2020-01-01/" + pinned.id
        try daemon.side.audit(
            Engine.artifactKeepAuditType, jobID: pinned.id, detail: "--keep", now: Date().timeIntervalSince1970)
        fs.base.sizes[directory] = 100
        fs.base.sizes[pinnedDirectory] = 100
        fs.block(.remove, path: directory)
        try fs.createDirectory(pinnedDirectory)
        try fs.createDirectory(directory)
        _ = try daemon.service.tick()
        XCTAssertEqual(fs.entered.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(try daemon.side.pendingActionIntents().filter { $0.jobID == job.id }.count, 1)
        let before = try XCTUnwrap(status(daemon).lastTickAt)
        // The tick loop can still be in its one-second idle sleep when removal
        // begins. Observe a full-pass window while the remover stays blocked.
        let afterFullPasses = Timestamp(before.epochSeconds + 0.2)
        let tickDeadline = ProcessInfo.processInfo.systemUptime + 3
        while try XCTUnwrap(status(daemon).lastTickAt) < afterFullPasses,
            ProcessInfo.processInfo.systemUptime < tickDeadline
        {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(status(daemon).lastTickAt), afterFullPasses)
        XCTAssertEqual(try daemon.side.pendingActionIntents().filter { $0.jobID == job.id }.count, 1)

        // Queue a manual dry run behind the automatic remover, then block its disk walk.
        // Drain must cover both the queued request and its later unlocked execution.
        fs.block(.size, path: pinnedDirectory)
        let manualStarted = DispatchSemaphore(value: 0)
        let manualFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            manualStarted.signal()
            do { _ = try daemon.result(.gc(GCParams())) } catch { XCTFail("manual GC failed: \(error)") }
            manualFinished.signal()
        }
        XCTAssertEqual(manualStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(manualFinished.wait(timeout: .now() + 0.1), .timedOut)
        guard case .status(let queued) = try daemon.result(.drain) else { return XCTFail("no drain status") }
        XCTAssertEqual(queued.drainComplete, false)
        fs.resume.signal()
        XCTAssertEqual(fs.entered.wait(timeout: .now() + 3), .success)
        XCTAssertFalse(fs.fileExists(directory))
        XCTAssertTrue(fs.fileExists(pinnedDirectory))
        guard case .status(let draining) = try daemon.result(.status) else { return XCTFail("no status") }
        XCTAssertEqual(draining.drainComplete, false, "manual work remains after the automatic worker ends")
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            daemon.stop(); stopped.signal()
        }
        XCTAssertEqual(stopped.wait(timeout: .now() + 0.1), .timedOut, "stop must join the manual worker too")
        fs.resume.signal()
        XCTAssertEqual(manualFinished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(stopped.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(try daemon.side.pendingActionIntents().isEmpty)
        XCTAssertEqual(try daemon.side.auditEntries(jobID: job.id, type: Engine.artifactRemovedAuditType).count, 1)
    }

    func testAutomaticRetentionIsCappedAtTwentyRemovalsAndContinuesNextPass() throws {
        let fs = FakeFileSystem()
        var config = config()
        config.reliability.ageRules.artifactRetention.maxRemovalsPerPass = 100
        let daemon = try TestDaemon(config: config, fileSystemOverride: fs)
        defer { daemon.destroy() }
        daemon.stop()  // Drive exact full passes without a racing server tick.
        let directories = (1...21).map { daemon.paths.jobsRoot + "/2020-01-01/J-\($0)" }
        for directory in directories { try fs.createDirectory(directory) }
        Thread.sleep(forTimeInterval: 0.06)
        _ = try daemon.service.tick()
        daemon.service.waitForBackgroundWork()
        XCTAssertEqual(directories.filter { !fs.fileExists($0) }.count, 20)
        Thread.sleep(forTimeInterval: 0.06)
        _ = try daemon.service.tick()
        daemon.service.waitForBackgroundWork()
        XCTAssertTrue(directories.allSatisfy { !fs.fileExists($0) })
    }
}
