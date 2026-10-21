// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore

public struct AuditEntry: Sendable, Equatable {
    public var seq: Int64
    public var at: Double
    public var epoch: Int64?
    public var jobID: String?
    public var resourceID: Int64?
    public var type: String
    public var detail: String?
    /// The watchdog pass that wrote it (nil outside a pass).
    public var passID: String? = nil
}

/// Read-only health view for a future watchdog process. Everything here can be computed
/// from a read-only connection to the database.
public struct LivenessReport: Sendable, Equatable {
    public var epoch: Int64?
    public var daemonPID: Int32?
    /// Seconds since the daemon last heartbeated its lease; nil if no lease exists.
    public var heartbeatAgeSeconds: Double?
    /// Admitted or running jobs whose run timeout has passed.
    public var overdueJobs: [String]
    /// Resources waiting for cleanup.
    public var orphanedResources: Int
    public var activeResources: Int
}

extension JobStore {
    // MARK: - Daemon heartbeat

    /// Refreshes the daemon lease heartbeat. Returns false if `epoch` is no longer current
    /// (another daemon took over), which the caller must treat as fatal.
    @discardableResult
    public func heartbeat(epoch: Int64, now: Double) throws -> Bool {
        try database.run(
            "UPDATE daemon_lease SET heartbeat = ? WHERE singleton = 1 AND epoch = ?;", [.real(now), .integer(epoch)])
        return database.changes == 1
    }

    public func livenessReport(now: Double) throws -> LivenessReport {
        let lease = try database.query("SELECT epoch, pid, heartbeat FROM daemon_lease WHERE singleton = 1;").first
        let overdue = try activeJobs().filter { $0.isRunTimedOut(now: now) }.map(\.id)
        let counts = try database.query(
            "SELECT state, COUNT(*) AS n FROM owned_resources WHERE state != 'released' GROUP BY state;")
        var orphaned = 0
        var active = 0
        for row in counts {
            let count = Int(row.int("n") ?? 0)
            if row.string("state") == OwnedResourceState.orphaned.rawValue { orphaned = count } else { active = count }
        }
        return LivenessReport(
            epoch: lease?.int("epoch"),
            daemonPID: lease?.int("pid").map { Int32($0) },
            heartbeatAgeSeconds: lease?.double("heartbeat").map { now - $0 },
            overdueJobs: overdue,
            orphanedResources: orphaned,
            activeResources: active
        )
    }

    // MARK: - Ownership ledger

    /// Records ownership of a resource before (or as) it is created. The grant is fenced:
    /// `epoch` must be the current daemon epoch, and a job owner must be active under it.
    /// Returns the row with a fresh generation.
    @discardableResult
    public func acquireResource(
        kind: OwnedResourceKind,
        externalID: String,
        owner: ResourceOwner,
        epoch: Int64,
        detail: String? = nil,
        identity: String? = nil,
        now: Double
    ) throws -> OwnedResource {
        try database.immediateTransaction {
            let current = try currentEpoch()
            guard current == epoch else {
                throw JobStoreError.staleEpoch(presented: epoch, current: current)
            }
            if let jobID = owner.jobID {
                guard let job = try job(id: jobID) else {
                    throw JobStoreError.jobNotFound(jobID)
                }
                guard job.state.isActive, job.ownerEpoch == epoch else {
                    throw JobStoreError.invalidTransition(jobID: jobID, from: job.state, action: "own \(kind.rawValue)")
                }
            }
            let live = try database.query(
                "SELECT 1 FROM owned_resources WHERE kind = ? AND external_id = ? AND state != 'released';",
                [.text(kind.rawValue), .text(externalID)]
            )
            guard live.isEmpty else {
                throw JobStoreError.alreadyOwned(kind: kind, externalID: externalID)
            }
            let generation = try nextGeneration()
            try database.run(
                """
                INSERT INTO owned_resources (kind, external_id, owner_job_id, owner_kind, epoch, generation, state, acquired_at, detail, identity)
                VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?, ?);
                """,
                [
                    .text(kind.rawValue), .text(externalID), .optional(owner.jobID),
                    .text(owner.jobID == nil ? "pool" : "job"),
                    .integer(epoch), .integer(generation), .real(now), .optional(detail), .optional(identity),
                ]
            )
            let id = database.lastInsertRowID
            try refreshCachedResource(id)
            try event(
                owner.jobID, "resource_acquired", detail: "\(kind.rawValue) \(externalID) gen=\(generation)",
                resourceID: id, at: now)
            guard let resource = try resource(id: id) else {
                throw JobStoreError.resourceNotFound(id)
            }
            return resource
        }
    }

