// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

@testable import SimQueueEngine

/// Templates were called goldens. A `simq-golden-...` sim and the ownership row an older
/// simqd wrote for it (kind stored as `golden`) are adopted as a template after the rename:
/// listed, cloned by default, never reaped, and protected by the `rm` guard.
final class TemplateLegacyGoldenTests: XCTestCase {
    let watchdog = WatchdogConfig()
    /// Synthetic template metadata written by a pre-rename daemon.
    let udid = "11111111-2222-4333-8444-555555555555"
    let simName = "simq-golden-exampleapp-default-1"
    var legacyDetail: String {
        #"{"built_at":1792525609.002513,"device_type":"iPhone 17","name":"\#(simName)","profile":"default","#
            + #""project":"exampleapp","runtime":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","#
            + #""runtime_version":"27.0","status":"ready","udid":"\#(udid)","#
            + #""xcode_version":"Xcode 27.0 Build version 27A266a"}"#
    }

    /// A store holding the row exactly as the pre-rename simqd wrote it (an older epoch),
    /// the sim on the host, and an engine started on top (a reinstall).
    private func start() throws -> (Harness, JobStore, Engine) {
        let harness = Harness(
            reliability: ReliabilityConfig(
                cleanupMode: .enforce, maxDestructiveActionsPerPass: 3, maxDestructiveActionsPerHour: 10))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        try store.database.run(
            """
            INSERT INTO owned_resources (kind, external_id, owner_kind, epoch, generation, state, acquired_at, detail)
            VALUES ('golden', ?, 'pool', 0, 0, 'active', 0, ?);
            """, [.text(udid), .text(legacyDetail)])
        harness.sims.setDevices([SimDevice(udid: udid, name: simName, isBooted: false)])
        harness.sims.clonesTemplate = true
        let (engine, _, _) = try harness.startWithActivePool(store: store)
        return (harness, store, engine)
    }

    private func storedKinds(_ store: JobStore) throws -> [String] {
        try store.database.query("SELECT kind FROM owned_resources WHERE external_id = ?;", [.text(udid)])
            .compactMap { $0.string("kind") }
    }

    func testALegacyGoldenRowAndSimAreAdoptedAsATemplate() throws {
        let (harness, store, engine) = try start()
        let entry = try XCTUnwrap(engine.templates().first)
        XCTAssertEqual(entry.record.name, simName)
        XCTAssertEqual(entry.record.udid, udid)
        XCTAssertEqual(entry.record.status, "ready")
        XCTAssertTrue(try engine.unregisteredTemplateSims().isEmpty, "registered, by its old row")

        // Watchdog passes adopt the row (new epoch) and never plan to delete the sim.
        XCTAssertFalse(try engine.plannedReconcile().contains { "\($0)".contains("deleteSim(udid: \"\(udid)\"") })
        for _ in 0..<8 {
            harness.clock.advance(by: 900)
            let pass = try engine.watchdogPass(.full, config: watchdog)
            XCTAssertTrue(pass.reconcile.failures.isEmpty, "\(pass.reconcile.failures)")
        }
        let row = try XCTUnwrap(store.liveResources(kinds: [.template]).first)
        XCTAssertEqual(row.epoch, engine.epoch, "adopted by the new daemon")
        XCTAssertEqual(row.owner, .pool)
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
        XCTAssertEqual(try storedKinds(store), ["golden"], "the stored kind is unchanged, so a rollback reads it")

        // Legacy records remain usable after explicit host-wide selection.
        engine.refreshDefaultTemplate()
        XCTAssertNil(harness.sims.defaultTemplate)
        harness.sims.configuredTemplateValue = udid
        var pool = SimPoolConfig()
        pool.maxSims = 1
        _ = try engine.poolPass(config: pool, demand: 1)
        XCTAssertEqual(harness.sims.clonedFrom, [udid])
    }

