// SPDX-License-Identifier: MIT

import Foundation
import SimQueueDaemon
import SimQueueHost
import XCTest

/// simqd's real file system: only SimQueue's own roots, never through or into a symlink.
final class RootedFileSystemTests: XCTestCase {
    private var base = ""
    private var root = ""
    private var outside = ""
    private var fs: RootedFileSystem!
    private let files = FileManager.default

    override func setUpWithError() throws {
        base = testScratchRoot() + "/sqfs-" + UUID().uuidString.prefix(8)
        root = base + "/state/work"
        outside = base + "/outside"
        try files.createDirectory(atPath: root + "/runs/J-1", withIntermediateDirectories: true)
        try files.createDirectory(atPath: outside + "/keep", withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: URL(fileURLWithPath: outside + "/keep/file"))
        fs = RootedFileSystem(roots: [root])
    }

    override func tearDown() {
        try? files.removeItem(atPath: base)
    }

    func testRefusesPathsOutsideTheRootsOrWithDotComponents() {
        for path in [outside + "/keep", base + "/state", root + "/../outside/keep", root + "/runs/./J-1", "runs/J-1"] {
            XCTAssertThrowsError(try fs.removeItem(path), path)
            XCTAssertFalse(fs.fileExists(path), path)
            XCTAssertThrowsError(try fs.createDirectory(path), path)
            XCTAssertNil(fs.sizeOfItem(path), path)
        }
        XCTAssertThrowsError(try fs.removeItem(root), "the root itself is never removed")
        XCTAssertTrue(files.fileExists(atPath: outside + "/keep/file"))
    }

    func testListsCreatesAndRemovesInsideTheRoot() throws {
        try fs.createDirectory(root + "/runs/J-2/a/b")
        XCTAssertEqual(try fs.children(of: root + "/runs"), [root + "/runs/J-1", root + "/runs/J-2"])
        try Data("12345".utf8).write(to: URL(fileURLWithPath: root + "/runs/J-2/a/b/f"))
        XCTAssertEqual(fs.sizeOfItem(root + "/runs/J-2"), 5)
        try fs.removeItem(root + "/runs/J-2")
        XCTAssertFalse(fs.fileExists(root + "/runs/J-2"))
        XCTAssertEqual(try fs.children(of: root + "/runs"), [root + "/runs/J-1"])
        XCTAssertNoThrow(try fs.removeItem(root + "/runs/missing"), "missing is fine")
    }

    func testRemovingATreeWithSymlinksRemovesTheLinksNotTheirTargets() throws {
        try files.createSymbolicLink(atPath: root + "/runs/J-1/link-dir", withDestinationPath: outside + "/keep")
        try files.createSymbolicLink(
            atPath: root + "/runs/J-1/link-file", withDestinationPath: outside + "/keep/file")
        XCTAssertEqual(fs.sizeOfItem(root + "/runs/J-1"), 0, "links are never followed for size")
        try fs.removeItem(root + "/runs/J-1")
        XCTAssertFalse(fs.fileExists(root + "/runs/J-1"))
        XCTAssertEqual(try String(contentsOfFile: outside + "/keep/file", encoding: .utf8), "precious")
    }

    func testNeverGoesThroughASymlinkedDirectory() throws {
        try files.createSymbolicLink(atPath: root + "/runs/J-3", withDestinationPath: outside)
        XCTAssertEqual(try fs.children(of: root + "/runs/J-3"), [], "a symlinked dir is not entered")
        XCTAssertThrowsError(try fs.removeItem(root + "/runs/J-3/keep"), "path through a link")
        XCTAssertThrowsError(try fs.createDirectory(root + "/runs/J-3/new"), "create through a link")
        XCTAssertFalse(files.fileExists(atPath: outside + "/new"))
        XCTAssertTrue(fs.fileExists(root + "/runs/J-3"), "the link itself exists")
        try fs.removeItem(root + "/runs/J-3")
        XCTAssertFalse(fs.fileExists(root + "/runs/J-3"))
        XCTAssertTrue(files.fileExists(atPath: outside + "/keep/file"), "only the link went")
    }

    func testARootThatIsASymlinkIsRefused() throws {
        let linked = base + "/linked-root"
        try files.createSymbolicLink(atPath: linked, withDestinationPath: outside)
        let unsafe = RootedFileSystem(roots: [linked])
        XCTAssertThrowsError(try unsafe.children(of: linked))
        XCTAssertThrowsError(try unsafe.removeItem(linked + "/keep"))
        XCTAssertTrue(files.fileExists(atPath: outside + "/keep/file"))
    }

    func testEmptyOnlyRemovalNeverRecursesOrFollowsLinks() throws {
        let empty = root + "/runs/empty"
        try fs.createDirectory(empty)
        XCTAssertTrue(try fs.removeEmptyDirectory(empty))
        XCTAssertFalse(try fs.removeEmptyDirectory(empty))
        try fs.createDirectory(empty + "/new-job")
        XCTAssertFalse(try fs.removeEmptyDirectory(empty))
        XCTAssertTrue(fs.fileExists(empty + "/new-job"))
        let link = root + "/runs/linked"
        try files.createSymbolicLink(atPath: link, withDestinationPath: outside + "/keep")
        XCTAssertFalse(try fs.removeEmptyDirectory(link))
        XCTAssertTrue(files.fileExists(atPath: outside + "/keep/file"))
        XCTAssertThrowsError(try fs.removeEmptyDirectory(root), "the managed root is never removed")
    }

    func testDryRunFileSystemReadsButNeverWrites() throws {
        let lines = FSLogLines()
        let dry = DryRunFileSystem(fs, log: { lines.append($0) })
        XCTAssertEqual(try dry.children(of: root + "/runs"), [root + "/runs/J-1"])
        XCTAssertThrowsError(try dry.removeItem(root + "/runs/J-1"))
        XCTAssertThrowsError(try dry.createDirectory(root + "/runs/J-9"))
        XCTAssertTrue(files.fileExists(atPath: root + "/runs/J-1"))
        XCTAssertFalse(files.fileExists(atPath: root + "/runs/J-9"))
        XCTAssertEqual(
            lines.all, ["dry-run: would remove \(root)/runs/J-1", "dry-run: would create \(root)/runs/J-9"])
    }
}

private final class FSLogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
