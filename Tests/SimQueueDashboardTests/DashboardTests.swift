// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueProtocol
import XCTest

@testable import SimQueueDashboard

final class DashboardTests: XCTestCase {
    func testSnapshotSeparatesActiveFromBoundedHistory() throws {
        var requests: [RequestParams] = []
        let status = try JSONDecoder().decode(
            StatusResult.self,
            from: Data(
                """
                {"daemon":{"version":"test","pid":1,"epoch":1,"started_at":0,
                "state_path":"state","socket_path":"socket","backend":"fake","cleanup_mode":"report_only","probe":"fake"},
                "queued":1,"admitted":0,"running":0,"paused":false,"draining":false,
                "load_throttled":false,"global_wait_reasons":[]}
                """.utf8))
        let job = JobInfo(
            job: Job(id: "J-1", sequence: 1, project: "example", submitter: "tester", queueTime: 1, createdAt: 1),
            explanation: nil)
        let api = DashboardAPI { params in
            requests.append(params)
            switch params {
            case .status: return .status(status)
            case .jobs(let query): return .jobs(query.states?.contains(.queued) == true ? [job] : [])
            default: throw DashboardError.unavailable
            }
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: api.response(path: "snapshot")) as? [String: Any])
        XCTAssertEqual((object["active"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((object["recent"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(requests.count, 3)
        guard case .jobs(let active) = requests[1], case .jobs(let recent) = requests[2] else { return XCTFail() }
        XCTAssertEqual(active.states, [.queued, .admitted, .running])
        XCTAssertEqual(active.limit, DashboardAPI.activeLimit)
        XCTAssertEqual(recent.limit, 100)
        XCTAssertTrue(try XCTUnwrap(recent.states).allSatisfy(\.isTerminal))
    }

    func testRoutesRejectOtherWebsitesAndMutationsBeforeObservingDaemon() {
        let api = DashboardAPI { _ in
            XCTFail("Unexpected daemon request"); throw DashboardError.unavailable
        }
        for request in [
            "GET /secret/api/snapshot HTTP/1.1\r\nHost: attacker.example\r\n\r\n",
            "POST /secret/api/snapshot HTTP/1.1\r\nHost: 127.0.0.1:9000\r\n\r\n",
            "GET /wrong/api/snapshot HTTP/1.1\r\nHost: 127.0.0.1:9000\r\n\r\n",
            "GET /secret/api/snapshot HTTP/1.1\r\nHost: 127.0.0.1:9000\r\nHost: attacker.example\r\n\r\n",
        ] {
            XCTAssertEqual(
                DashboardServer.route(request: request, authority: "127.0.0.1:9000", token: "secret", api: api).status,
                "403 Forbidden")
        }
        for path in ["cancel/J-1", "job/../state", "logs/", "job/a?b", "logs/J-1/extra"] {
            XCTAssertThrowsError(try api.response(path: path))
        }
    }

    func testAssetsAreSelfContainedAndUnknownRoutesFailClosed() {
        let api = DashboardAPI { _ in throw DashboardError.unavailable }
        func route(_ path: String) -> DashboardServer.Reply {
            DashboardServer.route(
                request: "GET /secret/\(path) HTTP/1.1\r\nHost: 127.0.0.1:9000\r\n\r\n", authority: "127.0.0.1:9000",
                token: "secret", api: api)
        }
        XCTAssertEqual(route("").status, "200 OK")
        XCTAssertEqual(route("app.js").type, "text/javascript; charset=utf-8")
        XCTAssertEqual(route("style.css").status, "200 OK")
        XCTAssertEqual(route("../state").status, "404 Not Found")
        XCTAssertEqual(route("api/snapshot").status, "503 Service Unavailable")
        XCTAssertFalse(String(decoding: route("app.js").body, as: UTF8.self).contains("innerHTML"))
    }

    func testHTTPFramingPreservesEntireUTF8Body() throws {
        let body = Data("<!doctype html>\n✓".utf8)
        let response = DashboardServer.wireResponse(.init("200 OK", "text/html", body))
        let separator = try XCTUnwrap(response.range(of: Data("\r\n\r\n".utf8)))
        XCTAssertEqual(Data(response[separator.upperBound...]), body)
        let headers = String(decoding: response[..<separator.lowerBound], as: UTF8.self)
        XCTAssertTrue(headers.contains("Content-Length: \(body.count)\r\n"))
        XCTAssertTrue(headers.contains("Cache-Control: no-store"))
        XCTAssertTrue(headers.contains("frame-ancestors 'none'"))
    }

    func testLogsAreBoundedAndJobDetailsUseExplain() throws {
        var requests: [RequestParams] = []
        let api = DashboardAPI { params in
            requests.append(params); throw DashboardError.unavailable
        }
        XCTAssertThrowsError(try api.response(path: "logs/J-42"))
        XCTAssertThrowsError(try api.response(path: "job/J-42"))
        guard case .logs(let logs) = requests[0], case .explain(let job) = requests[1] else { return XCTFail() }
        XCTAssertEqual(logs.jobID, "J-42")
        XCTAssertEqual(logs.offset, 0)
        XCTAssertEqual(logs.maxBytes, 32_768)
        XCTAssertEqual(job.jobID, "J-42")
    }
}
