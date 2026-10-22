// SPDX-License-Identifier: MIT

import XCTest

@testable import SimQueueCore

final class SchedulerTests: XCTestCase {
    private let scheduler = Scheduler(config: testConfig())

    // MARK: - Basics

    func testJobWithoutSimsIsAdmittedWithZeroSims() {
        let plan = scheduler.plan(input(queued: [makeJob("J-1", seq: 1)]))
        XCTAssertEqual(plan.admittedIDs, ["J-1"])
        XCTAssertEqual(plan.admissions.first?.grantedSims, 0)
        XCTAssertTrue(plan.waiting.isEmpty)
        XCTAssertNil(plan.reservedFor)
    }

    func testEmptyQueueProducesEmptyPlan() {
        let plan = scheduler.plan(input(queued: []))
        XCTAssertTrue(plan.admissions.isEmpty)
        XCTAssertTrue(plan.waiting.isEmpty)
    }

    func testPlanIsDeterministic() {
        let jobs = (1...6).map { makeJob("J-\($0)", seq: Int64($0), retryable: true, resources: sims(1, perSim: gib)) }
        let first = scheduler.plan(input(queued: jobs, pool: PoolSnapshot(idleRunning: 2)))
        let second = scheduler.plan(input(queued: jobs.reversed(), pool: PoolSnapshot(idleRunning: 2)))
        XCTAssertEqual(first, second)
    }

    // MARK: - Memory and reserve

    func testDefaultBootAllowanceIsThreeGiBAndWarmReuseDoesNotPayIt() {
        var config = testConfig()
        config.simBootCostBytes = SchedulerConfig().simBootCostBytes
        XCTAssertEqual(config.simBootCostBytes, 3 * gib)
        let jobs = [makeJob("probe", seq: 1, resources: sims(1, memory: gib / 2))]
        let policy = Scheduler(config: config)
        XCTAssertEqual(
            policy.plan(input(queued: jobs, host: makeHost(availableGiB: 6))).reasonCodes(for: "probe"),
            ["insufficient_memory"])
        XCTAssertEqual(policy.plan(input(queued: jobs, host: makeHost(availableGiB: 7))).admittedIDs, ["probe"])
        XCTAssertEqual(
            policy.plan(input(queued: jobs, host: makeHost(availableGiB: 4), pool: PoolSnapshot(idleRunning: 1)))
                .admittedIDs, ["probe"])
    }

    func testHostBootMemoryOverrideChangesColdAdmission() {
        var config = testConfig()
        let request = input(
            queued: [makeJob("probe", seq: 1, resources: sims(1, memory: gib / 2))],
            host: makeHost(availableGiB: 5))
        config.simBootCostBytes = 4_380_000_000
        XCTAssertEqual(Scheduler(config: config).plan(request).reasonCodes(for: "probe"), ["insufficient_memory"])
        var pool: SimPoolConfig?
        HostSizing(reserveBytes: config.reserveBytes, simBootCostBytes: gib).apply(
            cpuCount: 10, totalMemoryBytes: 32 * gib, to: &config, pool: &pool)
        XCTAssertEqual(Scheduler(config: config).plan(request).admittedIDs, ["probe"])
    }

    func testReserveIsHeldBackInBytes() {
        let host = makeHost(availableGiB: 5)
        let tooBig = makeJob("J-1", seq: 1, resources: sims(0, memory: 3 * gib))
        let plan = scheduler.plan(input(queued: [tooBig], host: host))
        XCTAssertEqual(plan.reasonCodes(for: "J-1"), ["insufficient_memory"])
        guard case .insufficientMemory(let available, let needed, let reserve) = plan.reasons(for: "J-1").first else {
            return XCTFail("expected insufficient_memory")
        }
        XCTAssertEqual(available, 5 * gib)
        XCTAssertEqual(needed, 3 * gib)
        XCTAssertEqual(reserve, 3 * gib)

        let fits = makeJob("J-2", seq: 2, resources: sims(0, memory: 2 * gib))
        XCTAssertEqual(scheduler.plan(input(queued: [fits], host: host)).admittedIDs, ["J-2"])
    }

    func testAvailableBelowReserveAdmitsNothingThatNeedsMemory() {
        let plan = scheduler.plan(
            input(queued: [makeJob("J-1", seq: 1, resources: sims(0, memory: 1))], host: makeHost(availableGiB: 2)))
        XCTAssertEqual(plan.reasonCodes(for: "J-1"), ["insufficient_memory"])
    }

