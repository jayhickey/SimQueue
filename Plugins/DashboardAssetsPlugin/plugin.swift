// SPDX-License-Identifier: MIT

import Foundation
import PackagePlugin

@main
struct DashboardAssetsPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let tool = try context.tool(named: "DashboardAssetCompiler")
        let directory = context.package.directoryURL.appending(path: ".build/dashboard")
        let names = ["index.html", "app.js", "style.css", "sw.js", "manifest.webmanifest"]
        let inputs = names.map { directory.appending(path: $0) }
        let output = context.pluginWorkDirectoryURL.appending(path: "DashboardAssets.swift")
        return [
            .buildCommand(
                displayName: "Embed dashboard assets (prepare with npm ci && npm run build in Web/dashboard)",
                executable: tool.url,
                arguments: [directory.path, output.path],
                inputFiles: inputs,
                outputFiles: [output]
            )
        ]
    }
}
