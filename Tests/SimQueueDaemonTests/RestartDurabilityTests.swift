// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueHost
import SimQueueIPC
import SimQueueProtocol
import SimQueueStore
import XCTest

/// A real `simqd` (fake sims, process executor) restarted mid-queue, once with SIGTERM and
/// once with SIGKILL. Queued jobs keep their place; the job that was running is stopped,
/// requeued and run again, so nothing is dropped. A job that opted out of replay, and
/// every started non-retryable job on a host with `restart_recovery: interrupt`, stops
/// without replay instead. Side-effect markers detect both replay and attempts that
/// incorrectly survive restart. The daemon's own exits leave their reason behind.
///
/// Also covers a crash after the durable admission marker but before claim. A debug-only
/// fault hook kills that daemon repeatedly; recovery caps only the offending job.
final class RestartDurabilityTests: XCTestCase {
    private var stateDir = ""
    private var daemon: Int32?

    private static var productsDirectory: URL {
        #if os(macOS)
            for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
                return bundle.bundleURL.deletingLastPathComponent()
            }
        #endif
        return Bundle.main.bundleURL
    }

    private func binary(_ name: String) throws -> String {
        let url = Self.productsDirectory.appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("\(name) not built at \(url.path)")
        }
        return url.path
    }

    override func setUp() {
        stateDir = testScratchRoot() + "/sqr-" + UUID().uuidString.prefix(8)
    }

    override func tearDown() {
        if let daemon { stop(daemon, SIGKILL) }
        daemon = nil
        // Any job command a test left behind (each one leads its own group).
        if let marks = try? String(contentsOfFile: stateDir + "/pids", encoding: .utf8) {
            for pgid in marks.split(separator: "\n").compactMap({ Int32($0) }) { kill(-pgid, SIGKILL) }
        }
        try? FileManager.default.removeItem(atPath: stateDir)
    }

    /// Starts simqd in the foreground on the fake backend and waits until it answers.
    private func startDaemon(
        crashBeforeClaim: String? = nil, waitForReady: Bool = true, logToState: Bool = false
    ) throws -> Int32 {
        let simqd = try binary("simqd")
        var environment = ProcessInfo.processInfo.environment
        environment["SIMQ_NO_AUTOSTART"] = "1"
        environment["SIMQ_HOST_LOCK"] = stateDir + "-host.lock"
        environment["SIMQ_TEST_CRASH_BEFORE_CLAIM"] = crashBeforeClaim
        try FileManager.default.createDirectory(
            atPath: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // With --log-to-state the daemon redirects its own output into simqd.log through
        // a pipe and a reader thread, like the installed service does.
        let pid = try ProcessSpawner.spawn(
            executable: simqd,
            argv: [simqd, "run", "--foreground", "--backend", "fake", "--probe", "fake", "--state-dir", stateDir]
                + (logToState ? ["--log-to-state"] : []),
            environment: environment, cwd: nil, outputPath: stateDir + (logToState ? "/spawn.out" : "/simqd.log"))
        daemon = pid
        if !waitForReady { return pid }
        try eventually("simqd answers", timeout: 30) {
            if let exit = try? ProcessSpawner.reap(pid) {
                throw TestFailure("simqd exited during startup (\(exit.description)): \(log())")
            }
            return (try? call(.status)) != nil
        }
        return pid
    }

    private func log() -> String {
        (try? String(contentsOfFile: stateDir + "/simqd.log", encoding: .utf8)) ?? ""
    }

    private func call(_ params: RequestParams) throws -> ResultPayload {
        let response = try SimQueueClient(socketPath: stateDir + "/simq.sock", timeoutSeconds: 5)
            .send(Request(params: params))
        guard let response, case .result(let payload) = response.body else {
            throw TestFailure("no result for \(params)")
        }
        return payload
    }

    private func job(_ id: String) throws -> JobInfo {
        guard case .job(let info) = try call(.explain(JobRef(jobID: id))) else { throw TestFailure("explain \(id)") }
        return info
    }

    /// Signals the daemon and reaps it.
    private func stop(_ pid: Int32, _ signal: Int32) {
        kill(pid, signal)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if (try? ProcessSpawner.reap(pid)) != nil { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        kill(pid, SIGKILL)
        _ = try? ProcessSpawner.reap(pid)
    }

    private func eventually(_ what: String, timeout: Double, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("timed out waiting for \(what)\n\(log())")
        throw TestFailure("timed out waiting for \(what)")
    }

    /// Queues `count` exclusive (one at a time), non-retryable jobs. Each one records its
    /// group, marks its start, runs for `seconds`, then marks its end. With `holdFirst`,
    /// the first job's first attempt (attempt 0) sleeps 120 s instead, so it can only end
    /// by being killed: the test proves the kill rather than racing a short sleep against
    /// a slow kill, reap or respawn. Its rerun (attempt 1) takes `seconds` like the rest.
    private func submitJobs(
        _ count: Int, seconds: Double, holdFirst: Bool = false, retryable: Bool = false,
        noRestartReplay: Bool = false
    ) throws -> [String] {
        return try (0..<count).map { index in
            let duration =
                holdFirst && index == 0
                ? "$([ \"$SIMQ_ATTEMPT\" = 0 ] && echo 120 || echo \(seconds))" : "\(seconds)"
            let script =
                "echo $$ >> \"$MARKS/pids\"; echo \"start $SIMQ_JOB_ID $SIMQ_ATTEMPT\" >> \"$MARKS/marks\"; "
                + "sleep \(duration); echo \"end $SIMQ_JOB_ID $SIMQ_ATTEMPT\" >> \"$MARKS/marks\""
            var params = SubmitParams(
                project: "durability", kind: "job\(index)", submitter: "test", exclusive: true, retryable: retryable,
                maxRetries: 2,
                command: ["/bin/sh", "-c", script], environment: ["MARKS": stateDir], cwd: stateDir)
            if noRestartReplay { params.noRestartReplay = true }
            guard case .submit(let response) = try call(.submit(params)) else { throw TestFailure("submit") }
            return response.job.id
        }
    }

    private func marks() -> [String] {
        ((try? String(contentsOfFile: stateDir + "/marks", encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// `replayed`: whether the job that was running when the daemon went away runs again.
    private func restartMidQueue(
        signal: Int32, retryable: Bool = false, noRestartReplay: Bool = false, config: String? = nil,
        replayed: Bool
    ) throws {
        if let config {
            try FileManager.default.createDirectory(
                atPath: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try config.write(toFile: stateDir + "/config.json", atomically: true, encoding: .utf8)
        }
        let first = try startDaemon()
        let ids = try submitJobs(
            4, seconds: 0.3, holdFirst: true, retryable: retryable, noRestartReplay: noRestartReplay)
        // The first job is mid-run, the rest are queued behind it.
        try eventually("job 1 running", timeout: 30) {
            try job(ids[0]).state == .running && marks().contains { $0.hasPrefix("start \(ids[0])") }
        }
        XCTAssertEqual(try job(ids[1]).state, .queued)

        stop(first, signal)
        daemon = nil
        _ = try startDaemon()

        try eventually("every job ends", timeout: 90) {
            try ids.allSatisfy { try job($0).state.isTerminal }
        }
        let infos = try ids.map(job)
        XCTAssertEqual(infos[0].state, replayed ? .succeeded : .interrupted, infos[0].message ?? "")
        for info in infos.dropFirst() { XCTAssertEqual(info.state, .succeeded) }
        let starts = marks().filter { $0.hasPrefix("start \(ids[0]) ") }
        XCTAssertEqual(starts.count, replayed ? 2 : 1, "side-effect marker detects sequential replay: \(marks())")
        XCTAssertEqual(infos[0].attempt, replayed ? 1 : 0)
        let ends = marks().filter { $0.hasPrefix("end ") }
        XCTAssertFalse(ends.contains("end \(ids[0]) 0"), "the interrupted attempt never ran on beside its replay")
        XCTAssertEqual(ends.filter { $0 == "end \(ids[0]) 1" }.count, replayed ? 1 : 0)
        for id in ids.dropFirst() { XCTAssertEqual(ends.filter { $0.hasPrefix("end \(id) ") }.count, 1) }
        XCTAssertEqual(infos.dropFirst().map(\.attempt), [0, 0, 0])
        if !replayed {
            XCTAssertTrue(infos[0].message?.contains("side effects may have occurred") == true, infos[0].message ?? "")
        }
        // Whatever happened to the running job, the restart must not close the queue.
        guard case .status(let status) = try call(.status) else { throw TestFailure("status") }
        XCTAssertFalse(status.draining, "a restart interruption is not an infra failure")
    }

    func testExplicitRetryAllowsOneSequentialReplayWithinTheBudget() throws {
        try restartMidQueue(signal: SIGKILL, retryable: true, replayed: true)
    }

    func testAJobThatOptedOutOfRestartReplayIsInterruptedAndNeverRunsAgain() throws {
        try restartMidQueue(signal: SIGKILL, retryable: true, noRestartReplay: true, replayed: false)
    }

    func testTheInterruptPolicyNeverReplaysStartedNonRetryableWork() throws {
        try restartMidQueue(signal: SIGKILL, config: #"{"restart_recovery": "interrupt"}"#, replayed: false)
    }

    private func stopRecord() -> DaemonStopRecordFile? {
        guard let data = FileManager.default.contents(atPath: stateDir + "/last-stop.json") else { return nil }
        return try? JSONDecoder().decode(DaemonStopRecordFile.self, from: data)
    }

    private struct DaemonStopRecordFile: Decodable {
        var epoch: Int64
        var reason: String
        var exitCode: Int32
        var audited: Bool
        enum CodingKeys: String, CodingKey {
            case epoch, reason, audited
            case exitCode = "exit_code"
        }
    }

    private func daemonEvents() -> [[String: Any]] {
        ((try? String(contentsOfFile: stateDir + "/events.jsonl", encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }.filter { $0["job_id"] == nil }
    }

    private func waitForExit(_ pid: Int32, timeout: Double = 30) throws -> ChildExit {
        var result: ChildExit?
        try eventually("simqd exits", timeout: timeout) {
            result = try ProcessSpawner.reap(pid)
            return result != nil
        }
        daemon = nil
        return try XCTUnwrap(result)
    }

    /// The exit that used to leave nothing behind: status 70, with the reason only in a
    /// pipe that died with the process.
    func testADaemonThatStopsItselfLeavesItsReasonInTheLogTheStopRecordAndTheEventLog() throws {
        let pid = try startDaemon(logToState: true)
        let store = try JobStore(path: SimQueuePaths(stateDir: stateDir).databasePath)
        _ = try store.acquireDaemonLease(ownerID: "usurper", pid: 1, now: Date().timeIntervalSince1970)
        XCTAssertEqual(try waitForExit(pid), .exited(70))
        XCTAssertTrue(
            log().hasSuffix("simqd: stopped: daemon lease lost (epoch 1 is no longer current)\n"),
            "the last line of the log is the reason: \(log().suffix(400))")
        let record = try XCTUnwrap(stopRecord())
        XCTAssertEqual(record.epoch, 1)
        XCTAssertEqual(record.exitCode, 70)
        XCTAssertTrue(record.reason.contains("daemon lease lost"), record.reason)
        XCTAssertTrue(record.audited)
        let stops = daemonEvents().filter { $0["type"] as? String == "daemon_stopped" }
        XCTAssertEqual(stops.count, 1)
        XCTAssertTrue((stops.first?["detail"] as? String)?.contains("daemon lease lost") == true)
    }

    func testTheNextDaemonSaysHowThePreviousOneEnded() throws {
        let first = try startDaemon(logToState: true)
        stop(first, SIGTERM)
        daemon = nil
        XCTAssertTrue(log().hasSuffix("simqd: stopped.\n"), String(log().suffix(300)))
        XCTAssertEqual(stopRecord()?.reason, "requested (SIGTERM)")
        XCTAssertEqual(stopRecord()?.exitCode, 0)

        let second = try startDaemon(logToState: true)
        try eventually("the clean stop is reported", timeout: 15) {
            log().contains("simqd: previous daemon: epoch 1 pid \(first) stopped at ")
                && log().contains("with status 0: requested (SIGTERM)")
        }
        stop(second, SIGKILL)
        daemon = nil

        // A killed daemon is reported as such, not mistaken for the clean stop before it.
        _ = try startDaemon(logToState: true)
        try eventually("the kill is reported", timeout: 15) {
            log().contains("simqd: previous daemon: epoch 2 pid \(second) left no stop record")
        }
        try eventually("the unrecorded exit reaches events.jsonl", timeout: 15) {
            daemonEvents().contains { $0["type"] as? String == "daemon_exit_unrecorded" }
        }
    }

    #if DEBUG
        func testRepeatedCrashBeforeClaimHitsTheCapAndTheNextJobRuns() throws {
            try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
            let store = try JobStore(path: SimQueuePaths(stateDir: stateDir).databasePath)
            let bad = try store.submit(
                JobSubmission(
                    project: "admission", submitter: "test", command: JobCommand(argv: ["/bin/sh", "-c", "exit 0"])),
                now: Date().timeIntervalSince1970
            ).job
            let next = try store.submit(
                JobSubmission(
                    project: "admission", submitter: "test", command: JobCommand(argv: ["/bin/sh", "-c", "exit 0"])),
                now: Date().timeIntervalSince1970
            ).job
            for _ in 0...JobStore.defaultMaxRestartRequeues {
                let pid = try startDaemon(crashBeforeClaim: bad.id, waitForReady: false)
                try eventually("fault hook kills the daemon", timeout: 20) {
                    guard let exit = try ProcessSpawner.reap(pid) else { return false }
                    XCTAssertEqual(exit.shellStatus, 128 + SIGKILL)
                    return true
                }
                daemon = nil
            }
            _ = try startDaemon(crashBeforeClaim: bad.id)
            try eventually("next job finishes after the cap", timeout: 20) { try job(next.id).state == .succeeded }
            let capped = try job(bad.id)
            XCTAssertEqual(capped.state, .infraFailed)
            XCTAssertEqual(capped.resultClass, .internalError)
            XCTAssertEqual(capped.attempt, JobStore.defaultMaxRestartRequeues)
            XCTAssertNil(capped.startedAt, "the fault happened before claim and spawn")
            XCTAssertTrue(capped.message?.contains("cap 3") == true, capped.message ?? "")
            XCTAssertTrue(log().contains("restart_cap=1"), log())
        }
    #endif

    func testSIGTERMMidQueueEveryJobCompletes() throws {
        try restartMidQueue(signal: SIGTERM, replayed: true)
    }

    func testKill9MidQueueEveryJobCompletes() throws {
        try restartMidQueue(signal: SIGKILL, replayed: true)
    }
}
