// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueEngine
import SimQueueStore
import XCTest

final class CapacityScenarioTests: XCTestCase {
    func testPoolGrowthWaitsForMemoryPressureAndBootHeadroomThenResumes() throws {
        for bootCost in [UInt64(0), SchedulerConfig().simBootCostBytes] {
            let harness = Harness()
            harness.config.simBootCostBytes = bootCost
            harness.reliability.cleanupMode = .enforce
            let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
            let (engine, _, _) = try harness.start(store: store)
            let config = SimPoolConfig(warmMin: 0)
            harness.probe.update { $0.memoryPressure = .warn }
            XCTAssertEqual(try engine.poolPass(config: config, demand: 1).createsDeferredForResources, 1)
            XCTAssertTrue(try store.poolSims().isEmpty)
            _ = try engine.poolPass(config: config, demand: 1)
            XCTAssertEqual(try store.auditEntries().filter { $0.type == "pool_deferred_resources" }.count, 1)
            harness.probe.update { $0.memoryPressure = .normal }
            _ = try engine.poolPass(config: config, demand: 1)
            harness.probe.update { $0.availableMemoryBytes = harness.config.reserveBytes + bootCost - 1 }
            XCTAssertEqual(try engine.poolPass(config: config, demand: 1).bootsDeferredForResources.count, 1)
            XCTAssertTrue(try harness.sims.listDevices().allSatisfy { !$0.isBooted })
            harness.probe.update { $0.availableMemoryBytes = 20 * gib }
            _ = try engine.poolPass(config: config, demand: 1)
            XCTAssertEqual(try store.poolSims().first?.phase, .settling)
        }
    }

    func testSlowPoolWorkRefreshesResourceSnapshotBeforeNextAction() throws {
        let harness = Harness()
        harness.reliability.cleanupMode = .enforce
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        var config = SimPoolConfig()
        config.maxSims = 2
        var completedCreates = 0
        let report = try engine.poolPass(config: config, demand: 2) { body in
            try body()
            // Read-only preflight also runs unlocked. Change the host only after
            // actual creation, so this tests the following action's fresh gates.
            if harness.sims.clonePlans.count > completedCreates {
                completedCreates = harness.sims.clonePlans.count
                harness.clock.advance(by: 6)
                harness.probe.update { $0.memoryPressure = .warn }
            }
        }
        XCTAssertEqual(completedCreates, 1, "the second clone cannot use the pre-operation healthy snapshot")
        XCTAssertEqual(report.createsDeferredForResources, 1)
        XCTAssertEqual(try store.poolSims().count, 1)
        let heldBoot = try engine.poolPass(config: config, demand: 1)
        XCTAssertEqual(heldBoot.bootsDeferredForResources.count, 1)
        harness.probe.update { $0.memoryPressure = .normal }
        _ = try engine.poolPass(config: config, demand: 1)
        XCTAssertEqual(try store.poolSims().first?.phase, .settling)
    }

    func testDemandFillsTheHostCapacityAndMemoryPressureStillStopsAdmission() throws {
        let harness = Harness()
        harness.reliability.cleanupMode = .enforce
        var pool: SimPoolConfig? = SimPoolConfig(warmMin: 0)
        HostSizing().apply(cpuCount: 10, totalMemoryBytes: 32 * gib, to: &harness.config, pool: &pool)
        let config = try XCTUnwrap(pool)
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        engine.pool = config
        _ = try engine.poolPass(config: config, demand: 0)
        XCTAssertTrue(try store.poolSims().isEmpty, "no demand, no boot")
        for _ in 0..<16 {
            _ = try engine.poolPass(config: config, demand: 4)
            harness.clock.advance(by: 30)
        }
        XCTAssertEqual(try store.poolSims().filter { $0.phase == .ready }.count, 4)
        XCTAssertEqual(try store.poolSims().count, harness.config.maxRunningSims)
        for index in 0..<4 {
            _ = try harness.submit(
                store, project: index % 2 == 0 ? "alpha" : "beta",
                resources: ResourceRequest(minSims: 1, memoryBytes: gib, memoryBytesPerSim: gib))
        }
        harness.probe.update { $0.memoryPressure = .warn }
        let held = try engine.tick()
        XCTAssertTrue(held.admitted.isEmpty)
        XCTAssertTrue(held.globalReasons.contains { $0.code == "memory_pressure" })
        harness.probe.update { $0.memoryPressure = .normal }
        let admitted = try engine.tick()
        XCTAssertEqual(admitted.admitted.count, 4, "\(admitted.plan.waiting)")
        XCTAssertEqual(try store.poolSims().filter { $0.phase == .leased }.count, 4)
        let fifth = try harness.submit(store, project: "gamma", resources: ResourceRequest(minSims: 1))
        let capped = try engine.tick()
        XCTAssertTrue(capped.admitted.isEmpty)
        XCTAssertTrue(
            capped.plan.waiting.contains { $0.jobID == fifth.id && $0.reasons.contains { $0.code == "sim_capacity" } })
        XCTAssertEqual(try store.activeJobs().count, 4)
    }
}
