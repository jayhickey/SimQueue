// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

@testable import SimQueueEngine

/// A queued simulator-free command must not wait out its timeout while unused owned
/// simulators keep the host under pressure. All host effects here use the fake backend.
final class PoolPressureReclaimTests: XCTestCase {
    private func setup() throws -> (Harness, JobStore, Engine, SimPoolConfig) {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        var config = SimPoolConfig(maxSims: 4, warmMin: 4)
        config.settle.mode = .off
        engine.pool = config
        return (harness, store, engine, config)
    }

    @discardableResult
    private func seed(
        _ id: String, _ harness: Harness, _ store: JobStore, _ engine: Engine,
        phase: PoolSimPhase = .ready, name: String? = nil, owned: Bool = true,
        lease: String? = nil, tainted: Bool = false, state: String? = nil
    ) throws -> PoolSim {
        let name = name ?? "simq-pool-1-\(id)"
        let sim = PoolSim(
            udid: id, name: name, phase: phase, createdAt: harness.clock.now(),
            lastUsedAt: harness.clock.now(), phaseSince: harness.clock.now(), leaseID: lease,
            prewarmPending: phase == .shutdown, tainted: tainted)
        try store.savePoolSim(sim)
        let device = SimDevice(udid: id, name: name, isBooted: phase != .shutdown, state: state)
        harness.sims.setDevices(try harness.sims.listDevices() + [device])
        if owned {
            try store.acquireResource(
                kind: .sim, externalID: id, owner: .pool, epoch: engine.epoch, now: harness.clock.now())
        }
        return sim
    }

    func testQueuedBuildCanProceedBeforeItsTimeoutAfterIdleSimulatorPressureRelief() throws {
        let (harness, store, engine, config) = try setup()
        try seed("A", harness, store, engine)
        let job = try harness.submit(store, resources: ResourceRequest(minSims: 0), queueTimeout: 30)
        harness.probe.update { $0.memoryPressure = .warn }
        XCTAssertTrue(try engine.tick().admitted.isEmpty)
        XCTAssertEqual(try store.job(id: job.id)?.state, .queued)

        _ = try engine.poolPass(config: config)
        XCTAssertEqual(harness.sims.shutdownUDIDs, ["A"], "queued build needs no simulator, but needs memory relief")
        XCTAssertEqual(try store.poolSims().first?.phase, .shutdown)
        XCTAssertTrue(try store.liveResources(kinds: [.sim]).contains { $0.externalID == "A" })
        harness.probe.update { $0.memoryPressure = .normal }
        harness.clock.advance(by: 1)
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        XCTAssertEqual(try store.job(id: job.id)?.attempt, 0)
    }

    func testPressureOverridesWarmMinimumIdleAgeAndSimulatorDemandWithoutRebooting() throws {
        let (harness, store, engine, config) = try setup()
        try seed("A", harness, store, engine)
        try seed("B", harness, store, engine, phase: .shutdown)
        harness.probe.update { $0.memoryPressure = .warn }
        _ = try engine.poolPass(config: config, demand: 4)
        XCTAssertEqual(harness.sims.shutdownUDIDs, ["A"], "not thirty minutes later or after queued demand disappears")
        XCTAssertTrue(harness.sims.bootedUDIDs.isEmpty, "warm_min, demand and prewarm cannot refill under pressure")
        XCTAssertEqual(try store.poolSims().count, 2, "no extra clone is created")
        XCTAssertTrue(try store.pendingActionIntents().isEmpty, "confirmed pressure shutdown completes its intent")
    }

