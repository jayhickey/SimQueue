// SPDX-License-Identifier: MIT

import Dispatch
import Foundation
import SimQueueHost
import SimQueueProtocol
import XCTest

@testable import SimQueueDaemon

/// Job output whose metadata answers while every open() blocks. Seen on a host where the output
/// volume stopped answering opens overnight: admitted jobs leased every pool sim and never
/// started, and `explain`/`wait` requests each kept a connection slot until all were refused
/// with "request limit reached". These cover what the daemon does instead.
final class HungJobOutputTests: XCTestCase {
    /// An I/O probe operation that blocks until opened, then never again. `open()` may be
    /// called more than once (a test opens it, and its `defer` opens it again).
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private let opened = DispatchGroup()
        private var isOpen = false
        init() { opened.enter() }
        func operation(_ root: String) throws { opened.wait() }
        func open() {
            lock.lock(); defer { lock.unlock() }
            guard !isOpen else { return }
            isOpen = true
            opened.leave()
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0
        var now: Double { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: Double) { lock.lock(); value += seconds; lock.unlock() }
    }

    /// A probe of `root` that has been pending past its limit, so it reports the root as hung.
    private func hungProbe(_ root: String, gate: Gate, clock: Clock) -> StorageIOProbe {
        let probe = StorageIOProbe(
            timeoutSeconds: 5, intervalSeconds: 30, inlineWaitSeconds: 0, operation: gate.operation,
            uptime: { clock.now })
        XCTAssertNil(probe.check(root), "A probe only just started is not reported yet")
        clock.advance(10)
        XCTAssertNotNil(probe.check(root))
        return probe
    }

    private func eventually(timeout: Double = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    private struct SubmitFailed: Error {}

    /// Submits a simulator-free job and returns its ID.
    private func submit(_ daemon: TestDaemon) throws -> String {
        let response = daemon.service.handle(
            Request(params: .submit(SubmitParams(project: "storage", submitter: "test", minSims: 0))))
        guard case .result(.submit(let submitted)) = response.body else {
            XCTFail("submit failed: \(response.body)")
            throw SubmitFailed()
        }
        return submitted.job.id
    }

    func testQueuedWorkWaitsWhileJobOutputIOHangsAndIsAdmittedOnceItAnswers() throws {
        let daemon = try TestDaemon()
        let gate = Gate()
        defer { gate.open(); daemon.destroy() }
        daemon.stop()
        let clock = Clock()
        let root = daemon.service.artifacts.root
        daemon.service.storageChecksEnabled = true
        daemon.service.validateStorage = { _ in }  // the metadata checks pass, as they did
        daemon.service.ioProbe = hungProbe(root, gate: gate, clock: clock)

        let job = try submit(daemon)
        _ = try daemon.service.tick()
        XCTAssertEqual(
            try daemon.service.jobInfo(job)?.state, .queued, "Nothing is admitted (and no sim leased) while hung")

        gate.open()
        XCTAssertTrue(eventually { daemon.service.ioProbe?.check(root) == nil })
        _ = try daemon.service.tick()
        XCTAssertNotEqual(try daemon.service.jobInfo(job)?.state, .queued, "Admitted once the probe passes")
    }

    /// A daemon that starts while the volume hangs has no finished probe yet. Nothing is
    /// admitted (or its run directory prepared) until one finishes; the clock never passes the
    /// probe's limit here, so this is the not-yet-verified case, not the hung one.
    func testAColdStartIntoAHungDriveAdmitsNothingUntilAProbeFinishes() throws {
        let daemon = try TestDaemon()
        let gate = Gate()
        defer { gate.open(); daemon.destroy() }
        daemon.stop()
        let root = daemon.service.artifacts.root
        let probe = StorageIOProbe(
            timeoutSeconds: 5, intervalSeconds: 30, inlineWaitSeconds: 0, operation: gate.operation, uptime: { 0 })
        daemon.service.storageChecksEnabled = true
        daemon.service.validateStorage = { _ in }
        daemon.service.ioProbe = probe

        let job = try submit(daemon)
        _ = try daemon.service.tick()
        XCTAssertEqual(try daemon.service.jobInfo(job)?.state, .queued, "Nothing is admitted on an unverified root")
        XCTAssertNil(probe.check(root), "Status and doctor still report without a result")
        XCTAssertTrue(probe.check(root, requireResult: true)?.contains("not verified") == true)

        gate.open()
        XCTAssertTrue(eventually { probe.check(root, requireResult: true) == nil })
        _ = try daemon.service.tick()
        XCTAssertNotEqual(try daemon.service.jobInfo(job)?.state, .queued, "Admitted once the first probe passes")
    }

    /// The check `simqd` gives the executor: volume failures pass through, and a probe that has
    /// not passed (not yet verified, or hung) holds start preparation.
    func testTheExecutorStorageCheckHoldsUntilTheProbeHasPassed() throws {
        let gate = Gate()
        defer { gate.open() }
        let clock = Clock()
        let probe = StorageIOProbe(
            timeoutSeconds: 5, intervalSeconds: 30, inlineWaitSeconds: 0, operation: gate.operation,
            uptime: { clock.now })
        let check = JobOutputGuard.storageCheck(volume: { _ in }, probe: probe)
        XCTAssertThrowsError(try check("/out"), "Not verified yet at startup")
        clock.advance(10)
        XCTAssertThrowsError(try check("/out"), "Hung")
        gate.open()
        XCTAssertTrue(eventually { (try? check("/out")) != nil }, "Passes once the probe does")
        let offline = JobOutputGuard.storageCheck(
            volume: { _ in throw JobStorage.Failure("volume offline") }, probe: probe)
        XCTAssertThrowsError(try offline("/out")) { error in
            XCTAssertEqual(String(describing: error), "volume offline")
        }
    }

    func testABoundedWriterReturnsAtItsDeadlineAndHoldsOneThreadPerHungRoot() {
        let writers = BoundedWriters()
        let gate = Gate()
        defer { gate.open() }
        let started = Date()
        XCTAssertFalse(writers.run(root: "/hung", deadlineSeconds: 0.2) { try? gate.operation("/hung") })
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "The caller is released at the deadline")
        XCTAssertEqual(writers.busyRoots, ["/hung"])

        final class Count: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            var calls: Int { lock.lock(); defer { lock.unlock() }; return value }
            func add() { lock.lock(); value += 1; lock.unlock() }
        }
        let count = Count()
        XCTAssertFalse(writers.run(root: "/hung", deadlineSeconds: 5) { count.add() }, "Skipped while blocked")
        XCTAssertTrue(writers.run(root: "/other", deadlineSeconds: 5) { count.add() }, "Other roots still write")
        XCTAssertEqual(count.calls, 1)

