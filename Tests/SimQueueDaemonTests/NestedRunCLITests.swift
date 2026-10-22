// SPDX-License-Identifier: MIT

import Foundation
import SimQueueProtocol
import XCTest

/// `simq run` inside a job is refused before any connection. The socket is missing and
/// autostart is off, so a run that got past the check would exit 69 instead.
final class NestedRunCLITests: XCTestCase {
    private func invoke(_ arguments: [String], jobID: String?) throws -> (code: Int32, output: String) {
        let products: URL
        #if os(macOS)
            products =
                Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }?
                .bundleURL.deletingLastPathComponent() ?? Bundle.main.bundleURL
        #else
            products = Bundle.main.bundleURL
        #endif
        let executable = products.appendingPathComponent("simq")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("simq not built at \(executable.path)")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SIMQ_NO_AUTOSTART"] = "1"
        environment["SIMQ_RECONNECT_SECONDS"] = "0"
        environment["SIMQ_STATE_DIR"] = testScratchRoot() + "/sqnr-" + UUID().uuidString.prefix(8)
        environment["SIMQ_JOB_ID"] = jobID
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testRunInsideAJobIsRefusedBeforeConnecting() throws {
        let nested = try invoke(["run", "--", "/usr/bin/true"], jobID: "j-parent")
        XCTAssertEqual(nested.code, SimQExitCode.nestedRun.rawValue, nested.output)
        let message = "simq: nested simq run inside job j-parent is not supported"
        XCTAssertTrue(nested.output.contains(message), nested.output)
        XCTAssertFalse(nested.output.contains("queued"), nested.output)
    }

    func testRunOutsideAJobStillReachesTheDaemon() throws {
        for jobID in [nil, ""] {
            let result = try invoke(["run", "--", "/usr/bin/true"], jobID: jobID)
            XCTAssertEqual(result.code, SimQExitCode.daemonUnavailable.rawValue, result.output)
        }
    }
}
