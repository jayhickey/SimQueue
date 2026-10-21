// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueHost
import SimQueueIPC
import SimQueueProtocol
import XCTest

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class SocketDisconnectTests: XCTestCase {
    private func daemonBinary() throws -> String {
        var products = Bundle.main.bundleURL
        #if os(macOS)
            if let bundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
                products = bundle.bundleURL.deletingLastPathComponent()
            }
        #endif
        let path = products.appendingPathComponent("simqd").path
        return try XCTUnwrap(
            FileManager.default.isExecutableFile(atPath: path) ? path : nil,
            "simqd must be built beside the tests: \(path)")
    }

    #if canImport(Darwin)
        func testPeerClosedBeforeAcceptCannotBecomeAnUnprotectedConnection() throws {
            let root = testScratchRoot() + "/closed-peer-" + UUID().uuidString.prefix(8)
            defer { try? FileManager.default.removeItem(atPath: root) }
            let listener = try UnixListener(path: root + "/s")
            defer { listener.close() }
            let client = try UnixConnection.connect(path: listener.path)
            try client.write(Data("already closed\n".utf8))
            client.close()
            // No accept thread runs until after peer closure: this deterministically
            // exercises Darwin's EINVAL while installing SO_NOSIGPIPE. Returning
            // that connection and writing its buffered response used to kill simqd.
            XCTAssertThrowsError(try listener.accept()) { error in
                XCTAssertEqual(error as? SocketError, .system(call: "setsockopt(SO_NOSIGPIPE)", errno: EINVAL))
            }
            // A rejected disconnected peer must not close the listening socket.
            let next = try UnixConnection.connect(path: listener.path)
            defer { next.close() }
            let accepted = try listener.accept()
            defer { accepted.close() }
            try accepted.write(Data("still listening\n".utf8))
            XCTAssertEqual(try next.readLine(maxBytes: 1024), Data("still listening".utf8))
        }
    #endif

    func testEarlyDisconnectsCannotKillDaemonWithDefaultSIGPIPE() throws {
        let binary = try daemonBinary()
        // Exercise both an ordinary foreground log and the rotating-log pipe. The
        // child uses default SIGPIPE even if the test runner ignores the signal.
        for rotating in [false, true] {
            let root = testScratchRoot() + "/disconnect-" + UUID().uuidString.prefix(8)
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: root) }
            let state = root + "/s"
            let socket = state + "/simq.sock"
            var argv = [
                binary, "run", "--foreground", "--state-dir", state, "--backend", "fake", "--probe", "fake",
                "--executor", "fake",
            ]
            if rotating { argv += ["--log-file", root + "/rotating.log"] }
            let pid = try ProcessSpawner.spawn(
                executable: binary, argv: argv, environment: ["PATH": "/usr/bin:/bin", "SIMQ_NO_AUTOSTART": "1"],
                cwd: nil, outputPath: root + "/bootstrap.log")
            defer {
                // Only this still-unreaped child can have this PID. Never signal
                // a discovered/reused process or a simulator process group.
                do {
                    if try ProcessSpawner.peekExit(pid) == nil {
                        kill(pid, SIGTERM)
                        let deadline = Date().addingTimeInterval(5)
                        while try ProcessSpawner.peekExit(pid) == nil, Date() < deadline {
                            Thread.sleep(forTimeInterval: 0.01)
                        }
                        if try ProcessSpawner.peekExit(pid) == nil {
                            kill(pid, SIGKILL)
                            let killDeadline = Date().addingTimeInterval(5)
                            while try ProcessSpawner.peekExit(pid) == nil, Date() < killDeadline {
                                Thread.sleep(forTimeInterval: 0.01)
                            }
                        }
                    }
                    XCTAssertNotNil(try ProcessSpawner.reap(pid), "diagnostic daemon must exit and be reaped")
                } catch {
                    // An unexpected ownership/wait error never permits a guessed
                    // fallback signal. Preserve it as a test-cleanup failure.
                    XCTFail("cannot verify/reap diagnostic daemon: \(error)")
                }
            }
            let client = SimQueueClient(socketPath: socket, timeoutSeconds: 1)
            let deadline = Date().addingTimeInterval(30)
            while (try? client.send(Request(params: .status))) == nil {
                guard try ProcessSpawner.peekExit(pid) == nil, Date() < deadline else {
                    let log = (try? String(contentsOfFile: root + "/bootstrap.log", encoding: .utf8)) ?? ""
                    return XCTFail("fake daemon did not become ready: \(log)")
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            let submitted = try XCTUnwrap(
                client.send(
                    Request(
                        params: .submit(
                            SubmitParams(
                                project: "disconnect", submitter: "test", minSims: 0, maxSims: 0,
                                payloadJSON: #"{"fake":{"run_seconds":60}}"#)))))
            guard case .result(.submit(let response)) = submitted.body else {
                return XCTFail("expected submitted fake job")
            }
            // Close with an unread response, including streamed wait responses.
            // When close wins the race with accept, Darwin can reject SO_NOSIGPIPE;
            // the server must discard that connection instead of sending on it.
            for index in 0..<256 {
                let connection = try UnixConnection.connect(path: socket)
                let params: RequestParams =
                    index.isMultiple(of: 3)
                    ? .wait(WaitParams(jobID: response.job.id, stream: true))
                    : (index.isMultiple(of: 2) ? .status : .jobs(JobsParams(limit: 256)))
                try connection.write(try LineCodec.encode(Request(params: params)))
                connection.close()
            }
            Thread.sleep(forTimeInterval: 0.05)
            XCTAssertNil(try ProcessSpawner.peekExit(pid), "closed clients killed the daemon (rotating=\(rotating))")
            let answer = try XCTUnwrap(client.send(Request(params: .status)))
            guard case .result(.status(let status)) = answer.body else { return XCTFail("expected status") }
            XCTAssertEqual(status.daemon.pid, pid)
            XCTAssertEqual(status.daemon.backend, "fake")
            _ = try client.send(Request(params: .cancel(CancelParams(jobID: response.job.id))))
            let waited = try XCTUnwrap(client.send(Request(params: .wait(WaitParams(jobID: response.job.id)))))
            guard case .result(.job(let terminal)) = waited.body else { return XCTFail("expected canceled job") }
            XCTAssertEqual(terminal.state, .canceled)
            XCTAssertNil(try ProcessSpawner.peekExit(pid), "daemon must still handle work after closed peers")
        }
    }
}
