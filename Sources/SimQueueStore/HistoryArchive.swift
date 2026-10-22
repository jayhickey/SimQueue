// SPDX-License-Identifier: MIT
import Foundation
import SimQueueCore

public struct HistoryArchiveResult: Sendable {
    public var archive: String
    public var jobsRemoved: Int
    public var auditsRemoved: Int
}

extension JobStore {
    /// New submissions stop at this live-page high-water mark. Existing work, cleanup
    /// and recovery can still write: storage pressure must never prevent termination.
    /// Protected state (active work, pins, retained artifacts and intents) is not evicted.
    public static let historyStorageHighWaterBytes = 256 * ByteSize.mebibyte

    func checkHistoryStoragePressure(limit: UInt64 = JobStore.historyStorageHighWaterBytes) throws {
        let pages = try database.query("PRAGMA page_count;").first?.int("page_count") ?? 0
        let free = try database.query("PRAGMA freelist_count;").first?.int("freelist_count") ?? 0
        let pageSize = try database.query("PRAGMA page_size;").first?.int("page_size") ?? 4096
        if UInt64(max(0, pages - free)) > limit / UInt64(max(1, pageSize)) {
            throw JobStoreError.invalidCommand(
                "storage_pressure: live database exceeds 256 MiB; let history maintenance finish, remove unneeded artifact pins/retained artifacts, then drain and export/compact state if needed; existing jobs and recovery remain enabled"
            )
        }
    }

    /// Durable full snapshots precede bounded, atomic pruning. Completed history aims
    /// for 10,000 jobs and 100,000 unreferenced audits or 30 days, whichever is smaller.
    /// Protected recovery/artifact state is exempt; admission backpressure limits growth.
    /// At most three self-contained 512 MiB archives plus one bounded in-progress copy.
    /// The lock also lets a later pass safely remove copies interrupted by process death.
    public static func archiveHistory(
        path: String, artifactsRoot: String, now: Double,
        keepJobs: Int = 10_000, keepAuditDays: Double = 30, keepAudits: Int = 100_000,
        beforePrune: (() throws -> Void)? = nil, duringPrune: (() throws -> Void)? = nil
    ) throws -> HistoryArchiveResult? {
        guard now.isFinite, keepJobs >= 0, keepAudits >= 0, keepAuditDays >= 0, keepAuditDays.isFinite else {
            throw JobStoreError.invalidCommand("history retention limits must be nonnegative and finite")
        }
        let directory = (path as NSString).deletingLastPathComponent + "/history-archives"
        let files = FileManager.default
        try files.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try Database.withArchiveLock(path: directory + "/archive.lock") {
            // No other archiver can own these names while this lock is held. A crash
            // before rename leaves only a disposable partial; it never authorizes pruning.
            for name in try files.contentsOfDirectory(atPath: directory)
            where name.hasPrefix("history-") && (name.hasSuffix(".partial") || name.contains(".partial-")) {
                do { try files.removeItem(atPath: directory + "/" + name) } catch let error as CocoaError
                    where error.code == .fileNoSuchFile
                { /* SQLite may remove its sidecar when the main partial closes. */  }
            }
            try rotateArchives(directory: directory, keeping: 3)
            return try archiveHistoryLocked(
                path: path, artifactsRoot: artifactsRoot, directory: directory, now: now,
                keepJobs: keepJobs, keepAuditDays: keepAuditDays, keepAudits: keepAudits,
                beforePrune: beforePrune, duringPrune: duringPrune)
        } ?? nil
    }

