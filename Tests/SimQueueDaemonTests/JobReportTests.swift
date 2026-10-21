// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueProtocol
import XCTest

/// `summary.md`, the job's `events.jsonl` and the daemon-wide append-only event log
/// (spec §5i), from real `sh` jobs over the socket.
final class JobReportTests: XCTestCase {
    private var daemon: TestDaemon!

    override func setUpWithError() throws {
        daemon = try TestDaemon(realProcesses: true)
    }

    override func tearDown() {
        daemon?.destroy()
    }

    private func run(_ script: String) throws -> JobInfo {
        let params = SubmitParams(
            project: "app", kind: "unit", submitter: "dev", command: ["/bin/sh", "-c", script], cwd: "/")
        return try daemon.wait(try daemon.submit(params).job.id)
    }

    private func lines(_ path: String) throws -> [[String: Any]] {
        try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    /// The job files are written right after the job ends; poll briefly for them.
    private func file(_ path: String) throws -> String {
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: path), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    func testAFailedJobGetsASummaryWithItsLogTailAndItsEvents() throws {
        let job = try run("echo first; echo 'it broke' >&2; exit 3")
        let dir = try XCTUnwrap(job.runDir)
        let summary = try file(dir + "/summary.md")
        XCTAssertTrue(summary.hasPrefix("# \(job.id): failed\n"), summary)
        for expected in [
            "- **Project:** app", "- **Kind:** unit", "- **Result:** command_failure", "- **Command exit code:** 3",
            "- **Queue wait:**", "- **Run time:**", "## Log tail", "it broke",
        ] {
            XCTAssertTrue(summary.contains(expected), "missing \(expected) in\n\(summary)")
        }
        let events = try lines(dir + "/events.jsonl")
        let types = events.compactMap { $0["type"] as? String }
        XCTAssertEqual(types.first, "queued")
        XCTAssertTrue(types.contains("failed"), "\(types)")
        XCTAssertTrue(events.allSatisfy { $0["job_id"] as? String == job.id && $0["at"] is String })
        XCTAssertFalse(
            job.artifacts?.contains { ["summary.md", "events.jsonl"].contains($0.path) } ?? false,
            "daemon-owned files aren't listed as artifacts")
    }

    func testASucceededJobsSummaryHasNoLogTail() throws {
        let job = try run("echo fine")
        let summary = try file(try XCTUnwrap(job.runDir) + "/summary.md")
        XCTAssertTrue(summary.hasPrefix("# \(job.id): succeeded\n"))
        XCTAssertFalse(summary.contains("## Log tail"))
    }

    func testTheDaemonWritesItsEventLogNextToTheStore() throws {
        let first = try run("true")
        let second = try run("true")
        let path = daemon.paths.stateDir + "/events.jsonl"
        let deadline = Date().addingTimeInterval(5)
        func ids() throws -> [String] { try lines(path).compactMap { $0["job_id"] as? String } }
        while try !(FileManager.default.fileExists(atPath: path) && ids().contains(second.id)), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(try ids().contains(first.id))
        XCTAssertTrue(try ids().contains(second.id))
    }

    /// The resume tests use their own file, so the daemon's own log (which keeps
    /// appending to `events.jsonl` every tick) can't race them.
    private func ownLog() throws -> String {
        _ = try run("true")
        _ = try run("true")
        return daemon.paths.stateDir + "/resume.jsonl"
    }

    private func seqs(_ path: String) throws -> [Int64] {
        try lines(path).compactMap { ($0["seq"] as? NSNumber)?.int64Value }
    }

    func testAnEventLogIsAppendOnlyAndResumesWithoutDuplicates() throws {
        let path = try ownLog()
        try EventLog(path: path).append(from: daemon.side)
        let before = try seqs(path)
        XCTAssertFalse(before.isEmpty)
        XCTAssertEqual(before, before.sorted())
        // A restarted daemon (a new log on the same file) carries on after the last line.
        _ = try run("true")
        try EventLog(path: path).append(from: daemon.side)
        let after = try seqs(path)
        XCTAssertEqual(Set(after).count, after.count, "resuming wrote no duplicates")
        XCTAssertEqual(Array(after.prefix(before.count)), before, "earlier lines are untouched")
        XCTAssertGreaterThan(after.count, before.count)
    }

    /// `kill -9` mid-write leaves a last line without its newline. The next daemon cuts
    /// it and resumes after the last whole line: each event once, nothing glued together.
    func testATornLastLineIsCutAndNothingIsDuplicated() throws {
        let path = try ownLog()
        try EventLog(path: path).append(from: daemon.side)
        let whole = try seqs(path)
        let lastLine = try XCTUnwrap(try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").last)
        // Tear the last line in half.
        let text = try String(contentsOfFile: path, encoding: .utf8)
        try String(text.dropLast(lastLine.count / 2 + 1)).write(toFile: path, atomically: false, encoding: .utf8)
        try EventLog(path: path).append(from: daemon.side)
        let after = try seqs(path)
        XCTAssertEqual(Array(after.prefix(whole.count)), whole, "the torn event is written again")
        XCTAssertEqual(Set(after).count, after.count, "and only once")
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).hasSuffix("\n"))
    }

