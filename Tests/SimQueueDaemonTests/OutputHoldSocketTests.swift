// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueProtocol
import XCTest

final class OutputHoldSocketTests: XCTestCase {
    private let id = "01234567-89ab-4cde-8fab-0123456789ab"

    func testLifecycleExplicitAcknowledgementDedupeAndBoundedReads() throws {
        let daemon = try TestDaemon()
        defer { daemon.destroy() }
        let created = try daemon.result(.outputHoldCreate(.init(id: id.uppercased(), label: "evidence")))
        guard case .outputHold(let hold) = created else { return XCTFail("wrong result: \(created)") }
        XCTAssertEqual(hold.hold.id, id)
        XCTAssertTrue(hold.jobs.isEmpty)
        var request = SubmitParams(
            project: "holds", submitter: "test", dedupeKey: "same", minSims: 0,
            payloadJSON: #"{"fake":{"run_seconds":60}}"#)
        guard case .submitHeld(let first) = try daemon.result(.submitHeld(.init(holdID: id, submission: request)))
        else {
            return XCTFail("protected submit requires a distinct acknowledgement")
        }
        XCTAssertEqual(first.holdID, id)
        let secondID = UUID().uuidString.lowercased()
        _ = try daemon.result(.outputHoldCreate(.init(id: secondID, label: "other")))
        guard
            case .submitHeld(let second) = try daemon.result(.submitHeld(.init(holdID: secondID, submission: request)))
        else {
            return XCTFail("wrong protected result")
        }
        XCTAssertEqual(second.submission.job.id, first.submission.job.id)
        XCTAssertTrue(second.submission.deduplicated)
        XCTAssertEqual(try daemon.protocolError(.outputHoldRelease(.init(id: id))).code, .invalidState)
        guard case .outputHold(let shown) = try daemon.result(.outputHoldShow(.init(id: id, limit: 1))) else {
            return XCTFail()
        }
        XCTAssertEqual(shown.jobs.map(\.jobID), [first.submission.job.id])
        XCTAssertEqual(shown.nextJobID, first.submission.job.id)
        guard
            case .outputHold(let next) = try daemon.result(
                .outputHoldShow(.init(id: id, afterJobID: shown.nextJobID, limit: 1)))
        else { return XCTFail() }
        XCTAssertTrue(next.jobs.isEmpty)
        XCTAssertNil(next.nextJobID)
        _ = try daemon.result(.cancel(.init(jobID: first.submission.job.id)))
        _ = try daemon.wait(first.submission.job.id)
        guard case .outputHold(let released) = try daemon.result(.outputHoldRelease(.init(id: id))) else {
            return XCTFail()
        }
        XCTAssertNotNil(released.hold.releasedAt)
        XCTAssertTrue(try daemon.side.hasActiveOutputHold(jobID: first.submission.job.id), "other hold remains")
        XCTAssertEqual(
            try daemon.protocolError(.submitHeld(.init(holdID: id, submission: request))).code, .invalidState)
        request.dedupeKey = nil
        let ordinary = try daemon.submit(request)
        XCTAssertNotEqual(ordinary.job.id, first.submission.job.id)
        XCTAssertFalse(try daemon.side.hasActiveOutputHold(jobID: ordinary.job.id))
        XCTAssertEqual(try daemon.protocolError(.outputHoldList(.init(limit: 201))).code, .invalidArgument)
        XCTAssertEqual(try daemon.protocolError(.outputHoldShow(.init(id: "invalid"))).code, .invalidArgument)
        XCTAssertEqual(try daemon.protocolError(.outputHoldShow(.init(id: UUID().uuidString))).code, .notFound)
        guard case .outputHolds(let list) = try daemon.result(.outputHoldList(.init(limit: 1))) else {
            return XCTFail()
        }
        XCTAssertEqual(list.holds.count, 1)
        XCTAssertNotNil(list.nextID)
    }

    func testWireRoundTripsAndOrdinarySubmitEncodingStaysUnchanged() throws {
        let submit = SubmitParams(project: "test", submitter: "test", minSims: 0)
        let ordinary = try LineCodec.encode(Request(id: "r", params: .submit(submit)))
        XCTAssertFalse(String(decoding: ordinary, as: UTF8.self).contains("hold"))
        let cases: [RequestParams] = [
            .outputHoldCreate(.init(id: id, label: "evidence")),
            .outputHoldShow(.init(id: id, afterJobID: "J-one", limit: 2)),
            .outputHoldList(.init(afterID: id, limit: 2)), .outputHoldRelease(.init(id: id)),
            .submitHeld(.init(holdID: id, submission: submit)),
        ]
        for params in cases {
            let request = Request(id: "r", params: params)
            XCTAssertEqual(try LineCodec.decode(Request.self, from: LineCodec.encode(request)), request)
        }
        let legacy = String(
            decoding: try LineCodec.encode(Request(params: .submitHeld(.init(holdID: id, submission: submit)))),
            as: UTF8.self)
        let removed = legacy.replacingOccurrences(of: "\"submission\":{", with: "\"submission\":{\"shards\":2,")
        XCTAssertThrowsError(try LineCodec.decode(Request.self, from: Data(removed.utf8)))
    }
}
