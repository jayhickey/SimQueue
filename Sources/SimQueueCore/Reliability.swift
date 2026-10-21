// SPDX-License-Identifier: MIT

/// Whether cleanup actually destroys anything. `reportOnly` (the default, and the mode
/// for the shadow week) plans and audits every action but performs no destructive one.
public enum CleanupMode: String, Sendable, Codable, CaseIterable {
    case reportOnly = "report-only"
    case enforce
}

/// Lets SimQueue act on specific resources outside its own namespace (for example a
/// legacy sim naming scheme being migrated). Disabled by default; when disabled, foreign
/// resources are only ever reported. Matching is by explicit prefix, set by an operator.
public struct ForeignResourceAllowlist: Sendable, Equatable, Codable {
    public var enabled: Bool
    public var simNamePrefixes: [String]

    public init(enabled: Bool = false, simNamePrefixes: [String] = []) {
        self.enabled = enabled
        self.simNamePrefixes = simNamePrefixes
    }

    public func allowsSim(named name: String) -> Bool {
        enabled && simNamePrefixes.contains { !$0.isEmpty && name.hasPrefix($0) }
    }
}

/// Configurable reliability defaults for cleanup and resource supervision.
public struct ReliabilityConfig: Sendable, Equatable, Codable {
    public var cleanupMode: CleanupMode
    /// A cleanup candidate must stay orphaned this long before anything destructive runs.
    public var orphanGraceSeconds: Double
    /// Pool sims idle (booted, unused) longer than this are shut down, beyond `warm_min`.
    public var idleShutdownSeconds: Double
    /// Pool sims older than this are recycled (deleted and re-cloned) when idle.
    public var recycleAfterSeconds: Double
    public var maxDestructiveActionsPerPass: Int
    public var maxDestructiveActionsPerHour: Int
    public var foreignAllowlist: ForeignResourceAllowlist
    public var anomalies: AnomalyPolicy
    /// Per-kind age limits (spec §8a.3). Process groups and work directories use these
    /// instead of `orphanGraceSeconds`.
    public var ageRules: AgeRules

    public init(
        cleanupMode: CleanupMode = .reportOnly,
        orphanGraceSeconds: Double = 10 * 60,
        idleShutdownSeconds: Double = 30 * 60,
        recycleAfterSeconds: Double = 7 * 24 * 60 * 60,
        maxDestructiveActionsPerPass: Int = 3,
        maxDestructiveActionsPerHour: Int = 10,
        foreignAllowlist: ForeignResourceAllowlist = ForeignResourceAllowlist(),
        anomalies: AnomalyPolicy = AnomalyPolicy(),
        ageRules: AgeRules = AgeRules()
    ) {
        self.ageRules = ageRules
        self.cleanupMode = cleanupMode
        self.orphanGraceSeconds = orphanGraceSeconds
        self.idleShutdownSeconds = idleShutdownSeconds
        self.recycleAfterSeconds = recycleAfterSeconds
        self.maxDestructiveActionsPerPass = maxDestructiveActionsPerPass
        self.maxDestructiveActionsPerHour = maxDestructiveActionsPerHour
        self.foreignAllowlist = foreignAllowlist
        self.anomalies = anomalies
    }
}

extension ReconcileAction {
    /// Kills, deletes or removes something on the host.
    public var isDestructive: Bool {
        switch self {
        case .killProcessGroup, .deleteSim, .removeDirectory: return true
        case .markGone, .adopt, .revokeLease, .reportForeignSim: return false
        }
    }

    /// Stable key for the thing the action targets (used for grace-period tracking).
    public var targetKey: String? {
        switch self {
        case .killProcessGroup(let pgid, _): return "process_group:\(pgid)"
        case .deleteSim(let udid, _): return "sim:\(udid)"
        case .removeDirectory(let path, _): return "dir:\(path)"
        case .markGone, .adopt, .revokeLease, .reportForeignSim: return nil
        }
    }
}

