// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueProtocol
import XCTest

/// The fake `xcrun`, `xcodebuild` and `simslim` scenarios run as real job commands through
/// the process executor. The fakes come first on the job's `PATH`, so no real Xcode tool
/// or simulator is ever touched.
final class FakeToolScenarioTests: XCTestCase {
    private var daemon: TestDaemon!
    private var tools: FakeToolHarness!

    /// What a typical CI job script does: list sims, verify the template, run the tests.
    private static let ciScript =
        "xcrun simctl list devices && simslim verify template && xcodebuild test -scheme Demo -resultBundlePath \"$SIMQ_RUN_DIR/Test.xcresult\""

    override func setUpWithError() throws {
        var config = DaemonConfig()
        config.timeouts.killGraceSeconds = 0.5
        daemon = try TestDaemon(config: config, realProcesses: true)
        tools = try FakeToolHarness()
    }

    override func tearDown() {
        daemon?.destroy()
        tools?.cleanUp()
    }

    private func runScenario(_ scenario: String, script: String = ciScript, timeout: Double? = nil) throws -> (
        job: JobInfo, log: String
    ) {
        let params = SubmitParams(
            project: "demo", kind: "ui-test", submitter: "ci", runTimeoutSeconds: timeout,
            command: ["/bin/sh", "-c", script], environment: tools.environment(scenario: scenario))
        let job = try daemon.wait(try daemon.submit(params).job.id)
        let log = try String(contentsOfFile: try XCTUnwrap(job.logPath), encoding: .utf8)
        return (job, log)
    }

    private var resultBundleSuffix: String { "-resultBundlePath " }

    func testSuccess() throws {
        let (job, log) = try runScenario("success")
        XCTAssertEqual(job.state, .succeeded)
        XCTAssertEqual(job.commandExitCode, 0)
        XCTAssertEqual(job.exitCode, .success)
        XCTAssertTrue(log.contains("** TEST SUCCEEDED ** (fake)"), log)
        let calls = try tools.loggedCalls()
        XCTAssertEqual(calls.count, 3, "\(calls)")
        XCTAssertEqual(calls[0], "xcrun simctl list devices")
        XCTAssertEqual(calls[1], "simslim verify template")
        XCTAssertTrue(calls[2].hasPrefix("xcodebuild test -scheme Demo " + resultBundleSuffix), calls[2])
        XCTAssertTrue(
            calls[2].hasSuffix("/\(job.id)/Test.xcresult"), "SIMQ_RUN_DIR is the job's directory: \(calls[2])")
    }

    func testTestFailure() throws {
        let (job, log) = try runScenario("test_failure")
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.resultClass, .commandFailure)
        XCTAssertEqual(job.commandExitCode, 65)
        XCTAssertEqual(job.exitCode, .testFailure)
        XCTAssertTrue(log.contains("Test Case '-[DemoTests testFails]' failed"), log)
        XCTAssertTrue(log.contains("** TEST FAILED ** (fake)"), log)
        XCTAssertEqual(try tools.loggedCalls().count, 3, "the earlier steps ran")
    }

    func testBuildFailure() throws {
        let (job, log) = try runScenario("build_failure", script: "xcodebuild build-for-testing -scheme Demo")
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.resultClass, .commandFailure)
        XCTAssertEqual(job.commandExitCode, 65)
        XCTAssertTrue(
            log.contains("error: fake compile error\n** BUILD FAILED ** (fake)"), "stderr is captured: \(log)")
    }

    func testHangEndsInRunTimeoutAndLeavesNothingRunning() throws {
        // Three fake tools start before the hang; 0.5 s was too tight on a busy macOS runner
        // (the run timed out before xcodebuild printed), so give them time to get there.
        let (job, log) = try runScenario("hang", timeout: 3)
        XCTAssertEqual(job.state, .timedOut)
        XCTAssertEqual(job.resultClass, .runTimeout)
        XCTAssertEqual(job.exitCode, .timedOut)
        XCTAssertTrue(log.contains("xcodebuild: hanging (fake)"), log)
        let group = try XCTUnwrap(try daemon.side.resources(jobID: job.id).first { $0.kind == .processGroup })
        XCTAssertFalse(try SystemProcessTable().isGroupLive(try XCTUnwrap(Int32(group.externalID))))
        let deadline = Date().addingTimeInterval(5)
        while try daemon.job(job.id).commandExitCode == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertNotNil(try daemon.job(job.id).commandExitCode, "the leader's status is recorded")
    }

    func testCrash() throws {
        let (job, log) = try runScenario("crash", script: "xcodebuild test -scheme Demo")
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.resultClass, .commandFailure)
        XCTAssertEqual(job.commandExitCode, 128 + 11, "SIGSEGV")
        XCTAssertEqual(job.exitCode, .testFailure)
        XCTAssertTrue(log.contains("xcodebuild: crashing (fake)"), log)
    }

    func testMissingToolIsACommandFailureNotInfra() throws {
        let (job, _) = try runScenario("tool_missing")
        XCTAssertEqual(job.resultClass, .commandFailure)
        XCTAssertEqual(job.commandExitCode, 72)
        XCTAssertEqual(try tools.loggedCalls(), ["xcrun simctl list devices"], "the script stops at the first failure")
    }
}
