// SPDX-License-Identifier: MIT

/// Watchdog passes (spec §8a.2): a light pass (process groups and leases) every minute and
/// a full pass (everything reconcile checks) every 15 minutes. Each pass has an id that
/// lands on every audit entry it writes.
public enum WatchdogPassKind: String, Sendable, Codable, CaseIterable {
    case light
    case full

    /// Whether a reconcile target (anomaly or sighting key) is checked by this kind of pass.
    public func covers(targetKey key: String) -> Bool {
        switch self {
        case .full: return true
        case .light: return key.hasPrefix("process_group:")
        }
    }

    /// The one target-key prefix this kind covers (nil: every key).
    public var targetKeyPrefix: String? {
        switch self {
        case .full: return nil
        case .light: return "process_group:"
        }
    }
}

public struct BreakerPolicy: Sendable, Equatable, Codable {
    /// The same target acted on twice within this window trips the breaker.
    public var repeatWindowSeconds: Double
    /// This many failed cleanup actions in a row trip the breaker.
    public var maxConsecutiveFailures: Int
    /// An open breaker half-opens (allows one action) after this long.
    public var halfOpenAfterSeconds: Double

    public init(
        repeatWindowSeconds: Double = 60 * 60, maxConsecutiveFailures: Int = 3, halfOpenAfterSeconds: Double = 60 * 60
    ) {
        self.repeatWindowSeconds = repeatWindowSeconds
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.halfOpenAfterSeconds = halfOpenAfterSeconds
    }
}

public struct WatchdogConfig: Sendable, Equatable, Codable {
    public var lightIntervalSeconds: Double
    public var fullIntervalSeconds: Double
    public var breaker: BreakerPolicy
    public var alerts: AlertPolicy

    public init(
        lightIntervalSeconds: Double = 60, fullIntervalSeconds: Double = 15 * 60,
        breaker: BreakerPolicy = BreakerPolicy(), alerts: AlertPolicy = AlertPolicy()
    ) {
        self.lightIntervalSeconds = lightIntervalSeconds
        self.fullIntervalSeconds = fullIntervalSeconds
        self.breaker = breaker
        self.alerts = alerts
    }

    /// The pass due now, if any. A full pass also covers what a light pass would.
    public func due(lastLightAt: Double?, lastFullAt: Double?, now: Double) -> WatchdogPassKind? {
        if lastFullAt.map({ now - $0 >= fullIntervalSeconds }) ?? true { return .full }
        let lastAny = max(lastLightAt ?? -.infinity, lastFullAt ?? -.infinity)
        return now - lastAny >= lightIntervalSeconds ? .light : nil
    }
}

public enum BreakerPhase: String, Sendable, Codable {
    /// Normal: actions run within the configured limits.
    case closed
    /// Tripped: the watchdog is report-only.
    case open
    /// Probation: one destructive action may run; success closes, failure reopens.
    case halfOpen = "half-open"
}

public struct BreakerState: Sendable, Equatable, Codable {
    public var phase: BreakerPhase
    public var reason: String?
    public var openedAt: Double?
    public var consecutiveFailures: Int
    /// Target key -> last time a destructive action ran on it (within the repeat window).
    public var recentActions: [String: Double]

    public init(
        phase: BreakerPhase = .closed, reason: String? = nil, openedAt: Double? = nil, consecutiveFailures: Int = 0,
        recentActions: [String: Double] = [:]
    ) {
        self.phase = phase
        self.reason = reason
        self.openedAt = openedAt
        self.consecutiveFailures = consecutiveFailures
        self.recentActions = recentActions
    }

    enum CodingKeys: String, CodingKey {
        case phase, reason
        case openedAt = "opened_at"
        case consecutiveFailures = "consecutive_failures"
        case recentActions = "recent_actions"
    }
}

/// What a pass did, as far as the breaker cares.
public struct BreakerPassOutcome: Sendable, Equatable {
    /// Targets of destructive actions that ran and were verified.
    public var executedTargets: [String]
    /// Destructive actions that failed or could not be verified.
    public var failures: Int

    public init(executedTargets: [String] = [], failures: Int = 0) {
        self.executedTargets = executedTargets
        self.failures = failures
    }
}

public enum BreakerTransition: Sendable, Equatable {
    case opened(reason: String)
    case halfOpened
    case closed
}