    func testBootCostIsChargedPerNewSim() {
        // 6 gib available - 3 reserve = 3; a boot costs 2 + 1 per sim = 3: fits exactly.
        let job = makeJob("J-1", seq: 1, retryable: true, resources: sims(1, perSim: gib))
        let plan = scheduler.plan(input(queued: [job], host: makeHost(availableGiB: 6)))
        XCTAssertEqual(plan.admissions.first?.newBoots, 1)
        XCTAssertEqual(plan.admissions.first?.chargedMemoryBytes, 3 * gib)
        let tight = scheduler.plan(input(queued: [job], host: makeHost(availableGiB: 5)))
        XCTAssertEqual(tight.reasonCodes(for: "J-1"), ["insufficient_memory"])
    }

    func testMultipleAdmissionsDrawDownMemoryWithinOnePass() {
        let jobs = (1...3).map { makeJob("J-\($0)", seq: Int64($0), resources: sims(0, memory: 8 * gib)) }
        let plan = scheduler.plan(input(queued: jobs, host: makeHost(availableGiB: 20)))
        XCTAssertEqual(plan.admittedIDs, ["J-1", "J-2"])
        XCTAssertEqual(plan.reasonCodes(for: "J-3"), ["insufficient_memory"])
    }

    // MARK: - Shards and sim allocation

    func testSimulatorRangeGetsLargestCountThatFits() {
        // 6 gib - 3 reserve = 3 gib at 1 gib per sim, 4 idle sims: grant 3.
        let job = makeJob("J-1", seq: 1, retryable: true, resources: sims(1, 4, perSim: gib))
        let plan = scheduler.plan(
            input(queued: [job], host: makeHost(availableGiB: 6), pool: PoolSnapshot(idleRunning: 4)))
        XCTAssertEqual(plan.admissions.first?.grantedSims, 3)
        XCTAssertEqual(plan.admissions.first?.fromIdleRunning, 3)
        XCTAssertEqual(plan.admissions.first?.newBoots, 0)
    }

    func testIdleRunningSimsAreUsedBeforeParkedAndBoots() {
        let job = makeJob("J-1", seq: 1, retryable: true, resources: sims(3, perSim: 0))
        let config = testConfig(maxParkedSims: 2, maxConcurrentBoots: 1)
        // One idle, one parked, one new boot.
        let plan = Scheduler(config: config).plan(
            input(queued: [job], pool: PoolSnapshot(idleRunning: 1, idleParked: 1)))
        let admission = plan.admissions.first
        XCTAssertEqual(admission?.fromIdleRunning, 1)
        XCTAssertEqual(admission?.fromParked, 1)
        XCTAssertEqual(admission?.newBoots, 1)
    }

    func testRunningCapBlocksNewSims() {
        let job = makeJob("J-1", seq: 1, retryable: true, resources: sims(1))
        let plan = scheduler.plan(input(queued: [job], pool: PoolSnapshot(busyRunning: 4)))
        XCTAssertEqual(plan.reasonCodes(for: "J-1"), ["sim_capacity"])
    }

    func testParkedThawCountsAgainstRunningCap() {
        let job = makeJob("J-1", seq: 1, retryable: true, resources: sims(1))
        let config = testConfig(maxRunningSims: 2, maxParkedSims: 1)
        let plan = Scheduler(config: config).plan(
            input(queued: [job], pool: PoolSnapshot(busyRunning: 2, idleParked: 1)))
        XCTAssertEqual(plan.reasonCodes(for: "J-1"), ["sim_capacity"])
    }

    func testAtMostOneBootAtATimeButMultiBootJobsStillRun() {
        XCTAssertEqual(SchedulerConfig().maxConcurrentBoots, 1)
        // A 2-sim job with no warm sims is admitted; its boots run one after another.
        let two = makeJob("J-1", seq: 1, retryable: true, resources: sims(2))
        let plan = scheduler.plan(input(queued: [two]))
        XCTAssertEqual(plan.admissions.first?.grantedSims, 2)
        XCTAssertEqual(plan.admissions.first?.newBoots, 2)

        // While those boots are pending, nothing else may boot.
        let other = makeJob("J-2", seq: 2, retryable: true, resources: sims(1))
        let blocked = scheduler.plan(input(queued: [other], pool: PoolSnapshot(bootsInProgress: 1)))
        XCTAssertEqual(blocked.reasonCodes(for: "J-2"), ["boot_capacity"])
    }

