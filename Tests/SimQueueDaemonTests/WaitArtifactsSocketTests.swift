// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueProtocol
import XCTest

/// CR on #64: the socket `wait` (the server's streamed wait, not `DaemonService.handle`) ends
/// with the run directory listed, like `explain`. Real `sh` jobs over the real socket.
final class WaitArtifactsSocketTests: XCTestCase {
    func testTheFinalWaitResponseListsArtifactsAndResultBundles() throws {
        let daemon = try TestDaemon(realProcesses: true)
        addTeardownBlock { daemon.destroy() }
        let script =
            #"mkdir -p "$SIMQ_RUN_DIR/Proof.xcresult/Data" "$SIMQ_RUN_DIR/shots"; "#
            + #"printf 'abcd' > "$SIMQ_RUN_DIR/Proof.xcresult/Data/blob"; printf 'png' > "$SIMQ_RUN_DIR/shots/a.png"; "#
            + #"printf 's' > "$TMPDIR/scratch.png""#
        let id = try daemon.submit(
            SubmitParams(project: "app", submitter: "dev", command: ["/bin/sh", "-c", script])
        ).job.id

        var events: [JobInfo] = []
        let done = try daemon.wait(id, stream: true) { events.append($0) }
        XCTAssertEqual(done.state, .succeeded)
        let runDir = try XCTUnwrap(done.runDir)
        let paths = (done.artifacts ?? []).map(\.path)
        XCTAssertTrue(paths.contains("Proof.xcresult"), "\(paths)")
        XCTAssertTrue(paths.contains("shots/a.png"), "\(paths)")
        XCTAssertFalse(paths.contains { $0.hasPrefix("tmp") }, "the job's TMPDIR is never listed: \(paths)")
        XCTAssertEqual(done.resultBundles, [runDir + "/Proof.xcresult"])
        XCTAssertNil(done.artifactsTruncated)
        XCTAssertTrue(events.allSatisfy { $0.artifacts == nil && $0.resultBundles == nil }, "polls don't list")

        // A plain (non-streamed) wait on the finished job gets the same listing.
        let again = try daemon.wait(id)
        XCTAssertEqual(again.resultBundles, done.resultBundles)
        XCTAssertEqual(again.artifacts, done.artifacts)
    }
}
