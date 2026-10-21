// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

/// Per-job sim preparation: `reset_apps` and `fresh_sim` on the leased pool sim before
/// the command starts. The default reuses the warm sim untouched. Fakes only.
final class SimPrepTests: XCTestCase {
    private func admitted(_ command: JobCommand) throws -> (Harness, JobStore, Engine, Job, String) {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))  // the pool acts
        harness.probe.update { host in
            host.cpuCount = 8
            host.load1 = 1
            host.load5 = 3
        }
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        var config = SimPoolConfig()
        engine.pool = config
        let job = try store.submit(
            JobSubmission(
                project: "app", priority: 50, submitter: "bot", resources: ResourceRequest(minSims: 1),
                exclusive: false, retryable: true, command: command),
            now: harness.clock.now()
        ).job
        _ = try engine.poolPass(config: config)
        _ = try engine.poolPass(config: config)
        harness.clock.advance(by: 10)
        _ = try engine.poolPass(config: config)
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        let udid = try XCTUnwrap(try engine.poolSimUDIDs(jobID: job.id).first)
        try engine.runSimPrep()
        XCTAssertTrue(engine.jobsAwaitingSimPrep.isEmpty)
        return (harness, store, engine, job, udid)
    }

    private func outcomes(_ store: JobStore, _ job: Job) throws -> [SimPrepOutcome] {
        try store.auditEntries(jobID: job.id, type: Engine.simPrepAuditType).compactMap {
            try $0.detail.map { try JSONDecoder().decode(SimPrepOutcome.self, from: Data($0.utf8)) }
        }
    }

    func testDefaultReusesTheWarmSimWithNoPrep() throws {
        let (harness, store, _, job, _) = try admitted(JobCommand(argv: ["true"]))
        XCTAssertTrue(harness.sims.prepCalls.isEmpty, "no erase or reset per lease by default")
        XCTAssertTrue(try outcomes(store, job).isEmpty)
        XCTAssertEqual(try store.job(id: job.id)?.state, .admitted)
    }

    func testResetAppsUninstallsResetsPrivacyThenTheKeychain() throws {
        let (harness, store, _, job, udid) = try admitted(
            JobCommand(argv: ["true"], resetApps: ["com.example.app", "com.example.widget"]))
        XCTAssertEqual(
            harness.sims.prepCalls,
            [
                "uninstall \(udid) com.example.app", "privacy \(udid) com.example.app",
                "uninstall \(udid) com.example.widget", "privacy \(udid) com.example.widget", "keychain \(udid)",
            ])
        XCTAssertEqual(
            try outcomes(store, job),
            [SimPrepOutcome(udid: udid, appsReset: ["com.example.app", "com.example.widget"], keychainReset: true)])
        XCTAssertEqual(try store.job(id: job.id)?.state, .admitted)
    }

    func testAFailedAppResetFallsBackToAnEraseAndSaysWhy() throws {
        let (h, store, _, job, udid) = try admittedFailing(resetFails: ["com.example.broken"])
        XCTAssertEqual(
            h.sims.prepCalls, ["uninstall \(udid) com.example.ok", "privacy \(udid) com.example.ok", "erase \(udid)"])
        let outcome = try XCTUnwrap(try outcomes(store, job).first)
        XCTAssertTrue(outcome.erased)
        XCTAssertEqual(outcome.appsReset, [], "the erase replaced the partial reset")
        XCTAssertTrue(outcome.fallbackReason?.contains("com.example.broken") == true, "\(outcome)")
        XCTAssertEqual(try h.sims.listDevices().first { $0.udid == udid }?.isBooted, true, "booted again")
        XCTAssertEqual(try store.job(id: job.id)?.state, .admitted)
    }

    func testFreshSimErasesBeforeTheCommand() throws {
        let (harness, store, _, job, udid) = try admitted(JobCommand(argv: ["true"], freshSim: true))
        XCTAssertEqual(harness.sims.prepCalls, ["erase \(udid)"])
        XCTAssertEqual(try outcomes(store, job), [SimPrepOutcome(udid: udid, erased: true)])
        XCTAssertEqual(try harness.sims.listDevices().first { $0.udid == udid }?.isBooted, true)
    }

    func testAFailedEraseEndsTheJobAsInfraAndTheSimIsRecycled() throws {
        let (harness, store, engine, job, udid) = try admittedFailing(resetFails: [], eraseFails: true, fresh: true)
        let ended = try XCTUnwrap(try store.job(id: job.id))
        XCTAssertTrue(
            ended.state == .infraFailed || ended.state == .queued, "\(ended.state): ended or requeued as infra")
        XCTAssertEqual(try store.poolSims().first { $0.udid == udid }?.tainted, true)
        XCTAssertNotNil(try outcomes(store, job).first?.error)
        var config = SimPoolConfig()
        _ = try engine.poolPass(config: config, demand: 0)  // released from the ended attempt
        let report = try engine.poolPass(config: config, demand: 0)
        XCTAssertTrue(
            report.actions.contains { if case .recycle(udid, _) = $0 { return true } else { return false } }
                || harness.sims.deletedUDIDs.contains(udid), "\(report.actions)")
    }

    /// Same as `admitted`, with failures injected before the lease.
    private func admittedFailing(
        resetFails: Set<String>, eraseFails: Bool = false, fresh: Bool = false, hold: Bool = false
    ) throws -> (
        Harness, JobStore, Engine, Job, String
    ) {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))  // the pool acts
        harness.sims.appResetFails = resetFails
        harness.probe.update { host in
            host.cpuCount = 8
            host.load1 = 1
            host.load5 = 3
        }
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        var config = SimPoolConfig()
        engine.pool = config
        let command =
            fresh
            ? JobCommand(argv: ["true"], freshSim: true)
            : JobCommand(argv: ["true"], resetApps: ["com.example.ok", "com.example.broken"])
        let job = try store.submit(
            JobSubmission(
                project: "app", priority: 50, submitter: "bot", resources: ResourceRequest(minSims: 1),
                exclusive: false, retryable: false, command: command),
            now: harness.clock.now()
        ).job
        _ = try engine.poolPass(config: config)
        _ = try engine.poolPass(config: config)
        harness.clock.advance(by: 10)
        _ = try engine.poolPass(config: config)
        let udid = try XCTUnwrap(try store.poolSims().first?.udid)
        if eraseFails { harness.sims.eraseFails = [udid] }
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        if !hold { try engine.runSimPrep() }
        return (harness, store, engine, job, udid)
    }

    /// The tick only queues preparation: no simulator command runs in it, and the job is
    /// held (`jobsAwaitingSimPrep`) until the outcome is recorded.
    func testTheTickQueuesPrepAndRunsNoSimctl() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))  // the pool acts
        harness.probe.update { host in
            host.cpuCount = 8
            host.load1 = 1
            host.load5 = 3
        }
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        var config = SimPoolConfig()
        engine.pool = config
        let job = try store.submit(
            JobSubmission(
                project: "app", priority: 50, submitter: "bot", resources: ResourceRequest(minSims: 1),
                exclusive: false, retryable: true, command: JobCommand(argv: ["true"], freshSim: true)),
            now: harness.clock.now()
        ).job
        _ = try engine.poolPass(config: config)
        _ = try engine.poolPass(config: config)
        harness.clock.advance(by: 10)
        _ = try engine.poolPass(config: config)
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        XCTAssertTrue(harness.sims.prepCalls.isEmpty, "no erase inside the tick")
        XCTAssertEqual(engine.jobsAwaitingSimPrep, [job.id])
        let work = try engine.takeSimPrepWork()
        XCTAssertEqual(work.map(\.jobID), [job.id])
        XCTAssertEqual(engine.jobsAwaitingSimPrep, [job.id], "held while in flight")
        XCTAssertTrue(try engine.takeSimPrepWork().isEmpty, "handed out once")
        let outcomes = Engine.performSimPrep(work[0], sims: harness.sims, naming: harness.environment.naming)
        try engine.finishSimPrep(work[0], outcomes: outcomes)
        XCTAssertTrue(engine.jobsAwaitingSimPrep.isEmpty)
        XCTAssertEqual(try store.job(id: job.id)?.state, .admitted)
    }

    /// The erase path refuses anything but an owned, non-template pool sim, before the backend
    /// is called, and the job ends as an infra failure.
    func testFreshSimRefusesTemplateAndForeignSimsAtTheEngine() throws {
        let naming = Harness().environment.naming
        let template = naming.templateName(project: "app", profile: "default", intentID: 1)
        for name in [template, "iPhone 17", "Other Tool Sim 1"] {
            let (harness, store, engine, job, udid) = try admittedFailing(resetFails: [], fresh: true, hold: true)
            var sim = try XCTUnwrap(try store.poolSims().first { $0.udid == udid })
            sim.name = name
            try store.savePoolSim(sim)
            try engine.runSimPrep()
            XCTAssertTrue(harness.sims.prepCalls.isEmpty, "\(name): no simctl call")
            let outcome = try XCTUnwrap(try outcomes(store, job).first)
            XCTAssertTrue(outcome.error?.contains("not an owned pool sim") == true, "\(outcome)")
            XCTAssertFalse(outcome.erased)
            XCTAssertEqual(try store.job(id: job.id)?.state, .infraFailed, name)
        }
        let work = SimPrepWork(
            jobID: "j", sims: [SimPrepTarget(udid: "G", name: template)], resetApps: ["com.example.app"],
            freshSim: false)
        let sims = FakeSimBackend()
        XCTAssertNotNil(Engine.performSimPrep(work, sims: sims, naming: naming).first?.error)
        XCTAssertTrue(sims.prepCalls.isEmpty, "reset_apps refuses a template too")
    }

    /// A job that ends while its sims are being prepared keeps them leased until the prep
    /// finishes, so the pool can't hand a sim to another job mid-erase. Then an erased sim is
    /// tainted (recycled); a sim that only had apps reset is released as usual.
    func testASimStaysLeasedWhileItsPrepRunsAfterTheJobEnded() throws {
        for fresh in [true, false] {
            let command =
                fresh
                ? JobCommand(argv: ["true"], freshSim: true)
                : JobCommand(argv: ["true"], resetApps: ["com.example.app"])
            let (harness, store, engine, job, udid) = try admittedHeld(command)
            let work = try engine.takeSimPrepWork()
            XCTAssertTrue(try store.cancel(jobID: job.id, now: harness.clock.now()))
            let config = try XCTUnwrap(engine.pool)
            _ = try engine.poolPass(config: config, demand: 0)
            let leased = try XCTUnwrap(try store.poolSims().first { $0.udid == udid })
            XCTAssertEqual(leased.phase, .leased, "fresh=\(fresh): still leased while prep runs")
            XCTAssertEqual(leased.leaseID, Engine.poolLeaseID(jobID: job.id))

            let outcomes = Engine.performSimPrep(work[0], sims: harness.sims, naming: harness.environment.naming)
            try engine.finishSimPrep(work[0], outcomes: outcomes)
            XCTAssertEqual(try store.job(id: job.id)?.state, .canceled, "a canceled job stays canceled")
            XCTAssertEqual(try store.poolSims().first { $0.udid == udid }?.tainted, fresh, "erased: tainted")
            _ = try engine.poolPass(config: config, demand: 0)
            let after = try store.poolSims().first { $0.udid == udid }
            XCTAssertNotEqual(after?.leaseID, Engine.poolLeaseID(jobID: job.id), "fresh=\(fresh): released after prep")
        }
    }

    /// `admitted`, but with the prep left queued (not run).
    private func admittedHeld(_ command: JobCommand) throws -> (Harness, JobStore, Engine, Job, String) {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .enforce))
        harness.probe.update { host in
            host.cpuCount = 8
            host.load1 = 1
            host.load5 = 3
        }
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        let config = SimPoolConfig()
        engine.pool = config
        let job = try store.submit(
            JobSubmission(
                project: "app", priority: 50, submitter: "bot", resources: ResourceRequest(minSims: 1),
                exclusive: false, retryable: false, command: command),
            now: harness.clock.now()
        ).job
        _ = try engine.poolPass(config: config)
        _ = try engine.poolPass(config: config)
        harness.clock.advance(by: 10)
        _ = try engine.poolPass(config: config)
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        let udid = try XCTUnwrap(try engine.poolSimUDIDs(jobID: job.id).first)
        return (harness, store, engine, job, udid)
    }

    func testCommandValidationRejectsBadBundleIDs() {
        XCTAssertNil(JobCommand(argv: ["true"], resetApps: ["com.example.App-1"]).validationError)
        XCTAssertNotNil(JobCommand(argv: ["true"], resetApps: ["com.example;rm -rf /"]).validationError)
        XCTAssertNotNil(JobCommand(argv: ["true"], resetApps: [".leading"]).validationError)
        XCTAssertNotNil(JobCommand(argv: ["true"], resetApps: [""]).validationError)
        XCTAssertNotNil(
            JobCommand(argv: ["true"], resetApps: (0...SimPrep.maxResetApps).map { "a\($0)" }).validationError)
    }
}
