// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueProtocol
import SimQueueSim
import SimQueueStore
import XCTest

/// `simqd --backend simctl|fake` and `--probe` selection. Nothing here runs a tool: the
/// fake tools on PATH log any call, and the log must stay empty.
final class HostBackendsTests: XCTestCase {
    static let host = HostSnapshot(
        sampledAt: 0, totalMemoryBytes: 1, availableMemoryBytes: 1, cpuCount: 1, freeDiskBytes: 1)

    func testSelectionAndThePlatformGate() throws {
        let tools = try FakeToolHarness()
        defer { tools.cleanUp() }
        let env = tools.toolEnvironment

        let fake = try HostBackends.make(
            backend: .fake, probe: nil, config: DaemonConfig(), environment: env, fakeHost: Self.host)
        XCTAssertEqual(fake.backend, .fake)
        XCTAssertEqual(fake.probeKind, .fake)
        XCTAssertTrue(fake.sims is FakeSimBackend)

        let systemProbe = try HostBackends.make(
            backend: .fake, probe: .system, config: DaemonConfig(), environment: env, fakeHost: Self.host)
        XCTAssertTrue(systemProbe.probe is SystemResourceProbe, "real readings with fake sims")

        var config = DaemonConfig()
        config.simctl = DaemonConfig.SimctlSettings(template: "simq-template-demo-slim")
        XCTAssertThrowsError(
            try HostBackends.make(
                backend: .simctl, probe: nil, config: config, environment: env, fakeHost: Self.host,
                simctlAvailable: false)
        ) { XCTAssertEqual($0 as? BackendGateError, .simctlNeedsMacOS) }

        let zeroConfig = try HostBackends.make(
            backend: .simctl, probe: nil, config: DaemonConfig(), environment: env, fakeHost: Self.host,
            simctlAvailable: true)
        XCTAssertNil((zeroConfig.sims as? SimctlBackend)?.template, "no simctl.template needed")
        XCTAssertNil(zeroConfig.sims.templateCloneSource?.cloneTemplate, "no template until one is built")
        let real = try HostBackends.make(
            backend: .simctl, probe: nil, config: config, environment: env, fakeHost: Self.host,
            simctlAvailable: true)
        XCTAssertEqual(real.backend, .simctl)
        XCTAssertEqual(real.probeKind, .system)
        XCTAssertEqual((real.sims as? SimctlBackend)?.template, "simq-template-demo-slim")
        XCTAssertEqual(try tools.loggedCalls(), [], "choosing a backend runs no tool")
    }

    func testSimctlConfigSection() throws {
        let config = try DaemonConfig.parse(Data(#"{"simctl": {"template": "simq-template-x"}}"#.utf8))
        XCTAssertEqual(config.simctl?.template, "simq-template-x")
        XCTAssertNil(try DaemonConfig.parse(Data("{}".utf8)).simctl)
        XCTAssertNil(try DaemonConfig.parse(Data("{}".utf8)).backend, "no config backend: the platform default")
        XCTAssertEqual(try DaemonConfig.parse(Data(#"{"backend": "fake"}"#.utf8)).backend, .fake)
        XCTAssertEqual(try DaemonConfig.parse(Data(#"{"backend": "simctl"}"#.utf8)).backend, .simctl)
        XCTAssertThrowsError(try DaemonConfig.parse(Data(#"{"backend": "real"}"#.utf8)))
        XCTAssertNil(try DaemonConfig.parse(Data(#"{"simctl": {}}"#.utf8)).simctl?.template, "optional")
        XCTAssertThrowsError(try DaemonConfig.parse(Data(#"{"simctl": {"template": ""}}"#.utf8)))
    }

    func testDoctorReportsTheActiveBackend() throws {
        let store = try JobStore(path: ":memory:")
        func detail(_ info: DaemonInfo) throws -> String? {
            try DoctorBuilder.build(store: store, now: 0, daemon: info, socketPath: nil).checks
                .first { $0.name == "backend" }?.detail
        }
        func info(_ backend: String, _ probe: String?, _ dryRun: Bool?) -> DaemonInfo {
            DaemonInfo(
                version: "t", pid: 1, epoch: 1, backend: backend, startedAt: 0, statePath: "s", socketPath: "k",
                cleanupMode: "report-only", probe: probe, dryRun: dryRun)
        }
        XCTAssertEqual(try detail(info("fake", "fake", nil)), "sims fake, probe fake")
        XCTAssertEqual(
            try detail(info("simctl", "system", true)),
            "sims simctl (real simulators), probe system, dry run (host actions logged, not run)")
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        guard case .result(.doctor(let report)) = daemon.service.handle(Request(params: .doctor)).body else {
            return XCTFail("doctor")
        }
        XCTAssertEqual(report.daemon?.backend, "fake")
        XCTAssertNotNil(report.checks.first { $0.name == "backend" })
    }
}
