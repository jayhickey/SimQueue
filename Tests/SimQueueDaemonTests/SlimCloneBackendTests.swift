// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueHost
import SimQueueSim
import XCTest

/// Real backend decisions with fake executables only; no SDK or simulator is touched.
final class SlimCloneBackendTests: XCTestCase {
    private static let source = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    private static let target = "8C1F2B9E-3D4A-4F5B-9C6D-7E8F9A0B1C2D"
    private static let other = "99999999-8888-4777-8666-555555555555"
    private static let foreign = "11111111-2222-4333-8444-555555555555"
    private static let sourceName = "simq-template-demo-slim-7"
    private static let targetName = "simq-pool-1-42"

    private var slimPlan: SimClonePlan {
        SimClonePlan(
            source: Self.source, sourceRef: TemplateRef(udid: Self.source, name: Self.sourceName), method: .simslim)
    }

    private func fixture() throws -> (FakeToolHarness, SimctlBackend) {
        let tools = try FakeToolHarness()
        addTeardownBlock { tools.cleanUp() }
        try tools.respond("simslim---version", out: "simslim 0.12.2\n")
        try tools.respond("simslim---help", out: RealBackendFakeToolTests.simslimHelp)
        try tools.respond("xcrun-list", out: listing())
        let backend = try SimctlBackend(
            template: Self.source, runner: ToolRunner(environment: tools.toolEnvironment, killGraceSeconds: 0.1))
        return (tools, backend)
    }

    private func listing(
        sourceState: String = "Shutdown", targetState: String? = nil, targetID: String = SlimCloneBackendTests.target,
        duplicateTarget: Bool = false
    ) throws -> String {
        var devices = [
            ["udid": Self.source, "name": Self.sourceName, "state": sourceState],
            ["udid": Self.foreign, "name": "Unrelated iPhone", "state": "Booted"],
        ]
        if let targetState {
            devices.append(["udid": targetID, "name": Self.targetName, "state": targetState])
        }
        if duplicateTarget {
            devices.append(["udid": Self.other, "name": Self.targetName, "state": "Shutdown"])
        }
        return String(
            decoding: try JSONSerialization.data(withJSONObject: ["devices": ["runtime": devices]]), as: UTF8.self)
    }

    private func cloneJSON(
        udid: String = SlimCloneBackendTests.target, source: String = SlimCloneBackendTests.source,
        name: String = SlimCloneBackendTests.targetName
    ) throws -> String {
        // sourceUdid deliberately appears after udid: selecting the last UUID is wrong.
        "{\"action\":\"clone\",\"udid\":\"\(udid)\",\"name\":\"\(name)\",\"sourceUdid\":\"\(source)\"}"
    }

    private func assertNoMutation(_ tools: FakeToolHarness, file: StaticString = #filePath, line: UInt = #line) throws {
        let calls = try tools.loggedCalls()
        XCTAssertFalse(
            calls.contains {
                $0.hasPrefix("simslim clone ") || $0.hasPrefix("xcrun simctl clone ")
                    || $0.hasPrefix("xcrun simctl delete ") || $0.hasPrefix("xcrun simctl shutdown ")
                    || $0.hasPrefix("xcrun simctl boot ")
            }, "\(calls)", file: file, line: line)
    }

