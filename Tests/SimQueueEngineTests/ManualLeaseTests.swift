// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueStore
import XCTest

/// A manual pool lease protects its sim only while its holder is live (pid + start time,
/// or a heartbeat within the orphan grace). Fakes only.
final class ManualLeaseTests: XCTestCase {
    private let holderPID: Int32 = 4242

    private func setUp(mode: CleanupMode, sims: Int = 1, perPass: Int = 3, perHour: Int = 10) throws -> (
        Harness, JobStore, Engine
    ) {
        let harness = Harness()
        // Warm the pool in enforce (report-only takes no pool host action), then restart in `mode`.
        harness.reliability.cleanupMode = .enforce
        harness.reliability.maxDestructiveActionsPerPass = perPass
        harness.reliability.maxDestructiveActionsPerHour = perHour
        harness.probe.update { host in
            host.cpuCount = 8
            host.load1 = 1
            host.load5 = 1
        }
        harness.processes.reuse(holderPID, identity: "fake:start-1")
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let (engine, _, _) = try harness.start(store: store)
        var config = SimPoolConfig()
        config.settle.mode = .load
        config.maxSims = sims
        config.maxConcurrentBoots = sims
        engine.pool = config
        for _ in 0..<(3 * sims) where try store.poolSims().filter({ $0.phase == .ready }).count < sims {
            _ = try engine.poolPass(config: config, demand: sims)
            harness.clock.advance(by: 30)
        }
        XCTAssertEqual(try store.poolSims().map(\.phase), Array(repeating: .ready, count: sims))
        guard mode != .enforce else { return (harness, store, engine) }
        harness.reliability.cleanupMode = mode
        let (restarted, _, _) = try harness.start(store: store)
        restarted.pool = config
        return (harness, store, restarted)
    }

    private func audits(_ store: JobStore, _ type: String) throws -> [String] {
        try store.auditEntries().filter { $0.type == type }.compactMap(\.detail)
    }

    func testCrashedHolderIsReportedOnceInReportOnlyAndKeepsTheSim() throws {
        let (harness, store, engine) = try setUp(mode: .reportOnly)
        let sim = try XCTUnwrap(try engine.acquireManualLease(leaseID: "lease:ci", pid: holderPID))
        XCTAssertEqual(sim.holderIdentity, "fake:start-1")
        _ = try engine.watchdogPass(.light, config: WatchdogConfig())
        XCTAssertEqual(try audits(store, "lease_would_reclaim"), [], "live holder: protected")

        harness.processes.leaderExited(holderPID)  // the holder crashed
        let report = try engine.watchdogPass(.light, config: WatchdogConfig())
        XCTAssertEqual(report.staleLeases.reported, [sim.udid])
        XCTAssertEqual(try audits(store, "lease_would_reclaim").count, 1)
        XCTAssertTrue(try audits(store, "lease_would_reclaim")[0].contains("holder pid 4242 is gone"))
        _ = try engine.watchdogPass(.full, config: WatchdogConfig())
        XCTAssertEqual(try audits(store, "lease_would_reclaim").count, 1, "reported once")
        XCTAssertEqual(try store.poolSims().first?.phase, .leased, "report-only never reclaims")
        XCTAssertEqual(try audits(store, "lease_reclaimed"), [])
    }

    func testCrashedHolderIsReclaimedInEnforce() throws {
        let (harness, store, engine) = try setUp(mode: .enforce)
        let sim = try XCTUnwrap(try engine.acquireManualLease(leaseID: "lease:ci", pid: holderPID))
        harness.processes.leaderExited(holderPID)
        let report = try engine.watchdogPass(.light, config: WatchdogConfig())
        XCTAssertEqual(report.staleLeases.reclaimed, [sim.udid])
        let after = try XCTUnwrap(try store.poolSims().first)
        XCTAssertEqual(after.phase, .recycling)
        XCTAssertTrue(after.tainted, "unknown state from a dead holder is never reused")
        XCTAssertNil(after.leaseID)
        XCTAssertNil(after.holderPID)
        XCTAssertEqual(try audits(store, "lease_reclaimed").count, 1)
        XCTAssertThrowsError(try engine.renewManualLease(udid: sim.udid, leaseID: "lease:ci"))
    }

