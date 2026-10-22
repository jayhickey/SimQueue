// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueProtocol
import XCTest

final class LogTailTests: XCTestCase {
    func testTailReadsNewestBoundedOutputAndHandlesGrowthAndTruncation() throws {
        let daemon = try TestDaemon()
        defer { daemon.destroy() }
        _ = try daemon.result(.drain)
        let id = try daemon.submit(SubmitParams(project: "test", submitter: "test", command: ["unused"])).job.id
        let job = try XCTUnwrap(daemon.side.job(id: id))
        let path = JobArtifacts(root: daemon.paths.jobsRoot).logPath(for: job)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        func write(_ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path)) }
        func tail(_ bytes: Int) throws -> LogsResult {
            guard
                case .logs(let result) = try daemon.result(.logs(LogsParams(jobID: id, maxBytes: 8, tailBytes: bytes)))
            else { throw NSError(domain: "test", code: 1) }
            return result
        }
        let text = String(repeating: "x", count: 70_000) + "é😀\nnew\n"
        try write(text)
        let first = try tail(8)
        XCTAssertEqual(first.data, "\nnew\n")
        XCTAssertFalse(first.data.contains("\u{FFFD}"))
        XCTAssertEqual(first.nextOffset, Int64(text.utf8.count))
        XCTAssertEqual(first.offset, first.nextOffset - 5)
        XCTAssertEqual(first.tailBytes, 8)
        XCTAssertTrue(first.atEnd)
        XCTAssertFalse(first.jobFinished, "an empty/live end is not terminal")
        try write(text + "second\n")
        XCTAssertEqual(try tail(8).data, "\nsecond\n")
        try write("short\n")
        let reset = try tail(8)
        XCTAssertEqual(reset.offset, 0)
        XCTAssertEqual(reset.data, "short\n")
        try write(String(repeating: "x", count: 200_000))
        guard
            case .logs(let bounded) = try daemon.result(
                .logs(LogsParams(jobID: id, maxBytes: Int.max, tailBytes: Int.max)))
        else {
            return XCTFail("missing bounded tail")
        }
        XCTAssertEqual(bounded.data.utf8.count, LogsParams.maxBytesLimit)
        XCTAssertEqual(bounded.tailBytes, LogsParams.maxBytesLimit)
        try write("short\n")
        for invalid in [0, -1] {
            XCTAssertEqual(
                try daemon.protocolError(.logs(LogsParams(jobID: id, tailBytes: invalid))).code, .invalidArgument)
        }
        guard case .logs(let legacy) = try daemon.result(.logs(LogsParams(jobID: id, maxBytes: 2))) else {
            return XCTFail("missing response")
        }
        XCTAssertEqual(legacy.data, "sh")
        XCTAssertNil(legacy.tailBytes)
    }

    func testTailProtocolRoundTripAndOldResponsesRemainDecodable() throws {
        let request = Request(params: .logs(LogsParams(jobID: "J-1", maxBytes: 32_768, tailBytes: 32_768)))
        XCTAssertEqual(try JSONDecoder().decode(Request.self, from: JSONEncoder().encode(request)), request)
        let original = LogsResult(
            jobID: "J-1", path: "output", offset: 0, nextOffset: 1, data: "a", jobFinished: true, atEnd: true)
        let decoded = try JSONDecoder().decode(LogsResult.self, from: JSONEncoder().encode(original))
        XCTAssertNil(decoded.tailBytes)
        XCTAssertEqual(decoded, original)
    }
}
