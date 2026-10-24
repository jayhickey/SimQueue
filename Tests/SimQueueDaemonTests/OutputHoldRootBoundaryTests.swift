// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueEngine
import SimQueueHost
import SimQueueProtocol
import SimQueueSim
import SimQueueStore
import XCTest

final class OutputHoldRootBoundaryTests: XCTestCase {
    func testRootedAncestorCannotDeleteHeldOutputThroughAgeOrBudgetGC() throws {
        for budgetOnly in [false, true] {
            for route in ["manual", "background", "watchdog"] {
                for layout in ["root", "nested", "deep-alias"] {
                    let state = testScratchRoot() + "/boundary-" + UUID().uuidString.prefix(8)
                    let outer = state + "/outputs", candidate = outer + "/2020-01-01/new-root"
                    let deepAlias = layout == "deep-alias"
                    let inner = deepAlias ? state + "/alias/live" : candidate + (layout == "nested" ? "/nested" : "")
                    let files = RootedFileSystem(roots: [outer, inner, state + "/work"])
                    try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(atPath: state) }
                    let clock = ManualClock(start: 1_800_000_000)
                    var config = DaemonConfig()
                    config.reliability.cleanupMode = .enforce
                    config.reliability.ageRules.artifactRetention.budgetBytes = budgetOnly ? 1 : nil
                    if budgetOnly {
                        config.reliability.ageRules.artifactRetention.unknownSeconds = 1_000_000_000
                    }
                    var environment = EngineEnvironment(
                        clock: clock, probe: FakeResourceProbe(fixed: healthyFakeHost), sims: FakeSimBackend(),
                        processes: FakeProcessTable(), fileSystem: files,
                        layout: RunDirectoryLayout(root: state + "/work"),
                        artifactsRoot: inner)
                    environment.historicalArtifactsRoots = [outer]
                    let store = try JobStore(path: ":memory:")
                    let (engine, _, _) = try Engine.start(
                        store: store, environment: environment, config: config.scheduler,
                        reliability: config.reliability,
                        ownerID: "test", pid: 1)
                    if deepAlias {
                        let anchor = candidate + "/anchor"
                        try FileManager.default.createDirectory(atPath: anchor, withIntermediateDirectories: true)
                        try FileManager.default.createSymbolicLink(
                            atPath: state + "/alias", withDestinationPath: anchor)
                    }
                    let id = UUID().uuidString
                    try store.createOutputHold(id: id, label: "evidence", now: clock.now())
                    let job = try store.submitHeld(
                        JobSubmission(project: "test", submitter: "test"), holdID: id, artifactsRoot: inner,
                        now: clock.now()
                    ).job
                    _ = try store.cancel(jobID: job.id, now: clock.now())
                    let path = JobArtifacts(root: inner).directory(for: job)
                    try files.createDirectory(path + "/DerivedData")
                    let marker = path + "/DerivedData/evidence"
                    let bytes = Data("held output".utf8)
                    try bytes.write(to: URL(fileURLWithPath: marker))
                    if !budgetOnly { clock.advance(by: 100 * 86_400) }
                    let inventory = try Engine.gcInventory(roots: [outer, inner], fileSystem: files)
                    XCTAssertTrue(inventory.directories.contains { $0.path == candidate && $0.jobID == "new-root" })
                    let plan = try engine.gcPlan(now: clock.now(), inventory: inventory)
                    // Configuration is deliberately bypassed here. Lexical engine
                    // planning cannot resolve the alias under the service lock; the
                    // physical filesystem boundary must refuse the attempted removal.
                    XCTAssertEqual(engine.gcCandidates(plan).contains { $0.path == candidate }, deepAlias)
                    for spelling in [candidate, candidate + "/", candidate + "/."] {
                        XCTAssertEqual(try engine.stillRemovable(spelling, now: clock.now()), deepAlias)
                    }
                    if route == "manual" {
                        let result = try engine.garbageCollect(apply: true, now: clock.now())
                        XCTAssertTrue(result.removed.isEmpty)
                        XCTAssertEqual(
                            result.failures.contains { $0.contains(candidate) && $0.contains("refusing") }, deepAlias)
                    } else if route == "watchdog" {
                        let report = try engine.watchdogPass(.full, config: WatchdogConfig()).age
                        XCTAssertTrue(report.artifactsRemoved.isEmpty)
                        XCTAssertEqual(
                            report.failures.contains { $0.contains(candidate) && $0.contains("refusing") }, deepAlias)
                    } else {
                        let service = DaemonService(
                            engine: engine, config: config,
                            info: DaemonInfo(
                                version: "test", pid: 1, epoch: engine.epoch, backend: "fake", startedAt: 0,
                                statePath: state + "/state.sqlite", socketPath: state + "/socket",
                                cleanupMode: "enforce"),
                            executor: nil, artifacts: JobArtifacts(root: inner))
                        guard
                            case .result(.gc(let accepted)) = service.handle(
                                Request(params: .gc(GCParams(apply: true, background: true)))
                            ).body
                        else {
                            return XCTFail("background GC not accepted")
                        }
                        XCTAssertEqual(accepted.scheduled, true)
                        service.waitForBackgroundWork()
                        guard case .result(.status(let status)) = service.handle(Request(params: .status)).body else {
                            return XCTFail("background GC status unavailable")
                        }
                        let summary = try XCTUnwrap(status.lastCleanup)
                        XCTAssertEqual(summary.removedCount, 0)
                        XCTAssertEqual(summary.failureCount, deepAlias ? 1 : 0)
                        if deepAlias {
                            XCTAssertTrue(
                                summary.failures.contains { $0.contains(candidate) && $0.contains("refusing") })
                        }
                    }
                    if !deepAlias {
                        XCTAssertNil(
                            try engine.beginArtifactRemoval(
                                path: candidate, reason: "stale ancestor plan", now: clock.now()))
                    } else {
                        let audit = try store.auditEntries()
                        XCTAssertTrue(
                            audit.contains { $0.type == "cleanup_failed" && $0.detail?.contains(candidate) == true })
                        XCTAssertFalse(
                            audit.contains {
                                $0.type == Engine.artifactRemovedAuditType && $0.detail?.contains(candidate) == true
                            })
                    }
                    XCTAssertEqual(
                        try Data(contentsOf: URL(fileURLWithPath: marker)), bytes,
                        "\(route), budget=\(budgetOnly), layout=\(layout)")
                    XCTAssertTrue(try store.hasActiveOutputHold(jobID: job.id))
                }
            }
        }
    }
}
