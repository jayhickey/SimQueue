// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore

extension JobStore {
    @discardableResult
    public func createOutputHold(id: String, label: String, now: Double) throws -> OutputHold {
        let id = try OutputHold.canonicalID(id)
        try OutputHold.validateLabel(label)
        try validateHoldTime(now)
        return try database.immediateTransaction {
            if let existing = try outputHold(id: id) {
                guard existing.label == label, existing.releasedAt == nil else {
                    throw OutputHoldError.conflict(
                        "output hold UUID already used with another label or permanently released")
                }
                return existing
            }
            try checkHistoryStoragePressure()
            try database.run(
                "INSERT INTO output_holds(id,label,created_at) VALUES(?,?,?);",
                [.text(id), .text(label), .real(now)])
            try audit("output_hold_created", detail: id, now: now)
            return OutputHold(id: id, label: label, createdAt: now)
        }
    }

    public func outputHold(id: String) throws -> OutputHold? {
        let id = try OutputHold.canonicalID(id)
        return try database.query("SELECT * FROM output_holds WHERE id=?;", [.text(id)]).first.map(decodeOutputHold)
    }

    /// Keyset pagination, including released tombstones. No unbounded membership reads.
    public func outputHolds(afterID: String? = nil, limit: Int = 100) throws -> [OutputHold] {
        try validateHoldPage(limit)
        let after = try afterID.map(OutputHold.canonicalID) ?? ""
        return try database.query(
            "SELECT * FROM output_holds WHERE id > ? ORDER BY id LIMIT ?;", [.text(after), .integer(Int64(limit))]
        ).map(decodeOutputHold)
    }

    public func outputHoldJobs(id: String, afterJobID: String? = nil, limit: Int = 100) throws -> [OutputHoldMembership]
    {
        let id = try OutputHold.canonicalID(id)
        try validateHoldPage(limit)
        guard try outputHold(id: id) != nil else { throw OutputHoldError.notFound(id) }
        guard (afterJobID?.utf8.count ?? 0) <= 256 else {
            throw OutputHoldError.invalidArgument("membership cursor is too long")
        }
        return try database.query(
            "SELECT job_id,attached_at FROM output_hold_jobs WHERE hold_id=? AND job_id > ? ORDER BY job_id LIMIT ?;",
            [.text(id), .text(afterJobID ?? ""), .integer(Int64(limit))]
        ).map { row in
            guard let jobID = row.string("job_id"), let at = row.double("attached_at") else {
                throw JobStoreError.corruptRow("output hold membership")
            }
            return OutputHoldMembership(jobID: jobID, attachedAt: at)
        }
    }

    /// Authoritative deletion veto. Lookup errors propagate to every retention caller.
    public func hasActiveOutputHold(jobID: String) throws -> Bool {
        try database.query(
            """
            SELECT 1 FROM output_hold_jobs m JOIN output_holds h ON h.id=m.hold_id
            WHERE m.job_id=? AND h.released_at IS NULL LIMIT 1;
            """, [.text(jobID)]
        ).first != nil
    }

