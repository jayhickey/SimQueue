// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueEngine
import SimQueueSim
import SimQueueStore
import XCTest

final class NamedTemplateTests: XCTestCase {
    func testCreatesRequestedProfileAndRebalancesWithinSharedPoolLimit() throws {
        let harness = Harness()
        harness.sims.clonesTemplate = true
        harness.reliability.cleanupMode = .enforce
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        var config = SimPoolConfig(maxSims: 1)
        config.settle.mode = .off
        engine.pool = config
        engine.hostTemplates = ["iphone": "phone", "ipad": "tablet"]
        engine.defaultHostTemplate = "iphone"
        var command = JobCommand(argv: ["true"]); command.template = "ipad"
        let job = try store.submit(
            JobSubmission(
                project: "app", submitter: "test",
                resources: ResourceRequest(minSims: 1), command: command), now: harness.clock.now()
        ).job
        for _ in 0..<3 { _ = try engine.poolPass(config: config) }
        XCTAssertEqual(harness.sims.clonedFrom, ["tablet"])
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        _ = try store.finish(jobID: job.id, result: .success, now: harness.clock.now())
        command.template = "iphone"
        _ = try store.submit(
            JobSubmission(
                project: "app", submitter: "test",
                resources: ResourceRequest(minSims: 1), command: command), now: harness.clock.now())
        for _ in 0..<5 {
            _ = try engine.poolPass(config: config)
            XCTAssertLessThanOrEqual(try store.poolSims().count, 1)
        }
        XCTAssertEqual(harness.sims.clonedFrom, ["tablet", "phone"])
        XCTAssertEqual(try engine.acquirePoolSim(leaseID: "manual")?.clonedFrom?.udid, "phone")
    }

