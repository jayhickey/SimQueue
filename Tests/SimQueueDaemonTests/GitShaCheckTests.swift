// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueProtocol
import XCTest

/// `git_sha` is checked against the worktree at submit and again just before the command
/// starts (spec §5k). Uses a real `git` on a throwaway repo; skipped where git is missing.
final class GitShaCheckTests: XCTestCase {
    private var daemon: TestDaemon!
    private var repo: String!

    override func setUpWithError() throws {
        guard (try? ToolRunner().run("git", ["--version"], timeoutSeconds: 10))?.succeeded == true else {
            throw XCTSkip("git is not installed")
        }
        repo = testScratchRoot() + "/sqg-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try git("init", "-q")
        try commit("one")
        var config = DaemonConfig()
        config.timeouts.killGraceSeconds = 0.5
        daemon = try TestDaemon(config: config, realProcesses: true)
    }

    override func tearDown() {
        daemon?.destroy()
        if let repo { try? FileManager.default.removeItem(atPath: repo) }
    }

    @discardableResult
    private func git(_ arguments: String...) throws -> String {
        let runner = ToolRunner(
            environment: ProcessInfo.processInfo.environment.merging([
                "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t",
                "GIT_COMMITTER_EMAIL": "t@example.com", "GIT_CONFIG_NOSYSTEM": "1", "HOME": repo,
            ]) { _, new in new })
        return try runner.check("git", ["-C", repo] + arguments, timeoutSeconds: 20)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ message: String) throws {
        try git("commit", "-q", "--allow-empty", "-m", message)
    }

    private func submit(
        sha: String?, worktree: String? = nil, script: String = "true", exclusive: Bool? = nil
    ) -> SubmitParams {
        SubmitParams(
            project: "app", submitter: "dev", worktree: worktree, gitSHA: sha, exclusive: exclusive,
            command: ["/bin/sh", "-c", script], cwd: repo)
    }

    func testMatchingShortShaIsStoredInFull() throws {
        let head = try git("rev-parse", "HEAD")
        let response = try daemon.submit(submit(sha: String(head.prefix(8)), worktree: repo))
        XCTAssertEqual(response.job.gitSHA, head)
        XCTAssertEqual(response.job.worktree, repo)
        let done = try daemon.wait(response.job.id)
        XCTAssertEqual(done.state, .succeeded)
    }

    func testCwdIsTheCheckoutWhenThereIsNoWorktree() throws {
        let head = try git("rev-parse", "HEAD")
        let done = try daemon.wait(try daemon.submit(submit(sha: head)).job.id)
        XCTAssertEqual(done.state, .succeeded)
        XCTAssertEqual(done.gitSHA, head)
    }

    func testMismatchIsRefusedAtSubmitWithBothShas() throws {
        let old = try git("rev-parse", "HEAD")
        try commit("two")
        let head = try git("rev-parse", "HEAD")
        let error = try daemon.protocolError(.submit(submit(sha: old, worktree: repo)))
        XCTAssertEqual(error.code, .invalidArgument)
        XCTAssertTrue(error.message.contains("not what's checked out in \(repo!)"), error.message)
        XCTAssertTrue(error.message.contains(String(old.prefix(12))), error.message)
        XCTAssertTrue(error.message.contains("HEAD is \(head.prefix(12))"), error.message)
    }

    func testUnknownShaAndNonCheckoutAndBadInputAreRefused() throws {
        let unknown = try daemon.protocolError(.submit(submit(sha: "deadbeefdeadbeef", worktree: repo)))
        XCTAssertTrue(unknown.message.contains("is not a commit in"), unknown.message)
        let plain = testScratchRoot() + "/sqg-plain-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: plain) }
        // GIT_CEILING_DIRECTORIES isn't set, so keep the plain dir outside any repo: /tmp is.
        let notRepo = try daemon.protocolError(.submit(submit(sha: "abcd1234", worktree: plain)))
        XCTAssertTrue(notRepo.message.contains("is not a git checkout"), notRepo.message)
        let bad = try daemon.protocolError(.submit(submit(sha: "HEAD; rm -rf /", worktree: repo)))
        XCTAssertTrue(bad.message.contains("4...64 hex digits"), bad.message)
        var noTree = submit(sha: "abcd1234")
        noTree.command = nil
        noTree.cwd = nil
        let none = try daemon.protocolError(.submit(noTree))
        XCTAssertTrue(none.message.contains("needs a worktree"), none.message)
    }

    func testNoShaMeansNoCheck() throws {
        let done = try daemon.wait(try daemon.submit(submit(sha: nil, worktree: "/nonexistent")).job.id)
        XCTAssertEqual(done.state, .succeeded)
        XCTAssertNil(done.gitSHA)
    }

    /// Holds the exclusive slot until `release()`, so a checked job queues behind it for as
    /// long as the test needs (no timing).
    private func holdExclusiveSlot() throws -> (id: String, release: () -> Void) {
        let gate = repo + "/.gate-" + UUID().uuidString.prefix(6)
        let blocker = try daemon.submit(
            submit(sha: nil, script: "while [ ! -f '\(gate)' ]; do sleep 0.02; done", exclusive: true))
        let deadline = Date().addingTimeInterval(10)
        while try daemon.side.job(id: blocker.job.id)?.state != .running, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return (blocker.job.id, { FileManager.default.createFile(atPath: gate, contents: nil) })
    }

    func testWorktreeThatMovesWhileQueuedFailsAtStartWithoutRunning() throws {
        let marker = repo + "/ran"
        let blocker = try holdExclusiveSlot()
        let head = try git("rev-parse", "HEAD")
        let checked = try daemon.submit(submit(sha: head, worktree: repo, script: "touch ran", exclusive: true))
        XCTAssertEqual(checked.job.state, .queued)
        try commit("moved")
        blocker.release()
        let done = try daemon.wait(checked.job.id)
        XCTAssertEqual(try daemon.wait(blocker.id).state, .succeeded)
        XCTAssertEqual(done.state, .failed)
        XCTAssertEqual(done.resultClass, .commandFailure)
        XCTAssertTrue(done.message?.contains("worktree changed since submit") == true, done.message ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "the command must not run")
        let log = try String(contentsOfFile: try XCTUnwrap(done.logPath), encoding: .utf8)
        XCTAssertTrue(log.contains("worktree changed since submit"), log)
    }

    func testGitFailingAtStartIsAnInfraFailureThatARetryableJobRetries() throws {
        let marker = repo + "/ran"
        let blocker = try holdExclusiveSlot()
        let head = try git("rev-parse", "HEAD")
        var params = submit(sha: head, worktree: repo, script: "touch ran", exclusive: true)
        params.retryable = true
        params.maxRetries = 1
        let checked = try daemon.submit(params)
        // The checkout breaks while the job queues: git can't answer at start.
        try FileManager.default.removeItem(atPath: repo + "/.git")
        blocker.release()
        let done = try daemon.wait(checked.job.id)
        XCTAssertEqual(done.state, .infraFailed, "\(done)")
        XCTAssertEqual(done.resultClass, .runnerBootstrapFailure)
        XCTAssertEqual(done.attempt, 1, "retried once, as a retryable infra failure")
        XCTAssertTrue(
            done.message?.contains("could not check git_sha before start") == true, done.message ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "the command must not run")
    }

    /// A shard group's `--build-command` step carries the group's worktree and git_sha, so
    /// the start check covers the build too: a worktree that moved fails the build without
    /// running it, and the shards never run.
}
