// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

@testable import SimQueueEngine

/// `simq template build/list/rm` on the fake backend, and the reaper's template exemption (#36).
final class TemplateTests: XCTestCase {
    let watchdog = WatchdogConfig()

    private func request(replace: Bool = false) -> TemplateBuildRequest {
        TemplateBuildRequest(
            project: "demo", profile: "default", slimArguments: ["--slim-arg"], deviceType: "iPhone-X-fake",
            runtime: "iOS-26-0", replace: replace, slim: true)
    }

    private func start(_ mode: CleanupMode = .enforce, limits: (Int, Int) = (3, 10)) throws -> (
        Harness, JobStore, Engine
    ) {
        let harness = Harness(
            reliability: ReliabilityConfig(
                cleanupMode: mode, maxDestructiveActionsPerPass: limits.0, maxDestructiveActionsPerHour: limits.1))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.startWithActivePool(store: store)
        return (harness, store, engine)
    }

    /// A template build is a pool action: it follows `pool.mode`, not `cleanup_mode`, and is
    /// refused (nothing created, no intent) when the pool is off or doesn't act on the host.
    func testBuildFollowsPoolModeAndIsRefusedWhenThePoolIsOff() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .reportOnly))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        var (engine, _, _) = try harness.start(store: store)
        XCTAssertThrowsError(try engine.buildTemplate(request()), "no pool") {
            XCTAssertEqual(
                ($0 as? TemplateError)?.description,
                "template build refused: the sim pool is off (no pool section in config.json); configure pool, "
                    + "with pool.mode active")
        }
        engine.pool = SimPoolConfig()
        XCTAssertThrowsError(try engine.buildTemplate(request()), "follow-cleanup under report-only") {
            XCTAssertTrue(("\($0)").contains("pool.mode is follow-cleanup and cleanup_mode is report-only"), "\($0)")
        }
        engine.pool?.mode = .reportOnly
        XCTAssertThrowsError(try engine.buildTemplate(request())) {
            XCTAssertTrue(("\($0)").contains("pool.mode is report-only"), "\($0)")
        }
        XCTAssertTrue(harness.sims.baseCreates.isEmpty, "a refused build creates nothing")
        XCTAssertTrue(try store.pendingActionIntents().isEmpty, "and records no intent")

        engine.pool?.mode = .active
        XCTAssertEqual(
            try engine.buildTemplate(request()).status, "ready", "active builds while cleanup is report-only")

        let enforcing = harness
        enforcing.reliability.cleanupMode = .enforce
        (engine, _, _) = try enforcing.start(store: try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0))
        engine.pool = SimPoolConfig()
        XCTAssertEqual(try engine.buildTemplate(request()).status, "ready", "follow-cleanup builds under enforce")
        engine.pool?.mode = .reportOnly
        XCTAssertThrowsError(try engine.buildTemplate(request(replace: true)), "report-only refuses even under enforce")
    }

    func testBuildRegistersAPoolOwnedTemplateThatTheReaperNeverTouches() throws {
        let (harness, store, engine) = try start()
        let record = try engine.buildTemplate(request())
        XCTAssertTrue(record.name.hasPrefix("simq-template-demo-default-"), record.name)
        XCTAssertEqual(record.status, "ready")
        XCTAssertEqual(harness.sims.baseCreates.map(\.deviceType), ["iPhone-X-fake"])
        XCTAssertEqual(harness.sims.baseCreates.map(\.runtime), ["iOS-26-0"])
        XCTAssertEqual(harness.sims.slimCalls.map(\.arguments), [["--slim-arg"]])
        XCTAssertEqual(record.xcodeVersion, harness.sims.versions.xcode)
        let row = try XCTUnwrap(store.liveResources(kinds: [.template]).first)
        XCTAssertEqual(row.owner, .pool)
        XCTAssertEqual(row.externalID, record.udid)
        XCTAssertTrue(try store.pendingActionIntents().isEmpty, "the create intent was confirmed")

        // Days of watchdog passes and a restart: the template is never planned for deletion.
        for _ in 0..<200 {
            harness.clock.advance(by: 900)
            let pass = try engine.watchdogPass(.full, config: watchdog)
            XCTAssertTrue(pass.reconcile.failures.isEmpty, "\(pass.reconcile.failures)")
        }
        let (restarted, _, _) = try harness.startWithActivePool(store: store)
        XCTAssertFalse(try restarted.plannedReconcile().contains { "\($0)".contains(record.udid) })
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
        XCTAssertEqual(try restarted.templates().map(\.record), [record])

        XCTAssertThrowsError(try restarted.buildTemplate(request())) {
            XCTAssertEqual(
                $0 as? TemplateError, .alreadyExists(project: "demo", profile: "default", name: record.name))
        }
        let replacement = try restarted.buildTemplate(request(replace: true))
        XCTAssertNotEqual(replacement.udid, record.udid)
        XCTAssertEqual(try restarted.templates().count, 2, "the old template stays until template rm")
    }

    /// #36: an unregistered `simq-template-...` sim (e.g. a hand-made simslim template) is
    /// never reaped: no delete, no failure, no anomaly, no cleanup budget spent.
    func testAnUnregisteredTemplateNamedSimIsExemptFromTheReaper() throws {
        let (harness, store, engine) = try start()
        let template = SimDevice(udid: "GOLD-1", name: "simq-template-demo-slim", isBooted: false)
        let leak = SimDevice(udid: "LEAK-1", name: "simq-pool-1-5", isBooted: false)
        harness.sims.setDevices([template, leak])
        harness.clock.advance(by: 3600)
        XCTAssertEqual(try engine.plannedReconcile(), [.deleteSim(udid: "LEAK-1", resourceID: nil)])
        for _ in 0..<8 {
            let pass = try engine.watchdogPass(.full, config: watchdog)
            XCTAssertTrue(pass.reconcile.failures.isEmpty, "\(pass.reconcile.failures)")
            harness.clock.advance(by: 900)
        }
        XCTAssertEqual(harness.sims.deletedUDIDs, ["LEAK-1"])
        XCTAssertTrue(try harness.sims.listDevices().contains(template))
        XCTAssertFalse(try store.auditEntries().contains { $0.detail?.contains("GOLD-1") == true })
        XCTAssertFalse(try store.alerts().contains { $0.key.contains("GOLD-1") })
    }

    func testASlimFailureKeepsTheTemplateRegisteredAsSlimFailed() throws {
        let (harness, _, engine) = try start()
        harness.sims.slimFails = true
        XCTAssertThrowsError(try engine.buildTemplate(request())) {
            guard case .slimFailed = $0 as? TemplateError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try engine.templates().map(\.record.status), ["slim_failed"])
    }

    func testStaleWhenXcodeOrTheRuntimeChanges() throws {
        let (harness, _, engine) = try start()
        try engine.buildTemplate(request())
        XCTAssertEqual(try engine.templates(versions: harness.sims.versions).map(\.stale), [false])
        harness.sims.versions.xcode = "Xcode 26.1 (fake)"
        XCTAssertEqual(try engine.templates(versions: harness.sims.versions).map(\.stale), [true])
        harness.sims.versions = TemplateToolVersions(xcode: harness.sims.versions.xcode, runtimes: [:])
        try engine.buildTemplate(request(replace: true))
        XCTAssertEqual(try engine.templates().map(\.record.runtimeVersion), ["26.0 (fake)", "missing"])
        XCTAssertEqual(
            try engine.templates(versions: harness.sims.versions).map(\.stale), [true, false],
            "the old one: Xcode and runtime changed")
    }

    /// CR follow-up on #61: the pool clones the template with the daemon's lock dropped, so a
    /// `simq template rm` can arrive mid-clone. It's refused (clear error) while the create's
    /// intent is pending, and works once the create finished.
    func testRemoveIsRefusedWhileAPoolCreateClonesTheTemplate() throws {
        let (harness, store, engine) = try start()
        let record = try engine.buildTemplate(request())
        harness.sims.cloneSource = record.udid
        var pool = SimPoolConfig()
        pool.maxSims = 1
        var refusals: [any Error] = []
        var protectedPhases: Set<String> = []
        var protectedAttempts = 0
        _ = try engine.poolPass(config: pool, demand: 1) { body in
            let intent = try XCTUnwrap(try store.pendingActionIntents().first)
            protectedPhases.insert(try Engine.poolCloneOperation(intent).phase.rawValue)
            XCTAssertThrowsError(try engine.removeTemplate(record.name)) { refusals.append($0) }
            protectedAttempts += 1
            try body()
        }
        XCTAssertEqual(protectedPhases, ["recorded", "started"], "protect both preflight and host mutation")
        XCTAssertEqual(refusals.count, protectedAttempts)
        for refusal in refusals {
            guard case .poolCreateInFlight(let template, let clones)? = refusal as? TemplateError else {
                return XCTFail("expected poolCreateInFlight, got \(refusal)")
            }
            XCTAssertEqual(template, record.name)
            XCTAssertEqual(clones.count, 1)
            XCTAssertTrue(clones[0].hasPrefix("simq-pool-"), clones[0])
            XCTAssertTrue("\(refusal)".contains("being cloned from template \(record.name)"), "\(refusal)")
        }
        XCTAssertEqual(
            try store.auditEntries().filter { $0.type == "template_remove_refused" }.count, protectedAttempts)
        XCTAssertEqual(try store.poolSims().count, 1, "the create still finished")
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty, "the template wasn't deleted mid-clone")
        XCTAssertEqual(try engine.removeTemplate(record.name), .removed, "allowed once the create is done")
    }

    func testBuildingATemplateRequiresExplicitSelectionBeforePoolCreation() throws {
        let (harness, store, engine) = try start()
        harness.sims.clonesTemplate = true
        let record = try engine.buildTemplate(request())
        XCTAssertNil(harness.sims.defaultTemplate)
        XCTAssertNil(harness.sims.cloneSource)
        XCTAssertEqual(try engine.poolPass(config: SimPoolConfig(), demand: 1).createsDeferredNoTemplate, 1)
        XCTAssertTrue(try store.poolSims().isEmpty)
        harness.sims.configuredTemplateValue = record.udid
        _ = try engine.poolPass(config: SimPoolConfig(), demand: 1)
        XCTAssertEqual(harness.sims.clonedFrom, [record.udid])
    }

    func testChangingActiveTemplateRefusesOldCloneHandoffWhileBuildsCanProgress() throws {
        let (harness, store, engine) = try start()
        harness.sims.clonesTemplate = true
        harness.sims.configuredTemplateValue = "OLD"
        var config = SimPoolConfig()
        config.settle.mode = .off
        engine.pool = config
        for _ in 0..<3 { _ = try engine.poolPass(config: config, demand: 1) }
        XCTAssertEqual(try engine.poolCapacity().idleRunning, 1)
        harness.sims.configuredTemplateValue = "NEW"
        XCTAssertEqual(try engine.poolCapacity().idleRunning, 0)
        XCTAssertThrowsError(try engine.acquirePoolSim(leaseID: "must-not-get-old-runtime")) {
            XCTAssertTrue(String(describing: $0).contains("Drain all jobs and leases"))
        }
        XCTAssertThrowsError(try engine.poolPass(config: config, demand: 1))
        let simulator = try harness.submit(store, resources: ResourceRequest(minSims: 1))
        let build = try harness.submit(store, resources: ResourceRequest(minSims: 0))
        XCTAssertEqual(try engine.tick().admitted, [build.id])
        XCTAssertEqual(try store.job(id: simulator.id)?.state, .queued)
        XCTAssertTrue(try store.poolSims().allSatisfy { $0.leaseID == nil })
    }

    /// CR on #63 follow-up 1: the intent records the source before the unlocked create. If the
    /// configured template switches in between, the clone must still copy
    /// the recorded source, so the intent, the rm guard and `cloned_from` all name what was
    /// actually cloned.
    func testAPoolCreateClonesTheRecordedSourceEvenIfConfigurationChangesMidCreate() throws {
        let (harness, store, engine) = try start()
        harness.sims.clonesTemplate = true
        let record = try engine.buildTemplate(request())
        harness.sims.configuredTemplateValue = record.udid
        XCTAssertEqual(harness.sims.cloneSource, record.udid)
        var pool = SimPoolConfig()
        pool.maxSims = 1
        var recorded: [String] = []
        _ = try engine.poolPass(config: pool, demand: 1) { body in
            recorded = try store.pendingActionIntents().map(\.detail)
            // What a refresh landing while the clone runs unlocked would do.
            harness.sims.configuredTemplateValue = "NEWER-UDID"
            try body()
        }
        XCTAssertEqual(recorded.count, 1)
        XCTAssertTrue(recorded[0].contains("\"source\":\"\(record.udid)\""), recorded[0])
        XCTAssertEqual(harness.sims.clonedFrom, [record.udid], "cloned the recorded source, not the new default")
        XCTAssertEqual(try store.poolSims().first?.clonedFrom, TemplateRef(udid: record.udid, name: record.name))
    }

    /// A template that isn't `ready` (`unverified` after a crash mid-build, or `slim_failed`)
    /// is never cloned, even when `simctl.template` names it: the pool holds its creates and
    /// audits why once, until the template is rebuilt with `--replace` or removed.
    func testThePoolNeverClonesATemplateThatIsntReady() throws {
        let (harness, store, engine) = try start()
        let pending = try engine.beginTemplateBuild(request(), versions: harness.sims.versions)
        guard case .built = Engine.performTemplateBuild(pending, builder: harness.sims) else {
            return XCTFail("create failed")
        }
        // A crash before register: the next daemon registers it as unverified.
        let (restarted, _, _) = try harness.startWithActivePool(store: store)
        let entry = try XCTUnwrap(restarted.templates().first)
        XCTAssertEqual(entry.record.status, "unverified")
        harness.sims.clonesTemplate = true
        var pool = SimPoolConfig()
        pool.maxSims = 1
        for configured in [entry.record.name, entry.record.udid] {
            harness.sims.configuredTemplateValue = configured
            let report = try restarted.poolPass(config: pool, demand: 1)
            XCTAssertEqual(report.createsDeferredUnreadyTemplate, 1, configured)
            _ = try restarted.poolPass(config: pool, demand: 1)
        }
        XCTAssertEqual(harness.sims.clonedFrom, [], "never cloned the unverified template")
        XCTAssertTrue(try store.poolSims().isEmpty)
        let audits = try store.auditEntries().filter { $0.type == "pool_create_deferred_unready_template" }
        XCTAssertEqual(audits.count, 1, "once per template (by name or UDID), not every pass")
        XCTAssertEqual(
            audits.first?.detail,
            "1 creates: template \(entry.record.name) is unverified, not ready; "
                + "rebuild it with simq template build --replace, or remove it with simq template rm")

        // Rebuilt: ready again, and the pool clones it.
        let rebuilt = try restarted.buildTemplate(request(replace: true))
        XCTAssertEqual(rebuilt.status, "ready")
        harness.sims.configuredTemplateValue = rebuilt.name
        let report = try restarted.poolPass(config: pool, demand: 1)
        XCTAssertEqual(report.createsDeferredUnreadyTemplate, 0)
        XCTAssertEqual(harness.sims.clonedFrom, [rebuilt.udid], "name selection captures the canonical source UUID")
        XCTAssertEqual(try store.poolSims().first?.clonedFrom, TemplateRef(udid: rebuilt.udid, name: rebuilt.name))
    }

    /// CR #61 follow-up 1: `simctl.template` may select a template by name. The intent
    /// captures its canonical UDID, and `rm` by UDID or name still sees the clone in flight.
    func testRemoveIsRefusedWhileAPoolCreateClonesTheTemplateNamedByName() throws {
        let (harness, store, engine) = try start()
        let record = try engine.buildTemplate(request())
        harness.sims.cloneSource = record.name
        var pool = SimPoolConfig()
        pool.maxSims = 1
        var refusals: [any Error] = []
        var protectedPhases: Set<String> = []
        var protectedAttempts = 0
        _ = try engine.poolPass(config: pool, demand: 1) { body in
            let intent = try XCTUnwrap(try store.pendingActionIntents().first)
            protectedPhases.insert(try Engine.poolCloneOperation(intent).phase.rawValue)
            for target in [record.udid, record.name] {
                XCTAssertThrowsError(try engine.removeTemplate(target)) { refusals.append($0) }
                protectedAttempts += 1
            }
            try body()
        }
        XCTAssertEqual(protectedPhases, ["recorded", "started"], "protect both preflight and host mutation")
        XCTAssertEqual(refusals.count, protectedAttempts)
        for refusal in refusals {
            guard case .poolCreateInFlight(let template, let clones)? = refusal as? TemplateError else {
                return XCTFail("expected poolCreateInFlight, got \(refusal)")
            }
            XCTAssertEqual(template, record.name)
            XCTAssertEqual(clones.count, 1)
        }
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
        XCTAssertEqual(try engine.removeTemplate(record.name), .removed)
    }

    /// A pool sim records the template it was cloned from, by UDID and name, whichever
    /// of the two the backend's clone source gives.
    func testAPoolSimRecordsTheTemplateItWasClonedFrom() throws {
        for byName in [false, true] {
            let (harness, store, engine) = try start()
            let record = try engine.buildTemplate(request())
            harness.sims.cloneSource = byName ? record.name : record.udid
            var pool = SimPoolConfig()
            pool.maxSims = 1
            _ = try engine.poolPass(config: pool, demand: 1)
            let sim = try XCTUnwrap(try store.poolSims().first)
            XCTAssertEqual(sim.clonedFrom, TemplateRef(udid: record.udid, name: record.name), "byName=\(byName)")
        }
        // An unregistered source is kept as given.
        let (harness, store, engine) = try start()
        harness.sims.cloneSource = "AAAA-1111"
        var pool = SimPoolConfig()
        pool.maxSims = 1
        _ = try engine.poolPass(config: pool, demand: 1)
        XCTAssertEqual(try store.poolSims().first?.clonedFrom, TemplateRef(udid: "AAAA-1111", name: nil))
    }

    func testRemoveGoesThroughReportOnlyAndTheRateLimits() throws {
        // Report-only: audited, kept.
        var (harness, store, engine) = try start(.reportOnly)
        var record = try engine.buildTemplate(request())
        XCTAssertEqual(try engine.removeTemplate(record.name), .wouldRemove)
        XCTAssertTrue(try harness.sims.listDevices().contains { $0.udid == record.udid })
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "template_would_remove" }.count, 1)

        // Hourly limit already used up: postponed, kept.
        (harness, store, engine) = try start(.enforce, limits: (3, 1))
        record = try engine.buildTemplate(request())
        try store.audit(Engine.destructiveAuditType, detail: "earlier", now: harness.clock.now())
        XCTAssertEqual(try engine.removeTemplate(record.udid), .postponed)
        XCTAssertTrue(try harness.sims.listDevices().contains { $0.udid == record.udid })

        // Enforce: deleted under an intent, row released, counted as destructive.
        harness.clock.advance(by: 3601)
        XCTAssertEqual(try engine.removeTemplate(record.name), .removed)
        XCTAssertEqual(harness.sims.deletedUDIDs, [record.udid])
        XCTAssertTrue(try store.liveResources(kinds: [.template]).isEmpty)
        XCTAssertEqual(try store.auditEntries().filter { $0.type == Engine.destructiveAuditType }.count, 2)
        XCTAssertThrowsError(try engine.removeTemplate(record.name)) {
            XCTAssertEqual($0 as? TemplateError, .notFound(record.name))
        }
    }

    // MARK: - CR #44 MUST: a crash between create and register

    func testACrashBetweenCreateAndRegisterIsRegisteredByRecovery() throws {
        let (harness, store, engine) = try start()
        let pending = try engine.beginTemplateBuild(request(), versions: harness.sims.versions)
        XCTAssertEqual(try store.pendingActionIntents().count, 1, "write-ahead: the intent comes first")
        guard case .built(let device, nil) = Engine.performTemplateBuild(pending, builder: harness.sims) else {
            return XCTFail("create failed")
        }
        // SIGKILL here: the sim exists, no template row. The next daemon recovers it.
        XCTAssertTrue(try store.liveResources(kinds: [.template]).isEmpty)
        let (restarted, _, _) = try harness.startWithActivePool(store: store)
        let entry = try XCTUnwrap(restarted.templates().first)
        XCTAssertEqual(entry.record.udid, device.udid)
        XCTAssertEqual(entry.record.name, pending.record.name)
        XCTAssertEqual(entry.record.status, "unverified", "the slim may not have run")
        XCTAssertEqual(entry.record.deviceType, "iPhone-X-fake")
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
        XCTAssertEqual(try store.auditEntries().filter { $0.type == "template_recovered" }.count, 1)
        XCTAssertTrue(try restarted.unregisteredTemplateSims().isEmpty)
        for _ in 0..<8 {
            harness.clock.advance(by: 900)
            _ = try restarted.watchdogPass(.full, config: watchdog)
        }
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
    }

    func testAHalfFailedCreateLeavesAnUnregisteredTemplateThatRmCanRemove() throws {
        let (harness, store, engine) = try start(.reportOnly)
        harness.sims.baseCreateFailsAfterCreating = true
        XCTAssertThrowsError(try engine.buildTemplate(request())) {
            guard case .createFailed = $0 as? TemplateError else { return XCTFail("\($0)") }
        }
        let leftover = try XCTUnwrap(engine.unregisteredTemplateSims().first)
        XCTAssertTrue(try engine.templates().isEmpty)
        XCTAssertEqual(try engine.removeTemplate(leftover.udid), .wouldRemove, "report-only keeps it")
        harness.reliability.cleanupMode = .enforce
        let (enforcing, _, _) = try harness.startWithActivePool(store: store)
        XCTAssertEqual(try enforcing.removeTemplate(leftover.udid), .removed)
        XCTAssertEqual(harness.sims.deletedUDIDs, [leftover.udid])
        XCTAssertTrue(try enforcing.unregisteredTemplateSims().isEmpty)
    }

    func testABackendThatCantSlimIsRefusedBeforeAnythingIsCreated() throws {
        let (harness, store, engine) = try start()
        harness.sims.slimWired = false
        XCTAssertThrowsError(try engine.buildTemplate(request())) {
            XCTAssertEqual($0 as? TemplateError, .slimNotWired)
        }
        XCTAssertTrue(harness.sims.baseCreates.isEmpty)
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
    }

    func testOneBuildPerProjectAndProfileAtATime() throws {
        let (harness, _, engine) = try start()
        _ = try engine.beginTemplateBuild(request(), versions: harness.sims.versions)
        XCTAssertThrowsError(try engine.beginTemplateBuild(request(replace: true), versions: harness.sims.versions)) {
            XCTAssertEqual($0 as? TemplateError, .inProgress(project: "demo", profile: "default"))
        }
    }

    /// Watchdog passes while a build runs (the service lock is free then) leave it alone:
    /// the guard against a second build holds, and the build registers as ready.
    func testWatchdogPassesDuringABuildLeaveItAlone() throws {
        let (harness, store, engine) = try start()
        let pending = try engine.beginTemplateBuild(request(), versions: harness.sims.versions)
        for kind in [WatchdogPassKind.light, .full] {  // between begin and perform
            harness.clock.advance(by: 60)
            _ = try engine.watchdogPass(kind, config: watchdog)
        }
        XCTAssertEqual(try store.pendingActionIntents().map(\.id), [pending.intent.id], "not abandoned")
        XCTAssertThrowsError(try engine.beginTemplateBuild(request(replace: true), versions: harness.sims.versions)) {
            XCTAssertEqual($0 as? TemplateError, .inProgress(project: "demo", profile: "default"))
        }
        let outcome = Engine.performTemplateBuild(pending, builder: harness.sims)
        for kind in [WatchdogPassKind.light, .full] {  // between perform and finish
            harness.clock.advance(by: 60)
            _ = try engine.watchdogPass(kind, config: watchdog)
        }
        XCTAssertTrue(try store.liveResources(kinds: [.template]).isEmpty, "not registered by recovery")
        let record = try engine.finishTemplateBuild(pending, outcome: outcome)
        XCTAssertEqual(record.status, "ready")
        XCTAssertEqual(try engine.templates().map(\.record), [record])
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
        XCTAssertTrue(try store.auditEntries().filter { $0.type == "template_recovered" }.isEmpty)
        // The next build is free to start once this one finished.
        XCTAssertNoThrow(try engine.beginTemplateBuild(request(replace: true), versions: harness.sims.versions))
    }

    /// If recovery did register the build (another daemon instance on the same state),
    /// finish rewrites that row instead of acquiring a second, and confirms nothing.
    func testFinishAfterRecoveryUpdatesTheRowAndConfirmsNothing() throws {
        let (harness, store, engine) = try start()
        let pending = try engine.beginTemplateBuild(request(), versions: harness.sims.versions)
        let outcome = Engine.performTemplateBuild(pending, builder: harness.sims)
        // Starting another engine on the state runs recovery; it has no in-flight builds.
        let (other, _, _) = try harness.startWithActivePool(store: store)
        XCTAssertTrue(try store.pendingActionIntents().isEmpty, "recovery confirmed the create")
        XCTAssertEqual(try other.templates().map(\.record.status), ["unverified"])
        let record = try engine.finishTemplateBuild(pending, outcome: outcome)
        XCTAssertEqual(record.status, "ready")
        XCTAssertEqual(try store.liveResources(kinds: [.template]).count, 1)
        XCTAssertEqual(try engine.templates().map(\.record.status), ["ready"])
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
    }

    /// "a-b"/"c" and "a"/"b-c" share a name prefix but are different builds.
    func testInProgressGuardDoesNotConfuseHyphenatedNames() throws {
        let (harness, _, engine) = try start()
        func request(_ project: String, _ profile: String) -> TemplateBuildRequest {
            TemplateBuildRequest(
                project: project, profile: profile, slimArguments: [], deviceType: "iPhone-X-fake",
                runtime: "iOS-26-0")
        }
        _ = try engine.beginTemplateBuild(request("a-b", "c"), versions: harness.sims.versions)
        XCTAssertNoThrow(try engine.beginTemplateBuild(request("a", "b-c"), versions: harness.sims.versions))
        XCTAssertThrowsError(try engine.beginTemplateBuild(request("a-b", "c"), versions: harness.sims.versions)) {
            XCTAssertEqual($0 as? TemplateError, .inProgress(project: "a-b", profile: "c"))
        }
    }
}

extension Harness {
    /// Template builds need a pool that acts on the host (`pool.mode: active`).
    func startWithActivePool(store: JobStore) throws -> (Engine, RecoveryReport, ReconcileReport) {
        let started = try start(store: store)
        var pool = SimPoolConfig()
        pool.mode = .active
        started.0.pool = pool
        return started
    }
}
