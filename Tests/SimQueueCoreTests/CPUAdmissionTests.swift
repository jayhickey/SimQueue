// SPDX-License-Identifier: MIT
import Foundation
import XCTest

@testable import SimQueueCore

final class CPUAdmissionTests: XCTestCase {
    private func host(_ percent: Double?, load: Double = 150) -> HostSnapshot {
        var host = makeHost(load1: load, load5: load)
        host.cpuSustainedPercent = percent
        return host
    }

    func testSustainedWindowRequiresContinuousHistoryAndWeightsTime() {
        var window = CPUUsageWindow()
        XCTAssertNil(window.add(at: 0, percent: 0))
        XCTAssertNil(window.add(at: 2, percent: 100))
        XCTAssertNil(window.add(at: 5, percent: 0))
        XCTAssertEqual(window.add(at: 10, percent: 50), 45)
        XCTAssertEqual(window.add(at: 12, percent: 100), 45)
        XCTAssertNil(window.add(at: 18, percent: 20))  // gap resets the window
        XCTAssertNil(window.add(at: 19, percent: .nan))
        XCTAssertNil(window.add(at: 20, percent: 20))
        XCTAssertNil(window.add(at: 21, percent: nil))
        XCTAssertNil(window.add(at: 22, percent: 20))
    }

    func testHighLoadWithSpareCPUAdmitsButHighCPUWithLowLoadHolds() {
        let scheduler = Scheduler(config: testConfig())
        let job = makeJob("one", seq: 1, resources: sims(1))
        let spare = scheduler.plan(input(queued: [job], host: host(44)))
        XCTAssertEqual(spare.admittedIDs, ["one"])
        XCTAssertFalse(spare.loadThrottled)
        let busy = scheduler.plan(input(queued: [job], host: host(95, load: 1)))
        XCTAssertTrue(busy.admissions.isEmpty)
        XCTAssertEqual(busy.waiting.first?.reasons.first?.code, "cpu_throttle")
        XCTAssertTrue(busy.loadThrottled)
    }

    func testCPUHysteresisRecoversWithoutHistoricalLoadClearing() {
        let config = testConfig()
        XCTAssertNil(config.admissionCPUWaitReason(host: host(85), now: 0, wasThrottled: false))
        XCTAssertNotNil(config.admissionCPUWaitReason(host: host(85), now: 0, wasThrottled: true))
        XCTAssertNil(config.admissionCPUWaitReason(host: host(75), now: 0, wasThrottled: true))
    }

    func testMissingInvalidAndStaleCPUUseLegacyLoadGate() {
        let config = testConfig()
        for value: Double? in [nil, .nan, -1, 101] {
            XCTAssertEqual(
                config.admissionCPUWaitReason(
                    host: host(value), now: 0,
                    wasThrottled: false)?.code, "load_throttle")
        }
        XCTAssertEqual(
            config.admissionCPUWaitReason(
                host: host(20), now: 6,
                wasThrottled: false)?.code, "load_throttle")
        XCTAssertEqual(config.bootWaitReason(host: host(nil), now: 0)?.code, "load_too_high_for_boot")
    }

    func testExplicitAbsoluteLoadCapStillApplies() {
        var config = testConfig()
        config.loadThrottle.maxLoad5 = 100
        XCTAssertEqual(
            config.admissionCPUWaitReason(
                host: host(20), now: 0,
                wasThrottled: false)?.code, "load_throttle")
        XCTAssertNotNil(config.admissionCPUWaitReason(host: host(20, load: 90), now: 0, wasThrottled: true))
        XCTAssertNil(config.admissionCPUWaitReason(host: host(20, load: 80), now: 0, wasThrottled: true))
    }

    func testWarmJobCanStartWhileNewBootWaits() {
        let scheduler = Scheduler(config: testConfig())
        let job = makeJob("one", seq: 1, resources: sims(1))
        let cold = scheduler.plan(input(queued: [job], host: host(85)))
        XCTAssertTrue(cold.admissions.isEmpty)
        XCTAssertEqual(cold.waiting.first?.reasons.first?.code, "cpu_too_high_for_boot")
        let warm = scheduler.plan(input(queued: [job], host: host(85), pool: PoolSnapshot(idleRunning: 1)))
        XCTAssertEqual(warm.admittedIDs, ["one"])
    }

    func testMemoryAndThermalProtectionsRemainAuthoritative() {
        let scheduler = Scheduler(config: testConfig())
        let job = makeJob("one", seq: 1, resources: sims(0))
        var sample = host(20)
        sample.memoryPressure = .warn
        XCTAssertEqual(
            scheduler.plan(input(queued: [job], host: sample)).waiting.first?.reasons.first?.code,
            "memory_pressure")
        sample.memoryPressure = .normal
        sample.thermalState = .serious
        XCTAssertEqual(
            scheduler.plan(input(queued: [job], host: sample)).waiting.first?.reasons.first?.code,
            "thermal")
        sample.thermalState = .nominal
        sample.availableMemoryBytes = 0
        XCTAssertEqual(
            scheduler.plan(input(queued: [job], host: sample)).waiting.first?.reasons.first?.code,
            "insufficient_memory")
    }

    func testCPUAdmissionWaitsForResourceResponseThenAllowsOverlap() {
        let scheduler = Scheduler(config: SchedulerConfig())
        let job = makeJob("one", seq: 1, resources: sims(0))
        var request = input(queued: [job], host: host(40))
        request.lastAdmissionAt = -9
        XCTAssertTrue(scheduler.plan(request).admissions.isEmpty)
        request.lastAdmissionAt = -10
        XCTAssertEqual(scheduler.plan(request).admittedIDs, ["one"])
        var active = makeJob("active", seq: 0, resources: sims(0))
        active.admittedAt = -10
        request.active = [active]
        XCTAssertEqual(scheduler.plan(request).admittedIDs, ["one"])
    }

    func testDefaultSettleUsesCPUButExplicitLoadSettingStaysStrict() {
        var scheduler = SchedulerConfig()
        var pool: SimPoolConfig? = SimPoolConfig()
        HostSizing().apply(cpuCount: 10, totalMemoryBytes: 32 * gib, to: &scheduler, pool: &pool)
        let calm = SettleSignals(load5: 150, load1: 150, cpuSustainedPercent: 40)
        XCTAssertEqual(SettleGate.evaluate(pool!.settle, signals: calm, waitedSeconds: 20), .settled)
        let busy = SettleSignals(load5: 1, load1: 1, cpuSustainedPercent: 95)
        XCTAssertEqual(SettleGate.evaluate(pool!.settle, signals: busy, waitedSeconds: 20), .wait)
        var sizing = HostSizing()
        sizing.settleLoadBelowIsExplicit = true
        sizing.apply(cpuCount: 10, totalMemoryBytes: 32 * gib, to: &scheduler, pool: &pool)
        XCTAssertNil(pool!.settle.cpuRecoveryBelow)
        XCTAssertEqual(SettleGate.evaluate(pool!.settle, signals: calm, waitedSeconds: 20), .wait)
    }

    func testOldSnapshotsDecodeWithoutCPUObservation() throws {
        var sample = host(nil)
        sample.cpuUsagePercent = nil
        let data = try JSONEncoder().encode(sample)
        XCTAssertNil(try JSONDecoder().decode(HostSnapshot.self, from: data).cpuSustainedPercent)
    }
}
