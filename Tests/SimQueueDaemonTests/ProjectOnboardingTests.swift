// SPDX-License-Identifier: MIT

import Foundation
import SimQueueDaemon
import XCTest

final class ProjectOnboardingTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = "/tmp/sqp-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: root) }

    private func makeRepo(_ name: String, containers: [String: [String]]) throws -> String {
        let repo = root + "/" + name
        for (container, schemes) in containers {
            let directory = repo + "/" + container + "/xcshareddata/xcschemes"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for scheme in schemes {
                FileManager.default.createFile(atPath: directory + "/\(scheme).xcscheme", contents: Data())
            }
        }
        return repo
    }

    func testDetectsTheWorkspaceAndItsOnlySharedScheme() throws {
        let repo = try makeRepo(
            "App", containers: ["App.xcodeproj": ["App", "AppUITests"], "App.xcworkspace": ["App"]])
        let resolved = try ProjectOnboarding.resolve(repo: repo, scheme: nil, container: nil)
        XCTAssertEqual(resolved.container, "App.xcworkspace", "a workspace wins over its project")
        XCTAssertEqual(resolved.scheme, "App")
        XCTAssertThrowsError(try ProjectOnboarding.resolve(repo: repo, scheme: nil, container: "App.xcodeproj")) {
            XCTAssertEqual(
                ($0 as? ProjectOnboarding.Failure)?.description,
                "several shared schemes: App, AppUITests; pass --scheme")
        }
        XCTAssertEqual(
            try ProjectOnboarding.resolve(repo: repo, scheme: "AppUITests", container: "App.xcodeproj").scheme,
            "AppUITests")
        XCTAssertThrowsError(try ProjectOnboarding.resolve(repo: root + "/missing", scheme: "X", container: nil))
    }

    func testAddWritesTheEntryKeepsOtherKeysAndRefusesDuplicatesAndBadEntries() throws {
        let config = root + "/state/config.json"
        try FileManager.default.createDirectory(atPath: root + "/state", withIntermediateDirectories: true)
        try #"{"max_concurrent_exclusive": 2, "unknown_future_key": true}"#.write(
            toFile: config, atomically: true, encoding: .utf8)
        let settings = DaemonConfig.ProjectSettings(repo: "/src/app", scheme: "App", container: "App.xcworkspace")
        try ProjectOnboarding.add(name: "myapp", settings: settings, configPath: config, replace: false)

        let loaded = try DaemonConfig.load(path: config)
        XCTAssertEqual(loaded.projects["myapp"], settings)
        XCTAssertEqual(loaded.scheduler.maxConcurrentExclusive, 2, "other keys are kept")
        let text = try String(contentsOfFile: config, encoding: .utf8)
        XCTAssertTrue(text.contains("unknown_future_key"), text)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: config)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.uint32Value & 0o777, 0o600)

        XCTAssertThrowsError(
            try ProjectOnboarding.add(name: "myapp", settings: settings, configPath: config, replace: false))
        var changed = settings
        changed.testPlan = "Full"
        try ProjectOnboarding.add(name: "myapp", settings: changed, configPath: config, replace: true)
        XCTAssertEqual(try DaemonConfig.load(path: config).projects["myapp"]?.testPlan, "Full")

        let relative = DaemonConfig.ProjectSettings(repo: "src/app", scheme: "App")
        XCTAssertThrowsError(
            try ProjectOnboarding.add(name: "other", settings: relative, configPath: config, replace: false))
        XCTAssertNil(try DaemonConfig.load(path: config).projects["other"], "a rejected entry is never written")
    }

    func testSeveralContainersWithASchemeNeverSilentlyDropTheContainer() throws {
        let repo = try makeRepo("Two", containers: ["A.xcodeproj": ["Shared", "OnlyA"], "B.xcodeproj": ["Shared"]])
        XCTAssertEqual(
            try ProjectOnboarding.resolve(repo: repo, scheme: "OnlyA", container: nil).container, "A.xcodeproj",
            "the one container that shares the scheme")
        for scheme in ["Shared", "Nowhere"] {
            XCTAssertThrowsError(try ProjectOnboarding.resolve(repo: repo, scheme: scheme, container: nil)) {
                XCTAssertEqual(
                    ($0 as? ProjectOnboarding.Failure)?.description,
                    "several containers in \(repo): A.xcodeproj, B.xcodeproj; pass --container")
            }
        }
    }

    func testAWorkspaceOffersItsReferencedProjectsSchemes() throws {
        let repo = try makeRepo("WS", containers: ["App.xcworkspace": [], "Sub/App.xcodeproj": ["AppScheme"]])
        try #"<Workspace version = "1.0"><FileRef location = "group:Sub/App.xcodeproj"></FileRef></Workspace>"#
            .write(toFile: repo + "/App.xcworkspace/contents.xcworkspacedata", atomically: true, encoding: .utf8)
        let resolved = try ProjectOnboarding.resolve(repo: repo, scheme: nil, container: nil)
        XCTAssertEqual(resolved.container, "App.xcworkspace")
        XCTAssertEqual(resolved.scheme, "AppScheme")
    }

    func testAddKeepsASymlinkedConfigAndWritesStableUnescapedJSON() throws {
        let real = root + "/dotfiles/config.json"
        let link = root + "/state/config.json"
        try FileManager.default.createDirectory(atPath: root + "/dotfiles", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/state", withIntermediateDirectories: true)
        try "{}".write(toFile: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let settings = DaemonConfig.ProjectSettings(repo: "/src/app", scheme: "App")
        try ProjectOnboarding.add(name: "myapp", settings: settings, configPath: link, replace: false)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), real, "still a symlink")
        let first = try String(contentsOfFile: real, encoding: .utf8)
        XCTAssertTrue(first.contains(#""/src/app""#), "slashes unescaped: \(first)")
        try ProjectOnboarding.add(name: "myapp", settings: settings, configPath: link, replace: true)
        XCTAssertEqual(try String(contentsOfFile: real, encoding: .utf8), first, "re-adding gives the same bytes")
    }

    func testConfigValidatesProjectEntries() {
        XCTAssertTrue(DaemonConfig.ProjectSettings.isValidName("my-app2"))
        for bad in ["MyApp", "1app", "my_app", "", String(repeating: "a", count: 33)] {
            XCTAssertFalse(DaemonConfig.ProjectSettings.isValidName(bad), bad)
        }
        for json in [
            #"{"projects": {"Bad": {"repo": "/r", "scheme": "S"}}}"#,
            #"{"projects": {"ok": {"repo": "/r", "scheme": ""}}}"#,
            #"{"projects": {"ok": {"repo": "/r", "scheme": "S", "container": "../x.xcodeproj"}}}"#,
            #"{"projects": {"ok": {"repo": "/r", "scheme": "S", "container": "x.txt"}}}"#,
        ] {
            XCTAssertThrowsError(try DaemonConfig.parse(Data(json.utf8)), json)
        }
    }
}
