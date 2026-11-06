// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueEngine
import SimQueueStore
import XCTest

final class PhysicalDeviceTests: XCTestCase {
    let phone = PhysicalDevice(udid: "FAKE-PHONE", name: "Test phone", labels: ["device:test", "physical", "ios27"])

    private func submit(_ store: JobStore, request: String = "physical", now: Double = 0) throws -> Job {
        var command = JobCommand(argv: ["true"])
        command.device = request
        return try store.submit(JobSubmission(project: "test", submitter: "test", command: command), now: now).job
    }

    private func configure(_ engine: Engine) {
        engine.physicalDevices = [phone]
        engine.deviceHealth = { _ in DeviceHealth(state: "ready") }
    }

    func testLabelsExclusiveLeaseAndReleaseOnCompletionAndCancel() throws {
        let h = Harness()
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try h.start(store: store)
        configure(engine)
        let first = try submit(store, request: "device:test")
        let second = try submit(store, request: "ios27")
        XCTAssertEqual(try engine.tick().admitted, [first.id])
        XCTAssertEqual(try store.physicalLeases(), [phone.udid: first.id])
        XCTAssertEqual(try store.job(id: first.id)?.command?.physicalUDID, phone.udid)
        XCTAssertEqual(try store.explanation(jobID: second.id)?.reasons.first?.code, "device_busy")
        _ = try store.finish(jobID: first.id, result: .success, now: h.clock.now())
        XCTAssertEqual(try engine.tick().admitted, [second.id])
        _ = try store.cancel(jobID: second.id, now: h.clock.now())
        _ = try engine.tick()
        XCTAssertTrue(try store.physicalLeases().isEmpty)
    }

    func testUnavailableHealthBacksOffAndDoesNotBlockSimulatorFreeWork() throws {
        for state in ["device_locked", "device_unpaired", "device_unavailable", "developer_mode_disabled"] {
            let h = Harness()
            let store = try JobStore(path: ":memory:")
            let (engine, _, _) = try h.start(store: store)
            configure(engine)
            var probes = 0
            engine.deviceHealth = { _ in
                probes += 1; return DeviceHealth(state: state, detail: "fake devicectl error")
            }
            let physical = try submit(store)
            let host = try store.submit(JobSubmission(project: "host", submitter: "test"), now: 0).job
            XCTAssertEqual(try engine.tick().admitted, [host.id])
            XCTAssertEqual(try store.explanation(jobID: physical.id)?.reasons.first?.code, state)
            _ = try engine.tick()
            XCTAssertEqual(probes, 1)
            h.clock.advance(by: 31)
            _ = try engine.tick()
            XCTAssertEqual(probes, 2)
            XCTAssertTrue(try store.physicalLeases().isEmpty)
        }
    }

    func testRuntimeLockOverridesReadyHealthUntilBackoffThenReprobes() throws {
        let h = Harness()
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try h.start(store: store)
        configure(engine)
        XCTAssertEqual(try engine.physicalDeviceInfos().first?.health.state, "ready")
        engine.recordPhysicalDeviceLocked(udid: phone.udid)
        let job = try submit(store)
        XCTAssertTrue(try engine.tick().admitted.isEmpty)
        XCTAssertEqual(try engine.physicalDeviceInfos().first?.health.state, "device_locked")
        XCTAssertEqual(try store.explanation(jobID: job.id)?.reasons.first?.code, "device_locked")
        h.clock.advance(by: 31)
        XCTAssertEqual(try engine.tick().admitted, [job.id])
        XCTAssertEqual(try engine.physicalDeviceInfos().first?.health.state, "ready")
    }

    func testRestartReleasesOrphanLeaseAndRequeuesUnstartedJob() throws {
        let h = Harness()
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try h.start(store: store)
        configure(engine)
        let job = try submit(store)
        _ = try engine.tick()
        let (restarted, _, _) = try h.start(store: store)
        configure(restarted)
        _ = try restarted.tick()
        XCTAssertEqual(try store.physicalLeases(), [phone.udid: job.id])
        XCTAssertEqual(try store.job(id: job.id)?.ownerEpoch, restarted.epoch)
    }

