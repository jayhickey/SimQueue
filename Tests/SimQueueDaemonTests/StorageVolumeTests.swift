// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueProtocol
import XCTest

final class StorageVolumeTests: XCTestCase {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String? = "original"
        func set(_ value: String?) { lock.lock(); self.value = value; lock.unlock() }
        func read(_ root: String) throws -> String {
            lock.lock(); defer { lock.unlock() }
            guard let value else { throw JobStorage.Failure("drive disconnected") }
            return value
        }
    }
    private func scratch() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func testPinsVolumeAcrossRestartRejectsReplacementAndRecoversOriginal() throws {
        let state = try scratch(); defer { try? FileManager.default.removeItem(atPath: state) }
        let root = state + "/jobs", path = state + "/volumes.json", probe = Probe()
        let guarder = try StorageVolumeGuard(path: path, probe: probe.read)
        try guarder.check(root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root), "identity checks must not create output")
        let restarted = try StorageVolumeGuard(path: path, probe: probe.read)
        probe.set(nil)
        XCTAssertThrowsError(try restarted.check(root))
        probe.set("replacement")
        XCTAssertThrowsError(try restarted.check(root)) { error in
            XCTAssertTrue(String(describing: error).contains("wrong volume"))
        }
        probe.set("original")
        XCTAssertNoThrow(try restarted.check(root))
        XCTAssertEqual(
            try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))[root],
            "original")
    }

    func testOfflineCleanupCannotMistakeMissingForDeletedOrTouchReplacement() throws {
        let state = try scratch(); defer { try? FileManager.default.removeItem(atPath: state) }
        let root = state + "/jobs", probe = Probe()
        let guarder = try StorageVolumeGuard(path: state + "/volumes.json", probe: probe.read)
        let fs = StorageFileSystem(base: RootedFileSystem(roots: [root]), roots: [root], validate: guarder.check)
        try fs.createDirectory(root + "/2026-01-01/J-1")
        probe.set("replacement")
        XCTAssertEqual(try fs.children(of: root), [])
        XCTAssertNil(fs.sizeOfItem(root))
        XCTAssertTrue(fs.fileExists(root + "/missing"), "unavailable storage is not deletion proof")
        XCTAssertThrowsError(try fs.removeItem(root + "/2026-01-01/J-1"))
        XCTAssertThrowsError(try fs.createDirectory(root + "/new"))
        probe.set("original")
        XCTAssertTrue(fs.fileExists(root + "/2026-01-01/J-1"))
        try fs.removeItem(root + "/2026-01-01/J-1")
        XCTAssertFalse(fs.fileExists(root + "/2026-01-01/J-1"))
    }

    func testUnboundOfflineRootDoesNotGetAnIdentityUntilAvailable() throws {
        let state = try scratch(); defer { try? FileManager.default.removeItem(atPath: state) }
        let probe = Probe(); probe.set(nil)
        let path = state + "/volumes.json"
        let guarder = try StorageVolumeGuard(path: path, probe: probe.read)
        XCTAssertThrowsError(try guarder.check(state + "/jobs"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        probe.set("original")
        try guarder.check(state + "/jobs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testCannotPersistBindingHoldsWritesAndMalformedBindingsAreNotReset() throws {
        let state = try scratch(); defer { try? FileManager.default.removeItem(atPath: state) }
        let probe = Probe()
        let guarder = try StorageVolumeGuard(path: state + "/absent/volumes.json", probe: probe.read)
        XCTAssertThrowsError(try guarder.check(state + "/jobs"))
        let invalid = state + "/invalid.json"
        try Data("broken".utf8).write(to: URL(fileURLWithPath: invalid))
        XCTAssertThrowsError(try StorageVolumeGuard(path: invalid, probe: probe.read))
    }

    func testRealVolumeIdentityCanBeReadWithoutCreatingRoot() throws {
        let state = try scratch(); defer { try? FileManager.default.removeItem(atPath: state) }
        XCTAssertFalse(try StorageVolumeGuard.volumeIdentity(state + "/jobs").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state + "/jobs"))
    }

    func testQueuedWorkHoldsOnDisconnectAndResumesWithoutResubmission() throws {
        let daemon = try TestDaemon()
        defer { daemon.destroy() }
        daemon.stop()
        let probe = Probe(); probe.set(nil)
        daemon.service.storageChecksEnabled = true
        daemon.service.validateStorage = { root in _ = try probe.read(root) }
        let response = daemon.service.handle(
            Request(params: .submit(SubmitParams(project: "storage", submitter: "test", minSims: 0))))
        guard case .result(.submit(let submitted)) = response.body else { return XCTFail("submit failed") }
        let job = submitted.job
        _ = try daemon.service.tick()
        XCTAssertEqual(try daemon.service.jobInfo(job.id)?.state, .queued)
        probe.set("original")
        _ = try daemon.service.tick()
        XCTAssertNotEqual(try daemon.service.jobInfo(job.id)?.state, .queued)
    }
}
