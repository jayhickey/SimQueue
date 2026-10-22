// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueProtocol
import SimQueueStore
import XCTest

/// Drives the built `simqd` and `simq` executables over a real socket and checks the
/// stable exit codes. Skipped if the executables aren't built next to the test bundle.
/// Fakes only: simqd uses a fake backend/probe except explicit simctl-selection cases
/// whose PATH contains FakeToolHarness scripts. Every simq call disables autostart.
final class CLIEndToEndTests: XCTestCase {
    private var stateDir = ""
    private var daemon: Process?

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

    /// The test's environment with auto-start off.
    private static var simqEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["SIMQ_NO_AUTOSTART"] = "1"
        return environment
    }

    @discardableResult
    private func simq(_ arguments: [String], withStateDir: Bool = true, environment: [String: String] = [:]) throws
        -> (code: Int32, output: String)
    {
        let process = Process()
        process.executableURL = try binary("simq")
        // Options go before a `--` (everything after it is the job's command).
        var arguments = arguments
        if withStateDir {
            arguments.insert(
                contentsOf: ["--state-dir", stateDir], at: arguments.firstIndex(of: "--") ?? arguments.endIndex)
        }
        process.arguments = arguments
        process.environment = Self.simqEnvironment.merging(environment) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    override func setUpWithError() throws {
        stateDir = testScratchRoot() + "/sqc-" + UUID().uuidString.prefix(8)
        try startDaemon(executor: "fake")
    }

    /// Starts `simqd` on `stateDir`, stopping any daemon this test already started.
    private func startDaemon(executor: String, extra: [String] = []) throws {
        if let daemon, daemon.isRunning {
            daemon.terminate()
            daemon.waitUntilExit()
        }
        let process = Process()
        process.executableURL = try binary("simqd")
        process.arguments =
            [
                "run", "--foreground", "--state-dir", stateDir, "--executor", executor, "--backend", "fake", "--probe",
                "fake",
            ]
            + extra
        // simqd's output goes to a log next to the state dir, so a startup failure says why.
        let logPath = stateDir + ".simqd.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        process.standardOutput = log
        process.standardError = log
        try process.run()
        daemon = process
        // A loaded CI host can take well over 10 s to launch a freshly built binary, so the
        // deadline is generous; a healthy start still takes well under a second.
        let started = Date()
        let deadline = started.addingTimeInterval(60)
        while try simq(["status"]).code != 0 {
            guard process.isRunning, Date() < deadline else {
                let output = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
                return XCTFail(
                    "simqd didn't come up after \(Int(Date().timeIntervalSince(started))) s"
                        + " (running: \(process.isRunning)); its output:\n\(output.suffix(4000))")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    override func tearDown() {
        if let daemon, daemon.isRunning {
            daemon.terminate()
            daemon.waitUntilExit()
        }
        try? FileManager.default.removeItem(atPath: stateDir)
        try? FileManager.default.removeItem(atPath: stateDir + ".simqd.log")
    }

    func testDrainAndResumeCLIAndRestartClearThePlannedGate() throws {
        let drained = try simq(["drain", "--timeout", "2s", "--json"])
        XCTAssertEqual(drained.code, 0, drained.output)
        XCTAssertTrue(drained.output.contains("\"drain_complete\" : true"), drained.output)
        let resumed = try simq(["resume", "--json"])
        XCTAssertEqual(resumed.code, 0, resumed.output)
        XCTAssertTrue(resumed.output.contains("\"paused\" : false"), resumed.output)
        XCTAssertEqual(try simq(["drain", "--no-wait"]).code, 0)
        try startDaemon(executor: "fake")
        let status = try simq(["status", "--json"])
        XCTAssertTrue(status.output.contains("\"paused\" : false"), status.output)
    }

    func testDrainTimeoutKeepsTheGateWithoutCancellingRunningWork() throws {
        try startDaemon(executor: "process")
        let go = stateDir + "/go"
        let submitted = try simq([
            "submit", "--project", "drain", "--timeout", "10s", "--", "/bin/sh", "-c",
            "while [ ! -f '\(go)' ]; do sleep 0.02; done",
        ])
        XCTAssertEqual(submitted.code, 0, submitted.output)
        let deadline = Date().addingTimeInterval(10)
        var running = false
        while Date() < deadline {
            if try simq(["explain", "J-0001", "--json"]).output.contains("\"state\" : \"running\"") {
                running = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(running)
        let timeout = try simq(["drain", "--timeout", "0.1s"])
        XCTAssertEqual(timeout.code, 7, timeout.output)
        let status = try simq(["status", "--json"])
        XCTAssertTrue(status.output.contains("\"paused\" : true"), status.output)
        XCTAssertTrue(try simq(["explain", "J-0001", "--json"]).output.contains("\"state\" : \"running\""))
        FileManager.default.createFile(atPath: go, contents: nil)
        XCTAssertEqual(try simq(["drain", "--timeout", "10s"]).code, 0)
        XCTAssertEqual(try simq(["resume"]).code, 0)
    }

    func testRunReconnectsToTheSameJobAfterDaemonRestart() throws {
        try assertClientReconnects(waitOnly: false)
    }

    func testWaitReconnectsToTheSameJobAfterDaemonRestart() throws {
        try assertClientReconnects(waitOnly: true)
    }

    private func assertClientReconnects(waitOnly: Bool) throws {
        try startDaemon(executor: "process")
        let marker = stateDir + "/command-started"
        let script = "touch \"\(marker)\"; if [ \"$SIMQ_ATTEMPT\" = 0 ]; then sleep 120; fi; echo finished"
        if waitOnly {
            let submitted = try simq([
                "submit", "--project", "restart", "--retryable", "--retries", "2", "--", "/bin/sh", "-c", script,
            ])
            XCTAssertEqual(submitted.code, 0, submitted.output)
        }
        let output = stateDir + "/client-output"
        FileManager.default.createFile(atPath: output, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
        defer { try? handle.close() }
        let client = Process()
        client.executableURL = try binary("simq")
        client.arguments =
            waitOnly
            ? ["wait", "J-0001", "--state-dir", stateDir]
            : [
                "run", "--sims", "0", "--project", "restart", "--retryable", "--retries", "2", "--state-dir", stateDir,
                "--", "/bin/sh", "-c", script,
            ]
        client.environment = Self.simqEnvironment
        client.standardOutput = handle
        client.standardError = handle
        try client.run()
        defer {
            if client.isRunning { client.terminate(); client.waitUntilExit() }
        }
        let started = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: marker), Date() < started {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker), "command started before the restart")
        daemon?.terminate()
        daemon?.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(client.isRunning, "the client must wait through a missing daemon")
        try startDaemon(executor: "process")
        let ended = Date().addingTimeInterval(30)
        while client.isRunning, Date() < ended { Thread.sleep(forTimeInterval: 0.05) }
        guard !client.isRunning else { return XCTFail("client did not finish after restart") }
        client.waitUntilExit()
        let text = try String(contentsOfFile: output, encoding: .utf8)
        XCTAssertEqual(client.terminationStatus, 0, text)
        let job = try simq(["explain", "J-0001", "--json"])
        XCTAssertTrue(job.output.contains("\"attempt\" : 1"), job.output)
        let jobs = try simq(["jobs", "--json"])
        XCTAssertFalse(jobs.output.contains("J-0002"), "reconnecting must never submit a duplicate")
    }

    func testSelectedCallerEnvironmentForwardsOnlyNamedVariables() throws {
        try startDaemon(executor: "process")
        let result = try simq(
            [
                "run", "--sims", "0", "--env-from", "DEVELOPER_DIR", "--env-from", "FORWARD_VALUE",
                "--env", "FORWARD_VALUE=explicit", "--", "/bin/sh", "-c",
                #"printf '%s|%s|%s' "$DEVELOPER_DIR" "$FORWARD_VALUE" "${PRIVATE_CANARY:-absent}""#,
            ],
            environment: [
                "DEVELOPER_DIR": "/selected/toolchain with spaces", "FORWARD_VALUE": "caller",
                "PRIVATE_CANARY": "never-forward-this",
            ])
        XCTAssertEqual(result.code, 0, result.output)
        XCTAssertTrue(result.output.contains("/selected/toolchain with spaces|explicit|absent"), result.output)
        XCTAssertFalse(result.output.contains("never-forward-this"))
        XCTAssertEqual(
            try simq(
                ["run", "--sims", "0", "--env-from", "SIMQ_JOB_ID", "--", "/bin/echo", "bad"],
                environment: ["SIMQ_JOB_ID": "spoof"]
            ).code, 64)
        XCTAssertEqual(
            try simq(["run", "--sims", "0", "--env-from", "DELIBERATELY_MISSING_VALUE", "--", "/bin/echo", "bad"]).code,
            64)
    }

    func testRemovedShardingFlagsAndCommandFailClearly() throws {
        for args in [
            ["shard", "plan"], ["submit", "--shards", "2", "--", "/bin/echo", "bad"],
            ["run", "--shards", "2", "--", "/bin/echo", "bad"],
        ] {
            XCTAssertEqual(try simq(args).code, 64)
        }
        let help = try simq(["--help"], withStateDir: false)
        XCTAssertFalse(help.output.contains("shard"), help.output)
    }

    func testExitCodes() throws {
        XCTAssertEqual(try simq(["submit", "--project", "demo", "--wait"]).code, 0)
        XCTAssertEqual(
            try simq(["submit", "--project", "demo", "--payload", #"{"fake":{"result":"test_failure"}}"#, "--wait"])
                .code, 1)
        XCTAssertEqual(
            try simq(["submit", "--project", "demo", "--payload", #"{"fake":{"result":"build_failure"}}"#, "--wait"])
                .code,
            2)
        XCTAssertEqual(
            try simq([
                "submit", "--project", "demo", "--payload", #"{"fake":{"run_seconds":30}}"#, "--timeout", "1s",
                "--wait",
            ])
            .code, 3)
        XCTAssertEqual(
            try simq(["submit", "--project", "demo", "--payload", #"{"fake":{"result":"internal_error"}}"#, "--wait"])
                .code,
            4)
        XCTAssertEqual(
            try simq([
                "submit", "--project", "demo", "--payload", #"{"fake":{"run_seconds":30}}"#, "--wait", "--wait-timeout",
                "1s",
            ]).code, 7)
        XCTAssertEqual(try simq(["submit", "--project", "demo", "--priority", "nope"]).code, 64)
        XCTAssertEqual(try simq(["submit", "--project", "demo", "--priority", "101"]).code, 64)
        XCTAssertEqual(try simq(["explain", "J-9999"]).code, 66)
        XCTAssertEqual(try simq(["submit", "--project", "demo", "--kind", "has space"]).code, 64)
        XCTAssertEqual(try simq(["submit", "--project", "demo", "--retries", "11"]).code, 64)
        XCTAssertEqual(try simq(["submit", "--project", "demo", "--sims", "2", "--max-sims", "1"]).code, 64)
    }

    func testFlagsReplaceKinds() throws {
        let submitted = try simq([
            "submit", "--project", "demo", "--kind", "lint", "--exclusive", "--retries", "2", "--json",
        ])
        XCTAssertEqual(submitted.code, 0, submitted.output)
        for expected in [#""kind" : "lint""#, #""exclusive" : true"#, #""retryable" : true"#, #""max_retries" : 2"#] {
            XCTAssertTrue(submitted.output.contains(expected), "\(expected) in \(submitted.output)")
        }
        let plain = try simq(["submit", "--project", "demo", "--retryable", "--json"])
        XCTAssertTrue(plain.output.contains(#""exclusive" : false"#), plain.output)
        XCTAssertTrue(plain.output.contains(#""retryable" : true"#), plain.output)
    }

    func testStatusShowsTheHealthLineAndTheDaemonWritesHealthJSON() throws {
        let status = try simq(["status"])
        XCTAssertEqual(status.code, 0)
        XCTAssertTrue(status.output.hasPrefix("health: ok; last watchdog pass "), status.output)

        let path = stateDir + "/health.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let health = try JSONDecoder().decode(HealthInfo.self, from: data)
        XCTAssertEqual(health.health, "ok")
        XCTAssertEqual(health.cleanupMode, "report-only")
        XCTAssertEqual(health.breaker.state, "closed")
        XCTAssertEqual(health.lastPassKind, "full")
        XCTAssertNotNil(health.lastPassID)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.uint32Value & 0o777, 0o600)

        let json = try simq(["status", "--json"])
        XCTAssertTrue(json.output.contains("\"health\" : {"), json.output)
    }

    /// One version everywhere: `--version` on both binaries, `status` and `doctor`.
    func testVersionShowsInVersionFlagStatusAndDoctor() throws {
        let version = SimQueueVersion.current
        let flag = try simq(["--version"], withStateDir: false)
        XCTAssertEqual(flag.code, 0)
        XCTAssertEqual(flag.output.trimmingCharacters(in: .whitespacesAndNewlines), version)
        let status = try simq(["status"])
        XCTAssertTrue(status.output.contains("simqd \(version) pid "), status.output)
        XCTAssertTrue(status.output.contains("\nsimq \(version)\n"), status.output)
        let doctor = try simq(["doctor"])
        XCTAssertTrue(doctor.output.hasPrefix("OK  version: simq \(version), simqd \(version)\n"), doctor.output)
        let json = try simq(["doctor", "--json"])
        XCTAssertTrue(json.output.contains(#""name" : "version""#), json.output)
    }

    /// Fake `simslim`, `xcodebuild` and `xcrun` (all succeed) in a fresh PATH dir.
    private func fakeSetupTools() throws -> String {
        let bin = testScratchRoot() + "/tools-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        let tools = [
            "simslim": "echo simslim 0.12.2", "xcodebuild": "printf 'Xcode 27.0\\nBuild version 27A266a\\n'",
            "xcrun": "echo /fake/simctl",
        ]
        for (name, body) in tools {
            let path = bin + "/" + name
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        return bin
    }

    func testInitWritesAStarterConfigOnceAndReportsTheChecks() throws {
        let dir = testScratchRoot() + "/sqi-" + UUID().uuidString.prefix(8)
        let tools = try fakeSetupTools()
        let first = try simq(
            ["init", "--state-dir", dir], withStateDir: false, environment: ["PATH": tools + ":/usr/bin:/bin"])
        XCTAssertEqual(first.code, 0, first.output)
        XCTAssertTrue(first.output.contains("config: wrote \(dir)/config.json"), first.output)
        XCTAssertTrue(first.output.contains("OK  simslim: 0.12.2"), first.output)
        XCTAssertTrue(first.output.contains("Next steps:"), first.output)
        let config = try String(contentsOfFile: dir + "/config.json", encoding: .utf8)
        XCTAssertTrue(config.contains(#""cleanup_mode": "report-only""#), config)
        let again = try simq(
            ["init", "--state-dir", dir], withStateDir: false, environment: ["PATH": tools + ":/usr/bin:/bin"])
        XCTAssertTrue(again.output.contains("config: kept"), again.output)

        // --launchd writes the agent and turns auto-start off; --no-load skips launchctl.
        let agents = dir + "-home/Library/LaunchAgents"
        let launchd = try simq(
            ["init", "--state-dir", dir, "--force", "--launchd", "--no-load", "--launch-agents-dir", agents],
            withStateDir: false, environment: ["PATH": tools + ":/usr/bin:/bin"])
        XCTAssertEqual(launchd.code, 0, launchd.output)
        let plist = try String(contentsOfFile: agents + "/dev.simqueue.simqd.plist", encoding: .utf8)
        XCTAssertTrue(plist.contains("<string>\(dir)</string>"), plist)
        XCTAssertTrue(
            try String(contentsOfFile: dir + "/config.json", encoding: .utf8).contains(#""autostart": false"#))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "-home/Library/Logs/SimQueue"))

        let old = tools + "/simslim"
        try Data("#!/bin/sh\necho simslim 0.9.1\n".utf8).write(to: URL(fileURLWithPath: old))
        let stale = try simq(
            ["init", "--state-dir", dir], withStateDir: false, environment: ["PATH": tools + ":/usr/bin:/bin"])
        XCTAssertTrue(stale.output.contains("WARN  simslim: 0.9.1 is older than 0.12.0"), stale.output)
    }

    /// A daemon that holds its lock but doesn't answer may still be live: refuse, touch nothing.
    func testUninstallRefusesWhenTheDaemonHoldsItsLockButDoesntAnswer() throws {
        let dir = testScratchRoot() + "/squ-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(#"{"backend": "fake"}"#.utf8).write(to: URL(fileURLWithPath: dir + "/config.json"))
        let lock = try InstanceLock(path: SimQueuePaths(stateDir: dir).lockPath)
        defer { lock.release() }
        let result = try simq(
            ["uninstall", "--yes", "--purge", "--state-dir", dir, "--launch-agents-dir", dir + "-agents"],
            withStateDir: false)
        XCTAssertEqual(result.code, 1, result.output)
        XCTAssertTrue(result.output.contains("simqd is running but didn't answer"), result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/config.json"), "nothing deleted")
    }

    func testUninstallCannotPurgeTerminalWorkWithUnreleasedProcessOwnershipEvenWhenForced() throws {
        let dir = testScratchRoot() + "/squ-" + UUID().uuidString.prefix(8)
        let paths = SimQueuePaths(stateDir: dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data(#"{"backend":"fake"}"#.utf8).write(to: URL(fileURLWithPath: paths.configPath))
        let store = try JobStore(path: paths.databasePath)
        let epoch = try store.acquireDaemonLease(ownerID: "uninstall-test", pid: 1, now: 1)
        let job = try store.submit(JobSubmission(project: "test", submitter: "test"), now: 1).job
        _ = try store.claim(jobID: job.id, grantedSims: 0, epoch: epoch, now: 2)
        let resource = try store.acquireResource(
            kind: .processGroup, externalID: "9999999", owner: .job(job.id), epoch: epoch, now: 2)
        _ = try store.cancel(jobID: job.id, now: 3)
        try store.markResourceOrphaned(id: resource.id, reason: "command cleanup not yet verified", now: 3)
        XCTAssertTrue(try store.activeJobs().isEmpty)
        XCTAssertTrue(try store.queuedJobs().isEmpty)

        let result = try simq(
            ["uninstall", "--yes", "--purge", "--force", "--state-dir", dir, "--launch-agents-dir", dir + "-agents"],
            withStateDir: false)
        XCTAssertEqual(result.code, 1, result.output)
        XCTAssertTrue(result.output.contains("owned command processes still need cleanup"), result.output)
        XCTAssertTrue(result.output.contains("simq doctor"), result.output)
        XCTAssertTrue(result.output.contains("successful drain"), result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.configPath), "refusal must retain configuration")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paths.databasePath), "refusal must retain the recovery ledger")
        XCTAssertEqual(try store.job(id: job.id)?.state, .canceled)
        XCTAssertEqual(try store.resource(id: resource.id)?.state, .orphaned)
    }

    func testUninstallCannotPurgeAnUnresolvedHostIntentEvenWhenForced() throws {
        let dir = testScratchRoot() + "/squ-" + UUID().uuidString.prefix(8)
        let paths = SimQueuePaths(stateDir: dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data(#"{"backend":"fake"}"#.utf8).write(to: URL(fileURLWithPath: paths.configPath))
        let store = try JobStore(path: paths.databasePath)
        _ = try store.recordActionIntent(
            ActionIntent(
                target: .simCreate(name: "simq-pool-1-pending"), auditType: "pool_created",
                detail: "clone outcome not yet verified"), now: 1)
        XCTAssertTrue(try store.activeJobs().isEmpty)
        XCTAssertTrue(try store.liveResources().isEmpty)
        let result = try simq(
            ["uninstall", "--yes", "--purge", "--force", "--state-dir", dir, "--launch-agents-dir", dir + "-agents"],
            withStateDir: false)
        XCTAssertEqual(result.code, 1, result.output)
        XCTAssertTrue(result.output.contains("host action remains pending"), result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.databasePath))
        XCTAssertEqual(try store.pendingActionIntents().count, 1)
    }

    func testUninstallRetiresOldPoolBeforeExplicitTemplateSwitchWithoutRecoveringQueuedWork() throws {
        #if !os(macOS)
            throw XCTSkip("simctl platform gate is macOS-only; executable tools remain fake")
        #else
            daemon?.terminate()
            daemon?.waitUntilExit()
            daemon = nil
            let tools = try FakeToolHarness()
            defer { tools.cleanUp() }
            let paths = SimQueuePaths(stateDir: stateDir)
            let now = Date().timeIntervalSince1970
            let store = try JobStore(path: paths.databasePath)
            let epoch = try XCTUnwrap(try store.currentEpoch())
            let history = try store.submit(JobSubmission(project: "history", submitter: "test"), now: now).job
            _ = try store.claim(jobID: history.id, grantedSims: 0, epoch: epoch, now: now)
            _ = try store.finish(jobID: history.id, result: .success, now: now)
            let naming = SimNamingScheme(ownerTag: SimNamingScheme.ownerTag(stateDirectory: stateDir))
            let oldName = naming.poolSimName(slot: 1, intentID: 1)
            var old = PoolSim(udid: "OLD-POOL", name: oldName, phase: .ready, createdAt: now)
            old.clonedFrom = TemplateRef(udid: "OLD-TEMPLATE", name: nil)
            try store.savePoolSim(old)
            _ = try store.acquireResource(kind: .sim, externalID: old.udid, owner: .pool, epoch: epoch, now: now)
            let template = try store.acquireResource(
                kind: .template, externalID: "NEW-TEMPLATE", owner: .pool, epoch: epoch, now: now)
            try store.audit("retained_template_switch_history", detail: "must survive uninstall", now: now)
            let config =
                #"{"backend":"simctl","autostart":false,"cleanup_mode":"report-only","simctl":{"template":"NEW-TEMPLATE"},"pool":{"mode":"active","warm_min":0,"max_sims":1}}"#
            try Data(config.utf8).write(to: URL(fileURLWithPath: paths.configPath))
            let before =
                #"{"devices":{"runtime":[{"udid":"OLD-POOL","name":"NAME","state":"Shutdown"},{"udid":"NEW-TEMPLATE","name":"simq-template-host-stock-2","state":"Shutdown"}]}}"#
                .replacingOccurrences(of: "NAME", with: oldName)
            let after =
                #"{"devices":{"runtime":[{"udid":"NEW-TEMPLATE","name":"simq-template-host-stock-2","state":"Shutdown"}]}}"#
            try tools.respond("xcrun-list", out: before)
            try tools.respond("xcrun-delete", out: "")
            var environment = Self.simqEnvironment.merging(tools.toolEnvironment) { $1 }
            environment["SIMQ_HOST_LOCK"] = stateDir + "/fake-tools-only-host.lock"
            let purgeRefused = try simq(
                ["uninstall", "--yes", "--purge", "--launch-agents-dir", stateDir + "-agents"],
                environment: environment)
            XCTAssertEqual(purgeRefused.code, 1, purgeRefused.output)
            XCTAssertTrue(
                purgeRefused.output.contains("owned simulators were retained by cleanup policy"), purgeRefused.output)
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.databasePath))
            XCTAssertEqual(try String(contentsOfFile: paths.configPath, encoding: .utf8), config)
            XCTAssertEqual(try store.poolSims().map(\.udid), [old.udid])
            XCTAssertEqual(try store.ownedSimUDIDs(), [old.udid])
            XCTAssertFalse(try tools.loggedCalls().contains("xcrun simctl delete OLD-POOL"))
            let queued = try store.submit(
                JobSubmission(project: "template-switch", submitter: "test", queueTimeoutSeconds: nil), now: now
            ).job
            func startup() throws -> (code: Int32, output: String) {
                let process = Process()
                process.executableURL = try binary("simqd")
                process.arguments = [
                    "run", "--foreground", "--state-dir", stateDir, "--backend", "simctl", "--probe", "fake",
                    "--executor", "fake", "--exit-after-startup",
                ]
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: data, as: UTF8.self))
            }
            let refused = try startup()
            XCTAssertNotEqual(refused.code, 0, refused.output)
            XCTAssertTrue(refused.output.contains("No queue recovery has run"), refused.output)
            XCTAssertEqual(try store.currentEpoch(), epoch)
            XCTAssertEqual(try store.job(id: queued.id), queued)
            XCTAssertEqual(try store.poolSims().map(\.udid), [old.udid])

            // The backend sees the owned clone before deletion and only the template
            // afterward; every xcrun invocation is a script in FakeToolHarness.
            try tools.respond("xcrun-list", out: before, next: after)
            let removed = try simq(
                ["uninstall", "--yes", "--force", "--launch-agents-dir", stateDir + "-agents"],
                environment: environment)
            XCTAssertEqual(removed.code, 0, removed.output)
            XCTAssertTrue(removed.output.contains("deleted sim OLD-POOL"), removed.output)
            let cleaned = try JobStore(readOnlyPath: paths.databasePath)
            XCTAssertTrue(try cleaned.poolSims().isEmpty)
            XCTAssertTrue(try cleaned.ownedSimUDIDs().isEmpty)
            XCTAssertEqual(try cleaned.currentEpoch(), epoch)
            XCTAssertEqual(try cleaned.job(id: queued.id), queued)
            XCTAssertEqual(try cleaned.job(id: history.id)?.state, .succeeded)
            XCTAssertEqual(try cleaned.resource(id: template.id)?.state, .active)
            XCTAssertEqual(try cleaned.auditCount(type: "retained_template_switch_history", since: 0), 1)

            let restarted = try startup()
            XCTAssertEqual(restarted.code, 0, restarted.output)
            let final = try JobStore(readOnlyPath: paths.databasePath)
            XCTAssertEqual(try final.currentEpoch(), epoch + 1)
            XCTAssertEqual(try final.job(id: queued.id), queued)
            XCTAssertEqual(try final.job(id: history.id)?.state, .succeeded)
            XCTAssertNotNil(try final.resource(id: template.id))
            XCTAssertTrue(try final.poolSims().isEmpty)
            XCTAssertTrue(try tools.loggedCalls().contains("xcrun simctl delete OLD-POOL"))
        #endif
    }

    func testOfflineUninstallCannotForcePurgeALeasedPoolSimulator() throws {
        daemon?.terminate()
        daemon?.waitUntilExit()
        daemon = nil
        let paths = SimQueuePaths(stateDir: stateDir)
        let config = #"{"backend":"fake","autostart":false}"#
        try Data(config.utf8).write(to: URL(fileURLWithPath: paths.configPath))
        let store = try JobStore(path: paths.databasePath)
        let epoch = try XCTUnwrap(try store.currentEpoch())
        let now = Date().timeIntervalSince1970
        var leased = PoolSim(udid: "LEASED-POOL", name: "simq-pool-1-1", phase: .leased, createdAt: now)
        leased.leaseID = "lease:live-holder"
        leased.holderPID = ProcessInfo.processInfo.processIdentifier
        leased.heartbeatAt = now
        try store.savePoolSim(leased)
        let resource = try store.acquireResource(
            kind: .sim, externalID: leased.udid, owner: .pool, epoch: epoch, now: now)
        let refused = try simq([
            "uninstall", "--yes", "--force", "--purge", "--launch-agents-dir", stateDir + "-agents",
        ])
        XCTAssertEqual(refused.code, 1, refused.output)
        XCTAssertTrue(refused.output.contains("pool simulators remain leased"), refused.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.databasePath))
        XCTAssertEqual(try String(contentsOfFile: paths.configPath, encoding: .utf8), config)
        let retained = try JobStore(readOnlyPath: paths.databasePath)
        XCTAssertEqual(try retained.poolSims(), [leased])
        XCTAssertEqual(try retained.ownedSimUDIDs(), [leased.udid])
        XCTAssertEqual(try retained.resource(id: resource.id)?.state, .active)
        XCTAssertEqual(try retained.currentEpoch(), epoch)
    }

    func testUninstallRequiresCompletedDrainBeforeStoppingAnIdleDaemon() throws {
        let agents = stateDir + "-agents"
        let refused = try simq(["uninstall", "--yes", "--purge", "--launch-agents-dir", agents])
        XCTAssertEqual(refused.code, 1, refused.output)
        XCTAssertTrue(refused.output.contains("drain has not completed"), refused.output)
        XCTAssertEqual(try simq(["status"]).code, 0, "a refused uninstall must leave the daemon serving")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateDir))
    }

    func testUninstallRefusesWhileJobsRunThenStopsTheDaemonAndPurges() throws {
        try startDaemon(executor: "process")
        // The fake backend, so uninstall never runs simctl (even on a Mac).
        try Data(#"{"backend": "fake"}"#.utf8).write(to: URL(fileURLWithPath: stateDir + "/config.json"))
        let agents = stateDir + "-agents"
        try FileManager.default.createDirectory(atPath: agents, withIntermediateDirectories: true)
        let submitted = try simq(["submit", "--project", "demo", "--", "sleep", "30"])
        XCTAssertEqual(submitted.code, 0, submitted.output)
        var busy = try simq(["uninstall", "--yes", "--launch-agents-dir", agents])
        for _ in 0..<100 where !busy.output.contains("running or admitted") {
            Thread.sleep(forTimeInterval: 0.1)
            busy = try simq(["uninstall", "--yes", "--launch-agents-dir", agents])
        }
        XCTAssertEqual(busy.code, 1, busy.output)
        XCTAssertTrue(busy.output.contains("running or admitted"), busy.output)
        XCTAssertEqual(try simq(["cancel", "J-0001"]).code, 0)
        let drained = try simq(["drain", "--timeout", "30s"])
        XCTAssertEqual(drained.code, 0, drained.output)

        var plan = try simq(["uninstall", "--purge", "--launch-agents-dir", agents])
        for _ in 0..<100 where plan.output.contains("running or admitted") {
            Thread.sleep(forTimeInterval: 0.1)
            plan = try simq(["uninstall", "--purge", "--launch-agents-dir", agents])
        }
        XCTAssertEqual(plan.code, 0, plan.output)
        XCTAssertTrue(plan.output.contains("Plan only."), plan.output)
        XCTAssertEqual(try simq(["status"]).code, 0, "the plan changes nothing")

        try Data().write(to: URL(fileURLWithPath: agents + "/homebrew.mxcl.simqueue.plist"))
        let brew = try simq(["uninstall", "--yes", "--launch-agents-dir", agents])
        XCTAssertEqual(brew.code, 1, brew.output)
        XCTAssertTrue(brew.output.contains("brew services stop simqueue"), brew.output)
        try FileManager.default.removeItem(atPath: agents + "/homebrew.mxcl.simqueue.plist")

        let done = try simq(["uninstall", "--yes", "--purge", "--launch-agents-dir", agents])
        XCTAssertEqual(done.code, 0, done.output)
        XCTAssertTrue(done.output.contains("simqd: stopped"), done.output)
        XCTAssertTrue(done.output.contains("state dir: deleted"), done.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDir))
        daemon?.waitUntilExit()
        XCTAssertEqual(try simq(["status"]).code, 69)
    }

    func testJSONOutputAndReadOnlyCommandsWithDaemonDown() throws {
        let submitted = try simq(["submit", "--project", "demo", "--queue-timeout", "none", "--json"])
        XCTAssertEqual(submitted.code, 0)
        XCTAssertTrue(submitted.output.contains("\"queue_timeout_seconds\"") == false, submitted.output)
        let listed = try simq(["jobs", "--json"])
        XCTAssertTrue(listed.output.contains("\"priority\" : 50"), listed.output)
        XCTAssertNotNil(
            listed.output.range(
                of: #""queue_time" : "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3})?Z""#, options: .regularExpression),
            listed.output)

        daemon?.terminate()
        daemon?.waitUntilExit()
        XCTAssertEqual(try simq(["status"]).code, 69)
        let udids = try simq(["owned-udids", "--json"])
        XCTAssertEqual(udids.code, 0)
        XCTAssertTrue(udids.output.contains("\"owned_udids\""))
        let doctor = try simq(["doctor", "--json"])
        XCTAssertEqual(doctor.code, 1, "daemon down is a warning")
        XCTAssertTrue(doctor.output.contains("\"owned_udids\""))
    }

    /// `simq golden ...` is a hidden alias of `simq template ...` (the name before the rename).
    func testGoldenIsAHiddenAliasOfTemplate() throws {
        let template = try simq(["template", "list", "--json"])
        XCTAssertEqual(template.code, 0, template.output)
        let golden = try simq(["golden", "list", "--json"])
        XCTAssertEqual(golden.code, 0, golden.output)
        XCTAssertEqual(golden.output, template.output)
        XCTAssertTrue(template.output.contains("\"templates\""), template.output)
        let help = try simq(["--help"], withStateDir: false)
        XCTAssertTrue(help.output.contains("template"), help.output)
        XCTAssertFalse(help.output.contains("golden"), help.output)
        XCTAssertEqual(try simq(["golden", "rm", "--help"], withStateDir: false).code, 0)
    }

    func testProcessExecutorRunsCommandsAndStreamsLogs() throws {
        try startDaemon(executor: "process")
        let ok = try simq([
            "submit", "--project", "demo", "--wait", "--env", "GREETING=hi", "--cwd", "/", "--",
            "/bin/sh", "-c", #"echo "$GREETING from $SIMQ_JOB_ID in $(pwd)""#,
        ])
        XCTAssertEqual(ok.code, 0, ok.output)
        let logs = try simq(["logs", "J-0001"])
        XCTAssertEqual(logs.code, 0)
        XCTAssertTrue(logs.output.contains("hi from J-0001 in /\n"), logs.output)

        let failed = try simq(["submit", "--project", "demo", "--wait", "--json", "--", "/bin/sh", "-c", "exit 3"])
        XCTAssertEqual(failed.code, 1, "a failed command exits 1")
        XCTAssertTrue(failed.output.contains(#""command_exit_code" : 3"#), failed.output)
        XCTAssertTrue(failed.output.contains(#""result_class" : "command_failure""#), failed.output)

        XCTAssertEqual(try simq(["submit", "--project", "demo"]).code, 64, "the process executor needs a command")
        XCTAssertEqual(try simq(["submit", "--project", "demo", "--env", "X=1"]).code, 64)

        let started = try simq([
            "submit", "--project", "demo", "--", "/bin/sh", "-c", "echo one; sleep 0.5; echo two",
        ])
        XCTAssertEqual(started.code, 0, started.output)
        let followed = try simq(["logs", "--follow", "J-0003"])
        XCTAssertEqual(followed.code, 0)
        XCTAssertTrue(followed.output.contains("one\ntwo\n"), followed.output)

        let timedOut = try simq(["submit", "--project", "demo", "--wait", "--timeout", "1s", "--", "sleep", "30"])
        XCTAssertEqual(timedOut.code, 3, timedOut.output)
    }

    /// Readable job names with spaces and punctuation go through submit, run, jobs, explain
    /// and logs unchanged; jobs and explain show local queued and started times.
    func testReadableJobNamesRunAndDisplayEverywhereWithLocalTimes() throws {
        try startDaemon(executor: "process")
        let utc = ["TZ": "UTC"]
        let names = ["Quotify PR #134 · Unit tests", "Quotify main · Unit + UI tests (full)"]
        for (index, name) in names.enumerated() {
            let id = "J-000\(index + 1)"
            let ran = try simq([
                "run", "--sims", "0", "--project", "quotify", "--kind", name, "--", "/bin/sh", "-c",
                #"echo "kind=$SIMQ_KIND"; printf p > "$SIMQ_RUN_DIR/$SIMQ_KIND.png""#,
            ])
            XCTAssertEqual(ran.code, 0, ran.output)
            XCTAssertTrue(ran.output.contains("kind=\(name)\n"), ran.output)

            let logs = try simq(["logs", id])
            XCTAssertEqual(logs.code, 0, logs.output)
            XCTAssertTrue(logs.output.contains("\n" + "kind=\(name)\n"), logs.output)
            let explained = try simq(["explain", id], environment: utc)
            XCTAssertTrue(
                explained.output.hasPrefix("\(id)  succeeded  p50  \(name)  quotify  queued at "), explained.output)
            XCTAssertTrue(explained.output.contains("\(name).png  1 B  image"), explained.output)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(try simq(["explain", id, "--json"]).output.utf8))
                    as? [String: Any])
            XCTAssertEqual(json["kind"] as? String, name)
            for key in ["queue_time", "started_at"] {
                let value = try XCTUnwrap(json[key] as? String, key)
                XCTAssertNotNil(Timestamp(rfc3339: value), "\(key) stays RFC 3339: \(value)")
            }
        }
        // A queued job (behind an exclusive one) has no start yet: a dash.
        XCTAssertEqual(
            try simq(["submit", "--sims", "0", "--exclusive", "--project", "quotify", "--", "sleep", "30"]).code, 0)
        XCTAssertEqual(
            try simq([
                "submit", "--sims", "0", "--exclusive", "--project", "quotify", "--kind", "  Quotify UI Tests ",
                "--", "true",
            ]).code, 0)
        let time = #"[A-Z][a-z]{2} [0-9]{1,2}, [0-9]{1,2}:[0-9]{2} [AP]M"#
        let jobs = try simq(["jobs"], environment: utc)
        XCTAssertEqual(jobs.code, 0, jobs.output)
        let lines = jobs.output.split(separator: "\n").map(String.init)
        let queued = try XCTUnwrap(lines.first { $0.hasPrefix("J-0004") }, jobs.output)
        XCTAssertNotNil(
            queued.range(
                of: "^J-0004  queued  p50  Quotify UI Tests  quotify  queued at \(time)  started at -",
                options: .regularExpression),
            "trimmed name, dash before the start: \(queued)")
        for (index, name) in names.enumerated() {
            let line = try XCTUnwrap(lines.first { $0.hasPrefix("J-000\(index + 1)") }, jobs.output)
            XCTAssertNotNil(
                line.range(
                    of:
                        "  \(NSRegularExpression.escapedPattern(for: name))  quotify  queued at \(time)  started at \(time)",
                    options: .regularExpression),
                line)
        }
        let listed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try simq(["jobs", "--json"]).output.utf8)) as? [[String: Any]])
        XCTAssertEqual(Set(listed.compactMap { $0["kind"] as? String }), Set(names + ["Quotify UI Tests", ""]))
        XCTAssertNil(listed.first { $0["id"] as? String == "J-0004" }?["started_at"], "no start yet")
        XCTAssertEqual(try simq(["cancel", "J-0004"]).code, 0)
        XCTAssertEqual(try simq(["cancel", "J-0003"]).code, 0)

        for bad in ["Quotify\nUnit tests", "tab\there", "esc\u{1B}[31m", "   ", String(repeating: "x", count: 101)] {
            let rejected = try simq(["submit", "--sims", "0", "--project", "quotify", "--kind", bad, "--", "true"])
            XCTAssertEqual(rejected.code, 64, "\(bad.debugDescription): \(rejected.output)")
            XCTAssertTrue(rejected.output.contains("kind must be at most 100 characters"), rejected.output)
        }
    }

    // MARK: - simq run

    private func jobState(_ id: String) throws -> String {
        let explained = try simq(["explain", id, "--json"])
        let match = explained.output.range(of: #""state" : "[a-z_]+""#, options: .regularExpression)
        return match.map { String(explained.output[$0]).components(separatedBy: "\"")[3] } ?? "?"
    }

    func testConfiguredOutputRootExportsPathsAndKeepsOldJobEvidence() throws {
        try startDaemon(executor: "process")
        let first = try simq(["run", "--sims", "0", "--project", "demo", "--", "/bin/echo", "old evidence"])
        XCTAssertEqual(first.code, 0, first.output)
        XCTAssertEqual(try simq(["drain", "--timeout", "10s"]).code, 0)
        let outputRoot = stateDir + ".output"
        defer { try? FileManager.default.removeItem(atPath: outputRoot) }
        let data = try JSONSerialization.data(withJSONObject: ["job_output_root": outputRoot])
        try data.write(to: URL(fileURLWithPath: stateDir + "/config.json"))
        try startDaemon(executor: "process")
        let second = try simq([
            "run", "--sims", "0", "--project", "demo", "--", "/bin/sh", "-c",
            #"echo "rd=$SIMQ_RUN_DIR"; echo "dd=$SIMQ_DERIVED_DATA"; echo "rb=$SIMQ_RESULT_BUNDLE"; echo "tmp=$SIMQ_TMPDIR"; echo "system_tmp=$TMPDIR""#,
        ])
        XCTAssertEqual(second.code, 0, second.output)
        XCTAssertTrue(second.output.contains("rd=" + outputRoot + "/"), second.output)
        for suffix in ["/DerivedData", "/Result.xcresult", "/tmp"] {
            XCTAssertTrue(second.output.contains(suffix), second.output)
        }
        let old = try simq(["logs", "J-0001"])
        XCTAssertTrue(old.output.contains("old evidence"), old.output)
        let status = try simq(["status", "--json"])
        XCTAssertTrue(status.output.contains(outputRoot), status.output)
        XCTAssertTrue(status.output.contains("job_output_root"), status.output)
    }

    func testRunStreamsOutputExportsPathsAndExitsWithTheCommandsStatus() throws {
        try startDaemon(executor: "process")
        let ran = try simq([
            "run", "--project", "demo", "--cwd", "/", "--",
            "/bin/sh", "-c",
            #"echo "out $SIMQ_JOB_ID"; echo "dd=$SIMQ_DERIVED_DATA"; echo "rb=$SIMQ_RESULT_BUNDLE"; echo "rd=$SIMQ_RUN_DIR"; exit 3"#,
        ])
        XCTAssertEqual(ran.code, 3, "the command's own status: \(ran.output)")
        XCTAssertTrue(ran.output.contains("out J-0001\n"), ran.output)
        let lines = ran.output.split(separator: "\n").map(String.init)
        let runDir = try XCTUnwrap(lines.first { $0.hasPrefix("rd=") }).dropFirst(3)
        XCTAssertTrue(runDir.hasSuffix("/J-0001"), ran.output)
        XCTAssertTrue(lines.contains("dd=\(runDir)/DerivedData"), ran.output)
        XCTAssertTrue(lines.contains("rb=\(runDir)/Result.xcresult"), ran.output)
        XCTAssertEqual(try jobState("J-0001"), "failed")

        let reserved = try simq(["run", "--project", "demo", "--env", "SIMQ_DERIVED_DATA=/tmp/dd", "--", "true"])
        XCTAssertEqual(reserved.code, 64, "SIMQ_* stays reserved for the daemon: \(reserved.output)")

        XCTAssertEqual(try simq(["run", "--project", "demo"]).code, 64, "run needs a command")
        XCTAssertEqual(try simq(["run", "--wait-timeout-exit", "0", "--", "true"]).code, 64)
        XCTAssertEqual(try simq(["run", "--project", "demo", "--timeout", "1s", "--", "sleep", "30"]).code, 3)
    }

    /// --exit-code mapped gives simq's stable codes; --result-file has the command's own
    /// status and the files the job left in SIMQ_RUN_DIR.
    func testRunExitCodeModesResultFileAndArtifacts() throws {
        try startDaemon(executor: "process")
        let script =
            #"mkdir -p "$SIMQ_RUN_DIR/shots" "$SIMQ_RUN_DIR/Proof.xcresult/Data" "$SIMQ_DERIVED_DATA"; "#
            + #"printf 'png' > "$SIMQ_RUN_DIR/shots/home.png"; printf 'mp4data' > "$SIMQ_RUN_DIR/proof.mp4"; "#
            + #"printf 'abcd' > "$SIMQ_RUN_DIR/Proof.xcresult/Data/blob"; printf 'x' > "$SIMQ_DERIVED_DATA/big"; "#
            + #"printf 'h' > "$SIMQ_RUN_DIR/.hidden"; "#
            + #"mkdir -p "$TMPDIR/cache"; printf 's' > "$TMPDIR/scratch.png"; printf 'c' > "$TMPDIR/cache/frame.mp4"; "#
            + #"[ "$TMPDIR" = "$SIMQ_RUN_DIR/tmp" ] || exit 9; exit 3"#
        let resultFile = stateDir + "/result.json"
        let mapped = try simq([
            "run", "--project", "demo", "--exit-code", "mapped", "--result-file", resultFile, "--", "/bin/sh", "-c",
            script,
        ])
        XCTAssertEqual(mapped.code, 1, "mapped: a command failure is 1: \(mapped.output)")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: resultFile))) as? [String: Any])
        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertEqual(json["result_class"] as? String, "command_failure")
        XCTAssertEqual(json["command_exit_code"] as? Int, 3)
        XCTAssertEqual(json["exit_code"] as? Int, 1)
        let runDir = try XCTUnwrap(json["run_dir"] as? String)
        XCTAssertTrue(runDir.hasSuffix("/J-0001"), runDir)
        let artifacts = try XCTUnwrap(json["artifacts"] as? [[String: Any]])
        let listed = artifacts.map {
            "\($0["path"] as? String ?? "?") \($0["bytes"] as? Int ?? -1) \($0["type"] as? String ?? "?")"
        }
        XCTAssertEqual(
            listed,
            [
                "Proof.xcresult 4 xcresult",
                "combined.log \(artifacts.first { $0["path"] as? String == "combined.log" }?["bytes"] as? Int ?? -1) log",
                "proof.mp4 7 video", "shots/home.png 3 image",
            ],
            "DerivedData, job.json, the job's TMPDIR and dot files are left out; a bundle is one entry")
        XCTAssertEqual(json["result_bundles"] as? [String], [runDir + "/Proof.xcresult"])
        XCTAssertTrue(mapped.output.contains("shots/home.png"), "listed on stderr too: \(mapped.output)")

        let passthrough = try simq([
            "run", "--project", "demo", "--exit-code", "passthrough", "--", "/bin/sh", "-c", "exit 3",
        ])
        XCTAssertEqual(passthrough.code, 3, passthrough.output)
        XCTAssertEqual(try simq(["run", "--project", "demo", "--exit-code", "bogus", "--", "true"]).code, 64)
        let timedOut = try simq([
            "run", "--project", "demo", "--exit-code", "mapped", "--timeout", "1s", "--", "sleep", "30",
        ])
        XCTAssertEqual(timedOut.code, 3, "simq's own codes are the same in both modes")
    }

    func testRunWaitTimeoutCancelsTheJobAndExitsWithTheChosenStatus() throws {
        try startDaemon(executor: "process")
        let holder = try simq(["submit", "--project", "demo", "--exclusive", "--", "sleep", "30"])
        XCTAssertEqual(holder.code, 0, holder.output)
        let blocked = try simq([
            "run", "--project", "demo", "--exclusive", "--wait-timeout", "1s", "--wait-timeout-exit", "75", "--",
            "true",
        ])
        XCTAssertEqual(blocked.code, 75, blocked.output)
        XCTAssertEqual(try jobState("J-0002"), "canceled", "a run nobody waits for is canceled")
        XCTAssertEqual(try simq(["cancel", "J-0001"]).code, 0)
    }

    func testRunForwardsSIGINTAsCancelAndExits130() throws {
        try startDaemon(executor: "process")
        let marker = stateDir + "/after-sleep"
        let process = Process()
        process.executableURL = try binary("simq")
        process.arguments = [
            "run", "--state-dir", stateDir, "--project", "demo", "--", "/bin/sh", "-c", "sleep 30; touch \(marker)",
        ]
        process.environment = Self.simqEnvironment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while try jobState("J-0001") != "running" {
            guard Date() < deadline else { return XCTFail("the run never started") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.3)  // let simq reach the log loop
        kill(process.processIdentifier, SIGINT)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 130)
        XCTAssertEqual(try jobState("J-0001"), "canceled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "the command's process group was stopped")
    }

    /// #41: a signal between the submit's reply and the wait still cancels the job.
    func testRunCancelsWhenTheSignalComesRightAfterTheSubmit() throws {
        #if !DEBUG
            throw XCTSkip("SIMQ_TEST_RUN_PAUSE_AFTER_SUBMIT is a debug-only hook")
        #endif
        try startDaemon(executor: "process")
        let process = Process()
        process.executableURL = try binary("simq")
        process.arguments = ["run", "--state-dir", stateDir, "--project", "demo", "--", "/bin/sh", "-c", "sleep 30"]
        var environment = Self.simqEnvironment
        environment["SIMQ_TEST_RUN_PAUSE_AFTER_SUBMIT"] = "3"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while try jobState("J-0001") == "?" {
            guard Date() < deadline else { return XCTFail("the run never submitted") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(process.processIdentifier, SIGINT)  // inside the pause: before `attach`
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 130)
        XCTAssertEqual(try jobState("J-0001"), "canceled")
    }

    /// #42: a dry run sees the real queue but its fake completions stay out of the real DB.
    func testDryRunNeverWritesTheRealStateDatabase() throws {
        XCTAssertEqual(try simq(["submit", "--project", "demo", "--wait"]).code, 0)  // J-0001, real
        try startDaemon(executor: "fake", extra: ["--dry-run"])
        XCTAssertEqual(try jobState("J-0001"), "succeeded", "the dry run starts from the real state")
        XCTAssertEqual(try simq(["submit", "--project", "demo", "--wait"]).code, 0)  // J-0002, dry run
        XCTAssertEqual(try jobState("J-0002"), "succeeded")
        try startDaemon(executor: "fake")
        XCTAssertEqual(try jobState("J-0001"), "succeeded")
        XCTAssertEqual(try jobState("J-0002"), "?", "the dry run's job is not in the real state")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateDir + "/simqueue-dry-run.sqlite"))
    }

    func testProjectAddDetectsAndWritesConfigWithoutTheDaemon() throws {
        daemon?.terminate()
        daemon?.waitUntilExit()
        let repo = stateDir + "-repo"
        try FileManager.default.createDirectory(
            atPath: repo + "/Demo.xcodeproj/xcshareddata/xcschemes", withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: repo + "/Demo.xcodeproj/xcshareddata/xcschemes/Demo.xcscheme", contents: Data())
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let added = try simq(["project", "add", "demo", "--repo", repo])
        XCTAssertEqual(added.code, 0, added.output)
        XCTAssertTrue(added.output.contains("added demo: \(repo), scheme Demo, Demo.xcodeproj"), added.output)
        let config = try String(contentsOfFile: stateDir + "/config.json", encoding: .utf8)
        XCTAssertTrue(config.contains(#""scheme" : "Demo""#), config)
        XCTAssertEqual(try simq(["project", "add", "demo", "--repo", repo]).code, 64, "duplicate without --replace")
        XCTAssertEqual(try simq(["project", "add", "Demo", "--repo", repo]).code, 64, "bad name")
        let bare = stateDir + "-bare"
        try FileManager.default.createDirectory(atPath: bare, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: bare) }
        let json = try simq(["project", "add", "bare", "--repo", bare, "--scheme", "X", "--json"])
        XCTAssertEqual(json.code, 0, json.output)
        XCTAssertTrue(json.output.contains(#""container" : null"#), "null, not \"\": \(json.output)")
    }
}
