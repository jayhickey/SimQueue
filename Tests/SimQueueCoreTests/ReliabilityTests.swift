// SPDX-License-Identifier: MIT

import XCTest

@testable import SimQueueCore

final class ReliabilityTests: XCTestCase {
    private let naming = SimNamingScheme()
    private let layout = RunDirectoryLayout(root: "/var/simq")

    private func resource(
        _ id: Int64,
        _ kind: OwnedResourceKind,
        _ externalID: String,
        owner: ResourceOwner = .job("J-1"),
        epoch: Int64 = 2,
        state: OwnedResourceState = .active
    ) -> OwnedResource {
        OwnedResource(
            id: id, kind: kind, externalID: externalID, owner: owner, epoch: epoch, generation: id, state: state,
            acquiredAt: 0)
    }

    private func plan(
        _ resources: [OwnedResource], active: Set<String> = [], world: ObservedWorld,
        allowlist: ForeignResourceAllowlist = .init()
    )
        -> [ReconcileAction]
    {
        Reconciler.plan(
            resources: resources, activeJobs: active, epoch: 2, world: world, naming: naming, layout: layout,
            foreignAllowlist: allowlist)
    }

    // MARK: - Defaults

    func testReliabilityDefaults() {
        let config = ReliabilityConfig()
        XCTAssertEqual(config.cleanupMode, .reportOnly)
        XCTAssertEqual(config.orphanGraceSeconds, 600)
        XCTAssertEqual(config.idleShutdownSeconds, 1800)
        XCTAssertEqual(config.recycleAfterSeconds, 7 * 86_400)
        XCTAssertEqual(config.maxDestructiveActionsPerPass, 3)
        XCTAssertEqual(config.maxDestructiveActionsPerHour, 10)
        XCTAssertFalse(config.foreignAllowlist.enabled)
    }

    // MARK: - Layout

    func testRunDirectoryLayoutManagesOnlyDirectChildren() {
        XCTAssertEqual(layout.runDir(jobID: "J-0001"), "/var/simq/runs/J-0001")
        XCTAssertEqual(layout.derivedDataDir(jobID: "J-0001"), "/var/simq/derived-data/J-0001")
        XCTAssertTrue(layout.isManaged("/var/simq/runs/J-0001"))
        XCTAssertFalse(layout.isManaged("/var/simq/runs"))
        XCTAssertFalse(layout.isManaged("/var/simq/runs/"))
        XCTAssertFalse(layout.isManaged("/var/simq/runs/J-1/nested"))
        XCTAssertFalse(layout.isManaged("/var/simq/other/J-1"))
        XCTAssertFalse(layout.isManaged("/Users/jay/Developer"))
        XCTAssertEqual(RunDirectoryLayout(root: "/var/simq/").root, "/var/simq")
    }

    // MARK: - Reconciler

    func testLiveOwnerKeepsEverything() {
        let resources = [
            resource(1, .sim, "U1"), resource(2, .processGroup, "500"),
            resource(3, .runDir, layout.runDir(jobID: "J-1")),
            resource(4, .lease, "J-1"),
        ]
        let world = ObservedWorld(
            sims: [SimDevice(udid: "U1", name: "simq-pool-1", isBooted: true)],
            liveProcessGroups: [500],
            managedDirectories: [layout.runDir(jobID: "J-1")]
        )
        XCTAssertEqual(plan(resources, active: ["J-1"], world: world), [])
    }

    func testDeadOwnerCleansUpInSafeOrder() {
        let resources = [
            resource(1, .runDir, layout.runDir(jobID: "J-1")), resource(2, .sim, "U1"),
            resource(3, .processGroup, "500"),
            resource(4, .lease, "J-1"),
        ]
        let world = ObservedWorld(
            sims: [SimDevice(udid: "U1", name: "simq-pool-1", isBooted: true)],
            liveProcessGroups: [500],
            managedDirectories: [layout.runDir(jobID: "J-1")]
        )
        XCTAssertEqual(
            plan(resources, world: world),
            [
                .killProcessGroup(pgid: 500, resourceID: 3), .revokeLease(resourceID: 4),
                .deleteSim(udid: "U1", resourceID: 2),
                .removeDirectory(path: layout.runDir(jobID: "J-1"), resourceID: 1),
            ]
        )
    }

