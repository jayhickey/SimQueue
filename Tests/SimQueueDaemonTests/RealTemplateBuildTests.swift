// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueProtocol
import SimQueueSim
import XCTest

/// `simq template build` end to end on the real backend (SimctlBackend over the fake tools):
/// behind the pool gate, created with `simctl create`, first-booted, registered with a
/// pool-owned template row that reconcile in enforce mode never touches.
final class RealTemplateBuildTests: XCTestCase {
    static let templateUDIDs = (1...18).map { String(format: "AAAAAAAA-BBBB-4CCC-8DDD-%012d", $0) }

    /// One JSON for both `simctl list -j devices` and `-j runtimes` (the fake tools key both
    /// as `xcrun-list`; each decoder ignores the other's key). Lists a template for each of
    /// the first nine intent ids, for both profiles, so the build's name is found whatever its id is.
    static func listing() -> String {
        let templates = templateUDIDs.enumerated().map { index, udid in
            let name = "simq-template-demo-\(index < 9 ? "lean" : "default")-\(index % 9 + 1)"
            return #"{"udid": "\#(udid)", "name": "\#(name)", "state": "Shutdown"}"#
        }
        let foreign = #"{"udid": "11111111-2222-4333-8444-555555555555", "name": "iPhone 16", "state": "Booted"}"#
        return #"""
            {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": [\#((templates + [foreign]).joined(separator: ","))]},
             "runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "version": "26.0"}]}
            """#
    }

    private func config(poolMode: String) throws -> DaemonConfig {
        try DaemonConfig.parse(
            Data(
                #"""
                {"cleanup_mode": "enforce",
                 "pool": {"mode": "\#(poolMode)", "warm_min": 0},
                 "template": {"device_type": "iPhone-16", "runtime": "iOS-26-0", "profiles": {"lean": ["--except", "search"]}},
                 "projects": {"demo": {"repo": "/src/demo", "scheme": "Demo"}}}
                """#.utf8))
    }

    private func daemon(poolMode: String, simslim: Bool) throws -> (TestDaemon, FakeToolHarness) {
        let harness = try FakeToolHarness()
        addTeardownBlock { harness.cleanUp() }
        try harness.respond("xcrun-list", out: Self.listing())
        try harness.respond("xcodebuild--version", out: "Xcode 26.0\nBuild version 17A000\n")
        if simslim {
            try harness.respond("simslim---help", out: RealBackendFakeToolTests.simslimHelp)
        } else {
            try harness.respond("simslim---help", status: 127)
        }
        let backend = try SimctlBackend(
            template: "simq-template-demo-lean-1",
            runner: ToolRunner(environment: harness.toolEnvironment, killGraceSeconds: 0.5))
        let daemon = try TestDaemon(config: try config(poolMode: poolMode), simsOverride: backend)
        addTeardownBlock { daemon.destroy() }
        return (daemon, harness)
    }

    func testBuildsWithSimslimAndRegistersAPoolOwnedTemplateThatEnforceNeverDeletes() throws {
        let (daemon, harness) = try daemon(poolMode: "active", simslim: true)
        guard
            case .template(let built) = try daemon.result(
                .templateBuild(TemplateBuildParams(project: "demo", profile: "lean", slim: true)))
        else { return XCTFail("no template result") }
        let template = try XCTUnwrap(built.templates.first)
        XCTAssertEqual(built.outcome, "built")
        XCTAssertEqual(template.status, "ready")
        XCTAssertEqual(template.slimmed, true)
        let calls = try harness.loggedCalls()
        XCTAssertTrue(calls.contains("xcrun simctl create \(template.name) iPhone-16 iOS-26-0"), "\(calls)")
        XCTAssertTrue(calls.contains("simslim on \(template.udid) --preserve-boot-state --except search"), "\(calls)")

        let row = try XCTUnwrap(
            try daemon.side.liveResources(kinds: [.template]).first { $0.externalID == template.udid })
        XCTAssertEqual(row.owner, .pool)
        XCTAssertEqual(row.state, .active)
        // Enforce-mode reconcile: the registered template is claimed, never deleted.
        _ = try daemon.service.handle(Request(params: .status))
        let report = try daemon.engine.reconcile()
        XCTAssertFalse(report.actions.contains { "\($0)".contains(template.udid) }, "\(report.actions)")
        XCTAssertFalse(try harness.loggedCalls().contains { $0.hasPrefix("xcrun simctl delete") })
        XCTAssertEqual(try daemon.side.resource(id: row.id)?.state, .active)
    }

    func testStockTemplateBuildNeedsNoSimslimAndRecordsThatItIsNotSlimmed() throws {
        let (daemon, harness) = try daemon(poolMode: "active", simslim: false)
        guard case .template(let built) = try daemon.result(.templateBuild(TemplateBuildParams(project: "demo"))) else {
            return XCTFail("no template result")
        }
        let template = try XCTUnwrap(built.templates.first)
        XCTAssertEqual(template.status, "ready")
        XCTAssertEqual(template.slimmed, false)
        XCTAssertFalse(try harness.loggedCalls().contains { $0.hasPrefix("simslim ") })
    }

    func testRefusedUpFrontWithoutSimslim() throws {
        let (daemon, harness) = try daemon(poolMode: "active", simslim: false)
        let error = try daemon.protocolError(.templateBuild(TemplateBuildParams(project: "demo", slim: true)))
        XCTAssertEqual(error.code, .invalidState)
        XCTAssertTrue(error.message.contains("install simslim"), error.message)
        XCTAssertFalse(
            try harness.loggedCalls().contains { $0.contains("simctl create") || $0.contains("simctl boot") })
        XCTAssertTrue(try daemon.side.liveResources(kinds: [.template]).isEmpty)
    }

    func testStillBehindThePoolGate() throws {
        let (daemon, harness) = try daemon(poolMode: "report-only", simslim: true)
        let error = try daemon.protocolError(.templateBuild(TemplateBuildParams(project: "demo", slim: true)))
        XCTAssertEqual(error.code, .invalidState)
        XCTAssertTrue(error.message.contains("pool.mode is report-only"), error.message)
        XCTAssertFalse(
            try harness.loggedCalls().contains { $0.contains("simctl create") || $0.hasPrefix("simslim on") })
    }
}