    // MARK: - Write-ahead spawn intents

    /// Prefix of a process-group row's external id while its pid is not yet known.
    public static let spawnIntentPrefix = "intent:"
    /// The environment variable a spawned job command carries its intent token in.
    public static let spawnTokenEnvironmentKey = "SIMQ_SPAWN_TOKEN"

    /// Records a process group *before* it is spawned: a `process_group` row whose external
    /// id is `intent:<token>`. The child is started with `SIMQ_SPAWN_TOKEN=<token>` in its
    /// environment, so a restarted daemon can find it even if the pid was never recorded.
    @discardableResult
    public func recordSpawnIntent(jobID: String, token: String, epoch: Int64, detail: String?, now: Double) throws
        -> OwnedResource
    {
        try acquireResource(
            kind: .processGroup, externalID: Self.spawnIntentPrefix + token, owner: .job(jobID), epoch: epoch,
            detail: detail, now: now)
    }

    /// Fills in the pgid and leader identity of a spawned intent. Throws `alreadyOwned` if
    /// another live row already has that pgid.
    public func resolveSpawnIntent(id: Int64, pgid: Int32, identity: String?, now: Double) throws {
        try database.immediateTransaction {
            guard let resource = try resource(id: id), resource.externalID.hasPrefix(Self.spawnIntentPrefix) else {
                throw JobStoreError.resourceNotFound(id)
            }
            let clash = try database.query(
                "SELECT 1 FROM owned_resources WHERE kind = 'process_group' AND external_id = ? AND state != 'released';",
                [.text("\(pgid)")])
            guard clash.isEmpty else {
                throw JobStoreError.alreadyOwned(kind: .processGroup, externalID: "\(pgid)")
            }
            try database.run(
                "UPDATE owned_resources SET external_id = ?, identity = ? WHERE id = ?;",
                [.text("\(pgid)"), .optional(identity), .integer(id)])
            try refreshCachedResource(id)
            try event(
                resource.owner.jobID, "spawn_intent_resolved",
                detail: "\(resource.externalID) -> process group \(pgid)", resourceID: id, at: now)
        }
    }

    /// Intents whose pid never got recorded (the daemon died between spawn and record).
    public func unresolvedSpawnIntents() throws -> [OwnedResource] {
        try liveResources().filter {
            $0.kind == .processGroup && $0.externalID.hasPrefix(Self.spawnIntentPrefix)
        }
    }

    /// Normal release by the holder. The holder presents the generation it was given;
    /// a mismatch (the resource was reclaimed and re-granted) throws `staleFence`.
    /// Returns false if the row was already released.
    @discardableResult
    public func releaseResource(id: Int64, generation: Int64, reason: String = "released", now: Double) throws -> Bool {
        try database.immediateTransaction {
            guard let resource = try resource(id: id) else {
                throw JobStoreError.resourceNotFound(id)
            }
            guard resource.generation == generation else {
                throw JobStoreError.staleFence(
                    jobID: resource.owner.jobID ?? "pool", presented: generation, current: resource.generation)
            }
            guard resource.state != .released else {
                return false
            }
            try setState(resource, .released, reason: reason, now: now)
            return true
        }
    }

    /// Daemon-side transitions used by reconciliation (not fenced by generation: the
    /// daemon owns the ledger).
    public func markResourceOrphaned(id: Int64, reason: String, now: Double) throws {
        try database.immediateTransaction {
            guard let resource = try resource(id: id) else {
                throw JobStoreError.resourceNotFound(id)
            }
            guard resource.state == .active else {
                return
            }
            try setState(resource, .orphaned, reason: reason, now: now)
        }
    }

