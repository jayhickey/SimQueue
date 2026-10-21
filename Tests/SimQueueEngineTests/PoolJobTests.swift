// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

/// `--sims N` jobs take their sims from the pool when it's on.
final class PoolJobTests: XCTestCase {
    func testASimJobWaitsForASettledPoolSimThenLeasesItAndGivesItBackWhenItEnds() throws {
        let harness = Harness()
        harness.reliability.cleanupMode = .enforce  // the pool takes no host action in report-only
        harness.probe.update { host in
            host.cpuCount = 8
            host.load1 = 1
            host.load5 = 3
        }
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        var config = SimPoolConfig()
        engine.pool = config
        let job = try harness.submit(store, resources: ResourceRequest(minSims: 1))

        XCTAssertTrue(try engine.tick().admitted.isEmpty, "no ready pool sim yet")
        XCTAssertEqual(try engine.poolPass(config: config).actions, [.create], "queued demand drives the pool")
        _ = try engine.poolPass(config: config)  // boots; settling
        XCTAssertTrue(try engine.tick().admitted.isEmpty, "a settling sim isn't capacity")
        harness.clock.advance(by: 10)
        _ = try engine.poolPass(config: config)  // settled
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        let udids = try engine.poolSimUDIDs(jobID: job.id)
        XCTAssertEqual(udids.count, 1)
        guard udids.count == 1 else { return }
        XCTAssertTrue(udids[0].hasPrefix("FAKE-POOL-"))
        XCTAssertEqual(try engine.poolCapacity().busyRunning, 1)

        _ = try store.finish(jobID: job.id, result: .success, now: harness.clock.now())
        let report = try engine.poolPass(config: config)
        XCTAssertEqual(report.releasedFromJobs, udids)
        XCTAssertTrue(report.actions.isEmpty, "the completed job leaves a warm, ready sim")
        XCTAssertEqual(try store.poolSims().first?.phase, .ready)
        XCTAssertEqual(harness.sims.bootedUDIDs, udids, "no redundant boot on release")
        XCTAssertTrue(try engine.poolSimUDIDs(jobID: job.id).isEmpty)
    }

    func testWithThePoolOffSimCapacityStillComesFromTheBackend() throws {
        let harness = Harness()
        harness.reliability.cleanupMode = .enforce  // the pool takes no host action in report-only
        harness.sims.setPool(PoolSnapshot(idleRunning: 2))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let job = try harness.submit(store, resources: ResourceRequest(minSims: 1))
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        XCTAssertTrue(try store.poolSims().isEmpty)
    }

    private func startWithOneSim(_ harness: Harness, store: JobStore) throws -> (Engine, SimPoolConfig) {
        harness.reliability.cleanupMode = .enforce
        harness.probe.update { host in
            host.cpuCount = 8
            host.load1 = 1
            host.load5 = 3
        }
        let (engine, _, _) = try harness.start(store: store)
        var config = SimPoolConfig()
        config.maxSims = 1
        engine.pool = config
        return (engine, config)
    }

