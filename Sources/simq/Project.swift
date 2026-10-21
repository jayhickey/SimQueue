// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import SimQueueDaemon
import SimQueueProtocol

struct Project: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Onboard projects (writes config.json; no daemon needed).", subcommands: [ProjectAdd.self])
}

struct ProjectAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a project entry to config.json.",
        discussion: """
            Writes projects.<name> (repo, scheme, container, test_plan) into the state
            directory's config.json and keeps every other key. Without --container or
            --scheme, they're detected by listing files: the repo's top-level .xcworkspace
            (preferred) or .xcodeproj, and its shared schemes. Nothing is built and xcodebuild
            isn't run. The name labels jobs and project metadata; it does not select a
            simulator environment. Use lowercase letters, digits and -. Restart simqd to load the change.
            Example: simq project add myapp --repo ~/Developer/MyApp --scheme MyApp
            """
    )

    @Option(help: "State directory. Default: $SIMQ_STATE_DIR or the platform default.") var stateDir: String?
    @Argument(help: "Project name (lowercase letters, digits and -).") var name: String
    @Option(help: "Repository path.") var repo: String
    @Option(help: "Scheme. Default: detected (the only shared scheme).") var scheme: String?
    @Option(help: ".xcworkspace or .xcodeproj inside the repo. Default: detected.") var container: String?
    @Option(help: "Test plan name.") var testPlan: String?
    @Flag(help: "Replace an existing entry with the same name.") var replace = false
    @Flag(help: "Print machine-readable JSON.") var json = false

    func validate() throws {
        guard DaemonConfig.ProjectSettings.isValidName(name) else {
            throw ValidationError(
                DaemonConfig.ProjectSettings.isReserved(name)
                    ? "project name \(name) is reserved (template, golden, pool and names starting with one of those plus - are taken by sim-name shapes)"
                    : "project name must be lowercase letters, digits and -, starting with a letter (max 32)")
        }
    }

    func run() throws {
        let paths = SimQueuePaths.resolve(explicit: stateDir)
        let repoPath = Submit.absolute((repo as NSString).expandingTildeInPath)
        do {
            let resolved = try ProjectOnboarding.resolve(repo: repoPath, scheme: scheme, container: container)
            let settings = DaemonConfig.ProjectSettings(
                repo: repoPath, scheme: resolved.scheme, container: resolved.container, testPlan: testPlan)
            try ProjectOnboarding.add(name: name, settings: settings, configPath: paths.configPath, replace: replace)
            if json {
                try printJSON(
                    Added(name: name, repo: repoPath, scheme: resolved.scheme, container: resolved.container))
            } else {
                print(
                    "added \(name): \(repoPath), scheme \(resolved.scheme)"
                        + (resolved.container.map { ", \($0)" } ?? "") + " -> \(paths.configPath)")
            }
        } catch let problem as ProjectOnboarding.Failure {
            printError(problem.description)
            throw failure(.usage)
        } catch let error as DaemonConfig.LoadError {
            printError(error.description)
            throw failure(.usage)
        }
    }

    /// `--json` output; `container` is `null` when xcodebuild's own lookup is used.
    struct Added: Encodable {
        var name: String
        var repo: String
        var scheme: String
        var container: String?
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(name, forKey: .name)
            try values.encode(repo, forKey: .repo)
            try values.encode(scheme, forKey: .scheme)
            try values.encode(container, forKey: .container)  // explicit null, not omitted
        }
        enum CodingKeys: String, CodingKey { case name, repo, scheme, container }
    }
}
