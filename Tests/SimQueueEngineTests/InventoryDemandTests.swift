// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueEngine
import SimQueueSim
import SimQueueStore
import XCTest

/// Idle admission and pool bookkeeping must not launch simulator inventory helpers.
/// Actual host actions and ownership reconciliation still need fresh observations.
final class InventoryDemandTests: XCTestCase {
    private final class InventoryBackend: SimBackend, @unchecked Sendable {
        let kind: BackendKind = .fake
        let base = FakeSimBackend()
        var listCalls = 0
        var snapshotCalls = 0
        var beforeList: (() -> Void)?
        var beforeSnapshot: (() -> Void)?

        func listDevices() throws -> [SimDevice] {
            listCalls += 1
            beforeList?()
            return try base.listDevices()
        }
        func poolSnapshot() throws -> PoolSnapshot {
            snapshotCalls += 1
            beforeSnapshot?()
            return try base.poolSnapshot()
        }
        func deleteDevice(udid: String) throws { try base.deleteDevice(udid: udid) }
        func createDevice(name: String) throws -> SimDevice { try base.createDevice(name: name) }
        func bootDevice(udid: String) throws { try base.bootDevice(udid: udid) }
        func shutdownDevice(udid: String) throws { try base.shutdownDevice(udid: udid) }
    }

    private func start() throws -> (Harness, InventoryBackend, JobStore, Engine) {
        let harness = Harness()
        harness.config.maxRunningPerProject = 1
        harness.reliability.cleanupMode = .enforce
        let backend = InventoryBackend()
        var environment = harness.environment
        environment.sims = backend
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try Engine.start(
            store: store, environment: environment, config: harness.config, reliability: harness.reliability,
            ownerID: "inventory-test", pid: 1)
        XCTAssertGreaterThan(backend.listCalls, 0, "startup still inspects actual simulator inventory")
        backend.listCalls = 0
        return (harness, backend, store, engine)
    }

    private var poolConfig: SimPoolConfig {
        var config = SimPoolConfig()
        config.mode = .active
        config.externalSimPatterns = ["Other Tool *"]
        return config
    }

    func testIdlePoolDoesNotListButFullWatchdogStillDoes() throws {
        let (harness, backend, _, engine) = try start()
        backend.base.listFailure = .timedOut("simctl list devices")
        for _ in 0..<12 {
            let report = try engine.poolPass(config: poolConfig, demand: 0)
            XCTAssertTrue(report.actions.isEmpty)
            harness.clock.advance(by: 5)
        }
        XCTAssertEqual(backend.listCalls, 0)
        XCTAssertNoThrow(try engine.watchdogPass(.light, config: WatchdogConfig()))
        XCTAssertEqual(backend.listCalls, 0)
        XCTAssertThrowsError(try engine.watchdogPass(.full, config: WatchdogConfig()))
        XCTAssertEqual(backend.listCalls, 1, "full ownership reconciliation never uses stale inventory")
    }

    func testResourceDeferredAndReportOnlyCreatesDoNotList() throws {
        let (harness, backend, store, engine) = try start()
        backend.base.listFailure = .timedOut("simctl list devices")
        harness.probe.update { $0.availableMemoryBytes = 0 }
        let held = try engine.poolPass(config: poolConfig, demand: 1)
        XCTAssertEqual(held.actions, [.create])
        XCTAssertEqual(held.createsDeferredForResources, 1)
        XCTAssertTrue(held.failures.isEmpty)
        var reporting = poolConfig
        reporting.mode = .reportOnly
        let report = try engine.poolPass(config: reporting, demand: 1)
        XCTAssertEqual(report.wouldExecute, [.create])
        XCTAssertEqual(backend.listCalls, 0)
        XCTAssertTrue(try store.poolSims().isEmpty)
    }

    func testNewCreateChecksExternalInventoryAndRetriesWithFreshState() throws {
        let (_, backend, store, engine) = try start()
        backend.base.setDevices([SimDevice(udid: "EXT", name: "Other Tool 1", isBooted: true)])
        let held = try engine.poolPass(config: poolConfig, demand: 1)
        XCTAssertEqual(held.createsDeferredForExternal, 1)
        XCTAssertTrue(try store.poolSims().isEmpty)
        XCTAssertEqual(backend.listCalls, 1, "the blocked pass observes the external simulator once")
        let observationsBeforeRetry = backend.listCalls
        backend.base.setDevices([])
        let created = try engine.poolPass(config: poolConfig, demand: 1)
        XCTAssertTrue(created.failures.isEmpty)
        XCTAssertEqual(try store.poolSims().count, 1)
        XCTAssertGreaterThan(
            backend.listCalls, observationsBeforeRetry,
            "a later pass must freshly observe the external simulator stopping")
    }