/// Circuit breaker for destructive watchdog actions (spec §8a.2, updated 10/19). Pure.
/// Opens only when the same target is acted on twice within the repeat window or after N
/// failures in a row. A backlog that hits the per-pass or hourly limit is not thrash: the
/// rest is postponed to the next window (logged, shown in health), never a trip. While open, passes are report-only.
/// After `halfOpenAfterSeconds` it half-opens and allows one action; a clean action
/// closes it, a failure (or another trip) reopens it.
public enum Breaker {
    /// Time-based transition, applied at the start of a pass.
    public static func advance(_ state: BreakerState, now: Double, policy: BreakerPolicy) -> (
        BreakerState, BreakerTransition?
    ) {
        var state = state
        state.recentActions = state.recentActions.filter { now - $0.value < policy.repeatWindowSeconds }
        if state.phase == .open, let openedAt = state.openedAt, now - openedAt >= policy.halfOpenAfterSeconds {
            state.phase = .halfOpen
            return (state, .halfOpened)
        }
        return (state, nil)
    }

    /// Adjusts the pass's cleanup limits for the breaker phase.
    public static func limit(_ config: ReliabilityConfig, phase: BreakerPhase) -> ReliabilityConfig {
        var config = config
        switch phase {
        case .closed: break
        case .open: config.cleanupMode = .reportOnly
        case .halfOpen: config.maxDestructiveActionsPerPass = min(config.maxDestructiveActionsPerPass, 1)
        }
        return config
    }

    /// Applies a pass's outcome.
    public static func record(
        _ outcome: BreakerPassOutcome, state: BreakerState, now: Double, policy: BreakerPolicy
    ) -> (BreakerState, BreakerTransition?) {
        var state = state
        var trip: String?
        for target in outcome.executedTargets {
            if let last = state.recentActions[target], now - last < policy.repeatWindowSeconds {
                trip = trip ?? "acted on \(target) twice within \(Int(policy.repeatWindowSeconds / 60)) min"
            }
            state.recentActions[target] = now
        }
        if outcome.failures > 0 {
            state.consecutiveFailures += outcome.failures
        } else if !outcome.executedTargets.isEmpty {
            state.consecutiveFailures = 0
        }
        if state.consecutiveFailures >= policy.maxConsecutiveFailures {
            trip = trip ?? "\(state.consecutiveFailures) cleanup failures in a row"
        }
        if state.phase == .halfOpen, trip == nil, outcome.failures > 0 {
            trip = "cleanup failed while half-open"
        }
        if let trip {
            let wasOpen = state.phase == .open
            state.phase = .open
            state.reason = trip
            state.openedAt = now
            return (state, wasOpen ? nil : .opened(reason: trip))
        }
        if state.phase == .halfOpen, !outcome.executedTargets.isEmpty {
            state = BreakerState(recentActions: state.recentActions)
            return (state, .closed)
        }
        return (state, nil)
    }
}

/// Overall health for `health.json`, `simq status` and `simq doctor`.
public enum HealthLevel: String, Sendable, Codable {
    case ok
    case degraded
    case breakerOpen = "breaker_open"
}

/// The watchdog's persisted state (one row).
public struct WatchdogState: Sendable, Equatable, Codable {
    public var breaker: BreakerState
    public var passCount: Int64
    public var lastPassID: String?
    public var lastPassKind: WatchdogPassKind?
    public var lastPassAt: Double?
    public var lastLightPassAt: Double?
    public var lastFullPassAt: Double?
    /// Targets whose cleanup the per-pass or hourly limit postponed to a later pass.
    public var postponedTargets: [String]
    /// Why the last attempted pass failed (a hung or failing backend, a database error).
    /// Cleared by the next pass that completes.
    public var lastPassError: String?
    public var lastPassErrorAt: Double?