    func testAReusedPidDoesNotKeepTheLease() throws {
        let (harness, store, engine) = try setUp(mode: .enforce)
        _ = try XCTUnwrap(try engine.acquireManualLease(leaseID: "lease:ci", pid: holderPID))
        harness.processes.reuse(holderPID, identity: "fake:start-2")
        _ = try engine.watchdogPass(.light, config: WatchdogConfig())
        XCTAssertEqual(try store.poolSims().first?.tainted, true)
    }

    func testHeartbeatOnlyLeaseLivesWhileRenewedAndIsReclaimedAfterTheGrace() throws {
        let (harness, store, engine) = try setUp(mode: .enforce)
        let sim = try XCTUnwrap(try engine.acquireManualLease(leaseID: "lease:ci", pid: nil))
        harness.clock.advance(by: 9 * 60)
        _ = try engine.watchdogPass(.light, config: WatchdogConfig())
        XCTAssertEqual(try store.poolSims().first?.phase, .leased, "inside the 10 min orphan grace")
        try engine.renewManualLease(udid: sim.udid, leaseID: "lease:ci")
        harness.clock.advance(by: 9 * 60)
        _ = try engine.watchdogPass(.light, config: WatchdogConfig())
        XCTAssertEqual(try store.poolSims().first?.phase, .leased, "renewed")
        harness.clock.advance(by: 2 * 60)
        _ = try engine.watchdogPass(.light, config: WatchdogConfig())
        XCTAssertEqual(try store.poolSims().first?.tainted, true)
        XCTAssertTrue(try audits(store, "lease_reclaimed").first?.contains("no heartbeat") == true)
    }

    func testAHolderPidThatIsNotRunningIsRefusedAndJobLeasesAreLeftAlone() throws {
        let (harness, store, engine) = try setUp(mode: .enforce)
        XCTAssertThrowsError(try engine.acquireManualLease(leaseID: "lease:x", pid: 9999)) { error in
            XCTAssertEqual(error as? PoolError, .holderNotRunning(9999))
        }
        XCTAssertEqual(try store.poolSims().first?.phase, .ready, "nothing leased")
        _ = try XCTUnwrap(try engine.acquirePoolSim(leaseID: "job:J1"))
        harness.clock.advance(by: 3600)
        XCTAssertEqual(
            try engine.reclaimStaleManualLeases(limits: ReliabilityConfig(cleanupMode: .enforce)).reclaimed, [])
        XCTAssertEqual(try store.poolSims().first?.leaseID, "job:J1", "job leases follow their job, not this rule")
    }

    func testReclaimsCountAgainstThePerPassAndHourlyLimits() throws {
        let (harness, store, engine) = try setUp(mode: .enforce, sims: 3, perPass: 1, perHour: 2)
        for index in 0..<3 {
            let pid = Int32(5000 + index)
            harness.processes.reuse(pid, identity: "fake:holder-\(index)")
            _ = try XCTUnwrap(try engine.acquireManualLease(leaseID: "lease:h\(index)", pid: pid))
            harness.processes.leaderExited(pid)  // every holder crashed
        }
        let watchdog = WatchdogConfig()
        var report = try engine.watchdogPass(.light, config: watchdog).staleLeases
        XCTAssertEqual(report.reclaimed.count, 1, "per-pass limit")
        XCTAssertEqual(report.postponed.count, 2)
        XCTAssertEqual(try audits(store, "lease_reclaim_postponed").count, 2)
        XCTAssertTrue(try audits(store, "lease_reclaim_postponed")[0].contains("per-pass limit"))

        harness.clock.advance(by: 60)
        report = try engine.watchdogPass(.light, config: watchdog).staleLeases
        XCTAssertEqual(report.reclaimed.count, 1)
        XCTAssertEqual(try audits(store, "lease_reclaim_postponed").count, 2, "a postponed reclaim is logged once")

        harness.clock.advance(by: 60)
        report = try engine.watchdogPass(.light, config: watchdog).staleLeases
        XCTAssertEqual(report.reclaimed, [], "hourly limit reached (2)")
        XCTAssertTrue(report.hourlyLimitHit)
        XCTAssertEqual(try store.poolSims().filter { $0.phase == .leased }.count, 1)
        XCTAssertEqual(try store.auditCount(type: Engine.destructiveAuditType, since: 0), 2, "reclaims are counted")

        harness.clock.advance(by: 3600)
        report = try engine.watchdogPass(.light, config: watchdog).staleLeases
        XCTAssertEqual(report.reclaimed.count, 1, "the next window")
        XCTAssertEqual(try store.poolSims().filter { $0.phase == .leased }.count, 0)
    }
}
