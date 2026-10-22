// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore

/// Where SimQueue keeps its state. One directory (owner-only, 0700) holds the database,
/// the socket, the lock file and the optional config file.
public struct SimQueuePaths: Sendable, Equatable {
    public static let stateDirEnvironmentKey = "SIMQ_STATE_DIR"

    public var stateDir: String

    public init(stateDir: String) {
        self.stateDir = stateDir
    }

    public var databasePath: String { stateDir + "/simqueue.sqlite" }
    public var socketPath: String { stateDir + "/simq.sock" }
    public var lockPath: String { stateDir + "/simqd.lock" }
    public var configPath: String { stateDir + "/config.json" }

    public static let hostLockEnvironmentKey = "SIMQ_HOST_LOCK"

    /// The host-wide lock a real-sim daemon holds (one per user: CoreSimulator's device
    /// set, and so the `simq-` namespace, is per user, not per state directory).
    /// `$SIMQ_HOST_LOCK`, else `~/.simqueue/simqd-host.lock`; never inside a state dir.
    public static func hostLockPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment[hostLockEnvironmentKey], !path.isEmpty { return path }
        return (environment["HOME"] ?? NSHomeDirectory()) + "/.simqueue/simqd-host.lock"
    }
    /// Watchdog health, rewritten after every pass (`HealthInfo`).
    public var healthPath: String { stateDir + "/health.json" }
    public var runsRoot: String { stateDir + "/work" }
    /// Per-job logs and artifacts, kept after the job ends: `jobs/<YYYY-MM-DD>/<job-id>/`.
    public var jobsRoot: String { stateDir + "/jobs" }

    /// `$SIMQ_STATE_DIR`, else `~/Library/Application Support/SimQueue` on macOS and
    /// `$XDG_STATE_HOME/simqueue` (or `~/.local/state/simqueue`) elsewhere.
    public static func resolve(
        explicit: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SimQueuePaths {
        if let explicit, !explicit.isEmpty {
            return SimQueuePaths(stateDir: explicit)
        }
        if let fromEnvironment = environment[stateDirEnvironmentKey], !fromEnvironment.isEmpty {
            return SimQueuePaths(stateDir: fromEnvironment)
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        #if os(macOS)
            return SimQueuePaths(stateDir: home + "/Library/Application Support/SimQueue")
        #else
            let base = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/state"
            return SimQueuePaths(stateDir: base + "/simqueue")
        #endif
    }
}

/// Where a job's logs and artifacts live (spec section 5i): `<root>/<date>/<job-id>/`, with
/// the job's UTC submit date, `combined.log` (stdout and stderr) and `job.json` (the final
/// job record). Outside the managed work roots, so job teardown never deletes them.
public struct JobArtifacts: Sendable, Equatable {
    public var root: String
    public var legacyRoot: String?

    public init(root: String) {
        self.root = root.hasSuffix("/") ? String(root.dropLast()) : root
    }

    public func directory(jobID: String, createdAt: Double) -> String {
        "\(root)/\(Timestamp(createdAt).rfc3339.prefix(10))/\(jobID)"
    }

    public func directory(for job: Job) -> String {
        JobArtifacts(root: job.command?.artifactsRoot ?? legacyRoot ?? root)
            .directory(jobID: job.id, createdAt: job.createdAt)
    }

    public func logPath(for job: Job) -> String { directory(for: job) + "/combined.log" }
    public func summaryPath(for job: Job) -> String { directory(for: job) + "/job.json" }

    public func logPath(jobID: String, createdAt: Double) -> String {
        directory(jobID: jobID, createdAt: createdAt) + "/combined.log"
    }

    public func summaryPath(jobID: String, createdAt: Double) -> String {
        directory(jobID: jobID, createdAt: createdAt) + "/job.json"
    }
}
