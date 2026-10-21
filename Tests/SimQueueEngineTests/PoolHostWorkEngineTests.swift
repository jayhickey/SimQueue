// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueEngine
import SimQueueSim
import SimQueueStore
import XCTest

/// `poolPass(hostWork:)`: the create and the boot run inside `hostWork` (which the daemon
/// uses to drop its lock), and what they commit afterwards comes from a fresh read.
final class PoolHostWorkEngineTests: XCTestCase {
    private func engine(_ configure: (FakeSimBackend) -> Void = { _ in }) throws -> (Engine, JobStore) {
        let harness = Harness()
        harness.reliability.cleanupMode = .enforce  // the pool takes no host action in report-only
        configure(harness.sims)
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        return (engine, store)
    }

    /// CR on #61: a pass planned `boot(A, prewarm)` and `shutdown(B)` from one snapshot. While
    /// A's boot ran unlocked, `simq lease acquire` leased ready B. The shutdown must not act on
    /// the stale `ready` row: B stays leased and is never shut down.
    func testAShutdownPlannedBeforeAnUnlockedBootSkipsASimLeasedMeanwhile() throws {
        let harness = Harness()
        harness.reliability.cleanupMode = .enforce
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let now = harness.clock.now()
        harness.sims.setDevices([
            SimDevice(udid: "A", name: "simq-pool-1-1", isBooted: false),
            SimDevice(udid: "B", name: "simq-pool-1-2", isBooted: true),
        ])
        try store.savePoolSim(
            PoolSim(udid: "A", name: "simq-pool-1-1", phase: .shutdown, createdAt: now, prewarmPending: true))
        try store.savePoolSim(
            PoolSim(
                udid: "B", name: "simq-pool-1-2", phase: .ready, createdAt: now, lastUsedAt: now - 7200,
                phaseSince: now - 7200))
        var config = SimPoolConfig()
        config.maxSims = 2
        config.idleShutdownSeconds = 60
        config.settle.mode = .off

        var leased: PoolSim?
        let report = try engine.poolPass(config: config, demand: 0) { body in
            try body()
            leased = try engine.acquireManualLease(leaseID: "lease:ci-1", pid: nil)
        }
        XCTAssertEqual(report.actions, [.boot(udid: "A", reason: .prewarm), .shutdown(udid: "B")], "the race's plan")
        XCTAssertEqual(leased?.udid, "B", "the handler leased ready B mid-boot")
        let b = try XCTUnwrap(try store.poolSims().first { $0.udid == "B" })
        XCTAssertEqual(b.phase, .leased, "not overwritten with shutdown")
        XCTAssertEqual(b.leaseID, "lease:ci-1")
        XCTAssertFalse(harness.sims.shutdownUDIDs.contains("B"), "a leased sim is never shut down")
        let skipped = try store.auditEntries().filter { $0.type == Engine.staleActionAuditType }.compactMap(\.detail)
        XCTAssertEqual(skipped.count, 1, "\(skipped)")
        XCTAssertTrue(skipped.first?.contains("found leased lease=lease:ci-1") ?? false, "\(skipped)")
        XCTAssertEqual(try store.poolSims().first { $0.udid == "A" }?.phase, .settling, "A's boot still committed")
    }

    /// CR #61 follow-up 4: phase and lease alone miss a row that was used and handed back to
    /// the same phase while the pass ran unlocked (e.g. leased, released and pre-warmed back to
    /// ready). B's idle shutdown was planned from an old `lastUsedAt`; it must be skipped.
    func testAnIdleShutdownSkipsASimUsedMeanwhileEvenInTheSamePhase() throws {
        let harness = Harness()
        harness.reliability.cleanupMode = .enforce
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let now = harness.clock.now()
        harness.sims.setDevices([
            SimDevice(udid: "A", name: "simq-pool-1-1", isBooted: false),
            SimDevice(udid: "B", name: "simq-pool-1-2", isBooted: true),
        ])
        try store.savePoolSim(
            PoolSim(udid: "A", name: "simq-pool-1-1", phase: .shutdown, createdAt: now, prewarmPending: true))
        try store.savePoolSim(
            PoolSim(
                udid: "B", name: "simq-pool-1-2", phase: .ready, createdAt: now, lastUsedAt: now - 7200,
                phaseSince: now - 7200))
        var config = SimPoolConfig()
        config.maxSims = 2
        config.idleShutdownSeconds = 60
        config.settle.mode = .off

        let report = try engine.poolPass(config: config, demand: 0) { body in
            try body()
            harness.clock.advance(by: 5)
            var b = try XCTUnwrap(try store.poolSims().first { $0.udid == "B" })
            b.lastUsedAt = harness.clock.now()
            b.phaseSince = harness.clock.now()
            try store.savePoolSim(b)
        }
        XCTAssertEqual(report.actions, [.boot(udid: "A", reason: .prewarm), .shutdown(udid: "B")], "the race's plan")
        XCTAssertEqual(try store.poolSims().first { $0.udid == "B" }?.phase, .ready, "B stays ready")
        XCTAssertFalse(harness.sims.shutdownUDIDs.contains("B"), "a sim used meanwhile isn't idle-shut-down")
        let skipped = try store.auditEntries().filter { $0.type == Engine.staleActionAuditType }.compactMap(\.detail)
        XCTAssertEqual(skipped.count, 1, "\(skipped)")
        XCTAssertTrue(skipped.first?.contains("found ready lease=none phase_since=") ?? false, "\(skipped)")
    }

