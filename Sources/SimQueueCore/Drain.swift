// SPDX-License-Identifier: MIT

/// Infra-failure drain, borrowed from XCSteward: after `limit` infra failures inside
/// `windowSeconds`, stop admitting until the failures age out or an operator resumes.
public struct InfraDrainPolicy: Sendable, Equatable {
    /// 0 disables the drain. Default 3 is a placeholder (XCSteward has no default either).
    public var limit: Int
    /// Default 15 minutes. Placeholder.
    public var windowSeconds: Double

    public init(limit: Int = 3, windowSeconds: Double = 15 * 60) {
        self.limit = limit
        self.windowSeconds = windowSeconds
    }

    /// - Parameters:
    ///   - failureTimes: finish times of jobs whose result class is an infra failure.
    ///   - clearedAt: when an operator last resumed; earlier failures don't count.
    public func status(failureTimes: [Double], clearedAt: Double?, now: Double) -> DrainStatus {
        guard limit > 0 else {
            return .normal
        }
        let since = max(now - windowSeconds, clearedAt ?? -Double.infinity)
        let recent = failureTimes.filter { $0 >= since && $0 <= now }.count
        return recent >= limit ? .draining(recentInfraFailures: recent) : .normal
    }
}

/// Restart-loop breaker: after `limit` unplanned daemon starts inside `windowSeconds`,
/// stop admitting until an operator resumes or the starts age out.
///
/// A restart requeues the jobs that were running, and those requeues do not feed the
/// infra-failure drain (a restart says nothing about the next job). Without this, a
/// daemon that keeps dying would keep admitting work and run each job once per restart
/// up to its restart cap. A start is unplanned when the previous daemon left no stop
/// record or recorded a failure; a requested stop (signal, stop request) is planned and
/// never counts, so drain-and-restart upgrades are unaffected.
public struct RestartBreakerPolicy: Sendable, Equatable {
    /// 0 disables the breaker. Default 3.
    public var limit: Int
    /// Default 15 minutes.
    public var windowSeconds: Double

    /// Audit type written at each unplanned daemon start.
    public static let auditType = "daemon_unplanned_restart"

    public init(limit: Int = 3, windowSeconds: Double = 15 * 60) {
        self.limit = limit
        self.windowSeconds = windowSeconds
    }

    /// - Parameters:
    ///   - restartTimes: when each unplanned start happened.
    ///   - clearedAt: when an operator last resumed; earlier starts don't count.
    public func status(restartTimes: [Double], clearedAt: Double?, now: Double) -> RestartBreakerStatus {
        guard limit > 0 else { return .normal }
        let since = max(now - windowSeconds, clearedAt ?? -Double.infinity)
        let recent = restartTimes.filter { $0 >= since && $0 <= now }.count
        return recent >= limit ? .tripped(restarts: recent, windowSeconds: windowSeconds) : .normal
    }
}

public enum RestartBreakerStatus: Sendable, Equatable {
    case normal
    case tripped(restarts: Int, windowSeconds: Double)
}

public enum DrainStatus: Sendable, Equatable {
    case normal
    case draining(recentInfraFailures: Int)
}

/// Operator controls persisted in the store.
public struct QueueControl: Sendable, Equatable {
    /// `simq pause`: admit nothing until resumed.
    public var paused: Bool
    /// Last `simq resume`; infra failures before this don't count toward the drain.
    public var drainClearedAt: Double?

    public init(paused: Bool = false, drainClearedAt: Double? = nil) {
        self.paused = paused
        self.drainClearedAt = drainClearedAt
    }
}