        gate.open()
        XCTAssertTrue(eventually { writers.busyRoots.isEmpty })
        XCTAssertTrue(writers.run(root: "/hung", deadlineSeconds: 5) { count.add() }, "Writes again once it answers")
        XCTAssertEqual(count.calls, 2)
    }

    func testExplainAnswersWithoutWalkingAHungRunDirectoryAndSaysWhy() throws {
        let daemon = try TestDaemon()
        let gate = Gate()
        defer { gate.open(); daemon.destroy() }
        daemon.stop()
        let clock = Clock()
        let root = daemon.service.artifacts.root
        let runDir = root + "/2026-01-01/J-1"
        try FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
        try Data("output".utf8).write(to: URL(fileURLWithPath: runDir + "/log.txt"))
        var info = try XCTUnwrap(daemon.service.jobInfo(try submit(daemon)))
        info.runDir = runDir
        daemon.service.ioProbe = hungProbe(root, gate: gate, clock: clock)

        let hung = daemon.service.attachArtifacts(to: info)
        XCTAssertNil(hung.artifacts, "The run directory is not walked")
        XCTAssertTrue(hung.artifactsUnavailable?.contains("I/O probe") == true, hung.artifactsUnavailable ?? "nil")

        gate.open()
        XCTAssertTrue(eventually { daemon.service.ioProbe?.check(root) == nil })
        let listed = daemon.service.attachArtifacts(to: info)
        XCTAssertNil(listed.artifactsUnavailable)
        XCTAssertEqual(listed.artifacts?.map(\.path), ["log.txt"])
    }

    func testWithoutAProbeTheListingIsUnchanged() throws {
        let daemon = try TestDaemon()
        defer { daemon.destroy() }
        daemon.stop()
        let runDir = daemon.service.artifacts.root + "/2026-01-01/J-2"
        try FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
        try Data("output".utf8).write(to: URL(fileURLWithPath: runDir + "/log.txt"))
        var info = try XCTUnwrap(daemon.service.jobInfo(try submit(daemon)))
        info.runDir = runDir
        XCTAssertNil(daemon.service.ioProbe)
        XCTAssertEqual(daemon.service.attachArtifacts(to: info).artifacts?.map(\.path), ["log.txt"])
    }

    func testTheProbedRootIsTheConfiguredRootHoldingTheRunDirectory() {
        XCTAssertEqual(
            DaemonService.outputRoot(of: "/out/jobs/2026-01-01/J-1", roots: ["/out/jobs", nil]), "/out/jobs")
        XCTAssertEqual(DaemonService.outputRoot(of: "/old/2026-01-01/J-1", roots: ["/out/jobs", "/old"]), "/old")
        XCTAssertEqual(
            DaemonService.outputRoot(of: "/out/jobs-2/2026-01-01/J-1", roots: ["/out/jobs"]), "/out/jobs-2",
            "A sibling with the same prefix is not that root")
        XCTAssertEqual(DaemonService.outputRoot(of: "/custom/2026-01-01/J-1", roots: ["/out/jobs"]), "/custom")
    }
}