    public init(
        breaker: BreakerState = BreakerState(), passCount: Int64 = 0, lastPassID: String? = nil,
        lastPassKind: WatchdogPassKind? = nil, lastPassAt: Double? = nil, lastLightPassAt: Double? = nil,
        lastFullPassAt: Double? = nil, postponedTargets: [String] = []
    ) {
        self.breaker = breaker
        self.passCount = passCount
        self.lastPassID = lastPassID
        self.lastPassKind = lastPassKind
        self.lastPassAt = lastPassAt
        self.lastLightPassAt = lastLightPassAt
        self.lastFullPassAt = lastFullPassAt
        self.postponedTargets = postponedTargets
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        breaker = try container.decode(BreakerState.self, forKey: .breaker)
        passCount = try container.decode(Int64.self, forKey: .passCount)
        lastPassID = try container.decodeIfPresent(String.self, forKey: .lastPassID)
        lastPassKind = try container.decodeIfPresent(WatchdogPassKind.self, forKey: .lastPassKind)
        lastPassAt = try container.decodeIfPresent(Double.self, forKey: .lastPassAt)
        lastLightPassAt = try container.decodeIfPresent(Double.self, forKey: .lastLightPassAt)
        lastFullPassAt = try container.decodeIfPresent(Double.self, forKey: .lastFullPassAt)
        postponedTargets = try container.decodeIfPresent([String].self, forKey: .postponedTargets) ?? []
        lastPassError = try container.decodeIfPresent(String.self, forKey: .lastPassError)
        lastPassErrorAt = try container.decodeIfPresent(Double.self, forKey: .lastPassErrorAt)
    }

    enum CodingKeys: String, CodingKey {
        case breaker
        case passCount = "pass_count"
        case lastPassID = "last_pass_id"
        case lastPassKind = "last_pass_kind"
        case lastPassAt = "last_pass_at"
        case lastLightPassAt = "last_light_pass_at"
        case lastFullPassAt = "last_full_pass_at"
        case postponedTargets = "postponed_targets"
        case lastPassError = "last_pass_error"
        case lastPassErrorAt = "last_pass_error_at"
    }
}

/// One health verdict, shared by `health.json`, `simq status` and `simq doctor`.
public struct HealthSummary: Sendable, Equatable {
    public var level: HealthLevel
    public var reasons: [String]
    /// Worth showing, but not a problem (for example postponed cleanups).
    public var notes: [String]

    public init(level: HealthLevel, reasons: [String], notes: [String] = []) {
        self.level = level
        self.reasons = reasons
        self.notes = notes
    }

    /// - breaker open: `breaker_open`;
    /// - breaker half-open, sustained or needs-human anomalies, the infra drain, or no
    ///   watchdog pass within `staleAfterSeconds`: `degraded`;
    /// - otherwise `ok`.
    /// Postponed cleanups (a backlog held by the rate limits) are a note, never a reason.
    public static func evaluate(
        breaker: BreakerState, anomalies: [AnomalyRecord], draining: Bool, lastPassAt: Double?, now: Double,
        staleAfterSeconds: Double, postponed: Int = 0, lastPassError: String? = nil
    ) -> HealthSummary {
        var reasons: [String] = []
        switch breaker.phase {
        case .open: reasons.append("breaker open: \(breaker.reason ?? "unknown")")
        case .halfOpen: reasons.append("breaker half-open: \(breaker.reason ?? "unknown")")
        case .closed: break
        }
        let needsHuman = anomalies.reduce(0) { $0 + ($1.level == .needsHuman ? 1 : 0) }
        let sustained = anomalies.reduce(0) { $0 + ($1.level == .sustained ? 1 : 0) }
        if needsHuman > 0 { reasons.append("\(needsHuman) anomal\(needsHuman == 1 ? "y needs" : "ies need") a human") }
        if sustained > 0 { reasons.append("\(sustained) sustained anomal\(sustained == 1 ? "y" : "ies")") }
        if draining { reasons.append("infra drain active") }
        if let lastPassError { reasons.append("last watchdog pass failed: \(lastPassError)") }
        if let lastPassAt {
            if now - lastPassAt > staleAfterSeconds { reasons.append("no watchdog pass for \(Int(now - lastPassAt))s") }
        } else if staleAfterSeconds.isFinite {
            reasons.append("no watchdog pass yet")
        }
        let level: HealthLevel = breaker.phase == .open ? .breakerOpen : reasons.isEmpty ? .ok : .degraded
        let notes =
            postponed > 0 ? ["\(postponed) cleanup\(postponed == 1 ? "" : "s") postponed to the next window"] : []
        return HealthSummary(level: level, reasons: reasons, notes: notes)
    }
}
