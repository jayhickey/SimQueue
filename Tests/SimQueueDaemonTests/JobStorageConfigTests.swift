// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueProtocol
import SimQueueStore
import XCTest

final class JobStorageConfigTests: XCTestCase {
    private func saveRouting(state: String, root: String, roots: [String]) throws {
        try JSONSerialization.data(withJSONObject: ["root": root, "roots": roots, "drained": true]).write(
            to: URL(fileURLWithPath: state + "/job-output.json"))
    }

    func testInitialRootCannotOverlapLegacyOutput() throws {
        let state = testScratchRoot() + "/routing-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: state) }
        let store = try JobStore(path: ":memory:")
        for root in [state, state + "/jobs/nested"] {
            XCTAssertThrowsError(try JobOutputConfiguration.prepare(stateDirectory: state, root: root, store: store))
            XCTAssertFalse(FileManager.default.fileExists(atPath: state + "/job-output.json"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: state + "/jobs"))
        }
    }

    func testOverlappingNewAndPersistedRootsFailWithoutChangingRoutingHistory() throws {
        let state = testScratchRoot() + "/routing-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: state) }
        let store = try JobStore(path: ":memory:")
        let outer = state + "/outputs", inner = outer + "/2020-01-01/new-root"
        let path = URL(fileURLWithPath: state + "/job-output.json")
        for roots in [[outer], [inner], [outer, inner]] {
            try saveRouting(state: state, root: roots.last!, roots: roots)
            let before = try Data(contentsOf: path)
            let requested = roots.count == 1 ? (roots[0] == outer ? inner : outer) : inner
            for persist in [false, true] {
                XCTAssertThrowsError(
                    try JobOutputConfiguration.prepare(
                        stateDirectory: state, root: requested, store: store, persist: persist)
                ) { error in
                    XCTAssertTrue(String(describing: error).contains("overlap"), "\(error)")
                }
                XCTAssertEqual(try Data(contentsOf: path), before)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outer))
    }

    func testRootAliasesCannotHidePersistedOverlap() throws {
        let state = testScratchRoot() + "/routing-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: state) }
        let store = try JobStore(path: ":memory:")
        let outer = state + "/outputs", inner = outer + "/2020-01-01/new-root"
        // Includes a persisted current root missing from its history array.
        for alias in [outer + "/", outer + "/.", outer + "/unused/..", outer + "//"] {
            try saveRouting(state: state, root: alias, roots: [inner])
            let path = URL(fileURLWithPath: state + "/job-output.json")
            let before = try Data(contentsOf: path)
            XCTAssertThrowsError(try JobOutputConfiguration.prepare(stateDirectory: state, root: inner, store: store))
            XCTAssertEqual(try Data(contentsOf: path), before)
        }
    }

    func testPhysicalRootAliasesAreRejectedAndSiblingRootsAreAllowed() throws {
        let state = testScratchRoot() + "/routing-" + UUID().uuidString.prefix(8)
        let outer = state + "/outputs", linked = state + "/alias"
        try FileManager.default.createDirectory(atPath: outer, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: state) }
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: outer)
        let store = try JobStore(path: ":memory:")
        try saveRouting(state: state, root: outer, roots: [outer])
        XCTAssertThrowsError(
            try JobOutputConfiguration.prepare(
                stateDirectory: state, root: linked + "/2020-01-01/new-root", store: store))
        #if os(macOS)
            let values = try URL(fileURLWithPath: state).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            if values.volumeSupportsCaseSensitiveNames == false {
                XCTAssertThrowsError(
                    try JobOutputConfiguration.prepare(
                        stateDirectory: state, root: state + "/OUTPUTS/new-root", store: store))
            }
        #endif
        try saveRouting(state: state, root: outer, roots: [outer])
        let sibling = outer + "-sibling"
        let result = try JobOutputConfiguration.prepare(stateDirectory: state, root: sibling, store: store)
        XCTAssertEqual(result.root, sibling)
        XCTAssertEqual(Set(result.roots), [outer, sibling])
    }

    func testDeepTargetAncestorSymlinkCannotHideNewOrPersistedOverlap() throws {
        let manager = FileManager.default
        for suffix in ["live", "missing", "missing/parents/live"] {
            let state = testScratchRoot() + "/routing-" + UUID().uuidString.prefix(8)
            let outer = state + "/outputs", anchor = outer + "/2020-01-01/new-root/anchor"
            let alias = state + "/alias", inner = alias + "/" + suffix
            try manager.createDirectory(atPath: anchor + "/live", withIntermediateDirectories: true)
            defer { try? manager.removeItem(atPath: state) }
            try manager.createSymbolicLink(atPath: alias, withDestinationPath: anchor)
            let marker = URL(fileURLWithPath: anchor + "/live/keep")
            let bytes = Data("preserve evidence".utf8)
            try bytes.write(to: marker)
            let store = try JobStore(path: ":memory:")
            let routing = URL(fileURLWithPath: state + "/job-output.json")
            // Proposed changes in either direction, persisted overlap, and a current
            // root omitted from history must all fail before rewriting any files.
            for (current, history, requested) in [
                (outer, [outer], inner), (inner, [inner], outer),
                (inner, [outer, inner], inner), (inner, [outer], inner),
            ] {
                try saveRouting(state: state, root: current, roots: history)
                let before = try Data(contentsOf: routing)
                let entries = try manager.subpathsOfDirectory(atPath: state).sorted()
                for persist in [false, true] {
                    XCTAssertThrowsError(
                        try JobOutputConfiguration.prepare(
                            stateDirectory: state, root: requested, store: store, persist: persist)
                    ) { error in
                        XCTAssertTrue(String(describing: error).contains("overlap"), "\(error)")
                    }
                    XCTAssertEqual(try Data(contentsOf: routing), before)
                    XCTAssertEqual(try manager.subpathsOfDirectory(atPath: state).sorted(), entries)
                    XCTAssertEqual(try Data(contentsOf: marker), bytes)
                    XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: alias), anchor)
                }
            }
        }
    }

    #if os(macOS)
        func testTmpAliasOverlapPreservesMissingSuffix() throws {
            let manager = FileManager.default
            let state = "/tmp/simqueue-routing-" + UUID().uuidString
            try manager.createDirectory(atPath: state, withIntermediateDirectories: true)
            defer { try? manager.removeItem(atPath: state) }
            let physical = URL(fileURLWithPath: state).resolvingSymlinksInPath().path
            let outer = physical + "/outputs"
            try manager.createDirectory(atPath: outer + "/live", withIntermediateDirectories: true)
            let store = try JobStore(path: ":memory:")
            try saveRouting(state: state, root: outer, roots: [outer])
            let routing = URL(fileURLWithPath: state + "/job-output.json")
            let before = try Data(contentsOf: routing)
            let entries = try manager.subpathsOfDirectory(atPath: state).sorted()
            for suffix in ["live", "missing", "missing/parents/live"] {
                XCTAssertThrowsError(
                    try JobOutputConfiguration.prepare(
                        stateDirectory: state, root: state + "/outputs/" + suffix, store: store))
                XCTAssertEqual(try Data(contentsOf: routing), before)
                XCTAssertEqual(try manager.subpathsOfDirectory(atPath: state).sorted(), entries)
            }
        }
    #endif

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
