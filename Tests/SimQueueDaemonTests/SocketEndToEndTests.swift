// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueIPC
import SimQueueProtocol
import SimQueueStore
import XCTest

final class SocketEndToEndTests: XCTestCase {
    private var daemon: TestDaemon!

    override func setUpWithError() throws {
        daemon = try TestDaemon()
    }

    override func tearDown() {
        daemon?.destroy()
    }

    func testSocketIsOwnerOnly() throws {
        XCTAssertEqual(UnixListener.permissions(of: daemon.paths.socketPath), 0o600)
        let attributes = try FileManager.default.attributesOfItem(atPath: daemon.paths.stateDir)
        XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0) & 0o777, 0o700)
    }

    func testSubmitThenWaitSucceeds() throws {
        let submitted = try daemon.submit(params())
        XCTAssertFalse(submitted.deduplicated)
        XCTAssertEqual(submitted.job.priority, Priority.defaultValue)
        let done = try daemon.wait(submitted.job.id)
        XCTAssertEqual(done.state, .succeeded)
        XCTAssertEqual(done.exitCodeValue, 0)
    }

    func testResultClassesMapToStableExitCodes() throws {
        for (result, code) in [("test_failure", 1), ("build_failure", 2), ("artifact_failure", 4)] {
            let job = try daemon.submit(params(fake: "{\"result\": \"\(result)\"}")).job
            XCTAssertEqual(try daemon.wait(job.id).exitCodeValue, Int32(code), result)
        }
    }

    func testHigherPriorityIsAheadAndEqualPriorityIsFIFO() throws {
        try daemon.side.setPaused(true)
        let first = try daemon.submit(params(priority: 50, submitter: "a")).job
        let second = try daemon.submit(params(priority: 50, submitter: "b")).job
        let urgent = try daemon.submit(params(priority: 90, submitter: "c")).job
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(try daemon.job(urgent.id).position, 1)
        XCTAssertEqual(try daemon.job(first.id).position, 2)
        XCTAssertEqual(try daemon.job(second.id).position, 3)
        XCTAssertEqual(try daemon.job(first.id).waitReasons.map(\.code), ["paused"])
        try daemon.side.setPaused(false)
        XCTAssertEqual(try daemon.wait(second.id).state, .succeeded)
    }

    func testKindIsALabelAndFlagsRoundTrip() throws {
        let plain = try daemon.submit(params()).job
        XCTAssertEqual(plain.kind, "")
        XCTAssertFalse(plain.exclusive)
        XCTAssertFalse(plain.retryable, "retryable is off by default")
        XCTAssertNil(plain.maxRetries)
        let flagged = try daemon.submit(params(submitter: "b", kind: "lint", exclusive: true, maxRetries: 2)).job
        XCTAssertEqual(flagged.kind, "lint")
        XCTAssertTrue(flagged.exclusive)
        XCTAssertTrue(flagged.retryable, "a retry count implies retryable")
        XCTAssertEqual(flagged.maxRetries, 2)
    }

    func testExclusiveJobsRunOneAtATimeOverTheSocket() throws {
        try daemon.side.setPaused(true)
        let first = try daemon.submit(params(submitter: "a", fake: #"{"run_seconds": 1.5}"#, exclusive: true)).job
        let second = try daemon.submit(params(submitter: "b", fake: #"{"run_seconds": 0.2}"#, exclusive: true)).job
        let other = try daemon.submit(params(submitter: "c", fake: #"{"run_seconds": 1.5}"#)).job
        try daemon.side.setPaused(false)
        let deadline = Date().addingTimeInterval(5)
        while try daemon.job(first.id).state != .running || daemon.job(other.id).state != .running {
            guard Date() < deadline else { return XCTFail("jobs didn't start") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let waiting = try daemon.job(second.id)
        XCTAssertEqual(waiting.state, .queued)
        XCTAssertEqual(waiting.waitReasons.map(\.code), ["exclusive_slot"])
        XCTAssertEqual(try daemon.wait(second.id).state, .succeeded)
        XCTAssertEqual(try daemon.job(first.id).state, .succeeded, "the second exclusive job ran after the first")
    }

    func testOnlyRetryableJobsAreRetriedAfterInfraFailure() throws {
        let failing = #"{"result": "artifact_failure"}"#
        let plain = try daemon.wait(try daemon.submit(params(submitter: "a", fake: failing)).job.id)
        XCTAssertEqual(plain.state, .infraFailed)
        XCTAssertEqual(plain.attempt, 0, "not retryable: no retry")
        // Three infra failures in total: the last one ends the job, so the infra drain
        // (3 in 15 min) doesn't hold a retry.
        let retried = try daemon.wait(
            try daemon.submit(params(submitter: "b", fake: failing, retryable: true, maxRetries: 1)).job.id)
        XCTAssertEqual(retried.state, .infraFailed)
        XCTAssertEqual(retried.attempt, 1, "one retry, then infra_failed")
        XCTAssertEqual(retried.exitCodeValue, 4)
    }

    func testInvalidKindAndRetryCountAreUsageErrors() throws {
        for bad in [params(kind: "has space"), params(maxRetries: 11), params(maxRetries: -1)] {
            let error = try daemon.protocolError(.submit(bad))
            XCTAssertEqual(error.code, .invalidArgument)
            XCTAssertEqual(error.code.exitCode, .usage)
        }
    }

    func testOutOfRangePriorityAndUnknownAliasAreUsageErrors() throws {
        let tooHigh = try daemon.protocolError(.submit(params(priority: 101)))
        XCTAssertEqual(tooHigh.code, .invalidArgument)
        XCTAssertEqual(tooHigh.code.exitCode, .usage)
        let alias = try daemon.protocolError(.submit(params(priorityName: "urgent")))
        XCTAssertEqual(alias.code, .invalidArgument)
        XCTAssertTrue(alias.message.contains("no aliases configured"))
    }

    func testDedupeKeyReturnsTheActiveJob() throws {
        try daemon.side.setPaused(true)
        let first = try daemon.submit(params(dedupeKey: "build-abc"))
        let again = try daemon.submit(params(submitter: "other", dedupeKey: "build-abc"))
        XCTAssertTrue(again.deduplicated)
        XCTAssertEqual(again.job.id, first.job.id)
    }

    func testDefaultTimeoutsAreAppliedAndNoneMeansNoLimit() throws {
        try daemon.side.setPaused(true)
        let plain = try daemon.submit(params()).job
        XCTAssertEqual(plain.queueTimeoutSeconds, 86_400, "queue timeout defaults to 24 h")
        XCTAssertNil(plain.runTimeoutSeconds, "run timeout has no default limit")
        XCTAssertNotNil(plain.queueDeadlineAt)
        let unlimited = try daemon.submit(params(submitter: "x", timeout: 0, queueTimeout: 0)).job
        XCTAssertNil(unlimited.queueTimeoutSeconds)
        XCTAssertNil(unlimited.queueDeadlineAt)
        XCTAssertEqual(try daemon.protocolError(.submit(params(submitter: "y", timeout: -1))).code, .invalidArgument)
    }

    func testRunTimeoutEndsTimedOutWithExitCode3() throws {
        let job = try daemon.submit(params(timeout: 0.2, fake: "{\"run_seconds\": 60}")).job
        let done = try daemon.wait(job.id)
        XCTAssertEqual(done.state, .timedOut)
        XCTAssertEqual(done.resultClass, .runTimeout)
        XCTAssertEqual(done.exitCodeValue, 3)
        XCTAssertNotNil(done.termSentAt)
        XCTAssertTrue(try daemon.processes.liveProcessGroups().isEmpty)
    }

    func testJobIgnoringSIGTERMIsKilledAfterGrace() throws {
        daemon.destroy()
        var config = DaemonConfig()
        config.timeouts.killGraceSeconds = 0.3
        daemon = try TestDaemon(config: config)
        let job = try daemon.submit(params(timeout: 0.1, fake: "{\"run_seconds\": 60, \"ignore_term\": true}")).job
        let done = try daemon.wait(job.id)
        XCTAssertEqual(done.state, .timedOut)
        let term = try XCTUnwrap(done.termSentAt)
        let kill = try XCTUnwrap(done.killSentAt)
        // The stored timestamps lose a little precision, so allow a hair under the grace (seen: 0.29999995).
        XCTAssertGreaterThanOrEqual(kill.epochSeconds - term.epochSeconds, 0.3 - 0.001)
        XCTAssertEqual(daemon.processes.signals.map(\.signal), [.term, .kill])
    }

    func testQueueTimeoutExpiresWithExitCode6() throws {
        try daemon.side.setPaused(true)
        let job = try daemon.submit(params(queueTimeout: 0.2)).job
        let done = try daemon.wait(job.id)
        XCTAssertEqual(done.state, .expired)
        XCTAssertEqual(done.resultClass, .queueTimeout)
        XCTAssertEqual(done.exitCodeValue, 6)
    }

    func testWaitStreamsChangesThenFinalResult() throws {
        try daemon.side.setPaused(true)
        let job = try daemon.submit(params(fake: "{\"run_seconds\": 0.2}")).job
        var states: [JobState] = []
        let path = daemon.paths.databasePath
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            try? JobStore(path: path).setPaused(false)
        }
        let done = try daemon.wait(job.id, stream: true) { states.append($0.state) }
        XCTAssertEqual(done.state, .succeeded)
        XCTAssertEqual(states.first, .queued)
        XCTAssertTrue(states.contains(.running))
    }

    func testClientWaitTimeoutLeavesTheJobAlone() throws {
        try daemon.side.setPaused(true)
        let job = try daemon.submit(params()).job
        XCTAssertThrowsError(
            try daemon.client.send(
                Request(params: .wait(WaitParams(jobID: job.id))), deadline: Date().timeIntervalSince1970 + 0.2)
        ) { error in
            XCTAssertEqual(error as? SocketError, .timedOut)
        }
        XCTAssertEqual(try daemon.job(job.id).state, .queued)
    }

    func testCancel() throws {
        try daemon.side.setPaused(true)
        let job = try daemon.submit(params()).job
        guard case .job(let canceled) = try daemon.result(.cancel(CancelParams(jobID: job.id))) else {
            return XCTFail("not a job")
        }
        XCTAssertEqual(canceled.state, .canceled)
        XCTAssertEqual(canceled.exitCodeValue, 5)
        XCTAssertEqual(try daemon.protocolError(.cancel(CancelParams(jobID: job.id))).code, .invalidState)
        XCTAssertEqual(try daemon.protocolError(.cancel(CancelParams(jobID: "J-9999"))).code, .notFound)
    }

    func testCancelRunningJobStopsItsProcessGroup() throws {
        let job = try daemon.submit(params(fake: "{\"run_seconds\": 60}")).job
        let deadline = Date().addingTimeInterval(5)
        while try daemon.job(job.id).state != .running, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        _ = try daemon.result(.cancel(CancelParams(jobID: job.id)))
        XCTAssertTrue(try daemon.processes.liveProcessGroups().isEmpty)
        XCTAssertTrue(try daemon.side.resources(jobID: job.id).allSatisfy { $0.state == .released })
    }

    func testStatusAndJobs() throws {
        let job = try daemon.submit(params()).job
        _ = try daemon.wait(job.id)
        guard case .status(let status) = try daemon.result(.status) else { return XCTFail("not status") }
        XCTAssertEqual(status.daemon.epoch, daemon.engine.epoch)
        XCTAssertNotNil(status.lastTickAt)
        guard case .jobs(let jobs) = try daemon.result(.jobs(JobsParams(states: [.succeeded]))) else {
            return XCTFail("not jobs")
        }
        XCTAssertEqual(jobs.map(\.id), [job.id])
    }

    func testExplainUnknownJobIsNotFound() throws {
        let error = try daemon.protocolError(.explain(JobRef(jobID: "J-4040")))
        XCTAssertEqual(error.code, .notFound)
        XCTAssertEqual(error.code.exitCode, .notFound)
    }

    func testTimestampsOnTheWireAreRFC3339UTC() throws {
        let job = try daemon.submit(params()).job
        _ = try daemon.wait(job.id)
        let pattern = try NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3})?Z$"#)
        for request in [Request(params: .status), Request(params: .explain(JobRef(jobID: job.id)))] {
            let connection = try UnixConnection.connect(path: daemon.paths.socketPath)
            defer { connection.close() }
            try connection.write(try LineCodec.encode(request))
            let line = try XCTUnwrap(connection.readLine(maxBytes: LineCodec.maxLineBytes))
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: line) as? [String: Any])
            var stamps: [String: Any] = [:]
            func collect(_ value: Any, _ path: String) {
                if let dictionary = value as? [String: Any] {
                    for (key, child) in dictionary { collect(child, path + "." + key) }
                } else if let array = value as? [Any] {
                    for child in array { collect(child, path + "[]") }
                } else if path.hasSuffix("_at") || path.hasSuffix(".queue_time") {
                    stamps[path] = value
                }
            }
            collect(object, "")
            XCTAssertFalse(stamps.isEmpty, "\(request.params) returned no timestamps")
            for (path, value) in stamps {
                let text = try XCTUnwrap(value as? String, "\(path) must be a string, got \(value)")
                XCTAssertEqual(
                    pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)), 1,
                    "\(path) = \(text)")
            }
        }
    }

    func testNewerSchemaVersionAndMalformedLinesAreRejected() throws {
        let response = try XCTUnwrap(daemon.client.send(Request(params: .status, schemaVersion: 99)))
        guard case .error(let error) = response.body else { return XCTFail("expected error") }
        XCTAssertEqual(error.code, .unsupportedSchemaVersion)

        let connection = try UnixConnection.connect(path: daemon.paths.socketPath)
        defer { connection.close() }
        try connection.write(Data("{not json\n".utf8))
        let line = try XCTUnwrap(connection.readLine(maxBytes: LineCodec.maxLineBytes))
        guard case .error(let malformed) = try LineCodec.decode(Response.self, from: line).body else {
            return XCTFail("expected error")
        }
        XCTAssertEqual(malformed.code, .badRequest)
    }

    func testOnlyOneDaemonPerStateDirectory() throws {
        XCTAssertThrowsError(try InstanceLock(path: daemon.paths.lockPath)) { error in
            XCTAssertEqual(error as? InstanceLock.LockError, .alreadyRunning(daemon.paths.lockPath))
        }
        XCTAssertThrowsError(try UnixListener(path: daemon.paths.socketPath)) { error in
            XCTAssertEqual(error as? SocketError, .alreadyRunning(daemon.paths.socketPath))
        }
    }

    func testLostLeaseStopsTheServer() throws {
        let intruder = try JobStore(path: daemon.paths.databasePath)
        _ = try intruder.acquireDaemonLease(ownerID: "other", pid: 2, now: Date().timeIntervalSince1970)
        let deadline = Date().addingTimeInterval(5)
        while !daemon.server.isStopped, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(daemon.server.isStopped)
        XCTAssertTrue(daemon.server.failure?.contains("lease lost") ?? false)
    }

    func testDoctorOnlineAndOfflineIncludeOwnedUDIDs() throws {
        let now = Date().timeIntervalSince1970
        daemon.sims.setDevices([
            SimDevice(udid: "UDID-A", name: "simq-pool-a", isBooted: true),
            SimDevice(udid: "UDID-B", name: "simq-pool-b", isBooted: true),
            SimDevice(udid: "OTHER-1", name: "Someone Else's Sim", isBooted: false),
        ])
        _ = try daemon.side.acquireResource(
            kind: .sim, externalID: "UDID-B", owner: .pool, epoch: daemon.engine.epoch, now: now)
        _ = try daemon.side.acquireResource(
            kind: .sim, externalID: "UDID-A", owner: .pool, epoch: daemon.engine.epoch, now: now)
        guard case .doctor(let online) = try daemon.result(.doctor) else { return XCTFail("not doctor") }
        XCTAssertEqual(online.ownedUDIDs, ["UDID-A", "UDID-B"])
        XCTAssertNotNil(online.daemon)
        XCTAssertEqual(online.exitStatus, 0, "\(online.checks.filter { $0.level != .ok })")
        XCTAssertEqual(
            online.checks.map(\.name),
            [
                "daemon", "backend", "socket", "database", "orphaned_resources", "overdue_jobs", "anomalies",
                "registry_vs_reality", "foreign_resources", "disk", "memory_swap", "xcode_pin", "simslim_verify",
                "breaker", "watchdog",
            ])
        let foreign = try XCTUnwrap(online.checks.first { $0.name == "foreign_resources" })
        XCTAssertTrue(foreign.detail.contains("OTHER-1"), foreign.detail)
        XCTAssertEqual(online.health?.health, "ok")
        XCTAssertEqual(online.health?.lastPassKind, "full", "the startup reconcile is the first full pass")

        // A registered sim that vanished outside SimQueue shows up as registry drift.
        daemon.sims.setDevices([SimDevice(udid: "UDID-A", name: "simq-pool-a", isBooted: true)])
        guard case .doctor(let drifted) = try daemon.result(.doctor) else { return XCTFail("not doctor") }
        let registry = try XCTUnwrap(drifted.checks.first { $0.name == "registry_vs_reality" })
        XCTAssertEqual(registry.level, .warn)
        XCTAssertTrue(registry.detail.hasPrefix("resource gone for 1 registry row;"), registry.detail)
        XCTAssertEqual(drifted.ownedUDIDs, ["UDID-A", "UDID-B"], "doctor is read-only: nothing marked gone")

        daemon.stop()
        let auditBefore = try JobStore(readOnlyPath: daemon.paths.databasePath).auditEntries().count
        let offline = try DoctorBuilder.offline(paths: daemon.paths, now: now + 120)
        XCTAssertNil(offline.daemon)
        XCTAssertEqual(offline.ownedUDIDs, ["UDID-A", "UDID-B"])
        XCTAssertEqual(offline.exitStatus, 1, "daemon down is a warning")
        XCTAssertEqual(
            try JobStore(readOnlyPath: daemon.paths.databasePath).auditEntries().count, auditBefore,
            "doctor never writes")
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(offline), encoding: .utf8))
        XCTAssertTrue(json.contains("\"owned_udids\":[\"UDID-A\",\"UDID-B\"]"))
    }
}

