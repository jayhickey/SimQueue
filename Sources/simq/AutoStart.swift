// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueDaemon
import SimQueueHost
import SimQueueIPC
import SimQueueProtocol

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Starts `simqd` when no daemon answers on the socket (on by default; off with
/// `"autostart": false` in the config or `SIMQ_NO_AUTOSTART=1`). The daemon runs detached (`DaemonLauncher`: new session, output in
/// `<state-dir>/simqd.log`, scrubbed environment) with the same state dir and config, so
/// it outlives the `simq` call (and a CI job) that started it. No launchd.
///
/// Two `simq` calls can't start two daemons: starts are serialized by
/// `<state-dir>/simq-autostart.lock`, and a start is skipped while simqd's own instance lock
/// (or, for a real backend, the host lock) is held, which means a daemon is already running
/// or coming up. simqd's instance and host locks remain the final guard.
enum AutoStart {
    /// Set to 1 to turn auto-start off for one call (tests, scripts that manage simqd).
    static let disableKey = "SIMQ_NO_AUTOSTART"
    /// Path to the simqd executable; default: next to `simq`.
    static let simqdPathKey = "SIMQ_SIMQD_PATH"
    /// True for a connect that found no daemon (socket missing, or nothing listening).
    static func isNoDaemon(_ error: SocketError) -> Bool {
        if case .system(let call, let code) = error, call == "connect" {
            return code == ENOENT || code == ECONNREFUSED
        }
        return false
    }

    enum Outcome: Equatable {
        /// Off: `"autostart": false`, or `SIMQ_NO_AUTOSTART=1`.
        case disabled
        /// A daemon answers now (started by this call or another).
        case ready
        case failed(String)
    }

    static func ensureDaemon(
        paths: SimQueuePaths, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Outcome {
        if environment[disableKey] == "1" { return .disabled }
        let config: DaemonConfig
        do {
            config = try DaemonConfig.load(path: paths.configPath)
        } catch {
            return .failed("can't auto-start simqd: \(error)")
        }
        let settings = config.autostart
        guard settings.enabled else { return .disabled }
        // What simqd will pick: the autostart backend, else the config's, else the platform's.
        let backend =
            settings.backend.flatMap(BackendKind.init(rawValue:))
            ?? BackendGate.choose(flag: nil, config: config.backend, dryRun: false)
        let deadline = Date().addingTimeInterval(settings.timeoutSeconds)

        // Serialize starts. Another simq holding this lock is starting the daemon: wait.
        var startLock: InstanceLock?
        while startLock == nil {
            do {
                startLock = try InstanceLock(path: paths.stateDir + "/simq-autostart.lock")
            } catch InstanceLock.LockError.alreadyRunning {
                if answers(paths) { return .ready }
                guard Date() < deadline else { return .failed("timed out waiting for another simq to start simqd") }
                Thread.sleep(forTimeInterval: 0.1)
            } catch {
                return .failed("can't auto-start simqd: \(error)")
            }
        }
        defer { startLock?.release() }
        if answers(paths) { return .ready }

        // A daemon holding its instance lock is running or starting: wait for it.
        if isHeld(paths.lockPath) {
            return waitUntilReady(paths, pid: nil, deadline: deadline)
        }
        if backend != .fake, isHeld(SimQueuePaths.hostLockPath(environment: environment)) {
            return .failed(
                "another simqd already holds the host lock \(SimQueuePaths.hostLockPath(environment: environment)); "
                    + "not starting a second real-sim daemon")
        }

        guard let simqd = simqdPath(environment: environment) else {
            return .failed("can't auto-start simqd: no simqd next to simq (set \(simqdPathKey))")
        }
        var argv = [
            simqd, "run", "--foreground", "--state-dir", paths.stateDir, "--config", paths.configPath,
        ]
        if let flag = settings.backend { argv += ["--backend", flag] }
        if let probe = settings.probe { argv += ["--probe", probe] }
        if let executor = settings.executor { argv += ["--executor", executor] }
        var callerEnvironment = environment
        callerEnvironment[SimQueuePaths.stateDirEnvironmentKey] = paths.stateDir
        let logPath = DaemonLauncher.logPath(stateDir: paths.stateDir)
        let pid: Int32
        do {
            pid = try DaemonLauncher.spawn(
                executable: simqd, argv: argv, callerEnvironment: callerEnvironment, stateDir: paths.stateDir)
        } catch {
            return .failed("can't auto-start simqd: \(error)")
        }
        printError("started simqd (pid \(pid), backend \(backend.rawValue)); log: \(logPath)")
        return waitUntilReady(paths, pid: pid, deadline: deadline)
    }

    /// Polls until a status request succeeds, the started daemon exits, or the deadline.
    static func waitUntilReady(_ paths: SimQueuePaths, pid: Int32?, deadline: Date) -> Outcome {
        while true {
            if answers(paths) { return .ready }
            if let pid, let exit = try? ProcessSpawner.reap(pid) {
                let tail =
                    (try? String(contentsOfFile: paths.stateDir + "/simqd.log", encoding: .utf8))
                    .map { $0.split(separator: "\n").suffix(5).joined(separator: "\n") } ?? ""
                return .failed("simqd \(exit.description) during startup\n\(tail)")
            }
            guard Date() < deadline else { return .failed("simqd didn't answer within the auto-start timeout") }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    static func answers(_ paths: SimQueuePaths) -> Bool {
        let client = SimQueueClient(socketPath: paths.socketPath, timeoutSeconds: 2)
        guard let response = try? client.send(Request(params: .status)), case .result = response.body else {
            return false
        }
        return true
    }

    static func isHeld(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        do {
            try InstanceLock(path: path).release()
            return false
        } catch {
            return true
        }
    }

    static func simqdPath(environment: [String: String]) -> String? {
        if let path = environment[simqdPathKey], !path.isEmpty {
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        guard let own = Bundle.main.executablePath else { return nil }
        let candidate =
            (URL(fileURLWithPath: own).resolvingSymlinksInPath().deletingLastPathComponent().path) + "/simqd"
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }
}
