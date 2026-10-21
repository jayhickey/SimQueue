// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueProtocol
import SimQueueSim
import XCTest

/// `template_build` / `template_list` / `template_rm` through the daemon, and the config rules.
final class TemplateServiceTests: XCTestCase {
    private func config() throws -> DaemonConfig {
        try DaemonConfig.parse(
            Data(
                #"""
                {"pool": {"mode": "active"},
                 "template": {"device_type": "Default-Device", "runtime": "iOS-26-0",
                            "profiles": {"lean": ["--drop", "photos"]}},
                 "projects": {"demo": {"repo": "/src/demo", "scheme": "Demo"}}}
                """#.utf8))
    }

    func testHostWideResolutionUsesFlagsThenHostDefaults() throws {
        let config = try config()
        let resolved = try config.templateTarget(project: "demo", profile: nil, deviceType: nil, runtime: nil)
        XCTAssertEqual(resolved.profile, "default")
        XCTAssertEqual(resolved.arguments, [])
        XCTAssertEqual(resolved.deviceType, "Default-Device", "project labels do not change the host device")
        XCTAssertEqual(resolved.runtime, "iOS-26-0", "the default fills what the project leaves out")
        let flagged = try config.templateTarget(
            project: "demo", profile: "lean", deviceType: "Flag-Device", runtime: nil)
        XCTAssertEqual(flagged.deviceType, "Flag-Device")
        XCTAssertEqual(flagged.arguments, ["--drop", "photos"])
        XCTAssertThrowsError(try config.templateTarget(project: "demo", profile: "nope", deviceType: nil, runtime: nil))
        let unlisted = try config.templateTarget(project: "other", profile: nil, deviceType: nil, runtime: nil)
        XCTAssertEqual(unlisted.deviceType, "Default-Device", "a project needn't be in the config")
        XCTAssertThrowsError(
            try config.templateTarget(project: "Bad Name", profile: nil, deviceType: nil, runtime: nil))
        XCTAssertThrowsError(
            try DaemonConfig().templateTarget(project: "demo", profile: nil, deviceType: nil, runtime: nil))
        // Zero config: the host's newest iOS runtime and iPhone; config and flags still win.
        let host = { () -> (deviceType: String, runtime: String)? in ("Host-iPhone", "Host-iOS") }
        let zero = try DaemonConfig().templateTarget(
            project: "demo", profile: nil, deviceType: nil, runtime: nil, hostDefault: host)
        XCTAssertEqual(zero.deviceType, "Host-iPhone")
        XCTAssertEqual(zero.runtime, "Host-iOS")
        XCTAssertEqual(zero.profile, "default")
        let mixed = try config.templateTarget(
            project: "demo", profile: nil, deviceType: nil, runtime: nil,
            hostDefault: {
                XCTFail("not read when the config has both"); return nil
            })
        XCTAssertEqual(mixed.runtime, "iOS-26-0")
    }

    func testProjectSpecificTemplateRoutingIsRejected() {
        XCTAssertThrowsError(
            try DaemonConfig.parse(
                Data(
                    #"{"projects":{"demo":{"repo":"/src/demo","scheme":"Demo","template":{"device_type":"Other"}}}}"#
                        .utf8)))
    }

    func testTemplateAndPoolAreReservedProjectNames() {
        for name in ["template", "pool", "template-app", "pool-x"] {
            XCTAssertFalse(DaemonConfig.ProjectSettings.isValidName(name), name)
            XCTAssertThrowsError(
                try DaemonConfig.parse(Data(#"{"projects": {"\#(name)": {"repo": "/r", "scheme": "S"}}}"#.utf8)))
        }
        XCTAssertThrowsError(try DaemonConfig.parse(Data(#"{"template": {"profiles": {"Bad Name": []}}}"#.utf8)))
    }

    func testBuildIsRefusedOverTheProtocolWhenThePoolIsOff() throws {
        var config = try config()
        config.pool?.mode = .reportOnly
        let daemon = try TestDaemon(config: config)
        defer { daemon.destroy() }
        let error = try daemon.protocolError(.templateBuild(TemplateBuildParams(project: "demo")))
        XCTAssertEqual(error.code, .invalidState)
        XCTAssertTrue(error.message.contains("pool.mode is report-only"), error.message)
        XCTAssertTrue(daemon.sims.baseCreates.isEmpty)
    }

    func testBuildListAndReportOnlyRemoveOverTheProtocol() throws {
        let daemon = try TestDaemon(config: try config())
        defer { daemon.destroy() }
        guard
            case .template(let built) = try daemon.result(
                .templateBuild(TemplateBuildParams(project: "demo", profile: "lean", slim: true)))
        else { return XCTFail("no template result") }
        XCTAssertEqual(built.outcome, "built")
        let template = try XCTUnwrap(built.templates.first)
        XCTAssertTrue(template.name.hasPrefix("simq-template-demo-lean-"), template.name)
        XCTAssertEqual(template.deviceType, "Default-Device")
        XCTAssertEqual(template.stale, false)
        XCTAssertEqual(daemon.sims.slimCalls.map(\.arguments), [["--drop", "photos"]])

        guard case .template(let listed) = try daemon.result(.templateList) else { return XCTFail("no list") }
        XCTAssertEqual(listed.templates, [template])
        XCTAssertEqual(
            try daemon.protocolError(.templateBuild(TemplateBuildParams(project: "demo", profile: "lean", slim: true)))
                .code,
            .invalidState, "already exists without --replace")
        XCTAssertEqual(
            try daemon.protocolError(.templateBuild(TemplateBuildParams(project: "Bad Name"))).code, .invalidArgument,
            "an unlisted project builds with the defaults; an invalid name doesn't")

        // The default cleanup mode is report-only: removal is reported and the template kept.
        guard
            case .template(let removed) = try daemon.result(
                .templateRemove(TemplateRemoveParams(template: template.name)))
        else { return XCTFail("no rm result") }
        XCTAssertEqual(removed.outcome, "would_remove")
        XCTAssertTrue(try daemon.sims.listDevices().contains { $0.udid == template.udid })
        XCTAssertEqual(
            try daemon.protocolError(.templateRemove(TemplateRemoveParams(template: "simq-template-x"))).code, .notFound
        )
    }

    func testDryRunRefusesToBuild() throws {
        let logged = LockedLines()
        let dryRun = DryRunSimBackend(FakeSimBackend()) { logged.append($0) }
        let daemon = try TestDaemon(config: try config(), simsOverride: dryRun)
        defer { daemon.destroy() }
        XCTAssertNotEqual(
            try daemon.protocolError(.templateBuild(TemplateBuildParams(project: "demo"))).code, .notFound)
        XCTAssertTrue(
            logged.lines.contains { $0.hasPrefix("dry-run: would create template simq-template-demo-default-") })
    }

    func testRequestsRoundTrip() throws {
        for params in [
            RequestParams.templateBuild(
                TemplateBuildParams(project: "demo", profile: "p", deviceType: "d", runtime: "r", replace: true)),
            .templateList, .templateRemove(TemplateRemoveParams(template: "g")),
        ] {
            let request = Request(id: "1", params: params)
            XCTAssertEqual(try JSONDecoder().decode(Request.self, from: JSONEncoder().encode(request)), request)
        }
    }

    func testBuildDoesNotHoldTheServiceLockWhileCreating() throws {
        let daemon = try TestDaemon(config: try config())
        defer { daemon.destroy() }
        let answered = DispatchSemaphore(value: 0)
        let service = daemon.service
        daemon.sims.beforeBaseCreate = {
            // Another request during the create must be served, not blocked.
            DispatchQueue.global().async {
                _ = service.handle(Request(params: .status))
                answered.signal()
            }
            _ = answered.wait(timeout: .now() + 5)
        }
        _ = try daemon.result(.templateBuild(TemplateBuildParams(project: "demo")))
        XCTAssertEqual(answered.wait(timeout: .now()), .timedOut, "consumed inside the hook")
        XCTAssertEqual(daemon.sims.baseCreates.count, 1)
    }

    func testDoctorListsUnregisteredTemplateSims() throws {
        let daemon = try TestDaemon(config: try config())
        defer { daemon.destroy() }
        daemon.sims.setDevices([SimDevice(udid: "GOLD-9", name: "simq-template-demo-default-77", isBooted: false)])
        guard case .doctor(let report) = try daemon.result(.doctor) else { return XCTFail("no doctor report") }
        let check = try XCTUnwrap(report.checks.first { $0.name == "templates" })
        XCTAssertEqual(check.level, .warn)
        XCTAssertTrue(check.detail.contains("unregistered template sims"), check.detail)
        XCTAssertTrue(check.detail.contains("GOLD-9"), check.detail)
    }
}

final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func append(_ line: String) {
        lock.lock()
        stored.append(line)
        lock.unlock()
    }
}
