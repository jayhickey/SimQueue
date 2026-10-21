// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueProtocol
import SimQueueStore
import XCTest

/// The process executor end to end: a real daemon on a real socket running small `sh`
/// commands in their own process groups. No simulators, no Xcode tools, nothing outside
/// temp directories.
final class ProcessExecutorTests: XCTestCase {
    private var daemon: TestDaemon!

    override func setUpWithError() throws {
        var config = DaemonConfig()
        config.timeouts.killGraceSeconds = 0.5
        daemon = try TestDaemon(config: config, realProcesses: true)
    }

    override func tearDown() {
        daemon?.destroy()
    }

    private func command(
        _ script: String, environment: [String: String]? = nil, cwd: String? = nil, timeout: Double? = nil
    ) -> SubmitParams {
        SubmitParams(
            project: "app", submitter: "dev", runTimeoutSeconds: timeout, command: ["/bin/sh", "-c", script],
            environment: environment, cwd: cwd)
    }

    private func run(_ params: SubmitParams) throws -> JobInfo {
        try daemon.wait(try daemon.submit(params).job.id)
    }

    /// Polls until `condition` holds (real time; the daemon ticks every 20 ms).
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

    private func processGroup(of jobID: String) throws -> (resource: OwnedResource, pgid: Int32) {
        let resource = try XCTUnwrap(
            try daemon.side.resources(jobID: jobID).first { $0.kind == .processGroup }, "no process group recorded")
        return (resource, try XCTUnwrap(Int32(resource.externalID)))
    }

