// SPDX-License-Identifier: MIT
import Foundation

public enum AlertLevel: String, Sendable, Codable, Comparable {
    case warn, page
    public static func < (lhs: AlertLevel, rhs: AlertLevel) -> Bool { lhs == .warn && rhs == .page }
}
public struct AlertEvent: Sendable, Equatable {
    public var key: String; public var level: AlertLevel; public var title: String; public var detail: String;
    public var needsHuman: Bool
    public init(key: String, level: AlertLevel, title: String, detail: String, needsHuman: Bool = false) {
        self.key = key; self.level = level; self.title = title; self.detail = detail; self.needsHuman = needsHuman
    }
}
public struct AlertPolicy: Sendable, Equatable, Codable {
    public var closeAfterCleanFullPasses: Int
    public init(closeAfterCleanFullPasses: Int = 2) { self.closeAfterCleanFullPasses = closeAfterCleanFullPasses }
}
/// Local current-health diagnostics. Legacy delivery keys are ignored when old rows decode.
public struct AlertRecord: Sendable, Equatable, Codable {
    public var key: String; public var level: AlertLevel; public var title: String; public var detail: String
    public var count: Int; public var firstSeenAt: Double; public var lastSeenAt: Double; public var needsHuman: Bool
    public var cleanPasses: Int; public var resolvedAt: Double?
    public init(event: AlertEvent, now: Double) {
        key = event.key; level = event.level; title = event.title; detail = event.detail; count = 1
        firstSeenAt = now; lastSeenAt = now; needsHuman = event.needsHuman; cleanPasses = 0; resolvedAt = nil
    }
    public var isResolved: Bool { resolvedAt != nil }
    enum CodingKeys: String, CodingKey {
        case key, level, title, detail, count
        case firstSeenAt = "first_seen_at", lastSeenAt = "last_seen_at", needsHuman = "needs_human", cleanPasses =
            "clean_passes", resolvedAt = "resolved_at"
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key); level = try c.decode(AlertLevel.self, forKey: .level)
        title = try c.decode(String.self, forKey: .title); detail = try c.decode(String.self, forKey: .detail);
        count = try c.decode(Int.self, forKey: .count)
        firstSeenAt = try c.decode(Double.self, forKey: .firstSeenAt);
        lastSeenAt = try c.decode(Double.self, forKey: .lastSeenAt)
        needsHuman = try c.decode(Bool.self, forKey: .needsHuman);
        cleanPasses = try c.decodeIfPresent(Int.self, forKey: .cleanPasses) ?? 0
        resolvedAt = try c.decodeIfPresent(Double.self, forKey: .resolvedAt)
    }
}
public enum AlertBook {
    public static func record(_ event: AlertEvent, into existing: AlertRecord?, now: Double, policy: AlertPolicy)
        -> AlertRecord
    {
        guard var r = existing else { return AlertRecord(event: event, now: now) }
        r.level = max(r.level, event.level); r.title = event.title; r.detail = event.detail; r.count += 1;
        r.lastSeenAt = now
        r.cleanPasses = 0; r.resolvedAt = nil; r.needsHuman = r.needsHuman || event.needsHuman
        return r
    }
    public static func clearance(_ record: AlertRecord, active: Bool, now: Double, policy: AlertPolicy) -> AlertRecord?
    {
        guard !record.isResolved else { return nil }; var r = record
        if active { guard r.cleanPasses != 0 else { return nil }; r.cleanPasses = 0; return r }
        r.cleanPasses += 1
        if r.cleanPasses >= max(1, policy.closeAfterCleanFullPasses) { r.resolvedAt = now }
        return r
    }
    public static let checkableKeyPrefixes = ["anomaly:", "breaker", "lookalike_sim:", "queued:"]
    public static func isCheckable(_ key: String) -> Bool {
        checkableKeyPrefixes.contains { key == $0 || (key.hasPrefix($0) && $0.hasSuffix(":")) }
    }
}