    func testRequestLargerThanRunningCapNeverFitsAndDoesNotBlockQueue() {
        let huge = makeJob("J-1", seq: 1, priority: 100, retryable: true, resources: sims(5))
        let small = makeJob("J-2", seq: 2, priority: 10, retryable: true, resources: sims(1))
        let plan = scheduler.plan(input(queued: [huge, small]))
        XCTAssertEqual(plan.reasonCodes(for: "J-1"), ["never_fits"])
        XCTAssertNil(plan.reservedFor)
        XCTAssertEqual(plan.admittedIDs, ["J-2"])
    }

    func testBootInProgressBlocksAnotherBootInSamePass() {
        let jobs = [
            makeJob("J-1", seq: 1, retryable: true, resources: sims(1)),
            makeJob("J-2", seq: 2, retryable: true, resources: sims(1)),
        ]
        let plan = scheduler.plan(input(queued: jobs))
        XCTAssertEqual(plan.admittedIDs, ["J-1"])
        XCTAssertEqual(plan.reasonCodes(for: "J-2"), ["boot_capacity"])
    }

    func testBootLoadGateOnlyAppliesToBoots() {
        let host = makeHost(load1: 25, load5: 10, cpuCount: 10)  // limit 2 x 10 = 20
        let job = makeJob("J-1", seq: 1, retryable: true, resources: sims(1))
        XCTAssertEqual(
            scheduler.plan(input(queued: [job], host: host)).reasonCodes(for: "J-1"), ["load_too_high_for_boot"])
        XCTAssertEqual(
            scheduler.plan(input(queued: [job], host: host, pool: PoolSnapshot(idleRunning: 1))).admittedIDs, ["J-1"])
    }

    // MARK: - Host-wide gates (defaults)

    func testDefaultHostThresholds() {
        let config = SchedulerConfig()
        XCTAssertEqual(
            config.loadThrottle,
            LoadThrottlePolicy(load5Above: 30, load1Above: 30, load5WithLoad1Above: 15, clearBelowLoad5: 20))
        XCTAssertEqual(config.pressureStop, .warn)
        XCTAssertEqual(config.maxSwapUsedBytes, 3 * gib)
        XCTAssertEqual(config.minFreeDiskBytes, 20 * gib)
    }

    func testLoad5AboveThirtyThrottlesUntilShortAverageRecovers() {
        let plan = scheduler.plan(input(queued: [makeJob("J-1", seq: 1)], host: makeHost(load1: 25, load5: 30.5)))
        XCTAssertEqual(plan.reasonCodes(for: "J-1"), ["load_throttle"])
        XCTAssertTrue(plan.loadThrottled)
        XCTAssertTrue(
            scheduler.plan(input(queued: [makeJob("J-1", seq: 1)], host: makeHost(load5: 30))).admissions.count == 1)
    }

    func testLoad1SpikeNeedsLoad5AboveFifteen() {
        let throttled = scheduler.plan(input(queued: [makeJob("J-1", seq: 1)], host: makeHost(load1: 31, load5: 16)))
        XCTAssertEqual(throttled.reasonCodes(for: "J-1"), ["load_throttle"])
        let spikeOnly = scheduler.plan(input(queued: [makeJob("J-1", seq: 1)], host: makeHost(load1: 31, load5: 15)))
        XCTAssertEqual(spikeOnly.admittedIDs, ["J-1"])
        XCTAssertFalse(spikeOnly.loadThrottled)
    }

    func testHistoricalHysteresisStillAppliesAboveShortAverageRecoveryThreshold() {
        let job = makeJob("J-1", seq: 1)
        let still = scheduler.plan(
            input(queued: [job], host: makeHost(load1: 25, load5: 20.5), loadThrottledPreviously: true))
        XCTAssertTrue(still.loadThrottled)
        XCTAssertEqual(still.reasons(for: "J-1"), [.loadThrottle(load1: 25, load5: 20.5, clearing: true)])
        let cleared = scheduler.plan(
            input(queued: [job], host: makeHost(load1: 25, load5: 20), loadThrottledPreviously: true))
        XCTAssertFalse(cleared.loadThrottled)
        XCTAssertEqual(cleared.admittedIDs, ["J-1"])
        // Without prior throttle, 20.5 is fine.
        XCTAssertFalse(scheduler.plan(input(queued: [job], host: makeHost(load1: 25, load5: 20.5))).loadThrottled)
    }

