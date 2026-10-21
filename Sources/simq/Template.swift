// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import SimQueueProtocol

struct Template: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build, list and remove host template candidates (simq-template-<project>-<profile>-<n>).",
        subcommands: [TemplateBuild.self, TemplateList.self, TemplateRemove.self])
}

/// `simq golden ...`: the template commands' name before the rename. Hidden from help;
/// runs the same subcommands.
struct LegacyGolden: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "golden",
        abstract: "Old name for simq template.",
        shouldDisplay: false,
        subcommands: [TemplateBuild.self, TemplateList.self, TemplateRemove.self])
}

func printTemplates(_ result: TemplateResult, json: Bool) throws {
    if json { return try printJSON(result) }
    if result.templates.isEmpty { print("no templates") }
    for template in result.templates {
        let slimming = template.slimmed.map { $0 ? "  slimmed" : "  stock" } ?? ""
        let stale = template.stale.map { $0 ? "  STALE" : "" } ?? "  (staleness unknown)"
        print(
            "\(template.name)  \(template.udid)  \(template.status)  \(template.deviceType) \(template.runtime)"
                + "  \(template.xcodeVersion)\(slimming)\(stale)")
    }
}

struct TemplateBuild: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Create a fresh simulator template; optionally slim it with --slim.",
        discussion: """
            Build a host template candidate using the flags or host-wide template defaults.
            The positional label identifies a candidate; it does not route project jobs.
            Building does not activate it. Explicitly set simctl.template to its UDID and
            restart after draining. A different active template is refused while incompatible
            pool clones remain. --slim opts in to separately installed simslim.
            """)
    @OptionGroup var connection: Connection
    @Argument(help: "Project name (candidate identification only).") var project: String

    @Option(help: "simctl device type for this run.") var deviceType: String?
    @Option(help: "simctl runtime for this run.") var runtime: String?
    @Flag(help: "Build a new template even if one exists.") var replace = false
    @Flag(help: "Opt in to simslim using the selected profile. Requires simslim on PATH.") var slim = false

    func run() throws {
        guard
            // No receive timeout: a build runs simctl create plus a first boot (minutes);
            // every step has its own timeout in the daemon.
            case .template(let result) = try call(
                connection,
                .templateBuild(
                    TemplateBuildParams(
                        project: project, profile: nil, deviceType: deviceType, runtime: runtime,
                        replace: replace ? true : nil, slim: slim ? true : nil)), timeout: 0)
        else { throw failure(.protocolError) }
        try printTemplates(result, json: connection.json)
    }
}

struct TemplateList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List registered templates, flagging stale ones.")
    @OptionGroup var connection: Connection

    func run() throws {
        guard case .template(let result) = try call(connection, .templateList) else { throw failure(.protocolError) }
        try printTemplates(result, json: connection.json)
    }
}

struct TemplateRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Remove a registered template (by name or UDID).",
        discussion: """
            Goes through the cleanup gate: in report-only mode it's reported and kept \
            (would_remove), and the destructive-action limits can postpone it.
            """)
    @OptionGroup var connection: Connection
    @Argument(help: "Template name or UDID.") var template: String

    func run() throws {
        guard
            case .template(let result) = try call(connection, .templateRemove(TemplateRemoveParams(template: template)))
        else { throw failure(.protocolError) }
        if connection.json { return try printJSON(result) }
        switch result.outcome {
        case "removed": print("removed \(template)")
        case "would_remove": print("report-only: would remove \(template) (kept)")
        default: print("postponed by the cleanup rate limits: \(template)")
        }
    }
}
