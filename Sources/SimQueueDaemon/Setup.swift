// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueProtocol
import SimQueueSim
import SimQueueStore

/// What `simq init` writes and checks. Pure apart from the tool probes, which run through a
/// `ToolRunner` (tests point its PATH at fake tools).
public enum SetupChecks {
    /// The oldest simslim SimQueue is tested with.
    public static let minimumSimslimVersion = [0, 12, 0]

    /// The first `MAJOR.MINOR[.PATCH]` in `text` (for `simslim 0.12.2`, `Xcode 27.0`).
    public static func parseVersion(_ text: String) -> [Int]? {
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let trimmed = word.hasPrefix("v") ? word.dropFirst() : word[...]
            let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 2, parts.count <= 3 else { continue }
            let numbers = parts.compactMap { Int($0) }
            if numbers.count == parts.count { return numbers + Array(repeating: 0, count: 3 - numbers.count) }
        }
        return nil
    }

    public static func isAtLeast(_ version: [Int], _ minimum: [Int]) -> Bool {
        for (have, need) in zip(version, minimum) where have != need { return have > need }
        return version.count >= minimum.count
    }

    static func dotted(_ version: [Int]) -> String { version.map(String.init).joined(separator: ".") }

    /// simslim on PATH, at least `minimumSimslimVersion`. Missing or old: a warning, since
    /// SimQueue still runs (unslimmed templates) without it.
    public static func simslim(runner: ToolRunner) -> DoctorCheck {
        let need = dotted(minimumSimslimVersion)
        guard let result = try? runner.run("simslim", ["--version"], timeoutSeconds: 10), result.succeeded else {
            return DoctorCheck(
                name: "simslim", level: .warn,
                detail: "not found on PATH; install it (brew install mobai-app/tap/simslim), \(need) or newer")
        }
        guard let version = parseVersion(result.stdout + " " + result.stderr) else {
            return DoctorCheck(name: "simslim", level: .warn, detail: "can't read its version; need \(need) or newer")
        }
        guard isAtLeast(version, minimumSimslimVersion) else {
            return DoctorCheck(
                name: "simslim", level: .warn,
                detail: "\(dotted(version)) is older than \(need); upgrade it (brew upgrade simslim)")
        }
        return DoctorCheck(name: "simslim", level: .ok, detail: dotted(version))
    }

    /// Xcode selected and `simctl` reachable. Missing: a failure (no simulators without it).
    public static func xcode(runner: ToolRunner) -> DoctorCheck {
        #if !os(macOS)
            return DoctorCheck(name: "xcode", level: .warn, detail: "not macOS: only the fake backend runs here")
        #else
            guard let result = try? runner.run("xcodebuild", ["-version"], timeoutSeconds: 30), result.succeeded,
                let version = parseVersion(result.stdout)
            else {
                return DoctorCheck(
                    name: "xcode", level: .fail,
                    detail:
                        "xcodebuild -version failed; install Xcode and run sudo xcode-select -s /Applications/Xcode.app"
                )
            }
            guard (try? runner.run("xcrun", ["--find", "simctl"], timeoutSeconds: 30))?.succeeded == true else {
                return DoctorCheck(
                    name: "xcode", level: .fail, detail: "Xcode \(dotted(version)), but xcrun can't find simctl")
            }
            return DoctorCheck(name: "xcode", level: .ok, detail: "Xcode \(dotted(version)), simctl found")
        #endif
    }

    /// The starter `config.json`: real simulators, report-only cleanup, a demand-driven pool. Every
    /// key is optional; see docs/config.example.json. `launchd`: launchd owns simqd, so
    /// `simq` must not auto-start a second one.
    public static func starterConfig(launchd: Bool) -> String {
        let autostart = launchd ? "false" : #"{"timeout_seconds": 30}"#
        return """
            {
              "autostart": \(autostart),
              "cleanup_mode": "report-only",
              "pool": {
                "mode": "active",
                "warm_min": 0,
                "max_concurrent_boots": 1
              }
            }

            """
    }

    public static let launchAgentLabel = "dev.simqueue.simqd"
    /// Homebrew's `brew services` label for the formula.
    public static let homebrewServiceLabel = "homebrew.mxcl.simqueue"

    /// The per-user LaunchAgent `simq init --launchd` installs (same shape as
    /// deploy/launchd/dev.simqueue.simqd.plist, filled in).
    public static func launchAgentPlist(simqd: String, stateDir: String, logPath: String) -> String {
        func xml(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <!-- Installed by simq init --launchd. Remove with simq uninstall. -->
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(launchAgentLabel)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(xml(simqd))</string>
                    <string>run</string>
                    <string>--foreground</string>
                    <string>--log-file</string>
                    <string>\(xml(logPath))</string>
                    <string>--state-dir</string>
                    <string>\(xml(stateDir))</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <dict>
                    <key>SuccessfulExit</key>
                    <false/>
                </dict>
                <key>ThrottleInterval</key>
                <integer>10</integer>
                <key>ProcessType</key>
                <string>Background</string>
                <key>StandardOutPath</key>
                <string>/dev/null</string>
                <key>StandardErrorPath</key>
                <string>/dev/null</string>
            </dict>
            </plist>

            """
    }
}

/// The destructive half of `simq uninstall`, kept pure enough to test on fakes.
public enum Uninstaller {
    public enum RemovalError: Error, CustomStringConvertible {
        case resourcesHeld
        public var description: String {
            "pool leases or command/host cleanup remain; restart with the current template, release leases and complete simq drain before uninstalling"
        }
    }
    public struct SimOutcome: Sendable, Equatable {
        public var deleted: [String] = []
        /// Report-only cleanup mode: listed, not deleted (pass `--force`).
        public var wouldDelete: [String] = []
        /// Held back by the destructive-action rate limits (pass `--force`, or rerun).
        public var rateLimited: [String] = []
        public var failed: [String: String] = [:]

        public init() {}
    }

    /// Deletes SimQueue's owned sims through the same `CleanupGate` the daemon uses (no
    /// grace: these are owned, not orphans). `force` skips the gate's report-only mode and
    /// rate limits, never the backend's own checks: `deleteDevice` still refuses anything
    /// outside SimQueue's namespace or a template.
    public static func deleteOwnedSims(
        udids: [String], backend: any SimBackend, reliability: ReliabilityConfig, executedLastHour: Int,
        force: Bool, now: Double
    ) -> SimOutcome {
        var outcome = SimOutcome()
        var gate = CleanupGate(config: reliability, executedLastHour: executedLastHour)
        for udid in udids {
            let decision = force ? .execute : gate.decide(firstSeenAt: now, now: now, graceSeconds: 0)
            switch decision {
            case .execute:
                do {
                    try backend.deleteDevice(udid: udid)
                    outcome.deleted.append(udid)
                } catch {
                    outcome.failed[udid] = "\(error)"
                }
            case .wouldExecute: outcome.wouldDelete.append(udid)
            case .deferRateLimit, .deferGrace: outcome.rateLimited.append(udid)
            }
        }
        return outcome
    }

    /// The caller holds the stopped state's instance lock. Retire only verified host
    /// removals, so a later explicit template selection is not blocked by stale rows.
    public static func deleteOwnedSimsAndRecord(
        udids: [String], backend: any SimBackend, store: JobStore?, reliability: ReliabilityConfig,
        executedLastHour: Int, force: Bool, now: Double
    ) throws -> (outcome: SimOutcome, devices: [SimDevice]) {
        if let store {
            guard try !store.poolSims().contains(where: { $0.phase == .leased || $0.leaseID != nil }),
                try store.liveResources(kinds: [.processGroup]).isEmpty,
                try store.pendingActionIntents().isEmpty
            else { throw RemovalError.resourcesHeld }
        }
        var outcome = deleteOwnedSims(
            udids: udids, backend: backend, reliability: reliability, executedLastHour: executedLastHour,
            force: force, now: now)
        // Unknown inventory never authorizes a metadata clear, even after a successful
        // delete call. A later explicit uninstall can verify and finish partial cleanup.
        let devices = try backend.listDevices()
        let present = Set(devices.map(\.udid))
        for udid in outcome.deleted where present.contains(udid) {
            outcome.failed[udid] = "simulator is still present after deletion; ownership retained"
        }
        outcome.deleted.removeAll { present.contains($0) }
        if let store, !outcome.deleted.isEmpty {
            let removed = Set(outcome.deleted)
            try store.database.immediateTransaction {
                for resource in try store.liveResources(kinds: [.sim]) where removed.contains(resource.externalID) {
                    try store.markResourceReleased(id: resource.id, reason: "verified uninstall deletion", now: now)
                }
                for udid in outcome.deleted {
                    try store.deletePoolSim(udid: udid)
                    try store.audit("pool_removed_by_uninstall", detail: udid, now: now)
                    // Conservatively charge each verified retirement, including an
                    // already-absent retry, so offline cleanup cannot bypass the budget.
                    try store.audit(Engine.destructiveAuditType, detail: "verified uninstall removal \(udid)", now: now)
                }
            }
        }
        return (outcome, devices)
    }

    /// Deletes the owned sims on this host's real backend (`simctl`), with this state dir's
    /// naming (owner tag), and lists the templates it keeps. Nil when the config's backend
    /// isn't simctl or simctl isn't here (nothing to delete).
    public static func deleteOwnedSimsOnHost(
        owned: [String], config: DaemonConfig, paths: SimQueuePaths, force: Bool, now: Double,
        runner: ToolRunner = ToolRunner(), simctlAvailable: Bool = BackendKind.simctlAvailable
    ) throws -> (outcome: SimOutcome, templates: [SimDevice])? {
        guard (config.backend ?? .platformDefault) == .simctl, simctlAvailable else { return nil }
        let naming = SimNamingScheme(ownerTag: SimNamingScheme.ownerTag(stateDirectory: paths.stateDir))
        let backend = try SimctlBackend(runner: runner, naming: naming)
        let store =
            FileManager.default.fileExists(atPath: paths.databasePath)
            ? try JobStore(path: paths.databasePath) : nil
        let executed = try store?.auditCount(type: Engine.destructiveAuditType, since: now - 3600) ?? 0
        let result = try deleteOwnedSimsAndRecord(
            udids: owned, backend: backend, store: store, reliability: config.reliability,
            executedLastHour: executed, force: force, now: now)
        return (result.outcome, result.devices.filter { naming.isTemplate($0.name) })
    }

    public enum PurgeError: Error, Equatable, CustomStringConvertible {
        case unsafePath(String)
        case notAStateDir(String)

        public var description: String {
            switch self {
            case .unsafePath(let path): return "refusing to delete \(path)"
            case .notAStateDir(let path):
                return
                    "\(path) doesn't look like a SimQueue state dir (no simqueue.sqlite or config.json); not deleting it"
            }
        }
    }

    /// `--purge` deletes the state dir only if it really is one: not `/`, not the home dir
    /// or one of its parents (after resolving symlinks), and holding the database or the config file.
    public static func checkPurgeable(_ paths: SimQueuePaths, home: String) throws {
        // Resolve symlinks on both sides, so a link to (or above) the home dir can't slip by.
        let dir = URL(fileURLWithPath: paths.stateDir).resolvingSymlinksInPath().standardizedFileURL.path
        let homeDir = URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
        if dir == "/" || dir == homeDir || homeDir.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/") {
            throw PurgeError.unsafePath(dir)
        }
        let files = FileManager.default
        guard files.fileExists(atPath: paths.databasePath) || files.fileExists(atPath: paths.configPath) else {
            throw PurgeError.notAStateDir(dir)
        }
    }
}
