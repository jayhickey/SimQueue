// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

/// Report-only passes cost the same however many leftovers have piled up: once a leftover
/// is reported, a later pass that finds it unchanged reads it from memory and writes
/// nothing for it until it's due for re-confirmation.
final class ReportOnlyCostTests: XCTestCase {
    /// Database rows changed by `passes` full passes, after `leftovers` sims and dirs in
    /// SimQueue's namespace have been reported and their anomalies have gone sustained.
    private func steadyStateChanges(leftovers: Int, passes: Int = 10) throws -> Int64 {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .reportOnly))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        harness.sims.setDevices(
            (0..<leftovers).map { SimDevice(udid: "LEAK-\($0)", name: "simq-leak-\($0)", isBooted: false) })
        for index in 0..<leftovers {
            try harness.fileSystem.createDirectory(harness.layout.runDir(jobID: "J-leak-\(index)"))
        }
        let (engine, _, _) = try harness.start(store: store)
        // Past the grace periods (10 min sims, 1 h dirs) and the 1 h sustained threshold.
        for _ in 0..<18 {
            harness.clock.advance(by: 600)
            try engine.watchdogPass(.full, config: WatchdogConfig())
        }
        XCTAssertEqual(try store.anomalies().filter { $0.level == .sustained }.count, 2 * leftovers)
        let before = try totalChanges(store)
        let auditBefore = try store.auditEntries().count
        for _ in 0..<passes {
            harness.clock.advance(by: 600)
            let pass = try engine.watchdogPass(.full, config: WatchdogConfig())
            XCTAssertEqual(pass.reconcile.wouldExecute.count, 2 * leftovers)
        }
        XCTAssertEqual(try store.auditEntries().count, auditBefore, "nothing new to audit")
        XCTAssertTrue(harness.sims.deletedUDIDs.isEmpty)
        return try totalChanges(store) - before
    }

    private func totalChanges(_ store: JobStore) throws -> Int64 {
        try XCTUnwrap(store.database.query("SELECT total_changes() AS n;").first?.int("n"))
    }

    func testUnchangedLeftoversCostNothingPerPass() throws {
        let one = try steadyStateChanges(leftovers: 1)
        let many = try steadyStateChanges(leftovers: 60)
        XCTAssertEqual(many, one, "a pass over 60 old leftovers writes what a pass over 1 writes")
        XCTAssertLessThanOrEqual(one, 10 * 2, "only the watchdog's own bookkeeping per pass")
    }

    func testAnomaliesAreReconfirmedPeriodicallyAndSurviveARestart() throws {
        let path = NSTemporaryDirectory() + "simq-reconfirm-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let harness = Harness(path: path, reliability: ReliabilityConfig(cleanupMode: .reportOnly))
        var store = try JobStore(path: path, maxQueuedPerSubmitterPerProject: 0)
        store.anomalyReconfirmSeconds = 3600
        harness.sims.setDevices([SimDevice(udid: "LEAK-1", name: "simq-leak-1", isBooted: false)])
        var (engine, _, _) = try harness.start(store: store)
        for _ in 0..<12 {
            harness.clock.advance(by: 600)
            try engine.watchdogPass(.full, config: WatchdogConfig())
        }
        let live = try XCTUnwrap(store.anomalies().first)
        let persisted = try XCTUnwrap(JobStore(readOnlyPath: path).anomalies().first)
        XCTAssertEqual(live.level, .sustained)
        XCTAssertEqual(persisted.level, live.level, "level changes are written at once")
        XCTAssertLessThanOrEqual(live.lastSeenAt - persisted.lastSeenAt, 3600, "re-confirmed at least hourly")
        XCTAssertGreaterThanOrEqual(live.consecutivePasses, persisted.consecutivePasses)

        // A restart picks up what was persisted and keeps counting from there.
        store = try JobStore(path: path, maxQueuedPerSubmitterPerProject: 0)
        (engine, _, _) = try harness.start(store: store)
        harness.clock.advance(by: 600)
        try engine.watchdogPass(.full, config: WatchdogConfig())
        let after = try XCTUnwrap(store.anomalies().first)
        XCTAssertEqual(after.level, .sustained)
        XCTAssertEqual(after.firstSeenAt, live.firstSeenAt)
        XCTAssertGreaterThan(after.consecutivePasses, persisted.consecutivePasses)
    }

    func testALightPassNeitherListsSimsNorPlansForThem() throws {
        let harness = Harness(reliability: ReliabilityConfig(cleanupMode: .reportOnly))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        harness.sims.setDevices([SimDevice(udid: "LEAK-1", name: "simq-leak-1", isBooted: false)])
        let (engine, _, _) = try harness.start(store: store)
        harness.clock.advance(by: 600)
        let full = try engine.watchdogPass(.full, config: WatchdogConfig())
        XCTAssertEqual(full.reconcile.actions, [.deleteSim(udid: "LEAK-1", resourceID: nil)])

        // A light pass only covers process groups and leases, so a sim backend that can't
        // list doesn't stop it, and it plans nothing for sims.
        harness.sims.listFailure = .timedOut("simctl list devices")
        harness.clock.advance(by: 60)
        let light = try engine.watchdogPass(.light, config: WatchdogConfig())
        XCTAssertTrue(light.reconcile.actions.isEmpty)
        XCTAssertThrowsError(try engine.watchdogPass(.full, config: WatchdogConfig()))
        XCTAssertEqual(
            try store.anomalies().map(\.key), full.reconcile.anomalies.map(\.key), "the light pass kept the rest")
    }
}