    func testSecondBootRechecksExternalInventoryAfterSlowHostWork() throws {
        let (harness, backend, store, engine) = try start()
        for udid in ["A", "B"] {
            try store.savePoolSim(
                PoolSim(udid: udid, name: "simq-pool-1-\(udid)", phase: .shutdown, createdAt: harness.clock.now()))
        }
        backend.base.setDevices([
            SimDevice(udid: "A", name: "simq-pool-1-A", isBooted: false),
            SimDevice(udid: "B", name: "simq-pool-1-B", isBooted: false),
        ])
        var config = poolConfig
        config.maxConcurrentBoots = 2
        var hostCalls = 0
        let report = try engine.poolPass(config: config, demand: 2) { body in
            try body()
            hostCalls += 1
            harness.clock.advance(by: 6)
            backend.base.setDevices(
                try backend.base.listDevices() + [SimDevice(udid: "EXT", name: "Other Tool 1", isBooted: true)])
        }
        XCTAssertEqual(report.actions, [.boot(udid: "B", reason: .demand), .boot(udid: "A", reason: .demand)])
        XCTAssertEqual(hostCalls, 1)
        XCTAssertEqual(backend.base.bootedUDIDs, ["B"])
        XCTAssertEqual(report.bootsDeferredForExternal, ["A"])
        XCTAssertEqual(backend.listCalls, 2, "the first boot's inventory cannot authorize the next boot")
        XCTAssertEqual(try store.poolSims().first { $0.udid == "A" }?.phase, .shutdown)
    }

    func testSlowInventoryCannotAuthorizeCreateAfterResourcePressureChanges() throws {
        let (harness, backend, store, engine) = try start()
        backend.beforeList = {
            harness.clock.advance(by: 6)
            harness.probe.update { $0.memoryPressure = .critical }
        }
        let report = try engine.poolPass(config: poolConfig, demand: 1)
        XCTAssertEqual(report.createsDeferredForResources, 1)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(try store.poolSims().isEmpty)
        XCTAssertEqual(backend.listCalls, 1)
    }

    func testSlowInventoryCannotAuthorizeCreateAfterSwapGrowthSpikes() throws {
        let (harness, backend, store, engine) = try start()
        _ = try engine.tick()  // the normal scheduling pass records the pre-inventory baseline
        backend.beforeList = {
            harness.clock.advance(by: 6)
            harness.probe.update { $0.swapUsedBytes = gib }
        }
        let report = try engine.poolPass(config: poolConfig, demand: 1)
        XCTAssertEqual(report.createsDeferredForResources, 1)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(try store.poolSims().isEmpty)
        XCTAssertEqual(backend.listCalls, 1)
        XCTAssertGreaterThan(
            engine.swapTracker.growthBytesPerMinute, harness.config.swapGrowthLimitBytesPerMinute,
            "the refreshed host sample must update the shared growth gate before create")
    }

    func testNoPoolIdleAndSimulatorFreeJobsDoNotQueryBackend() throws {
        let (harness, backend, store, engine) = try start()
        XCTAssertTrue(try engine.tick().admitted.isEmpty)
        let job = try harness.submit(store, resources: ResourceRequest(minSims: 0))
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        XCTAssertEqual(backend.snapshotCalls, 0)
        XCTAssertEqual(backend.listCalls, 0)
    }

    func testNoPoolSimulatorDemandRefreshesInventoryAndActiveJobsKeepConcurrency() throws {
        let (harness, backend, store, engine) = try start()
        backend.base.setPool(PoolSnapshot(idleRunning: 1))
        let simJob = try harness.submit(store)
        let admitted = try engine.tick()
        XCTAssertEqual(admitted.admitted, [simJob.id])
        XCTAssertEqual(admitted.plan.admissions.first?.fromIdleRunning, 1)
        XCTAssertEqual(backend.snapshotCalls, 1)
        let simFree = try harness.submit(store, resources: ResourceRequest(minSims: 0))
        let held = try engine.tick()
        XCTAssertTrue(held.admitted.isEmpty)
        XCTAssertEqual(held.plan.waiting.first?.reasons.map(\.code), ["project_cap"])
        XCTAssertEqual(backend.snapshotCalls, 1, "active grants do not force another inventory query")
        _ = try store.finish(jobID: simJob.id, result: .success, now: harness.clock.now())
        XCTAssertEqual(try engine.tick().admitted, [simFree.id])
        XCTAssertEqual(backend.snapshotCalls, 1)
    }

    func testSlowLegacyInventoryRefreshesCallerResourceSampleBeforeAdmission() throws {
        let (harness, backend, store, engine) = try start()
        backend.base.setPool(PoolSnapshot(idleRunning: 1))
        let callerHost = try harness.probe.sample(now: harness.clock.now())
        _ = try harness.submit(store)
        backend.beforeSnapshot = {
            harness.clock.advance(by: 6)
            harness.probe.update { $0.memoryPressure = .critical }
        }
        let result = try engine.tick(host: callerHost)
        XCTAssertTrue(result.admitted.isEmpty)
        XCTAssertEqual(result.host.memoryPressure, .critical)
        XCTAssertEqual(result.host.sampledAt, harness.clock.now())
        XCTAssertEqual(result.plan.waiting.first?.reasons.map(\.code), ["memory_pressure"])
    }

    func testSlowLegacyInventoryDoesNotAdmitAJobWhoseQueueDeadlinePassed() throws {
        let (harness, backend, store, engine) = try start()
        backend.base.setPool(PoolSnapshot(idleRunning: 1))
        let job = try harness.submit(store, queueTimeout: 1)
        backend.beforeSnapshot = { harness.clock.advance(by: 6) }
        let result = try engine.tick()
        XCTAssertTrue(result.admitted.isEmpty)
        XCTAssertEqual(result.timeouts.expired, [job.id])
        XCTAssertEqual(try store.job(id: job.id)?.state, .expired)
    }
}
