// SPDX-License-Identifier: MIT
import Foundation
import SimQueueCore
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

@testable import SimQueueEngine

final class SlimCloneEngineTests: XCTestCase {
    private let source = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    private let sourceName = "simq-template-demo-lean-1"

    private func world(slimmed: Bool? = true, perPass: Int = 3) throws -> (Harness, JobStore, Engine, SimPoolConfig) {
        let harness = Harness(
            reliability: ReliabilityConfig(
                cleanupMode: .enforce, orphanGraceSeconds: 0, maxDestructiveActionsPerPass: perPass))
        harness.sims.clonesTemplate = true
        harness.sims.configuredTemplateValue = sourceName
        harness.sims.setDevices([SimDevice(udid: source, name: sourceName, isBooted: false)])
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        try engine.registerTemplate(
            TemplateRecord(
                project: "demo", profile: "lean", name: sourceName, udid: source,
                deviceType: "Phone", runtime: "iOS", xcodeVersion: "Xcode", runtimeVersion: "iOS",
                builtAt: harness.clock.now(), slimmed: slimmed), now: harness.clock.now())
        var pool = SimPoolConfig(); pool.maxSims = 3; pool.maxConcurrentBoots = 1; pool.warmMin = 0;
        pool.settle.mode = .off
        engine.pool = pool
        return (harness, store, engine, pool)
    }

    private func pending(
        _ engine: Engine, _ store: JobStore, phase: Engine.PoolCloneOperation.Phase = .started,
        suffix: Int = 1, createdUDID: String? = nil
    ) throws -> (ActionIntent, SimClonePreparation) {
        let plan = try engine.selectedClonePlan()
        var intent = try store.recordActionIntent(
            ActionIntent(
                target: .simCreate(name: ""), auditType: Engine.poolCreatedAuditType,
                detail: "pending"), now: 1
        ) { .simCreate(name: "simq-pool-\(suffix)-\($0)") }
        guard case .simCreate(let name) = intent.target else { throw PoolError.cloneRecoveryBlocked("test target") }
        let proof = SimClonePreparation(name: name, plan: plan, previousUDIDs: [source], sourceWasShutdown: true)
        let operation = Engine.PoolCloneOperation(
            plan: plan, phase: phase, preparation: phase == .recorded ? nil : proof, createdUDID: createdUDID)
        intent.detail = try Engine.poolCloneDetail(operation)
        try store.updateActionIntentDetail(intent)
        return (intent, proof)
    }

    func testSlimCloneCapturesCanonicalSourceMethodAndBootReservationWhileUnlocked() throws {
        let (h, store, engine, pool) = try world()
        var started = false
        _ = try engine.poolPass(config: pool, demand: 2) { body in
            let intent = try XCTUnwrap(try store.pendingActionIntents().first)
            let operation = try Engine.poolCloneOperation(intent)
            XCTAssertEqual(operation.plan.source, self.source)
            XCTAssertEqual(operation.plan.method, .simslim)
            XCTAssertEqual(try engine.poolCapacity().bootsInProgress, 1)
            XCTAssertTrue(try engine.resolveActionIntents().confirmed.isEmpty)
            if operation.phase == .started {
                started = true
                XCTAssertEqual(
                    try engine.poolCreatesInFlight(fromTemplate: self.sourceName, udid: self.source).count, 1)
                h.sims.configuredTemplateValue = "new-source"
            }
            try body()
        }
        XCTAssertTrue(started)
        XCTAssertEqual(h.sims.clonePlans.map(\.method), [.simslim], "one temporary boot slot permits one create")
        XCTAssertEqual(h.sims.clonedFrom, [source])
        let clone = try XCTUnwrap(try store.poolSims().first)
        XCTAssertEqual(clone.cloneMethod, .simslim)
        XCTAssertEqual(clone.clonedFrom, TemplateRef(udid: source, name: sourceName))
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
    }

