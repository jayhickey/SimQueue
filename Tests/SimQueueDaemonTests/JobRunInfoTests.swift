// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueProtocol
import SimQueueStore
import XCTest

/// A job's results say which pool sims (and templates) it ran on and roughly how
/// much memory its process tree peaked at (`sims[].cloned_from`, `peak_memory_mib`).
final class JobRunInfoTests: XCTestCase {
    func testTheStoreKeepsSimsAndOnlyRaisesThePeak() throws {
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let job = try store.submit(JobSubmission(project: "app", submitter: "dev"), now: 0).job
        XCTAssertNil(try store.jobRunInfo(jobID: job.id))
        let sim = JobSim(
            udid: "U1", name: "simq-pool-1-3", clonedFrom: TemplateRef(udid: "G1", name: "simq-template-app-default-2"))
        try store.recordJobSims(jobID: job.id, sims: [sim])
        try store.recordPeakResidentBytes(jobID: job.id, bytes: 300 << 20)
        try store.recordPeakResidentBytes(jobID: job.id, bytes: 100 << 20)
        let info = try XCTUnwrap(try store.jobRunInfo(jobID: job.id))
        XCTAssertEqual(info.sims, [sim])
        XCTAssertEqual(info.peakResidentBytes, 300 << 20, "a lower sample never lowers the peak")

        var jobInfo = JobInfo(job: try XCTUnwrap(try store.job(id: job.id)), explanation: nil)
        jobInfo.attachRunInfo(info)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(jobInfo)) as? [String: Any])
        XCTAssertEqual(json["peak_memory_mib"] as? Double, 300)
        let sims = try XCTUnwrap(json["sims"] as? [[String: Any]])
        XCTAssertEqual(sims.first?["udid"] as? String, "U1")
        let cloned = try XCTUnwrap(sims.first?["cloned_from"] as? [String: Any])
        XCTAssertEqual(cloned["udid"] as? String, "G1")
        XCTAssertEqual(cloned["name"] as? String, "simq-template-app-default-2")
    }

    func testARealJobReportsItsSimsAndASampledPeakEverywhere() throws {
        let daemon = try TestDaemon(realProcesses: true)
        addTeardownBlock { daemon.destroy() }
        try daemon.side.setPaused(true)
        let id = try daemon.submit(
            SubmitParams(project: "app", submitter: "dev", command: ["/bin/sh", "-c", "sleep 0.4"])
        ).job.id
        // A pool sim leased to the job before it starts (report-only keeps the lease).
        var sim = PoolSim(udid: "U1", name: "simq-pool-1-7", phase: .leased, createdAt: 0, leaseID: "job:\(id)")
        sim.clonedFrom = TemplateRef(udid: "G1", name: "simq-template-app-default-2")
        try daemon.side.savePoolSim(sim)
        try daemon.side.setPaused(false)

        let done = try daemon.wait(id)
        XCTAssertEqual(done.state, .succeeded)
        let expected = [JobSim(udid: "U1", name: "simq-pool-1-7", clonedFrom: sim.clonedFrom)]
        XCTAssertEqual(done.sims, expected)
        let peak = try XCTUnwrap(done.peakMemoryMiB, "sampled while the job ran")
        XCTAssertGreaterThan(peak, 0)
        XCTAssertLessThan(peak, 4096)

        XCTAssertEqual(try daemon.job(id).sims, expected, "explain too")
        XCTAssertEqual(try daemon.job(id).peakMemoryMiB, peak)
        let summary = try XCTUnwrap(done.runDir) + "/job.json"
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: summary))) as? [String: Any])
        XCTAssertEqual(json["peak_memory_mib"] as? Double, peak, "and job.json (what --result-file mirrors)")
        XCTAssertEqual((json["sims"] as? [[String: Any]])?.first?["udid"] as? String, "U1")
    }

    /// CR on #66: a retried attempt starts its own record (sims and peak), so the peak is
    /// per attempt, not the max over every attempt.
    func testANewAttemptResetsThePeakAndReplacesTheSims() throws {
        let store = try JobStore(path: ":memory:", maxQueuedPerSubmitterPerProject: 0)
        let job = try store.submit(JobSubmission(project: "app", submitter: "dev"), now: 0).job
        try store.beginJobRun(jobID: job.id, sims: [JobSim(udid: "U1", name: "simq-pool-1-1", clonedFrom: nil)])
        try store.recordPeakResidentBytes(jobID: job.id, bytes: 900 << 20)
        try store.beginJobRun(jobID: job.id, sims: [JobSim(udid: "U2", name: "simq-pool-2-2", clonedFrom: nil)])
        var info = try XCTUnwrap(try store.jobRunInfo(jobID: job.id))
        XCTAssertNil(info.peakResidentBytes, "the earlier attempt's peak is gone")
        XCTAssertEqual(info.sims.map(\.udid), ["U2"])
        try store.recordPeakResidentBytes(jobID: job.id, bytes: 200 << 20)
        info = try XCTUnwrap(try store.jobRunInfo(jobID: job.id))
        XCTAssertEqual(info.peakResidentBytes, 200 << 20)
        try store.beginJobRun(jobID: job.id, sims: [])
        XCTAssertEqual(try store.jobRunInfo(jobID: job.id)?.sims, [], "an attempt without pool sims clears them")
    }

    /// CR on #66: one process-table walk per executor step covers every running job's group.
    func testOneWalkPerStepCoversEveryRunningJob() throws {
        let table = CountingResidentTable()
        let daemon = try TestDaemon(realProcesses: true, processTable: table)
        addTeardownBlock { daemon.destroy() }
        let ids = try (0..<2).map { _ in
            try daemon.submit(SubmitParams(project: "app", submitter: "dev", command: ["/bin/sh", "-c", "sleep 0.5"]))
                .job.id
        }
        for id in ids { XCTAssertEqual(try daemon.wait(id).state, .succeeded) }
        XCTAssertTrue(table.groupSetSizes.contains(2), "both jobs' groups in one walk: \(table.groupSetSizes)")
        XCTAssertFalse(table.groupSetSizes.contains(0), "no walk without a running job")
        for id in ids { XCTAssertNotNil(try daemon.job(id).peakMemoryMiB) }
    }
}

/// The real process table, recording the group set of every resident-memory walk.
final class CountingResidentTable: ProcessTable, @unchecked Sendable {
    let base = SystemProcessTable()
    private let lock = NSLock()
    private var sizes: [Int] = []
    var groupSetSizes: [Int] { lock.withLock { sizes } }

    func liveProcessGroups() throws -> Set<Int32> { try base.liveProcessGroups() }
    func terminateGroup(_ pgid: Int32, graceSeconds: Double) throws {
        try base.terminateGroup(pgid, graceSeconds: graceSeconds)
    }
    func signalGroup(_ pgid: Int32, _ signal: ProcessSignal) throws { try base.signalGroup(pgid, signal) }
    func processIdentity(_ pid: Int32) throws -> String? { try base.processIdentity(pid) }
    func residentBytes(ofGroups groups: Set<Int32>) throws -> [Int32: UInt64] {
        lock.withLock { sizes.append(groups.count) }
        return try base.residentBytes(ofGroups: groups)
    }
}