    /// The stand-ins change only their recorded inventory after an exact SDK mutation.
    private func installCleanupInventoryTransitions(_ tools: FakeToolHarness) throws {
        let hook = """
            action=" $* "
            if [[ "${2:-}" == "delete" && "${3:-}" == "\(Self.target)" ]]; then
              cp "$FAKE_TOOL_STATE/after-delete.json" "$FAKE_TOOL_STATE/xcrun-list.out"
            fi
            if [[ "${2:-}" == "shutdown" && "${3:-}" == "\(Self.source)" ]]; then
              cp "$FAKE_TOOL_STATE/after-shutdown.json" "$FAKE_TOOL_STATE/xcrun-list.out"
            fi
            """
        try FakeToolHarness.script(for: "xcrun").replacingOccurrences(of: "action=\" $* \"", with: hook)
            .write(to: tools.binDirectory.appendingPathComponent("xcrun"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tools.binDirectory.appendingPathComponent("xcrun").path)
        try listing(sourceState: "Booted").write(
            to: tools.stateDirectory.appendingPathComponent("after-delete.json"), atomically: true, encoding: .utf8)
        try listing().write(
            to: tools.stateDirectory.appendingPathComponent("after-shutdown.json"), atomically: true, encoding: .utf8)
    }

    func testStockCloneNeverProbesOrInvokesMissingSimslim() throws {
        let (tools, backend) = try fixture()
        try tools.respond("simslim---version", err: "missing", status: 127)
        try tools.respond("simslim---help", err: "missing", status: 127)
        let prepared = try backend.prepareClone(
            name: Self.targetName, plan: SimClonePlan(source: Self.source, method: .simctl))
        try tools.respond("xcrun-clone", out: Self.target)
        try tools.respond("xcrun-list", out: listing(targetState: "Shutdown"))
        XCTAssertEqual(try backend.createPreparedDevice(prepared).udid, Self.target)
        let calls = try tools.loggedCalls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("simslim ") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("xcrun simctl boot ") || $0.hasPrefix("xcrun simctl shutdown ") })
        XCTAssertTrue(calls.contains("xcrun simctl clone \(Self.source) \(Self.targetName)"))
    }

    func testSlimCloneUsesStructuredTargetAndPreservesExactSource() throws {
        let (tools, backend) = try fixture()
        let prepared = try backend.prepareClone(name: Self.targetName, plan: slimPlan)
        XCTAssertTrue(prepared.sourceWasShutdown)
        XCTAssertTrue(prepared.previousUDIDs.contains(Self.source))
        try tools.respond("simslim-clone", out: cloneJSON())
        try tools.respond("xcrun-list", out: listing(targetState: "Shutdown"))
        let clone = try backend.createPreparedDevice(prepared)
        XCTAssertEqual(clone.udid, Self.target)
        XCTAssertEqual(clone.state, "Shutdown")
        let calls = try tools.loggedCalls()
        XCTAssertTrue(calls.contains("simslim clone \(Self.source) \(Self.targetName) --json"))
        XCTAssertFalse(calls.contains { $0.hasPrefix("xcrun simctl clone ") })
    }

    func testSlimPreflightRequiresExactShutdownRatherThanNotBooted() throws {
        for state in ["Booted", "Booting", "ShuttingDown", "Creating", "Unknown"] {
            let (tools, backend) = try fixture()
            try tools.respond("xcrun-list", out: listing(sourceState: state))
            XCTAssertThrowsError(try backend.prepareClone(name: Self.targetName, plan: slimPlan), state)
            try assertNoMutation(tools)
        }
    }

    func testMissingCapabilityAndPreexistingTargetRefuseBeforeMutation() throws {
        let (missing, unsupported) = try fixture()
        try missing.respond("simslim---help", out: "  on <udid>  Slim a simulator\n")
        XCTAssertThrowsError(try unsupported.prepareClone(name: Self.targetName, plan: slimPlan))
        try assertNoMutation(missing)

        let (tools, backend) = try fixture()
        try tools.respond("xcrun-list", out: listing(targetState: "Shutdown"))
        XCTAssertThrowsError(try backend.prepareClone(name: Self.targetName, plan: slimPlan))
        XCTAssertTrue(try backend.listDevices().contains { $0.udid == Self.target })
        try assertNoMutation(tools)
    }

    func testMalformedJSONUUIDAndWrongSourceCannotAdoptListedClone() throws {
        let outputs = try [
            "not JSON", "{}", cloneJSON(udid: ""), cloneJSON(udid: "prefix-\(Self.target)"),
            cloneJSON(source: Self.foreign), cloneJSON(name: "simq-pool-2-43"),
        ]
        for output in outputs {
            let (tools, backend) = try fixture()
            let prepared = try backend.prepareClone(name: Self.targetName, plan: slimPlan)
            try tools.respond("simslim-clone", out: output)
            try tools.respond("xcrun-list", out: listing(targetState: "Shutdown"))
            XCTAssertThrowsError(try backend.createPreparedDevice(prepared), output)
            XCTAssertFalse(try tools.loggedCalls().contains { $0.hasPrefix("xcrun simctl delete ") })
        }
    }

    func testReportedCloneMustBeNewAndMatchFreshInventory() throws {
        for reported in [Self.source, Self.foreign, Self.other] {
            let (tools, backend) = try fixture()
            let prepared = try backend.prepareClone(name: Self.targetName, plan: slimPlan)
            try tools.respond("simslim-clone", out: cloneJSON(udid: reported))
            try tools.respond("xcrun-list", out: listing(targetState: "Shutdown"))
            XCTAssertThrowsError(try backend.createPreparedDevice(prepared), reported)
        }
    }

    func testSlimSuccessRequiresBothSourceAndCloneExactlyShutdown() throws {
        for state in ["Booted", "Booting", "ShuttingDown"] {
            for sourceChanged in [false, true] {
                let (tools, backend) = try fixture()
                let prepared = try backend.prepareClone(name: Self.targetName, plan: slimPlan)
                try tools.respond("simslim-clone", out: cloneJSON())
                try tools.respond(
                    "xcrun-list",
                    out: listing(
                        sourceState: sourceChanged ? state : "Shutdown", targetState: sourceChanged ? "Shutdown" : state
                    ))
                XCTAssertThrowsError(
                    try backend.createPreparedDevice(prepared), "sourceChanged=\(sourceChanged), \(state)")
            }
        }
    }

    func testFailedHelperDoesNotAdoptPartialTargetAndCleanupIsScoped() throws {
        let (tools, backend) = try fixture()
        let prepared = try backend.prepareClone(name: Self.targetName, plan: slimPlan)
        try tools.respond("simslim-clone", err: "source state restore failed", status: 1)
        try tools.respond("xcrun-list", out: listing(sourceState: "Booted", targetState: "Booted"))
        XCTAssertThrowsError(try backend.createPreparedDevice(prepared))
        XCTAssertTrue(try backend.listDevices().contains { $0.udid == Self.target })
        try installCleanupInventoryTransitions(tools)
        try backend.cleanUpInterruptedClone(prepared)
        let remaining = try backend.listDevices()
        XCTAssertFalse(remaining.contains { $0.udid == Self.target })
        XCTAssertEqual(remaining.first { $0.udid == Self.source }?.state, "Shutdown")
        XCTAssertEqual(remaining.first { $0.udid == Self.foreign }?.state, "Booted")
        let calls = try tools.loggedCalls()
        XCTAssertEqual(calls.filter { $0 == "xcrun simctl delete \(Self.target)" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "xcrun simctl shutdown \(Self.source)" }.count, 1)
        XCTAssertFalse(
            calls.contains {
                $0 == "xcrun simctl delete \(Self.foreign)" || $0 == "xcrun simctl shutdown \(Self.foreign)"
            })
    }

    func testInterruptedCleanupRefusesPreviousOrAmbiguousTargetIdentities() throws {
        for ambiguous in [false, true] {
            let (tools, backend) = try fixture()
            var prepared = try backend.prepareClone(name: Self.targetName, plan: slimPlan)
            if !ambiguous { prepared.previousUDIDs.insert(Self.target) }
            try tools.respond("xcrun-list", out: listing(targetState: "Shutdown", duplicateTarget: ambiguous))
            XCTAssertThrowsError(try backend.cleanUpInterruptedClone(prepared))
            XCTAssertTrue(try backend.listDevices().contains { $0.udid == Self.target })
            try assertNoMutation(tools)
        }
        let (tools, backend) = try fixture()
        var prepared = try backend.prepareClone(name: Self.targetName, plan: slimPlan)
        prepared.expectedTargetUDID = Self.target
        let renamed = try listing(targetState: "Shutdown").replacingOccurrences(
            of: Self.targetName, with: "simq-pool-renamed-42")
        try tools.respond("xcrun-list", out: renamed)
        XCTAssertThrowsError(try backend.cleanUpInterruptedClone(prepared), "a renamed target is still present by UUID")
        XCTAssertTrue(try backend.listDevices().contains { $0.udid == Self.target })
        try assertNoMutation(tools)
    }

    func testSourceOnlyBootResidueRequiresProofAndIsRestoredWithoutTargetDeletion() throws {
        let (tools, backend) = try fixture()
        var prepared = try backend.prepareClone(name: Self.targetName, plan: slimPlan)
        try tools.respond("xcrun-list", out: listing(sourceState: "Booted"))
        prepared.sourceWasShutdown = false
        XCTAssertThrowsError(try backend.cleanUpInterruptedClone(prepared))
        try assertNoMutation(tools)
        prepared.sourceWasShutdown = true
        try installCleanupInventoryTransitions(tools)
        try backend.cleanUpInterruptedClone(prepared)
        XCTAssertEqual(try backend.listDevices().first { $0.udid == Self.source }?.state, "Shutdown")
        let calls = try tools.loggedCalls()
        XCTAssertTrue(calls.contains("xcrun simctl shutdown \(Self.source)"))
        XCTAssertFalse(calls.contains { $0.hasPrefix("xcrun simctl delete ") })
    }
}