    func testUnreadableRegisteredTemplateMetadataCannotSilentlySelectStockCloning() throws {
        let (h, store, engine, _) = try world()
        let record = try XCTUnwrap(try store.liveResources(kinds: [.template]).first)
        try store.updateResourceDetail(id: record.id, detail: "not valid template metadata")
        for selected in [source, sourceName] {
            h.sims.configuredTemplateValue = selected
            XCTAssertThrowsError(try engine.selectedClonePlan(), selected)
        }
        XCTAssertTrue(h.sims.clonePlans.isEmpty)
    }

    func testStockAndLegacyMetadataKeepPlainClonePath() throws {
        for marker: Bool? in [false, nil] {
            let (h, _, engine, pool) = try world(slimmed: marker)
            _ = try engine.poolPass(config: pool, demand: 1)
            XCTAssertEqual(h.sims.clonePlans.map(\.method), [.simctl])
        }
    }

    func testSlowPreflightCannotAuthorizeSlimBootFromStalePressureOrLoad() throws {
        for gate in ["pressure", "load"] {
            let (h, store, engine, pool) = try world()
            let report = try engine.poolPass(config: pool, demand: 1) { body in
                try body()
                h.clock.advance(by: 6)
                h.probe.update { if gate == "pressure" { $0.memoryPressure = .critical } else { $0.load1 = 1000 } }
            }
            XCTAssertTrue(h.sims.clonePlans.isEmpty, gate)
            XCTAssertTrue(try store.pendingActionIntents().isEmpty, "held preflight never started")
            XCTAssertEqual(try engine.poolCapacity().bootsInProgress, 0)
            XCTAssertEqual(gate == "pressure" ? report.createsDeferredForResources : report.createsDeferredForLoad, 1)
        }
    }

    func testHighBootLoadDoesNotTurnStockClonesIntoBootingOperations() throws {
        let (h, _, engine, pool) = try world(slimmed: false)
        h.probe.update { $0.load1 = 1000 }
        _ = try engine.poolPass(config: pool, demand: 1)
        XCTAssertEqual(h.sims.clonePlans.map(\.method), [.simctl])
    }

    func testLegacySlimSourceClonesCannotBeLeasedButExistingLeaseCanBeReleased() throws {
        let (h, store, engine, pool) = try world()
        var old = PoolSim(udid: "OLD", name: "simq-pool-1-99", phase: .ready, createdAt: h.clock.now())
        old.clonedFrom = TemplateRef(udid: source, name: sourceName)
        try store.savePoolSim(old)
        h.sims.setDevices(try h.sims.listDevices() + [SimDevice(udid: old.udid, name: old.name, isBooted: true)])
        XCTAssertEqual(try engine.poolCapacity().idleRunning, 0)
        XCTAssertNil(try engine.acquirePoolSim(leaseID: "lease:new"))
        old.phase = .leased; old.leaseID = "lease:existing"
        try store.savePoolSim(old)
        _ = try engine.poolPass(config: pool, demand: 0)
        XCTAssertEqual(try store.poolSims().first?.leaseID, "lease:existing")
        XCTAssertFalse(h.sims.deletedUDIDs.contains(old.udid))
        XCTAssertEqual(try engine.releasePoolSim(udid: old.udid, config: pool).phase, .recycling)
        _ = try engine.poolPass(config: pool, demand: 0)
        XCTAssertTrue(h.sims.deletedUDIDs.contains(old.udid))
    }

    func testUnstartedRecoveryNeverMutatesPreexistingTargetOrBootedSource() throws {
        for phase in [Engine.PoolCloneOperation.Phase.recorded, .prepared] {
            let (h, store, engine, pool) = try world()
            let (_, proof) = try pending(engine, store, phase: phase)
            h.sims.setDevices([
                SimDevice(udid: source, name: sourceName, isBooted: true),
                SimDevice(udid: "EXISTING", name: proof.name, isBooted: true),
            ])
            try engine.recoverInterruptedPoolClones(config: pool, hostWork: Engine.inlineHostWork)
            XCTAssertTrue(try store.pendingActionIntents().isEmpty)
            XCTAssertTrue(h.sims.deletedUDIDs.isEmpty)
            XCTAssertTrue(h.sims.shutdownUDIDs.isEmpty)
            XCTAssertEqual(try h.sims.listDevices().count, 2)
        }
    }

