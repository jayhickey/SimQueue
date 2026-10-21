// SPDX-License-Identifier: MIT

import Foundation
import SimQueueHost

/// How `simq` launches an auto-started `simqd` so it survives the caller, including a
/// GitHub Actions job (whose runner kills every process carrying the job's
/// `RUNNER_TRACKING_ID` when the job ends):
/// - a new session (setsid), so no controlling terminal and its own process group;
/// - stdin from /dev/null, stdout and stderr appended to `<state-dir>/simqd.log`;
/// - cwd is the state dir;
/// - a scrubbed environment (`environment(from:)`): no runner, GitHub or Actions
///   variables, no caller TMPDIR, no tokens.
/// The caller (`simq`) exits right after the daemon answers, so the daemon is reparented
/// to launchd/init and is never a child of the CI step's shell.
public enum DaemonLauncher {
    /// Passed through when set; everything else is dropped.
    public static let allowedKeys: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "LANG", "DEVELOPER_DIR"]
    /// SimQueue's own settings (`SIMQ_STATE_DIR`, `SIMQ_HOST_LOCK`, `SIMQ_NO_AUTOSTART`, ...).
    public static let allowedPrefix = "SIMQ_"
    /// Never passed, even if a future allowlist widens (defense in depth).
    public static let deniedPrefixes = ["RUNNER_", "GITHUB_", "ACTIONS_"]

    /// The daemon's environment: the allowlist, minus anything runner-related. Jobs later
    /// get this environment plus their own `--env`, never the calling step's environment.
    public static func environment(from caller: [String: String]) -> [String: String] {
        caller.filter { key, _ in
            (allowedKeys.contains(key) || key.hasPrefix(allowedPrefix))
                && !deniedPrefixes.contains(where: { key.hasPrefix($0) })
        }
    }

    /// Spawns `argv` detached as described above. Returns the daemon's pid (its session id).
    public static func spawn(
        executable: String, argv: [String], callerEnvironment: [String: String], stateDir: String
    ) throws -> Int32 {
        try FileManager.default.createDirectory(
            atPath: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try ProcessSpawner.spawn(
            executable: executable, argv: argv + ["--log-file", logPath(stateDir: stateDir)],
            environment: environment(from: callerEnvironment), cwd: stateDir,
            outputPath: logPath(stateDir: stateDir), newSession: true)
    }

    public static func logPath(stateDir: String) -> String { stateDir + "/simqd.log" }
}