    func testShortAverageRecoveryBoundaryDoesNotOscillateWithHistoricalLoad() {
        let policy = LoadThrottlePolicy()
        for was in [false, true] {
            XCTAssertFalse(policy.isThrottled(load1: 20, load5: 40.55, wasThrottled: was))
            XCTAssertTrue(policy.isThrottled(load1: 20.001, load5: 40.55, wasThrottled: was))
            XCTAssertTrue(policy.isThrottled(load1: 47, load5: 40.55, wasThrottled: was))
        }
        var held = true
        for _ in 0..<8 {
            held = policy.isThrottled(load1: 20, load5: 40.55, wasThrottled: held)
            XCTAssertFalse(held, "five-minute history cannot re-trigger after short-average recovery")
        }
    }

    func testLoadRecoveryPreservesOtherResourceAndBootGates() {
        let job = makeJob("J-1", seq: 1, resources: sims(1))
        let cases: [(HostSnapshot, Double, String)] = [
            (makeHost(pressure: .warn, load1: 20, load5: 40.55), 0, "memory_pressure"),
            (makeHost(load1: 20, load5: 40.55, thermal: .serious), 0, "thermal"),
            (makeHost(load1: 20, load5: 40.55, freeDiskGiB: 1), 0, "disk_low"),
            (makeHost(load1: 20, load5: 40.55), Double(51 * mib), "swap_growing"),
            (makeHost(availableGiB: 2, load1: 20, load5: 40.55), 0, "insufficient_memory"),
            (makeHost(load1: 20, load5: 40.55, cpuCount: 4), 0, "load_too_high_for_boot"),
        ]
        for (host, swapGrowth, reason) in cases {
            let plan = scheduler.plan(
                input(queued: [job], host: host, swapGrowth: swapGrowth, loadThrottledPreviously: true))
            XCTAssertFalse(plan.loadThrottled)
            XCTAssertTrue(plan.admittedIDs.isEmpty)
            XCTAssertTrue(plan.reasonCodes(for: job.id).contains(reason), "\(reason): \(plan.waiting)")
        }
        var paced = testConfig()
        paced.maxAdmissionsPerPass = 1
        paced.minAdmissionIntervalSeconds = 1
        let recovered = Scheduler(config: paced).plan(
            input(
                queued: [makeJob("J-1", seq: 1), makeJob("J-2", seq: 2)],
                host: makeHost(load1: 20, load5: 40.55), loadThrottledPreviously: true))
        XCTAssertEqual(recovered.admittedIDs, ["J-1"], "recovery retains paced admission")
    }

    func testOptionalMaxLoad5HoldsWithHysteresisAndIsOffByDefault() {
        XCTAssertNil(SchedulerConfig().loadThrottle.maxLoad5, "off by default")
        let policy = LoadThrottlePolicy(maxLoad5: 20)
        XCTAssertFalse(policy.isThrottled(load1: 0, load5: 20, wasThrottled: false))
        XCTAssertTrue(policy.isThrottled(load1: 0, load5: 20.1, wasThrottled: false))
        // Default resume point is 80% of the limit.
        XCTAssertTrue(policy.isThrottled(load1: 0, load5: 16.1, wasThrottled: true))
        XCTAssertFalse(policy.isThrottled(load1: 0, load5: 16, wasThrottled: true))
        let custom = LoadThrottlePolicy(maxLoad5: 20, resumeBelowLoad5: 10)
        XCTAssertTrue(custom.isThrottled(load1: 0, load5: 12, wasThrottled: true))
        XCTAssertFalse(custom.isThrottled(load1: 0, load5: 10, wasThrottled: true))
        // Short-average recovery cannot bypass an explicit limit or its resume point.
        XCTAssertTrue(policy.isThrottled(load1: 20, load5: 20.1, wasThrottled: false))
        XCTAssertTrue(policy.isThrottled(load1: 20, load5: 16.1, wasThrottled: true))
        XCTAssertFalse(policy.isThrottled(load1: 20, load5: 16, wasThrottled: true))
        // Default triggers still apply when the short average has not recovered.
        XCTAssertTrue(LoadThrottlePolicy(maxLoad5: 50).isThrottled(load1: 25, load5: 31, wasThrottled: false))
    }

