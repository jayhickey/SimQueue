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

private final class HoldRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var methods: [SimQueueProtocol.Method] = []
    func append(_ method: SimQueueProtocol.Method) { lock.withLock { methods.append(method) } }
    var value: [SimQueueProtocol.Method] { lock.withLock { methods } }
}

final class OutputHoldCLITests: XCTestCase {
    private let id = "01234567-89ab-4cde-8fab-0123456789ab"

    private func invoke(_ arguments: [String], stateDir: String) throws -> (code: Int32, output: String) {
        let products: URL
        #if os(macOS)
            products =
                Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }?.bundleURL.deletingLastPathComponent()
                ?? Bundle.main.bundleURL
        #else
            products = Bundle.main.bundleURL
        #endif
        let executable = products.appendingPathComponent("simq")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("simq not built") }
        let output = stateDir + "/cli-\(UUID().uuidString).log"
        FileManager.default.createFile(atPath: output, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
        defer { try? handle.close(); try? FileManager.default.removeItem(atPath: output) }
        let process = Process()
        process.executableURL = executable
        var args = arguments
        args.insert(contentsOf: ["--state-dir", stateDir], at: args.firstIndex(of: "--") ?? args.endIndex)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SIMQ_JOB_ID")
        environment["SIMQ_NO_AUTOSTART"] = "1"
        environment["SIMQ_RECONNECT_SECONDS"] = "0"
        environment["SIMQ_REQUEST_TIMEOUT_SECONDS"] = "2"
        process.environment = environment
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            throw TestFailure("CLI exceeded deadline")
        }
        return (process.terminationStatus, try String(contentsOfFile: output, encoding: .utf8))
    }

    func testOutputHoldCLIAndBothProtectedSubmissionCommands() throws {
        let daemon = try TestDaemon()
        defer { daemon.destroy() }
        let state = daemon.paths.stateDir
        let create = try invoke(
            ["output-hold", "create", "--id", id.uppercased(), "--label", "evidence", "--json"], stateDir: state)
        XCTAssertEqual(create.code, 0, create.output)
        let hold = try JSONDecoder().decode(OutputHoldResult.self, from: Data(create.output.utf8))
        XCTAssertEqual(hold.hold.id, id)
        let submitted = try invoke(["submit", "--sims", "0", "--output-hold", id, "--wait", "--json"], stateDir: state)
        XCTAssertEqual(submitted.code, 0, submitted.output)
        let run = try invoke(["run", "--sims", "0", "--output-hold", id, "--", "/usr/bin/true"], stateDir: state)
        XCTAssertEqual(run.code, 0, run.output)
        let show = try invoke(["output-hold", "show", id, "--json", "--limit", "1"], stateDir: state)
        XCTAssertEqual(show.code, 0, show.output)
        let shown = try JSONDecoder().decode(OutputHoldResult.self, from: Data(show.output.utf8))
        XCTAssertEqual(shown.jobs.count, 1)
        XCTAssertNotNil(shown.nextJobID)
        let list = try invoke(["output-hold", "list", "--json"], stateDir: state)
        XCTAssertEqual(list.code, 0, list.output)
        XCTAssertEqual(try JSONDecoder().decode(OutputHoldsResult.self, from: Data(list.output.utf8)).holds.count, 1)
        let release = try invoke(["output-hold", "release", id, "--json"], stateDir: state)
        XCTAssertEqual(release.code, 0, release.output)
        let count = try daemon.side.allJobs().count
        let refused = try invoke(["submit", "--sims", "0", "--output-hold", id], stateDir: state)
        XCTAssertNotEqual(refused.code, 0)
        XCTAssertEqual(try daemon.side.allJobs().count, count)
        let invalid = try invoke(["run", "--output-hold", "invalid", "--", "true"], stateDir: state)
        XCTAssertEqual(invalid.code, SimQExitCode.usage.rawValue, invalid.output)
    }

    func testUnsupportedProtectionNeverFallsBackOrExecutesOrdinarySubmission() throws {
        for command in ["submit", "run"] {
            let state = testScratchRoot() + "/sqoh-" + UUID().uuidString.prefix(8)
            try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: state) }
            let listener = try UnixListener(path: state + "/simq.sock")
            let methods = HoldRequestLog()
            let done = DispatchGroup()
            defer { listener.close(); _ = done.wait(timeout: .now() + 3) }
            done.enter()
            Thread.detachNewThread {
                defer { done.leave() }
                while let connection = try? listener.accept() {
                    defer { connection.close() }
                    guard
                        let line = try? connection.readLine(
                            maxBytes: LineCodec.maxLineBytes, deadline: Date().timeIntervalSince1970 + 3),
                        let request = try? LineCodec.decode(Request.self, from: line)
                    else { return }
                    methods.append(request.params.method)
                    _ = try? connection.write(
                        LineCodec.encode(
                            Response(
                                id: request.id,
                                body: .error(ProtocolError(.invalidArgument, "unknown method submit_held (old daemon)"))
                            )))
                }
            }
            let result = try invoke(
                [command, "--sims", "0", "--output-hold", id, "--", "/usr/bin/true"], stateDir: state)
            listener.close()
            XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
            XCTAssertNotEqual(result.code, 0, result.output)
            XCTAssertEqual(methods.value, [.submitHeld], "no ordinary submit, wait or command execution")
        }
    }
}
