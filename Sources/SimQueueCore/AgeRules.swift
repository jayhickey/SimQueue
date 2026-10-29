// SPDX-License-Identifier: MIT

/// "Nothing should be older than…" (spec §8a.3). Every default is per-host config.
/// Rules that act go through the same gate as reconcile (cleanup mode, limits, breaker);
/// the queued-job and foreign rules only report.
public struct AgeRules: Sendable, Equatable, Codable {
    /// An owned process group whose job is no longer running is stopped after this long.
    public var orphanProcessSeconds: Double
    /// An owned run or DerivedData work directory is removed this long after its job ends.
    public var workDirAfterJobSeconds: Double
    /// An external lease older than this is revoked, even if its holder still looks alive.
    public var leaseMaxAgeSeconds: Double
    /// A job queued longer than this raises a `warn` alert. It is never canceled.
    public var queuedAlertSeconds: Double
    /// Job logs and artifacts (`jobs/<date>/<id>/`) are kept this long after the job ends.
    public var artifactRetention: ArtifactRetention
    /// A foreign booted sim seen this long appears in local doctor diagnostics. Report only.
    public var foreignBootedSimReportSeconds: Double

    public init(
        orphanProcessSeconds: Double = 2 * 60,
        workDirAfterJobSeconds: Double = 60 * 60,
        leaseMaxAgeSeconds: Double = 2700,
        queuedAlertSeconds: Double = 6 * 60 * 60,
        artifactRetention: ArtifactRetention = ArtifactRetention(),
        foreignBootedSimReportSeconds: Double = 24 * 60 * 60
    ) {
        self.orphanProcessSeconds = orphanProcessSeconds
        self.workDirAfterJobSeconds = workDirAfterJobSeconds
        self.leaseMaxAgeSeconds = leaseMaxAgeSeconds
        self.queuedAlertSeconds = queuedAlertSeconds
        self.artifactRetention = artifactRetention
        self.foreignBootedSimReportSeconds = foreignBootedSimReportSeconds
    }

    /// How long a cleanup target must stay a candidate before anything destructive runs:
    /// the age rule for its kind, else the general orphan grace (sims).
    public func graceSeconds(forTargetKey key: String, default fallback: Double) -> Double {
        if key.hasPrefix("process_group:") { return orphanProcessSeconds }
        if key.hasPrefix("dir:") { return workDirAfterJobSeconds }
        return fallback
    }
}

/// Retention for job logs and artifacts, by how the job ended.
public struct ArtifactRetention: Sendable, Equatable, Codable {
    public var succeededSeconds: Double
    /// Failed, timed out, canceled, interrupted, expired or infra-failed.
    public var otherSeconds: Double
    /// A directory with no job record (pruned, or from another daemon's database).
    public var unknownSeconds: Double
    /// Most directories removed in one full pass; the rest wait for the next one.
    public var maxRemovalsPerPass: Int
    /// A job's `DerivedData` (`SIMQ_DERIVED_DATA`) is removed this long after the job ended,
    /// before the rest of its directory (build products are large and rarely needed later).
    public var derivedDataSeconds: Double
    /// Total size budget for the jobs directory. Past it, ended jobs' directories are removed
    /// oldest first (passes before failures, never `--keep` jobs, never a failure younger than
    /// `failedBudgetFloorSeconds`) until it fits. Nil: none.
    public var budgetBytes: UInt64?
    /// How long a `--keep` job's directory stays (it's also exempt from the budget). Nil:
    /// `defaultKeptSeconds`.
    public var keptSeconds: Double?

    public static let defaultKeptSeconds: Double = 90 * 86_400
    /// The size budget never removes a job that didn't succeed until this long after it ended,
    /// so a red run's results survive a full budget (age retention still applies).
    public static let failedBudgetFloorSeconds: Double = 86_400
    public var keptRetentionSeconds: Double { keptSeconds ?? Self.defaultKeptSeconds }

    public init(
        succeededSeconds: Double = 7 * 86_400, otherSeconds: Double = 14 * 86_400, unknownSeconds: Double = 30 * 86_400,
        maxRemovalsPerPass: Int = 20, derivedDataSeconds: Double = 86_400, budgetBytes: UInt64? = nil,
        keptSeconds: Double? = nil
    ) {
        self.budgetBytes = budgetBytes
        self.keptSeconds = keptSeconds
        self.succeededSeconds = succeededSeconds
        self.otherSeconds = otherSeconds
        self.unknownSeconds = unknownSeconds
        self.maxRemovalsPerPass = maxRemovalsPerPass
        self.derivedDataSeconds = derivedDataSeconds
    }

    /// Seconds to keep a job's directory after `endedAt`; nil while the job is active.
    public func keepSeconds(for state: JobState?, pinned: Bool = false) -> Double? {
        guard let state else { return unknownSeconds }
        guard state.isTerminal else { return nil }
        if pinned { return max(keptRetentionSeconds, state == .succeeded ? succeededSeconds : otherSeconds) }
        return state == .succeeded ? succeededSeconds : otherSeconds
    }
}