    func testRemovingALegacyGoldenIsRefusedWhileAPoolCreateClonesIt() throws {
        let (harness, store, engine) = try start()
        engine.refreshDefaultTemplate()
        harness.sims.configuredTemplateValue = udid
        XCTAssertEqual(harness.sims.cloneSource, udid)
        var pool = SimPoolConfig()
        pool.maxSims = 1
        var refusals: [any Error] = []
        var protectedPhases: Set<String> = []
        var protectedAttempts = 0
        _ = try engine.poolPass(config: pool, demand: 1) { body in
            let intent = try XCTUnwrap(try store.pendingActionIntents().first)
            protectedPhases.insert(try Engine.poolCloneOperation(intent).phase.rawValue)
            for target in [simName, udid] {
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
            XCTAssertEqual(template, simName)
            XCTAssertEqual(clones.count, 1)
        }
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty, "not deleted mid-clone")
        XCTAssertEqual(try engine.removeTemplate(simName), .removed, "allowed once the create is done")
        XCTAssertEqual(harness.sims.deletedUDIDs, [udid])
        XCTAssertTrue(try store.liveResources(kinds: [.template]).isEmpty)
    }

    /// An unregistered `simq-golden-...` sim (no row) is exempt from the reaper, like an
    /// unregistered `simq-template-...` one, and doctor's list of unregistered templates has it.
    func testAnUnregisteredLegacyGoldenSimIsNeverReaped() throws {
        let harness = Harness(
            reliability: ReliabilityConfig(
                cleanupMode: .enforce, maxDestructiveActionsPerPass: 3, maxDestructiveActionsPerHour: 10))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.startWithActivePool(store: store)
        let legacy = SimDevice(udid: "GOLD-2", name: "simq-golden-demo-slim", isBooted: false)
        let leak = SimDevice(udid: "LEAK-2", name: "simq-pool-1-6", isBooted: false)
        harness.sims.setDevices([legacy, leak])
        harness.clock.advance(by: 3600)
        XCTAssertEqual(try engine.plannedReconcile(), [.deleteSim(udid: "LEAK-2", resourceID: nil)])
        for _ in 0..<8 {
            _ = try engine.watchdogPass(.full, config: watchdog)
            harness.clock.advance(by: 900)
        }
        XCTAssertEqual(harness.sims.deletedUDIDs, ["LEAK-2"])
        XCTAssertEqual(try engine.unregisteredTemplateSims().map(\.udid), ["GOLD-2"])
    }

    /// A build that crashed between create and register under an older simqd left a
    /// `golden-pending` intent: the next daemon still registers the sim.
    func testALegacyPendingIntentIsStillRecovered() throws {
        let harness = Harness(
            reliability: ReliabilityConfig(
                cleanupMode: .enforce, maxDestructiveActionsPerPass: 3, maxDestructiveActionsPerHour: 10))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.startWithActivePool(store: store)
        let pending = try engine.beginTemplateBuild(
            TemplateBuildRequest(
                project: "demo", profile: "default", slimArguments: [], deviceType: "iPhone-X-fake",
                runtime: "iOS-26-0", replace: false),
            versions: harness.sims.versions)
        var legacy = pending.intent
        XCTAssertTrue(legacy.detail.hasPrefix("template-pending "))
        legacy.detail = "golden-pending " + legacy.detail.dropFirst("template-pending ".count)
        try store.updateActionIntentDetail(legacy)
        guard case .built(let device, nil) = Engine.performTemplateBuild(pending, builder: harness.sims) else {
            return XCTFail("create failed")
        }
        let (restarted, _, _) = try harness.startWithActivePool(store: store)
        let entry = try XCTUnwrap(restarted.templates().first)
        XCTAssertEqual(entry.record.udid, device.udid)
        XCTAssertEqual(entry.record.status, "unverified")
        XCTAssertTrue(try store.pendingActionIntents().isEmpty)
    }
}
