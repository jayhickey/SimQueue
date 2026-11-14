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

/// Restart-loop breaker: while `limit` unplanned daemon starts fall inside the last
/// `windowSeconds`, nothing is admitted.
///
/// A restart requeues the jobs that were running, and those requeues do not feed the
/// infra-failure drain (a restart says nothing about the next job). Without this, a
/// daemon that keeps dying would keep admitting work and run each job once per restart
/// up to its restart cap. A start is unplanned when the previous daemon left no stop
/// record or recorded a failure; a requested stop (signal, stop request) is planned and
/// never counts, so drain-and-restart upgrades are unaffected.
///
/// The hold is not a latch. It lifts by itself as soon as the oldest of those starts is
/// older than the window, so an unattended host resumes work once the daemon has stayed
/// up; `simq resume` lifts it at once by forgetting the starts so far. A further
/// unplanned start inside the window brings it back.
///
/// The default limit is deliberately above the per-job restart cap. One job that takes
/// the daemon down every time it is admitted is ended `infra_failed` by its fourth
/// restart (`JobStore.defaultMaxRestartRequeues` requeues, then the cap), which is four
/// unplanned starts: the cap removes that job before the breaker would hold everyone
/// else. Five starts in the window means the restarts are not one job's doing.
public struct RestartBreakerPolicy: Sendable, Equatable {
    /// 0 disables the breaker. Default 5.
    public var limit: Int
    /// Default 15 minutes.
    public var windowSeconds: Double

    /// Audit type written at each unplanned daemon start.
    public static let auditType = "daemon_unplanned_restart"

    public init(limit: Int = 5, windowSeconds: Double = 15 * 60) {
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
    /// Last `simq resume`; infra failures and unplanned daemon restarts before this
    /// don't count toward the drain or the restart-loop breaker.
    public var drainClearedAt: Double?

    public init(paused: Bool = false, drainClearedAt: Double? = nil) {
        self.paused = paused
        self.drainClearedAt = drainClearedAt
    }
}