    func testLoadThrottlePolicyTable() {
        let policy = LoadThrottlePolicy()
        let cases: [(Double, Double, Bool, Bool)] = [
            (0, 0, false, false), (0, 30.01, false, false), (25, 30.01, false, true),
            (30.01, 15.01, false, true), (30.01, 15, false, false), (30, 16, false, false),
            (5, 25, true, false), (25, 25, true, true), (25, 20, true, false), (5, 19, true, false),
        ]
        for (load1, load5, was, expected) in cases {
            XCTAssertEqual(
                policy.isThrottled(load1: load1, load5: load5, wasThrottled: was), expected,
                "load1=\(load1) load5=\(load5) was=\(was)")
        }
    }

    func testMemoryPressureWarnOrWorseStopsAdmission() {
        for pressure in [MemoryPressure.warn, .critical] {
            let plan = scheduler.plan(input(queued: [makeJob("J-1", seq: 1)], host: makeHost(pressure: pressure)))
            XCTAssertEqual(plan.reasonCodes(for: "J-1"), ["memory_pressure"])
        }
    }

    func testHistoricalSwapAloneDoesNotStopHealthyAdmissions() {
        let over = scheduler.plan(input(queued: [makeJob("J-1", seq: 1)], host: makeHost(swapUsed: 3 * gib + 1)))
        XCTAssertEqual(over.admittedIDs, ["J-1"])
        let at = scheduler.plan(input(queued: [makeJob("J-1", seq: 1)], host: makeHost(swapUsed: 3 * gib)))
        XCTAssertEqual(at.admittedIDs, ["J-1"])
    }

    func testSwapGrowthStopsAdmission() {
        let plan = scheduler.plan(input(queued: [makeJob("J-1", seq: 1)], swapGrowth: Double(51 * mib)))
        XCTAssertEqual(plan.reasonCodes(for: "J-1"), ["swap_growing"])
    }

    func testThermalSeriousStopsAdmission() {
        XCTAssertEqual(
            scheduler.plan(input(queued: [makeJob("J-1", seq: 1)], host: makeHost(thermal: .serious))).reasonCodes(
                for: "J-1"),
            ["thermal"]
        )
        XCTAssertEqual(
            scheduler.plan(input(queued: [makeJob("J-1", seq: 1)], host: makeHost(thermal: .fair))).admittedIDs, ["J-1"]
        )
    }

    func testDiskBelowTwentyGiBStopsAdmission() {
        XCTAssertEqual(
            scheduler.plan(input(queued: [makeJob("J-1", seq: 1)], host: makeHost(freeDiskGiB: 19))).reasonCodes(
                for: "J-1"),
            ["disk_low"]
        )
        XCTAssertEqual(
            scheduler.plan(input(queued: [makeJob("J-1", seq: 1)], host: makeHost(freeDiskGiB: 20))).admittedIDs,
            ["J-1"])
    }

    func testConfiguredDiskFloorGatesAdmission() {
        var config = testConfig()
        config.minFreeDiskBytes = 50 * gib
        let strict = Scheduler(config: config)
        XCTAssertEqual(
            strict.plan(input(queued: [makeJob("J-1", seq: 1)], host: makeHost(freeDiskGiB: 49))).reasonCodes(
                for: "J-1"),
            ["disk_low"])
        XCTAssertEqual(
            strict.plan(input(queued: [makeJob("J-1", seq: 1)], host: makeHost(freeDiskGiB: 50))).admittedIDs, ["J-1"])

        config.minFreeDiskBytes = 0
        let off = Scheduler(config: config)
        XCTAssertEqual(
            off.plan(input(queued: [makeJob("J-1", seq: 1)], host: makeHost(freeDiskGiB: 0))).admittedIDs, ["J-1"],
            "a 0 floor turns the disk gate off")
    }

    func testPausedAndDrainingStopAdmissionAndReportAllReasons() {
        let plan = scheduler.plan(
            input(
                queued: [makeJob("J-1", seq: 1)],
                host: makeHost(pressure: .warn),
                control: QueueControl(paused: true),
                drain: .draining(recentInfraFailures: 3)
            )
        )
        XCTAssertEqual(plan.reasonCodes(for: "J-1"), ["paused", "draining", "memory_pressure"])
        XCTAssertNil(plan.reservedFor, "a global stop is not a reservation")
    }

