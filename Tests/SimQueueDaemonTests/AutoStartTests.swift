// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import XCTest

/// `simq` starting `simqd` itself (on by default), and the config keys for it
/// (`max_load5`, `resume_below_load5`, `autostart`, `backend`). Fakes only: `writeConfig`
/// refuses a config that could auto-start anything but the fake backend, and a test that
/// writes none runs with `SIMQ_NO_AUTOSTART=1`.
final class AutoStartTests: XCTestCase {
    private var stateDir = ""
    /// Pids from `started simqd (pid N)` lines.
    private var startedDaemons: [Int32] = []

    private static var productsDirectory: URL {
        #if os(macOS)
            for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
                return bundle.bundleURL.deletingLastPathComponent()
            }
        #endif
        return Bundle.main.bundleURL
    }

    private func binary(_ name: String) throws -> URL {
        let url = Self.productsDirectory.appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("\(name) not built at \(url.path)")
        }
        return url
    }

    /// Runs `simq` via posix_spawn and waitpid (not Foundation's Process, whose exit
    /// monitoring on Linux can miss a child whose own child outlives it).
    private func startSimq(_ arguments: [String], environment: [String: String] = [:]) throws -> (Int32, String) {
        let simq = try binary("simq").path
        var env = ProcessInfo.processInfo.environment
        let hasConfig = FileManager.default.fileExists(atPath: stateDir + "/config.json")
        env["SIMQ_NO_AUTOSTART"] = hasConfig ? nil : "1"
        env["SIMQ_HOST_LOCK"] = stateDir + "-host.lock"
        let output = stateDir + "-" + UUID().uuidString.prefix(6) + ".out"
        let pid = try ProcessSpawner.spawn(
            executable: simq, argv: [simq] + arguments + ["--state-dir", stateDir],
            environment: env.merging(environment) { _, new in new }, cwd: nil, outputPath: output)
        return (pid, output)
    }

    private func finish(_ started: (Int32, String)) -> (code: Int32, output: String) {
        let deadline = Date().addingTimeInterval(60)
        var code: Int32 = -1
        while Date() < deadline {
            if let exit = try? ProcessSpawner.reap(started.0) {
                code = exit.shellStatus
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if code == -1 { kill(started.0, SIGKILL) }
        let output = (try? String(contentsOfFile: started.1, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: started.1)
        // Remember any daemon this call started, so tearDown can stop it even if it never
        // answered a status request.
        if let range = output.range(of: "started simqd (pid ") {
            let digits = output[range.upperBound...].prefix { $0.isNumber }
            if let pid = Int32(digits) { startedDaemons.append(pid) }
        }
        return (code, output)
    }

    /// Writes `config.json`, refusing one whose auto-start would pick a real backend.
    private func writeConfig(_ json: String) throws {
        let config = try DaemonConfig.parse(Data(json.utf8))
        let backend =
            config.autostart.backend.flatMap(BackendKind.init(rawValue:))
            ?? BackendGate.choose(flag: nil, config: config.backend, dryRun: false)
        guard !config.autostart.enabled || backend == .fake else {
            XCTFail("test bug: this config would auto-start the \(backend) backend")
            throw TestFailure("refused a config that auto-starts the \(backend) backend")
        }
        try FileManager.default.createDirectory(
            atPath: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(json.utf8).write(to: URL(fileURLWithPath: stateDir + "/config.json"))
    }

    override func setUp() {
        stateDir = testScratchRoot() + "/sqa-" + UUID().uuidString.prefix(8)
    }

    override func tearDown() {
        // Stop a daemon this test started, by the pid it reports.
        if let pidText = try? String(contentsOfFile: stateDir + "/simqd.log", encoding: .utf8),
            pidText.contains("ready")
        {
            let (code, output) =
                (try? startSimq(["status", "--json"], environment: ["SIMQ_NO_AUTOSTART": "1"]))
                .map(finish) ?? (1, "")
            if code == 0, let data = output.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let daemon = json["daemon"] as? [String: Any], let pid = daemon["pid"] as? Int
            {
                kill(Int32(pid), SIGTERM)
                let deadline = Date().addingTimeInterval(5)
                while kill(Int32(pid), 0) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            }
        }
        // Fallback: stop every daemon a call reported starting, by its pid, so no fake
        // simqd outlives the test.
        for pid in startedDaemons where kill(pid, 0) == 0 {
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(5)
            while kill(pid, 0) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        startedDaemons = []
        try? FileManager.default.removeItem(atPath: stateDir)
        try? FileManager.default.removeItem(atPath: stateDir + "-host.lock")
    }

    /// No `autostart` section needed: on by default, with simqd's own backend choice (here
    /// the config's explicit `backend: fake`).
    func testOnByDefault() throws {
        _ = try binary("simqd")
        try writeConfig(#"{"backend": "fake"}"#)
        let result = finish(try startSimq(["status"]))
        XCTAssertEqual(result.code, 0, result.output)
        XCTAssertTrue(result.output.contains("started simqd"), result.output)
        XCTAssertTrue(result.output.contains("backend fake"), result.output)
    }

    func testOffWithAutostartFalse() throws {
        try writeConfig(#"{"backend": "fake", "autostart": false}"#)
        let result = finish(try startSimq(["status"]))
        XCTAssertEqual(result.code, 69, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDir + "/simqd.log"))
    }

    func testTwoConcurrentCallsStartOneDaemonThatOutlivesThem() throws {
        _ = try binary("simqd")
        try writeConfig(#"{"autostart": {"backend": "fake", "executor": "fake", "timeout_seconds": 20}}"#)
        let first = try startSimq(["status"])
        let second = try startSimq(["status"])
        let results = [finish(first), finish(second)]
        for result in results { XCTAssertEqual(result.code, 0, result.output) }
        XCTAssertEqual(
            results.filter { $0.output.contains("started simqd") }.count, 1, results.map(\.output).joined())
        let logDeadline = Date().addingTimeInterval(3)
        while Date() < logDeadline,
            ((try? String(contentsOfFile: stateDir + "/simqd.log", encoding: .utf8)) ?? "").contains("simqd: ready")
                == false
        { Thread.sleep(forTimeInterval: 0.01) }
        let log = try String(contentsOfFile: stateDir + "/simqd.log", encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "simqd: ready").count - 1, 1, log)
        // Still up after both callers exited; a later call doesn't start another.
        let again = finish(try startSimq(["status"]))
        XCTAssertEqual(again.code, 0, again.output)
        XCTAssertFalse(again.output.contains("started simqd"), again.output)
    }

    func testOptOutEnvironmentWins() throws {
        try writeConfig(#"{"autostart": {"backend": "fake", "executor": "fake"}}"#)
        let result = finish(try startSimq(["status"], environment: ["SIMQ_NO_AUTOSTART": "1"]))
        XCTAssertEqual(result.code, 69, result.output)
    }

    func testAStartupFailureIsReportedWithTheLogTail() throws {
        // A stand-in simqd that fails at startup.
        try writeConfig(#"{"autostart": {"backend": "fake", "timeout_seconds": 10}}"#)
        let failing = stateDir + "/failing-simqd"
        try Data("#!/bin/sh\necho 'simqd: no template configured'\nexit 64\n".utf8)
            .write(to: URL(fileURLWithPath: failing))
        chmod(failing, 0o755)
        let result = finish(try startSimq(["status"], environment: ["SIMQ_SIMQD_PATH": failing]))
        XCTAssertEqual(result.code, 69, result.output)
        XCTAssertTrue(result.output.contains("during startup"), result.output)
        XCTAssertTrue(result.output.contains("no template configured"), result.output)
    }

    func testTheLaunchEnvironmentIsScrubbed() {
        let caller = [
            "HOME": "/h", "USER": "u", "LOGNAME": "u", "PATH": "/bin", "LANG": "C", "DEVELOPER_DIR": "/x",
            "SIMQ_STATE_DIR": "/s", "SIMQ_HOST_LOCK": "/l", "RUNNER_TRACKING_ID": "github_1",
            "RUNNER_TEMP": "/r", "GITHUB_TOKEN": "secret", "GITHUB_WORKSPACE": "/w", "ACTIONS_RUNTIME_TOKEN": "t",
            "TMPDIR": "/caller/tmp", "SHELL": "/bin/zsh", "AWS_SECRET_ACCESS_KEY": "k",
        ]
        XCTAssertEqual(
            DaemonLauncher.environment(from: caller),
            [
                "HOME": "/h", "USER": "u", "LOGNAME": "u", "PATH": "/bin", "LANG": "C", "DEVELOPER_DIR": "/x",
                "SIMQ_STATE_DIR": "/s", "SIMQ_HOST_LOCK": "/l",
            ])
    }

    func testTheDaemonIsSpawnedInItsOwnSessionWithTheScrubbedEnvironmentAndStateDirCwd() throws {
        try FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let caller = [
            "PATH": "/usr/bin:/bin", "HOME": "/tmp", "RUNNER_TRACKING_ID": "github_x", "GITHUB_TOKEN": "s",
            "ACTIONS_ID_TOKEN_REQUEST_URL": "u", "TMPDIR": "/caller/tmp", "SIMQ_HOST_LOCK": "/l",
        ]
        let pid = try DaemonLauncher.spawn(
            executable: "/bin/sh",
            argv: ["/bin/sh", "-c", "env > env.txt; pwd -P > pwd.txt; echo to-log; touch done; sleep 5"],
            callerEnvironment: caller, stateDir: stateDir)
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: stateDir + "/done"), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(getsid(pid), pid, "leads its own session")
        XCTAssertNotEqual(getsid(pid), getsid(0))
        XCTAssertEqual(getpgid(pid), pid)
        let env = try String(contentsOfFile: stateDir + "/env.txt", encoding: .utf8)
        for banned in ["RUNNER_", "GITHUB_", "ACTIONS_", "TMPDIR="] {
            XCTAssertFalse(env.contains(banned), "\(banned) leaked: \(env)")
        }
        XCTAssertTrue(env.contains("SIMQ_HOST_LOCK=/l"), env)
        let cwd = try String(contentsOfFile: stateDir + "/pwd.txt", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(cwd, URL(fileURLWithPath: stateDir).resolvingSymlinksInPath().path)
        XCTAssertTrue(
            try String(contentsOfFile: DaemonLauncher.logPath(stateDir: stateDir), encoding: .utf8).contains("to-log"))
    }

    func testConfigKeys() throws {
        let config = try DaemonConfig.parse(
            Data(
                #"{"max_load5": 20, "resume_below_load5": 12, "autostart": {"backend": "simctl", "probe": "system"}}"#
                    .utf8))
        XCTAssertEqual(config.scheduler.loadThrottle.maxLoad5, 20)
        XCTAssertEqual(config.scheduler.loadThrottle.resumeBelowLoad5, 12)
        XCTAssertTrue(config.autostart.enabled)
        XCTAssertEqual(config.autostart.backend, "simctl")
        XCTAssertEqual(config.autostart.probe, "system")
        XCTAssertNil(config.autostart.executor)
        XCTAssertEqual(config.autostart.timeoutSeconds, 30)
        let defaults = try DaemonConfig.parse(Data("{}".utf8))
        XCTAssertNil(defaults.scheduler.loadThrottle.maxLoad5, "the load5 limit is off by default")
        XCTAssertTrue(defaults.autostart.enabled, "auto-start is on by default")
        XCTAssertNil(defaults.autostart.backend, "simqd picks the backend")
        XCTAssertFalse(try DaemonConfig.parse(Data(#"{"autostart": false}"#.utf8)).autostart.enabled)
        XCTAssertTrue(try DaemonConfig.parse(Data(#"{"autostart": true}"#.utf8)).autostart.enabled)
        for bad in [
            #"{"max_load5": 0}"#, #"{"resume_below_load5": 5}"#, #"{"max_load5": 10, "resume_below_load5": 11}"#,
            #"{"autostart": {"backend": "real"}}"#, #"{"autostart": {"timeout_seconds": 0}}"#,
            #"{"autostart": "yes"}"#,
        ] {
            XCTAssertThrowsError(try DaemonConfig.parse(Data(bad.utf8)), bad)
        }
    }
}
