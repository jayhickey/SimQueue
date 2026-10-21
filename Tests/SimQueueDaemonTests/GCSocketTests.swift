// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueEngine
import SimQueueProtocol
import XCTest

/// `gc` and `submit --keep` over the socket (the retention logic itself is in AgeRuleTests).
final class GCSocketTests: XCTestCase {
    func testGCIsADryRunByDefaultAndApplyIsRefusedInReportOnly() throws {
        let daemon = try TestDaemon(config: DaemonConfig())
        defer { daemon.destroy() }
        XCTAssertNotEqual(DaemonConfig().reliability.cleanupMode, .enforce, "default is report-only")
        guard case .gc(let dry) = try daemon.result(.gc(GCParams())) else { return XCTFail("not a gc result") }
        XCTAssertFalse(dry.applied)
        XCTAssertTrue(dry.removed.isEmpty)
        let refused = try daemon.protocolError(.gc(GCParams(apply: true)))
        XCTAssertEqual(refused.code, .invalidState)
        XCTAssertTrue(refused.message.contains("nothing removed"), refused.message)
    }

    func testApplyRunsInEnforceModeAndReportsTheBudget() throws {
        var config = DaemonConfig()
        config.reliability.cleanupMode = .enforce
        config.reliability.ageRules.artifactRetention.budgetBytes = 1024
        let daemon = try TestDaemon(config: config)
        defer { daemon.destroy() }
        guard case .gc(let result) = try daemon.result(.gc(GCParams(apply: true))) else {
            return XCTFail("not a gc result")
        }
        XCTAssertTrue(result.applied)
        XCTAssertEqual(result.budgetBytes, 1024)
    }

    func testSubmitWithKeepPinsTheJob() throws {
        let daemon = try TestDaemon()
        defer { daemon.destroy() }
        let pinned = try daemon.submit(
            SubmitParams(project: "app", submitter: "dev", keep: true))
        let plain = try daemon.submit(
            SubmitParams(project: "app", submitter: "dev"))
        XCTAssertEqual(try daemon.side.auditEntries(jobID: pinned.job.id, type: Engine.artifactKeepAuditType).count, 1)
        XCTAssertTrue(try daemon.side.auditEntries(jobID: plain.job.id, type: Engine.artifactKeepAuditType).isEmpty)
    }

    /// --keep on a deduplicated submit pins the job it returns (once).
    func testKeepOnADeduplicatedSubmitPinsTheExistingJob() throws {
        let daemon = try TestDaemon()
        defer { daemon.destroy() }
        var params = SubmitParams(project: "app", submitter: "dev", dedupeKey: "k")
        let first = try daemon.submit(params)
        params.keep = true
        let again = try daemon.submit(params)
        XCTAssertTrue(again.deduplicated)
        XCTAssertEqual(again.job.id, first.job.id)
        _ = try daemon.submit(params)
        let pins = try daemon.side.auditEntries(jobID: first.job.id, type: Engine.artifactKeepAuditType)
        XCTAssertEqual(pins.count, 1, "pinned once")
    }
}