    // MARK: - Caps, reservation, backfill

    func testProjectCapIsPerProjectAndDoesNotReserve() {
        let active = (1...3).map { index -> Job in
            var job = makeJob("A-\(index)", seq: Int64(index), project: "app")
            job.state = .running
            return job
        }
        let queued = [
            makeJob("J-1", seq: 10, priority: 100, project: "app"),
            makeJob("J-2", seq: 11, priority: 10, project: "other"),
        ]
        let plan = scheduler.plan(input(queued: queued, active: active))
        XCTAssertEqual(plan.reasonCodes(for: "J-1"), ["project_cap"])
        XCTAssertEqual(plan.admittedIDs, ["J-2"])
        XCTAssertNil(plan.reservedFor)
    }

    func testExclusiveJobsRunOneAtATime() {
        var running = makeJob("A-1", seq: 1, exclusive: true)
        running.state = .running
        let plan = scheduler.plan(
            input(queued: [makeJob("J-1", seq: 2, exclusive: true), makeJob("J-2", seq: 3)], active: [running]))
        XCTAssertEqual(plan.reasonCodes(for: "J-1"), ["exclusive_slot"])
        XCTAssertEqual(plan.admittedIDs, ["J-2"])
    }

    func testExclusiveIsTheOnlyThingThatTakesTheSlot() {
        // Two exclusive jobs queued together: only the first is admitted in one pass.
        let plan = scheduler.plan(
            input(queued: [makeJob("J-1", seq: 1, exclusive: true), makeJob("J-2", seq: 2, exclusive: true)]))
        XCTAssertEqual(plan.admittedIDs, ["J-1"])
        XCTAssertEqual(plan.reasonCodes(for: "J-2"), ["exclusive_slot"])
        // Retryable or labeled jobs never compete for it.
        var labeled = makeJob("J-3", seq: 3, retryable: true)
        labeled.kind = "build"
        XCTAssertEqual(scheduler.plan(input(queued: [labeled])).admittedIDs, ["J-3"])
    }

    func testExclusiveSlotCountIsConfigurable() {
        let plan = Scheduler(config: testConfig(maxConcurrentExclusive: 2)).plan(
            input(queued: (1...3).map { makeJob("J-\($0)", seq: Int64($0), exclusive: true) }))
        XCTAssertEqual(plan.admittedIDs, ["J-1", "J-2"])
    }

    func testMemoryConstrainedWaiterReservesAvailableHeadroom() {
        let host = makeHost(availableGiB: 6)
        let queued = [
            makeJob("J-high", seq: 1, priority: 100, retryable: true, resources: sims(2, perSim: gib)),
            makeJob("J-sim", seq: 2, priority: 50, retryable: true, resources: sims(1, perSim: 0)),
            makeJob("J-small", seq: 3, priority: 10, resources: sims(0, memory: 100 * mib)),
        ]
        let plan = scheduler.plan(input(queued: queued, host: host, pool: PoolSnapshot(idleRunning: 1)))
        XCTAssertEqual(plan.reservedFor, "J-high")
        XCTAssertEqual(plan.warmupHint, 1)
        XCTAssertEqual(plan.reasonCodes(for: "J-sim"), ["insufficient_memory"])
        XCTAssertTrue(plan.admittedIDs.isEmpty)
    }

    func testSimulatorReservationAllowsFittingBuildAboveFormerBackfillCutoff() {
        var request = input(
            queued: [
                makeJob("waiter", seq: 1, priority: 100, resources: sims(1, memory: gib)),
                makeJob("build", seq: 2, resources: sims(0, memory: 2 * gib)),
            ], host: makeHost(availableGiB: 12), pool: PoolSnapshot(busyRunning: 4))
        request.allowNewBoots = false
        let plan = scheduler.plan(request)
        XCTAssertEqual(plan.reservedFor, "waiter")
        XCTAssertEqual(plan.admittedIDs, ["build"])
        XCTAssertTrue(plan.reasonCodes(for: "waiter").contains("sim_capacity"))
    }

