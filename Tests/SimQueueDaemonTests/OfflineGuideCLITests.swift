// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import XCTest

/// Offline discovery exercises the real CLI with autostart enabled and an executable
/// daemon trap. Installation fixtures copy that CLI, so symlink/path resolution is real.
final class OfflineGuideCLITests: XCTestCase {
    private var root: URL!
    private var state: URL { root.appendingPathComponent("must-not-create-state") }
    private var marker: URL { root.appendingPathComponent("daemon-was-started") }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: testScratchRoot()).appendingPathComponent(
            "sqog-" + UUID().uuidString.prefix(8) + "'")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
        let trap = root.appendingPathComponent("daemon-trap")
        try "#!/bin/sh\nprintf started > \"$SIMQ_OFFLINE_TRAP_MARKER\"\nexit 99\n".write(
            to: trap, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trap.path)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func binary() throws -> URL {
        let products: URL
        #if os(macOS)
            products =
                Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }?
                .bundleURL.deletingLastPathComponent() ?? Bundle.main.bundleURL
        #else
            products = Bundle.main.bundleURL
        #endif
        let executable = products.appendingPathComponent("simq")
        return try XCTUnwrap(
            FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil,
            "simq must be built for offline CLI verification at \(executable.path)")
    }

    private func invoke(_ args: [String], executable: URL? = nil, cwd: URL? = nil) throws -> (
        code: Int32, output: String
    ) {
        let process = Process()
        process.executableURL = try executable ?? binary()
        process.arguments = args
        process.currentDirectoryURL = cwd ?? root
        var environment = ProcessInfo.processInfo.environment
        // A disabled autostart would make a broken offline command look harmless.
        environment["SIMQ_NO_AUTOSTART"] = nil
        environment["SIMQ_STATE_DIR"] = state.path
        environment["SIMQ_HOST_LOCK"] = root.appendingPathComponent("must-not-create-host-lock").path
        environment["SIMQ_SIMQD_PATH"] = root.appendingPathComponent("daemon-trap").path
        environment["SIMQ_OFFLINE_TRAP_MARKER"] = marker.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path), "offline discovery created state")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "offline discovery launched a daemon")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-create-host-lock").path))
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func put(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func installBinary(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: binary(), to: url)
    }

    private func putGuides(at directory: URL) throws {
        for relative in ["README.md", "docs/INSTALL.md", "docs/PROTOCOL.md"] {
            try put("offline fixture\n", at: directory.appendingPathComponent(relative))
        }
    }

    func testAgentGuideAndRootHelpAreOfflineAndVersionMatched() throws {
        let guide = try invoke(["agent-guide"])
        XCTAssertEqual(guide.code, 0, guide.output)
        XCTAssertTrue(guide.output.contains("SimQueue \(SimQueueVersion.current) agent guide"), guide.output)
        for required in [
            "--sims 0", "--sims 1", "SIMQ_UDID", "SIMQ_SIM_UDIDS", "SIMQ_DERIVED_DATA", "SIMQ_RESULT_BUNDLE",
            "--memory-hint-mib", "--env-from", "--result-file", "--exit-code", "--retryable", "--fresh-sim",
        ] {
            XCTAssertTrue(guide.output.contains(required), "guide omitted \(required)")
        }
        let help = try invoke(["--help"])
        XCTAssertEqual(help.code, 0, help.output)
        let words = help.output.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(words.contains("simq agent-guide"), help.output)
        XCTAssertTrue(words.contains("simq docs"), help.output)
        XCTAssertTrue(words.contains("simq run --sims 0 -- swift build -j 4"), help.output)
        XCTAssertTrue(words.contains("simq run --sims 1 -- ./run-tests.sh"), help.output)
    }

    func testDocsResolveTheCellarExecutableThroughASymlinkAndIgnoreWorkingDirectory() throws {
        let prefix = root.appendingPathComponent("Cellar/simqueue/0.1.0")
        let executable = prefix.appendingPathComponent("bin/simq")
        let documents = prefix.appendingPathComponent("share/doc/simqueue")
        try installBinary(at: executable)
        try putGuides(at: documents)
        let linked = root.appendingPathComponent("prefix/bin/simq")
        try FileManager.default.createDirectory(
            at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: executable)
        let unrelated = root.appendingPathComponent("unrelated")
        try putGuides(at: unrelated)
        let plain = try invoke(["docs"], executable: linked, cwd: unrelated)
        XCTAssertEqual(plain.code, 0, plain.output)
        XCTAssertEqual(plain.output.trimmingCharacters(in: .whitespacesAndNewlines), documents.path)
        let json = try invoke(["docs", "--json"], executable: linked, cwd: unrelated)
        XCTAssertEqual(json.code, 0, json.output)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any])
        XCTAssertEqual(record["path"] as? String, documents.path)
        XCTAssertEqual(record["layout"] as? String, "homebrew")
        XCTAssertEqual(record["version"] as? String, SimQueueVersion.current)
        XCTAssertEqual(record["schema_version"] as? Int, 1)
    }

    func testDocsLocateAnExtractedArchiveWithoutHomebrew() throws {
        let prefix = root.appendingPathComponent("archive")
        let executable = prefix.appendingPathComponent("bin/simq")
        try installBinary(at: executable)
        try putGuides(at: prefix)
        for file in ["LICENSE", "NOTICE"] { try put("fixture\n", at: prefix.appendingPathComponent(file)) }
        let result = try invoke(["docs", "--json"], executable: executable)
        XCTAssertEqual(result.code, 0, result.output)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        XCTAssertEqual(record["path"] as? String, prefix.path)
        XCTAssertEqual(record["layout"] as? String, "archive")
    }

    func testDocsResolveTheAppBundledCLIThroughTheCaskLink() throws {
        let contents = root.appendingPathComponent("Applications/SimQueue.app/Contents")
        let executable = contents.appendingPathComponent("Helpers/simq")
        let documents = contents.appendingPathComponent("Resources/doc/simqueue")
        try installBinary(at: executable)
        try putGuides(at: documents)
        let linked = root.appendingPathComponent("prefix/bin/simq")
        try FileManager.default.createDirectory(
            at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: executable)
        let result = try invoke(["docs", "--json"], executable: linked)
        XCTAssertEqual(result.code, 0, result.output)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        XCTAssertEqual(record["path"] as? String, documents.path)
        XCTAssertEqual(record["layout"] as? String, "app")
    }

    func testSourceBuildDocsRequireARecognizableCheckoutAncestor() throws {
        let checkout = root.appendingPathComponent("checkout")
        let executable = checkout.appendingPathComponent(".build/arm64-apple-macosx/debug/simq")
        try installBinary(at: executable)
        try putGuides(at: checkout)
        try put("// fixture\n", at: checkout.appendingPathComponent("Package.swift"))
        try put("// fixture\n", at: checkout.appendingPathComponent("Sources/simq/SimQ.swift"))
        let result = try invoke(["docs", "--json"], executable: executable)
        XCTAssertEqual(result.code, 0, result.output)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        XCTAssertEqual(record["path"] as? String, checkout.path)
        XCTAssertEqual(record["layout"] as? String, "source")
    }

    func testMissingOrIncompleteDocsFailClearlyWithoutCreatingState() throws {
        let prefix = root.appendingPathComponent("incomplete")
        let executable = prefix.appendingPathComponent("bin/simq")
        try installBinary(at: executable)
        try put("partial\n", at: prefix.appendingPathComponent("share/doc/simqueue/README.md"))
        // A convenient cwd is not evidence that those docs belong to this executable.
        let unrelated = root.appendingPathComponent("ambient-docs")
        try putGuides(at: unrelated)
        let result = try invoke(["docs", "--json"], executable: executable, cwd: unrelated)
        XCTAssertEqual(result.code, 1, result.output)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        XCTAssertEqual(record["error"] as? String, "documentation_not_found")
        XCTAssertNil(record["path"])
        XCTAssertTrue((record["message"] as? String)?.contains("simq agent-guide") == true, result.output)
    }

    func testOfflineCommandsDoNotAcceptConnectionOptions() throws {
        for command in ["agent-guide", "docs"] {
            let rejected = try invoke([command, "--state-dir", state.path])
            XCTAssertEqual(rejected.code, 64, rejected.output)
            let help = try invoke([command, "--help"])
            XCTAssertEqual(help.code, 0, help.output)
            XCTAssertFalse(help.output.contains("--state-dir"), help.output)
        }
    }
}
