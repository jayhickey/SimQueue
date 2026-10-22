// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueProtocol
import XCTest

@testable import SimQueueDashboard

final class DashboardTests: XCTestCase {
    func testListenerDefaultsToLoopbackAndAllowsExplicitIPv4Bindings() throws {
        for address in [nil, "127.0.0.1", "0.0.0.0"] as [String?] {
            let server: DashboardServer
            if let address {
                server = try DashboardServer(bindAddress: address, socketPath: "/unused-test-socket")
            } else {
                server = try DashboardServer(socketPath: "/unused-test-socket")
            }
            let url = try XCTUnwrap(URLComponents(string: server.url))
            XCTAssertEqual(url.host, "127.0.0.1")
            XCTAssertGreaterThan(try XCTUnwrap(url.port), 0)
        }
    }

    func testUnavailableAddressDoesNotFallBackToLoopbackOrWildcard() {
        XCTAssertThrowsError(try DashboardServer(bindAddress: "192.0.2.123", socketPath: "/unused-test-socket"))
    }

    func testInvalidBindingsNeverFallBackToWildcard() {
        for address in ["", "localhost", "999.0.0.1", "127.0.0.1:8765", "::1", "https://example.com"] {
            XCTAssertThrowsError(try DashboardServer(bindAddress: address, socketPath: "/unused-test-socket")) {
                guard case DashboardError.invalidBindAddress = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
    }

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

    func testRoutesRejectMalformedHostsMissingCapabilitiesAndUnsafeMutations() {
        let api = DashboardAPI { _ in
            XCTFail("Unexpected daemon request"); throw DashboardError.unavailable
        }
        for request in [
            "GET /secret/api/snapshot HTTP/1.1\r\nHost: example.com/path\r\n\r\n",
            "GET /secret/api/snapshot HTTP/1.1\r\nHost: user@example.com\r\n\r\n",
            "GET /secret/api/snapshot HTTP/1.1\r\n\r\n",
            "POST /secret/api/snapshot HTTP/1.1\r\nHost: 127.0.0.1:9000\r\n\r\n",
            "GET /wrong/api/snapshot HTTP/1.1\r\nHost: 127.0.0.1:9000\r\n\r\n",
            "GET /secret/api/snapshot HTTP/1.1\r\nHost: 127.0.0.1:9000\r\nHost: attacker.example\r\n\r\n",
        ] {
            XCTAssertEqual(
                DashboardServer.route(request: request, token: "secret", api: api).status,
                "403 Forbidden")
        }
        for path in ["cancel/J-1", "job/../state", "logs/", "job/a?b", "logs/J-1/extra"] {
            XCTAssertThrowsError(try api.response(path: path))
        }
    }

    func testReverseProxyHostsAndHTTPSControls() {
        var requests: [RequestParams] = []
        let api = DashboardAPI { params in
            requests.append(params)
            throw ProtocolError(.invalidState, "test response")
        }
        for host in ["mini.example.ts.net", "mini.example.ts.net:8765", "127.0.0.1:9000"] {
            let base = " /secret/ HTTP/1.1\r\nHost: \(host)\r\n"
            XCTAssertEqual(
                DashboardServer.route(request: "GET" + base + "\r\n", token: "secret", api: api).status, "200 OK")
            for scheme in ["http", "https"] {
                let request =
                    "POST /secret/api/cancel/J-1 HTTP/1.1\r\nHost: \(host)\r\nOrigin: \(scheme)://\(host)\r\nX-SimQueue-Action: 1\r\n\r\n"
                XCTAssertEqual(
                    DashboardServer.route(request: request, token: "secret", api: api).status, "409 Conflict")
            }
            let crossOrigin =
                "POST /secret/api/cancel/J-1 HTTP/1.1\r\nHost: \(host)\r\nOrigin: https://other.example\r\nX-SimQueue-Action: 1\r\n\r\n"
            XCTAssertEqual(
                DashboardServer.route(request: crossOrigin, token: "secret", api: api).status, "403 Forbidden")
        }
        XCTAssertEqual(requests.count, 6)
    }

    func testAssetsAreSelfContainedAndUnknownRoutesFailClosed() {
        let api = DashboardAPI { _ in throw DashboardError.unavailable }
        func route(_ path: String) -> DashboardServer.Reply {
            DashboardServer.route(
                request: "GET /secret/\(path) HTTP/1.1\r\nHost: 127.0.0.1:9000\r\n\r\n", token: "secret", api: api)
        }
        XCTAssertEqual(route("").status, "200 OK")
        XCTAssertEqual(route("app.js").type, "text/javascript; charset=utf-8")
        XCTAssertEqual(route("style.css").status, "200 OK")
        XCTAssertEqual(route("../state").status, "404 Not Found")
        XCTAssertEqual(route("api/snapshot").status, "503 Service Unavailable")
        XCTAssertFalse(String(decoding: route("app.js").body, as: UTF8.self).contains("innerHTML"))
    }

    func testPWAAssetsKeepCapabilityScopeAndServeNativePNGIcons() throws {
        let api = DashboardAPI { _ in
            XCTFail("Asset requested the daemon"); throw DashboardError.unavailable
        }
        func asset(_ path: String, token: String = "secret") -> DashboardServer.Reply {
            DashboardServer.route(
                request: "GET /\(token)/\(path) HTTP/1.1\r\nHost: mini.example.ts.net\r\n\r\n",
                token: "secret", api: api)
        }
        let manifestReply = asset("manifest.webmanifest")
        XCTAssertEqual(manifestReply.status, "200 OK")
        XCTAssertTrue(manifestReply.type.hasPrefix("application/manifest+json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestReply.body) as? [String: Any])
        XCTAssertEqual(manifest["start_url"] as? String, "./")
        XCTAssertEqual(manifest["scope"] as? String, "./")
        XCTAssertEqual(manifest["id"] as? String, "./")
        XCTAssertEqual(manifest["display"] as? String, "standalone")
        let icons = try XCTUnwrap(manifest["icons"] as? [[String: String]])
        XCTAssertEqual(icons.compactMap { $0["sizes"] }, ["192x192", "512x512"])
        for size in [180, 192, 512] {
            let name = "icon-\(size).png"
            let reply = asset(name)
            XCTAssertEqual(reply.status, "200 OK")
            XCTAssertEqual(reply.type, "image/png")
            XCTAssertEqual(Array(reply.body.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
            func dimension(_ offset: Int) -> Int {
                reply.body[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            }
            XCTAssertEqual(dimension(16), size)
            XCTAssertEqual(dimension(20), size)
            XCTAssertEqual(asset(name, token: "wrong").status, "403 Forbidden")
        }
        XCTAssertEqual(asset("manifest.webmanifest", token: "wrong").status, "403 Forbidden")
        XCTAssertEqual(asset("sw.js", token: "wrong").status, "403 Forbidden")
        XCTAssertTrue(asset("sw.js").type.hasPrefix("text/javascript"))
        let html = String(decoding: asset("").body, as: UTF8.self)
        XCTAssertTrue(html.contains("rel=\"manifest\""))
        XCTAssertTrue(html.contains("rel=\"apple-touch-icon\""))
        let wire = String(decoding: DashboardServer.wireResponse(asset("sw.js")), as: UTF8.self)
        XCTAssertTrue(wire.contains("worker-src 'self'"))
        XCTAssertTrue(wire.contains("manifest-src 'self'"))
        XCTAssertFalse(wire.contains("Service-Worker-Allowed"))
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

    func testMutationsRequireSameOriginAndExplicitActionHeader() throws {
        var requests: [RequestParams] = []
        let job = JobInfo(
            job: Job(id: "J-1", sequence: 1, project: "test", submitter: "test", queueTime: 0, createdAt: 0),
            explanation: nil)
        let api = DashboardAPI { params in
            requests.append(params); return .job(job)
        }
        let prefix = "POST /secret/api/priority/J-1/70 HTTP/1.1\r\nHost: 127.0.0.1:9000\r\n"
        let valid = "Origin: http://127.0.0.1:9000\r\nX-SimQueue-Action: 1\r\nContent-Length: 0\r\n\r\n"
        func route(_ headers: String) -> DashboardServer.Reply {
            DashboardServer.route(request: prefix + headers, token: "secret", api: api)
        }
        for headers in [
            "\r\n",
            valid.replacingOccurrences(of: "Origin: http://127.0.0.1:9000", with: "Origin: https://attacker.example"),
            valid.replacingOccurrences(of: "X-SimQueue-Action: 1\r\n", with: ""),
            valid.replacingOccurrences(of: "Content-Length: 0", with: "Content-Length: 2"),
            "Transfer-Encoding: chunked\r\n" + valid,
        ] {
            XCTAssertEqual(route(headers).status, "403 Forbidden")
        }
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(route(valid).status, "200 OK")
        XCTAssertEqual(requests, [.bump(BumpParams(jobID: "J-1", priority: 70))])
        _ = try api.mutate(path: "cancel/J-1")
        XCTAssertEqual(requests.last, .cancel(CancelParams(jobID: "J-1")))
        for path in ["priority/J-1/101", "priority/J-1/-1", "priority/J-1/1.5", "cancel/J-1/extra", "drain/J-1"] {
            XCTAssertThrowsError(try api.mutate(path: path))
        }
        XCTAssertEqual(requests.count, 2)
    }

    func testStaleJobConflictIsReturnedToTheBrowser() {
        let api = DashboardAPI { _ in throw ProtocolError(.invalidState, "job already started") }
        let reply = DashboardServer.route(
            request:
                "POST /secret/api/priority/J-1/70 HTTP/1.1\r\nHost: 127.0.0.1:9000\r\nOrigin: http://127.0.0.1:9000\r\nX-SimQueue-Action: 1\r\n\r\n",
            token: "secret", api: api)
        XCTAssertEqual(reply.status, "409 Conflict")
        XCTAssertEqual(String(decoding: reply.body, as: UTF8.self), "job already started")
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
    func testTailRouteIsBoundedAndRejectsOldDaemonResponses() throws {
        var requests: [RequestParams] = []
        let api = DashboardAPI { params in
            requests.append(params)
            return .logs(
                LogsResult(
                    jobID: "J-1", path: "output", offset: 100, nextOffset: 104,
                    data: "tail", jobFinished: false, atEnd: true, tailBytes: 32_768))
        }
        _ = try api.response(path: "logs/J-1/tail")
        XCTAssertEqual(requests, [.logs(LogsParams(jobID: "J-1", maxBytes: 32_768, tailBytes: 32_768))])
        for path in ["logs/J-1/tail/extra", "job/J-1/tail", "logs/J-1/arbitrary"] {
            XCTAssertThrowsError(try api.response(path: path))
        }
        XCTAssertEqual(requests.count, 1)
        let old = DashboardAPI { _ in
            .logs(
                LogsResult(
                    jobID: "J-1", path: "output", offset: 0,
                    nextOffset: 4, data: "head", jobFinished: false, atEnd: false))
        }
        XCTAssertThrowsError(try old.response(path: "logs/J-1/tail")) { error in
            XCTAssertEqual((error as? ProtocolError)?.code, .invalidState)
        }
    }

}
