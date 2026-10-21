// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

/// QUO-386 replay gaps (spec §10): the crash replay with sims made by the pool manager's
/// own create path (simq-style names), a shut-down sibling that was never deleted, a
/// lookalike and another tool's sim, replayed in enforce and in report-only mode.
final class PoolCrashReplayTests: XCTestCase {
    let watchdog = WatchdogConfig()

    private struct World {
        var harness: Harness
        var store: JobStore
        var pooled: [SimDevice]
        var sibling: SimDevice
        var lookalike = SimDevice(udid: "LOOK-1", name: "SimQ Pool 3", isBooted: true)
        var otherTool = SimDevice(udid: "OTHER-1", name: "xctool-runner-1", isBooted: false)
    }

    /// Pool sims created through `poolPass` by a daemon in enforce mode (a report-only pool
    /// creates nothing); then that daemon is SIGKILLed with a shut-down leftover (a
    /// pool-style name, no row: its delete never happened) beside them, and its successor
    /// runs in `mode`.
    private func crashedWorld(_ mode: CleanupMode, path: String) throws -> World {
        let harness = Harness(path: path, reliability: ReliabilityConfig(cleanupMode: .enforce))
        let store = try JobStore(path: path, maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        var config = SimPoolConfig()
        config.settle.mode = .load
        config.maxSims = 2
        config.maxConcurrentBoots = 2
        engine.pool = config
        for _ in 0..<6 where try store.poolSims().filter({ $0.phase == .ready }).count < 2 {
            _ = try engine.poolPass(config: config, demand: 2)
            harness.clock.advance(by: 30)
        }
        let pooled = try harness.sims.listDevices()
        XCTAssertEqual(pooled.count, 2)
        let naming = SimNamingScheme()
        for sim in pooled {
            XCTAssertTrue(sim.name.hasPrefix("simq-pool-"), "the pool manager's simq-style name: \(sim.name)")
            XCTAssertTrue(naming.owns(sim.name))
        }
        let sibling = SimDevice(udid: "SIB-1", name: naming.poolSimName(slot: 3, intentID: 999), isBooted: false)
        harness.reliability = ReliabilityConfig(cleanupMode: mode)
        var world = World(harness: harness, store: store, pooled: pooled, sibling: sibling)
        harness.sims.setDevices(pooled + [sibling, world.lookalike, world.otherTool])
        world.store = try JobStore(path: path, maxQueuedPerSubmitterPerProject: 0)  // the SIGKILLed daemon's successor
        return world
    }

    func testEnforceReapsOnlyTheShutDownSibling() throws {
        let path = NSTemporaryDirectory() + "simq-pool-replay-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let world = try crashedWorld(.enforce, path: path)
        world.harness.clock.advance(by: 30)
        let (restarted, _, _) = try world.harness.start(store: world.store)
        for _ in 0..<(2 * 96) {
            world.harness.clock.advance(by: 900)
            _ = try restarted.watchdogPass(.full, config: watchdog)
        }
        XCTAssertEqual(world.harness.sims.deletedUDIDs, [world.sibling.udid], "only the unowned sibling")
        let left = try world.harness.sims.listDevices()
        for sim in world.pooled + [world.lookalike, world.otherTool] {
            XCTAssertTrue(left.contains { $0.udid == sim.udid }, sim.name)
        }
        XCTAssertEqual(try world.store.alerts().filter { $0.key.contains("LOOK-1") }.map(\.count), [1])
        XCTAssertFalse(try world.store.alerts().contains { $0.key.contains("OTHER-1") }, "other tools: no alert")
        XCTAssertEqual(
            try world.store.auditEntries().filter { $0.type == Engine.destructiveAuditType }.count, 1)
    }

    func testReportOnlyReplayTouchesNothingAndReportsTheSiblingOnce() throws {
        let path = NSTemporaryDirectory() + "simq-pool-replay-ro-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let world = try crashedWorld(.reportOnly, path: path)
        world.harness.clock.advance(by: 30)
        let (restarted, _, _) = try world.harness.start(store: world.store)
        var wouldDelete = false
        for _ in 0..<(2 * 96) {
            world.harness.clock.advance(by: 900)
            let pass = try restarted.watchdogPass(.full, config: watchdog)
            wouldDelete =
                wouldDelete
                || pass.reconcile.wouldExecute.contains(.deleteSim(udid: world.sibling.udid, resourceID: nil))
        }
        XCTAssertTrue(wouldDelete, "the sibling is reported as would-delete")
        XCTAssertTrue(world.harness.sims.deletedUDIDs.isEmpty, "report-only deletes nothing")
        XCTAssertEqual(try world.harness.sims.listDevices().count, 5)
        let reported = try world.store.auditEntries().filter {
            $0.type == "cleanup_would_execute" && $0.detail?.contains(world.sibling.udid) == true
        }
        XCTAssertEqual(reported.count, 1, "reported once, not every pass")
        XCTAssertTrue(try world.store.auditEntries().filter { $0.type == Engine.destructiveAuditType }.isEmpty)
        XCTAssertEqual(try world.store.alerts().filter { $0.key.contains("LOOK-1") }.map(\.count), [1])
    }
}
