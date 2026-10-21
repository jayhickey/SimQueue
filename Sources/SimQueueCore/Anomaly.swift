// SPDX-License-Identifier: MIT

/// How long a reconcile anomaly (a cleanup that failed, was refused, is rate-limited, or
/// would run but report-only mode holds it back) may persist before it escalates.
public struct AnomalyPolicy: Sendable, Equatable, Codable {
    /// Consecutive anomalous passes that make an anomaly `sustained`.
    public var sustainedAfterPasses: Int
    /// Age that makes an anomaly `sustained`, whatever the pass count.
    public var sustainedAfterSeconds: Double
    /// Age that makes an anomaly `needs_human`.
    public var needsHumanAfterSeconds: Double
    /// Clean passes in a row that clear an anomaly. A single clean pass doesn't reset it.
    public var clearAfterCleanPasses: Int

    public init(
        sustainedAfterPasses: Int = 4,
        sustainedAfterSeconds: Double = 60 * 60,
        needsHumanAfterSeconds: Double = 24 * 60 * 60,
        clearAfterCleanPasses: Int = 2
    ) {
        self.sustainedAfterPasses = sustainedAfterPasses
        self.sustainedAfterSeconds = sustainedAfterSeconds
        self.needsHumanAfterSeconds = needsHumanAfterSeconds
        self.clearAfterCleanPasses = clearAfterCleanPasses
    }
}

public enum AnomalyLevel: String, Sendable, Codable, CaseIterable, Comparable {
    case observed
    case sustained
    case needsHuman = "needs_human"

    private var rank: Int {
        switch self {
        case .observed: return 0
        case .sustained: return 1
        case .needsHuman: return 2
        }
    }

    public static func < (lhs: AnomalyLevel, rhs: AnomalyLevel) -> Bool { lhs.rank < rhs.rank }
}

public struct AnomalyRecord: Sendable, Equatable, Codable {
    public var key: String
    public var detail: String
    public var firstSeenAt: Double
    public var lastSeenAt: Double
    public var consecutivePasses: Int
    public var cleanPasses: Int
    public var level: AnomalyLevel

    public init(
        key: String,
        detail: String,
        firstSeenAt: Double,
        lastSeenAt: Double,
        consecutivePasses: Int,
        cleanPasses: Int = 0,
        level: AnomalyLevel = .observed
    ) {
        self.key = key
        self.detail = detail
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.consecutivePasses = consecutivePasses
        self.cleanPasses = cleanPasses
        self.level = level
    }
}

public struct AnomalyUpdate: Sendable, Equatable {
    public var records: [AnomalyRecord]
    /// Anomalies whose level went up on this pass (new level in the record).
    public var escalated: [AnomalyRecord]
    /// Anomalies cleared by enough clean passes.
    public var cleared: [AnomalyRecord]
}

/// Pure state machine, one step per reconcile pass. Levels only rise while an anomaly
/// persists; it is cleared after `clearAfterCleanPasses` clean passes in a row.
public enum AnomalyTracker {
    public static func step(
        previous: [AnomalyRecord],
        seen: [String: String],
        now: Double,
        policy: AnomalyPolicy
    ) -> AnomalyUpdate {
        var byKey = Dictionary(previous.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var escalated: [AnomalyRecord] = []
        var cleared: [AnomalyRecord] = []

        for (key, detail) in seen {
            var record =
                byKey[key]
                ?? AnomalyRecord(key: key, detail: detail, firstSeenAt: now, lastSeenAt: now, consecutivePasses: 0)
            record.detail = detail
            record.lastSeenAt = now
            record.consecutivePasses += 1
            record.cleanPasses = 0
            let age = now - record.firstSeenAt
            var level = AnomalyLevel.observed
            if age >= policy.needsHumanAfterSeconds {
                level = .needsHuman
            } else if record.consecutivePasses >= policy.sustainedAfterPasses || age >= policy.sustainedAfterSeconds {
                level = .sustained
            }
            if level > record.level {
                record.level = level
                escalated.append(record)
            }
            byKey[key] = record
        }
        for (key, var record) in byKey where seen[key] == nil {
            record.cleanPasses += 1
            if record.cleanPasses >= policy.clearAfterCleanPasses {
                byKey[key] = nil
                cleared.append(record)
            } else {
                byKey[key] = record
            }
        }
        let sortedRecords = byKey.values.sorted { $0.key < $1.key }
        return AnomalyUpdate(
            records: sortedRecords,
            escalated: escalated.sorted { $0.key < $1.key },
            cleared: cleared.sorted { $0.key < $1.key }
        )
    }
}
