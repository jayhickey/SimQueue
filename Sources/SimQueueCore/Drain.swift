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
