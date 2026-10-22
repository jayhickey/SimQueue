// SPDX-License-Identifier: MIT

import SimQueueCore
import XCTest

final class HostSizingTests: XCTestCase {
    private func applied(
        _ sizing: HostSizing = HostSizing(), cores: Int, gib: UInt64, pool: SimPoolConfig? = SimPoolConfig()
    ) -> (SchedulerConfig, SimPoolConfig?) {
        var scheduler = SchedulerConfig()
        var pool = pool
        sizing.apply(cpuCount: cores, totalMemoryBytes: gib * ByteSize.gibibyte, to: &scheduler, pool: &pool)
        return (scheduler, pool)
    }

    func testTheMiniKeepsItsHostGatesAndCanFillItsRunningCapacity() throws {
        let (scheduler, pool) = applied(cores: 10, gib: 32)
        let old = SchedulerConfig()
        XCTAssertEqual(scheduler.loadThrottle, old.loadThrottle, "30/30/15/20")
        XCTAssertEqual(scheduler.maxRunningSims, old.maxRunningSims)
        XCTAssertEqual(scheduler.bootLoadLimit(cpuCount: 10), 20)
        XCTAssertEqual(pool?.maxSims, scheduler.maxRunningSims)
        XCTAssertEqual(pool?.settle.loadBelow, SettleConfig().loadBelow)
        XCTAssertEqual(pool?.settle.load1RecoveryBelow, scheduler.loadThrottle.clearBelowLoad5)
        XCTAssertEqual(scheduler.reserveBytes, 32 * ByteSize.gibibyte / 10, "10% of RAM, about the old 3 GiB")
    }

    func testABiggerHostScalesEveryLimit() throws {
        let (scheduler, pool) = applied(cores: 24, gib: 128)
        XCTAssertEqual(scheduler.loadThrottle.load5Above, 72)
        XCTAssertEqual(scheduler.loadThrottle.load1Above, 72)
        XCTAssertEqual(scheduler.loadThrottle.load5WithLoad1Above, 36)
        XCTAssertEqual(scheduler.loadThrottle.clearBelowLoad5, 48)
        XCTAssertEqual(scheduler.bootLoadLimit(cpuCount: 24), 48)
        XCTAssertEqual(scheduler.maxRunningSims, 16)
        XCTAssertEqual(scheduler.reserveBytes, UInt64(Double(128 * ByteSize.gibibyte) * 0.1))
        XCTAssertEqual(pool?.maxSims, 16)
        XCTAssertEqual(pool?.settle.loadBelow, 48)
        XCTAssertEqual(pool?.settle.load1RecoveryBelow, 48)
    }

    func testASmallHostGetsAtLeastOneSimAndTheMinimumReserve() throws {
        let (scheduler, pool) = applied(cores: 4, gib: 8)
        XCTAssertEqual(scheduler.maxRunningSims, 1)
        XCTAssertEqual(pool?.maxSims, 1)
        XCTAssertEqual(scheduler.reserveBytes, ByteSize.gibibyte, "10% is under the 1 GiB floor")
    }

    func testSixteenGiBHostStillUsesTenPercentReserve() {
        let (scheduler, _) = applied(cores: 10, gib: 16)
        XCTAssertEqual(scheduler.reserveBytes, UInt64(Double(16 * ByteSize.gibibyte) * 0.1))
        let (explicit, _) = applied(HostSizing(minReserveBytes: 2 * ByteSize.gibibyte), cores: 4, gib: 8)
        XCTAssertEqual(explicit.reserveBytes, 2 * ByteSize.gibibyte)
    }

    func testAutomaticPoolDoesNotExceedAnExplicitRunningLimit() throws {
        let sizing = HostSizing(maxRunningSims: 2)
        let (scheduler, pool) = applied(sizing, cores: 24, gib: 128)
        XCTAssertEqual(scheduler.maxRunningSims, 2)
        XCTAssertEqual(pool?.maxSims, 2)
    }

    func testExplicitSettingsWin() throws {
        var sizing = HostSizing(reserveBytes: 5 * ByteSize.gibibyte, maxRunningSims: 3)
        sizing.poolMaxSimsIsExplicit = true
        sizing.settleLoadBelowIsExplicit = true
        var pool = SimPoolConfig(maxSims: 6)
        pool.settle.loadBelow = 12
        let (scheduler, applied) = applied(sizing, cores: 24, gib: 128, pool: pool)
        XCTAssertEqual(scheduler.reserveBytes, 5 * ByteSize.gibibyte)
        XCTAssertEqual(scheduler.maxRunningSims, 3)
        XCTAssertEqual(applied?.maxSims, 6)
        XCTAssertEqual(applied?.settle.loadBelow, 12)
        XCTAssertNil(applied?.settle.load1RecoveryBelow)
    }

    func testExplicitPerCoreSettlingRemainsStrict() throws {
        var sizing = HostSizing(settleLoad5PerCore: 1.5)
        sizing.settleLoad5PerCoreIsExplicit = true
        let (_, pool) = applied(sizing, cores: 10, gib: 32)
        XCTAssertEqual(pool?.settle.loadBelow, 15)
        XCTAssertNil(pool?.settle.load1RecoveryBelow)
        for cores in [4, 10, 24] {
            let (scheduler, pool) = applied(cores: cores, gib: 64)
            XCTAssertEqual(pool?.settle.load1RecoveryBelow, scheduler.loadThrottle.clearBelowLoad5)
        }
    }

    func testThePoolNeverDropsBelowWarmMinAndANilPoolStaysNil() throws {
        XCTAssertEqual(applied(cores: 4, gib: 8, pool: SimPoolConfig(maxSims: 3, warmMin: 3)).1?.maxSims, 3)
        XCTAssertNil(applied(cores: 10, gib: 32, pool: nil).1)
    }

    func testTheMaxLoad5LimitStaysAbsolute() throws {
        var scheduler = SchedulerConfig()
        scheduler.loadThrottle.maxLoad5 = 12
        var pool: SimPoolConfig?
        HostSizing().apply(cpuCount: 24, totalMemoryBytes: 64 * ByteSize.gibibyte, to: &scheduler, pool: &pool)
        XCTAssertEqual(scheduler.loadThrottle.maxLoad5, 12)
    }

    func testShortAverageRecoveryScalesWithTheExistingHostClearFactor() {
        for cores in [4, 10, 24] {
            let (scheduler, _) = applied(cores: cores, gib: 64)
            let clear = Double(cores) * 2
            let history = Double(cores) * 4
            for held in [false, true] {
                XCTAssertFalse(scheduler.loadThrottle.isThrottled(load1: clear, load5: history, wasThrottled: held))
                XCTAssertTrue(
                    scheduler.loadThrottle.isThrottled(load1: clear + 0.01, load5: history, wasThrottled: held))
            }
        }
        let (custom, _) = applied(HostSizing(throttleClearLoad5PerCore: 1), cores: 10, gib: 32)
        XCTAssertFalse(custom.loadThrottle.isThrottled(load1: 10, load5: 40, wasThrottled: true))
        XCTAssertTrue(custom.loadThrottle.isThrottled(load1: 10.01, load5: 40, wasThrottled: true))
    }
}
