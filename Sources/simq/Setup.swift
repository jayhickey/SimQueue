// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueIPC
import SimQueueProtocol
import SimQueueStore

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// The command that builds a simulator template. (`simq golden build` still works as a hidden
/// alias.)
let templateBuildCommand = "simq template build"

func launchAgentsDirectory(_ explicit: String?) -> String {
    explicit ?? (NSHomeDirectory() + "/Library/LaunchAgents")
}

/// True when this `simq` runs from a Homebrew keg (…/Cellar/simqueue/…).
var installedByHomebrew: Bool {
    let path = Bundle.main.executablePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? ""
    return path.contains("/Cellar/simqueue/")
}

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set SimQueue up on this Mac: a starter config, Xcode check and optional simslim check.",
        discussion: """
            Writes <state-dir>/config.json (kept if it exists; --force replaces it) and checks that
            Xcode and simctl are available. simslim is optional and used only with template build --slim.
            simq starts simqd on demand, so nothing else is needed. --launchd instead installs
            a per-user LaunchAgent (~/Library/LaunchAgents/\(SetupChecks.launchAgentLabel).plist)
            and turns auto-start off; with Homebrew, use `brew services start simqueue` instead.
            Exits 0 when everything checks out, 1 when a check failed.
            """)
    @Option(help: "State directory. Default: $SIMQ_STATE_DIR or the platform default.")
    var stateDir: String?
    @Flag(help: "Replace an existing config.json with the starter one.")
    var force = false
    @Flag(help: "Install and load a LaunchAgent for simqd (macOS), and set \"autostart\": false.")
    var launchd = false
    @Flag(help: .hidden) var noLoad = false
    @Option(help: .hidden) var launchAgentsDir: String?

    func run() throws {
        let paths = SimQueuePaths.resolve(explicit: stateDir)
        let files = FileManager.default
        try files.createDirectory(
            atPath: paths.stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        print("state dir: \(paths.stateDir)")

        if files.fileExists(atPath: paths.configPath) && !force {
            print("config: kept \(paths.configPath) (--force replaces it)")
            if launchd, (try? DaemonConfig.load(path: paths.configPath))?.autostart.enabled != false {
                print("WARN  config: set \"autostart\": false in it, so simq doesn't start a second simqd")
            }
        } else {
            try Data(SetupChecks.starterConfig(launchd: launchd).utf8).write(
                to: URL(fileURLWithPath: paths.configPath), options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configPath)
            _ = try DaemonConfig.load(path: paths.configPath)
            print("config: wrote \(paths.configPath)")
        }

        let runner = ToolRunner()
        let checks = [SetupChecks.xcode(runner: runner), SetupChecks.simslim(runner: runner)]
        for check in checks { print("\(check.level.rawValue.uppercased())  \(check.name): \(check.detail)") }

        if launchd { try installLaunchAgent(paths: paths, runner: runner) }

        print("")
        print("Next steps:")
        print("  simq doctor                      # health report")
        print("  \(templateBuildCommand) host           # stock template; --slim is optional")
        print("  # Set simctl.template in config.json to the returned UDID; drain and restart simqd.")
        print("  simq run --project <name> -- /bin/sh -c 'xcodebuild test -scheme <Scheme> -destination id=$SIMQ_UDID'")
        if !launchd {
            print(
                installedByHomebrew
                    ? "  brew services start simqueue     # optional: simqd as a login service"
                    : "  simq init --launchd              # optional: simqd as a login service")
        }
        print("Docs: https://github.com/jayhickey/SimQueue#readme")
        if checks.contains(where: { $0.level == .fail }) { throw ExitCode(1) }
    }

    private func installLaunchAgent(paths: SimQueuePaths, runner: ToolRunner) throws {
        #if !os(macOS)
            if !noLoad {
                printError("--launchd needs macOS (launchd)")
                throw failure(.usage)
            }
        #endif
        let directory = launchAgentsDirectory(launchAgentsDir)
        if FileManager.default.fileExists(atPath: directory + "/\(SetupChecks.homebrewServiceLabel).plist") {
            printError("Homebrew's simqueue service is installed; manage simqd with brew services instead of --launchd")
            throw ExitCode(1)
        }
        guard let simqd = AutoStart.simqdPath(environment: ProcessInfo.processInfo.environment) else {
            printError("no simqd next to simq (set \(AutoStart.simqdPathKey))")
            throw ExitCode(1)
        }
        // Next to the LaunchAgents dir: ~/Library/Logs/SimQueue (tests pass their own dir).
        let logDirectory = URL(fileURLWithPath: directory).deletingLastPathComponent().path + "/Logs/SimQueue"
        try FileManager.default.createDirectory(atPath: logDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let plist = directory + "/\(SetupChecks.launchAgentLabel).plist"
        try Data(
            SetupChecks.launchAgentPlist(simqd: simqd, stateDir: paths.stateDir, logPath: logDirectory + "/simqd.log")
                .utf8
        ).write(to: URL(fileURLWithPath: plist), options: .atomic)
        print("launchd: wrote \(plist)")
        if noLoad { return }
        let domain = "gui/\(getuid())"
        // Already loaded (a rerun): boot the old one out so the new plist takes effect.
        if (try? runner.run("launchctl", ["print", "\(domain)/\(SetupChecks.launchAgentLabel)"], timeoutSeconds: 30))?
            .succeeded == true
        {
            _ = try? runner.run(
                "launchctl", ["bootout", "\(domain)/\(SetupChecks.launchAgentLabel)"], timeoutSeconds: 30)
            print("launchd: unloaded the previous \(SetupChecks.launchAgentLabel)")
        }
        let result = try runner.run("launchctl", ["bootstrap", domain, plist], timeoutSeconds: 30)
        guard result.succeeded else {
            printError("launchctl bootstrap failed (\(result.status)): \(result.stderr)")
            printError(
                "simqd is NOT running, and with \"autostart\": false in \(paths.configPath) simq won't start one."
                    + " Fix the error and rerun simq init --launchd, or set \"autostart\" back to true.")
            throw ExitCode(1)
        }
        print("launchd: loaded \(SetupChecks.launchAgentLabel)")
    }
}

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop simqd, delete the simulators SimQueue owns, and optionally its state.",
        discussion: """
            Without --yes it only prints the plan. Refuses while jobs are running or admitted,
            while simqd holds its lock but doesn't answer, and while jobs are queued unless
            --force (queued jobs stay in the database for the next simqd; only --purge deletes
            them). Stops simqd (and unloads the LaunchAgent
            simq init --launchd installed), then deletes the simq-* sims SimQueue owns through
            the same cleanup gate as the daemon: in report-only cleanup mode, or past the
            destructive-action limits, they're listed, not deleted, unless --force. The backend
            still refuses anything outside SimQueue's namespace. Templates are kept and listed.
            --purge also deletes the state dir (queue database, logs, artifacts, config).
            """)
    @OptionGroup var connection: Connection
    @Flag(help: "Do it (without this, print the plan only).")
    var yes = false
    @Flag(help: "Also delete the state dir.")
    var purge = false
    @Flag(
        help:
            "Delete owned sims despite report-only mode or the rate limits, and go ahead with queued jobs (kept unless --purge)."
    )
    var force = false
    @Option(help: .hidden) var launchAgentsDir: String?

    func run() throws {
        let paths = connection.paths
        let directory = launchAgentsDirectory(launchAgentsDir)
        if FileManager.default.fileExists(atPath: directory + "/\(SetupChecks.homebrewServiceLabel).plist") {
            printError("Homebrew's simqueue service is installed: run `brew services stop simqueue` first")
            throw ExitCode(1)
        }
        // Straight to the socket: uninstall never auto-starts a daemon.
        let status: StatusResult? = {
            guard
                case .result(.status(let status))? = try? connection.client(timeout: 5).send(
                    Request(params: .status))?.body
            else { return nil }
            return status
        }()
        // No answer isn't proof there's no daemon: a busy or wedged simqd still holds its
        // lock. Never stop or delete anything under a daemon that may be live.
        if status == nil, AutoStart.answers(paths) || AutoStart.isHeld(paths.lockPath) {
            printError(
                "simqd is running but didn't answer; wait and retry, or stop it yourself first (lock: \(paths.lockPath))"
            )
            throw ExitCode(1)
        }
        if let status {
            if status.running + status.admitted > 0 {
                printError(
                    "\(status.running + status.admitted) job(s) running or admitted; wait for them or cancel them, then retry"
                )
                throw ExitCode(1)
            }
            if status.queued > 0 && !force {
                printError(
                    "\(status.queued) job(s) queued; cancel them, or pass --force to go ahead"
                        + " (they stay queued for the next simqd unless --purge deletes the state dir)")
                throw ExitCode(1)
            }
        }
        try requireNoPendingCleanup(paths)
        if yes, let status, status.drainComplete != true {
            printError(
                "drain has not completed; run `simq drain --timeout 30m` before uninstalling so pool/template work finishes safely"
            )
            throw ExitCode(1)
        }
        let config = (try? DaemonConfig.load(path: paths.configPath)) ?? DaemonConfig()
        let agent = directory + "/\(SetupChecks.launchAgentLabel).plist"
        let hasAgent = FileManager.default.fileExists(atPath: agent)
        let owned =
            FileManager.default.fileExists(atPath: paths.databasePath)
            ? ((try? JobStore(readOnlyPath: paths.databasePath).ownedSimUDIDs()) ?? []) : []
        if purge { try Uninstaller.checkPurgeable(paths, home: NSHomeDirectory()) }

        print("state dir: \(paths.stateDir)")
        print("simqd: \(status.map { "running (pid \($0.daemon.pid))" } ?? "not running")")
        if hasAgent { print("LaunchAgent: \(agent)") }
        print(
            "owned sims: \(owned.count) (cleanup_mode \(config.reliability.cleanupMode.rawValue)\(force ? ", --force" : ""))"
        )
        guard yes else {
            print(
                "Plan only. Rerun with --yes to stop simqd\(hasAgent ? ", unload the LaunchAgent" : ""), delete owned sims"
                    + "\(purge ? " and delete the state dir" : "").")
            return
        }

        if hasAgent {
            #if os(macOS)
                _ = try? ToolRunner().run(
                    "launchctl", ["bootout", "gui/\(getuid())/\(SetupChecks.launchAgentLabel)"], timeoutSeconds: 30)
            #endif
            try FileManager.default.removeItem(atPath: agent)
            print("launchd: removed \(SetupChecks.launchAgentLabel)")
        }
        if let status {
            kill(status.daemon.pid, SIGTERM)
            let deadline = Date().addingTimeInterval(30)
            while AutoStart.answers(paths) || AutoStart.isHeld(paths.lockPath) {
                guard Date() < deadline else {
                    printError("simqd (pid \(status.daemon.pid)) didn't stop within 30 s")
                    throw ExitCode(1)
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            print("simqd: stopped")
        }

        // Fence autostart while final ownership is read, host deletions are verified,
        // and their pool/ownership rows are retired. A new daemon must not race cleanup.
        let cleanupLock =
            FileManager.default.fileExists(atPath: paths.stateDir)
            ? try InstanceLock(path: paths.lockPath) : nil
        defer { cleanupLock?.release() }
        // A bounded worker could finish registration while shutdown is being awaited.
        // Read the final ownership ledger only after the daemon released its lock.
        try requireNoPendingCleanup(paths)
        let stoppedStore =
            FileManager.default.fileExists(atPath: paths.databasePath)
            ? try JobStore(readOnlyPath: paths.databasePath) : nil
        if let stoppedStore {
            if try stoppedStore.poolSims().contains(where: { $0.phase == .leased || $0.leaseID != nil }) {
                printError(
                    "pool simulators remain leased; restart with the current template, release leases and complete simq drain before uninstalling"
                )
                throw ExitCode(1)
            }
            let active = try stoppedStore.activeJobs()
            let queued = try stoppedStore.queuedJobs()
            if !active.isEmpty || (!force && !queued.isEmpty) {
                printError(
                    "work appeared while stopping simqd; state was retained. Restart it and drain or cancel the new work before uninstalling"
                )
                throw ExitCode(1)
            }
        }
        let finalOwned = try stoppedStore?.ownedSimUDIDs() ?? []
        try deleteSims(owned: finalOwned, config: config, paths: paths)

        if purge {
            try FileManager.default.removeItem(atPath: paths.stateDir)
            print("state dir: deleted")
        }
        if installedByHomebrew { print("Finally: brew uninstall simqueue") }
    }

    private func requireNoPendingCleanup(_ paths: SimQueuePaths) throws {
        if filesWithPendingCleanup(paths) {
            printError(
                "owned command processes still need cleanup, or a host action remains pending; inspect simq doctor and wait for a successful drain before uninstalling"
            )
            throw ExitCode(1)
        }
    }

    private func filesWithPendingCleanup(_ paths: SimQueuePaths) -> Bool {
        guard FileManager.default.fileExists(atPath: paths.databasePath) else { return false }
        guard let store = try? JobStore(readOnlyPath: paths.databasePath),
            let groups = try? store.liveResources(kinds: [.processGroup]),
            let intents = try? store.pendingActionIntents()
        else { return true }
        return !groups.isEmpty || !intents.isEmpty
    }

    private func deleteSims(owned: [String], config: DaemonConfig, paths: SimQueuePaths) throws {
        guard
            let (outcome, templates) = try Uninstaller.deleteOwnedSimsOnHost(
                owned: owned, config: config, paths: paths, force: force, now: Date().timeIntervalSince1970)
        else {
            print("sims: no simctl backend here; nothing to delete")
            return
        }
        for udid in outcome.deleted { print("deleted sim \(udid)") }
        for udid in outcome.wouldDelete { print("kept sim \(udid) (report-only cleanup mode; --force deletes it)") }
        for udid in outcome.rateLimited { print("kept sim \(udid) (destructive-action limit; rerun, or --force)") }
        for (udid, why) in outcome.failed.sorted(by: { $0.key < $1.key }) { printError("sim \(udid): \(why)") }
        if !templates.isEmpty {
            print("templates kept (delete by hand with xcrun simctl delete <udid>):")
            for sim in templates { print("  \(sim.name) \(sim.udid)") }
        }
        if !outcome.failed.isEmpty { throw ExitCode(1) }
        if purge, !outcome.wouldDelete.isEmpty || !outcome.rateLimited.isEmpty {
            printError(
                "owned simulators were retained by cleanup policy; state kept. Review the plan and retry with --force before purging ownership metadata"
            )
            throw ExitCode(1)
        }
    }
}
