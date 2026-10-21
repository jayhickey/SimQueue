// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueEngine
import SimQueueHost
import SimQueueProtocol
import SimQueueSim
import XCTest

/// Template candidates never select the active host-wide clone source implicitly.
final class DefaultTemplateTests: XCTestCase {
    private func daemon(configured: String? = nil, warmMin: Int = 1) throws -> (TestDaemon, FakeSimBackend) {
        let sims = FakeSimBackend()
        sims.clonesTemplate = true
        sims.configuredTemplateValue = configured
        var config = try DaemonConfig.parse(
            Data(
                #"""
                {"template": {"device_type": "Default-Device", "runtime": "iOS-26-0", "profiles": {"lean": []}},
                 "projects": {"demo": {"repo": "/src/demo", "scheme": "Demo"}},
                 "cleanup_mode": "enforce"}
                """#.utf8))
        var pool = SimPoolConfig()
        pool.maxSims = 1
        pool.warmMin = warmMin
        pool.settle.mode = .load
        pool.settle.loadBelow = 1000
        config.pool = pool
        return (try TestDaemon(config: config, simsOverride: sims), sims)
    }

    private func status(_ daemon: TestDaemon) throws -> StatusResult {
        guard case .status(let status) = try daemon.result(.status) else { throw TestFailure("no status") }
        return status
    }

    private func templateCheck(_ daemon: TestDaemon) throws -> DoctorCheck? {
        guard case .doctor(let report) = try daemon.result(.doctor) else { throw TestFailure("no doctor") }
        return report.checks.first { $0.name == "template" }
    }

    private func eventually(_ what: String, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(10)
        while try !condition() {
            guard Date() < deadline else { return XCTFail(what) }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// Nothing configured at all: `simq template build <any project>` picks the host's
    /// newest iOS runtime and iPhone, and the pool clones the result.

    func testBuildingCandidatesDoesNotSelectOrSwitchTheHostTemplate() throws {
        let (daemon, sims) = try daemon(configured: "chosen", warmMin: 0)
        defer { daemon.destroy() }
        for label in ["first", "second"] {
            _ = try daemon.result(.templateBuild(TemplateBuildParams(project: label)))
            XCTAssertEqual(sims.cloneTemplate, "chosen")
            XCTAssertNil(sims.defaultTemplate)
        }
        XCTAssertTrue(try status(daemon).templateHint?.contains("chosen") == true)
    }

    func testDefaultTargetFromSimctlRuntimes() throws {
        let json = #"""
            {"runtimes": [
              {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-6", "version": "18.6", "platform": "iOS",
               "isAvailable": true, "supportedDeviceTypes": [
                 {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16", "productFamily": "iPhone"}]},
              {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "version": "26.0", "platform": "iOS",
               "isAvailable": true, "supportedDeviceTypes": [
                 {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16", "productFamily": "iPhone"},
                 {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "productFamily": "iPhone"},
                 {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13", "productFamily": "iPad"}]},
              {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-1", "version": "26.1", "platform": "iOS",
               "isAvailable": false, "supportedDeviceTypes": [
                 {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "productFamily": "iPhone"}]},
              {"identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-26-0", "version": "26.0",
               "platform": "watchOS", "isAvailable": true, "supportedDeviceTypes": []}
            ]}
            """#
        let target = try SimctlBackend.parseDefaultTemplateTarget(runtimesJSON: json)
        XCTAssertEqual(target.runtime, "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "newest available iOS")
        XCTAssertEqual(target.deviceType, "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "its newest iPhone")
        XCTAssertThrowsError(try SimctlBackend.parseDefaultTemplateTarget(runtimesJSON: #"{"runtimes": []}"#))
    }

    /// CR #63: removing the last template clears the default (it isn't kept, so nothing
    /// clones a deleted sim), and status and doctor say there's no template again.

    /// CR #63 follow-up: a fresh template beats a newer stale one, and doctor warns when
    /// every ready template is stale.

    func testTheConfiguredTemplateOverridesTheDefault() throws {
        let (daemon, sims) = try daemon(configured: "my-template")
        defer { daemon.destroy() }
        try eventually("the pool never cloned the configured template") { sims.clonedFrom.first == "my-template" }
        XCTAssertTrue(try status(daemon).templateHint?.contains("my-template") == true)
        XCTAssertEqual(try templateCheck(daemon)?.detail, "clones copy my-template (simctl.template)")
    }

    func testAFakeBackendThatDoesntCloneHasNoTemplateCheck() throws {
        let daemon = try TestDaemon()
        defer { daemon.destroy() }
        XCTAssertNil(try status(daemon).templateHint)
        XCTAssertNil(try templateCheck(daemon))
    }

    /// The real backend: no `simctl.template` is fine; a clone with no template says what to
    /// do and runs no tool; with a default it clones that UDID.
    func testSimctlBackendClonesTheDefaultTemplate() throws {
        let harness = try FakeToolHarness()
        defer { harness.cleanUp() }
        let backend = try SimctlBackend(runner: ToolRunner(environment: harness.toolEnvironment, killGraceSeconds: 0.5))
        XCTAssertNil(backend.cloneTemplate)
        XCTAssertThrowsError(try backend.createDevice(name: "simq-pool-1-1")) {
            XCTAssertEqual($0 as? SimctlBackendError, .noTemplate)
            XCTAssertEqual("\($0)", "no template yet, run simq template build")
        }
        XCTAssertEqual(try harness.loggedCalls(), [], "no tool ran")
        backend.setDefaultTemplate(DefaultTemplate(name: "simq-template-demo-default-3", udid: "GOLD-3"))
        try harness.respond("simslim---version", out: "simslim 0.12.2\n")
        try harness.respond("simslim---help", out: "Usage: simslim <command>\n  clone <udid> <name>\n")
        try harness.respond("xcrun-list", out: #"{"devices":{}}"#)
        try harness.respond("xcrun-clone", out: "done\n")
        _ = try? backend.createDevice(name: "simq-pool-1-1")
        XCTAssertTrue(try harness.loggedCalls().contains("xcrun simctl clone GOLD-3 simq-pool-1-1"))
    }
}