    /// A torn line longer than one 64 KiB scan block, after a whole line that is too.
    /// Deterministic on a busy host: the whole line's seq is fixed and below anything the
    /// store has, and the assertions only need what follows to be newer.
    func testResumingFindsTheLastWholeLineAcrossLongLines() throws {
        _ = try run("true")
        let path = daemon.paths.stateDir + "/long.jsonl"
        let long = String(repeating: "x", count: 200 * 1024)
        let whole = #"{"seq":2,"detail":"\#(long)"}"# + "\n"
        let torn = #"{"seq":3,"detail":"\#(long)"#
        try (#"{"seq":1}"# + "\n" + whole + torn).write(toFile: path, atomically: false, encoding: .utf8)
        XCTAssertEqual(EventLog.lastSeq(in: path), 2, "the scan skips the torn line, back past 64 KiB")
        try EventLog(path: path).append(from: daemon.side)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(#"{"seq":1}"# + "\n" + whole), "whole lines are kept")
        XCTAssertFalse(text.contains(torn), "the torn line is cut")
        let added = try seqs(path).dropFirst(2)
        XCTAssertFalse(added.isEmpty, "the job's events follow")
        XCTAssertTrue(added.allSatisfy { $0 > 2 }, "resumed after seq 2: \(added)")
        XCTAssertEqual(Set(added).count, added.count)
    }

    /// No newline within the scan limit: the tail can't be told apart from good lines, so
    /// nothing is cut (only a newline is added) and the log resumes after the store's
    /// newest event, never re-appending history from `.1` or seq 0.
    func testAScanThatGivesUpCutsNothingAndResumesAfterTheStore() throws {
        _ = try run("true")
        let path = daemon.paths.stateDir + "/gaveup.jsonl"
        let good = #"{"seq":1}"# + "\n"
        let fragment = String(repeating: "y", count: 4096)
        try (good + fragment).write(toFile: path, atomically: false, encoding: .utf8)
        // History in `.1` that a fallback would resume from (and so duplicate).
        try (#"{"seq":1}"# + "\n").write(toFile: path + ".1", atomically: false, encoding: .utf8)

        try EventLog.truncateTornTail(path, limit: 1024)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), good + fragment + "\n", "nothing cut")
        XCTAssertEqual(EventLog.scanLastSeq(in: path, limit: 1024), .gaveUp)
        XCTAssertEqual(EventLog.scanLastSeq(in: path), .seq(1), "with the full limit it's found")

        try (good + fragment).write(toFile: path, atomically: false, encoding: .utf8)
        let newest = try XCTUnwrap(try daemon.side.latestAuditSeq())
        let log = EventLog(path: path, scanLimit: 1024)
        try log.append(from: daemon.side)
        XCTAssertEqual(
            try String(contentsOfFile: path, encoding: .utf8).prefix(good.count + fragment.count + 1),
            Substring(good + fragment + "\n"), "good lines and the fragment are kept")
        let job = try run("true")
        try log.append(from: daemon.side)
        let added = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").dropFirst(2).map {
            try XCTUnwrap(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let addedSeqs = added.compactMap { ($0["seq"] as? NSNumber)?.int64Value }
        XCTAssertTrue(addedSeqs.allSatisfy { $0 > newest }, "only events after the store's newest: \(addedSeqs)")
        XCTAssertTrue(added.contains { $0["job_id"] as? String == job.id })
    }

    /// The scan-limit cases of `truncateTornTail`: a single torn line that reaches the start
    /// of the file is cut to empty; one longer than the limit isn't.
    func testTruncationToEmptyOnlyWhenTheScanReachesTheStart() throws {
        let path = daemon.paths.stateDir + "/single.jsonl"
        try #"{"seq":1,"det"#.write(toFile: path, atomically: false, encoding: .utf8)
        try EventLog.truncateTornTail(path, limit: 1024)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "", "one torn line, nothing else: cut")
        let long = String(repeating: "z", count: 2048)
        try long.write(toFile: path, atomically: false, encoding: .utf8)
        try EventLog.truncateTornTail(path, limit: 1024)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), long + "\n", "gave up: kept")
    }

    /// A last line that ends in a newline but doesn't parse is skipped, not trusted.
    func testLastSeqSkipsBackOverAnUnparseableLine() throws {
        let path = daemon.paths.stateDir + "/junk.jsonl"
        try (#"{"seq":7}"# + "\n" + "garbage\n").write(toFile: path, atomically: false, encoding: .utf8)
        XCTAssertEqual(EventLog.lastSeq(in: path), 7)
        XCTAssertNil(EventLog.lastSeq(in: daemon.paths.stateDir + "/missing.jsonl"))
    }

    /// `writeSummary` reads a job's audit entries under the lock at every job end;
    /// make sure that's an index lookup, not a table scan.
    func testAJobsAuditEntriesAreReadByIndex() throws {
        let plan = try daemon.side.database.query(
            "EXPLAIN QUERY PLAN SELECT * FROM audit_log WHERE job_id = ? ORDER BY seq;", [.text("J-0001")])
        let detail = plan.compactMap { $0.string("detail") }.joined(separator: "; ")
        XCTAssertTrue(detail.contains("audit_log_job_idx"), detail)
    }

    func testTheEventLogRotatesPastItsSize() throws {
        let path = daemon.paths.stateDir + "/rotating.jsonl"
        _ = try run("true")
        let log = EventLog(path: path, rotateBytes: 1)
        try log.append(from: daemon.side)
        _ = try run("true")
        try log.append(from: daemon.side)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".1"), "the old generation is kept")
        let old = try lines(path + ".1").compactMap { ($0["seq"] as? NSNumber)?.int64Value }
        let new = try lines(path).compactMap { ($0["seq"] as? NSNumber)?.int64Value }
        XCTAssertLessThan(try XCTUnwrap(old.max()), try XCTUnwrap(new.min()))
    }
}