    func testClaimCannotDoubleLeaseEvenAcrossStoreConnections() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try JobStore(path: path)
        let second = try JobStore(path: path)
        let epoch = try first.acquireDaemonLease(ownerID: "test", pid: 1, now: 0)
        let a = try submit(first)
        let b = try submit(second)
        XCTAssertNotNil(try first.claim(jobID: a.id, grantedSims: 0, epoch: epoch, now: 0, physicalUDID: phone.udid))
        XCTAssertNil(try second.claim(jobID: b.id, grantedSims: 0, epoch: epoch, now: 0, physicalUDID: phone.udid))
        XCTAssertEqual(try second.job(id: b.id)?.state, .queued)
    }

    func testLeaseRemainsDuringCleanupAndTimeoutReleasesIt() throws {
        let h = Harness()
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try h.start(store: store)
        configure(engine)
        let job = try submit(store)
        _ = try engine.tick()
        _ = try store.cancel(jobID: job.id, now: h.clock.now())
        try store.releasePhysicalLeases(holdingJobIDs: [job.id], now: h.clock.now())
        XCTAssertEqual(try store.physicalLeases()[phone.udid], job.id)
        try store.releasePhysicalLeases(holdingJobIDs: [], now: h.clock.now())
        XCTAssertTrue(try store.physicalLeases().isEmpty)
        let timed = try submit(store)
        _ = try engine.tick()
        _ = try store.finish(jobID: timed.id, result: .runTimeout, now: h.clock.now())
        _ = try engine.tick()
        XCTAssertTrue(try store.physicalLeases().isEmpty)
    }

    func testHostMemoryGatesStillHoldPhysicalJobs() throws {
        let h = Harness()
        h.probe.set(healthyHost(availableGiB: 0))
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try h.start(store: store)
        configure(engine)
        _ = try submit(store)
        XCTAssertTrue(try engine.tick().admitted.isEmpty)
        XCTAssertTrue(try store.physicalLeases().isEmpty)
    }
    func testRunningCrashRecoveryReclaimsOnlyAfterOldGroupStops() throws {
        let h = Harness()
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try h.start(store: store)
        configure(engine)
        let job = try submit(store)
        _ = try engine.tick()
        let pgid: Int32 = 4242
        h.processes.spawn(pgid)
        _ = try store.markRunning(jobID: job.id, pid: pgid, epoch: engine.epoch, now: h.clock.now())
        _ = try store.acquireResource(
            kind: .processGroup, externalID: String(pgid), owner: .job(job.id),
            epoch: engine.epoch, identity: h.processes.processIdentity(pgid), now: h.clock.now())
        let next = try submit(store)
        let (restarted, _, _) = try h.start(store: store)
        configure(restarted)
        XCTAssertEqual(try store.job(id: job.id)?.state, .interrupted)
        XCTAssertEqual(try restarted.tick().admitted, [next.id])
        XCTAssertEqual(try store.physicalLeases()[phone.udid], next.id)
        XCTAssertTrue(h.sims.deletedUDIDs.isEmpty)
    }

    func testLiveUnverifiableGroupKeepsPhoneAcrossCancel() throws {
        let h = Harness()
        let store = try JobStore(path: ":memory:")
        let (engine, _, _) = try h.start(store: store)
        configure(engine)
        let job = try submit(store)
        _ = try engine.tick()
        let pgid: Int32 = 4242
        h.processes.spawn(pgid)
        _ = try store.acquireResource(
            kind: .processGroup, externalID: String(pgid), owner: .job(job.id),
            epoch: engine.epoch, identity: nil, now: h.clock.now())
        _ = try store.cancel(jobID: job.id, now: h.clock.now())
        let next = try submit(store)
        XCTAssertTrue(try engine.tick().admitted.isEmpty)
        XCTAssertEqual(try store.physicalLeases()[phone.udid], job.id)
        h.processes.exit(pgid)
        XCTAssertEqual(try engine.tick().admitted, [next.id])
    }

}