    func testReservedParkedAndFutureSimulatorSlotsCannotBeTakenByBackfill() {
        // A four-sim waiter cannot fit while two other sims are busy. Its idle,
        // parked and future slots must all remain available when those jobs finish.
        let queued = [
            makeJob("large", seq: 1, priority: 100, resources: sims(4)),
            makeJob("small", seq: 2, resources: sims(1)),
            makeJob("build", seq: 3, resources: sims(0, memory: gib)),
        ]
        let held = scheduler.plan(
            input(
                queued: queued, host: makeHost(availableGiB: 32),
                pool: PoolSnapshot(idleRunning: 1, busyRunning: 2, idleParked: 1)))
        XCTAssertEqual(held.reservedFor, "large")
        XCTAssertEqual(held.admittedIDs, ["build"])
        XCTAssertTrue(held.reasonCodes(for: "small").contains("sim_capacity"))
        let released = scheduler.plan(
            input(
                queued: Array(queued.prefix(2)), host: makeHost(availableGiB: 32),
                pool: PoolSnapshot(idleRunning: 3, idleParked: 1)))
        XCTAssertEqual(released.admittedIDs, ["large"], "backfill cannot perpetually take the released capacity")
    }

    func testMemoryReservationLetsLargeJobRunAfterCapacityReturns() {
        let queued = [
            makeJob("large", seq: 1, priority: 100, resources: sims(0, memory: 8 * gib)),
            makeJob("small", seq: 2, resources: sims(0, memory: gib)),
        ]
        for _ in 0..<5 {
            let held = scheduler.plan(input(queued: queued, host: makeHost(availableGiB: 10)))
            XCTAssertEqual(held.reservedFor, "large")
            XCTAssertTrue(held.admittedIDs.isEmpty)
        }
        let recovered = scheduler.plan(input(queued: queued, host: makeHost(availableGiB: 12)))
        XCTAssertEqual(recovered.admittedIDs.first, "large")
    }

    func testImpossibleMemoryHintDoesNotReserveTheWholeHost() {
        let plan = scheduler.plan(
            input(queued: [
                makeJob("impossible", seq: 1, priority: 100, resources: sims(0, memory: 40 * gib)),
                makeJob("build", seq: 2, resources: sims(0, memory: gib)),
            ]))
        XCTAssertEqual(plan.reasonCodes(for: "impossible"), ["never_fits"])
        XCTAssertNil(plan.reservedFor)
        XCTAssertEqual(plan.admittedIDs, ["build"])
    }

    func testCompletedJobsStillPaceTheNextAdmissionAndLargeHintsSaturate() {
        let scheduler = Scheduler(config: SchedulerConfig(simBootCostBytes: 0))
        var request = input(queued: [makeJob("next", seq: 2)], now: 10)
        request.lastAdmissionAt = 9.5
        XCTAssertTrue(scheduler.plan(request).admissions.isEmpty)
        request.now = 10.5
        XCTAssertEqual(scheduler.plan(request).admittedIDs, ["next"])
        XCTAssertEqual(
            ResourceRequest(minSims: 3, memoryBytes: UInt64.max, memoryBytesPerSim: UInt64.max)
                .memoryCost(sims: 3, boots: 3, bootCost: UInt64.max), UInt64.max)
        let huge = makeJob("huge", seq: 1, resources: sims(3, perSim: UInt64.max))
        XCTAssertEqual(scheduler.plan(input(queued: [huge])).reasonCodes(for: "huge"), ["never_fits"])
        let broad = makeJob("range", seq: 1, resources: sims(0, Int.max))
        XCTAssertLessThanOrEqual(scheduler.plan(input(queued: [broad])).admissions.first?.grantedSims ?? Int.max, 4)
    }

    func testProductionPacingIsHostWideAndProjectCapIsOptional() {
        let policy = Scheduler(config: SchedulerConfig(simBootCostBytes: 0))
        let queued = (1...8).map { makeJob("job-\($0)", seq: Int64($0), project: $0.isMultiple(of: 2) ? "a" : "b") }
        XCTAssertEqual(policy.plan(input(queued: queued)).admissions.count, 1)
        var recent = makeJob("active", seq: 0)
        recent.state = .running
        recent.admittedAt = 9.5
        XCTAssertEqual(policy.plan(input(queued: queued, active: [recent], now: 10)).admissions.count, 0)
        let older = (1...4).map { index -> Job in
            var job = makeJob("active-\(index)", seq: Int64(index), project: "a")
            job.state = .running; job.admittedAt = 0
            return job
        }
        let afterSettling = policy.plan(input(queued: queued, active: older, now: 120))
        XCTAssertEqual(afterSettling.admissions.count, 1, "one project can exceed three active jobs")
        let atCoreLimit = policy.plan(input(queued: queued, active: older, host: makeHost(cpuCount: 4), now: 120))
        XCTAssertTrue(atCoreLimit.admissions.isEmpty)
        XCTAssertEqual(atCoreLimit.reasonCodes(for: "job-1"), ["admission_pacing"])
    }

