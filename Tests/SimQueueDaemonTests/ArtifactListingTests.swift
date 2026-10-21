// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueProtocol
import XCTest

/// The run directory listing behind `artifacts`, `artifacts_truncated` and `result_bundles`.
final class ArtifactListingTests: XCTestCase {
    private var runDir = ""

    override func setUpWithError() throws {
        runDir = testScratchRoot() + "/sql-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: runDir)
    }

    private func write(_ relative: String, _ text: String = "x") throws {
        let path = runDir + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    /// The job's TMPDIR (`<run dir>/tmp`) is scratch, not results: never listed, and its
    /// files neither use up the 200-entry cap nor the walk bound.
    func testTheJobsTmpdirIsNeverListedAndDoesntCrowdOutArtifacts() throws {
        for index in 0..<(ArtifactInfo.listCap + 50) { try write("tmp/scratch-\(index).png") }
        try write("tmp/nested/deep.mp4")
        try write("proof.mp4", "mp4data")
        try write("shots/home.png", "png")
        let listing = ArtifactListing.list(runDir: runDir, maxVisited: 50)
        XCTAssertEqual(listing.entries.map(\.path), ["proof.mp4", "shots/home.png"])
        XCTAssertFalse(listing.truncated, "tmp is skipped before it's walked")
        XCTAssertTrue(ArtifactListing.skippedTopLevel.contains("tmp"))
        // Only the top-level tmp is skipped: a results folder called tmp deeper down is listed.
        try write("shots/tmp/kept.png")
        XCTAssertTrue(ArtifactListing.list(runDir: runDir).entries.map(\.path).contains("shots/tmp/kept.png"))
    }

    func testTheWalkBoundMarksTheListingTruncatedEvenInsideABundle() throws {
        for index in 0..<30 { try write("Proof.xcresult/Data/blob-\(index)", "ab") }
        let bounded = ArtifactListing.list(runDir: runDir, maxVisited: 10)
        XCTAssertEqual(bounded.entries.map(\.path), ["Proof.xcresult"])
        XCTAssertTrue(bounded.truncated, "the bundle's size was cut short by the walk bound")
        let full = ArtifactListing.list(runDir: runDir)
        XCTAssertFalse(full.truncated)
        XCTAssertEqual(full.entries.first?.bytes, 60)
    }

    func testAttachSetsArtifactsTruncationAndResultBundles() throws {
        try write("Proof.xcresult/Data/blob", "abcd")
        try write("UI/Smoke.xcresult/Info.plist")
        try write("proof.mp4")
        var info = JobInfo(
            job: Job(id: "J-0001", sequence: 1, project: "demo", submitter: "t", queueTime: 0, createdAt: 0),
            explanation: nil)
        XCTAssertNil(ArtifactListing.attach(to: info).artifacts, "not started: nothing to list")
        info.runDir = runDir
        let attached = ArtifactListing.attach(to: info)
        XCTAssertEqual(attached.artifacts?.count, 3)
        XCTAssertNil(attached.artifactsTruncated)
        XCTAssertEqual(attached.resultBundles, [runDir + "/Proof.xcresult", runDir + "/UI/Smoke.xcresult"])
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(attached)) as? [String: Any])
        XCTAssertEqual(json["result_bundles"] as? [String], attached.resultBundles)
        XCTAssertEqual(json["run_dir"] as? String, runDir)
    }
}
