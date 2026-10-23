// SPDX-License-Identifier: MIT

/// Simulator pool counts the scheduler needs. Booted-and-running sims and parked
/// (SIGSTOPped) sims are capped separately, borrowed from manzanas' CapacityClass.
public struct PoolSnapshot: Sendable, Codable, Equatable {
    /// Booted, not parked, not assigned to a job.
    public var idleRunning: Int
    /// Booted, not parked, assigned to a job.
    public var busyRunning: Int
    /// Booted but parked; thawing one makes it running.
    public var idleParked: Int
    public var bootsInProgress: Int

    public init(idleRunning: Int = 0, busyRunning: Int = 0, idleParked: Int = 0, bootsInProgress: Int = 0) {
        self.idleRunning = idleRunning
        self.busyRunning = busyRunning
        self.idleParked = idleParked
        self.bootsInProgress = bootsInProgress
    }

    /// Sims counted against `maxRunningSims`. A booting sim counts as running.
    public var runningTotal: Int { idleRunning + busyRunning + bootsInProgress }
}

/// Naming for simulators SimQueue owns. Kept configurable so the scheme can follow
/// whatever convention the host already uses; nothing is hard-coded to one project.
public struct SimNamingScheme: Sendable, Equatable, Codable {
    /// Every owned simulator name starts with `simq-`. Configuration can only add an
    /// extra namespace segment after it (`simq-<extra>-`).
    public static let root = "simq"

    /// `simq`, or `simq-<extra>` when config adds a segment.
    public private(set) var prefix: String
    /// This daemon's owner tag (`d` + 8 hex digits, from its state directory), appended to
    /// the pool sims it creates so two daemons on one host never make the same name and
    /// neither reaps the other's sims. Nil (tests, older setups): names carry no tag. Not
    /// part of the config; the daemon sets it at startup.
    public var ownerTag: String?

    public init(prefix: String = SimNamingScheme.root, ownerTag: String? = nil) {
        self.prefix = Self.normalized(prefix)
        self.ownerTag = ownerTag
    }

    /// The owner tag for a state directory: `d` + the 32-bit FNV-1a hash of its standardized
    /// path, in hex. Stable across restarts; distinct state dirs get distinct tags.
    public static func ownerTag(stateDirectory: String) -> String {
        var path = stateDirectory
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        var hash: UInt32 = 2_166_136_261
        for byte in path.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let hex = String(hash, radix: 16)
        return "d" + String(repeating: "0", count: 8 - hex.count) + hex
    }

    /// The owner tag a sim name ends with (`-d` + 8 hex digits), or nil for an untagged name.
    /// Untagged names end in an intent id (digits), so the two never get confused.
    public static func ownerTag(of simulatorName: String) -> String? {
        guard let last = simulatorName.split(separator: "-").last, last.count == 9, last.first == "d",
            last.dropFirst().allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { return nil }
        return String(last)
    }

    /// In the `simq-` namespace and tagged by a different daemon (or tagged at all when this
    /// scheme has no tag). Never adopted, reaped, deleted or counted as ours.
    public func belongsToAnotherDaemon(_ simulatorName: String) -> Bool {
        guard inNamespace(simulatorName), let tag = Self.ownerTag(of: simulatorName) else { return false }
        return tag != ownerTag
    }

    /// `simq` → `simq`; `simq-ci` → `simq-ci`; `ci` → `simq-ci`; empty → `simq`.
    static func normalized(_ configured: String) -> String {
        var extra = Substring(configured.filter { $0 != " " })
        if extra == Self.root {
            extra = ""
        } else if extra.hasPrefix(Self.root + "-") {
            extra = extra.dropFirst(Self.root.count + 1)
        }
        extra = Substring(extra.drop { $0 == "-" })
        while extra.hasSuffix("-") { extra = extra.dropLast() }
        return extra.isEmpty ? Self.root : "\(Self.root)-\(extra)"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(prefix: try container.decodeIfPresent(String.self, forKey: .prefix) ?? Self.root)
    }

    enum CodingKeys: String, CodingKey { case prefix }

    /// A pool sim's name: `simq-<project>-<slot>-<intent id>-<owner tag>` (project `pool`
    /// when no project owns it; no tag when `ownerTag` is nil). The intent id is the
    /// write-ahead intent recorded for the create; it counts per state dir, so the tag is
    /// what keeps names unique per host.
    public func poolSimName(project: String = "pool", slot: Int, intentID: Int64) -> String {
        "\(prefix)-\(project)-\(slot)-\(intentID)" + (ownerTag.map { "-\($0)" } ?? "")
    }

    /// A pool sim name's slot (the number before the intent id), tag or no tag.
    public static func poolSlot(of simulatorName: String) -> Int? {
        var parts = simulatorName.split(separator: "-")
        if ownerTag(of: simulatorName) != nil { parts.removeLast() }
        return parts.count >= 4 ? Int(parts[parts.count - 2]) : nil
    }

    /// A template sim's name: `simq-template-<project>-<profile>-<intent id>`. `template` (and
    /// `golden`, the legacy shape) is reserved as a project name so this never collides with
    /// a pool sim's name.
    public func templateName(project: String, profile: String, intentID: Int64) -> String {
        "\(prefix)-template-\(project)-\(profile)-\(intentID)"
    }

    public func poolName(project: String, index: Int) -> String {
        "\(prefix)-pool-\(project)-\(index)"
    }

    /// True for any simulator this daemon owns (the reaper deletes unknown owned sims): in
    /// the namespace and not tagged by another daemon.
    public func owns(_ simulatorName: String) -> Bool {
        inNamespace(simulatorName) && !belongsToAnotherDaemon(simulatorName)
    }

    /// In the `simq-` namespace, whichever daemon made it.
    public func inNamespace(_ simulatorName: String) -> Bool {
        simulatorName.hasPrefix("\(prefix)-")
    }

    /// Outside the namespace, but close enough to be mistaken for one of ours: the same
    /// prefix once case, spaces, dots and underscores are ignored (`SimQ Pool 1`,
    /// `simq_pool_1`). Such sims are never adopted; the watchdog alerts on them once.
    public func isLookalike(_ simulatorName: String) -> Bool {
        guard !inNamespace(simulatorName) else { return false }
        func normalized(_ text: String) -> String {
            String(text.lowercased().map { " ._".contains($0) ? "-" : $0 })
        }
        return normalized(simulatorName).hasPrefix(normalized(prefix) + "-")
    }

    /// A template sim's name: `simq-template-...`, or `simq-golden-...` from before the rename
    /// to template (still a template: never reaped, never handed out, protected from prep).
    public func isTemplate(_ simulatorName: String) -> Bool {
        simulatorName.hasPrefix("\(prefix)-template-") || simulatorName.hasPrefix("\(prefix)-golden-")
    }
}

/// One simulator as the backend reports it.
public struct SimDevice: Sendable, Equatable, Codable {
    public var dataSizeBytes: UInt64?
    public var udid: String
    public var name: String
    public var runtime: String?
    public var deviceType: String?
    public var isBooted: Bool
    /// Exact host state; Booting and ShuttingDown must never be treated as Shutdown.
    public var state: String?

    public init(
        udid: String, name: String, isBooted: Bool, state: String? = nil, runtime: String? = nil,
        deviceType: String? = nil, dataSizeBytes: UInt64? = nil
    ) {
        self.dataSizeBytes = dataSizeBytes
        self.runtime = runtime
        self.deviceType = deviceType
        self.udid = udid
        self.name = name
        self.isBooted = isBooted
        self.state = state ?? (isBooted ? "Booted" : "Shutdown")
    }
}
