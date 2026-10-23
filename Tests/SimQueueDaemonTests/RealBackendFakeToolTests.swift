// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueHost
import SimQueueSim
import XCTest

/// The real macOS backends (simctl/simslim sims, host probe, process probe) driven
/// through FakeToolHarness's fake tools with recorded macOS output. No real tool is run.
final class RealBackendFakeToolTests: XCTestCase {
    static let owned = "8C1F2B9E-3D4A-4F5B-9C6D-7E8F9A0B1C2D"
    static let foreign = "11111111-2222-4333-8444-555555555555"
    static let template = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"

    /// Shape of `xcrun simctl list -j devices` (Xcode 16/26), trimmed.
    static func listing(ownedState: String? = "Shutdown") -> String {
        var devices = [
            #"{"udid": "\#(foreign)", "name": "iPhone 16", "state": "Booted", "isAvailable": true}"#,
            #"{"udid": "\#(template)", "name": "simq-template-demo-slim", "state": "Shutdown", "isAvailable": true}"#,
        ]
        if let ownedState {
            devices.append(
                #"{"udid": "\#(owned)", "name": "simq-pool-1-42", "state": "\#(ownedState)", "isAvailable": true}"#)
        }
        return #"{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-2": [\#(devices.joined(separator: ","))]}}"#
    }

    private func setUp() throws -> (FakeToolHarness, SimctlBackend) {
        let harness = try FakeToolHarness()
        addTeardownBlock { harness.cleanUp() }
        var timeouts = SimctlBackend.Timeouts()
        timeouts.bootStatus = 0.5
        let backend = try SimctlBackend(
            template: "simq-template-demo-slim",
            runner: ToolRunner(environment: harness.toolEnvironment, killGraceSeconds: 0.5),
            timeouts: timeouts)
        return (harness, backend)
    }

    /// Building the real backend runs no tool (the daemon builds one by default on macOS).
    func testBuildingTheBackendRunsNoTool() throws {
        let (harness, _) = try setUp()
        XCTAssertEqual(try harness.loggedCalls(), [])
    }

    func testListParsesSimctlJSON() throws {
        let (harness, backend) = try setUp()
        try harness.respond("xcrun-list", out: Self.listing(ownedState: "Booted"))
        let devices = try backend.listDevices()
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices.first { $0.udid == Self.owned }?.isBooted, true)
        XCTAssertEqual(try backend.poolSnapshot().idleRunning, 1, "only booted sims in the namespace")
        try harness.respond("xcrun-list", out: "not json")
        XCTAssertThrowsError(try backend.listDevices())
    }

    /// Sim prep (`fresh_sim`, `reset_apps`) runs these simctl commands, on owned sims only.
    func testSimPrepRunsSimctlOnOwnedSimsOnly() throws {
        let (harness, backend) = try setUp()
        try harness.respond("xcrun-list", out: Self.listing(ownedState: "Booted"))
        try backend.uninstallApp(udid: Self.owned, bundleID: "com.example.app")
        try backend.resetAppPrivacy(udid: Self.owned, bundleID: "com.example.app")
        try backend.resetKeychain(udid: Self.owned)
        try backend.eraseDevice(udid: Self.owned)
        let calls = try harness.loggedCalls()
        for expected in [
            "xcrun simctl uninstall \(Self.owned) com.example.app",
            "xcrun simctl privacy \(Self.owned) reset all com.example.app",
            "xcrun simctl keychain \(Self.owned) reset", "xcrun simctl erase \(Self.owned)",
        ] {
            XCTAssertTrue(calls.contains(expected), "\(expected) in \(calls)")
        }
        for udid in [Self.foreign, Self.template] {
            XCTAssertThrowsError(try backend.eraseDevice(udid: udid), "never a foreign or template sim")
            XCTAssertThrowsError(try backend.uninstallApp(udid: udid, bundleID: "com.example.app"))
        }
        XCTAssertThrowsError(try backend.uninstallApp(udid: Self.owned, bundleID: "-rf"), "bundle ids are checked")
        try harness.respond("xcrun-uninstall", err: "uninstall failed", status: 1)
        XCTAssertThrowsError(try backend.uninstallApp(udid: Self.owned, bundleID: "com.example.app"))
    }