    func testHigherPriorityWinsScarceCapacity() {
        let queued = [
            makeJob("J-normal", seq: 1, priority: 50, retryable: true, resources: sims(1)),
            makeJob("J-higher", seq: 2, priority: 70, retryable: true, resources: sims(1)),
        ]
        let plan = scheduler.plan(input(queued: queued, pool: PoolSnapshot(idleRunning: 1, busyRunning: 3)))
        XCTAssertEqual(plan.admittedIDs, ["J-higher"])
        XCTAssertEqual(plan.waiting.map(\.position), [2])
    }

    func testHighPriorityArrivingBehindAQueueGoesFirst() {
        // Several equal-priority jobs are queued, then a higher-priority job arrives.
        var queued = (1...4).map {
            makeJob(
                "J-low\($0)", seq: Int64($0), priority: 70, exclusive: true, retryable: true,
                queueTime: Double($0) * 60,
                resources: sims(1))
        }
        queued.append(
            makeJob(
                "J-urgent", seq: 5, priority: 100, exclusive: true, retryable: true, queueTime: 600, resources: sims(1))
        )
        let plan = scheduler.plan(input(queued: queued, pool: PoolSnapshot(idleRunning: 1), now: 660))
        XCTAssertEqual(plan.admittedIDs, ["J-urgent"])
        XCTAssertEqual(plan.waiting.first?.jobID, "J-low1")
    }

    func testExplanationsFollowDispatchOrder() {
        let queued = (1...3).map {
            makeJob("J-\($0)", seq: Int64($0), priority: 50, retryable: true, resources: sims(1))
        }
        let plan = scheduler.plan(input(queued: queued, pool: PoolSnapshot(busyRunning: 4)))
        XCTAssertEqual(plan.waiting.map(\.jobID), ["J-1", "J-2", "J-3"])
        XCTAssertEqual(plan.waiting.map(\.position), [1, 2, 3])
    }

    // MARK: - Lag correction

    func testGrantedSimsNotYetBusyInPoolAreNotGrantedTwice() {
        var active = makeJob("A-1", seq: 1, retryable: true, resources: sims(2))
        active.state = .admitted
        active.grantedSims = 2
        active.admittedAt = -600
        let job = makeJob("J-1", seq: 2, retryable: true, resources: sims(1))
        // Pool still shows the two granted sims as idle.
        let plan = scheduler.plan(input(queued: [job], active: [active], pool: PoolSnapshot(idleRunning: 2)))
        XCTAssertEqual(plan.admissions.first?.fromIdleRunning, 0)
        XCTAssertEqual(plan.admissions.first?.newBoots, 1)
    }

    func testUnattachedGrantsBeyondPoolCountAsPendingBoots() {
        var active = makeJob("A-1", seq: 1, retryable: true, resources: sims(1))
        active.state = .admitted
        active.grantedSims = 1
        active.admittedAt = -600
        let plan = scheduler.plan(
            input(queued: [makeJob("J-1", seq: 2, retryable: true, resources: sims(1))], active: [active]))
        XCTAssertEqual(plan.reasonCodes(for: "J-1"), ["boot_capacity"])
    }

    func testRecentlyAdmittedMemoryIsChargedUntilSettled() {
        var active = makeJob("A-1", seq: 1, resources: sims(0, memory: 10 * gib))
        active.state = .running
        active.admittedAt = -10
        let job = makeJob("J-1", seq: 2, resources: sims(0, memory: gib))
        let host = makeHost(availableGiB: 12)
        XCTAssertEqual(
            scheduler.plan(input(queued: [job], active: [active], host: host)).reasonCodes(for: "J-1"),
            ["insufficient_memory"])
        active.admittedAt = -120
        XCTAssertEqual(scheduler.plan(input(queued: [job], active: [active], host: host)).admittedIDs, ["J-1"])
    }
}