    public func markResourceReleased(id: Int64, reason: String, now: Double) throws {
        try database.immediateTransaction {
            guard let resource = try resource(id: id) else {
                throw JobStoreError.resourceNotFound(id)
            }
            guard resource.state != .released else {
                return
            }
            try setState(resource, .released, reason: reason, now: now)
        }
    }

    /// Rewrites a resource's detail in place (a template's record after its build finishes).
    public func updateResourceDetail(id: Int64, detail: String?) throws {
        try database.run(
            "UPDATE owned_resources SET detail = ? WHERE id = ?;", [SQLValue.optional(detail), .integer(id)])
        try refreshCachedResource(id)
    }

    /// Re-stamps a surviving pool resource with the new epoch and a new generation.
    public func adoptResource(id: Int64, epoch: Int64, now: Double) throws {
        try database.immediateTransaction {
            guard let resource = try resource(id: id) else {
                throw JobStoreError.resourceNotFound(id)
            }
            let generation = try nextGeneration()
            try database.run(
                "UPDATE owned_resources SET epoch = ?, generation = ?, state = 'active' WHERE id = ?;",
                [.integer(epoch), .integer(generation), .integer(id)]
            )
            try refreshCachedResource(id)
            try event(resource.owner.jobID, "resource_adopted", detail: "gen=\(generation)", resourceID: id, at: now)
        }
    }

    public func resource(id: Int64) throws -> OwnedResource? {
        try database.query("SELECT * FROM owned_resources WHERE id = ?;", [.integer(id)]).first.map(
            Self.resource(from:))
    }

    /// Rows in state `active` or `orphaned`, by id. Served from the write-through cache
    /// in a writing store.
    public func liveResources() throws -> [OwnedResource] {
        try validateCaches()
        if let liveSorted { return liveSorted }
        if let liveCache {
            let sorted = liveCache.values.sorted { $0.id < $1.id }
            liveSorted = sorted
            return sorted
        }
        let rows = try database.query("SELECT * FROM owned_resources WHERE state != 'released' ORDER BY id;").map(
            Self.resource(from:))
        if !database.readOnly {
            liveCache = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            liveByKind = [:]
            liveKindSorted = [:]
            for row in rows { liveByKind[row.kind, default: [:]][row.id] = row }
        }
        return rows
    }