    func testOwnerFromOlderEpochCountsAsDead() {
        let resources = [resource(1, .processGroup, "500", epoch: 1)]
        XCTAssertEqual(
            plan(resources, active: ["J-1"], world: ObservedWorld(liveProcessGroups: [500])),
            [.killProcessGroup(pgid: 500, resourceID: 1)]
        )
    }

    func testVanishedResourcesAreMarkedGone() {
        let resources = [
            resource(1, .sim, "U1", owner: .pool), resource(2, .processGroup, "500"),
            resource(3, .derivedDataDir, "/var/simq/derived-data/J-1"),
        ]
        XCTAssertEqual(
            plan(resources, world: ObservedWorld()),
            [.markGone(resourceID: 1), .markGone(resourceID: 2), .markGone(resourceID: 3)])
    }

    func testPoolSimsFromOldEpochAreAdoptedNotDeleted() {
        let resources = [resource(1, .sim, "U1", owner: .pool, epoch: 1)]
        let world = ObservedWorld(sims: [SimDevice(udid: "U1", name: "simq-pool-1", isBooted: false)])
        XCTAssertEqual(plan(resources, world: world), [.adopt(resourceID: 1)])
    }

    /// The one name exemption (#36): `simq-template-...` sims are never reaped.
    func testUnknownSimsInNamespaceAreLeaksExceptTemplates() {
        let world = ObservedWorld(sims: [
            SimDevice(udid: "U1", name: "simq-pool-9", isBooted: true),
            SimDevice(udid: "U2", name: "simq-template-app-iphone", isBooted: false),
            SimDevice(udid: "U3", name: "My Phone Sim", isBooted: true),
            SimDevice(udid: "U4", name: "iPhone 17 Pro", isBooted: false),
        ])
        XCTAssertEqual(
            plan([], world: world),
            [
                .reportForeignSim(udid: "U3", name: "My Phone Sim"),
                .reportForeignSim(udid: "U4", name: "iPhone 17 Pro"),
                .deleteSim(udid: "U1", resourceID: nil),
            ]
        )
    }

    func testUnknownDirectoriesUnderManagedRootsAreLeaks() {
        let world = ObservedWorld(managedDirectories: ["/var/simq/runs/J-9", "/elsewhere/x"])
        XCTAssertEqual(plan([], world: world), [.removeDirectory(path: "/var/simq/runs/J-9", resourceID: nil)])
    }

    func testForeignAllowlistIsDisabledByDefaultAndOnlyWidens() {
        let world = ObservedWorld(sims: [SimDevice(udid: "U3", name: "Legacy Slot 1", isBooted: true)])
        XCTAssertEqual(plan([], world: world), [.reportForeignSim(udid: "U3", name: "Legacy Slot 1")])
        let disabled = ForeignResourceAllowlist(enabled: false, simNamePrefixes: ["Legacy Slot"])
        XCTAssertEqual(
            plan([], world: world, allowlist: disabled), [.reportForeignSim(udid: "U3", name: "Legacy Slot 1")])
        let enabled = ForeignResourceAllowlist(enabled: true, simNamePrefixes: ["Legacy Slot"])
        XCTAssertEqual(plan([], world: world, allowlist: enabled), [.deleteSim(udid: "U3", resourceID: nil)])
        XCTAssertFalse(ForeignResourceAllowlist(enabled: true, simNamePrefixes: [""]).allowsSim(named: "anything"))
    }

    // MARK: - Cleanup gate

