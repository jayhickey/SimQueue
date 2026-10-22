// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueHost
import SimQueueProtocol
import SimQueueSim
import SimQueueStore
import XCTest

final class SmokeTests: XCTestCase {
    func testVersionIsASemanticVersion() {
        XCTAssertTrue(SimQueueVersion.isValid(SimQueueVersion.current), SimQueueVersion.current)
        for good in ["0.0.0-dev", "1.2.3", "1.2.3-rc.1", "0.0.0-dev+abc1234", "10.20.30+build.7"] {
            XCTAssertTrue(SimQueueVersion.isValid(good), good)
        }
        for bad in ["", "v1.2.3", "1.2", "1.2.3.4", "1.2.3-", "1.2.3+", "1..3", "1.2.3-rc..1", "1.2.x", "1.2.3 "] {
            XCTAssertFalse(SimQueueVersion.isValid(bad), bad)
        }
    }

    func testVersionDoctorCheckWarnsOnlyOnAMismatch() {
        XCTAssertEqual(DoctorCheck.version(client: "1.0.0", daemon: "1.0.0").level, .ok)
        XCTAssertEqual(DoctorCheck.version(client: "1.0.0", daemon: nil).level, .ok)
        let mismatch = DoctorCheck.version(client: "1.0.1", daemon: "1.0.0")
        XCTAssertEqual(mismatch.level, .warn)
        XCTAssertEqual(mismatch.name, "version")
        XCTAssertTrue(mismatch.detail.contains("simq 1.0.1, simqd 1.0.0"), mismatch.detail)
    }

    /// `app_cli`: the running simq vs SimQueue.app's bundled one, found through an injected lookup.
    func testAppCLIDoctorCheck() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("simq-appcli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        let app = home + "/Applications/SimQueue.app"
        let helpers = app + "/Contents/Helpers"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: helpers + "/simq", contents: Data(), attributes: [.posixPermissions: 0o755])
        let cellar = root.appendingPathComponent("Cellar/simqueue/bin").path
        try FileManager.default.createDirectory(atPath: cellar, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: cellar + "/simq", contents: Data(), attributes: [.posixPermissions: 0o755])
        let link = root.appendingPathComponent("bin-simq").path

        let apps = DoctorCheck.installedApps(home: home, isExecutable: { $0.hasPrefix(home) })
        XCTAssertEqual(apps, [app])

        // App present, simq is the app's (through a symlink, like the cask's bin link): OK.
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: helpers + "/simq")
        let same = try XCTUnwrap(DoctorCheck.appCLI(runningSimq: link, apps: apps))
        XCTAssertEqual(same.name, "app_cli")
        XCTAssertEqual(same.level, .ok, same.detail)

        // App present, simq is the formula's: WARN with the one-line fix.
        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: cellar + "/simq")
        let other = try XCTUnwrap(DoctorCheck.appCLI(runningSimq: link, apps: apps))
        XCTAssertEqual(other.level, .warn)
        XCTAssertTrue(other.detail.contains("brew uninstall simqueue && brew link --cask simqueue-app"), other.detail)

        // No app installed: no check.
        let none = DoctorCheck.installedApps(home: home, isExecutable: { _ in false })
        XCTAssertEqual(none, [])
        XCTAssertNil(DoctorCheck.appCLI(runningSimq: link, apps: none))
    }

    func testFakeBackendIsAlwaysAllowed() throws {
        XCTAssertEqual(try BackendGate.resolve(requested: .fake, simctlAvailable: false), .fake)
        XCTAssertEqual(try BackendGate.resolve(requested: .fake, simctlAvailable: true), .fake)
    }

    /// No opt-in variable: simctl resolves wherever simctl exists, with a clear error elsewhere.
    func testRealBackendNeedsOnlyMacOS() throws {
        XCTAssertEqual(try BackendGate.resolve(requested: .simctl, simctlAvailable: true), .simctl)
        XCTAssertThrowsError(try BackendGate.resolve(requested: .simctl, simctlAvailable: false)) { error in
            XCTAssertEqual(error as? BackendGateError, .simctlNeedsMacOS)
            XCTAssertTrue("\(error)".contains("--backend fake"))
        }
    }

    func testDefaultBackendIsSimctlOnMacOSAndFakeOtherwiseAndForADryRun() {
        #if os(macOS)
            XCTAssertEqual(BackendKind.platformDefault, .simctl)
        #else
            XCTAssertEqual(BackendKind.platformDefault, .fake)
        #endif
        XCTAssertEqual(BackendGate.choose(flag: nil, config: nil, dryRun: false), .platformDefault)
        XCTAssertEqual(BackendGate.choose(flag: nil, config: nil, dryRun: true), .fake)
        XCTAssertEqual(BackendGate.choose(flag: nil, config: .fake, dryRun: false), .fake, "config fake")
        XCTAssertEqual(BackendGate.choose(flag: nil, config: .simctl, dryRun: true), .fake, "dry run beats config")
        XCTAssertEqual(BackendGate.choose(flag: .simctl, config: nil, dryRun: true), .simctl, "real reads on request")
        XCTAssertEqual(BackendGate.choose(flag: .fake, config: .simctl, dryRun: false), .fake, "flag wins")
    }

    func testPriorityIsAPlainIntegerWithNeutralDefault() {
        XCTAssertEqual(Priority.defaultValue, 50)
        XCTAssertEqual(Priority.range, 0...100)
    }

    func testEnvelopeUsesSnakeCaseSchemaVersion() throws {
        let data = try JSONEncoder().encode(Envelope(kind: "status"))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"schema_version\":1"))
    }

    func testInMemorySQLiteOpens() throws {
        _ = try Database(path: ":memory:")
        XCTAssertFalse(Database.libraryVersion.isEmpty)
    }

    func testFakeProbeAndBackend() throws {
        let host = HostSnapshot(
            sampledAt: 0,
            totalMemoryBytes: 32 << 30,
            availableMemoryBytes: 3 << 30,
            cpuCount: 8,
            freeDiskBytes: 100 << 30
        )
        let probe = FakeResourceProbe(fixed: host)
        XCTAssertEqual(try probe.sample(now: 42).availableMemoryBytes, 3 << 30)
        XCTAssertEqual(try probe.sample(now: 42).sampledAt, 42)
        let backend = FakeSimBackend(devices: [SimDevice(udid: "FAKE-1", name: "simq-pool-1", isBooted: false)])
        XCTAssertEqual(try backend.listDevices().count, 1)
        XCTAssertEqual(try backend.poolSnapshot(), PoolSnapshot())
    }
}
