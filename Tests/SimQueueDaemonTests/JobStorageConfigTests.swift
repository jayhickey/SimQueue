// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueProtocol
import SimQueueStore
import XCTest

final class JobStorageConfigTests: XCTestCase {
    func testConfigurationDefaultsAndValidation() throws {
        XCTAssertNil(DaemonConfig().jobOutputRoot)
        XCTAssertTrue(DaemonConfig().hostTemplates.isEmpty)
        let config = try DaemonConfig.parse(
            Data(
                #"{"job_output_root":"/output/jobs","host_templates":{"iphone":"phone","ipad":"tablet"},"default_host_template":"iphone"}"#
                    .utf8))
        XCTAssertEqual(config.jobOutputRoot, "/output/jobs")
        XCTAssertEqual(config.hostTemplates["ipad"], "tablet")
        XCTAssertEqual(config.defaultHostTemplate, "iphone")
        for json in [
            #"{"job_output_root":"relative"}"#, #"{"job_output_root":"/"}"#,
            #"{"default_host_template":"unknown"}"#, #"{"host_templates":{"iphone":""}}"#,
        ] {
            XCTAssertThrowsError(try DaemonConfig.parse(Data(json.utf8)))
        }
    }

    func testMissingExternalVolumeDoesNotCreateMountDirectory() throws {
        let root = "/Volumes/simqueue-missing-" + UUID().uuidString + "/jobs"
        XCTAssertThrowsError(try JobStorage.check(root))
        let files = StorageFileSystem(base: RootedFileSystem(roots: [root]), roots: [root])
        XCTAssertThrowsError(try files.createDirectory(root + "/2026-01-01/J-1"))
        XCTAssertTrue(files.fileExists(root + "/pending-cleanup"), "offline is not proof of deletion")
        XCTAssertThrowsError(try files.removeItem(root + "/pending-cleanup"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root))
    }

    func testWritableDirectoryAndMissingLeafPassWithoutCreatingOutput() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try manager.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(atPath: base) }

        XCTAssertNoThrow(try JobStorage.check(base))
        let root = base + "/missing/jobs"
        XCTAssertNoThrow(try JobStorage.check(root))
        XCTAssertFalse(manager.fileExists(atPath: base + "/missing"), "checking must not create output")
        let files = StorageFileSystem(base: RootedFileSystem(roots: [root]), roots: [root])
        try files.createDirectory(root + "/2026-01-01/J-1")
        XCTAssertTrue(manager.fileExists(atPath: root + "/2026-01-01/J-1"))
    }

    func testRegularFileCannotBeAnOutputRoot() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let contents = Data("keep".utf8)
        try contents.write(to: URL(fileURLWithPath: root))
        defer { try? manager.removeItem(atPath: root) }

        XCTAssertThrowsError(try JobStorage.check(root))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: root)), contents)
    }

    func testLinkedOutputRootCannotWriteOrRemoveThroughItsTarget() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let target = base + "/target"
        let root = base + "/linked-jobs"
        try manager.createDirectory(atPath: target, withIntermediateDirectories: true)
        defer { try? manager.removeItem(atPath: base) }
        let contents = Data("preserve target".utf8)
        try contents.write(to: URL(fileURLWithPath: target + "/keep"))
        try manager.createSymbolicLink(atPath: root, withDestinationPath: target)

        XCTAssertThrowsError(try JobStorage.check(root))
        let files = StorageFileSystem(base: RootedFileSystem(roots: [root]), roots: [root])
        XCTAssertThrowsError(try files.createDirectory(root + "/2026-01-01/J-1"))
        XCTAssertThrowsError(try files.removeItem(root + "/keep"))
        XCTAssertEqual(try files.children(of: root), [], "cleanup must not enter a linked root")
        XCTAssertFalse(manager.fileExists(atPath: target + "/2026-01-01"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target + "/keep")), contents)
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: root), target)
    }

    func testDanglingOutputRootLinkIsRejectedWithoutCreatingItsTarget() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let target = base + "/missing-target"
        let root = base + "/linked-jobs"
        try manager.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(atPath: base) }
        try manager.createSymbolicLink(atPath: root, withDestinationPath: target)

        XCTAssertThrowsError(try JobStorage.check(root))
        let files = StorageFileSystem(base: RootedFileSystem(roots: [root]), roots: [root])
        XCTAssertThrowsError(try files.createDirectory(root + "/2026-01-01/J-1"))
        XCTAssertFalse(manager.fileExists(atPath: target))
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: root), target)
    }

    func testRootChangeRequiresDrainAndPreservesRecordedOutput() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: state) }
        let store = try JobStore(path: ":memory:")
        let original = state + "/jobs"
        _ = try JobOutputConfiguration.prepare(stateDirectory: state, root: original, store: store)
        var command = JobCommand(argv: ["true"])
        command.artifactsRoot = original
        let job = try store.submit(JobSubmission(project: "app", submitter: "test", command: command), now: 0).job
        let changed = state + "/other"
        XCTAssertThrowsError(try JobOutputConfiguration.prepare(stateDirectory: state, root: changed, store: store))
        try JobOutputConfiguration.markDrained(true, stateDirectory: state)
        let configuration = try JobOutputConfiguration.prepare(stateDirectory: state, root: changed, store: store)
        XCTAssertEqual(Set(configuration.roots), [original, changed])
        var artifacts = JobArtifacts(root: changed); artifacts.legacyRoot = original
        XCTAssertTrue(artifacts.directory(for: try XCTUnwrap(store.job(id: job.id))).hasPrefix(original + "/"))
    }
}