    func testPersistentPressureReclaimsMultipleIdleSimulatorsInOnePass() throws {
        let (harness, store, engine, config) = try setup()
        for id in ["A", "B", "C"] { try seed(id, harness, store, engine) }
        harness.probe.update { $0.memoryPressure = .critical }
        let report = try engine.poolPass(config: config, demand: 3)
        XCTAssertEqual(harness.sims.shutdownUDIDs, ["A", "B", "C"])
        XCTAssertEqual(shutdowns(report.actions), ["A", "B", "C"], "report retains every completed candidate")
        XCTAssertEqual(try store.poolSims().map(\.phase), [.shutdown, .shutdown, .shutdown])
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "pool_pressure_shutdown" }.count, 3)
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
        XCTAssertTrue(harness.sims.bootedUDIDs.isEmpty)
        XCTAssertTrue(harness.sims.clonePlans.isEmpty)
        _ = try engine.poolPass(config: config, demand: 3)
        XCTAssertEqual(harness.sims.shutdownUDIDs, ["A", "B", "C"], "already shut down is not reclaimed twice")
    }

    private func shutdowns(_ actions: [SimPoolAction]) -> [String] {
        actions.compactMap { if case .shutdown(let udid) = $0 { udid } else { nil } }
    }

    func testPressureClearingAfterAShutdownStopsImmediatelyWithRemainingSimsReady() throws {
        for clearedAfter in [1, 2] {
            let (harness, store, engine, config) = try setup()
            for id in ["A", "B", "C"] { try seed(id, harness, store, engine) }
            harness.probe.update { $0.memoryPressure = .warn }
            var callsAfterRelief = 0
            let report = try engine.poolPass(config: config, demand: 3) { body in
                if harness.sims.shutdownUDIDs.count == clearedAfter { callsAfterRelief += 1 }
                try body()
                if harness.sims.shutdownUDIDs.count == clearedAfter {
                    harness.probe.update { $0.memoryPressure = .normal }
                }
            }
            let expected = Array(["A", "B", "C"].prefix(clearedAfter))
            XCTAssertEqual(harness.sims.shutdownUDIDs, expected)
            XCTAssertEqual(shutdowns(report.actions), expected)
            XCTAssertEqual(try store.poolSims().filter { $0.phase == .ready }.count, 3 - clearedAfter)
            XCTAssertEqual(callsAfterRelief, 1, "only verification of the last shutdown; no next candidate inventory")
            XCTAssertTrue(try store.pendingActionIntents().isEmpty)
        }
    }

    func testPressureClearingDuringNextCandidateInventoryStopsBeforeItsShutdown() throws {
        let (harness, store, engine, config) = try setup()
        for id in ["A", "B", "C"] { try seed(id, harness, store, engine) }
        harness.probe.update { $0.memoryPressure = .warn }
        var clearedBetweenCandidates = false
        let report = try engine.poolPass(config: config, demand: 3) { body in
            try body()
            if harness.sims.shutdownUDIDs == ["A"], try store.pendingActionIntents().isEmpty {
                clearedBetweenCandidates = true
                harness.probe.update { $0.memoryPressure = .normal }
            }
        }
        XCTAssertTrue(clearedBetweenCandidates, "first intent confirmed before the next unlocked inventory")
        XCTAssertEqual(harness.sims.shutdownUDIDs, ["A"])
        XCTAssertEqual(shutdowns(report.actions), ["A"])
        XCTAssertEqual(try store.poolSims().filter { $0.phase == .ready }.count, 2)
    }

    func testDryRunReportsAllVerifiedCandidatesWithoutMutationAndDeduplicatesAudits() throws {
        let (harness, store, engine, original) = try setup()
        for id in ["A", "B", "C"] { try seed(id, harness, store, engine) }
        var config = original
        config.mode = .reportOnly
        harness.probe.update { $0.memoryPressure = .warn }
        for _ in 0..<2 {
            let report = try engine.poolPass(config: config, demand: 3)
            XCTAssertEqual(shutdowns(report.actions), ["A", "B", "C"])
            XCTAssertEqual(shutdowns(report.wouldExecute), ["A", "B", "C"])
        }
        XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty)
        XCTAssertEqual(try store.poolSims().filter { $0.phase == .ready }.count, 3)
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
        XCTAssertEqual(
            try store.auditEntries().filter {
                $0.type == "pool_would_execute" && ($0.detail?.hasPrefix("pressure-shutdown(") ?? false)
            }.count, 3)
    }

    func testFailedFirstShutdownStopsTheBatchAndKeepsLaterCandidatesReady() throws {
        enum Injected: Error { case unavailable }
        let (harness, store, engine, config) = try setup()
        for id in ["A", "B", "C"] { try seed(id, harness, store, engine) }
        harness.probe.update { $0.memoryPressure = .warn }
        let report = try engine.poolPass(config: config, demand: 3) { body in
            if try store.poolSims().first(where: { $0.udid == "A" })?.phase == .shutdown {
                throw Injected.unavailable
            }
            try body()
        }
        XCTAssertFalse(report.failures.isEmpty)
        XCTAssertEqual(shutdowns(report.actions), ["A"])
        XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty)
        XCTAssertEqual(try store.pendingActionIntents().count, 1, "failed target remains fenced")
        XCTAssertEqual(try store.poolSims().filter { $0.phase == .ready }.map(\.udid), ["B", "C"])
    }

    func testShutdownReturningWithTargetStillBootedRestoresReadyAndStopsTheBatch() throws {
        let (harness, store, engine, config) = try setup()
        for id in ["A", "B", "C"] { try seed(id, harness, store, engine) }
        harness.probe.update { $0.memoryPressure = .warn }
        var skippedShutdown = false
        let report = try engine.poolPass(config: config, demand: 3) { body in
            if !skippedShutdown, try store.poolSims().first(where: { $0.udid == "A" })?.phase == .shutdown {
                skippedShutdown = true
                return
            }
            try body()
        }
        XCTAssertTrue(skippedShutdown, "simulate a shutdown command returning without changing the device")
        XCTAssertEqual(shutdowns(report.actions), ["A"])
        XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty)
        XCTAssertEqual(try store.poolSims().filter { $0.phase == .ready }.count, 3)
        XCTAssertTrue(try store.pendingActionIntents().isEmpty, "Booted verification safely restored the first row")
    }

    func testLaterCandidateLeasedOrOwnershipReleasedDuringEarlierShutdownIsSkipped() throws {
        for protection in ["lease", "released-ownership"] {
            let (harness, store, engine, config) = try setup()
            for id in ["A", "B", "C"] { try seed(id, harness, store, engine) }
            harness.probe.update { $0.memoryPressure = .warn }
            var protectedLaterCandidate = false
            let report = try engine.poolPass(config: config, demand: 3) { body in
                try body()
                if !protectedLaterCandidate, harness.sims.shutdownUDIDs == ["A"] {
                    protectedLaterCandidate = true
                    if protection == "lease" {
                        XCTAssertEqual(try engine.acquireManualLease(leaseID: "lease:concurrent", pid: nil)?.udid, "B")
                    } else {
                        let owner = try XCTUnwrap(try store.liveResources(kinds: [.sim]).first { $0.externalID == "B" })
                        XCTAssertTrue(
                            try store.releaseResource(
                                id: owner.id, generation: owner.generation, now: harness.clock.now()))
                    }
                }
            }
            XCTAssertTrue(protectedLaterCandidate)
            XCTAssertEqual(harness.sims.shutdownUDIDs, ["A", "C"], protection)
            XCTAssertEqual(shutdowns(report.actions), ["A", "C"], protection)
            XCTAssertEqual(
                try store.poolSims().first { $0.udid == "B" }?.phase, protection == "lease" ? .leased : .ready)
            XCTAssertTrue(try store.pendingActionIntents().isEmpty)
        }
    }

    func testNewPendingIntentAfterFirstShutdownStopsBeforeTheNextCandidate() throws {
        let (harness, store, engine, config) = try setup()
        for id in ["A", "B", "C"] { try seed(id, harness, store, engine) }
        harness.probe.update { $0.memoryPressure = .warn }
        var interveningIntent: ActionIntent?
        let report = try engine.poolPass(config: config, demand: 3) { body in
            try body()
            if interveningIntent == nil, harness.sims.shutdownUDIDs == ["A"], try store.pendingActionIntents().isEmpty {
                interveningIntent = try store.recordActionIntent(
                    ActionIntent(
                        target: .path("/fake/other-operation"), auditType: "pending_test_action", detail: "pending"),
                    now: harness.clock.now())
            }
        }
        XCTAssertNotNil(interveningIntent)
        XCTAssertEqual(harness.sims.shutdownUDIDs, ["A"])
        XCTAssertEqual(shutdowns(report.actions), ["A"])
        XCTAssertEqual(try store.poolSims().filter { $0.phase == .ready }.count, 2)
        XCTAssertEqual(try store.pendingActionIntents().map(\.id), [try XCTUnwrap(interveningIntent).id])
    }

    func testNoCreateBootOrPrewarmUnderPressureWithoutReadyCandidates() throws {
        for empty in [true, false] {
            let (harness, store, engine, config) = try setup()
            if !empty { try seed("A", harness, store, engine, phase: .shutdown) }
            harness.probe.update { $0.memoryPressure = .warn }
            _ = try engine.poolPass(config: config, demand: 4)
            XCTAssertEqual(try store.poolSims().count, empty ? 0 : 1)
            XCTAssertTrue(harness.sims.bootedUDIDs.isEmpty)
            XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
            XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty)
            XCTAssertTrue(try store.pendingActionIntents().isEmpty)
        }
    }

    func testSettlingCanCompleteBeforeVerifiedReadyOnlyPressureReclaim() throws {
        let (harness, store, engine, _) = try setup()
        try seed("A", harness, store, engine, phase: .settling)
        var config = SimPoolConfig(maxSims: 1)
        config.settle.mode = .off
        harness.probe.update { $0.memoryPressure = .warn }
        let report = try engine.poolPass(config: config, demand: 1)
        XCTAssertEqual(
            report.actions,
            [.settled(udid: "A", capHit: false, waitedSeconds: 0), .shutdown(udid: "A")],
            "settling is not frozen; pressure relief requires the subsequent genuine ready transition")
        XCTAssertEqual(try store.poolSims().first?.phase, .shutdown)
        XCTAssertEqual(harness.sims.shutdownUDIDs, ["A"])
        XCTAssertTrue(harness.sims.bootedUDIDs.isEmpty)
        XCTAssertTrue(harness.sims.clonePlans.isEmpty)
    }

    func testConfiguredSettleFailureStillShutsDownAtItsDeadlineUnderPressure() throws {
        let (harness, store, engine, _) = try setup()
        try seed("A", harness, store, engine, phase: .settling)
        var config = SimPoolConfig(maxSims: 1)
        config.settle.mode = .load
        config.settle.loadBelow = -1
        config.settle.maxWaitSeconds = 1
        config.settle.onCap = .fail
        harness.clock.advance(by: 1)
        harness.probe.update { $0.memoryPressure = .warn }
        let report = try engine.poolPass(config: config, demand: 1)
        XCTAssertTrue(report.actions.contains(.settleFailed(udid: "A", waitedSeconds: 1)))
        XCTAssertEqual(try store.poolSims().first?.phase, .shutdown)
        XCTAssertEqual(harness.sims.shutdownUDIDs, ["A"], "existing explicit settle-failure cleanup must progress")
        XCTAssertTrue(harness.sims.bootedUDIDs.isEmpty)
        XCTAssertTrue(harness.sims.clonePlans.isEmpty)
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "settle_cap_hit" }.count, 1)
    }

    func testStuckBootIsCleanedUpUnderPressureWithoutCreatingOrBootingAReplacement() throws {
        let (harness, store, engine, _) = try setup()
        try seed("A", harness, store, engine, phase: .booting)
        var config = SimPoolConfig(maxSims: 1)
        config.bootTimeoutSeconds = 1
        harness.clock.advance(by: 1)
        harness.probe.update { $0.memoryPressure = .warn }
        _ = try engine.poolPass(config: config, demand: 1)
        XCTAssertEqual(harness.sims.deletedUDIDs, ["A"], "existing stuck-boot recovery still executes")
        XCTAssertTrue(try store.poolSims().isEmpty)
        XCTAssertTrue(try store.liveResources(kinds: [.sim]).isEmpty)
        XCTAssertTrue(harness.sims.bootedUDIDs.isEmpty)
        XCTAssertTrue(harness.sims.clonePlans.isEmpty)
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
    }

    func testLeasedInflightTaintedAndUnleasedUserSimulatorsAreProtected() throws {
        for protection in ["manual", "job", "booting", "settling", "tainted", "unleased"] {
            let (harness, store, engine, original) = try setup()
            var config = original
            let phase: PoolSimPhase
            let lease: String?
            switch protection {
            case "manual": phase = .leased; lease = "lease:manual"
            case "job":
                let job = try harness.submit(store, resources: ResourceRequest(minSims: 0))
                XCTAssertEqual(try engine.tick().admitted, [job.id])
                phase = .leased; lease = Engine.poolLeaseID(jobID: job.id)
            case "booting": phase = .booting; lease = nil
            case "settling":
                phase = .settling; lease = nil
                config.settle.mode = .load
                config.settle.loadBelow = -1
            default: phase = .ready; lease = nil
            }
            try seed("A", harness, store, engine, phase: phase, lease: lease, tainted: protection == "tainted")
            harness.probe.update { $0.memoryPressure = .warn }
            _ = try engine.poolPass(
                config: config, demand: 4, unleasedUsers: ["tainted", "unleased"].contains(protection) ? ["A"] : [])
            XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty, protection)
            XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty, protection)
            XCTAssertEqual(try store.poolSims().first?.phase, phase, protection)
        }
    }

    func testAbsentOrReleasedOwnershipIsInsufficientEvenForANamespaceMatch() throws {
        for released in [false, true] {
            let (harness, store, engine, config) = try setup()
            try seed("A", harness, store, engine, owned: released)
            if released {
                let resource = try XCTUnwrap(try store.liveResources(kinds: [.sim]).first)
                XCTAssertTrue(
                    try store.releaseResource(
                        id: resource.id, generation: resource.generation, now: harness.clock.now()))
            }
            harness.probe.update { $0.memoryPressure = .warn }
            _ = try engine.poolPass(config: config, demand: 1)
            XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty)
            XCTAssertEqual(try store.poolSims().first?.phase, .ready)
        }
    }

    func testForeignTemplateWrongNameAndUnknownHostStateAreProtected() throws {
        for protection in ["foreign", "other-daemon", "template", "mismatch", "unknown-state", "missing"] {
            let (harness, store, engine, config) = try setup()
            let name: String
            switch protection {
            case "foreign": name = "personal-device"
            case "other-daemon": name = "simq-pool-1-1-d12345678"
            case "template": name = "simq-template-source"
            default: name = "simq-pool-1-1"
            }
            try seed("A", harness, store, engine, name: name)
            if protection == "missing" {
                harness.sims.setDevices([])
            } else if protection == "mismatch" {
                harness.sims.setDevices([SimDevice(udid: "A", name: "simq-pool-2-2", isBooted: true)])
            } else if protection == "unknown-state" {
                harness.sims.setDevices([SimDevice(udid: "A", name: name, isBooted: true, state: "Booting")])
            }
            harness.probe.update { $0.memoryPressure = .warn }
            _ = try engine.poolPass(config: config, demand: 1)
            XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty, protection)
        }
    }

    func testPendingIntentPreventsReclaimAndRecoveryDoesNotRunHostMutation() throws {
        let (harness, store, engine, config) = try setup()
        try seed("A", harness, store, engine)
        let intent = try store.recordActionIntent(
            ActionIntent(target: .sim(udid: "A"), auditType: "pending_test_action", detail: "unfinished"),
            now: harness.clock.now())
        harness.probe.update { $0.memoryPressure = .warn }
        _ = try engine.poolPass(config: config, demand: 4)
        XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty)
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
        XCTAssertEqual(try store.pendingActionIntents().map(\.id), [intent.id])
    }

    func testReportOnlyModeNeverReclaims() throws {
        let (harness, store, engine, original) = try setup()
        try seed("A", harness, store, engine)
        var config = original
        config.mode = .reportOnly
        harness.probe.update { $0.memoryPressure = .critical }
        _ = try engine.poolPass(config: config, demand: 4)
        XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty)
        XCTAssertEqual(try store.poolSims().first?.phase, .ready)
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
    }

    func testOrphanedOrJobOwnedLedgerEntriesAreNotPoolAuthority() throws {
        for orphaned in [false, true] {
            let (harness, store, engine, config) = try setup()
            try seed("A", harness, store, engine, owned: false)
            let owner: ResourceOwner
            if orphaned {
                owner = .pool
            } else {
                let job = try harness.submit(store, resources: ResourceRequest(minSims: 0))
                XCTAssertEqual(try engine.tick().admitted, [job.id])
                owner = .job(job.id)
            }
            let resource = try store.acquireResource(
                kind: .sim, externalID: "A", owner: owner, epoch: engine.epoch, now: harness.clock.now())
            if orphaned {
                try store.markResourceOrphaned(id: resource.id, reason: "uncertain owner", now: harness.clock.now())
            }
            harness.probe.update { $0.memoryPressure = .warn }
            _ = try engine.poolPass(config: config, demand: 1)
            XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty)
            XCTAssertEqual(try store.poolSims().first?.phase, .ready)
        }
    }

    func testPressureClearingDuringUnlockedInventoryCancelsTheShutdown() throws {
        let (harness, store, engine, config) = try setup()
        try seed("A", harness, store, engine)
        harness.probe.update { $0.memoryPressure = .warn }
        var calls = 0
        _ = try engine.poolPass(config: config, demand: 1) { body in
            calls += 1
            try body()
            harness.probe.update { $0.memoryPressure = .normal }
        }
        XCTAssertGreaterThan(calls, 0, "inventory must also run through off-lock hostWork")
        XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty, "fresh pressure, not the pass's old sample")
        XCTAssertEqual(try store.poolSims().first?.phase, .ready)
    }

    func testLeaseGrantedDuringUnlockedInventoryCannotBeReclaimed() throws {
        let (harness, store, engine, config) = try setup()
        try seed("A", harness, store, engine)
        harness.probe.update { $0.memoryPressure = .warn }
        var granted: PoolSim?
        _ = try engine.poolPass(config: config, demand: 1) { body in
            try body()
            if granted == nil { granted = try engine.acquireManualLease(leaseID: "lease:concurrent", pid: nil) }
        }
        XCTAssertEqual(granted?.udid, "A", "control request entered while inventory was unlocked")
        XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty)
        XCTAssertEqual(try store.poolSims().first?.leaseID, "lease:concurrent")
        XCTAssertEqual(try store.poolSims().first?.phase, .leased)
    }

    func testOwnershipReleasedDuringUnlockedInventoryCannotAuthorizeShutdown() throws {
        let (harness, store, engine, config) = try setup()
        try seed("A", harness, store, engine)
        let resource = try XCTUnwrap(try store.liveResources(kinds: [.sim]).first)
        harness.probe.update { $0.memoryPressure = .warn }
        var changed = false
        _ = try engine.poolPass(config: config, demand: 1) { body in
            try body()
            if !changed {
                changed = true
                XCTAssertTrue(
                    try store.releaseResource(
                        id: resource.id, generation: resource.generation, now: harness.clock.now()))
            }
        }
        XCTAssertTrue(changed)
        XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty)
        XCTAssertEqual(try store.poolSims().first?.phase, .ready)
    }

    func testFailedShutdownKeepsDurableFenceUntilReadOnlyRecoveryRestoresReady() throws {
        enum Injected: Error { case shutdownUnavailable }
        let (harness, store, engine, config) = try setup()
        let original = try seed("A", harness, store, engine)
        harness.probe.update { $0.memoryPressure = .warn }
        var interrupted = false
        let report = try engine.poolPass(config: config, demand: 1) { body in
            if try store.poolSims().first?.phase == .shutdown {
                interrupted = true
                throw Injected.shutdownUnavailable
            }
            try body()
        }
        XCTAssertTrue(interrupted)
        XCTAssertFalse(report.failures.isEmpty)
        XCTAssertEqual(try store.poolSims().first?.phase, .shutdown)
        XCTAssertNil(try engine.acquirePoolSim(leaseID: "lease:too-soon"))
        XCTAssertEqual(try store.pendingActionIntents().count, 1, "crash proof survives failed host work")
        XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty, "injected failure occurred before host mutation")

        harness.probe.update { $0.memoryPressure = .normal }
        _ = try engine.poolPass(config: SimPoolConfig(maxSims: 1), demand: 0)
        XCTAssertEqual(try store.poolSims().first, original, "Booted inventory restores the exact previous ready row")
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
        XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty, "recovery observes rather than mutating the host")
        XCTAssertEqual(try engine.acquirePoolSim(leaseID: "lease:after-recovery")?.udid, "A")
    }

    func testUnknownRecoveryInventoryKeepsFenceAndIntentInsteadOfHandingOutOrRetrying() throws {
        enum Injected: Error { case interrupted }
        let (harness, store, engine, config) = try setup()
        let original = try seed("A", harness, store, engine)
        harness.probe.update { $0.memoryPressure = .warn }
        _ = try engine.poolPass(config: config, demand: 1) { body in
            if try store.poolSims().first?.phase == .shutdown { throw Injected.interrupted }
            try body()
        }
        harness.sims.setDevices([
            SimDevice(udid: "A", name: original.name, isBooted: false, state: "ShuttingDown")
        ])
        harness.probe.update { $0.memoryPressure = .normal }
        XCTAssertThrowsError(try engine.poolPass(config: config, demand: 1))
        XCTAssertEqual(try store.poolSims().first?.phase, .shutdown)
        XCTAssertEqual(try store.pendingActionIntents().count, 1)
        XCTAssertNil(try engine.acquirePoolSim(leaseID: "lease:unsafe"))
        XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty)
        XCTAssertTrue(harness.sims.bootedUDIDs.isEmpty)
    }

    func testSuccessorEpochRecoversBootedSimulatorWithoutHidingItBehindShutdownState() throws {
        enum Injected: Error { case stoppedBeforeShutdown }
        let (harness, store, engine, config) = try setup()
        try seed("A", harness, store, engine)
        harness.probe.update { $0.memoryPressure = .warn }
        _ = try engine.poolPass(config: config, demand: 1) { body in
            if try store.poolSims().first?.phase == .shutdown { throw Injected.stoppedBeforeShutdown }
            try body()
        }
        XCTAssertEqual(try store.pendingActionIntents().count, 1)
        harness.probe.update { $0.memoryPressure = .normal }
        let (successor, _, _) = try harness.start(store: store)
        XCTAssertGreaterThan(successor.epoch, engine.epoch)
        successor.pool = SimPoolConfig(maxSims: 1)
        _ = try successor.poolPass(config: SimPoolConfig(maxSims: 1), demand: 0)
        XCTAssertEqual(try store.poolSims().first?.phase, .ready)
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
        XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty)
        XCTAssertEqual(try successor.acquirePoolSim(leaseID: "lease:successor")?.udid, "A")
    }

    func testVanishedShutdownTargetCanResolveWithoutRecreatingPoolOrOwnershipRows() throws {
        enum Injected: Error { case stoppedBeforeShutdown }
        let (harness, store, engine, config) = try setup()
        try seed("A", harness, store, engine)
        harness.probe.update { $0.memoryPressure = .warn }
        _ = try engine.poolPass(config: config, demand: 1) { body in
            if try store.poolSims().first?.phase == .shutdown { throw Injected.stoppedBeforeShutdown }
            try body()
        }
        let resource = try XCTUnwrap(try store.liveResources(kinds: [.sim]).first)
        try harness.sims.deleteDevice(udid: "A")
        harness.probe.update { $0.memoryPressure = .normal }
        let (successor, _, _) = try harness.start(store: store)
        XCTAssertGreaterThan(successor.epoch, engine.epoch)
        _ = try successor.reconcilePool()
        XCTAssertEqual(try store.resource(id: resource.id)?.state, .released, "startup confirms the missing resource")
        _ = try successor.poolPass(config: SimPoolConfig(maxSims: 0), demand: 0)
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
        XCTAssertTrue(try store.poolSims().isEmpty)
        XCTAssertTrue(try store.liveResources(kinds: [.sim]).isEmpty)
        XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty)
    }

    func testEndedJobKeepsItsLeaseWhileSimulatorPreparationOrAProcessGroupIsStillLive() throws {
        for protection in ["preparation", "process-group"] {
            let (harness, store, engine, config) = try setup()
            try seed("A", harness, store, engine)
            let job = try harness.submit(store)
            XCTAssertEqual(try engine.tick().admitted, [job.id])
            if protection == "preparation" {
                engine.simPrepInFlight.insert(job.id)
            } else {
                harness.processes.spawn(950)
                try store.acquireResource(
                    kind: .processGroup, externalID: "950", owner: .job(job.id), epoch: engine.epoch,
                    identity: FakeProcessTable.defaultIdentity(950), now: harness.clock.now())
            }
            _ = try store.finish(jobID: job.id, result: .success, now: harness.clock.now())
            harness.probe.update { $0.memoryPressure = .warn }
            _ = try engine.poolPass(config: config, demand: 4)
            XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty, protection)
            XCTAssertEqual(try engine.poolSimUDIDs(jobID: job.id), ["A"], protection)
            XCTAssertEqual(try store.poolSims().first?.phase, .leased, protection)
        }
    }

    func testShutdownPublishesLeaseBarrierBeforeOffLockWorkAndDoesNotRestoreDeletedRow() throws {
        let (harness, store, engine, config) = try setup()
        try seed("A", harness, store, engine)
        harness.probe.update { $0.memoryPressure = .warn }
        var sawBarrier = false
        _ = try engine.poolPass(config: config, demand: 1) { body in
            if try store.poolSims().first?.phase == .shutdown, !sawBarrier {
                sawBarrier = true
                XCTAssertNil(try engine.acquireManualLease(leaseID: "lease:late", pid: nil))
                XCTAssertFalse(try store.pendingActionIntents().isEmpty, "durable before the shutdown")
                try body()
                try store.deletePoolSim(udid: "A")
            } else {
                try body()
            }
        }
        XCTAssertTrue(sawBarrier, "shutdown must run through the unlocking hostWork boundary")
        XCTAssertEqual(harness.sims.shutdownUDIDs, ["A"])
        XCTAssertTrue(try store.poolSims().isEmpty, "never resurrect a row removed while unlocked")
    }

    func testNormalPressureKeepsConsecutiveJobHandoffWarm() throws {
        let (harness, store, engine, config) = try setup()
        try seed("A", harness, store, engine)
        let first = try harness.submit(store)
        let second = try harness.submit(store)
        XCTAssertEqual(try engine.tick().admitted, [first.id])
        _ = try store.finish(jobID: first.id, result: .success, now: harness.clock.now())
        _ = try engine.poolPass(config: config)
        XCTAssertTrue(harness.sims.shutdownUDIDs.isEmpty)
        XCTAssertEqual(try engine.tick().admitted, [second.id])
        XCTAssertEqual(try engine.poolSimUDIDs(jobID: second.id), ["A"])
    }
}
