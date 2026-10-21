// SPDX-License-Identifier: MIT

import SimQueueCore

extension JobStore {
    /// Writes the intent before a destructive action. If this throws, the action must not run.
    @discardableResult
    public func recordActionIntent(_ intent: ActionIntent, now: Double) throws -> ActionIntent {
        try database.run(
            """
            INSERT INTO action_intents (target_kind, target, audit_type, detail, job_id, resource_id,
                release_reason, created_at, pass_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            [
                .text(intent.target.kind), .text(intent.target.value), .text(intent.auditType), .text(intent.detail),
                .optional(intent.jobID), intent.resourceID.map { .integer($0) } ?? .null,
                .optional(intent.releaseReason), .real(now), .optional(currentPassID),
            ])
        var stored = intent
        stored.id = database.lastInsertRowID
        stored.createdAt = now
        stored.passID = currentPassID
        return stored
    }

    /// The action happened and was verified: its audit entry, the release of its ownership
    /// row and the removal of the intent land together, or not at all.
    public func confirmActionIntent(_ intent: ActionIntent, detailSuffix: String = "", now: Double) throws {
        try database.immediateTransaction {
            try event(
                intent.jobID, intent.auditType, detail: intent.detail + detailSuffix, resourceID: intent.resourceID,
                at: now)
            if let id = intent.resourceID, let reason = intent.releaseReason, let row = try resource(id: id),
                row.state != .released
            {
                try setState(row, .released, reason: reason, now: now)
            }
            try database.run("DELETE FROM action_intents WHERE id = ?;", [.integer(intent.id)])
        }
    }

    /// Records an intent whose target needs the intent's own id (a sim create names the
    /// sim after it): written with `target(id)` in one transaction.
    public func recordActionIntent(
        _ intent: ActionIntent, now: Double, target: (Int64) -> ActionTarget
    ) throws -> ActionIntent {
        try database.immediateTransaction {
            var stored = try recordActionIntent(intent, now: now)
            stored.target = target(stored.id)
            try database.run(
                "UPDATE action_intents SET target_kind = ?, target = ? WHERE id = ?;",
                [.text(stored.target.kind), .text(stored.target.value), .integer(stored.id)])
            return stored
        }
    }

    /// Rewrites a pending intent's detail (e.g. a template build's pending record, which
    /// needs the name the intent id gave it).
    public func updateActionIntentDetail(_ intent: ActionIntent) throws {
        try database.run(
            "UPDATE action_intents SET detail = ? WHERE id = ?;",
            [SQLValue.optional(intent.detail), .integer(intent.id)])
    }

    /// The action didn't happen (it failed, or recovery found the target still there).
    public func abandonActionIntent(_ intent: ActionIntent, reason: String, now: Double) throws {
        try database.immediateTransaction {
            try event(
                intent.jobID, "action_intent_abandoned", detail: "\(intent.detail): \(reason)",
                resourceID: intent.resourceID, at: now)
            try database.run("DELETE FROM action_intents WHERE id = ?;", [.integer(intent.id)])
        }
    }

    /// Intents with no outcome yet, oldest first. Empty in normal operation.
    public func pendingActionIntents() throws -> [ActionIntent] {
        try database.query("SELECT * FROM action_intents ORDER BY id;").compactMap { row in
            guard let id = row.int("id"), let kind = row.string("target_kind"), let value = row.string("target"),
                let target = ActionTarget(kind: kind, value: value), let auditType = row.string("audit_type"),
                let detail = row.string("detail"), let createdAt = row.double("created_at")
            else { return nil }
            return ActionIntent(
                id: id, target: target, auditType: auditType, detail: detail, jobID: row.string("job_id"),
                resourceID: row.int("resource_id"), releaseReason: row.string("release_reason"),
                createdAt: createdAt, passID: row.string("pass_id"))
        }
    }
}