    func testIdleShutdownBlocksNewLeasesBeforeHostWorkAndDoesNotRewriteRemovedRows() throws {
        let harness = Harness()
        harness.reliability.cleanupMode = .enforce
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        let now = harness.clock.now()
        harness.sims.setDevices([SimDevice(udid: "B", name: "simq-pool-1-2", isBooted: true)])
        try store.savePoolSim(
            PoolSim(
                udid: "B", name: "simq-pool-1-2", phase: .ready, createdAt: now,
                lastUsedAt: now - 7200, phaseSince: now - 7200))
        var config = SimPoolConfig()
        config.idleShutdownSeconds = 60
        var calls = 0
        let report = try engine.poolPass(config: config, demand: 0) { body in
            calls += 1
            XCTAssertEqual(try store.poolSims().first?.phase, .shutdown, "barrier exists before unlocking")
            XCTAssertNil(
                try engine.acquireManualLease(leaseID: "lease:late", pid: nil),
                "never grant a simulator being shut down")
            try body()
            try store.deletePoolSim(udid: "B")
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(report.actions, [.shutdown(udid: "B")])
        XCTAssertEqual(harness.sims.shutdownUDIDs, ["B"])
        XCTAssertTrue(try store.poolSims().isEmpty, "completion cannot restore a row removed during host work")
    }

    private var poolConfig: SimPoolConfig {
        var pool = SimPoolConfig()
        pool.maxSims = 1
        pool.maxConcurrentBoots = 1
        pool.settle.mode = .off
        return pool
    }

    func testCreateAndBootRunInsideHostWorkWithMeasuredDurations() throws {
        let (engine, store) = try engine {
            $0.createDelaySeconds = 0.2
            $0.bootDelaySeconds = 0.2
        }
        var calls = 0
        let hostWork: PoolHostWork = { body in
            calls += 1
            try body()
        }
        _ = try engine.poolPass(config: poolConfig, demand: 1, hostWork: hostWork)
        XCTAssertEqual(calls, 2, "read-only preflight and create both ran inside hostWork")
        _ = try engine.poolPass(config: poolConfig, demand: 1, hostWork: hostWork)
        XCTAssertEqual(calls, 3, "the boot also ran inside hostWork")
        XCTAssertEqual(try store.poolSims().map(\.phase), [.settling], "booted, then settling")
        for type in ["pool_created", "pool_booted"] {
            let detail = try XCTUnwrap(try store.auditEntries().first { $0.type == type }?.detail)
            let ms = try XCTUnwrap(
                detail.range(of: "duration_ms=").map { Int(detail[$0.upperBound...].prefix { $0.isNumber }) } ?? nil,
                detail)
            XCTAssertGreaterThanOrEqual(ms, 180, "\(type): \(detail)")
        }
    }

    func testABootWhoseRowChangedMeanwhileIsNotCommitted() throws {
        let (engine, store) = try engine()
        _ = try engine.poolPass(config: poolConfig, demand: 1)
        let udid = try XCTUnwrap(try store.poolSims().first?.udid)
        // While the boot runs unlocked, something else drops the row (a restart reconcile,
        // say). The pass must not write a stale `ready` row back.
        _ = try engine.poolPass(config: poolConfig, demand: 1) { body in
            try body()
            try store.deletePoolSim(udid: udid)
        }
        XCTAssertTrue(try store.poolSims().isEmpty)
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "pool_boot_superseded" }.count, 1)
        XCTAssertTrue(try store.auditEntries().filter { $0.type == "pool_booted" }.isEmpty)
    }

    func testACreateThatBootsTakesTheBootSlot() throws {
        // simslim clone boots the template: with one boot slot, a create and a boot never
        // run in the same pass, and no create starts while a sim boots or settles.
        let (engine, store) = try engine { $0.createBoots = true }
        var pool = poolConfig
        pool.maxSims = 2
        pool.settle.mode = .load
        pool.settle.loadBelow = -1  // never settles: the first sim keeps its slot
        pool.settle.maxWaitSeconds = 3600
        _ = try engine.poolPass(config: pool, demand: 2)
        XCTAssertEqual(try store.poolSims().count, 1, "one create, not two, with one boot slot")
        _ = try engine.poolPass(config: pool, demand: 2)
        XCTAssertEqual(try store.poolSims().map(\.phase), [.settling], "the boot took the slot")
        _ = try engine.poolPass(config: pool, demand: 2)
        XCTAssertEqual(try store.poolSims().count, 1, "no create while the first sim settles")
    }

    func testRecoveredPoolDoesNotWaitForHistoricalLoadOrBypassAdmissionGates() throws {
        for gate in ["none", "max_load5", "pressure"] {
            let harness = Harness(preserveAdmissionPacing: true)
            harness.reliability.cleanupMode = .enforce
            if gate == "max_load5" { harness.config.loadThrottle.maxLoad5 = 25 }
            var settings: SimPoolConfig? = SimPoolConfig()
            HostSizing(maxRunningSims: 1).apply(
                cpuCount: 10, totalMemoryBytes: 32 * gib, to: &harness.config, pool: &settings)
            var pool = try XCTUnwrap(settings)
            pool.settle.onCap = .fail
            let store = try JobStore(path: ":memory:")
            let (engine, _, _) = try harness.start(store: store)
            engine.pool = pool
            _ = try engine.poolPass(config: pool, demand: 1)
            _ = try engine.poolPass(config: pool, demand: 1)
            let udid = try XCTUnwrap(try store.poolSims().first?.udid)
            XCTAssertEqual(try store.poolSims().first?.phase, .settling, "boot status completed before settling")
            harness.clock.advance(by: 100)
            harness.probe.update {
                $0.load1 = 20.01; $0.load5 = 31
            }
            _ = try engine.poolPass(config: pool, demand: 1)
            XCTAssertEqual(try store.poolSims().first?.phase, .settling, "above recovery still holds")
            harness.probe.update {
                $0.load1 = 20
                if gate == "pressure" { $0.memoryPressure = .warn }
            }
            let recovered = try engine.poolPass(config: pool, demand: 1)
            XCTAssertEqual(recovered.actions, [.settled(udid: udid, capHit: false, waitedSeconds: 100)])
            XCTAssertEqual(try store.poolSims().first?.phase, .ready, "load5 history cannot strand default settling")
            let first = try harness.submit(store)
            let next = try harness.submit(store, resources: ResourceRequest(minSims: 0))
            let tick = try engine.tick()
            if gate == "none" {
                XCTAssertEqual(tick.admitted, [first.id])
                XCTAssertEqual(try engine.poolSimUDIDs(jobID: first.id), [udid])
                XCTAssertTrue(try engine.tick().admitted.isEmpty, "recovery does not bypass one-second pacing")
                harness.clock.advance(by: 1)
                XCTAssertEqual(try engine.tick().admitted, [next.id])
            } else {
                XCTAssertTrue(tick.admitted.isEmpty, gate)
                XCTAssertFalse(tick.globalReasons.isEmpty, gate)
                XCTAssertEqual(try store.job(id: first.id)?.state, .queued)
                XCTAssertEqual(try store.job(id: next.id)?.state, .queued)
            }
            XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty, "no failed-settle shutdown after healthy recovery")
        }
    }

    func testExplicitLoad5SettingKeepsASimulatorSettlingAfterLoad1Recovers() throws {
        let harness = Harness()
        harness.reliability.cleanupMode = .enforce
        var sizing = HostSizing(maxRunningSims: 1)
        sizing.settleLoadBelowIsExplicit = true
        var settings: SimPoolConfig? = SimPoolConfig()
        sizing.apply(cpuCount: 10, totalMemoryBytes: 32 * gib, to: &harness.config, pool: &settings)
        var pool = try XCTUnwrap(settings)
        pool.settle.onCap = .fail
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        engine.pool = pool
        _ = try engine.poolPass(config: pool, demand: 1)
        _ = try engine.poolPass(config: pool, demand: 1)
        let udid = try XCTUnwrap(try store.poolSims().first?.udid)
        harness.probe.update {
            $0.load1 = 11; $0.load5 = 31
        }
        harness.clock.advance(by: 179)
        _ = try engine.poolPass(config: pool, demand: 1)
        XCTAssertEqual(try store.poolSims().first?.phase, .settling)
        harness.clock.advance(by: 1)
        let capped = try engine.poolPass(config: pool, demand: 1)
        XCTAssertEqual(capped.actions, [.settleFailed(udid: udid, waitedSeconds: 180)])
        XCTAssertEqual(try store.poolSims().first?.phase, .shutdown)
        XCTAssertEqual(harness.sims.shutdownUDIDs, [udid], "explicit fail policy still applies at its cap")
    }
}
