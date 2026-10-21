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