final class DaemonConfigTests: XCTestCase {
    func testDefaultsAreGeneric() {
        let config = DaemonConfig()
        XCTAssertEqual(config.priorityAliases.values, [:])
        XCTAssertEqual(config.timeouts.defaultQueueTimeoutSeconds, 86_400)
        XCTAssertNil(config.timeouts.defaultRunTimeoutSeconds)
        XCTAssertEqual(config.timeouts.killGraceSeconds, 10)
        XCTAssertEqual(config.reliability.cleanupMode, .reportOnly)
        XCTAssertEqual(config.defaultMaxRetries, 1)
        XCTAssertEqual(config.scheduler.maxConcurrentExclusive, 1)
    }

    func testRetryAndExclusiveSettings() throws {
        let config = try DaemonConfig.parse(
            Data(#"{"default_max_retries": 3, "max_concurrent_exclusive": 2}"#.utf8))
        XCTAssertEqual(config.defaultMaxRetries, 3)
        XCTAssertEqual(config.scheduler.maxConcurrentExclusive, 2)
        for bad in [
            #"{"default_max_retries": 11}"#, #"{"default_max_retries": -1}"#, #"{"max_concurrent_exclusive": 0}"#,
        ] {
            XCTAssertThrowsError(try DaemonConfig.parse(Data(bad.utf8)), bad)
        }
    }

    func testParsesUserSettings() throws {
        let config = try DaemonConfig.parse(
            Data(
                """
                {"priority_aliases": {"Urgent": 90, "background": 5}, "aging_points_per_minute": 1,
                 "aging_max_boost": 10, "default_run_timeout_seconds": 1800,
                 "default_queue_timeout_seconds": 0, "kill_grace_seconds": 3, "cleanup_mode": "enforce"}
                """.utf8))
        XCTAssertEqual(config.priorityAliases.resolve("urgent"), 90)
        XCTAssertEqual(config.scheduler.priority, PriorityPolicy(agingPointsPerMinute: 1, maxBoost: 10))
        XCTAssertEqual(config.timeouts.defaultRunTimeoutSeconds, 1_800)
        let submission = config.timeouts.apply(to: JobSubmission(project: "p", submitter: "s"))
        XCTAssertNil(submission.queueTimeoutSeconds, "0 in config means no limit")
        XCTAssertEqual(config.timeouts.killGraceSeconds, 3)
        XCTAssertEqual(config.reliability.cleanupMode, .enforce)
    }

    func testWatchdogIntervals() throws {
        XCTAssertEqual(DaemonConfig().watchdog, WatchdogConfig(lightIntervalSeconds: 60, fullIntervalSeconds: 900))
        let config = try DaemonConfig.parse(
            Data(#"{"watchdog_light_interval_seconds": 30, "watchdog_full_interval_seconds": 600}"#.utf8))
        XCTAssertEqual(config.watchdog.lightIntervalSeconds, 30)
        XCTAssertEqual(config.watchdog.fullIntervalSeconds, 600)
        XCTAssertEqual(
            try DaemonConfig.parse(Data(#"{"reconcile_interval_seconds": 45}"#.utf8)).watchdog.lightIntervalSeconds, 45,
            "older key still sets the light interval")
        for bad in [#"{"watchdog_light_interval_seconds": 0}"#, #"{"watchdog_full_interval_seconds": -1}"#] {
            XCTAssertThrowsError(try DaemonConfig.parse(Data(bad.utf8)), bad)
        }
    }

    func testRejectsBadValues() {
        for bad in [
            #"{"priority_aliases": {"x": 101}}"#, #"{"priority_aliases": {"12": 50}}"#,
            #"{"default_queue_timeout_seconds": -1}"#, #"{"aging_points_per_minute": -1}"#, "not json",
        ] {
            XCTAssertThrowsError(try DaemonConfig.parse(Data(bad.utf8)), bad)
        }
    }

    func testAliasResolvesOverTheSocket() throws {
        var config = DaemonConfig()
        config.priorityAliases = PriorityAliases(["urgent": 90])
        let daemon = try TestDaemon(config: config)
        defer { daemon.destroy() }
        XCTAssertEqual(try daemon.submit(params(priorityName: "urgent")).job.priority, 90)
    }

    func testMissingConfigFileMeansDefaults() throws {
        XCTAssertEqual(try DaemonConfig.load(path: "/nonexistent/simq/config.json"), DaemonConfig())
    }
}

/// #35: one real-sim daemon per user host-wide, whatever its state dir.
final class HostLockTests: XCTestCase {
    func testASecondRealSimDaemonIsRefusedAndNamesTheHolder() throws {
        let path = NSTemporaryDirectory() + "simq-host-\(UUID().uuidString).lock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try XCTUnwrap(try HostLock.acquire(backend: .simctl, lockPath: path, stateDir: "/state/a"))
        XCTAssertThrowsError(try HostLock.acquire(backend: .simctl, lockPath: path, stateDir: "/state/b")) {
            XCTAssertEqual($0 as? HostLock.Failure, .heldBy(lockPath: path, stateDir: "/state/a"))
            XCTAssertTrue("\($0)".contains("only one real-sim daemon per user"), "\($0)")
        }
        XCTAssertNil(try HostLock.acquire(backend: .fake, lockPath: path, stateDir: "/state/c"), "fake sims need none")
        first.release()
        let again = try HostLock.acquire(backend: .simctl, lockPath: path, stateDir: "/state/b")
        XCTAssertNotNil(again, "free once the holder is gone")
        again?.release()
    }

    func testTheDefaultPathIsOutsideAnyStateDir() {
        XCTAssertEqual(
            SimQueuePaths.hostLockPath(environment: ["HOME": "/home/u"]), "/home/u/.simqueue/simqd-host.lock")
        XCTAssertEqual(SimQueuePaths.hostLockPath(environment: ["SIMQ_HOST_LOCK": "/tmp/x.lock"]), "/tmp/x.lock")
    }

    func testTheExampleConfigHasAnExplicitHostTemplateAndGenericPatterns() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/config.example.json").path
        let config = try DaemonConfig.load(path: path)
        XCTAssertEqual(config.pool?.externalSimPatterns, [])
        XCTAssertEqual(config.pool?.mode, .active, "the example runs the pool while cleanup stays report-only")
        XCTAssertEqual(config.backend, .simctl)
        XCTAssertEqual(config.simctl?.template, "REPLACE-WITH-EXPLICIT-TEMPLATE-UDID")
        XCTAssertTrue(config.autostart.enabled)
        XCTAssertEqual(config.pool?.mode, .active, "the example runs the pool while cleanup stays report-only")
        XCTAssertEqual(DaemonConfig().pool?.externalSimPatterns ?? [], [], "generic default: none")
        for pattern in ["*", "?", "??*", "*?*", ""] {
            XCTAssertThrowsError(
                try DaemonConfig.parse(Data(#"{"pool": {"external_sim_patterns": ["\#(pattern)"]}}"#.utf8)),
                "only wildcards: \(pattern)")
        }
        XCTAssertNoThrow(try DaemonConfig.parse(Data(#"{"pool": {"external_sim_patterns": ["a?*"]}}"#.utf8)))
    }
}