    private static func archiveHistoryLocked(
        path: String, artifactsRoot: String, directory: String, now: Double,
        keepJobs: Int, keepAuditDays: Double, keepAudits: Int,
        beforePrune: (() throws -> Void)?, duringPrune: (() throws -> Void)?
    ) throws -> HistoryArchiveResult? {
        let store = try JobStore(path: path, maxQueuedPerSubmitterPerProject: 0)
        let db = store.database
        let count = try db.query("SELECT COUNT(*) AS n FROM jobs;").first?.int("n") ?? 0
        let auditCount = try db.query("SELECT COUNT(*) AS n FROM audit_log;").first?.int("n") ?? 0
        let cutoff = now - keepAuditDays * 86_400
        let oldAudit = try db.query("SELECT 1 FROM audit_log WHERE at < ? LIMIT 1;", [.real(cutoff)]).first != nil
        let oldAlerts =
            try db.query("SELECT 1 FROM alerts WHERE last_seen_at < ? LIMIT 1;", [.real(cutoff)]).first != nil
        guard count > keepJobs || auditCount > keepAudits || oldAudit || oldAlerts else { return nil }
        // Reserve a slot before copying, so interruption after durable rename still
        // leaves at most three complete archives. Never delete the last snapshot first.
        try rotateArchives(directory: directory, keeping: 2)
        let files = FileManager.default
        let archive = directory + "/history-\(Int(now))-\(UUID().uuidString).sqlite"
        let temporary = archive + ".partial"
        defer {
            for suffix in ["", "-journal", "-wal", "-shm"] { try? files.removeItem(atPath: temporary + suffix) }
        }
        try Database.snapshot(source: path, destination: temporary)
        let snapshot = try Database(path: temporary, readOnly: true)
        guard try snapshot.query("PRAGMA integrity_check;").first?.string("integrity_check") == "ok" else {
            throw JobStoreError.corruptRow("history snapshot failed integrity check; live history unchanged")
        }
        let size = (try files.attributesOfItem(atPath: temporary)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size <= 512 * ByteSize.mebibyte else {
            throw JobStoreError.invalidCommand("history archive exceeds 512 MiB; live history unchanged")
        }
        let watermark = try snapshot.query("SELECT COALESCE(MAX(seq),0) AS n FROM audit_log;").first?.int("n") ?? 0
        let countWatermark =
            try snapshot.query(
                "SELECT seq FROM audit_log ORDER BY seq DESC LIMIT 1 OFFSET ?;", [.integer(Int64(keepAudits))]
            ).first?.int("seq") ?? 0
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: temporary))
        try handle.synchronize(); try handle.close()
        try files.moveItem(atPath: temporary, toPath: archive)
        try Database.syncDirectory(directory)
        try beforePrune?()
        // Compare snapshot state, not just insertion sequence: a queued job in the
        // snapshot may have finished while the backup ran and must retain its outcome.
        try db.run("ATTACH DATABASE ? AS history_snapshot;", [.text(archive)])
        defer { try? db.execute("DETACH DATABASE history_snapshot;") }
        let safetyCutoff = now - 3600
        let settleCutoff = min(safetyCutoff, try store.watchdogState().lastFullPassAt ?? safetyCutoff)
        var jobsRemoved = 0
        var auditsRemoved = 0
        try db.withStatementDeadline(seconds: 2) {
            try db.withArchiveAuthorization(watermark: watermark, cutoff: now.nextUp) {
                try db.immediateTransaction {
                    let cursor =
                        try db.query("SELECT job_cursor FROM history_archive_state WHERE singleton=1;").first?.int(
                            "job_cursor") ?? 0
                    let candidates = try db.query(
                        """
                        SELECT j.seq, j.id, j.created_at, j.command_json FROM jobs j JOIN history_snapshot.jobs s ON s.id=j.id
                        WHERE j.seq > ? AND j.state NOT IN ('queued','admitted','running') AND s.state NOT IN ('queued','admitted','running')
                        AND NOT EXISTS(SELECT 1 FROM jobs c WHERE c.parent_id=j.id)
                        AND NOT EXISTS(SELECT 1 FROM owned_resources r WHERE r.owner_job_id=j.id AND r.state!='released')
                        AND NOT EXISTS(SELECT 1 FROM action_intents i WHERE i.job_id=j.id OR i.resource_id IN (SELECT id FROM owned_resources WHERE owner_job_id=j.id))
                        AND NOT EXISTS(SELECT 1 FROM audit_log a WHERE a.job_id=j.id AND (a.type='artifact_keep' OR a.seq > ?))
                        AND NOT EXISTS(SELECT 1 FROM audit_log a WHERE a.job_id=j.parent_id AND a.type='artifact_keep')
                        AND NOT EXISTS(SELECT 1 FROM owned_resources r JOIN audit_log a ON a.resource_id=r.id
                          JOIN jobs retained ON retained.id=a.job_id WHERE r.owner_job_id=j.id AND retained.id!=j.id)
                        ORDER BY j.seq LIMIT 1000;
                        """, [.integer(cursor), .integer(watermark)])
                    let pendingPaths = try db.query("SELECT target FROM action_intents WHERE target_kind='path';")
                        .compactMap { $0.string("target") }
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.calendar = Calendar(identifier: .gregorian)
                    formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    for row in candidates {
                        guard jobsRemoved < min(1000, max(0, count - Int64(keepJobs))) else { break }
                        guard let id = row.string("id"), let created = row.double("created_at") else { continue }
                        let command = row.string("command_json").flatMap {
                            try? JSONDecoder().decode(JobCommand.self, from: Data($0.utf8))
                        }
                        let artifact =
                            (command?.artifactsRoot ?? artifactsRoot) + "/"
                            + formatter.string(from: Date(timeIntervalSince1970: created)) + "/"
                            + id
                        guard !files.fileExists(atPath: artifact),
                            !pendingPaths.contains(where: {
                                artifact == $0 || artifact.hasPrefix($0 + "/") || $0.hasPrefix(artifact + "/")
                            })
                        else { continue }
                        try db.run("DELETE FROM job_run_info WHERE job_id=?;", [.text(id)])
                        try db.run("DELETE FROM explanations WHERE job_id=?;", [.text(id)])
                        try db.run(
                            "DELETE FROM owned_resources WHERE owner_job_id=? AND state='released';", [.text(id)])
                        try db.run("DELETE FROM jobs WHERE id=?;", [.text(id)])
                        jobsRemoved += db.changes
                    }
                    let nextCursor = candidates.count == 1000 ? (candidates.last?.int("seq") ?? 0) : 0
                    try db.run(
                        "UPDATE history_archive_state SET job_cursor=? WHERE singleton=1;", [.integer(nextCursor)])
                    // A released pool resource remains if a retained job's audit references
                    // it. That relationship is needed to explain retained run ownership.
                    try db.run(
                        """
                        DELETE FROM owned_resources WHERE id IN (
                        SELECT r.id FROM owned_resources r WHERE r.state='released' AND r.owner_job_id IS NULL
                        AND r.released_at < ? AND NOT EXISTS(SELECT 1 FROM action_intents i WHERE i.resource_id=r.id)
                        AND NOT EXISTS(SELECT 1 FROM audit_log a WHERE a.resource_id=r.id AND
                          (a.seq > ? OR EXISTS(SELECT 1 FROM jobs j WHERE j.id=a.job_id))) ORDER BY r.id LIMIT 10000);
                        """, [.real(cutoff), .integer(watermark)])
                    try db.run(
                        """
                        DELETE FROM audit_log WHERE seq IN (SELECT a.seq FROM audit_log a WHERE a.seq <= ?
                        AND (a.at < ? OR a.seq <= ?) AND a.at < ?
                        AND (a.type!='settle_cap_hit' OR a.at < ?)
                        AND (a.job_id IS NULL OR NOT EXISTS(SELECT 1 FROM jobs j WHERE j.id=a.job_id))
                        AND (a.resource_id IS NULL OR NOT EXISTS(SELECT 1 FROM owned_resources r WHERE r.id=a.resource_id))
                        AND NOT EXISTS(SELECT 1 FROM action_intents i WHERE i.job_id=a.job_id OR i.resource_id=a.resource_id)
                        ORDER BY a.seq LIMIT 10000);
                        """,
                        [
                            .integer(watermark), .real(cutoff), .integer(countWatermark), .real(safetyCutoff),
                            .real(settleCutoff),
                        ])
                    auditsRemoved = db.changes
                    // Current unresolved health records and anomaly/breaker tables stay
                    // live. Only unchanged, fully resolved old diagnostics are history.
                    let alertCursor =
                        try db.query("SELECT alert_cursor FROM history_archive_state WHERE singleton=1;").first?.string(
                            "alert_cursor") ?? ""
                    let oldHealth = try db.query(
                        """
                        SELECT a.alert_key, a.record_json FROM alerts a JOIN history_snapshot.alerts s
                        ON s.alert_key=a.alert_key AND s.record_json=a.record_json
                        WHERE a.last_seen_at < ? AND a.alert_key > ? ORDER BY a.alert_key LIMIT 1000;
                        """, [.real(cutoff), .text(alertCursor)])
                    for row in oldHealth {
                        guard let key = row.string("alert_key"), let json = row.string("record_json"),
                            let record = try? JSONDecoder().decode(AlertRecord.self, from: Data(json.utf8)),
                            let resolved = record.resolvedAt, resolved < cutoff
                        else { continue }
                        try db.run("DELETE FROM alerts WHERE alert_key=?;", [.text(key)])
                    }
                    let nextAlertCursor = oldHealth.count == 1000 ? (oldHealth.last?.string("alert_key") ?? "") : ""
                    try db.run(
                        "UPDATE history_archive_state SET alert_cursor=? WHERE singleton=1;", [.text(nextAlertCursor)])
                    try duringPrune?()
                    try store.audit(
                        "history_archived",
                        detail: "\(archive): jobs=\(jobsRemoved) audits=\(auditsRemoved) watermark=\(watermark)",
                        now: now)
                }
            }
        }
        _ = try db.query("PRAGMA wal_checkpoint(PASSIVE);")
        // Existing databases may not support incremental vacuum. Physical compaction
        // then requires a deliberately drained VACUUM; allocated free pages are reused.
        try db.execute("PRAGMA incremental_vacuum(256);")
        return HistoryArchiveResult(archive: archive, jobsRemoved: jobsRemoved, auditsRemoved: auditsRemoved)
    }

    private static func rotateArchives(directory: String, keeping: Int) throws {
        let files = FileManager.default
        let archives = try files.contentsOfDirectory(atPath: directory).filter {
            $0.hasPrefix("history-") && $0.hasSuffix(".sqlite")
        }.sorted {
            let a =
                (try? files.attributesOfItem(atPath: directory + "/" + $0)[.modificationDate] as? Date) ?? .distantPast
            let b =
                (try? files.attributesOfItem(atPath: directory + "/" + $1)[.modificationDate] as? Date) ?? .distantPast
            return a == b ? $0 > $1 : a > b
        }
        for name in archives.dropFirst(keeping) { try files.removeItem(atPath: directory + "/" + name) }
        try Database.syncDirectory(directory)
    }
}