    func testStartedRecoveryRestoresSourceEvenWhenTargetWasNeverCreated() throws {
        let (h, store, engine, pool) = try world()
        let (intent, _) = try pending(engine, store)
        h.sims.setDevices([SimDevice(udid: source, name: sourceName, isBooted: true)])
        XCTAssertTrue(try engine.resolveActionIntents().confirmed.isEmpty)
        XCTAssertEqual(try engine.poolCapacity().bootsInProgress, 1)
        try engine.recoverInterruptedPoolClones(config: pool) { body in
            XCTAssertTrue(engine.hostActionIntentsInFlight.contains(intent.id))
            XCTAssertEqual(try engine.poolCapacity().bootsInProgress, 1)
            try body()
        }
        XCTAssertEqual(try h.sims.listDevices().first?.state, "Shutdown")
        XCTAssertTrue(h.sims.deletedUDIDs.isEmpty, "template is restored, never deleted")
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
        XCTAssertEqual(try engine.poolCapacity().bootsInProgress, 0)
    }

    func testPartialCommittedCloneIsFencedThenLedgerRetiredOnlyAfterCleanup() throws {
        let (h, store, engine, pool) = try world()
        let (_, proof) = try pending(engine, store, createdUDID: "PARTIAL")
        h.sims.setDevices(try h.sims.listDevices() + [SimDevice(udid: "PARTIAL", name: proof.name, isBooted: false)])
        var row = PoolSim(udid: "PARTIAL", name: proof.name, phase: .ready, createdAt: h.clock.now())
        row.clonedFrom = proof.plan.sourceRef; row.cloneMethod = .simslim
        try store.savePoolSim(row)
        let resource = try store.acquireResource(
            kind: .sim, externalID: row.udid, owner: .pool, epoch: engine.epoch, now: h.clock.now())
        try engine.recoverInterruptedPoolClones(config: pool) { body in
            XCTAssertNil(try engine.acquirePoolSim(leaseID: "lease:race"))
            try body()
            XCTAssertFalse(try store.poolSims().isEmpty, "row stays fenced until host deletion returns")
        }
        XCTAssertTrue(try store.poolSims().isEmpty)
        XCTAssertEqual(try store.resource(id: resource.id)?.state, .released)
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
    }

    func testResourceOnlyCommitIsRetiredAfterVerifiedInterruptedCleanup() throws {
        let (h, store, engine, pool) = try world()
        let (_, proof) = try pending(engine, store, createdUDID: "PARTIAL")
        h.sims.setDevices(try h.sims.listDevices() + [SimDevice(udid: "PARTIAL", name: proof.name, isBooted: false)])
        let resource = try store.acquireResource(
            kind: .sim, externalID: "PARTIAL", owner: .pool, epoch: engine.epoch, now: h.clock.now())
        XCTAssertTrue(try store.poolSims().isEmpty, "crash before PoolSim save")
        _ = try engine.watchdogPass(.full, config: WatchdogConfig())
        XCTAssertEqual(try store.resource(id: resource.id)?.state, .active)
        try engine.recoverInterruptedPoolClones(config: pool, hostWork: Engine.inlineHostWork)
        XCTAssertEqual(try store.resource(id: resource.id)?.state, .released)
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
        XCTAssertFalse(try h.sims.listDevices().contains { $0.udid == "PARTIAL" })
    }