    func testSimctlClonesAndConfirmsWithoutRequiringSimslim() throws {
        let (harness, backend) = try setUp()
        try harness.respond("simslim---version", out: "simslim 0.4.1\n")
        try harness.respond("simslim---help", out: "Usage: simslim <command>\n  clone   clone a template\n  measure\n")
        try harness.respond("xcrun-clone", out: "cloned to \(Self.owned)\n")
        try harness.respond("xcrun-list", out: Self.listing(ownedState: nil), next: Self.listing())
        let device = try backend.createDevice(name: "simq-pool-1-42")
        XCTAssertEqual(device.udid, Self.owned)
        XCTAssertFalse(backend.createBoots)
        XCTAssertFalse(try harness.loggedCalls().contains { $0.hasPrefix("simslim ") })
        XCTAssertTrue(try harness.loggedCalls().contains("xcrun simctl clone simq-template-demo-slim simq-pool-1-42"))
        XCTAssertThrowsError(try backend.createDevice(name: "iPhone 17")) {
            XCTAssertEqual($0 as? SimctlBackendError, .outsideNamespace("iPhone 17"))
        }
        XCTAssertThrowsError(try backend.createDevice(name: "simq-pool-2-43"), "clone returned but not listed") {
            XCTAssertEqual($0 as? SimctlBackendError, .createNotConfirmed("simq-pool-2-43"))
        }
    }

