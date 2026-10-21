// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueProtocol
import SimQueueSim
import XCTest

/// Templates were called goldens. The old config keys, socket names and project-name
/// shape keep working after the rename. Project-specific routing is refused under v1's
/// explicit host-wide template contract.
final class TemplateRenameCompatTests: XCTestCase {
    /// A synthetic legacy config exercises old key compatibility and host-wide routing.
    static let preRenameConfig = #"""
        {
          "simctl": { "golden": "11111111-2222-4333-8444-555555555555" },
          "projects": { "exampleapp": { "repo": "/src/exampleapp", "scheme": "ExampleApp", "container": "ExampleApp.xcodeproj" } },
          "golden": { "device_type": "iPhone 17", "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                      "profiles": { "default": [] } },
          "pool": {
            "mode": "active",
            "max_sims": 1,
            "max_concurrent_boots": 1,
            "settle": { "mode": "load", "load_below": 20, "max_wait_seconds": 180, "on_cap": "handoff" },
            "external_sim_patterns": ["ExampleApp Smoke *", "ExampleApp Slot *"]
          }
        }
        """#

    func testThePreRenameConfigLoadsUnchangedAndTheSimctlBackendClonesItsGolden() throws {
        let config = try DaemonConfig.parse(Data(Self.preRenameConfig.utf8))
        XCTAssertEqual(config.simctl?.template, "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(config.template.deviceType, "iPhone 17")
        XCTAssertEqual(config.template.runtime, "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        XCTAssertEqual(config.template.profiles, ["default": []])

        let tools = try FakeToolHarness()
        defer { tools.cleanUp() }
        let backends = try HostBackends.make(
            backend: .simctl, probe: nil, config: config, environment: tools.toolEnvironment,
            fakeHost: HostBackendsTests.host, simctlAvailable: true)
        let source = try XCTUnwrap(backends.sims.templateCloneSource)
        XCTAssertEqual(source.configuredTemplate, "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(source.cloneTemplate, "11111111-2222-4333-8444-555555555555")
    }

    func testOldConfigKeysAreReadAndTheNewOnesWin() throws {
        let old = try DaemonConfig.parse(
            Data(
                #"""
                {"simctl": {"golden": "old-udid"},
                 "golden": {"device_type": "Old-Device", "profiles": {"lean": ["--old"]}},
                 "projects": {"demo": {"repo": "/src/demo", "scheme": "Demo"}}}
                """#.utf8))
        XCTAssertEqual(old.simctl?.template, "old-udid")
        XCTAssertEqual(old.template.deviceType, "Old-Device")
        XCTAssertEqual(old.template.profiles["lean"], ["--old"])
        XCTAssertNil(old.projects["demo"]?.template)

        let both = try DaemonConfig.parse(
            Data(
                #"""
                {"simctl": {"golden": "old-udid", "template": "new-udid"},
                 "golden": {"device_type": "Old-Device"},
                 "template": {"device_type": "New-Device"},
                 "projects": {"demo": {"repo": "/src/demo", "scheme": "Demo"}}}
                """#.utf8))
        XCTAssertEqual(both.simctl?.template, "new-udid")
        XCTAssertEqual(both.template.deviceType, "New-Device")
        XCTAssertNil(both.projects["demo"]?.template)

        XCTAssertThrowsError(try DaemonConfig.parse(Data(#"{"simctl": {"golden": ""}}"#.utf8))) {
            XCTAssertTrue("\($0)".contains("simctl.golden must not be empty"), "\($0)")
        }
        // Project labels do not serialize simulator-routing settings.
        let encoded = try JSONEncoder().encode(try XCTUnwrap(old.projects["demo"]))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any]).keys
        XCTAssertFalse(keys.contains("template"))
        XCTAssertFalse(keys.contains("golden"))
    }

    func testProjectTemplateAndLegacyGoldenOverridesAreExplicitlyRefused() throws {
        for key in ["template", "golden"] {
            let object: [String: Any] = [
                "template": ["device_type": "Host-Device", "runtime": "Host-Runtime"],
                "projects": ["demo": ["repo": "/src/demo", "scheme": "Demo", key: ["runtime": "Project-Runtime"]]],
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try DaemonConfig.parse(data), key) { error in
                let message = String(describing: error)
                XCTAssertTrue(message.contains("project.template/golden was removed"), message)
                XCTAssertTrue(message.contains("host-wide"), message)
                XCTAssertTrue(message.contains("project labels do not route simulators"), message)
            }
        }
    }

    func testGoldenStaysAReservedProjectName() {
        for name in ["golden", "golden-app", "template", "template-app"] {
            XCTAssertFalse(DaemonConfig.ProjectSettings.isValidName(name), name)
        }
    }

    // MARK: - Socket protocol

    private func config() throws -> DaemonConfig {
        try DaemonConfig.parse(
            Data(
                #"""
                {"pool": {"mode": "active"},
                 "template": {"device_type": "Default-Device", "runtime": "iOS-26-0"}}
                """#.utf8))
    }

    /// Sends one raw request line through the service and returns the answer as JSON.
    private func exchange(_ daemon: TestDaemon, _ line: String) throws -> [String: Any] {
        let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
        let data = try JSONEncoder().encode(daemon.service.handle(request))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testOldMethodNamesAreAnsweredWithTheOldNames() throws {
        let daemon = try TestDaemon(config: try config())
        defer { daemon.destroy() }
        let built = try exchange(
            daemon, #"{"schema_version": 1, "id": "1", "method": "golden_build", "params": {"project": "demo"}}"#)
        XCTAssertEqual(built["result_kind"] as? String, "golden")
        let result = try XCTUnwrap(built["result"] as? [String: Any])
        XCTAssertEqual(result["outcome"] as? String, "built")
        XCTAssertNil(result["templates"])
        let template = try XCTUnwrap((result["goldens"] as? [[String: Any]])?.first)
        let name = try XCTUnwrap(template["name"] as? String)
        XCTAssertTrue(name.hasPrefix("simq-template-demo-default-"), name)

        let listed = try exchange(daemon, #"{"schema_version": 1, "id": "2", "method": "golden_list"}"#)
        XCTAssertEqual(listed["result_kind"] as? String, "golden")
        XCTAssertEqual(((listed["result"] as? [String: Any])?["goldens"] as? [Any])?.count, 1)

        // The new names get only the new names.
        let current = try exchange(daemon, #"{"schema_version": 1, "id": "3", "method": "template_list"}"#)
        XCTAssertEqual(current["result_kind"] as? String, "template")
        let currentResult = try XCTUnwrap(current["result"] as? [String: Any])
        XCTAssertEqual((currentResult["templates"] as? [Any])?.count, 1)
        XCTAssertNil(currentResult["goldens"])

        // golden_rm with the old field name (report-only by default: kept).
        let removed = try exchange(
            daemon, #"{"schema_version": 1, "id": "4", "method": "golden_rm", "params": {"golden": "\#(name)"}}"#)
        XCTAssertEqual(removed["result_kind"] as? String, "golden")
        XCTAssertEqual((removed["result"] as? [String: Any])?["outcome"] as? String, "would_remove")
    }

    func testOldRequestShapesDecodeToTheTemplateRequests() throws {
        let remove = try JSONDecoder().decode(
            Request.self,
            from: Data(#"{"schema_version": 1, "id": "1", "method": "golden_rm", "params": {"golden": "g"}}"#.utf8))
        XCTAssertEqual(remove.params, .templateRemove(TemplateRemoveParams(template: "g")))
        XCTAssertTrue(remove.usesLegacyTemplateNames)
        let current = try JSONDecoder().decode(
            Request.self,
            from: Data(#"{"schema_version": 1, "id": "1", "method": "template_rm", "params": {"template": "g"}}"#.utf8))
        XCTAssertEqual(current.params, remove.params)
        XCTAssertFalse(current.usesLegacyTemplateNames)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                Request.self, from: Data(#"{"schema_version": 1, "id": "1", "method": "silver_rm"}"#.utf8)))
    }

    /// An older daemon's answers (`golden` result kind, `goldens`, `golden_hint`) still decode.
    func testAnswersFromAnOlderDaemonDecode() throws {
        let response = try JSONDecoder().decode(
            Response.self,
            from: Data(
                #"""
                {"schema_version": 1, "id": "1", "type": "result", "result_kind": "golden",
                 "result": {"outcome": "listed", "goldens": []}}
                """#.utf8))
        XCTAssertEqual(response.body, .result(.template(TemplateResult(outcome: "listed", templates: []))))

        let daemon = try TestDaemon(config: try config())
        defer { daemon.destroy() }
        guard case .status(var status) = try daemon.result(.status) else { return XCTFail("no status") }
        status.templateHint = "no template yet, run simq template build"
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        XCTAssertEqual(object["template_hint"] as? String, status.templateHint)
        XCTAssertEqual(object["golden_hint"] as? String, status.templateHint, "the old field is still sent")
        object["template_hint"] = nil
        let old = try JSONDecoder().decode(StatusResult.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.templateHint, status.templateHint)
    }
}