    /// Session 3: J-0006's sim was shut down at release while J-0007/J-0008 waited, and the
    /// replacement boot was then deferred by load for 9 minutes. With queued sim demand, an
    /// ended job's sim is handed off (kept booted, ready) instead.
    func testAReleasedSimIsHandedToAQueuedJobInsteadOfShutDown() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, config) = try startWithOneSim(harness, store: store)
        let first = try harness.submit(store, resources: ResourceRequest(minSims: 1))
        let second = try harness.submit(store, resources: ResourceRequest(minSims: 1))
        _ = try engine.poolPass(config: config)  // create
        _ = try engine.poolPass(config: config)  // boot
        harness.clock.advance(by: 10)
        _ = try engine.poolPass(config: config)  // settled
        XCTAssertEqual(try engine.tick().admitted, [first.id])
        let udid = try XCTUnwrap(try engine.poolSimUDIDs(jobID: first.id).first)

        _ = try store.finish(jobID: first.id, result: .success, now: harness.clock.now())
        let report = try engine.poolPass(config: config)
        XCTAssertEqual(report.releasedFromJobs, [udid])
        XCTAssertEqual(harness.sims.shutdownUDIDs, [], "not shut down: a queued job wants it")
        XCTAssertEqual(try store.poolSims().first?.phase, .ready)
        XCTAssertFalse(report.actions.contains { if case .boot = $0 { true } else { false } }, "\(report.actions)")
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "pool_handed_off" }.count, 1)
        XCTAssertEqual(try engine.tick().admitted, [second.id], "the next job gets it right away")
        XCTAssertEqual(try engine.poolSimUDIDs(jobID: second.id), [udid])

        // Nobody waiting: retain warm state until the configured idle deadline.
        _ = try store.finish(jobID: second.id, result: .success, now: harness.clock.now())
        _ = try engine.poolPass(config: config)
        XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty)
        XCTAssertEqual(try store.poolSims().first?.phase, .ready)
        harness.clock.advance(by: config.idleShutdownSeconds + 1)
        _ = try engine.poolPass(config: config)
        XCTAssertEqual(harness.sims.shutdownUDIDs, [udid])
        XCTAssertEqual(try store.poolSims().first?.phase, .shutdown)
        XCTAssertTrue(
            try store.liveResources(kinds: [.sim]).contains { $0.externalID == udid },
            "idle shutdown preserves owned simulator for later reuse")
    }

    func testEndedJobKeepsItsSimulatorUntilActiveOrOrphanedProcessesAreGone() throws {
        for orphaned in [false, true] {
            let harness = Harness()
            let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
            let (engine, config) = try startWithOneSim(harness, store: store)
            let first = try harness.submit(store)
            let second = try harness.submit(store)
            for _ in 0..<3 { _ = try engine.poolPass(config: config) }
            XCTAssertEqual(try engine.tick().admitted, [first.id])
            let udid = try XCTUnwrap(engine.poolSimUDIDs(jobID: first.id).first)
            harness.processes.spawn(950)
            let resource = try store.acquireResource(
                kind: .processGroup, externalID: "950", owner: .job(first.id),
                epoch: engine.epoch, identity: FakeProcessTable.defaultIdentity(950), now: harness.clock.now())
            _ = try store.finish(jobID: first.id, result: .success, now: harness.clock.now())
            if orphaned {
                try store.markResourceOrphaned(id: resource.id, reason: "cleanup pending", now: harness.clock.now())
            }
            XCTAssertTrue(try engine.poolPass(config: config).releasedFromJobs.isEmpty)
            XCTAssertEqual(try engine.poolSimUDIDs(jobID: first.id), [udid])
            XCTAssertTrue(try engine.tick().admitted.isEmpty, "the next job cannot share a still-used simulator")
            harness.processes.exit(950)
            XCTAssertEqual(try engine.poolPass(config: config).releasedFromJobs, [udid])
            XCTAssertEqual(try engine.tick().admitted, [second.id])
        }
    }

    /// A sim in use without a lease is tainted: never handed off, even with demand.
    func testATaintedSimIsNeverHandedOff() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, config) = try startWithOneSim(harness, store: store)
        let first = try harness.submit(store, resources: ResourceRequest(minSims: 1))
        _ = try harness.submit(store, resources: ResourceRequest(minSims: 1))
        _ = try engine.poolPass(config: config)
        _ = try engine.poolPass(config: config)
        harness.clock.advance(by: 10)
        _ = try engine.poolPass(config: config)
        XCTAssertEqual(try engine.tick().admitted, [first.id])
        var sim = try XCTUnwrap(try store.poolSims().first)
        sim.tainted = true
        try store.savePoolSim(sim)
        _ = try store.finish(jobID: first.id, result: .success, now: harness.clock.now())
        _ = try engine.poolPass(config: config)
        XCTAssertTrue(harness.sims.deletedUDIDs.contains(sim.udid), "tainted simulator is recycled by the worker")
        XCTAssertFalse(try store.poolSims().contains { $0.udid == sim.udid })
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "pool_handed_off" }.count, 0)
    }

    /// Session 3: J-0004 (40 GiB) made the pool boot a sim memory admission then refused.
    /// Queued jobs that don't fit the available memory (above the reserve) aren't demand.
    func testThePoolDoesNotCreateForAJobMemoryAdmissionWouldRefuse() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, config) = try startWithOneSim(harness, store: store)
        harness.probe.update { $0.availableMemoryBytes = 16 * ByteSize.gibibyte }
        let big = try harness.submit(
            store, resources: ResourceRequest(minSims: 1, memoryBytes: 40 * ByteSize.gibibyte))
        XCTAssertEqual(try engine.poolDemand(availableMemoryBytes: 16 * ByteSize.gibibyte), 0)
        XCTAssertEqual(try engine.poolDemand(), 1, "without a memory figure every queued sim counts")
        XCTAssertEqual(try engine.poolPass(config: config).actions, [], "no create for a job that can't be admitted")
        let waiting = try engine.tick()
        XCTAssertTrue(waiting.admitted.isEmpty)
        XCTAssertTrue(waiting.plan.waiting.flatMap(\.reasons).contains { $0.code == "never_fits" })
        _ = try store.cancel(jobID: big.id, now: harness.clock.now())
        _ = try harness.submit(store, resources: ResourceRequest(minSims: 1, memoryBytes: 2 * ByteSize.gibibyte))
        XCTAssertEqual(try engine.poolPass(config: config).actions, [.create], "a job that fits drives the pool")
    }
}