    /// No terminal adoption. The submission and membership commit before scheduler observation.
    /// The daemon serializes this with removal-intent creation and release under its lock.
    public func submitHeld(
        _ submission: JobSubmission, holdID: String, artifactsRoot: String, keepArtifacts: Bool = false, now: Double
    ) throws -> SubmitResult {
        let id = try OutputHold.canonicalID(holdID)
        try validateSubmission(submission)
        try validateHoldTime(now)
        return try database.immediateTransaction {
            guard let hold = try outputHold(id: id) else { throw OutputHoldError.notFound(id) }
            guard hold.releasedAt == nil else { throw OutputHoldError.conflict("output hold is permanently released") }
            guard now >= hold.createdAt else {
                throw OutputHoldError.invalidArgument("attachment precedes hold creation")
            }
            let result = try submitInTransaction(submission, now: now)
            let job = result.job
            // Check both job identity and overlapping paths, including ancestor/DerivedData
            // intents without a job id, and interrupted intents left for recovery.
            let root = job.command?.artifactsRoot ?? artifactsRoot
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            // JobArtifacts uses Timestamp's millisecond-rounded UTC date, including
            // values immediately before midnight that round into the following day.
            let path =
                (root + "/"
                + formatter.string(from: Date(timeIntervalSince1970: (job.createdAt * 1000).rounded() / 1000)) + "/"
                + job.id
                as NSString).standardizingPath
            let overlapping =
                try database.query(
                    """
                    SELECT 1 FROM action_intents WHERE job_id=? OR
                    (target_kind='path' AND (target=? OR substr(?,1,length(rtrim(target,'/'))+1)=rtrim(target,'/') || '/'
                    OR substr(target,1,length(?)+1)=? || '/')) LIMIT 1;
                    """, [.text(job.id), .text(path), .text(path), .text(path), .text(path)]
                ).first != nil
            guard !overlapping else {
                throw OutputHoldError.inUse(
                    "output removal/recovery intent overlaps job \(job.id); protection was not attached")
            }
            try database.run(
                "INSERT INTO output_hold_jobs(hold_id,job_id,attached_at) VALUES(?,?,?) ON CONFLICT(hold_id,job_id) DO NOTHING;",
                [.text(id), .text(job.id), .real(now)])
            if database.changes != 0 {
                try audit("output_hold_attached", jobID: job.id, detail: id, now: now)
            }
            // A protected submit's optional legacy pin is part of the same commit.
            // Ordinary submit retains its existing independent pin behavior.
            if keepArtifacts, try auditEntries(jobID: job.id, type: "artifact_keep").isEmpty {
                let deduplicated: Bool
                if case .deduplicated = result { deduplicated = true } else { deduplicated = false }
                try audit(
                    "artifact_keep", jobID: job.id,
                    detail: deduplicated ? "--keep (deduplicated submit)" : "--keep", now: now)
            }
            return result
        }
    }

    /// The service supplies executor/preparation writers while holding its state lock.
    /// Durable live-process rows include unresolved spawn tokens and orphaned groups.
    @discardableResult
    public func releaseOutputHold(id: String, writersInFlight: Set<String> = [], now: Double) throws -> OutputHold {
        let id = try OutputHold.canonicalID(id)
        try validateHoldTime(now)
        return try database.immediateTransaction {
            guard var hold = try outputHold(id: id) else { throw OutputHoldError.notFound(id) }
            if hold.releasedAt != nil { return hold }
            let busy =
                try database.query(
                    """
                    SELECT 1 FROM output_hold_jobs m JOIN jobs j ON j.id=m.job_id WHERE m.hold_id=? AND
                    (j.state IN ('queued','admitted','running') OR EXISTS(
                    SELECT 1 FROM owned_resources r WHERE r.owner_job_id=j.id AND r.kind='process_group' AND r.state!='released')
                    OR EXISTS(SELECT 1 FROM action_intents i WHERE i.target_kind='process_group' AND
                    (i.job_id=j.id OR i.resource_id IN (SELECT id FROM owned_resources WHERE owner_job_id=j.id)))) LIMIT 1;
                    """, [.text(id)]
                ).first != nil
            guard !busy else {
                throw OutputHoldError.inUse("output hold has active jobs or unresolved command processes")
            }
            for jobID in writersInFlight {
                if try database.query(
                    "SELECT 1 FROM output_hold_jobs WHERE hold_id=? AND job_id=?;", [.text(id), .text(jobID)]
                ).first != nil {
                    throw OutputHoldError.inUse("output hold has an executor/preparation writer")
                }
            }
            let lastAttachment = try database.query(
                "SELECT MAX(attached_at) AS at FROM output_hold_jobs WHERE hold_id=?;", [.text(id)]
            ).first?.double("at")
            guard now >= max(hold.createdAt, lastAttachment ?? hold.createdAt) else {
                throw OutputHoldError.invalidArgument("release precedes hold creation or attachment")
            }
            try database.run("UPDATE output_holds SET released_at=? WHERE id=?;", [.real(now), .text(id)])
            try audit("output_hold_released", detail: id, now: now)
            hold.releasedAt = now
            return hold
        }
    }

    private func decodeOutputHold(_ row: Row) throws -> OutputHold {
        guard let id = row.string("id"), let label = row.string("label"), let createdAt = row.double("created_at")
        else {
            throw JobStoreError.corruptRow("output hold")
        }
        return OutputHold(id: id, label: label, createdAt: createdAt, releasedAt: row.double("released_at"))
    }

    private func validateHoldTime(_ now: Double) throws {
        guard now.isFinite, now >= 0 else {
            throw OutputHoldError.invalidArgument("hold timestamp must be finite and nonnegative")
        }
    }

    private func validateHoldPage(_ limit: Int) throws {
        guard (1...200).contains(limit) else { throw OutputHoldError.invalidArgument("limit must be 1...200") }
    }
}