    func testGateWaitsForOrphanGrace() {
        var gate = CleanupGate(config: ReliabilityConfig(cleanupMode: .enforce), executedLastHour: 0)
        XCTAssertEqual(gate.decide(firstSeenAt: 0, now: 599), .deferGrace(remainingSeconds: 1))
        XCTAssertEqual(gate.decide(firstSeenAt: 0, now: 600), .execute)
    }

    func testGateIsReportOnlyByDefault() {
        var gate = CleanupGate(config: ReliabilityConfig(), executedLastHour: 0)
        XCTAssertEqual(gate.decide(firstSeenAt: 0, now: 10_000), .wouldExecute)
        XCTAssertEqual(gate.executedThisPass, 0)
    }

    func testGateEnforcesPerPassAndPerHourLimits() {
        var gate = CleanupGate(config: ReliabilityConfig(cleanupMode: .enforce), executedLastHour: 0)
        let decisions = (0..<5).map { _ in gate.decide(firstSeenAt: 0, now: 1_000) }
        XCTAssertEqual(decisions, [.execute, .execute, .execute, .deferRateLimit, .deferRateLimit])

        var hourly = CleanupGate(config: ReliabilityConfig(cleanupMode: .enforce), executedLastHour: 9)
        XCTAssertEqual(hourly.decide(firstSeenAt: 0, now: 1_000), .execute)
        XCTAssertEqual(hourly.decide(firstSeenAt: 0, now: 1_000), .deferRateLimit)
    }

    func testDestructiveClassification() {
        XCTAssertTrue(ReconcileAction.killProcessGroup(pgid: 1, resourceID: 1).isDestructive)
        XCTAssertTrue(ReconcileAction.deleteSim(udid: "U", resourceID: nil).isDestructive)
        XCTAssertTrue(ReconcileAction.removeDirectory(path: "/p", resourceID: nil).isDestructive)
        XCTAssertFalse(ReconcileAction.markGone(resourceID: 1).isDestructive)
        XCTAssertFalse(ReconcileAction.adopt(resourceID: 1).isDestructive)
        XCTAssertFalse(ReconcileAction.revokeLease(resourceID: 1).isDestructive)
        XCTAssertFalse(ReconcileAction.reportForeignSim(udid: "U", name: "n").isDestructive)
    }

    // MARK: - Pool maintenance

    func testIdleShutdownKeepsWarmMinimum() {
        let sims = [
            PoolSimState(udid: "A", isBooted: true, isBusy: false, createdAt: 0, lastUsedAt: 100),
            PoolSimState(udid: "B", isBooted: true, isBusy: false, createdAt: 0, lastUsedAt: 200),
            PoolSimState(udid: "C", isBooted: true, isBusy: true, createdAt: 0, lastUsedAt: 0),
        ]
        let config = ReliabilityConfig()
        XCTAssertEqual(
            PoolMaintenance.plan(sims: sims, warmMin: 1, config: config, now: 200 + 1800), [.shutdown(udid: "A")])
        XCTAssertEqual(PoolMaintenance.plan(sims: sims, warmMin: 0, config: config, now: 100 + 1799), [])
        XCTAssertEqual(PoolMaintenance.plan(sims: sims, warmMin: 2, config: config, now: 100_000), [])
    }

    func testOldIdleSimsAreRecycledButBusyOnesWait() {
        let week = 7.0 * 86_400
        let sims = [
            PoolSimState(udid: "old", isBooted: false, isBusy: false, createdAt: 0, lastUsedAt: week),
            PoolSimState(udid: "busy", isBooted: true, isBusy: true, createdAt: 0, lastUsedAt: week),
            PoolSimState(udid: "new", isBooted: false, isBusy: false, createdAt: week - 1, lastUsedAt: week),
        ]
        XCTAssertEqual(
            PoolMaintenance.plan(sims: sims, warmMin: 0, config: ReliabilityConfig(), now: week),
            [.recycle(udid: "old")])
    }
}
