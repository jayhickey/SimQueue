// SPDX-License-Identifier: MIT

import Foundation
import SimQueueProtocol
import XCTest

/// Parsing checks use a missing socket with autostart disabled: no job or daemon runs.
final class MemoryHintCLITests: XCTestCase {
    private func invoke(_ arguments: [String]) throws -> (code: Int32, output: String) {
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
        environment["SIMQ_STATE_DIR"] = testScratchRoot() + "/sqmh-" + UUID().uuidString.prefix(8)
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testMemoryHintIsOptionalAndOldSpellingIsRejected() throws {
        for command in ["run", "submit"] {
            for options in [[], ["--memory-hint-mib", "1024"]] {
                let result = try invoke([command] + options + ["--", "/usr/bin/true"])
                XCTAssertEqual(result.code, SimQExitCode.daemonUnavailable.rawValue, result.output)
            }
            let removed = try invoke([command, "--memory-mib", "1024", "--", "/usr/bin/true"])
            XCTAssertEqual(removed.code, SimQExitCode.usage.rawValue, removed.output)
            XCTAssertTrue(removed.output.contains("Unknown option '--memory-mib'"), removed.output)
        }
    }

    func testHelpAndValidationDescribeTheHint() throws {
        for command in ["run", "submit"] {
            let help = try invoke([command, "--help"])
            XCTAssertEqual(help.code, 0, help.output)
            let words = help.output.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            XCTAssertTrue(words.contains("--memory-hint-mib"), help.output)
            XCTAssertTrue(words.contains("not a memory limit or RAM reservation"), help.output)
            XCTAssertTrue(words.contains("512 MiB minimum accounting"), help.output)
            XCTAssertFalse(help.output.contains("--memory-mib"), help.output)
            let overflow = try invoke([
                command, "--memory-hint-mib", "18446744073709551615", "--", "/usr/bin/true",
            ])
            XCTAssertEqual(overflow.code, SimQExitCode.usage.rawValue, overflow.output)
        }
    }
}
