// SPDX-License-Identifier: MIT

import Foundation
import XCTest

@testable import SimQueueDashboard

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private final class TokenServerWorker: @unchecked Sendable {
    let server: DashboardServer
    init(_ server: DashboardServer) { self.server = server }
}

private final class ObservedTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

final class DashboardTokenTests: XCTestCase {
    private func configPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("config.json").path
    }

    func testUpgradeAddsTokenOnceAndPreservesConfigurationAndPermissions() throws {
        let path = try configPath()
        try Data(#"{"job_output_root":"/example/jobs","custom":{"nested":true}}"#.utf8).write(
            to: URL(fileURLWithPath: path))
        let store = DashboardTokenStore(configPath: path)
        let first = try store.loadOrCreate()
        XCTAssertNotNil(UUID(uuidString: first))
        let saved = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(try DashboardTokenStore(configPath: path).loadOrCreate(), first)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), saved)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(config["job_output_root"] as? String, "/example/jobs")
        XCTAssertEqual((config["custom"] as? [String: Bool])?["nested"], true)
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testMissingConfigIsCreatedAndExistingLegacyURLTokenIsRetained() throws {
        let path = try configPath()
        let store = DashboardTokenStore(configPath: path)
        XCTAssertEqual(try store.loadOrCreate(), try store.current())
        let imported = UUID().uuidString
        try Data("{\"dashboard_token\":\"\(imported)\"}".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(try store.loadOrCreate(), imported)
    }

    func testInvalidConfigNeverGetsSilentlyOverwrittenOrServed() throws {
        let path = try configPath()
        let store = DashboardTokenStore(configPath: path)
        for text in ["{broken", "[]", #"{"dashboard_token":""}"#, #"{"dashboard_token":123}"#] {
            let bytes = Data(text.utf8)
            try bytes.write(to: URL(fileURLWithPath: path))
            XCTAssertThrowsError(try store.loadOrCreate())
            XCTAssertThrowsError(try store.current())
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        }
    }

    func testSymlinkConfigIsPreservedAndItsTargetGetsTheToken() throws {
        let path = try configPath()
        let target = path + ".target"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        let token = try DashboardTokenStore(configPath: path).loadOrCreate()
        XCTAssertEqual(try DashboardTokenStore(configPath: target).current(), token)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path), target)
    }

    func testConcurrentFirstLaunchesAgreeOnOneToken() throws {
        let path = try configPath()
        let group = DispatchGroup()
        let observed = ObservedTokens()
        for _ in 0..<12 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { observed.append(try DashboardTokenStore(configPath: path).loadOrCreate()) } catch {
                    XCTFail("Concurrent startup failed: \(error)")
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        let token = try DashboardTokenStore(configPath: path).current()
        XCTAssertEqual(observed.snapshot().count, 12)
        XCTAssertEqual(Set(observed.snapshot()), [token])
        XCTAssertEqual(try DashboardTokenStore(configPath: path).loadOrCreate(), token)
    }

    func testRestartKeepsPWALinkAndRotationRevokesRunningListeners() throws {
        let path = try configPath()
        let first = try DashboardServer(socketPath: "/unused", configPath: path)
        let savedURL = try XCTUnwrap(URL(string: first.url))
        let port = try XCTUnwrap(savedURL.port)
        first.stop()
        let worker = TokenServerWorker(try DashboardServer(port: UInt16(port), socketPath: "/unused", configPath: path))
        XCTAssertEqual(worker.server.url, savedURL.absoluteString)
        let done = expectation(description: "server stopped")
        Thread.detachNewThread {
            try? worker.server.run(); done.fulfill()
        }
        func get(_ url: URL, expected: Int) {
            let request = expectation(description: "HTTP \(expected)")
            URLSession.shared.dataTask(with: url) { _, response, error in
                XCTAssertNil(error)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, expected)
                request.fulfill()
            }.resume()
            wait(for: [request], timeout: 5)
        }
        get(savedURL, expected: 200)
        _ = try DashboardTokenStore(configPath: path).rotate()
        XCTAssertNotEqual(worker.server.url, savedURL.absoluteString)
        get(savedURL, expected: 403)
        get(try XCTUnwrap(URL(string: worker.server.url)), expected: 200)
        try Data("{broken".utf8).write(to: URL(fileURLWithPath: path))
        get(try XCTUnwrap(URL(string: worker.server.url)), expected: 503)
        worker.server.stop()
        wait(for: [done], timeout: 5)
    }
}
