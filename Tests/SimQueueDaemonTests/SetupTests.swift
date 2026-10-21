// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueProtocol
import SimQueueSim
import XCTest

final class SetupTests: XCTestCase {
    func testStarterPoolScalesToTheHostAndKeepsAnExplicitCap() throws {
        var automatic = try DaemonConfig.parse(Data(SetupChecks.starterConfig(launchd: false).utf8))
        automatic.applyHostSizing(cpuCount: 24, totalMemoryBytes: 128 * ByteSize.gibibyte)
        XCTAssertEqual(automatic.pool?.maxSims, 16)
        XCTAssertEqual(automatic.pool?.warmMin, 0, "idle hosts do not eagerly boot to the ceiling")
        var limited = try DaemonConfig.parse(Data(#"{"pool":{"max_sims":2}}"#.utf8))
        limited.applyHostSizing(cpuCount: 24, totalMemoryBytes: 128 * ByteSize.gibibyte)
        XCTAssertEqual(limited.pool?.maxSims, 2)
    }

    func testVersionParsingAndComparison() {
        XCTAssertEqual(SetupChecks.parseVersion("simslim 0.12.2"), [0, 12, 2])
        XCTAssertEqual(SetupChecks.parseVersion("Xcode 27.0\nBuild version 27A266a"), [27, 0, 0])
        XCTAssertEqual(SetupChecks.parseVersion("v1.2.3"), [1, 2, 3])
        XCTAssertNil(SetupChecks.parseVersion("simslim dev"))
        XCTAssertTrue(SetupChecks.isAtLeast([0, 12, 0], [0, 12, 0]))
        XCTAssertTrue(SetupChecks.isAtLeast([1, 0, 0], [0, 12, 0]))
        XCTAssertTrue(SetupChecks.isAtLeast([0, 12, 3], [0, 12, 0]))
        XCTAssertFalse(SetupChecks.isAtLeast([0, 11, 9], [0, 12, 0]))
    }

    private func tools(_ scripts: [String: String]) throws -> ToolRunner {
        let bin = testScratchRoot() + "/setup-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        for (name, body) in scripts {
            let path = bin + "/" + name
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        return ToolRunner(environment: ["PATH": bin])
    }

    func testSimslimCheck() throws {
        XCTAssertEqual(SetupChecks.simslim(runner: try tools(["simslim": "echo simslim 0.12.2"])).level, .ok)
        let old = SetupChecks.simslim(runner: try tools(["simslim": "echo simslim 0.11.0"]))
        XCTAssertEqual(old.level, .warn)
        XCTAssertTrue(old.detail.contains("older than 0.12.0"), old.detail)
        let missing = SetupChecks.simslim(runner: try tools([:]))
        XCTAssertEqual(missing.level, .warn)
        XCTAssertTrue(missing.detail.contains("not found"), missing.detail)
        XCTAssertEqual(SetupChecks.simslim(runner: try tools(["simslim": "echo dev"])).level, .warn)
    }

    func testXcodeCheck() throws {
        let check = SetupChecks.xcode(
            runner: try tools(["xcodebuild": "echo Xcode 27.0", "xcrun": "echo /usr/bin/simctl"]))
        #if os(macOS)
            XCTAssertEqual(check.level, .ok)
            XCTAssertEqual(check.detail, "Xcode 27.0.0, simctl found")
            XCTAssertEqual(SetupChecks.xcode(runner: try tools([:])).level, .fail)
        #else
            XCTAssertEqual(check.level, .warn)
        #endif
    }

    func testStarterConfigLoadsAndLaunchdTurnsAutostartOff() throws {
        let dir = testScratchRoot() + "/cfg-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for launchd in [false, true] {
            let path = dir + "/config-\(launchd).json"
            try Data(SetupChecks.starterConfig(launchd: launchd).utf8).write(to: URL(fileURLWithPath: path))
            let config = try DaemonConfig.load(path: path)
            XCTAssertEqual(config.autostart.enabled, !launchd)
            XCTAssertEqual(config.reliability.cleanupMode, .reportOnly)
            XCTAssertFalse(config.host.poolMaxSimsIsExplicit)
        }
    }

    func testLaunchAgentPlistIsValidAndEscaped() throws {
        let text = SetupChecks.launchAgentPlist(
            simqd: "/opt/a&b/simqd", stateDir: "/Users/me/S <Q>", logPath: "/Users/me/Library/Logs/SimQueue/simqd.log")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "dev.simqueue.simqd")
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            [
                "/opt/a&b/simqd", "run", "--foreground", "--log-file", "/Users/me/Library/Logs/SimQueue/simqd.log",
                "--state-dir", "/Users/me/S <Q>",
            ])
        XCTAssertEqual(
            plist["StandardOutPath"] as? String, "/dev/null", "the daemon owns its rotating stdout/stderr sink")
        XCTAssertEqual(
            plist["StandardErrorPath"] as? String, "/dev/null",
            "launchd must not retain a separate unbounded log descriptor")
    }

    func testOwnedSimDeletesGoThroughTheCleanupGate() {
        let udids = ["A", "B", "C", "D", "E"]
        func backend() -> FakeSimBackend {
            FakeSimBackend(devices: udids.map { SimDevice(udid: $0, name: "simq-pool-\($0)", isBooted: false) })
        }
        var reliability = ReliabilityConfig()
        reliability.cleanupMode = .reportOnly
        let reportOnly = backend()
        let reported = Uninstaller.deleteOwnedSims(
            udids: udids, backend: reportOnly, reliability: reliability, executedLastHour: 0, force: false, now: 100)
        XCTAssertEqual(reported.wouldDelete, udids)
        XCTAssertEqual(reportOnly.deletedUDIDs, [])

        reliability.cleanupMode = .enforce
        reliability.maxDestructiveActionsPerPass = 3
        let enforced = backend()
        enforced.deleteFails = ["B"]
        let outcome = Uninstaller.deleteOwnedSims(
            udids: udids, backend: enforced, reliability: reliability, executedLastHour: 0, force: false, now: 100)
        XCTAssertEqual(outcome.deleted, ["A", "C"])
        XCTAssertEqual(Array(outcome.failed.keys), ["B"])
        XCTAssertEqual(outcome.rateLimited, ["D", "E"], "the per-pass limit holds the rest back")

        reliability.cleanupMode = .reportOnly
        let forced = backend()
        let all = Uninstaller.deleteOwnedSims(
            udids: udids, backend: forced, reliability: reliability, executedLastHour: 99, force: true, now: 100)
        XCTAssertEqual(all.deleted, udids, "--force skips report-only and the limits")
    }

    func testPurgeOnlyDeletesARealStateDir() throws {
        let home = testScratchRoot() + "/home-" + UUID().uuidString.prefix(8)
        let state = home + "/Library/Application Support/SimQueue"
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        for unsafe in ["/", home, home + "/", URL(fileURLWithPath: home).deletingLastPathComponent().path] {
            XCTAssertThrowsError(try Uninstaller.checkPurgeable(SimQueuePaths(stateDir: unsafe), home: home)) {
                XCTAssertEqual(
                    $0 as? Uninstaller.PurgeError, .unsafePath(URL(fileURLWithPath: unsafe).standardizedFileURL.path))
            }
        }
        XCTAssertThrowsError(try Uninstaller.checkPurgeable(SimQueuePaths(stateDir: state), home: home)) {
            guard case .notAStateDir = $0 as? Uninstaller.PurgeError else { return XCTFail("\($0)") }
        }
        // A symlink to the home dir (or above it) is the home dir.
        let link = testScratchRoot() + "/link-" + UUID().uuidString.prefix(8)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: home)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: home + "/config.json"))
        XCTAssertThrowsError(try Uninstaller.checkPurgeable(SimQueuePaths(stateDir: link), home: home)) {
            guard case .unsafePath = $0 as? Uninstaller.PurgeError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try Uninstaller.checkPurgeable(SimQueuePaths(stateDir: home), home: link)) {
            guard case .unsafePath = $0 as? Uninstaller.PurgeError else { return XCTFail("\($0)") }
        }
        try Data("{}".utf8).write(to: URL(fileURLWithPath: state + "/config.json"))
        XCTAssertNoThrow(try Uninstaller.checkPurgeable(SimQueuePaths(stateDir: state), home: home))
    }
}
