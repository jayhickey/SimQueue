// SPDX-License-Identifier: MIT
import Foundation

// Build-time only. Assets travel inside the executable; no runtime resource bundle is needed.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let files = [
    ("index.html", "", "text/html"), ("app.js", "app.js", "text/javascript"),
    ("style.css", "style.css", "text/css"), ("sw.js", "sw.js", "text/javascript"),
    ("manifest.webmanifest", "manifest.webmanifest", "application/manifest+json"),
]
var entries: [String] = []
for (name, route, type) in files {
    let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    // Refuse a delimiter collision rather than silently generating different JavaScript.
    guard !text.contains("\"\"\"########") else { fatalError("Asset contains reserved Swift delimiter") }
    entries.append("\"\(route)\": (\"\(type)\", ########\"\"\"\n\(text)\n\"\"\"########)")
}
let source =
    "// Generated in the build directory. Do not commit.\nenum DashboardAssets {\nstatic let files: [String: (type: String, text: String)] = [\n"
    + entries.joined(separator: ",\n") + "\n]\n}\n"
try source.write(to: output, atomically: true, encoding: .utf8)
