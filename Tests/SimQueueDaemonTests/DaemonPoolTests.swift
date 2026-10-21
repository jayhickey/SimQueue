// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueEngine
import SimQueueProtocol
import XCTest

/// The daemon runs the pool pass each tick, and `lease_acquire` hands out a sim only
/// once it has settled. Fakes only.
final class DaemonPoolTests: XCTestCase {
    func testPoolConfigParsesAndValidates() throws {
        let config = try DaemonConfig.parse(
            Data(
                #"""
                {"pool": {"max_sims": 3, "warm_min": 1, "max_concurrent_boots": 2,
                 "settle": {"load_below": 5, "max_wait_seconds": 60, "on_cap": "fail"}}}
                """#.utf8))
        let pool = try XCTUnwrap(config.pool)
        XCTAssertEqual(pool.maxSims, 3)
        XCTAssertEqual(pool.warmMin, 1)
        XCTAssertEqual(pool.maxConcurrentBoots, 2)
        XCTAssertEqual(pool.settle.maxWaitSeconds, 60)
        XCTAssertEqual(pool.settle.onCap, .fail)
        XCTAssertNil(try DaemonConfig.parse(Data("{}".utf8)).pool, "no pool section: pool off")
        XCTAssertEqual(try DaemonConfig.parse(Data("{}".utf8)).reliability.orphanGraceSeconds, 600)
        XCTAssertEqual(
            try DaemonConfig.parse(Data(#"{"orphan_grace_seconds": 120}"#.utf8)).reliability.orphanGraceSeconds, 120)
        XCTAssertThrowsError(try DaemonConfig.parse(Data(#"{"orphan_grace_seconds": 0}"#.utf8)))
        XCTAssertNil(try DaemonConfig.parse(Data(#"{"pool": {"enabled": false}}"#.utf8)).pool)
        for bad in [
            #"{"pool": {"prewarm_on_release": false}}"#,
            #"{"pool": {"max_sims": 0}}"#, #"{"pool": {"max_sims": 2, "warm_min": 3}}"#,
            #"{"pool": {"max_concurrent_boots": 0}}"#, #"{"pool": {"settle": {"max_wait_seconds": 0}}}"#,
        ] {
            XCTAssertThrowsError(try DaemonConfig.parse(Data(bad.utf8)), bad)
        }
    }

    func testUnsupportedSettlingConfigurationIsRejected() {
        for settings in [#"{"mode":"quiet"}"#, #"{"mode":"both"}"#, #"{"quiet_window_seconds":5}"#] {
            XCTAssertThrowsError(try DaemonConfig.parse(Data("{\"pool\":{\"settle\":\(settings)}}".utf8)), settings)
        }
    }

    private func poolDaemon(warmMin: Int = 0, realProcesses: Bool = false) throws -> TestDaemon {
        var config = DaemonConfig()
        var pool = SimPoolConfig()
        pool.maxSims = 2
        pool.warmMin = warmMin
        pool.settle.mode = .load
        pool.settle.loadBelow = 1000
        config.pool = pool
        config.reliability.cleanupMode = .enforce  // the pool takes no host action in report-only
        return try TestDaemon(config: config, realProcesses: realProcesses)
    }

    private func acquire(_ daemon: TestDaemon, _ holder: String) -> LeaseResult? {
        let response = daemon.service.handle(Request(params: .leaseAcquire(LeaseAcquireParams(holder: holder))))
        guard case .result(.lease(let result)) = response.body else { return nil }
        return result
    }

    func testLeaseAcquireWaitsForSettleThenGrantsAndReleases() throws {
        let daemon = try poolDaemon()
        defer { daemon.stop() }
        let first = try XCTUnwrap(acquire(daemon, "ci-1"))
        XCTAssertEqual(first.state, "pending", "no sim exists yet: the request becomes demand")
        var granted: LeaseResult?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let result = try XCTUnwrap(acquire(daemon, "ci-1"))
            if result.state == "granted" {
                granted = result
                break
            }
            XCTAssertNil(result.udid)
            Thread.sleep(forTimeInterval: 0.02)
        }
        let lease = try XCTUnwrap(granted, "the pool pass created, booted and settled a sim for the waiting holder")
        let udid = try XCTUnwrap(lease.udid)
        XCTAssertTrue(lease.name?.hasPrefix("simq-") == true, lease.name ?? "")
        let sim = try XCTUnwrap(try daemon.side.poolSims().first { $0.udid == udid })
        XCTAssertEqual(sim.phase, .leased)
        XCTAssertEqual(sim.leaseID, "lease:ci-1")
        XCTAssertEqual(acquire(daemon, "ci-1")?.udid, udid, "repeating returns the held sim")
        let renew = daemon.service.handle(Request(params: .leaseRenew(LeaseReleaseParams(holder: "ci-1", udid: udid))))
        guard case .result(.lease(let renewed)) = renew.body else { return XCTFail("\(renew.body)") }
        XCTAssertEqual(renewed.udid, udid)
        let badRenew = daemon.service.handle(
            Request(params: .leaseRenew(LeaseReleaseParams(holder: "someone-else", udid: udid))))
        guard case .error(let renewFailure) = badRenew.body else { return XCTFail("renew by another holder") }
        XCTAssertEqual(renewFailure.code, .invalidState)
        let deadHolder = daemon.service.handle(
            Request(params: .leaseAcquire(LeaseAcquireParams(holder: "ci-2", pid: 999_999))))
        guard case .error(let pidFailure) = deadHolder.body else { return XCTFail("a holder pid that isn't running") }
        XCTAssertEqual(pidFailure.code, .invalidArgument)

        let wrong = daemon.service.handle(
            Request(params: .leaseRelease(LeaseReleaseParams(holder: "someone-else", udid: udid))))
        guard case .error(let failure) = wrong.body else { return XCTFail("release by another holder must fail") }
        XCTAssertEqual(failure.code, .invalidState)
        let released = daemon.service.handle(
            Request(params: .leaseRelease(LeaseReleaseParams(holder: "ci-1", udid: udid))))
        guard case .result(.lease(let done)) = released.body else { return XCTFail("\(released.body)") }
        XCTAssertEqual(done.state, "released")
        XCTAssertNotEqual(try daemon.side.poolSims().first { $0.udid == udid }?.phase, .leased)
    }

    func testDaemonTickRunsThePoolPassToWarmMin() throws {
        let daemon = try poolDaemon(warmMin: 1)
        defer { daemon.stop() }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, try daemon.side.poolSims().first?.phase != .ready {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(try daemon.side.poolSims().map(\.phase), [.ready], "warm_min is kept with no demand")
    }

    /// With the pool on and the default report-only mode, doctor says the pool is idle and why.
    func testDoctorSaysAReportOnlyPoolCreatesNothing() throws {
        var config = DaemonConfig()
        config.pool = SimPoolConfig()
        XCTAssertEqual(config.reliability.cleanupMode, .reportOnly, "the default")
        let daemon = try TestDaemon(config: config)
        defer { daemon.stop() }
        guard case .result(.doctor(let report)) = daemon.service.handle(Request(params: .doctor)).body else {
            return XCTFail("no doctor result")
        }
        let check = try XCTUnwrap(report.checks.first { $0.name == "pool" })
        XCTAssertEqual(check.level, .warn)
        XCTAssertTrue(
            check.detail.contains("pool.mode is follow-cleanup and cleanup_mode is report-only"), check.detail)
        XCTAssertTrue(check.detail.contains("set pool.mode to active"), check.detail)
        XCTAssertTrue(try daemon.side.poolSims().isEmpty)
    }

    /// `pool.mode: active` runs the pool on its own sims while cleanup stays report-only.
    func testActivePoolWarmsSimsWhileCleanupIsReportOnly() throws {
        var config = DaemonConfig()
        var pool = SimPoolConfig()
        pool.maxSims = 2
        pool.warmMin = 1
        pool.mode = .active
        pool.settle.mode = .load
        pool.settle.loadBelow = 1000
        config.pool = pool
        XCTAssertEqual(config.reliability.cleanupMode, .reportOnly)
        let daemon = try TestDaemon(config: config)
        defer { daemon.stop() }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, try daemon.side.poolSims().first?.phase != .ready {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(try daemon.side.poolSims().map(\.phase), [.ready])
        guard case .result(.doctor(let report)) = daemon.service.handle(Request(params: .doctor)).body else {
            return XCTFail("no doctor result")
        }
        let check = try XCTUnwrap(report.checks.first { $0.name == "pool" })
        XCTAssertFalse(check.detail.contains("creates and boots no sims"), check.detail)
        XCTAssertTrue(check.detail.contains("mode active"), check.detail)
    }

    func testPoolModeParsesAndRejectsUnknownValues() throws {
        XCTAssertEqual(try DaemonConfig.parse(Data(#"{"pool": {}}"#.utf8)).pool?.mode, .followCleanup)
        for mode in PoolMode.allCases {
            XCTAssertEqual(
                try DaemonConfig.parse(Data(#"{"pool": {"mode": "\#(mode.rawValue)"}}"#.utf8)).pool?.mode, mode)
        }
        XCTAssertThrowsError(try DaemonConfig.parse(Data(#"{"pool": {"mode": "enforce"}}"#.utf8))) { error in
            XCTAssertTrue("\(error)".contains("pool.mode must be one of"), "\(error)")
        }
    }

    func testResetAppsIsValidatedRunAndReportedInTheJobResult() throws {
        let off = try TestDaemon(config: DaemonConfig())
        defer { off.stop() }
        func submit(_ daemon: TestDaemon, _ params: SubmitParams) -> Response {
            daemon.service.handle(Request(params: .submit(params)))
        }
        let noPool = submit(
            off,
            SubmitParams(project: "app", submitter: "t", minSims: 1, command: ["true"], resetApps: ["com.example.app"]))
        guard case .error(let poolOff) = noPool.body else { return XCTFail("pool off must reject") }
        XCTAssertEqual(poolOff.code, .invalidArgument)
        XCTAssertTrue(poolOff.message.contains("pool"), poolOff.message)

        let daemon = try poolDaemon()
        defer { daemon.stop() }
        let noSim = submit(daemon, SubmitParams(project: "app", submitter: "t", command: ["true"], freshSim: true))
        guard case .error(let noSimError) = noSim.body else { return XCTFail("needs a sim") }
        XCTAssertEqual(noSimError.code, .invalidArgument)
        let badID = submit(
            daemon, SubmitParams(project: "app", submitter: "t", minSims: 1, command: ["true"], resetApps: ["a b"]))
        guard case .error(let badIDError) = badID.body else { return XCTFail("bad bundle id") }
        XCTAssertEqual(badIDError.code, .invalidArgument)

        let ok = submit(
            daemon,
            SubmitParams(project: "app", submitter: "t", minSims: 1, command: ["true"], resetApps: ["com.example.app"]))
        guard case .result(.submit(let submitted)) = ok.body else { return XCTFail("\(ok.body)") }
        XCTAssertEqual(submitted.job.resetApps, ["com.example.app"])
        var prep: [SimPrepOutcome]?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let explained = daemon.service.handle(Request(params: .explain(JobRef(jobID: submitted.job.id))))
            if case .result(.job(let job)) = explained.body, let outcomes = job.simPrep {
                prep = outcomes
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let outcome = try XCTUnwrap(prep?.first, "prep ran once the job leased a sim")
        XCTAssertEqual(outcome.appsReset, ["com.example.app"])
        XCTAssertTrue(outcome.keychainReset)
        XCTAssertFalse(outcome.erased)
    }

    func testDoctorShowsPoolSimsSettlingAndSettleCapHits() throws {
        let daemon = try poolDaemon(warmMin: 1)
        defer { daemon.stop() }
        func doctor() throws -> DoctorReport {
            guard case .result(.doctor(let report)) = daemon.service.handle(Request(params: .doctor)).body else {
                throw XCTSkip("no doctor result")
            }
            return report
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, try daemon.side.poolSims().first?.phase != .ready {
            Thread.sleep(forTimeInterval: 0.02)
        }
        var report = try doctor()
        let pool = try XCTUnwrap(report.pool)
        XCTAssertEqual(pool.sims.map(\.phase), ["ready"])
        XCTAssertTrue(pool.sims[0].name.hasPrefix("simq-"))
        XCTAssertEqual(pool.settling, [])
        XCTAssertEqual(pool.unleasedUsers, [])
        XCTAssertEqual(pool.settleCapHitsLastHour, 0)
        XCTAssertEqual(report.checks.first { $0.name == "pool" }?.level, .ok)

        try daemon.engine.store.audit(
            "settle_cap_hit", detail: "udid=X waited=120 on_cap=handoff", now: Date().timeIntervalSince1970)
        report = try doctor()
        XCTAssertEqual(report.pool?.settleCapHitsLastHour, 1)
        XCTAssertTrue(report.pool?.recentSettleCapHits.first?.contains("on_cap=handoff") == true)
        XCTAssertEqual(report.checks.first { $0.name == "pool" }?.level, .warn)
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: try JSONEncoder().encode(report))
        XCTAssertEqual(decoded.pool, report.pool)
    }

    func testLeaseAcquireWithThePoolOffIsRefused() throws {
        let daemon = try TestDaemon()
        defer { daemon.stop() }
        let response = daemon.service.handle(Request(params: .leaseAcquire(LeaseAcquireParams(holder: "x"))))
        guard case .error(let failure) = response.body else { return XCTFail("pool off must refuse") }
        XCTAssertEqual(failure.code, .invalidState)
    }

    func testLeaseMessagesRoundTrip() throws {
        let request = Request(id: "r1", params: .leaseAcquire(LeaseAcquireParams(holder: "h")))
        let decoded = try JSONDecoder().decode(Request.self, from: try JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)
        let response = Response(
            id: "r1", body: .result(.lease(LeaseResult(state: "pending", holder: "h", poolState: "settling"))))
        let data = try JSONEncoder().encode(response)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""pool_state":"settling""#))
        XCTAssertEqual(try JSONDecoder().decode(Response.self, from: data), response)
    }

    func testAJobCommandGetsItsLeasedPoolSimAsSIMQ_UDID() throws {
        let daemon = try poolDaemon(warmMin: 1, realProcesses: true)
        defer { daemon.destroy() }
        var params = SubmitParams(project: "demo", submitter: "t", minSims: 1)
        params.command = ["/bin/sh", "-c", #"echo "udid=$SIMQ_UDID all=$SIMQ_SIM_UDIDS""#]
        let id = try daemon.submit(params).job.id
        let job = try daemon.wait(id)
        XCTAssertEqual(job.state, .succeeded, "\(job)")
        guard case .logs(let chunk) = try daemon.result(.logs(LogsParams(jobID: id, offset: 0))) else {
            return XCTFail("no logs")
        }
        let log = chunk.data
        let line = try XCTUnwrap(log.split(separator: "\n").first { $0.hasPrefix("udid=") }, log)
        let parts = line.split(separator: " ")
        let udid = parts[0].dropFirst("udid=".count)
        XCTAssertFalse(udid.isEmpty, log)
        XCTAssertEqual(parts[1], "all=\(udid)", "one sim: SIMQ_UDID is the only leased UDID")
    }
}
