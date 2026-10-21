// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import XCTest

/// CR on #67: a relative, symlinked or `~` state dir must not change the daemon's tag (its
/// own sims would look like another daemon's). The tag is persisted on first start.
final class OwnerTagFileTests: XCTestCase {
    private func scratch() throws -> String {
        let dir = testScratchRoot() + "/tag-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
    }

    func testEverySpellingOfTheStateDirGetsOneTag() throws {
        let root = try scratch()
        let state = root + "/state"
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        let link = root + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: state)
        // Before any file exists, every spelling resolves to the same path, hence one tag.
        let spellings = [state, state + "/", link, root + "/./state", root + "/x/../state"]
        let tags = Set(spellings.map { OwnerTagFile.resolve(stateDirectory: $0, persist: false) })
        XCTAssertEqual(tags.count, 1, "\(tags)")
        XCTAssertEqual(OwnerTagFile.resolve(stateDirectory: "state", persist: false, cwd: root), tags.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state + "/owner-tag"), "persist: false never writes")
    }

    func testTheFirstStartPersistsTheTagAndLaterStartsReuseIt() throws {
        let state = try scratch() + "/state"
        let first = OwnerTagFile.resolve(stateDirectory: state, persist: true)
        let saved = try String(contentsOfFile: state + "/owner-tag", encoding: .utf8)
        XCTAssertEqual(saved, first + "\n")
        // A later start reuses the file even if the hash of the spelling would differ.
        try Data("d0badbeef\n".utf8).write(to: URL(fileURLWithPath: state + "/owner-tag"))
        XCTAssertEqual(OwnerTagFile.resolve(stateDirectory: state, persist: true), "d0badbeef")
        // Garbage in the file is replaced by the computed tag.
        try Data("not a tag".utf8).write(to: URL(fileURLWithPath: state + "/owner-tag"))
        XCTAssertEqual(OwnerTagFile.resolve(stateDirectory: state, persist: true), first)
        XCTAssertEqual(try String(contentsOfFile: state + "/owner-tag", encoding: .utf8), first + "\n")
    }

    /// CR on #73: a failed write is logged, and the computed tag is still used.
    func testAFailedWriteIsLoggedAndTheComputedTagStillUsed() throws {
        let root = try scratch()
        let blocker = root + "/file"
        try Data("x".utf8).write(to: URL(fileURLWithPath: blocker))
        let state = blocker + "/state"  // under a regular file: can't be created
        var lines: [String] = []
        let tag = OwnerTagFile.resolve(stateDirectory: state, persist: true, log: { lines.append($0) })
        XCTAssertEqual(tag, OwnerTagFile.resolve(stateDirectory: state, persist: false))
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines[0].contains("couldn't save the owner tag") && lines[0].contains(tag), lines[0])
        var quiet: [String] = []
        _ = OwnerTagFile.resolve(stateDirectory: root + "/ok", persist: true, log: { quiet.append($0) })
        XCTAssertEqual(quiet, [], "a successful write logs nothing")
    }
}
