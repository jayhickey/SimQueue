// SPDX-License-Identifier: MIT
//
// Fake-tool harness skeleton. The pattern (scenario-driven bash stand-ins for
// xcrun/xcodebuild that log every call) is borrowed from XCSteward; see NOTICE.
// No XCSteward code is copied here.

import Foundation
import XCTest

/// Writes fake `xcrun`, `xcodebuild` and `simslim` scripts into a temp directory.
/// Each script appends its arguments to a log file and exits according to
/// `FAKE_TOOL_SCENARIO`. Executors under test get this directory first on PATH,
/// so no real Xcode tool or simulator is ever touched.
struct FakeToolHarness {
    let root: URL
    let binDirectory: URL
    let logFile: URL

    static let toolNames = ["xcrun", "xcodebuild", "simslim", "vm_stat", "sysctl", "ps"]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("simq-fake-tools-\(UUID().uuidString)", isDirectory: true)
        binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        logFile = root.appendingPathComponent("calls.log")
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: logFile.path, contents: Data())
        for name in Self.toolNames {
            let url = binDirectory.appendingPathComponent(name)
            try Self.script(for: name).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    /// Scenarios, chosen with `FAKE_TOOL_SCENARIO` (every tool logs its call first):
    /// - `success` (default): every tool exits 0; `xcodebuild test` prints `** TEST SUCCEEDED **`.
    /// - `test_failure`: `xcodebuild test` / `test-without-building` print a failing test
    ///   case and `** TEST FAILED **`, exit 65. Other actions succeed.
    /// - `build_failure`: `xcodebuild` prints `** BUILD FAILED **`, exits 65.
    /// - `hang`: `xcodebuild` prints a line, then never returns (until killed).
    /// - `crash`: `xcodebuild` dies from SIGSEGV (status 139 to its parent).
    /// - `tool_missing`: every tool exits 72.
    static func script(for name: String) -> String {
        """
        #!/bin/bash
        set -euo pipefail
        printf '%s %s\\n' "\(name)" "$*" >> "${FAKE_TOOL_LOG:?missing FAKE_TOOL_LOG}"
        action=" $* "
        case "${FAKE_TOOL_SCENARIO:-success}" in
          tool_missing) echo "\(name): not found (fake)" >&2; exit 72 ;;
          build_failure)
            if [[ "\(name)" == "xcodebuild" ]]; then echo "error: fake compile error" >&2; echo "** BUILD FAILED ** (fake)" >&2; exit 65; fi ;;
          test_failure)
            if [[ "\(name)" == "xcodebuild" && ( "$action" == *" test "* || "$action" == *" test-without-building "* ) ]]; then
              echo "Test Case '-[DemoTests testFails]' failed (0.001 seconds). (fake)"
              echo "** TEST FAILED ** (fake)"
              exit 65
            fi ;;
          hang)
            if [[ "\(name)" == "xcodebuild" ]]; then echo "xcodebuild: hanging (fake)"; exec sleep 3600; fi ;;
          crash)
            if [[ "\(name)" == "xcodebuild" ]]; then echo "xcodebuild: crashing (fake)"; ulimit -c 0; kill -SEGV $$; fi ;;
        esac
        # Recorded responses: with FAKE_TOOL_STATE set, a call answers from files named
        # after it (xcrun: xcrun-<simctl verb>; sysctl: sysctl-<key>; others: <tool>-<first arg>):
        # .out (stdout), .err (stderr), .status (exit code), .sleep (seconds first; alone it
        # just hangs), .next (replaces .out after this call, for before/after listings).
        if [[ -n "${FAKE_TOOL_STATE:-}" ]]; then
          case "\(name)" in
            xcrun) key="xcrun-${2:-}" ;;
            sysctl) key="sysctl-${2:-}" ;;
            *) key="\(name)-${1:-}" ;;
          esac
          f="$FAKE_TOOL_STATE/$key"
          if [[ -f "$f.sleep" && ! -f "$f.out" ]]; then exec sleep "$(cat "$f.sleep")"; fi
          if [[ -f "$f.sleep" ]]; then sleep "$(cat "$f.sleep")"; fi
          if [[ -f "$f.out" || -f "$f.status" || -f "$f.err" ]]; then
            if [[ -f "$f.out" ]]; then cat "$f.out"; fi
            if [[ -f "$f.err" ]]; then cat "$f.err" >&2; fi
            if [[ -f "$f.next" ]]; then mv "$f.next" "$f.out"; fi
            exit "$(cat "$f.status" 2>/dev/null || echo 0)"
          fi
        fi
        if [[ "\(name)" == "xcodebuild" && "$action" == *" test "* ]]; then echo "** TEST SUCCEEDED ** (fake)"; fi
        echo "\(name) ok (fake)"
        """
    }

    /// Environment that puts the fake tools first on `PATH` for a job or process.
    func environment(scenario: String) -> [String: String] {
        ["PATH": binDirectory.path + ":/usr/bin:/bin", "FAKE_TOOL_LOG": logFile.path, "FAKE_TOOL_SCENARIO": scenario]
    }

    /// Runs one fake tool directly and returns its exit status (128 + signal if killed).
    func run(_ tool: String, _ arguments: [String], scenario: String = "success") throws -> Int32 {
        let process = Process()
        process.executableURL = binDirectory.appendingPathComponent(tool)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["FAKE_TOOL_LOG"] = logFile.path
        env["FAKE_TOOL_SCENARIO"] = scenario
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        // Shell convention for a signal death: 128 + signal number.
        return process.terminationReason == .uncaughtSignal
            ? 128 + process.terminationStatus : process.terminationStatus
    }

    /// Where recorded responses live (`FAKE_TOOL_STATE`).
    var stateDirectory: URL { root.appendingPathComponent("state", isDirectory: true) }

    /// Records the response for one call key (see the script's recorded-responses block).
    func respond(
        _ key: String, out: String? = nil, err: String? = nil, status: Int32? = nil, sleep: Double? = nil,
        next: String? = nil
    ) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let files: [(String, String?)] = [
            ("out", out), ("err", err), ("status", status.map { "\($0)" }), ("sleep", sleep.map { "\($0)" }),
            ("next", next),
        ]
        for (suffix, value) in files {
            guard let value else { continue }
            try value.write(
                to: stateDirectory.appendingPathComponent("\(key).\(suffix)"), atomically: true, encoding: .utf8)
        }
    }

    /// Environment for a `ToolRunner`: fake tools first on PATH, answering from `stateDirectory`.
    /// Backends built over it run only the fake tools; it is never set on the test process.
    var toolEnvironment: [String: String] {
        [
            "PATH": binDirectory.path + ":/usr/bin:/bin", "FAKE_TOOL_LOG": logFile.path,
            "FAKE_TOOL_STATE": stateDirectory.path,
        ]
    }

    func loggedCalls() throws -> [String] {
        try String(contentsOf: logFile, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

final class FakeToolHarnessTests: XCTestCase {
    func testFakeToolsLogCallsAndHonorScenarios() throws {
        let harness = try FakeToolHarness()
        defer { harness.cleanUp() }

        XCTAssertEqual(try harness.run("xcodebuild", ["build-for-testing", "-scheme", "Demo"]), 0)
        XCTAssertEqual(try harness.run("xcodebuild", ["build"], scenario: "build_failure"), 65)
        XCTAssertEqual(try harness.run("simslim", ["--version"], scenario: "tool_missing"), 72)
        XCTAssertEqual(try harness.run("xcodebuild", ["test"], scenario: "test_failure"), 65)
        XCTAssertEqual(try harness.run("xcodebuild", ["build"], scenario: "test_failure"), 0, "only test actions fail")
        XCTAssertEqual(try harness.run("xcodebuild", ["test"], scenario: "crash"), 128 + 11)

        let calls = try harness.loggedCalls()
        XCTAssertEqual(calls.count, 6)
        XCTAssertEqual(calls.first, "xcodebuild build-for-testing -scheme Demo")
    }
}