extension ReconcileAction {
    /// Key under which the engine tracks first-seen time: destructive targets plus
    /// foreign sims (so each is reported once, not every pass).
    public var sightingKey: String? {
        if case .reportForeignSim(let udid, _) = self {
            return "foreign_sim:\(udid)"
        }
        return targetKey
    }
}

public enum CleanupDecision: Sendable, Equatable {
    case execute
    /// Report-only mode: would have executed.
    case wouldExecute
    case deferGrace(remainingSeconds: Double)
    case deferRateLimit
}

/// Decides, for each destructive action in a pass, whether it may run now. Pure.
public struct CleanupGate: Sendable {
    public var config: ReliabilityConfig
    /// Destructive actions already executed in the last hour (from the audit log).
    public private(set) var executedLastHour: Int
    public private(set) var executedThisPass = 0
    /// The hourly limit held an action back on this pass (trips the breaker).
    public private(set) var hourlyLimitHit = false

    public init(config: ReliabilityConfig, executedLastHour: Int, executedThisPass: Int = 0) {
        self.config = config
        self.executedLastHour = executedLastHour
        self.executedThisPass = executedThisPass
    }

    /// - Parameters:
    ///   - firstSeenAt: when this target first became a cleanup candidate.
    ///   - graceSeconds: the target's grace period (an age rule); nil uses `orphanGraceSeconds`.
    public mutating func decide(firstSeenAt: Double, now: Double, graceSeconds: Double? = nil) -> CleanupDecision {
        let waited = now - firstSeenAt
        let grace = graceSeconds ?? config.orphanGraceSeconds
        if waited < grace {
            return .deferGrace(remainingSeconds: grace - waited)
        }
        if config.cleanupMode == .reportOnly {
            return .wouldExecute
        }
        guard executedLastHour < config.maxDestructiveActionsPerHour else {
            hourlyLimitHit = true
            return .deferRateLimit
        }
        guard executedThisPass < config.maxDestructiveActionsPerPass else {
            return .deferRateLimit
        }
        executedThisPass += 1
        executedLastHour += 1
        return .execute
    }
}

/// One pool sim as the pool manager sees it.
public struct PoolSimState: Sendable, Equatable {
    public var udid: String
    public var isBooted: Bool
    public var isBusy: Bool
    public var createdAt: Double
    /// Last time a job released it (or when it finished booting).
    public var lastUsedAt: Double

    public init(udid: String, isBooted: Bool, isBusy: Bool, createdAt: Double, lastUsedAt: Double) {
        self.udid = udid
        self.isBooted = isBooted
        self.isBusy = isBusy
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public enum PoolMaintenanceAction: Sendable, Equatable {
    /// Not destructive: the sim stays, just shut down.
    case shutdown(udid: String)
    /// Destructive: delete and re-clone. Goes through `CleanupGate` limits when executed.
    case recycle(udid: String)
}

/// Idle shutdown and age-based recycling (executed by the pool manager in a later phase).
public enum PoolMaintenance {
    public static func plan(sims: [PoolSimState], warmMin: Int, config: ReliabilityConfig, now: Double)
        -> [PoolMaintenanceAction]
    {
        var actions: [PoolMaintenanceAction] = []
        let idle = sims.filter { !$0.isBusy }
        var recycled = Set<String>()
        for sim in idle.sorted(by: { ($0.createdAt, $0.udid) < ($1.createdAt, $1.udid) })
        where now - sim.createdAt >= config.recycleAfterSeconds {
            actions.append(.recycle(udid: sim.udid))
            recycled.insert(sim.udid)
        }
        // Keep the `warmMin` most recently used idle booted sims warm.
        let bootedIdle = idle.filter { $0.isBooted && !recycled.contains($0.udid) }
            .sorted { ($0.lastUsedAt, $0.udid) > ($1.lastUsedAt, $1.udid) }
        for sim in bootedIdle.dropFirst(max(0, warmMin)) where now - sim.lastUsedAt >= config.idleShutdownSeconds {
            actions.append(.shutdown(udid: sim.udid))
        }
        return actions
    }
}