    /// #43: a reported UDID that isn't listed is never swapped for another sim with the name.
    func testCreateNeverFallsBackToALookalikeByName() throws {
        let (harness, backend) = try setUp()
        try harness.respond("simslim---version", out: "simslim 0.4.1\n")
        try harness.respond("simslim---help", out: "Usage: simslim <command>\n  clone   clone a template\n")
        let reported = "99999999-8888-4777-8666-555555555555"
        try harness.respond("xcrun-clone", out: "cloned to \(reported)\n")
        try harness.respond("xcrun-list", out: Self.listing(ownedState: nil), next: Self.listing())
        XCTAssertThrowsError(try backend.createDevice(name: "simq-pool-1-42")) {
            XCTAssertEqual($0 as? SimctlBackendError, .createNotConfirmed("simq-pool-1-42"))
        }
        // No UDID in the output: two sims with the name is ambiguous, so it's refused too.
        try harness.respond("xcrun-clone", out: "done\n")
        let twin = #"{"udid": "\#(reported)", "name": "simq-pool-1-42", "state": "Shutdown", "isAvailable": true}"#
        try harness.respond(
            "xcrun-list",
            out: Self.listing(ownedState: nil),
            next: Self.listing().replacingOccurrences(
                of: #""iPhone 16", "state": "Booted", "isAvailable": true}"#,
                with: #""iPhone 16", "state": "Booted", "isAvailable": true}, \#(twin)"#))
        XCTAssertThrowsError(try backend.createDevice(name: "simq-pool-1-42")) {
            XCTAssertEqual($0 as? SimctlBackendError, .createNotConfirmed("simq-pool-1-42"))
        }
        // No UDID and exactly one sim with the name: confirmed.
        try harness.respond("xcrun-list", out: Self.listing(ownedState: nil), next: Self.listing())
        XCTAssertEqual(try backend.createDevice(name: "simq-pool-1-42").udid, Self.owned)
    }

    func testCloneNeverAdoptsAnExistingSimulatorWithTheRequestedName() throws {
        let (harness, backend) = try setUp()
        // Both a reported UDID and name-only output must represent a new simulator,
        // not a device that was present before this clone attempt.
        for output in ["cloned to \(Self.owned)\n", "done\n"] {
            try harness.respond("xcrun-clone", out: output)
            try harness.respond("xcrun-list", out: Self.listing(), next: Self.listing())
            XCTAssertThrowsError(try backend.createDevice(name: "simq-pool-1-42")) {
                XCTAssertEqual($0 as? SimctlBackendError, .createNotConfirmed("simq-pool-1-42"))
            }
        }
    }

    /// `simslim --help` (0.12.x), trimmed to the lines the backend looks at.
    static let simslimHelp = """
        USAGE
          simslim <command> [args]
        COMMANDS
          list                 List available simulators and their slim status
          on <udid>            Slim a simulator (persist disables + reboot slim)
              --preserve-boot-state
                               Return an initially shutdown simulator to shutdown
          clone <udid> <name>  Clone apps, data, settings, and the service profile

        """

    func testTemplateCreateIsConfirmedAndOnlyForTemplateNames() throws {
        let (harness, backend) = try setUp()
        try harness.respond("xcrun-create", out: "\(Self.template)\n")
        try harness.respond("xcrun-list", out: Self.listing())
        let device = try backend.createBaseDevice(
            name: "simq-template-demo-slim", deviceType: "iPhone-16", runtime: "iOS-18-2")
        XCTAssertEqual(device.udid, Self.template)
        XCTAssertTrue(
            try harness.loggedCalls().contains("xcrun simctl create simq-template-demo-slim iPhone-16 iOS-18-2"))
        XCTAssertThrowsError(try backend.createBaseDevice(name: "simq-pool-1-1", deviceType: "d", runtime: "r")) {
            XCTAssertEqual($0 as? SimctlBackendError, .outsideNamespace("simq-pool-1-1"), "template names only")
        }
        XCTAssertThrowsError(try backend.createBaseDevice(name: "simq-template-x-y-9", deviceType: "d", runtime: "r")) {
            XCTAssertEqual($0 as? SimctlBackendError, .createNotConfirmed("simq-template-x-y-9"), "not listed after")
        }
    }

    func testTemplateSlimUsesSimslimOnWhenInstalled() throws {
        let (harness, backend) = try setUp()
        try harness.respond("simslim---help", out: Self.simslimHelp)
        try harness.respond("xcrun-list", out: Self.listing())
        XCTAssertTrue(backend.slimSupported)
        try backend.slim(udid: Self.template, arguments: ["--except", "search"])
        let calls = try harness.loggedCalls()
        XCTAssertTrue(calls.contains("simslim on \(Self.template) --preserve-boot-state --except search"), "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("xcrun simctl boot") }, "simslim does the boot")
        XCTAssertFalse(calls.contains { $0.hasPrefix("xcrun simctl shutdown") }, "already shut down")
    }

    func testWithoutASimslimThatCanSlimTemplatesAreNotSupported() throws {
        let (harness, backend) = try setUp()
        try harness.respond("simslim---help", err: "simslim: command not found\n", status: 127)
        try harness.respond("xcrun-list", out: Self.listing())
        XCTAssertFalse(backend.slimSupported, "no stock templates: they make clone boots a load spike")
        XCTAssertThrowsError(try backend.slim(udid: Self.template, arguments: []))
        let (other, older) = try setUp()
        try other.respond("simslim---help", out: "Usage: simslim clone <udid> <name>\n")
        XCTAssertFalse(older.slimSupported, "a simslim without `on` can't slim")
        XCTAssertFalse(try harness.loggedCalls().contains { $0.contains("simctl boot") || $0.hasPrefix("simslim on") })
    }

    /// A no isn't cached: installing simslim (or upgrading to one with `on`) after the
    /// daemon started is detected on the next check. A yes is cached.
    func testANoFromSimslimIsCheckedAgainSoALaterInstallIsDetected() throws {
        let (harness, backend) = try setUp()
        try harness.respond("simslim---help", err: "simslim: command not found\n", status: 127)
        XCTAssertFalse(backend.slimSupported)
        try harness.respond("simslim---help", out: "Usage: simslim clone <udid> <name>\n", err: "", status: 0)
        XCTAssertFalse(backend.slimSupported, "still no `on`")
        try harness.respond("simslim---help", out: Self.simslimHelp, err: "", status: 0)
        XCTAssertTrue(backend.slimSupported, "installed later: detected without a restart")
        try harness.respond("simslim---help", err: "simslim: command not found\n", status: 127)
        XCTAssertTrue(backend.slimSupported, "a yes is cached")
        try harness.respond("xcrun-list", out: Self.listing())
        try backend.slim(udid: Self.template, arguments: [])
        let calls = try harness.loggedCalls()
        XCTAssertEqual(calls.filter { $0 == "simslim --help" }.count, 3, "\(calls)")
        XCTAssertTrue(calls.contains("simslim on \(Self.template) --preserve-boot-state"), "\(calls)")
    }

    /// `listsOnCommand`: the 0.12.x table, then the fallback for other help layouts. Prose
    /// that starts with "on" and a simslim without `on` don't count.
    func testListsOnCommandFallbackLayouts() {
        XCTAssertTrue(SimctlBackend.listsOnCommand(Self.simslimHelp), "0.12.x table")
        let yes = [
            "Usage: simslim on <udid> [--preserve-boot-state]\n",
            "usage:\n  simslim on UDID\n",
            "COMMANDS\n\ton <udid>\tSlim a simulator\n",
            "COMMANDS\n  on [options] <udid>   Slim a simulator\n",
            "COMMANDS\n  on UDID   Slim a simulator\n",
            "SUBCOMMANDS:\n  list    List simulators\n  on      Slim a simulator\n",
            "SUBCOMMANDS:\n  on\tSlim a simulator\n",
        ]
        for help in yes { XCTAssertTrue(SimctlBackend.listsOnCommand(help), help) }
        let no = [
            "",
            "Usage: simslim clone <udid> <name>\n",
            "COMMANDS\n  clone <udid> <name>  Clone a simulator\n      on success, prints the new UDID\n",
            "on <udid> at the start of a line isn't a command table entry\n",
            "  On failure the simulator is shut down\n",
            "  off <udid>   Undo slimming\n",
            "  only <udid>  Slim one service\n",
            "  on   the next boot, settings apply\n",
        ]
        for help in no { XCTAssertFalse(SimctlBackend.listsOnCommand(help), help) }
    }

    func testAFailedSlimShutsTheTemplateDownAndReportsIt() throws {
        let (harness, backend) = try setUp()
        try harness.respond("simslim---help", out: Self.simslimHelp)
        try harness.respond("xcrun-list", out: Self.listing())
        try harness.respond("simslim-on", err: "boot timed out\n", status: 1)
        XCTAssertThrowsError(try backend.slim(udid: Self.template, arguments: []))
        XCTAssertTrue(try harness.loggedCalls().contains("xcrun simctl shutdown \(Self.template)"), "left shut down")
    }

    func testTemplateSlimRefusesPoolAndForeignSims() throws {
        let (harness, backend) = try setUp()
        try harness.respond("simslim---help", out: Self.simslimHelp)
        try harness.respond("xcrun-list", out: Self.listing())
        for udid in [Self.owned, Self.foreign] {
            XCTAssertThrowsError(try backend.slim(udid: udid, arguments: []), udid) {
                guard case .outsideNamespace = $0 as? SimctlBackendError else { return XCTFail("\($0)") }
            }
        }
        XCTAssertFalse(try harness.loggedCalls().contains { $0.hasPrefix("simslim on") || $0.contains("simctl boot") })
    }

    func testToolVersionsParse() throws {
        let versions = try SimctlBackend.parseToolVersions(
            xcode: "Xcode 26.0\nBuild version 17A000\n",
            runtimesJSON:
                #"{"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-0", "version": "26.0"}]}"#)
        XCTAssertEqual(versions.xcode, "Xcode 26.0 Build version 17A000")
        XCTAssertEqual(versions.runtimeVersion(for: "iOS-26-0"), "26.0")
        XCTAssertEqual(versions.runtimeVersion(for: "com.apple.CoreSimulator.SimRuntime.iOS-26-0"), "26.0")
        XCTAssertThrowsError(try SimctlBackend.parseToolVersions(xcode: "", runtimesJSON: "nope"))
    }

    /// #43's rule applies to template bases too: a reported UDID must be listed under the name.
    func testCreateBaseDeviceNeverFallsBackToALookalikeByName() throws {
        let (harness, backend) = try setUp()
        let name = "simq-template-demo-slim"
        try harness.respond("xcrun-create", out: "99999999-8888-4777-8666-555555555555\n")
        try harness.respond("xcrun-list", out: Self.listing())
        XCTAssertThrowsError(try backend.createBaseDevice(name: name, deviceType: "d", runtime: "r")) {
            XCTAssertEqual($0 as? SimctlBackendError, .createNotConfirmed(name))
        }
        try harness.respond("xcrun-create", out: "\(Self.template.lowercased())\n")
        XCTAssertEqual(try backend.createBaseDevice(name: name, deviceType: "d", runtime: "r").udid, Self.template)
    }

    func testCloneWorksWhenSimslimIsMissing() throws {
        let (harness, backend) = try setUp()
        try harness.respond("simslim---version", status: 127)
        try harness.respond("simslim---help", status: 127)
        try harness.respond("xcrun-clone", out: "\(Self.owned)\n")
        try harness.respond("xcrun-list", out: Self.listing(ownedState: nil), next: Self.listing())
        XCTAssertEqual(try backend.createDevice(name: "simq-pool-1-42").udid, Self.owned)
        XCTAssertFalse(try harness.loggedCalls().contains { $0.hasPrefix("simslim ") })
    }

    func testBootRunsBootThenBootstatusAndTimesOut() throws {
        let (harness, backend) = try setUp()
        try harness.respond("xcrun-list", out: Self.listing())
        try backend.bootDevice(udid: Self.owned)
        let calls = try harness.loggedCalls()
        XCTAssertTrue(calls.contains("xcrun simctl boot \(Self.owned)"))
        XCTAssertTrue(calls.contains("xcrun simctl bootstatus \(Self.owned) -b"))
        XCTAssertThrowsError(try backend.bootDevice(udid: Self.foreign), "never boots a foreign sim")

        try harness.respond("xcrun-bootstatus", sleep: 30)
        let started = Date()
        XCTAssertThrowsError(try backend.bootDevice(udid: Self.owned)) {
            guard case .timedOut = $0 as? ToolError else { return XCTFail("\($0)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "killed at the timeout")
    }

    func testShutdownToleratesAlreadyShutDown() throws {
        let (harness, backend) = try setUp()
        try harness.respond("xcrun-list", out: Self.listing())
        try harness.respond(
            "xcrun-shutdown", err: "Unable to shutdown device in current state: Shutdown\n", status: 149)
        XCTAssertNoThrow(try backend.shutdownDevice(udid: Self.owned))
    }

    func testDeleteIsConfirmedNeverAssumed() throws {
        let (harness, backend) = try setUp()
        // Gone from the next listing: success.
        try harness.respond("xcrun-list", out: Self.listing(), next: Self.listing(ownedState: nil))
        XCTAssertNoThrow(try backend.deleteDevice(udid: Self.owned))
        // Still listed after delete exits 0: not a success.
        try harness.respond("xcrun-list", out: Self.listing())
        XCTAssertThrowsError(try backend.deleteDevice(udid: Self.owned)) {
            XCTAssertEqual($0 as? SimctlBackendError, .deleteNotConfirmed(Self.owned))
        }
        // delete fails: throws.
        try harness.respond("xcrun-delete", err: "Invalid device\n", status: 164)
        XCTAssertThrowsError(try backend.deleteDevice(udid: Self.owned)) {
            guard case .failed = $0 as? ToolError else { return XCTFail("\($0)") }
        }
        // Foreign and template sims are refused before any delete call.
        let deletes = try harness.loggedCalls().filter { $0.hasPrefix("xcrun simctl delete") }.count
        XCTAssertThrowsError(try backend.deleteDevice(udid: Self.foreign))
        XCTAssertThrowsError(try backend.deleteDevice(udid: Self.template))
        XCTAssertEqual(try harness.loggedCalls().filter { $0.hasPrefix("xcrun simctl delete") }.count, deletes)
    }

    /// Recorded `vm_stat` output (macOS 15, 16 KB pages), trimmed.
    static let vmStat = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                               10000.
        Pages active:                            500000.
        Pages inactive:                           20000.
        Pages speculative:                         3000.
        Pages throttled:                              0.
        Pages wired down:                        150000.
        Pages purgeable:                           2000.
        """

    func testHostProbeParsesRecordedReadings() throws {
        let harness = try FakeToolHarness()
        defer { harness.cleanUp() }
        try harness.respond("vm_stat-", out: Self.vmStat)
        try harness.respond(
            "sysctl-vm.swapusage", out: "total = 2048.00M  used = 1024.50M  free = 1023.50M  (encrypted)\n")
        try harness.respond("sysctl-kern.memorystatus_vm_pressure_level", out: "2\n")
        let probe = SystemResourceProbe(runner: ToolRunner(environment: harness.toolEnvironment), diskPath: "/")
        let snapshot = try probe.sample(now: 100)
        XCTAssertEqual(snapshot.availableMemoryBytes, (10000 + 20000 + 3000 + 2000) * 16384)
        XCTAssertEqual(snapshot.swapUsedBytes, UInt64(1024.5 * 1024 * 1024))
        XCTAssertEqual(snapshot.memoryPressure, .warn)
        XCTAssertGreaterThan(snapshot.cpuCount, 0)
        XCTAssertGreaterThan(snapshot.freeDiskBytes, 0)
        XCTAssertGreaterThanOrEqual(snapshot.load1, 0)

        try harness.respond("sysctl-kern.memorystatus_vm_pressure_level", out: "garbage\n")
        XCTAssertThrowsError(try probe.sample(now: 101), "an unreadable reading throws; admission holds")
        try harness.respond("vm_stat-", sleep: 30)
        let slow = SystemResourceProbe(
            runner: ToolRunner(environment: harness.toolEnvironment, killGraceSeconds: 0.5), timeoutSeconds: 0.5)
        XCTAssertThrowsError(try slow.sample(now: 102)) {
            guard case .timedOut = $0 as? ToolError else { return XCTFail("\($0)") }
        }
    }

    func testProcessProbeFindsUnleasedUsersAndSimCPU() throws {
        let harness = try FakeToolHarness()
        defer { harness.cleanUp() }
        let devices = "/Users/x/Library/Developer/CoreSimulator/Devices/\(Self.owned)/data"
        try harness.respond(
            "ps--axo",
            out: """
                  101  12.5 \(devices)/../launchd_sim
                  102   3.0 \(devices)/Containers/SpringBoard
                  200  80.0 xcodebuild test -destination id=\(Self.owned)
                  201   1.0 /usr/bin/xcrun simctl io \(Self.owned) screenshot a.png
                  300   9.9 xcodebuild test -destination id=\(Self.foreign)
                junk line
                """)
        let lines = try SimProcessProbe(runner: ToolRunner(environment: harness.toolEnvironment)).processes()
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(SimProcessProbe.users(of: [Self.owned], in: lines), [Self.owned: [200, 201]])
        XCTAssertEqual(
            SimProcessProbe.users(of: [Self.owned], in: lines, exceptPIDs: [200, 201]), [:], "lease holders")
        XCTAssertEqual(SimProcessProbe.simCPUPercent(Self.owned, in: lines), 15.5, accuracy: 0.001)
    }

    func testSimulatorDataSizeReadingsAreOptionalAndMalformedValuesStayUnknown() throws {
        let listing =
            #"{"devices":{"runtime":[{"udid":"a","name":"a","state":"Shutdown","dataPathSize":123},{"udid":"b","name":"b","state":"Shutdown","dataPathSize":-1},{"udid":"c","name":"c","state":"Shutdown"}]}}"#
        let devices = try SimctlBackend.parseDeviceList(listing)
        XCTAssertEqual(devices.map(\.dataSizeBytes), [123, nil, nil])
    }

    /// Cheap, read-only real calls; runs only on the macOS CI job (SIMQ_REAL_READONLY=1).
    /// No boots, no writes.
    func testRealReadOnlyCallsOnMacOS() throws {
        guard ProcessInfo.processInfo.environment["SIMQ_REAL_READONLY"] == "1" else {
            throw XCTSkip("set SIMQ_REAL_READONLY=1 on macOS for real read-only calls")
        }
        let runner = ToolRunner()
        let listing = try runner.check("xcrun", ["simctl", "list", "-j", "devices"], timeoutSeconds: 120)
        let devices = try SimctlBackend.parseDeviceList(listing)
        print("simctl list: \(devices.count) devices, \(devices.filter(\.isBooted).count) booted")
        let snapshot = try SystemResourceProbe(runner: runner).sample(now: Date().timeIntervalSince1970)
        print(
            "host probe: load1=\(snapshot.load1) load5=\(snapshot.load5) cpus=\(snapshot.cpuCount) "
                + "available=\(snapshot.availableMemoryBytes) swap_used=\(snapshot.swapUsedBytes) "
                + "pressure=\(snapshot.memoryPressure.rawValue) free_disk=\(snapshot.freeDiskBytes) "
                + "thermal=\(snapshot.thermalState.rawValue)")
        XCTAssertGreaterThan(snapshot.totalMemoryBytes, 0)
        XCTAssertGreaterThan(snapshot.availableMemoryBytes, 0)
        XCTAssertGreaterThan(try SimProcessProbe(runner: runner).processes().count, 0)
    }
}
