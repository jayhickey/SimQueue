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

    /// Field case: another tool kept the duo template booted, so every create for the
    /// highest-ranked duo waiter failed preflight once a second for 38 minutes. Both that
    /// waiter and a photos job behind it said only "needs 1, 0 ready".
    func testFailingCreateIsNamedForWaitersAuditedOnceAndClearedWhenItSucceeds() throws {
        let harness = Harness()
        harness.sims.clonesTemplate = true
        harness.reliability.cleanupMode = .enforce
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        var config = SimPoolConfig(maxSims: 2)
        config.settle.mode = .off
        engine.pool = config
        engine.hostTemplates = ["duo": "fold", "photos": "camera"]
        engine.defaultHostTemplate = "photos"
        func submit(_ template: String) throws -> Job {
            var command = JobCommand(argv: ["true"]); command.template = template
            return try store.submit(
                JobSubmission(
                    project: "app", submitter: "test", resources: ResourceRequest(minSims: 1), command: command),
                now: harness.clock.now()
            ).job
        }
        let duo = try submit("duo")
        harness.clock.advance(by: 1)
        let photos = try submit("photos")
        let failure = FakeSimError.slimFailed("template fold is Booted, not Shutdown")
        harness.sims.prepareFailure = failure

        for _ in 0..<5 {
            _ = try engine.poolPass(config: config)
            harness.clock.advance(by: 1)
        }
        let block = try XCTUnwrap(engine.poolBlock)
        XCTAssertEqual(block.template, "duo")
        XCTAssertEqual(block.jobID, duo.id)
        XCTAssertEqual(block.failures, 5)
        XCTAssertEqual(block.detail, "\(failure)")
        XCTAssertEqual(try store.auditCount(type: "pool_action_failed", since: 0), 1)
        XCTAssertEqual(try store.auditCount(type: "pool_blocked", since: 0), 1)

        let tick = try engine.tick()
        XCTAssertTrue(tick.admitted.isEmpty)
        func reasons(_ id: String) -> [WaitReason] {
            tick.plan.waiting.first { $0.jobID == id }?.reasons ?? []
        }
        XCTAssertEqual(reasons(duo.id), [.poolBlocked(template: "duo", detail: "\(failure)", behindJobID: nil)])
        XCTAssertEqual(
            reasons(photos.id), [.poolBlocked(template: "duo", detail: "\(failure)", behindJobID: duo.id)])
        XCTAssertEqual(try store.explanation(jobID: photos.id)?.reasons.first?.code, "pool_blocked")

        harness.sims.prepareFailure = nil
        _ = try engine.poolPass(config: config)
        XCTAssertNil(engine.poolBlock)
        XCTAssertEqual(harness.sims.clonedFrom, ["fold"])
        XCTAssertEqual(try store.auditCount(type: "pool_unblocked", since: 0), 1)
    }

    func testPoolBlockClearsWhenThePoolServesAnotherTemplate() throws {
        let harness = Harness()
        harness.sims.clonesTemplate = true
        harness.reliability.cleanupMode = .enforce
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try harness.start(store: store)
        var config = SimPoolConfig(maxSims: 2)
        config.settle.mode = .off
        engine.pool = config
        engine.hostTemplates = ["duo": "fold", "photos": "camera"]
        var command = JobCommand(argv: ["true"]); command.template = "duo"
        let duo = try store.submit(
            JobSubmission(project: "app", submitter: "test", resources: ResourceRequest(minSims: 1), command: command),
            now: harness.clock.now()
        ).job
        harness.sims.prepareFailure = FakeSimError.noTemplate
        _ = try engine.poolPass(config: config)
        XCTAssertNotNil(engine.poolBlock)
        // The blocked waiter goes away (canceled); the pool must not keep blaming it.
        _ = try store.cancel(jobID: duo.id, now: harness.clock.now())
        _ = try engine.poolPass(config: config)
        XCTAssertNil(engine.poolBlock)
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
