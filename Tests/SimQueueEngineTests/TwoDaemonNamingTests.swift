// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueSim
import SimQueueStore
import XCTest

/// Two daemons (two state dirs) on one host share the simulator list. Their intent ids
/// count separately, so untagged pool names collided, and each reaper saw the other's
/// row-less `simq-*` sims as leaks. Owner tags fix both.
final class TwoDaemonNamingTests: XCTestCase {
    private func daemon(_ tag: String, sims: FakeSimBackend, clock: ManualClock) throws -> (Engine, JobStore) {
        var reliability = ReliabilityConfig()
        reliability.cleanupMode = .enforce
        reliability.orphanGraceSeconds = 0
        let environment = EngineEnvironment(
            clock: clock, probe: SettableResourceProbe(healthyHost()), sims: sims, processes: FakeProcessTable(),
            fileSystem: FakeFileSystem(), layout: RunDirectoryLayout(root: "/fake/\(tag)"),
            naming: SimNamingScheme(ownerTag: tag))
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try Engine.start(
            store: store, environment: environment, config: SchedulerConfig(), reliability: reliability,
            timeouts: TimeoutConfig(), ownerID: tag, pid: 1)
        return (engine, store)
    }

    func testTwoDaemonsMakeDistinctNamesAndNeverReapEachOther() throws {
        let sims = FakeSimBackend()
        let clock = ManualClock(start: 1_800_000_000)
        let (a, storeA) = try daemon("d0000000a", sims: sims, clock: clock)
        let (b, storeB) = try daemon("d0000000b", sims: sims, clock: clock)
        var pool = SimPoolConfig()
        pool.maxSims = 1
        pool.settle.mode = .off
        _ = try a.poolPass(config: pool, demand: 1)
        _ = try b.poolPass(config: pool, demand: 1)
        let nameA = try XCTUnwrap(try storeA.poolSims().first?.name)
        let nameB = try XCTUnwrap(try storeB.poolSims().first?.name)
        XCTAssertEqual(nameA, "simq-pool-1-1-d0000000a")
        XCTAssertEqual(nameB, "simq-pool-1-1-d0000000b", "same slot and intent id, distinct names")

        // Each reconciles past the orphan grace, in enforce mode, several times.
        for _ in 0..<3 {
            clock.advance(by: 3600)
            _ = try a.reconcile()
            _ = try b.reconcile()
        }
        XCTAssertTrue(sims.deletedUDIDs.isEmpty, "neither reaped the other's sim: \(sims.deletedUDIDs)")
        XCTAssertEqual(Set(try sims.listDevices().map(\.name)), [nameA, nameB])

        // A real leak of A's own (no row) is still reaped by A only.
        try storeA.deletePoolSim(udid: try XCTUnwrap(try storeA.poolSims().first?.udid))
        for resource in try storeA.liveResources(kinds: [.sim]) {
            try storeA.markResourceReleased(id: resource.id, reason: "test: forget it", now: clock.now())
        }
        clock.advance(by: 3600)
        _ = try b.reconcile()
        XCTAssertTrue(sims.deletedUDIDs.isEmpty, "B never touches A's sim")
        _ = try a.reconcile()
        clock.advance(by: 3600)
        _ = try a.reconcile()
        XCTAssertEqual(try sims.listDevices().map(\.name), [nameB], "A reaped its own leak")
    }
}
