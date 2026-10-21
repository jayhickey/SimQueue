// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueIPC
import SimQueueProtocol
import XCTest

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Real CLI/socket coverage: recovering an observation must never create another job
/// or advance its log offset before a complete response was received.
final class ObservationRecoveryTests: XCTestCase {
    private final class Server: @unchecked Sendable {
        enum Answer { case result(ResultPayload), unanswered, disconnect, trickle }
        let listener: UnixListener
        let done = DispatchGroup()
        private let lock = NSLock()
        private var received: [RequestParams] = []
        var requests: [RequestParams] { lock.withLock { received } }

        init(path: String, answer: @escaping @Sendable (Request, Int) -> Answer) throws {
            listener = try UnixListener(path: path)
            done.enter()
            Thread.detachNewThread { [self] in
                defer { listener.close(); done.leave() }
                while let connection = try? listener.accept() {
                    defer { connection.close() }
                    guard let line = try? connection.readLine(maxBytes: 1 << 20),
                        let request = try? LineCodec.decode(Request.self, from: line)
                    else { continue }
                    let index = lock.withLock {
                        received.append(request.params)
                        return received.count - 1
                    }
                    switch answer(request, index) {
                    case .result(let payload):
                        try? connection.write(LineCodec.encode(Response(id: request.id, body: .result(payload))))
                    case .unanswered:
                        // The client closes this connection when its receive times out.
                        _ = try? connection.readLine(maxBytes: 1 << 20)
                    case .disconnect: break
                    case .trickle:
                        for _ in 0..<50 {
                            do { try connection.write(Data(" ".utf8)) } catch { break }
                            Thread.sleep(forTimeInterval: 0.04)
                        }
                    }
                }
            }
        }

