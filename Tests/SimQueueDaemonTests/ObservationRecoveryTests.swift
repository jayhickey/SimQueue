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
        enum Answer {
            case result(ResultPayload), unanswered, disconnect, trickle
            /// Answers after a pause with nothing sent (a wait on a job still in the queue).
            case later(Double, ResultPayload)
            /// The daemon goes away: stops listening (removing the socket), then drops this
            /// connection mid-request, like a drained simqd exiting for a restart.
            case exit
        }
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
                    case .later(let seconds, let payload):
                        Thread.sleep(forTimeInterval: seconds)
                        try? connection.write(LineCodec.encode(Response(id: request.id, body: .result(payload))))
                    case .exit:
                        listener.close()
                        return
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

    /// What a test's background thread hands back: the restarted stand-in daemon.
    private final class Restart: @unchecked Sendable {
        let lock = NSLock()
        var server: Server?
        var logsServed = false
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
        env["SIMQ_RECONNECT_SECONDS"] = String(recovery)
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

    /// The Quotify #147 failure: a drain and restart while `simq run` waits for its job to
    /// start. The new daemon (new socket, new process) is back quickly, but the requeued job
    /// stays queued for longer than the reconnect window. The client must reattach to the
    /// same job and keep waiting with no recovery deadline, not exit 69.
    func testRunWaitsOnTheSameJobAcrossADaemonRestartLongerThanTheReconnectWindow() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let socket = path + "/simq.sock"
        let old = try Server(path: socket) { request, _ in
            switch request.params {
            case .submit: return .result(.submit(SubmitResponse(job: Self.job(.queued), deduplicated: false)))
            default: return .exit
            }
        }
        let restart = Restart()
        DispatchQueue.global().async {
            // Down for longer than the first backoff step, then a fresh daemon.
            _ = old.done.wait(timeout: .now() + 5)
            Thread.sleep(forTimeInterval: 0.3)
            let server = try? Server(path: socket) { request, _ in
                switch request.params {
                case .explain:
                    let done = restart.lock.withLock { restart.logsServed }
                    return .result(.job(Self.job(done ? .succeeded : .queued)))
                // Silent for twice the reconnect window while the job waits in the queue.
                case .wait: return .later(2, .job(Self.job(.running)))
                case .logs(let params):
                    restart.lock.withLock { restart.logsServed = true }
                    return .result(
                        .logs(
                            LogsResult(
                                jobID: params.jobID, path: "unused", offset: params.offset,
                                nextOffset: params.offset + 5, data: "done\n", jobFinished: true, atEnd: true)))
                default: return .disconnect
                }
            }
            restart.lock.withLock { restart.server = server }
        }
        let (code, text, _) = try run(["run", "--sims", "0", "--", "/usr/bin/true"], state: path, recovery: 1)
        let server = try XCTUnwrap(restart.lock.withLock { restart.server }, text)
        defer { server.stop() }
        XCTAssertEqual(code, 0, text)
        XCTAssertTrue(text.contains("reconnected; still waiting on J-0001"), text)
        XCTAssertEqual(text.components(separatedBy: "done\n").count - 1, 1, text)
        XCTAssertEqual(old.requests.map { $0.method }, [.submit, .wait], "one submit, before the restart")
        XCTAssertEqual(server.requests.map { $0.method }, [.explain, .wait, .logs, .explain], text)
        for params in server.requests {
            switch params {
            case .explain(let ref): XCTAssertEqual(ref.jobID, "J-0001")
            case .wait(let wait): XCTAssertEqual(wait.jobID, "J-0001")
            case .logs(let logs): XCTAssertEqual(logs.jobID, "J-0001")
            default: XCTFail("unexpected \(params)")
            }
        }
    }

    /// A submit while the daemon is away (autostart off) waits for it to come back instead of
    /// exiting 69. Nothing was sent while the connect failed, so the one submit is safe.
    func testSubmitWaitsForARestartingDaemon() throws {
        let path = try directory()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let restart = Restart()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
            let started = try? Server(path: path + "/simq.sock") { _, _ in
                .result(.submit(SubmitResponse(job: Self.job(.queued), deduplicated: false)))
            }
            restart.lock.withLock { restart.server = started }
        }
        let (code, text, elapsed) = try run(["submit", "--", "/usr/bin/true"], state: path, recovery: 5)
        let started = try XCTUnwrap(restart.lock.withLock { restart.server }, text)
        defer { started.stop() }
        XCTAssertEqual(code, 0, text)
        XCTAssertGreaterThanOrEqual(elapsed, 0.7)
        XCTAssertTrue(text.contains("queued J-0001"), text)
        XCTAssertEqual(started.requests.map { $0.method }, [.submit])
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
