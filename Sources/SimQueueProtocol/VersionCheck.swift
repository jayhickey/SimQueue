// SPDX-License-Identifier: MIT

import Foundation

extension DoctorCheck {
    /// The `version` line `simq doctor` adds: this `simq` and the daemon it reached. A
    /// mismatch warns (an upgrade swapped the binaries but simqd wasn't restarted, or a
    /// stale `simq` is first on PATH).
    public static func version(client: String, daemon: String?) -> DoctorCheck {
        guard let daemon else {
            return DoctorCheck(name: "version", level: .ok, detail: "simq \(client) (daemon not running)")
        }
        if daemon == client {
            return DoctorCheck(name: "version", level: .ok, detail: "simq \(client), simqd \(daemon)")
        }
        return DoctorCheck(
            name: "version", level: .warn,
            detail: "simq \(client), simqd \(daemon): they differ; restart simqd (or fix PATH) so both run one build")
    }
}

extension DoctorCheck {
    /// The one-line fix for a formula `simq` that took over the app cask's link.
    public static let appCLIFix = "brew uninstall simqueue && brew link --cask simqueue-app"

    /// Installed SimQueue.app bundles that ship their own `simq`, in lookup order.
    public static func installedApps(
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [String] {
        ["\(home)/Applications/SimQueue.app", "/Applications/SimQueue.app"]
            .filter { isExecutable($0 + "/Contents/Helpers/simq") }
    }

    /// `app_cli`: with SimQueue.app installed, the running `simq` should be the app's own.
    /// Nil (no check) when no installed app bundles `simq`. Warns only; never relinks.
    public static func appCLI(runningSimq: String, apps: [String]) -> DoctorCheck? {
        guard let first = apps.first else { return nil }
        let real = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let running = real(runningSimq)
        if let app = apps.first(where: { real($0 + "/Contents/Helpers/simq") == running }) {
            return DoctorCheck(name: "app_cli", level: .ok, detail: "simq is \(app)'s bundled simq")
        }
        return DoctorCheck(
            name: "app_cli", level: .warn,
            detail:
                "simq runs from \(running), not \(first)'s bundled simq (another install took over the link); fix: \(appCLIFix)"
        )
    }
}