        func stop() {
            listener.close()
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "stand-in socket worker must stop")
        }
    }

    private func directory() throws -> String {
        let path = testScratchRoot() + "/sqo-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return path
    }

    private func run(_ args: [String], state: String, recovery: Double = 0.7) throws -> (Int32, String, Double) {
        #if os(macOS)
            let products = try XCTUnwrap(Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") })
                .bundleURL.deletingLastPathComponent()
        #else
            let products = Bundle.main.bundleURL
        #endif
        let binary = products.appendingPathComponent("simq")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path), "build simq with --build-tests")
        let process = Process()
        process.executableURL = binary
        process.arguments = args + ["--state-dir", state]
        // Insert connection flags before the submitted command's separator.
        if let separator = process.arguments?.firstIndex(of: "--") {
            var arguments = args
            arguments.insert(contentsOf: ["--state-dir", state], at: separator)
            process.arguments = arguments
        }
        var env = ProcessInfo.processInfo.environment
        env["SIMQ_NO_AUTOSTART"] = "1"
        env["SIMQ_REQUEST_TIMEOUT_SECONDS"] = "0.1"
        env["SIMQ_TEST_OBSERVATION_RECOVERY_SECONDS"] = String(recovery)
        process.environment = env
        let output = URL(fileURLWithPath: state).appendingPathComponent(UUID().uuidString + ".client.log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        let started = Date()
        try process.run()
        let limit = started.addingTimeInterval(8)
        while process.isRunning, Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            // Kill only this test-owned child if an implementation regression loops;
            // never leave a failed recovery test blocking the entire test process.
            _ = kill(process.processIdentifier, SIGKILL)
            XCTFail("observation client exceeded the external test deadline")
        }
        process.waitUntilExit()
        let data = try Data(contentsOf: output)
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), Date().timeIntervalSince(started))
    }

    private static func job(_ state: JobState) -> JobInfo {
        JobInfo(
            job: Job(
                id: "J-0001", sequence: 1, project: "observation", submitter: "test", queueTime: 0, createdAt: 0,
                state: state, resultClass: state == .succeeded ? .success : nil), explanation: nil)
    }

    func testRunRecoversDelayedLogsAndExplainWithoutDuplicateOutputOrSubmission() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let server = try Server(path: path + "/simq.sock") { request, index in
            switch request.params {
            case .submit: return .result(.submit(SubmitResponse(job: Self.job(.queued), deduplicated: false)))
            case .wait: return .result(.job(Self.job(.running)))
            case .logs(let params):
                if index == 3 { return .unanswered }
                let data = params.offset == 0 ? "first\n" : "last\n"
                return .result(
                    .logs(
                        LogsResult(
                            jobID: params.jobID, path: "unused", offset: params.offset,
                            nextOffset: params.offset + Int64(data.utf8.count), data: data,
                            jobFinished: params.offset > 0, atEnd: params.offset > 0)))
            case .explain:
                return index == 5 ? .unanswered : .result(.job(Self.job(.succeeded)))
            default: return .disconnect
            }
        }
        defer { server.stop() }
        let (code, text, _) = try run(["run", "--sims", "0", "--", "/usr/bin/true"], state: path)
        XCTAssertEqual(code, 0, text)
        XCTAssertTrue(text.contains("daemon busy or disconnected"), text)
        XCTAssertEqual(text.components(separatedBy: "first\n").count - 1, 1, text)
        XCTAssertEqual(text.components(separatedBy: "last\n").count - 1, 1, text)
        XCTAssertEqual(server.requests.map { $0.method }, [.submit, .wait, .logs, .logs, .logs, .explain, .explain])
        let offsets = server.requests.compactMap { params -> Int64? in
            if case .logs(let logs) = params { XCTAssertEqual(logs.jobID, "J-0001"); return logs.offset }
            return nil
        }
        XCTAssertEqual(offsets, [0, 6, 6], "an unanswered log read must replay its exact offset")
    }

    func testPersistentObservationTimeoutsAndUnboundedWaitRecoveryHaveBoundedDuration() throws {
        for waiting in [false, true] {
            let path = try directory()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let server = try Server(path: path + "/simq.sock") { request, index in
                switch request.params {
                case .submit: return .result(.submit(SubmitResponse(job: Self.job(.queued), deduplicated: false)))
                case .wait:
                    return waiting ? (index == 0 ? .disconnect : .unanswered) : .result(.job(Self.job(.running)))
                default: return .unanswered
                }
            }
            let args = waiting ? ["wait", "J-0001"] : ["run", "--sims", "0", "--", "/usr/bin/true"]
            let (code, text, elapsed) = try run(args, state: path)
            XCTAssertEqual(code, 69, text)
            XCTAssertGreaterThanOrEqual(elapsed, 0.6)
            XCTAssertLessThan(elapsed, 2.5, "receive timeout must fit the remaining recovery window: \(text)")
            XCTAssertGreaterThan(server.requests.count, waiting ? 1 : 3)
            server.stop()
        }
    }

    func testTimedOutMutationsAreNeverReplayed() throws {
        for args in [["submit", "--", "/usr/bin/true"], ["cancel", "J-0001"]] {
            let path = try directory()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let server = try Server(path: path + "/simq.sock") { _, _ in .unanswered }
            let (code, text, _) = try run(args, state: path)
            XCTAssertEqual(code, 69, text)
            XCTAssertEqual(server.requests.count, 1, "an ambiguous mutation must not be replayed")
            server.stop()
        }
    }

    func testAbsoluteWaitDeadlineWinsDuringRecoveryAndPartialReplies() throws {
        for trickling in [false, true] {
            let path = try directory()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let server = try Server(path: path + "/simq.sock") { _, index in
                index == 0 ? .disconnect : (trickling ? .trickle : .unanswered)
            }
            let (code, text, elapsed) = try run(
                ["wait", "J-0001", "--wait-timeout", "0.5s"], state: path, recovery: 2)
            XCTAssertEqual(code, 7, text)
            XCTAssertGreaterThanOrEqual(elapsed, 0.45)
            XCTAssertLessThan(elapsed, 1.5, "original wait deadline wins over recovery and partial bytes: \(text)")
            XCTAssertGreaterThanOrEqual(server.requests.count, 2)
            server.stop()
        }
    }
}
