// SPDX-License-Identifier: MIT

/// A job's priority: an integer the caller chooses. Higher runs first; equal priorities run
/// in submission order. SimQueue attaches no meaning to particular values.
public enum Priority {
    public static let range: ClosedRange<Int> = 0...100
    /// Used when the caller doesn't say.
    public static let defaultValue = 50

    public static func isValid(_ value: Int) -> Bool {
        range.contains(value)
    }
}

/// Optional names for priority values, defined by the user in config (for example
/// `urgent = 90`). Empty by default: SimQueue ships no named classes.
public struct PriorityAliases: Sendable, Equatable, Codable {
    public var values: [String: Int]

    /// Names are case-insensitive.
    public init(_ values: [String: Int] = [:]) {
        self.values = Dictionary(
            values.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// Resolves "75" or a defined alias to a priority in range.
    public func resolve(_ text: String) -> Int? {
        let trimmed = String(text.filter { !$0.isWhitespace })
        if let number = Int(trimmed) {
            return Priority.isValid(number) ? number : nil
        }
        guard let value = values[trimmed.lowercased()], Priority.isValid(value) else {
            return nil
        }
        return value
    }
}

/// Scores and orders queued jobs: priority plus a small aging boost so low-priority work
/// gain priority up to the configured cap, then FIFO tie-breaks (earlier queue time, then lower sequence).
public struct PriorityPolicy: Sendable, Equatable, Codable {
    /// Points added per minute waited. 0 disables aging.
    public var agingPointsPerMinute: Double
    /// Cap on the aging boost.
    public var maxBoost: Double

    public init(agingPointsPerMinute: Double = 0.5, maxBoost: Double = 25) {
        self.agingPointsPerMinute = agingPointsPerMinute
        self.maxBoost = maxBoost
    }

    /// Aging boost for a job, measured from its (possibly inherited) queue time.
    public func agingBoost(queueTime: Double, now: Double) -> Double {
        let waitedMinutes = max(0, now - queueTime) / 60
        return min(maxBoost, agingPointsPerMinute * waitedMinutes)
    }

    public func effectiveScore(of job: Job, now: Double) -> Double {
        Double(job.priority) + agingBoost(queueTime: job.queueTime, now: now)
    }

    /// Seconds a job at `lower` priority must wait before it ranks ahead of a freshly
    /// queued job at `higher` (equal scores go to the older job). Nil if aging can never
    /// close the gap.
    public func overtakeSeconds(lower: Int, higher: Int) -> Double? {
        let gap = Double(higher - lower)
        guard gap > 0 else {
            return 0
        }
        guard agingPointsPerMinute > 0, maxBoost >= gap else {
            return nil
        }
        return gap / agingPointsPerMinute * 60
    }

    /// Dispatch order: effective score (descending), then queue time (oldest first),
    /// then submit sequence (lowest first).
    public func isOrderedBefore(_ lhs: Job, _ rhs: Job, now: Double) -> Bool {
        let lhsScore = effectiveScore(of: lhs, now: now)
        let rhsScore = effectiveScore(of: rhs, now: now)
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }
        if lhs.queueTime != rhs.queueTime {
            return lhs.queueTime < rhs.queueTime
        }
        return lhs.sequence < rhs.sequence
    }

    public func order(_ jobs: [Job], now: Double) -> [Job] {
        jobs.sorted { isOrderedBefore($0, $1, now: now) }
    }
}