    func testSuccessWritesLogAndSummaryWithJobEnvironment() throws {
        let job = try run(
            command(
                #"echo "hello $GREETING $SIMQ_JOB_ID attempt=$SIMQ_ATTEMPT project=$SIMQ_PROJECT"; pwd; echo err >&2"#,
                environment: ["GREETING": "world"], cwd: "/"))
        XCTAssertEqual(job.state, .succeeded)
        XCTAssertEqual(job.resultClass, .success)
        XCTAssertEqual(job.commandExitCode, 0)
        XCTAssertEqual(job.exitCode, .success)
        XCTAssertEqual(job.command, ["/bin/sh", "-c", job.command?.last ?? ""])
        XCTAssertEqual(job.cwd, "/")
        XCTAssertEqual(job.environmentKeys, ["GREETING"], "names only, never values")

        let logPath = try XCTUnwrap(job.logPath)
        let day = String(job.queueTime.rfc3339.prefix(10))
        XCTAssertEqual(logPath, daemon.paths.jobsRoot + "/\(day)/\(job.id)/combined.log")
        let log = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertTrue(log.contains("hello world \(job.id) attempt=0 project=app\n/\nerr\n"), log)
        XCTAssertTrue(log.hasPrefix("=== simq \(job.id) attempt 0 at "), log)
        XCTAssertTrue(log.contains("=== simq: command exited with status 0"), log)

        let summary = try String(
            contentsOfFile: daemon.paths.jobsRoot + "/\(day)/\(job.id)/job.json", encoding: .utf8)
        XCTAssertTrue(summary.contains(#""command_exit_code" : 0"#), summary)
        XCTAssertTrue(summary.contains(#""state" : "succeeded""#), summary)
        XCTAssertFalse(summary.contains("world"), "environment values stay out of job.json")

        try eventually("process group released") {
            try daemon.side.resources(jobID: job.id).allSatisfy { $0.state == .released }
        }
    }

    func testEachJobGetsItsOwnTmpDirRemovedAfterTheGroupExits() throws {
        let job = try run(command(#"echo "tmp=$TMPDIR simq=$SIMQ_TMPDIR"; echo x > "$TMPDIR/scratch""#))
        XCTAssertEqual(job.state, .succeeded)
        let directory = (try XCTUnwrap(job.logPath) as NSString).deletingLastPathComponent
        let tmp = directory + "/tmp"
        let log = try String(contentsOfFile: try XCTUnwrap(job.logPath), encoding: .utf8)
        XCTAssertTrue(log.contains("tmp=\(tmp) simq=\(tmp)\n"), log)
        try eventually("tmp removed after the group exits") { !FileManager.default.fileExists(atPath: tmp) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory + "/combined.log"), "only tmp goes")
    }

    func testAJobsOwnTMPDIRWins() throws {
        let job = try run(command(#"echo "tmp=$TMPDIR""#, environment: ["TMPDIR": "/var/tmp"]))
        let log = try String(contentsOfFile: try XCTUnwrap(job.logPath), encoding: .utf8)
        XCTAssertTrue(log.contains("tmp=/var/tmp\n"), log)
    }

    func testEachJobLeadsItsOwnProcessGroup() throws {
        let id = try daemon.submit(command("sleep 5")).job.id
        try eventually("running") { try daemon.job(id).state == .running }
        let (_, pgid) = try processGroup(of: id)
        XCTAssertNotEqual(pgid, getpgrp())
        XCTAssertTrue(try SystemProcessTable().isGroupLive(pgid))
        #if os(Linux)
            let stat = try String(contentsOfFile: "/proc/\(pgid)/stat", encoding: .utf8)
            XCTAssertEqual(SystemProcessTableProbe.pgid(stat), pgid, "the leader's pid is its group id")
        #endif
        _ = try daemon.result(.cancel(CancelParams(jobID: id)))
        try eventually("group gone") { try !SystemProcessTable().isGroupLive(pgid) }
    }

    func testRecordsTheLeaderIdentityAtSpawn() throws {
        let id = try daemon.submit(command("sleep 5")).job.id
        try eventually("running") { try daemon.job(id).state == .running }
        let (resource, pgid) = try processGroup(of: id)
        let identity = try XCTUnwrap(resource.identity, "process group recorded without identity")
        XCTAssertEqual(try SystemProcessTable().processIdentity(pgid), identity)
        XCTAssertEqual(try SystemProcessTable().verifyGroup(pgid, identity: identity), .verified)
        XCTAssertEqual(try SystemProcessTable().verifyGroup(pgid, identity: "\(identity)x"), .reused)
        _ = try daemon.result(.cancel(CancelParams(jobID: id)))
        try eventually("group gone") { try !SystemProcessTable().isGroupLive(pgid) }
        XCTAssertEqual(try SystemProcessTable().verifyGroup(pgid, identity: identity), .gone)
    }

    func testTheCommandCarriesItsSpawnTokenAndCanBeFoundByIt() throws {
        let id = try daemon.submit(command(#"echo "token=$SIMQ_SPAWN_TOKEN"; sleep 5"#)).job.id
        try eventually("running") { try daemon.job(id).state == .running }
        let (resource, pgid) = try processGroup(of: id)
        XCTAssertFalse(resource.externalID.hasPrefix("intent:"), "resolved right after the spawn")
        let logPath = try XCTUnwrap(try daemon.job(id).logPath)
        var token = ""
        try eventually("token logged") {
            let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            token = log.split(separator: "\n").first { $0.hasPrefix("token=") }.map { String($0.dropFirst(6)) } ?? ""
            return !token.isEmpty
        }
        XCTAssertTrue(token.contains(id), token)
        guard SystemProcessTable().supportsEnvironmentScan else {
            // Some macOS releases hide other processes' environments (#47). Recovery then
            // interrupts the job instead of guessing (SpawnIntentTests covers that path).
            XCTAssertTrue(try SystemProcessTable().processes(withEnvironmentEntry: "SIMQ_SPAWN_TOKEN=\(token)").isEmpty)
            _ = try daemon.result(.cancel(CancelParams(jobID: id)))
            try eventually("group gone") { try !SystemProcessTable().isGroupLive(pgid) }
            throw XCTSkip("this host can't read other processes' environments; the token was still set")
        }
        let matches = try SystemProcessTable().processes(withEnvironmentEntry: "SIMQ_SPAWN_TOKEN=\(token)")
        XCTAssertTrue(matches.contains(ProcessMatch(pid: pgid, pgid: pgid)), "\(matches) vs \(pgid)")
        XCTAssertTrue(try SystemProcessTable().processes(withEnvironmentEntry: "SIMQ_SPAWN_TOKEN=\(token)x").isEmpty)
        _ = try daemon.result(.cancel(CancelParams(jobID: id)))
        try eventually("group gone") { try !SystemProcessTable().isGroupLive(pgid) }
    }

    func testNonZeroExitIsACommandFailureWithItsStatus() throws {
        let job = try run(command("echo failing; exit 3"))
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.resultClass, .commandFailure)
        XCTAssertEqual(job.commandExitCode, 3)
        XCTAssertEqual(job.exitCode, .testFailure, "simq exits 1 for a failed command")
        XCTAssertEqual(job.message, "command exited with status 3")
    }

    func testSignalDeathRecordsShellStyleStatus() throws {
        let job = try run(command("kill -KILL $$"))
        XCTAssertEqual(job.resultClass, .commandFailure)
        XCTAssertEqual(job.commandExitCode, 128 + 9)
        XCTAssertEqual(job.message, "command killed by signal 9")
    }

    func testMissingExecutableAndMissingDirectoryFailWithoutSpawning() throws {
        let missing = try run(
            SubmitParams(project: "app", submitter: "dev", command: ["simq-definitely-not-a-command"]))
        XCTAssertEqual(missing.resultClass, .commandFailure)
        XCTAssertEqual(missing.commandExitCode, 127)
        XCTAssertEqual(missing.message, "command not found: simq-definitely-not-a-command")

        let noDirectory = try run(command("true", cwd: "/simq-no-such-directory"))
        XCTAssertEqual(noDirectory.resultClass, .commandFailure)
        XCTAssertNil(noDirectory.commandExitCode)
        XCTAssertEqual(noDirectory.message, "working directory /simq-no-such-directory does not exist")
        XCTAssertTrue(try daemon.side.resources(jobID: noDirectory.id).isEmpty, "nothing was started")
    }

    func testSubmitValidatesCommands() throws {
        let noCommand = try daemon.protocolError(.submit(SubmitParams(project: "app", submitter: "dev")))
        XCTAssertEqual(noCommand.code, .invalidArgument)
        XCTAssertTrue(noCommand.message.contains("pass one after --"), noCommand.message)
        for (environment, cwd) in [
            (["SIMQ_JOB_ID": "x"], nil), (["1BAD": "x"], nil), (["A-B": "x"], nil),
            ([String: String](), "relative/dir"),
        ] as [([String: String], String?)] {
            let error = try daemon.protocolError(.submit(command("true", environment: environment, cwd: cwd)))
            XCTAssertEqual(error.code, .invalidArgument, "\(environment) \(cwd ?? "")")
        }
        let environmentWithoutCommand = try daemon.protocolError(
            .submit(SubmitParams(project: "app", submitter: "dev", environment: ["A": "b"])))
        XCTAssertEqual(environmentWithoutCommand.code, .invalidArgument)
    }

    func testRunTimeoutStopsTheWholeGroupAndRecordsTheStatus() throws {
        let job = try run(command("sleep 30 & sleep 30; wait", timeout: 0.3))
        XCTAssertEqual(job.state, .timedOut)
        XCTAssertEqual(job.exitCode, .timedOut)
        let (_, pgid) = try processGroup(of: job.id)
        XCTAssertFalse(try SystemProcessTable().isGroupLive(pgid), "timed_out is recorded only once the group is gone")
        try eventually("leader status recorded") { try daemon.job(job.id).commandExitCode == 128 + 15 }
    }

    func testAnExitCausedByTheRunTimeoutIsStillATimeout() throws {
        // SIGTERM kills the leader at once, but the group keeps looking live for a few
        // polls (as a dying process can on macOS), so the executor reaps the leader before
        // the timeout path sees the group gone. The job must still end `timed_out`, not
        // `command_failure`.
        daemon.destroy()
        var config = DaemonConfig()
        config.timeouts.killGraceSeconds = 5
        daemon = try TestDaemon(config: config, realProcesses: true, processTable: LaggingProcessTable(lagPolls: 4))
        let job = try run(command("sleep 30", timeout: 0.3))
        XCTAssertEqual(job.state, .timedOut)
        XCTAssertEqual(job.resultClass, .runTimeout)
        XCTAssertEqual(job.commandExitCode, 128 + 15, "the status is recorded before timed_out")
    }

    func testCancelEscalatesToKillWhenTermIsIgnored() throws {
        let id = try daemon.submit(command(#"trap "" TERM; echo ready; sleep 30"#)).job.id
        try eventually("running") { try daemon.job(id).state == .running }
        let (resource, pgid) = try processGroup(of: id)
        // Cancel only once the trap is in place. "running" means spawned, not that the shell
        // has run its first line: on macOS (slower exec of /bin/sh) a SIGTERM sent right away
        // killed the shell before `trap` ran (#47).
        let logPath = try XCTUnwrap(try daemon.job(id).logPath)
        try eventually("trap installed") {
            ((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "").contains("ready\n")
        }
        let canceled = try daemon.result(.cancel(CancelParams(jobID: id)))
        guard case .job(let info) = canceled else { return XCTFail("not a job") }
        XCTAssertEqual(info.state, .canceled)
        try eventually("group killed") { try !SystemProcessTable().isGroupLive(pgid) }
        try eventually("resource released") { try daemon.side.resource(id: resource.id)?.state == .released }
        try eventually("leader status recorded") { try daemon.job(id).commandExitCode == 128 + 9 }
        let audit = try daemon.side.auditEntries().filter { $0.resourceID == resource.id }.map(\.type)
        XCTAssertTrue(audit.contains("leftover_kill"), "\(audit)")
        XCTAssertFalse(audit.contains("cleanup_failed"), "\(audit)")
    }

    func testLeftoverBackgroundProcessesAreStoppedAfterTheJobEnds() throws {
        let id = try daemon.submit(command(#"(trap "" TERM; exec sleep 30) & echo started"#)).job.id
        try eventually("leader exit observed") { try daemon.job(id).state == .succeeded }
        let job = try daemon.job(id)
        XCTAssertEqual(job.state, .succeeded, "the job is its leader's exit")
        let (resource, pgid) = try processGroup(of: job.id)
        XCTAssertEqual(try ProcessSpawner.peekExit(pgid), .exited(0), "exit is observed without reaping the leader")
        XCTAssertEqual(
            try SystemProcessTable().processIdentity(pgid), resource.identity,
            "the zombie leader reserves its original identity while the descendant is stopped")
        try eventually("leftover killed") { try !SystemProcessTable().isGroupLive(pgid) }
        try eventually("resource released") { try daemon.side.resource(id: resource.id)?.state == .released }
        let audit = try daemon.side.auditEntries().filter { $0.resourceID == resource.id }.map(\.type)
        XCTAssertEqual(audit.filter { $0.hasPrefix("leftover_") }, ["leftover_term", "leftover_kill"])
        try eventually("retained leader reaped") { try SystemProcessTable().processIdentity(pgid) != resource.identity }
        let completed = try daemon.wait(job.id)
        XCTAssertNil(completed.cleanupPending, "wait completes only after descendants have stopped")
        XCTAssertFalse(try SystemProcessTable().isGroupLive(pgid))
    }

    func testUnverifiableGroupIsOrphanedWithoutSignals() throws {
        daemon.destroy()
        let table = IdentityHidingProcessTable()
        daemon = try TestDaemon(realProcesses: true, processTable: table)
        let id = try daemon.submit(command("trap '' TERM; echo ready; sleep 30")).job.id
        try eventually("running") { try daemon.job(id).state == .running }
        let (resource, pgid) = try processGroup(of: id)
        defer {
            // Test-only cleanup of the exact process this test created, with its
            // original identity checked independently of the intentionally blind fake.
            if (try? SystemProcessTable().processIdentity(pgid)) == resource.identity {
                try? SystemProcessTable().terminateGroup(pgid, graceSeconds: 0.05)
            }
        }
        let log = try XCTUnwrap(try daemon.job(id).logPath)
        try eventually("trap installed") {
            ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").contains("ready\n")
        }
        table.hideIdentity(of: pgid)
        _ = try daemon.result(.cancel(CancelParams(jobID: id)))
        try eventually("unverified group orphaned") { try daemon.side.resource(id: resource.id)?.state == .orphaned }
        XCTAssertTrue(table.signals.isEmpty, "neither cancellation nor executor cleanup may signal an unverified group")
        XCTAssertTrue(try SystemProcessTable().isGroupLive(pgid))
        let blocked = try daemon.wait(id)
        XCTAssertEqual(
            blocked.cleanupBlocked, true, "wait reports manual cleanup instead of hanging or claiming completion")
        guard case .logs(let logResult) = try daemon.result(.logs(LogsParams(jobID: id))) else {
            return XCTFail("no logs result")
        }
        XCTAssertTrue(logResult.jobFinished, "log following must stop for explicitly blocked cleanup")
        XCTAssertTrue(
            try daemon.engine.jobsWithLiveProcessGroups().contains(id),
            "reported blocked cleanup still holds host capacity")
    }

    func testLogsFollowAcrossChunksWithoutSplittingCharacters() throws {
        let text = String(repeating: "é€😀a", count: 50)
        let id = try daemon.submit(command("printf '%s' '\(text)'; sleep 0.3; echo; echo done")).job.id
        var offset: Int64 = 0
        var collected = ""
        var finished = false
        let deadline = Date().addingTimeInterval(10)
        while !finished, Date() < deadline {
            guard case .logs(let chunk) = try daemon.result(.logs(LogsParams(jobID: id, offset: offset, maxBytes: 5)))
            else { return XCTFail("not logs") }
            XCTAssertFalse(chunk.data.contains("\u{FFFD}"), "chunk split a character: \(chunk)")
            XCTAssertGreaterThanOrEqual(chunk.nextOffset, offset)
            collected += chunk.data
            offset = chunk.nextOffset
            finished = chunk.jobFinished && chunk.atEnd
            if chunk.atEnd && !finished { Thread.sleep(forTimeInterval: 0.02) }
        }
        XCTAssertTrue(finished)
        XCTAssertTrue(collected.contains(text + "\ndone\n"), collected)

        let unknown = try daemon.protocolError(.logs(LogsParams(jobID: "J-9999")))
        XCTAssertEqual(unknown.code, .notFound)
    }

    func testInfraRetryAfterArtifactFailureThenSuccess() throws {
        // The log directory can't be created while a plain file sits where the date
        // directory goes; that's an artifact (infra) failure, retried for a retryable job.
        let day = String(Timestamp(Date().timeIntervalSince1970).rfc3339.prefix(10))
        try FileManager.default.createDirectory(atPath: daemon.paths.jobsRoot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: daemon.paths.jobsRoot + "/" + day, contents: Data())
        var params = command("echo ok")
        params.retryable = true
        // A retry can be re-admitted on the next 20 ms tick, before the test removes the
        // file, so allow a few: the point is that an artifact failure is retried.
        params.maxRetries = 3
        let id = try daemon.submit(params).job.id
        try eventually("first attempt failed and was requeued") { try daemon.job(id).attempt >= 1 }
        try FileManager.default.removeItem(atPath: daemon.paths.jobsRoot + "/" + day)
        let job = try daemon.wait(id)
        XCTAssertEqual(job.state, .succeeded)
        XCTAssertGreaterThanOrEqual(job.attempt, 1)
        XCTAssertTrue(try daemon.side.events(jobID: id).contains("infra_retry"))
    }
}

/// Reads the process group field of a `/proc/<pid>/stat` line (test helper).
enum SystemProcessTableProbe {
    static func pgid(_ stat: String) -> Int32? {
        guard let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        return fields.count >= 3 ? Int32(fields[2]) : nil
    }
}

final class SystemProcessTableTests: XCTestCase {
    func testProcessIdentityIsStableAndAbsentForMissingPIDs() throws {
        let table = SystemProcessTable()
        let mine = try XCTUnwrap(try table.processIdentity(getpid()))
        XCTAssertEqual(try table.processIdentity(getpid()), mine)
        #if os(Linux)
            XCTAssertTrue(mine.hasPrefix("linux:"), mine)
        #else
            XCTAssertTrue(mine.hasPrefix("darwin:"), mine)
        #endif
        XCTAssertNil(try table.processIdentity(0))
        XCTAssertNil(try table.processIdentity(Int32.max))
    }

    func testParsesStartTimeAfterTheCommandName() {
        // The command name may contain spaces and parentheses; field 22 is counted after the last ')'.
        let fields = (3...30).map { $0 == 22 ? "987654" : "\($0)" }.joined(separator: " ")
        XCTAssertEqual(SystemProcessTable.parseStartTime("42 (a b) c) " + fields), 987_654)
        XCTAssertNil(SystemProcessTable.parseStartTime("42 (short) S 1 2"))
        XCTAssertNil(SystemProcessTable.parseStartTime("garbage"))
    }

    func testRefusesGroupsThatAreNotJobGroups() {
        let table = SystemProcessTable()
        for pgid in [Int32(0), 1, -1, getpgrp()] {
            XCTAssertThrowsError(try table.signalGroup(pgid, .term), "\(pgid)")
        }
    }

    func testSignallingAGoneGroupIsNotAnError() throws {
        // A pid far above any default pid_max is never a live group.
        XCTAssertNoThrow(try SystemProcessTable().signalGroup(4_000_000, .term))
    }

    func testEnvironmentIsReadFromAProcArgsBuffer() {
        var buffer: [UInt8] = [2, 0, 0, 0]
        for part in ["/bin/sh", "", "", "sh", "-c", "A=1", "B=x=y", "", "junk"] {
            buffer += Array(part.utf8) + [0]
        }
        XCTAssertEqual(SystemProcessTable.environment(fromProcArgs: buffer), ["A=1", "B=x=y"])
        XCTAssertEqual(SystemProcessTable.environment(fromProcArgs: [1, 0]), [])
    }

    func testChildExitDecoding() {
        XCTAssertEqual(ChildExit.exited(3).shellStatus, 3)
        XCTAssertEqual(ChildExit.signaled(15).shellStatus, 143)
    }

    func testResolveExecutable() throws {
        XCTAssertEqual(ProcessSpawner.resolveExecutable("sh", path: "/nonexistent:/bin", cwd: nil), "/bin/sh")
        XCTAssertNil(ProcessSpawner.resolveExecutable("sh", path: "/nonexistent", cwd: nil))
        XCTAssertEqual(ProcessSpawner.resolveExecutable("/bin/sh", path: nil, cwd: nil), "/bin/sh")
        XCTAssertEqual(ProcessSpawner.resolveExecutable("bin/sh", path: nil, cwd: "/"), "//bin/sh")
        XCTAssertNil(ProcessSpawner.resolveExecutable("/bin", path: nil, cwd: nil), "directories don't run")
    }

    #if os(Linux)
        func testLiveGroupsIncludeOwnGroupAndSkipZombies() throws {
            let table = SystemProcessTable()
            XCTAssertTrue(try table.liveProcessGroups().contains(getpgrp()))
            let log = NSTemporaryDirectory() + "simq-zombie-\(UUID().uuidString).log"
            defer { try? FileManager.default.removeItem(atPath: log) }
            let pid = try ProcessSpawner.spawn(
                executable: "/bin/sh", argv: ["sh", "-c", "exit 0"], environment: [:], cwd: nil, outputPath: log)
            // Unreaped, the child is a zombie: its group must not count as live.
            let deadline = Date().addingTimeInterval(5)
            while try table.isGroupLive(pid), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertFalse(try table.isGroupLive(pid))
            XCTAssertNotNil(try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), "still a zombie")
            var exit: ChildExit?
            while exit == nil { exit = try ProcessSpawner.reap(pid) }
            XCTAssertEqual(exit, .exited(0))
        }
    #endif
}

/// Injects failed identity reads without weakening real signal or liveness behavior.
private final class IdentityHidingProcessTable: ProcessTable, @unchecked Sendable {
    private let base = SystemProcessTable()
    private let lock = NSLock()
    private var hiddenPID: Int32?
    private var recordedSignals: [ProcessSignal] = []
    var signals: [ProcessSignal] { lock.withLock { recordedSignals } }
    func hideIdentity(of pid: Int32) { lock.withLock { hiddenPID = pid } }
    func liveProcessGroups() throws -> Set<Int32> { try base.liveProcessGroups() }
    func processIdentity(_ pid: Int32) throws -> String? {
        if lock.withLock({ hiddenPID == pid }) { return nil }
        return try base.processIdentity(pid)
    }
    func signalGroup(_ pgid: Int32, _ signal: ProcessSignal) throws {
        lock.withLock { recordedSignals.append(signal) }
        try base.signalGroup(pgid, signal)
    }
    func terminateGroup(_ pgid: Int32, graceSeconds: Double) throws {
        try base.terminateGroup(pgid, graceSeconds: graceSeconds)
    }
}