    /// Live rows of the given kinds, by id. Cost grows with those kinds' rows only.
    public func liveResources(kinds: Set<OwnedResourceKind>) throws -> [OwnedResource] {
        try validateCaches()
        if liveCache == nil {
            let all = try liveResources()
            guard liveCache != nil else { return all.filter { kinds.contains($0.kind) } }
        }
        var result: [OwnedResource] = []
        for kind in kinds.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let sorted = liveKindSorted[kind] {
                result += sorted
            } else {
                let sorted = (liveByKind[kind] ?? [:]).values.sorted { $0.id < $1.id }
                liveKindSorted[kind] = sorted
                result += sorted
            }
        }
        return kinds.count > 1 ? result.sorted { $0.id < $1.id } : result
    }

    /// Drops the in-process caches if a transaction rolled back since they were built
    /// (they may hold writes the database never kept) or another connection committed
    /// (`PRAGMA data_version` moves only for other connections' writes).
    func validateCaches() throws {
        let version = try database.query("PRAGMA data_version;").first?.int("data_version")
        guard database.rollbackCount != cacheRollbackCount || version != cacheDataVersion else { return }
        cacheRollbackCount = database.rollbackCount
        cacheDataVersion = version
        liveCache = nil
        liveByKind = [:]
        liveKindSorted = [:]
        sightingCache = nil
        alertCache = nil
        anomalyCache = nil
        anomalyPersisted = [:]
    }

    /// Re-reads one ownership row into the cache after a write (a no-op until the cache is built).
    func refreshCachedResource(_ id: Int64) throws {
        guard liveCache != nil else { return }
        let old = liveCache?[id]
        if let row = try resource(id: id), row.state != .released {
            liveCache?[id] = row
            if let old, old.kind != row.kind {
                liveByKind[old.kind]?[id] = nil
                liveKindSorted[old.kind] = nil
            }
            liveByKind[row.kind, default: [:]][id] = row
            liveKindSorted[row.kind] = nil
        } else {
            liveCache?[id] = nil
            if let old {
                liveByKind[old.kind]?[id] = nil
                liveKindSorted[old.kind] = nil
            }
        }
    }

    public func resources(jobID: String) throws -> [OwnedResource] {
        try database.query("SELECT * FROM owned_resources WHERE owner_job_id = ? ORDER BY id;", [.text(jobID)])
            .map(Self.resource(from:))
    }

    /// UDIDs of every sim SimQueue owns (rows not yet released). Backs the stable
    /// `owned_udids` field of `simq doctor --json`, which external reapers read.
    public func ownedSimUDIDs() throws -> [String] {
        try database.query(
            "SELECT external_id FROM owned_resources WHERE kind = 'sim' AND state != 'released' ORDER BY external_id;"
        ).compactMap { $0.string("external_id") }
    }

    /// Records that a resource was just used (pool idle-shutdown input).
    public func touchResource(id: Int64, now: Double) throws {
        try database.run("UPDATE owned_resources SET last_used_at = ? WHERE id = ?;", [.real(now), .integer(id)])
        try refreshCachedResource(id)
    }

    // MARK: - Cleanup sightings (orphan grace)

    public struct Sighting: Sendable, Equatable {
        public var firstSeenAt: Double
        public var reported: Bool
    }

    /// Keeps sightings for exactly `keys`: new keys start now, keys no longer seen are
    /// dropped (so a target that recovers and orphans again gets a fresh grace period).
    /// `inScope` limits which existing sightings this pass may drop (a light watchdog pass
    /// only checks some kinds of targets, so it must not reset the others' grace).
    public func syncSightings(
        _ keys: Set<String>, inScope: (String) -> Bool = { _ in true }, now: Double
    ) throws -> [String: Sighting] {
        try syncSightings(keys, scopePrefix: nil, inScope: inScope, now: now)
    }

    /// As above, for a pass that covers only keys starting with `scopePrefix` (a bucket
    /// prefix such as `process_group:`): only that bucket is walked.
    public func syncSightings(
        _ keys: Set<String>, scopePrefix: String?, inScope: (String) -> Bool = { _ in true }, now: Double
    ) throws -> [String: Sighting] {
        let book = try sightingBook()
        let candidates: [String]
        if let scopePrefix, let book {
            candidates = Array(book.bucket(scopePrefix).keys)
        } else {
            candidates = Array(try sightings().keys)
        }
        // A covered-prefix pass looks keys up in its bucket; a full pass in the flat copy.
        let scoped = scopePrefix.flatMap { prefix in book.map { $0.bucket(prefix) } }
        let flat = scoped == nil ? try sightings() : [:]
        func current(_ key: String) -> Sighting? {
            if let scoped, let scopePrefix, key.hasPrefix(scopePrefix) { return scoped[key] }
            return scoped == nil ? flat[key] : book?[key]
        }
        let gone = candidates.filter { !keys.contains($0) && inScope($0) }
        var result: [String: Sighting] = [:]
        var new: [String] = []
        for key in keys {
            if let sighting = current(key) { result[key] = sighting } else { new.append(key) }
        }
        guard !gone.isEmpty || !new.isEmpty else { return result }
        try database.immediateTransaction {
            for key in gone {
                try database.run("DELETE FROM cleanup_sightings WHERE target_key = ?;", [.text(key)])
            }
            for key in new.sorted() {
                try database.run(
                    "INSERT INTO cleanup_sightings (target_key, first_seen_at) VALUES (?, ?);",
                    [.text(key), .real(now)])
                try event(nil, "cleanup_candidate", detail: key, at: now)
                result[key] = Sighting(firstSeenAt: now, reported: false)
            }
        }
        for key in gone { sightingCache?[key] = nil }
        for key in new { sightingCache?[key] = result[key] }
        return result
    }

    /// The bucketed sighting cache (nil in a read-only store).
    func sightingBook() throws -> PrefixBuckets<Sighting>? {
        _ = try sightings()
        return sightingCache
    }

    /// Every current sighting, by target key.
    public func sightings() throws -> [String: Sighting] {
        try validateCaches()
        if let sightingFlat { return sightingFlat }
        if let sightingCache {
            let flat = sightingCache.all
            sightingFlat = flat
            return flat
        }
        var result: [String: Sighting] = [:]
        for row in try database.query("SELECT * FROM cleanup_sightings;") {
            guard let key = row.string("target_key"), let first = row.double("first_seen_at") else { continue }
            result[key] = Sighting(firstSeenAt: first, reported: (row.int("reported") ?? 0) != 0)
        }
        if !database.readOnly {
            sightingCache = PrefixBuckets(result)
            sightingFlat = result
        }
        return result
    }

    public func markSightingReported(_ key: String) throws {
        try database.run("UPDATE cleanup_sightings SET reported = 1 WHERE target_key = ?;", [.text(key)])
        sightingCache?[key]?.reported = true
    }

    public func clearSighting(_ key: String) throws {
        try database.run("DELETE FROM cleanup_sightings WHERE target_key = ?;", [.text(key)])
        sightingCache?[key] = nil
    }

    // MARK: - Watchdog

    public func watchdogState() throws -> WatchdogState {
        guard
            let json = try database.query("SELECT state_json FROM watchdog_state WHERE singleton = 1;").first?
                .string("state_json")
        else {
            return WatchdogState()
        }
        return try JSONDecoder().decode(WatchdogState.self, from: Data(json.utf8))
    }

    public func saveWatchdogState(_ state: WatchdogState, now: Double) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(state), as: UTF8.self)
        try database.run(
            """
            INSERT INTO watchdog_state (singleton, state_json, updated_at) VALUES (1, ?, ?)
            ON CONFLICT(singleton) DO UPDATE SET state_json = excluded.state_json, updated_at = excluded.updated_at;
            """,
            [.text(json), .real(now)])
    }

    // MARK: - Alerts

    /// Every alert, most recently seen first.
    public func alerts() throws -> [AlertRecord] {
        try validateCaches()
        if let alertSorted { return alertSorted }
        let book = try alertBook()
        let sorted = book.values.sorted { ($0.lastSeenAt, $1.key) > ($1.lastSeenAt, $0.key) }
        if !database.readOnly { alertSorted = sorted }
        return sorted
    }

    /// The alert book by key, loaded once into memory in a writing store.
    func alertBook() throws -> [String: AlertRecord] {
        try validateCaches()
        if let alertCache { return alertCache }
        var book: [String: AlertRecord] = [:]
        for row in try database.query("SELECT record_json FROM alerts;") {
            guard let json = row.string("record_json"),
                let record = try? JSONDecoder().decode(AlertRecord.self, from: Data(json.utf8))
            else { continue }
            book[record.key] = record
        }
        if !database.readOnly { alertCache = book }
        return book
    }

    /// Steps every open, checkable alert on a full watchdog pass (`activeKeys`: alerts
    /// whose condition still holds). Writes only alerts that changed; audits each one
    /// resolved (`alert_cleared`) and returns those.
    @discardableResult
    public func stepAlertClearance(activeKeys: Set<String>, now: Double, policy: AlertPolicy) throws -> [AlertRecord] {
        let changed = try alertBook().values.compactMap { record -> AlertRecord? in
            guard !record.isResolved, AlertBook.isCheckable(record.key) else { return nil }
            return AlertBook.clearance(record, active: activeKeys.contains(record.key), now: now, policy: policy)
        }
        guard !changed.isEmpty else { return [] }
        return try database.immediateTransaction {
            var resolved: [AlertRecord] = []
            for record in changed.sorted(by: { $0.key < $1.key }) {
                try saveAlert(record)
                if record.isResolved {
                    try event(
                        nil, "alert_cleared",
                        detail: "\(record.key): clear for \(record.cleanPasses) full passes in a row", at: now)
                    resolved.append(record)
                }
            }
            return resolved
        }
    }

    public func alert(key: String) throws -> AlertRecord? {
        if !database.readOnly { return try alertBook()[key] }
        guard
            let json = try database.query("SELECT record_json FROM alerts WHERE alert_key = ?;", [.text(key)]).first?
                .string("record_json")
        else {
            return nil
        }
        return try JSONDecoder().decode(AlertRecord.self, from: Data(json.utf8))
    }

    public func saveAlert(_ record: AlertRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(record), as: UTF8.self)
        try database.run(
            """
            INSERT INTO alerts (alert_key, record_json, last_seen_at) VALUES (?, ?, ?)
            ON CONFLICT(alert_key) DO UPDATE SET record_json = excluded.record_json,
                last_seen_at = excluded.last_seen_at;
            """,
            [.text(record.key), .text(json), .real(record.lastSeenAt)])
        alertCache?[record.key] = record
    }

    /// Folds events into their alert records and audits each one (`alert_raised`).
    @discardableResult
    public func recordAlerts(_ events: [AlertEvent], now: Double, policy: AlertPolicy) throws -> [AlertRecord] {
        try database.immediateTransaction {
            try events.map { event in
                let record = AlertBook.record(event, into: try alert(key: event.key), now: now, policy: policy)
                try saveAlert(record)
                try self.event(
                    nil, "alert_raised",
                    detail:
                        "\(event.key) [\(record.level.rawValue)] x\(record.count)\(record.needsHuman ? " needs-human" : ""): \(event.detail)",
                    at: now)
                return record
            }
        }
    }

    // MARK: - Audit log

    public func auditCount(type: String, since: Double) throws -> Int {
        Int(
            try database.query(
                "SELECT COUNT(*) AS n FROM audit_log WHERE type = ? AND at >= ?;", [.text(type), .real(since)]
            )
            .first?.int("n") ?? 0
        )
    }

    /// The newest audit entry's `seq`, or nil when there are none.
    public func latestAuditSeq() throws -> Int64? {
        try database.query("SELECT MAX(seq) AS seq FROM audit_log;").first?.int("seq")
    }

    /// Every audit entry for a job, oldest first (uses `audit_log_job_idx`).
    public func auditEntries(jobID: String) throws -> [AuditEntry] {
        try database.query("SELECT * FROM audit_log WHERE job_id = ? ORDER BY seq;", [.text(jobID)]).map { row in
            AuditEntry(
                seq: row.int("seq") ?? 0, at: row.double("at") ?? 0, epoch: row.int("epoch"),
                jobID: row.string("job_id"),
                resourceID: row.int("resource_id"), type: row.string("type") ?? "", detail: row.string("detail"),
                passID: row.string("pass_id"))
        }
    }

    /// One job's audit entries of one type, oldest first.
    public func auditEntries(jobID: String, type: String) throws -> [AuditEntry] {
        try database.query(
            "SELECT * FROM audit_log WHERE job_id = ? AND type = ? ORDER BY seq;", [.text(jobID), .text(type)]
        ).map { row in
            AuditEntry(
                seq: row.int("seq") ?? 0, at: row.double("at") ?? 0, epoch: row.int("epoch"),
                jobID: row.string("job_id"),
                resourceID: row.int("resource_id"), type: row.string("type") ?? "", detail: row.string("detail"),
                passID: row.string("pass_id"))
        }
    }

    public func auditEntries(afterSeq: Int64 = 0, limit: Int = 10_000) throws -> [AuditEntry] {
        try database.query(
            "SELECT * FROM audit_log WHERE seq > ? ORDER BY seq LIMIT ?;",
            [.integer(afterSeq), .integer(Int64(limit))]
        ).map { row in
            AuditEntry(
                seq: row.int("seq") ?? 0,
                at: row.double("at") ?? 0,
                epoch: row.int("epoch"),
                jobID: row.string("job_id"),
                resourceID: row.int("resource_id"),
                type: row.string("type") ?? "",
                detail: row.string("detail"),
                passID: row.string("pass_id")
            )
        }
    }

    /// Appends a free-form entry (used by the engine for reconcile actions and by future
    /// watchdog and CLI commands).
    public func audit(
        _ type: String, jobID: String? = nil, resourceID: Int64? = nil, detail: String? = nil, now: Double
    ) throws {
        try event(jobID, type, detail: detail, resourceID: resourceID, at: now)
    }

    // MARK: - Private

    private func nextGeneration() throws -> Int64 {
        try database.run("UPDATE fence_counter SET value = value + 1 WHERE singleton = 1;")
        guard let value = try database.query("SELECT value FROM fence_counter WHERE singleton = 1;").first?.int("value")
        else {
            throw JobStoreError.corruptRow("fence_counter missing")
        }
        return value
    }

    func setState(_ resource: OwnedResource, _ state: OwnedResourceState, reason: String, now: Double) throws {
        try database.run(
            "UPDATE owned_resources SET state = ?, released_at = ? WHERE id = ?;",
            [.text(state.rawValue), state == .released ? .real(now) : .null, .integer(resource.id)]
        )
        try refreshCachedResource(resource.id)
        try event(
            resource.owner.jobID,
            "resource_\(state.rawValue)",
            detail: "\(resource.kind.rawValue) \(resource.externalID): \(reason)",
            resourceID: resource.id,
            at: now
        )
    }

    static func resource(from row: Row) throws -> OwnedResource {
        guard let id = row.int("id"),
            let kind = row.string("kind").flatMap(OwnedResourceKind.init(rawValue:)),
            let externalID = row.string("external_id"),
            let epoch = row.int("epoch"),
            let generation = row.int("generation"),
            let state = row.string("state").flatMap(OwnedResourceState.init(rawValue:)),
            let acquiredAt = row.double("acquired_at")
        else {
            throw JobStoreError.corruptRow("owned_resources")
        }
        let owner: ResourceOwner = row.string("owner_job_id").map { .job($0) } ?? .pool
        return OwnedResource(
            id: id,
            kind: kind,
            externalID: externalID,
            owner: owner,
            epoch: epoch,
            generation: generation,
            state: state,
            acquiredAt: acquiredAt,
            releasedAt: row.double("released_at"),
            detail: row.string("detail"),
            identity: row.string("identity")
        )
    }
}