    func testFailedCleanupRetainsIntentReservationAndNeverHandsOutPartialClone() throws {
        let (h, store, engine, pool) = try world()
        let (_, proof) = try pending(engine, store)
        h.sims.setDevices([
            SimDevice(udid: source, name: sourceName, isBooted: true),
            SimDevice(udid: "PARTIAL", name: proof.name, isBooted: true),
        ])
        h.sims.deleteFails = ["PARTIAL"]
        XCTAssertThrowsError(try engine.recoverInterruptedPoolClones(config: pool, hostWork: Engine.inlineHostWork))
        XCTAssertEqual(try store.pendingActionIntents().count, 1)
        XCTAssertEqual(try engine.poolCapacity().bootsInProgress, 1)
        XCTAssertNil(try engine.acquirePoolSim(leaseID: "lease:new"))
        h.sims.deleteFails = []
        try engine.recoverInterruptedPoolClones(config: pool, hostWork: Engine.inlineHostWork)
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
        XCTAssertEqual(try h.sims.listDevices().map(\.udid), [source])
        XCTAssertEqual(try h.sims.listDevices().first?.state, "Shutdown")
    }

    func testDurableInterruptedTargetIsNotReapedByGenericWatchdog() throws {
        let (h, store, engine, pool) = try world()
        let (_, proof) = try pending(engine, store)
        h.sims.setDevices(try h.sims.listDevices() + [SimDevice(udid: "PARTIAL", name: proof.name, isBooted: false)])
        let watchdog = try engine.watchdogPass(.full, config: WatchdogConfig())
        XCTAssertFalse(
            watchdog.reconcile.actions.contains { action in
                if case .deleteSim(let udid, _) = action { return udid == "PARTIAL" }
                return false
            })
        XCTAssertTrue(h.sims.deletedUDIDs.isEmpty)
        XCTAssertEqual(try store.pendingActionIntents().count, 1)
        try engine.recoverInterruptedPoolClones(config: pool, hostWork: Engine.inlineHostWork)
        XCTAssertEqual(h.sims.deletedUDIDs, ["PARTIAL"])
    }

    func testMalformedOrUnknownCloneProofBlocksWithoutGenericAdoption() throws {
        let (h, store, engine, pool) = try world()
        _ = try store.recordActionIntent(
            ActionIntent(
                target: .simCreate(name: "simq-pool-1-999"), auditType: Engine.poolCreatedAuditType,
                detail: "pool-clone-v99 unknown"), now: 1)
        XCTAssertTrue(try engine.resolveActionIntents().confirmed.isEmpty)
        XCTAssertEqual(try engine.poolCapacity().bootsInProgress, 1)
        XCTAssertThrowsError(try engine.recoverInterruptedPoolClones(config: pool, hostWork: Engine.inlineHostWork))
        XCTAssertEqual(try store.pendingActionIntents().count, 1)
        XCTAssertTrue(h.sims.deletedUDIDs.isEmpty)
        XCTAssertTrue(h.sims.shutdownUDIDs.isEmpty)
    }

    func testRecoveryAndNormalRecyclesSharePerPassCleanupLimit() throws {
        let (h, store, engine, pool) = try world(perPass: 1)
        for i in 1...2 {
            let (_, proof) = try pending(engine, store, suffix: i)
            h.sims.setDevices(
                try h.sims.listDevices() + [SimDevice(udid: "PARTIAL-\(i)", name: proof.name, isBooted: false)])
        }
        var old = PoolSim(udid: "RECYCLE", name: "simq-pool-3-99", phase: .recycling, createdAt: h.clock.now())
        old.clonedFrom = TemplateRef(udid: source, name: sourceName); old.cloneMethod = .simslim
        try store.savePoolSim(old)
        h.sims.setDevices(try h.sims.listDevices() + [SimDevice(udid: old.udid, name: old.name, isBooted: false)])
        let report = try engine.poolPass(config: pool, demand: 0)
        XCTAssertEqual(h.sims.deletedUDIDs.count, 1)
        XCTAssertEqual(try store.pendingActionIntents().count, 1)
        XCTAssertEqual(report.recyclesPostponed, [old.udid])
        XCTAssertEqual(try engine.poolCapacity().bootsInProgress, 1)
    }
}
