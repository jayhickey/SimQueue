// SPDX-License-Identifier: MIT

import ArgumentParser
import Dispatch
import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueEngine
import SimQueueHost
import SimQueueProtocol
import SimQueueSim
import SimQueueStore

@main
struct SimQD: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simqd",
        abstract: "SimQueue daemon (pre-alpha). Foreground only; simulators are fakes.",
        version: SimQueueVersion.current,
        subcommands: [Run.self]
    )
}

extension BackendKind: ExpressibleByArgument {}
extension ProbeKind: ExpressibleByArgument {}

/// What runs a job once it is admitted.
enum ExecutorKind: String, ExpressibleByArgument, CaseIterable {
    /// Runs the job's command in its own process group (`simq submit -- <cmd>`).
    case process
    /// Pretends: jobs finish per their `payload_json` `fake` plan. For tests and demos.
    case fake
}

/// Unbuffered stdout line, so logs appear promptly under launchd or a pipe.
func log(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the daemon in the foreground.",
        discussion: """
            Serves the simq socket (0600) in the state directory and runs the scheduler.
            With --executor process (the default) each job's command runs in its own
            process group, with output in <state-dir>/jobs/<date>/<job-id>/combined.log.
            --executor fake runs nothing. The sim backend is --backend, else fake for
            --dry-run, else the config's `backend`, else simctl (real simulators via xcrun simctl
            and simslim) on macOS and fake elsewhere. Clones copy simctl.template when configured,
            else the newest template `simq template build` made. --probe
            defaults to fake with fake sims and system with real ones. A launchd plist lives in
            deploy/launchd/ but is not installed.
            """
    )

    @Flag(help: "Run in the foreground. Required: background mode does not exist.")
    var foreground = false

    @Option(help: "Simulator backend: simctl (macOS default) or fake (default elsewhere and for --dry-run).")
    var backend: BackendKind?

    @Option(help: "Host probe: fake or system (read-only real readings). Default: follows --backend.")
    var probe: ProbeKind?

    @Option(help: "Job executor: process (default; runs each job's command) or fake (runs nothing).")
    var executor: ExecutorKind = .process

    @Flag(
        help:
            "Plan and log every host action (sim create/boot/shutdown/delete, signals, job commands) without running any. Forces cleanup to report-only."
    )
    var dryRun = false

    @Flag(help: "Start up (lease, recovery, reconcile, socket), print status, and exit. Used by CI smoke tests.")
    var exitAfterStartup = false

    @Option(help: "State directory (database, socket, lock, config). Default: $SIMQ_STATE_DIR or the platform default.")
    var stateDir: String?
    @Option(help: "Bound daemon stdout/stderr to four rotating 5 MiB log segments at this path.")
    var logFile: String?

    @Option(help: "Config file. Default: <state-dir>/config.json (optional).")
    var config: String?

    /// A fixed, healthy fake host for the fake backend (not a measurement of any machine).
    static let fakeHost = HostSnapshot(
        sampledAt: 0,
        totalMemoryBytes: 32 * ByteSize.gibibyte,
        availableMemoryBytes: 16 * ByteSize.gibibyte,
        cpuCount: 8,
        freeDiskBytes: 200 * ByteSize.gibibyte
    )

    func validate() throws {
        guard foreground else {
            throw ValidationError("simqd only runs with --foreground in this version.")
        }
    }

    private func fail(_ message: String, _ code: SimQExitCode) -> ExitCode {
        FileHandle.standardError.write(Data("simqd: \(message)\n".utf8))
        return ExitCode(code.rawValue)
    }

    func run() throws {
        if let logFile { try RotatingDaemonLog.redirect(to: logFile) }
        let paths = SimQueuePaths.resolve(explicit: stateDir)
        var daemonConfig: DaemonConfig
        do {
            daemonConfig = try DaemonConfig.load(path: config ?? paths.configPath)
        } catch {
            throw fail("\(error)", .usage)
        }
        let chosen = BackendGate.choose(flag: backend, config: daemonConfig.backend, dryRun: dryRun)
        do {
            _ = try BackendGate.resolve(requested: chosen)
        } catch let error as BackendGateError {
            throw fail(error.description, .usage)
        }
        if dryRun { DryRun.apply(to: &daemonConfig) }

        // Pool sim names carry this state dir's owner tag, so a second daemon on the host
        // (another state dir) never makes the same name or reaps this one's sims. Kept in
        // `<state>/owner-tag` after the first start, so the spelling of the path never matters.
        let naming = SimNamingScheme(
            ownerTag: OwnerTagFile.resolve(stateDirectory: paths.stateDir, persist: !dryRun, log: { log($0) }))
        let host: HostBackends
        do {
            host = try HostBackends.make(
                backend: chosen, probe: probe, config: daemonConfig, environment: ProcessInfo.processInfo.environment,
                fakeHost: Self.fakeHost, diskPath: paths.stateDir, naming: naming)
        } catch {
            throw fail("\(error)", .usage)
        }
        let resolved = host.backend
        // Load gates, the memory reserve and sim counts scale with this host's cores and RAM
        // (config `host`). Sampled once here; an unreadable probe keeps the plain defaults.
        if let sample = try? host.probe.sample(now: Date().timeIntervalSince1970) {
            daemonConfig.applyHostSizing(cpuCount: sample.cpuCount, totalMemoryBytes: sample.totalMemoryBytes)
            log(daemonConfig.hostSizingSummary(cpuCount: sample.cpuCount, totalMemoryBytes: sample.totalMemoryBytes))
        }

        let lock: InstanceLock
        do {
            lock = try InstanceLock(path: paths.lockPath)
        } catch {
            throw fail("\(error)", .internalError)
        }
        defer { lock.release() }
        let hostLock: InstanceLock?
        do {
            hostLock = try HostLock.acquire(
                backend: resolved, lockPath: SimQueuePaths.hostLockPath(), stateDir: paths.stateDir)
        } catch {
            throw fail("\(error)", .internalError)
        }
        defer { hostLock?.release() }

        let databasePath: String
        do {
            databasePath = dryRun ? try DryRun.prepareDatabase(realPath: paths.databasePath) : paths.databasePath
        } catch {
            throw fail("dry run: cannot copy \(paths.databasePath): \(error)", .internalError)
        }
        let store = try JobStore(
            path: databasePath, maxInfraRetries: daemonConfig.defaultMaxRetries,
            maxQueuedPerSubmitterPerProject: daemonConfig.maxQueuedPerSubmitterPerProject)
        store.maxQueuedTotal = daemonConfig.maxQueuedTotal
        let outputRoot = daemonConfig.jobOutputRoot ?? paths.jobsRoot
        let outputConfiguration = try JobOutputConfiguration.prepare(
            stateDirectory: paths.stateDir, root: outputRoot, store: store, persist: !dryRun)
        if resolved == .simctl {
            let poolSims = try store.poolSims()
            if !poolSims.isEmpty {
                guard
                    let selected = daemonConfig.simctl?.template ?? daemonConfig.defaultHostTemplate.flatMap({
                        daemonConfig.hostTemplates[$0]
                    }) ?? daemonConfig.hostTemplates.values.sorted().first
                else {
                    throw ValidationError(
                        "simctl.template is required for an existing pool. Select its recorded clone source, or drain and reset the pool using the previous version before upgrading."
                    )
                }
                guard
                    poolSims.allSatisfy({ sim in
                        ([selected] + Array(daemonConfig.hostTemplates.values)).contains {
                            sim.clonedFrom?.udid == $0 || sim.clonedFrom?.name == $0
                        }
                    })
                else {
                    throw ValidationError(
                        "simctl.template differs from existing pool clones. Finish leases, run simq drain, then simq uninstall --yes to stop the service and remove only owned pool sims (templates and state kept); select the new template and restart. No queue recovery has run."
                    )
                }
            }
        }
        let fakeProcesses = FakeProcessTable()
        let hostProcesses: any ProcessTable = executor == .process ? SystemProcessTable() : fakeProcesses
        let dryRunLog: @Sendable (String) -> Void = { line in log(line) }
        let processes: any ProcessTable = dryRun ? DryRunProcessTable(hostProcesses, log: dryRunLog) : hostProcesses
        var environment = EngineEnvironment(
            clock: SystemClock(),
            probe: host.probe,
            sims: dryRun ? DryRunSimBackend(host.sims, log: dryRunLog) : host.sims,
            processes: processes,
            // The real disk, limited to SimQueue's own work and jobs directories and never
            // following symlinks; a dry run only reads (every removal is planned, not run).
            fileSystem: dryRun
                ? DryRunFileSystem(
                    StorageFileSystem(
                        base: RootedFileSystem(roots: [paths.runsRoot] + outputConfiguration.roots),
                        roots: outputConfiguration.roots), log: dryRunLog)
                : StorageFileSystem(
                    base: RootedFileSystem(roots: [paths.runsRoot] + outputConfiguration.roots),
                    roots: outputConfiguration.roots),
            layout: RunDirectoryLayout(root: paths.runsRoot),
            naming: naming,
            processGraceSeconds: daemonConfig.timeouts.killGraceSeconds,
            artifactsRoot: outputRoot
        )
        environment.historicalArtifactsRoots = outputConfiguration.roots
        let pid = ProcessInfo.processInfo.processIdentifier
        let (engine, recovery, reconcile) = try Engine.start(
            store: store,
            environment: environment,
            config: daemonConfig.scheduler,
            reliability: daemonConfig.reliability,
            timeouts: daemonConfig.timeouts,
            watchdog: daemonConfig.watchdog,
            ownerID: "simqd-\(pid)",
            pid: pid
        )
        let info = DaemonInfo(
            version: SimQueueVersion.current,
            pid: pid,
            epoch: engine.epoch,
            backend: resolved.rawValue,
            startedAt: environment.clock.now(),
            statePath: databasePath,
            socketPath: paths.socketPath,
            cleanupMode: daemonConfig.reliability.cleanupMode.rawValue,
            probe: host.probeKind.rawValue,
            dryRun: dryRun ? true : nil
        )
        var artifacts = JobArtifacts(root: outputRoot)
        artifacts.legacyRoot = paths.jobsRoot
        let jobExecutor: any JobExecutor
        if dryRun {
            jobExecutor = DryRunExecutor(log: { log($0) })
        } else if executor == .process {
            jobExecutor = ProcessExecutor(
                artifacts: artifacts, processes: processes, graceSeconds: daemonConfig.timeouts.killGraceSeconds)
        } else {
            jobExecutor = FakeExecutor(processes: fakeProcesses)
        }
        // Alerts go to health.json always, and to GitHub issues only when configured.
        #if DEBUG
            if let target = ProcessInfo.processInfo.environment["SIMQ_TEST_CRASH_BEFORE_CLAIM"] {
                engine.admissionAttemptRecorded = { jobID in
                    if jobID == target { raise(SIGKILL) }
                }
            }
        #endif
        let service = DaemonService(
            engine: engine, config: daemonConfig, info: info, executor: jobExecutor, artifacts: artifacts)
        service.storageChecksEnabled = true
        let server: DaemonServer
        do {
            server = try DaemonServer(service: service, socketPath: paths.socketPath)
        } catch {
            throw fail("\(error)", .internalError)
        }

        log(
            "simqd \(SimQueueVersion.current) foreground, backend=\(resolved.rawValue), probe=\(host.probeKind.rawValue), executor=\(dryRun ? "dry-run" : executor.rawValue), "
                + "dry_run=\(dryRun), "
                + "sqlite=\(Database.libraryVersion), schema=v\(SchemaMigrations.latestVersion), epoch=\(engine.epoch)"
        )
        log(
            "simqd: state=\(paths.stateDir) socket=\(paths.socketPath) cleanup=\(daemonConfig.reliability.cleanupMode.rawValue)"
        )
        log(
            "simqd: recovered requeued=\(recovery.requeued.count) interrupted=\(recovery.interrupted.count) "
                + "restart_killed=\(recovery.killedProcessGroups.count) restart_cap=\(recovery.restartCapReached.count) "
                + "timed_out=\(engine.startupTimeouts.timedOut.count) expired=\(engine.startupTimeouts.expired.count) "
                + "reconcile_actions=\(reconcile.actions.count)"
        )

        if exitAfterStartup {
            server.stop()
            return
        }

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signalQueue = DispatchQueue(label: "simqd.signals")
        let sources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
            source.setEventHandler { server.stop() }
            source.resume()
            return source
        }
        server.start()
        log("simqd: ready; Ctrl-C or SIGTERM stops.")
        withExtendedLifetime(sources) {
            server.waitUntilStopped()
        }
        if let failure = server.failure {
            throw fail("stopped: \(failure)", .internalError)
        }
        log("simqd: stopped.")
    }
}