// MARK: - Sustained anomalies

extension JobStore {
    /// The current anomaly book. In a writing store it comes from memory after the first
    /// read, so it includes pass counters not yet re-confirmed in the database.
    public func anomalies() throws -> [AnomalyRecord] {
        try validateCaches()
        if let anomalySorted { return anomalySorted }
        if let anomalyCache {
            let sorted = anomalyCache.values.sorted { $0.key < $1.key }
            anomalySorted = sorted
            return sorted
        }
        let loaded = try persistedAnomalies()
        if !database.readOnly {
            anomalyCache = Dictionary(loaded.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            anomalyPersisted = anomalyCache ?? [:]
        }
        return loaded
    }

    /// The book's records whose key starts with `prefix`, found by binary search in the
    /// sorted book (cost grows with the slice, not the book).
    public func anomalies(withPrefix prefix: String) throws -> [AnomalyRecord] {
        let all = try anomalies()
        let range = Self.prefixRange(all, prefix)
        return Array(all[range])
    }

    static func prefixRange(_ sorted: [AnomalyRecord], _ prefix: String) -> Range<Int> {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid].key < prefix { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < sorted.count, sorted[end].key.hasPrefix(prefix) { end += 1 }
        return low..<end
    }

    /// Saves a pass that only judged keys starting with `prefix`: `update.records` is that
    /// slice's new state. The rest of the book is left as it is, and only the slice is
    /// diffed against what's persisted.
    public func saveAnomalies(_ update: AnomalyUpdate, now: Double, prefix: String) throws {
        var sorted = try anomalies()
        anomalySorted = nil  // keep `sorted` uniquely referenced so the splice is in place
        let range = Self.prefixRange(sorted, prefix)
        let newSlice = update.records.sorted { $0.key < $1.key }
        let keep = Set(newSlice.map(\.key))
        let removed = sorted[range].map(\.key).filter { !keep.contains($0) }
        let changed = newSlice.filter { anomalyNeedsWrite($0) }
        sorted.replaceSubrange(range, with: newSlice)
        for key in removed { anomalyCache?[key] = nil }
        for record in newSlice { anomalyCache?[record.key] = record }
        anomalySorted = sorted
        try persistAnomalies(removed: removed, changed: changed, update: update, now: now)
    }

    func anomalyNeedsWrite(_ record: AnomalyRecord) -> Bool {
        guard let old = anomalyPersisted[record.key] else { return true }
        return old.level != record.level || old.detail != record.detail || old.firstSeenAt != record.firstSeenAt
            || (old.cleanPasses == 0) != (record.cleanPasses == 0)
            || record.lastSeenAt - old.lastSeenAt >= anomalyReconfirmSeconds
    }

    func persistedAnomalies() throws -> [AnomalyRecord] {
        try database.query("SELECT * FROM anomalies ORDER BY target_key;").compactMap { row in
            guard let key = row.string("target_key"), let detail = row.string("detail"),
                let first = row.double("first_seen_at"), let last = row.double("last_seen_at"),
                let passes = row.int("consecutive_passes"),
                let level = row.string("level").flatMap(AnomalyLevel.init(rawValue:))
            else {
                return nil
            }
            return AnomalyRecord(
                key: key, detail: detail, firstSeenAt: first, lastSeenAt: last, consecutivePasses: Int(passes),
                cleanPasses: Int(row.int("clean_passes") ?? 0), level: level)
        }
    }

    /// Saves one pass's anomaly book, writing only what changed: new and removed rows,
    /// level, detail or first-seen changes, a clean/dirty flip, and a re-confirmation of
    /// an unchanged row once per `anomalyReconfirmSeconds`. A pass over the same
    /// leftovers costs the same however long they've been there.
    public func saveAnomalies(_ update: AnomalyUpdate, now: Double) throws {
        _ = try anomalies()  // load the book once
        let records = Dictionary(update.records.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let removed = anomalyPersisted.keys.filter { records[$0] == nil }
        let changed = update.records.filter { anomalyNeedsWrite($0) }
        anomalyCache = records
        anomalySorted = update.records.sorted { $0.key < $1.key }
        try persistAnomalies(removed: Array(removed), changed: changed, update: update, now: now)
    }

    func persistAnomalies(removed: [String], changed: [AnomalyRecord], update: AnomalyUpdate, now: Double) throws {
        guard !removed.isEmpty || !changed.isEmpty || !update.escalated.isEmpty || !update.cleared.isEmpty else {
            return
        }
        do {
            try database.immediateTransaction {
                for key in removed {
                    try database.run("DELETE FROM anomalies WHERE target_key = ?;", [.text(key)])
                }
                for record in changed {
                    try database.run(
                        """
                        INSERT OR REPLACE INTO anomalies (target_key, detail, first_seen_at, last_seen_at,
                            consecutive_passes, clean_passes, level) VALUES (?, ?, ?, ?, ?, ?, ?);
                        """,
                        [
                            .text(record.key), .text(record.detail), .real(record.firstSeenAt),
                            .real(record.lastSeenAt), .integer(Int64(record.consecutivePasses)),
                            .integer(Int64(record.cleanPasses)), .text(record.level.rawValue),
                        ]
                    )
                }
                for record in update.escalated {
                    try event(
                        nil, "anomaly_\(record.level.rawValue)",
                        detail: "\(record.key): \(record.detail) (passes=\(record.consecutivePasses))", at: now)
                }
                for record in update.cleared {
                    try event(nil, "anomaly_cleared", detail: "\(record.key) after \(record.level.rawValue)", at: now)
                }
            }
        } catch {
            // The database didn't take it: reload from what it has on the next read.
            anomalyCache = nil
            anomalyPersisted = [:]
            throw error
        }
        for key in removed { anomalyPersisted[key] = nil }
        for record in changed { anomalyPersisted[record.key] = record }
    }
}