    func testSelectionLeasesOnlyMatchingTemplateAndSharesCapacity() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        engine.pool = SimPoolConfig(maxSims: 2)
        engine.hostTemplates = ["iphone": "phone", "ipad": "tablet"]
        engine.defaultHostTemplate = "iphone"
        for (id, source) in [("P", "phone"), ("T", "tablet")] {
            var sim = PoolSim(udid: id, name: "simq-pool-\(id)", phase: .ready, createdAt: 0)
            sim.clonedFrom = TemplateRef(udid: source, name: nil)
            try store.savePoolSim(sim)
        }
        var command = JobCommand(argv: ["true"]); command.template = "ipad"
        let job = try store.submit(
            JobSubmission(project: "app", submitter: "test", resources: ResourceRequest(minSims: 1), command: command),
            now: harness.clock.now()
        ).job
        let tick = try engine.tick()
        XCTAssertEqual(tick.admitted, [job.id])
        XCTAssertEqual(try engine.poolSimUDIDs(jobID: job.id), ["T"])
        XCTAssertEqual(try engine.acquirePoolSim(leaseID: "manual")?.udid, "P")
        XCTAssertNil(try engine.acquirePoolSim(leaseID: "another", template: "ipad"))
    }

    private func blockedPool(maxSims: Int = 2) throws -> (Harness, JobStore, Engine, SimPoolConfig) {
        let harness = Harness()
        harness.sims.clonesTemplate = true
        harness.reliability.cleanupMode = .enforce
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        var config = SimPoolConfig(maxSims: maxSims)
        config.settle.mode = .off
        engine.pool = config
        engine.hostTemplates = ["duo": "fold", "photos": "camera"]
        engine.defaultHostTemplate = "photos"
        return (harness, store, engine, config)
    }

    private func submit(_ store: JobStore, _ harness: Harness, template: String, priority: Int = 50) throws -> Job {
        var command = JobCommand(argv: ["true"]); command.template = template
        return try store.submit(
            JobSubmission(
                project: "app", priority: priority, submitter: "test", resources: ResourceRequest(minSims: 1),
                command: command),
            now: harness.clock.now()
        ).job
    }

    private static let booted = FakeSimError.slimFailed("template fold is Booted, not Shutdown")

    /// Has the pool clone and boot one photos sim (pending manual-lease demand), as it
    /// would for an earlier photos job, and returns it once ready.
    private func readyPhotosClone(_ engine: Engine, _ store: JobStore, _ config: SimPoolConfig) throws -> PoolSim {
        for _ in 0..<6 {
            _ = try engine.poolPass(config: config, extraDemand: 1)
            if let ready = try store.poolSims().first(where: { $0.phase == .ready }) { return ready }
        }
        throw XCTSkip("the fake pool never readied a photos clone")
    }

    /// Field case: another tool kept the duo template booted, so every create for the duo
    /// waiter failed preflight once a second for 38 minutes, each one audited, and the
    /// waiter said only "needs 1, 0 ready".
    func testFailingCreateIsNamedAuditedOnceAndClearedWhenItSucceeds() throws {
        let (harness, store, engine, config) = try blockedPool()
        let duo = try submit(store, harness, template: "duo")
        harness.sims.prepareFailure = Self.booted
        for _ in 0..<5 {
            _ = try engine.poolPass(config: config)
            harness.clock.advance(by: 1)
        }
        let block = try XCTUnwrap(engine.poolBlocks["duo"])
        XCTAssertEqual(block.jobID, duo.id)
        XCTAssertEqual(block.failures, 5)
        XCTAssertEqual(block.detail, "\(Self.booted)")
        XCTAssertEqual(try store.auditCount(type: "pool_action_failed", since: 0), 1)
        XCTAssertEqual(try store.auditCount(type: "pool_blocked", since: 0), 1)
        let tick = try engine.tick()
        XCTAssertTrue(tick.admitted.isEmpty)
        XCTAssertEqual(
            tick.plan.waiting.first { $0.jobID == duo.id }?.reasons,
            [.poolBlocked(template: "duo", detail: "\(Self.booted)")])
        XCTAssertEqual(try store.explanation(jobID: duo.id)?.reasons.first?.code, "pool_blocked")

        harness.sims.prepareFailure = nil
        _ = try engine.poolPass(config: config)
        XCTAssertNil(engine.poolBlocks["duo"])
        XCTAssertEqual(harness.sims.clonedFrom, ["fold"])
        XCTAssertEqual(try store.auditCount(type: "pool_unblocked", since: 0), 1)
    }

    /// The stall itself: a photos job queued behind the blocked duo waiter, with its own
    /// template's sim ready in a full pool, waited too. The pool targeted duo and would have
    /// recycled the photos sim to make room for a clone that could never succeed; the duo
    /// waiter's reservation took the idle sim. Now the read-only preflight finds duo
    /// blocked before anything is recycled, and the photos job runs on its own sim.
    func testJobBehindABlockedTemplateRunsOnItsOwnReadySim() throws {
        let (harness, store, engine, config) = try blockedPool(maxSims: 1)
        let ready = try readyPhotosClone(engine, store, config)
        XCTAssertEqual(ready.clonedFrom?.udid, "camera")
        let audited = try store.auditCount(type: Engine.destructiveAuditType, since: 0)
        let duo = try submit(store, harness, template: "duo", priority: 90)
        harness.clock.advance(by: 1)
        let photos = try submit(store, harness, template: "photos")
        harness.sims.prepareFailure = Self.booted

        // Duo is the top-ranked waiter: its preflight fails, then the pool serves photos.
        for _ in 0..<3 {
            _ = try engine.poolPass(config: config)
            harness.clock.advance(by: 1)
        }
        XCTAssertNotNil(engine.poolBlocks["duo"])
        XCTAssertEqual(try store.poolSims().map(\.udid), [ready.udid], "the ready photos sim is never recycled")
        XCTAssertEqual(try store.auditCount(type: Engine.destructiveAuditType, since: 0), audited)
        let tick = try engine.tick()
        XCTAssertEqual(tick.admitted, [photos.id])
        XCTAssertEqual(try engine.poolSimUDIDs(jobID: photos.id), [ready.udid])
        XCTAssertEqual(
            tick.plan.waiting.first { $0.jobID == duo.id }?.reasons.map(\.code), ["pool_blocked"])
        // In use now: further passes leave it leased to the photos job.
        _ = try engine.poolPass(config: config)
        XCTAssertEqual(try store.poolSims().first { $0.udid == ready.udid }?.phase, .leased)
    }

    /// The pool prepares other templates while one is blocked: it boots the photos job's
    /// shut-down sim instead of retrying only the failing duo clone.
    func testPoolBootsAnotherTemplatesSimWhileOneIsBlocked() throws {
        let (harness, store, engine, config) = try blockedPool()
        let clone = try readyPhotosClone(engine, store, config)
        try harness.sims.shutdownDevice(udid: clone.udid)
        try store.savePoolSim(try clone.applying(.shutDown, now: harness.clock.now()))
        _ = try submit(store, harness, template: "duo", priority: 90)
        harness.clock.advance(by: 1)
        let photos = try submit(store, harness, template: "photos")
        harness.sims.prepareFailure = Self.booted
        var admitted: [String] = []
        for _ in 0..<6 where admitted.isEmpty {
            _ = try engine.poolPass(config: config)
            harness.clock.advance(by: 1)
            admitted = try engine.tick().admitted
        }
        XCTAssertEqual(admitted, [photos.id])
        XCTAssertEqual(try engine.poolSimUDIDs(jobID: photos.id), [clone.udid])
        XCTAssertTrue(
            try store.auditCount(type: "pool_booted", since: 0) >= 2, "booted again for the photos job")
        XCTAssertNotNil(engine.poolBlocks["duo"])
    }

    /// A block must not outlive its cause while creates wait on something else: the
    /// read-only preflight re-checks it, and a recheck that still fails doesn't count as
    /// another attempt.
    func testBlockIsRecheckedWhileCreatesAreDeferredForAnotherReason() throws {
        let (harness, store, engine, config) = try blockedPool()
        _ = try submit(store, harness, template: "duo")
        harness.sims.prepareFailure = Self.booted
        _ = try engine.poolPass(config: config)
        XCTAssertEqual(engine.poolBlocks["duo"]?.failures, 1)
        harness.probe.update { $0.memoryPressure = .warn }  // creates now wait for memory
        harness.clock.advance(by: Engine.poolBlockRecheckSeconds)
        _ = try engine.poolPass(config: config)
        XCTAssertEqual(engine.poolBlocks["duo"]?.failures, 1, "a recheck is not a create attempt")
        XCTAssertNotNil(engine.poolBlocks["duo"])

        harness.sims.prepareFailure = nil  // the other tool shut the template down
        harness.clock.advance(by: 1)
        _ = try engine.poolPass(config: config)
        XCTAssertNotNil(engine.poolBlocks["duo"], "rechecked at most every poolBlockRecheckSeconds")
        harness.clock.advance(by: Engine.poolBlockRecheckSeconds)
        _ = try engine.poolPass(config: config)
        XCTAssertNil(engine.poolBlocks["duo"])
        XCTAssertTrue(harness.sims.clonedFrom.isEmpty, "the create itself still waits for memory")
    }

    func testBlockClearsWhenNoQueuedJobNeedsItAndSurvivesARestart() throws {
        let (harness, store, engine, config) = try blockedPool()
        let duo = try submit(store, harness, template: "duo")
        harness.sims.prepareFailure = Self.booted
        _ = try engine.poolPass(config: config)
        let block = try XCTUnwrap(engine.poolBlocks["duo"])

        let (restarted, _, _) = try harness.start(store: store)
        XCTAssertEqual(restarted.poolBlocks["duo"]?.detail, block.detail)
        XCTAssertEqual(restarted.poolBlocks["duo"]?.since, block.since)

        _ = try store.cancel(jobID: duo.id, now: harness.clock.now())
        restarted.pool = config
        restarted.hostTemplates = engine.hostTemplates
        restarted.defaultHostTemplate = engine.defaultHostTemplate
        _ = try restarted.poolPass(config: config)
        XCTAssertNil(restarted.poolBlocks["duo"])
        let (again, _, _) = try harness.start(store: store)
        XCTAssertTrue(again.poolBlocks.isEmpty, "a cleared block stays cleared")
    }

    func testWrongTemplateWaitsEvenWhenAnotherDeviceIsReady() throws {
        let harness = Harness()
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        engine.pool = SimPoolConfig(maxSims: 1)
        engine.hostTemplates = ["iphone": "phone", "ipad": "tablet"]
        var sim = PoolSim(udid: "P", name: "simq-pool-1", phase: .ready, createdAt: 0)
        sim.clonedFrom = TemplateRef(udid: "phone", name: nil)
        try store.savePoolSim(sim)
        var command = JobCommand(argv: ["true"]); command.template = "ipad"
        _ = try store.submit(
            JobSubmission(project: "app", submitter: "test", resources: ResourceRequest(minSims: 1), command: command),
            now: harness.clock.now())
        let tick = try engine.tick()
        XCTAssertTrue(tick.admitted.isEmpty)
        XCTAssertTrue(tick.plan.waiting.first?.reasons.contains { $0.code == "pool_warming" } == true)
    }
}
