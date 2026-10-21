// SPDX-License-Identifier: MIT

import Foundation
import SimQueueIPC
import SimQueueProtocol
import XCTest

/// Lease acquisition retries a timed-out request until its own deadline. A stand-in
/// daemon on a real socket ignores the first request to exercise that recovery path.
private final class ServedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

final class LeaseClientRetryTests: XCTestCase {
    private static var productsDirectory: URL {
        #if os(macOS)
            for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
                return bundle.bundleURL.deletingLastPathComponent()
            }
        #endif
        return Bundle.main.bundleURL
    }

    private func simq() throws -> URL {
        let url = Self.productsDirectory.appendingPathComponent("simq")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("simq not built at \(url.path)")
        }
        return url
    }

    /// Serves `answers.count` connections in order: nil reads the request and never answers
    /// (until the client gives up), a result answers it.
    private func standInDaemon(at socketPath: String, answers: [LeaseResult?]) throws -> (DispatchGroup, () -> Int) {
        let listener = try UnixListener(path: socketPath)
        let group = DispatchGroup()
        let served = ServedCount()
        group.enter()
        Thread.detachNewThread {
            defer {
                listener.close()
                group.leave()
            }
            for answer in answers {
                guard let connection = try? listener.accept() else { return }
                defer { connection.close() }
                guard let line = try? connection.readLine(maxBytes: 1 << 20),
                    let request = try? LineCodec.decode(Request.self, from: line)
                else { return }
                served.increment()
                guard let answer else {
                    _ = try? connection.readLine(maxBytes: 1 << 20)  // until the client hangs up
                    continue
                }
                _ = try? connection.write(LineCodec.encode(Response(id: request.id, body: .result(.lease(answer)))))
            }
        }
        return (group, { served.value })
    }

    private func run(_ arguments: [String], environment: [String: String]) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = try simq()
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self)
        )
    }

    private func stateDir() throws -> String {
        let dir = testScratchRoot() + "/sql-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    func testLeaseAcquireRetriesATimedOutRequestUntilItsDeadline() throws {
        let dir = try stateDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let granted = LeaseResult(state: "granted", holder: "ci-1", udid: "FAKE-POOL-0001", name: "simq-pool-1-1")
        let (done, served) = try standInDaemon(at: dir + "/simq.sock", answers: [nil, nil, granted])
        let (code, stdout, stderr) = try run(
            ["lease", "acquire", "--holder", "ci-1", "--pid", "0", "--wait-timeout", "30s", "--state-dir", dir],
            environment: ["SIMQ_REQUEST_TIMEOUT_SECONDS": "0.5", "SIMQ_NO_AUTOSTART": "1"])
        XCTAssertEqual(code, 0, stderr)
        XCTAssertTrue(stdout.hasPrefix("FAKE-POOL-0001"), stdout)
        XCTAssertTrue(stderr.contains("daemon busy"), stderr)
        XCTAssertEqual(served(), 3, "two timed-out requests, then the answered one")
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
    }

    func testLeaseAcquireStillGivesUpAtItsDeadline() throws {
        let dir = try stateDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let (done, _) = try standInDaemon(at: dir + "/simq.sock", answers: Array(repeating: nil, count: 50))
        let started = Date()
        let (code, _, stderr) = try run(
            ["lease", "acquire", "--holder", "ci-1", "--pid", "0", "--wait-timeout", "2s", "--state-dir", dir],
            environment: ["SIMQ_REQUEST_TIMEOUT_SECONDS": "0.5", "SIMQ_NO_AUTOSTART": "1"])
        XCTAssertEqual(code, 69, "daemon unavailable once the wait deadline has passed: \(stderr)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        // Unblock the stand-in so its thread exits.
        for _ in 0..<50 {
            guard let connection = try? UnixConnection.connect(path: dir + "/simq.sock") else { break }
            connection.close()
        }
        _ = done.wait(timeout: .now() + 5)
    }
}
