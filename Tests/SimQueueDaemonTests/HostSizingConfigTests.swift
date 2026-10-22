// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import XCTest

/// Config `host`: per-core load factors and RAM-derived limits.
final class HostSizingConfigTests: XCTestCase {
    func testHostKeysParseAndApply() throws {
        var config = try DaemonConfig.parse(
            Data(
                #"""
                {"host": {"throttle_load5_per_core": 4, "throttle_load1_per_core": 5,
                          "throttle_load5_with_load1_per_core": 2, "throttle_clear_load5_per_core": 3,
                          "boot_load_per_core": 3.5, "settle_load5_per_core": 2.5,
                          "reserve_percent": 15, "min_reserve_mib": 1024,
                          "ram_per_running_sim_mib": 4096, "ram_per_pool_sim_mib": 8192},
                 "pool": {}}
                """#.utf8))
        config.applyHostSizing(cpuCount: 10, totalMemoryBytes: 32 * ByteSize.gibibyte)
        XCTAssertEqual(config.scheduler.loadThrottle.load5Above, 40)
        XCTAssertEqual(config.scheduler.loadThrottle.load1Above, 50)
        XCTAssertEqual(config.scheduler.loadThrottle.load5WithLoad1Above, 20)
        XCTAssertEqual(config.scheduler.loadThrottle.clearBelowLoad5, 30)
        XCTAssertEqual(config.scheduler.bootLoadLimit(cpuCount: 10), 35)
        XCTAssertEqual(config.pool?.settle.loadBelow, 25)
        XCTAssertNil(config.pool?.settle.load1RecoveryBelow)
        XCTAssertEqual(config.scheduler.reserveBytes, UInt64(Double(32 * ByteSize.gibibyte) * 0.15))
        XCTAssertEqual(config.scheduler.maxRunningSims, 8)
        XCTAssertEqual(config.pool?.maxSims, 4)
    }

    func testAbsoluteSettingsBeatTheDerivedOnes() throws {
        var config = try DaemonConfig.parse(
            Data(
                #"""
                {"host": {"reserve_mib": 4096, "max_running_sims": 2},
                 "pool": {"max_sims": 5, "settle": {"load_below": 9}}}
                """#.utf8))
        config.applyHostSizing(cpuCount: 24, totalMemoryBytes: 128 * ByteSize.gibibyte)
        XCTAssertEqual(config.scheduler.reserveBytes, 4 * ByteSize.gibibyte)
        XCTAssertEqual(config.scheduler.maxRunningSims, 2)
        XCTAssertEqual(config.pool?.maxSims, 5)
        XCTAssertEqual(config.pool?.settle.loadBelow, 9)
        XCTAssertNil(config.pool?.settle.load1RecoveryBelow)
        XCTAssertEqual(config.scheduler.loadThrottle.load5Above, 72, "the per-core factors still scale")
    }

    func testBadHostValuesAreRejected() {
        for bad in [
            #"{"host": {"boot_load_per_core": 0}}"#,
            #"{"host": {"throttle_load5_per_core": -1}}"#,
            #"{"host": {"throttle_load5_per_core": 2, "throttle_clear_load5_per_core": 3}}"#,
            #"{"host": {"reserve_percent": 100}}"#,
            #"{"host": {"max_running_sims": 0}}"#,
            #"{"host": {"ram_per_running_sim_mib": 0}}"#,
            #"{"host": {"ram_per_pool_sim_mib": 0}}"#,
            #"{"host": {"reserve_mib": 18446744073709551615}}"#,
            #"{"host": {"min_reserve_mib": 17592186044416}}"#,
            #"{"host": {"ram_per_running_sim_mib": 18446744073709551615}}"#,
        ] {
            XCTAssertThrowsError(try DaemonConfig.parse(Data(bad.utf8)), bad)
        }
    }

    func testSimulatorBootMemoryOverrideAndDefault() throws {
        for (host, expected) in [
            ("{}", 3 * ByteSize.gibibyte),
            (#"{"sim_boot_cost_mib": 1024}"#, ByteSize.gibibyte),
            (#"{"sim_boot_cost_mib": 0}"#, UInt64(0)),
            (#"{"sim_boot_cost_mib": 16777216}"#, UInt64(16777216) * ByteSize.mebibyte),
        ] {
            var config = try DaemonConfig.parse(Data("{\"host\": \(host), \"pool\": {}}".utf8))
            config.applyHostSizing(cpuCount: 10, totalMemoryBytes: 32 * ByteSize.gibibyte)
            XCTAssertEqual(config.scheduler.simBootCostBytes, expected, host)
        }
        for value in ["-1", "1.5", "16777217", "18446744073709551615", "\"1024\""] {
            XCTAssertThrowsError(
                try DaemonConfig.parse(Data("{\"host\": {\"sim_boot_cost_mib\": \(value)}}".utf8)))
        }
    }

    func testNoHostSectionMeansTheDefaults() throws {
        XCTAssertEqual(try DaemonConfig.parse(Data("{}".utf8)).host, HostSizing())
    }

    func testDefaultSettlingRecoveryAndExplicitOverrides() throws {
        for (json, expected) in [
            (#"{"pool":{"settle":{"mode":"load"}}}"#, Optional(20.0)),
            (#"{"pool":{"settle":{"load_below":20}}}"#, nil),
            (#"{"host":{"settle_load5_per_core":2},"pool":{}}"#, nil),
            (#"{"pool":{"settle":{"load_below":20,"load1_recovery_below":1000}}}"#, nil),
        ] {
            var config = try DaemonConfig.parse(Data(json.utf8))
            config.applyHostSizing(cpuCount: 10, totalMemoryBytes: 32 * ByteSize.gibibyte)
            XCTAssertEqual(config.pool?.settle.load1RecoveryBelow, expected, json)
            XCTAssertEqual(config.pool?.settle.loadBelow, 20, json)
            let summary = config.hostSizingSummary(cpuCount: 10, totalMemoryBytes: 32 * ByteSize.gibibyte)
            XCTAssertEqual(summary.contains("or load1 <= 20.0 (default recovery)"), expected != nil, summary)
        }
    }

    func testReserveMiBZeroMeansNoReserve() throws {
        var config = try DaemonConfig.parse(Data(#"{"host": {"reserve_mib": 0}}"#.utf8))
        config.applyHostSizing(cpuCount: 10, totalMemoryBytes: 32 * ByteSize.gibibyte)
        XCTAssertEqual(config.scheduler.reserveBytes, 0)
    }

    func testTheStartupLineNamesEveryDerivedLimit() throws {
        var config = try DaemonConfig.parse(Data(#"{"pool": {}}"#.utf8))
        config.applyHostSizing(cpuCount: 10, totalMemoryBytes: 32 * ByteSize.gibibyte)
        XCTAssertEqual(
            config.hostSizingSummary(cpuCount: 10, totalMemoryBytes: 32 * ByteSize.gibibyte),
            "simqd: host sizing for 10 cores, 32768 MiB: reserve 3276 MiB, max_running_sims 4, "
                + "boot gate load1 <= 20.0, default throttle load5 > 30.0 or load1 > 30.0 with load5 > 15.0, "
                + "recovery at load1 <= 20.0; otherwise load5 <= 20.0 after entry triggers clear, "
                + "pool max_sims 4, settle load5 < 20.0 or load1 <= 20.0 (default recovery)")
    }
}
