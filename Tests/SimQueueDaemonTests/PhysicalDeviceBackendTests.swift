// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueProtocol
import XCTest

final class PhysicalDeviceBackendTests: XCTestCase {
    private func fakeTools() throws -> (URL, [String: String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "simq-device-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = #"""
            #!/bin/sh
            printf '%s\n' "$*" >> "$CALLS"
            if [ "$1" = devicectl ]; then
              case "$*" in
                *"info details"*)
                  if [ "$SCENARIO" = offline ]; then echo 'fake device unavailable' >&2; exit 1; fi
                  paired=paired; mode=enabled; tunnel=connected
                  [ "$SCENARIO" = unpaired ] && paired=unpaired
                  [ "$SCENARIO" = developer ] && mode=disabled
                  [ "$SCENARIO" = cached ] && tunnel=disconnected
                  while [ "$1" != --json-output ]; do shift; done; shift
                  if [ "$SCENARIO" = modern ]; then
                    printf '{"result":{"properties":{"connection":{"pairingState":"paired","state":"connected"},"state":{"developerModeStatus":{"enabled":{"mode":1}}}}}}' > "$1"
                    exit 0
                  fi
                  printf '{"result":{"device":{"connectionProperties":{"pairingState":"%s","tunnelState":"%s"},"deviceProperties":{"developerModeStatus":"%s","thermalState":"nominal"}}}}' "$paired" "$tunnel" "$mode" > "$1"
                  ;;
                *"info lockState"*)
                  locked=false
                  [ "$SCENARIO" = locked ] && locked=true
                  while [ "$1" != --json-output ]; do shift; done; shift
                  if [ "$SCENARIO" = modern ]; then
                    printf '{"result":{"isPasscodeRequired":false,"hasBeenUnlockedSinceBoot":true}}' > "$1"
                  elif [ "$SCENARIO" = unknown-lock ]; then
                    printf '{"result":{"hasBeenUnlockedSinceBoot":true}}' > "$1"
                  else
                    printf '{"result":{"isLocked":%s}}' "$locked" > "$1"
                  fi
                  ;;
                *"copy from"*)
                  [ "$SCENARIO" = copy-failure ] && exit 1
                  while [ "$1" != --destination ]; do shift; done; shift
                  mkdir -p "$1"
                  printf 'fake private artifact' > "$1/result.txt"
                  ;;
              esac
            else
              printf 'fake xcodebuild\n'
              exit "${BUILD_EXIT:-0}"
            fi
            exit 0
            """#
        for name in ["xcrun", "xcodebuild"] {
            let path = root.appendingPathComponent(name)
            try script.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        return (root, ["PATH": root.path + ":/usr/bin:/bin", "CALLS": root.appendingPathComponent("calls").path])
    }

    func testFakeDevicectlHealthAndErrors() throws {
        let (_, environment) = try fakeTools()
        for (scenario, state) in [
            ("ready", "ready"), ("modern", "ready"), ("unknown-lock", "device_unavailable"),
            ("locked", "device_locked"), ("offline", "device_unavailable"),
            ("unpaired", "device_unpaired"), ("developer", "developer_mode_disabled"), ("cached", "device_unavailable"),
        ] {
            var env = environment; env["SCENARIO"] = scenario
            let health = Devicectl(runner: ToolRunner(environment: env)).health(udid: "FAKE-PHONE")
            XCTAssertEqual(health.state, state, scenario + ": " + health.detail)
            if scenario == "offline" { XCTAssertTrue(health.detail.contains("fake device unavailable")) }
            if scenario == "ready" { XCTAssertEqual(health.thermal, "nominal") }
        }
        let calls = try String(contentsOfFile: environment["CALLS"]!, encoding: .utf8)
        XCTAssertFalse(calls.contains("install"))
        XCTAssertFalse(calls.contains("launch"))
    }

    func testConfigParsingDefaultsAndInvalidDuplicates() throws {
        XCTAssertTrue(try DaemonConfig.parse(Data("{}".utf8)).devices.isEmpty)
        let config = try DaemonConfig.parse(
            Data(
                #"{"devices":[{"udid":"FAKE-PHONE","name":"Phone","labels":["device:test","physical","ios27"]}]}"#.utf8)
        )
        XCTAssertEqual(config.devices.first?.enabled, true)
        XCTAssertTrue(config.devices[0].matches("ios27"))
        for body in [
            #"{"devices":[{"udid":"A","name":"Phone"},{"udid":"A","name":"Other"}]}"#,
            #"{"devices":[{"udid":"","name":"Phone"}]}"#,
            #"{"devices":[{"udid":"A","name":"Phone","labels":[" "]}]}"#,
        ] { XCTAssertThrowsError(try DaemonConfig.parse(Data(body.utf8))) }
        let disabled = PhysicalDevice(udid: "A", name: "disabled", labels: ["physical"], enabled: false)
        XCTAssertFalse(disabled.matches("physical"))
    }

    func testDestinationProvisioningAndLaunchArguments() {
        var command = JobCommand(argv: ["xcodebuild", "test", "-allowProvisioningUpdates", "-destination", "id=wrong"])
        command.physicalUDID = "FAKE-PHONE"
        XCTAssertEqual(
            command.executionArgv, ["xcodebuild", "test", "-allowProvisioningUpdates", "-destination", "id=FAKE-PHONE"])
        command.argv = ["xcrun", "devicectl", "device", "process", "launch", "app.bundle", "--", "--input", "a b"]
        XCTAssertEqual(
            command.executionArgv,
            [
                "xcrun", "devicectl", "device", "process", "launch", "app.bundle", "--device", "FAKE-PHONE",
                "--terminate-existing", "--", "--input", "a b",
            ])
        command.argv = ["xcrun", "devicectl", "device", "install", "app", "app path.app"]
        XCTAssertEqual(Array(command.executionArgv.suffix(2)), ["--device", "FAKE-PHONE"])
        command.argv = ["xcrun", "devicectl", "device", "info", "processes"]
        XCTAssertEqual(Array(command.executionArgv.suffix(2)), ["--device", "FAKE-PHONE"])
    }

    func testPhysicalExecutionAndArtifactCopyUseOnlyFakeTools() throws {
        let (_, environment) = try fakeTools()
        var config = DaemonConfig()
        config.devices = [PhysicalDevice(udid: "FAKE-PHONE", name: "Phone", labels: ["physical"])]
        let daemon = try TestDaemon(
            config: config, deviceHealth: { _ in DeviceHealth(state: "ready") }, realProcesses: true)
        defer { daemon.destroy() }
        var params = SubmitParams(
            project: "demo", submitter: "test", command: ["xcodebuild", "test", "-allowProvisioningUpdates"],
            environment: environment)
        params.device = "physical"
        params.deviceArtifact = DeviceArtifact(bundle: "example.app", path: "Library/Caches/EncoderANEBenchmark")
        let info = try daemon.wait(daemon.submit(params).job.id)
        XCTAssertEqual(info.state, .succeeded, info.message ?? "")
        XCTAssertEqual(info.physicalUDID, "FAKE-PHONE")
        let dir = try XCTUnwrap(info.runDir)
        XCTAssertEqual(
            try String(contentsOfFile: dir + "/device-artifacts/result.txt", encoding: .utf8), "fake private artifact")
        let calls = try String(contentsOfFile: environment["CALLS"]!, encoding: .utf8)
        XCTAssertTrue(calls.contains("test -allowProvisioningUpdates -destination id=FAKE-PHONE"), calls)
        XCTAssertTrue(
            calls.contains(
                "--domain-type appDataContainer --domain-identifier example.app --source Library/Caches/EncoderANEBenchmark --destination "
                    + dir + "/device-artifacts"), calls)
        XCTAssertFalse(calls.contains("simctl"))
    }

    func testArtifactFailureAndOriginalCommandStatus() throws {
        let (_, environment) = try fakeTools()
        var config = DaemonConfig()
        config.devices = [PhysicalDevice(udid: "FAKE-PHONE", name: "Phone")]
        let daemon = try TestDaemon(
            config: config, deviceHealth: { _ in DeviceHealth(state: "ready") }, realProcesses: true)
        defer { daemon.destroy() }
        for (scenario, code, expected) in [
            ("copy-failure", "0", ResultClass.artifactFailure), ("ready", "74", .commandFailure),
        ] {
            var env = environment; env["SCENARIO"] = scenario; env["BUILD_EXIT"] = code
            var params = SubmitParams(
                project: "demo", submitter: "test", command: ["xcodebuild", "build"], environment: env)
            params.device = "FAKE-PHONE"
            params.deviceArtifact = DeviceArtifact(bundle: "example.app", path: "Library/Caches")
            let info = try daemon.wait(daemon.submit(params).job.id)
            XCTAssertEqual(info.resultClass, expected, info.message ?? "")
            XCTAssertEqual(info.commandExitCode, Int32(code))
        }
    }

    func testUnsafeArtifactsAndSimulatorOptionsAreRejected() throws {
        var command = JobCommand(argv: ["true"])
        command.device = "physical"
        for path in ["../private", "/private", "Library/../../private", "."] {
            command.deviceArtifact = DeviceArtifact(bundle: "example.app", path: path)
            XCTAssertNotNil(command.validationError)
        }
        command.deviceArtifact = nil
        command.freshSim = true
        XCTAssertNotNil(command.validationError)
    }
    func testCLIPhysicalSelectionDevicesAndValidation() throws {
        let products: URL
        #if os(macOS)
            products =
                Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }?.bundleURL.deletingLastPathComponent()
                ?? Bundle.main.bundleURL
        #else
            products = Bundle.main.bundleURL
        #endif
        let executable = products.appendingPathComponent("simq").path
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("simq not built") }
        var config = DaemonConfig()
        config.devices = [PhysicalDevice(udid: "FAKE-PHONE", name: "Phone", labels: ["device:test"])]
        let daemon = try TestDaemon(
            config: config, deviceHealth: { _ in DeviceHealth(state: "ready") }, realProcesses: true)
        defer { daemon.destroy() }
        let runner = ToolRunner(environment: [
            "PATH": "/usr/bin:/bin", "SIMQ_NO_AUTOSTART": "1", "SIMQ_RECONNECT_SECONDS": "0",
        ])
        let output = try runner.check(
            executable,
            [
                "run", "--state-dir", daemon.paths.stateDir, "--device", "device:test", "--", "/bin/sh", "-c",
                "echo udid=$SIMQ_UDID type=$SIMQ_RESOURCE_TYPE sims=$SIMQ_SIMS",
            ], timeoutSeconds: 10)
        XCTAssertTrue(output.contains("udid=FAKE-PHONE type=physical sims=0"), output)
        let devices = try runner.check(
            executable, ["devices", "--state-dir", daemon.paths.stateDir, "--json"], timeoutSeconds: 10)
        let parsed = try JSONDecoder().decode([PhysicalDeviceInfo].self, from: Data(devices.utf8))
        XCTAssertEqual(parsed.first?.device.udid, "FAKE-PHONE")
        XCTAssertEqual(parsed.first?.health.state, "ready")
        var invalid = SubmitParams(project: "demo", submitter: "test", minSims: 1, command: ["true"])
        invalid.device = "device:test"
        XCTAssertEqual(try daemon.protocolError(.submit(invalid)).code, .invalidArgument)
        invalid.minSims = 0
        invalid.freshSim = true
        XCTAssertEqual(try daemon.protocolError(.submit(invalid)).code, .invalidArgument)
    }

}
