// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueStore

/// What recovery did with intents left behind by a crash or a database failure.
public struct ActionIntentRecovery: Sendable, Equatable {
    /// The target is gone: the action happened and is audited now.
    public var confirmed: [ActionIntent] = []
    /// The target is still there: the action never completed.
    public var abandoned: [ActionIntent] = []

    public init() {}
}

extension Engine {
    /// Runs a destructive host action under a write-ahead intent. The intent is written
    /// first, so a database that can't take it stops the action before it starts. `action`
    /// performs and verifies the action (throwing if the target survived). On success the
    /// audit entry, the row release and the intent's removal land in one transaction; if
    /// that write fails, the intent stays behind and recovery audits the action later.
    func performUnderIntent(_ intent: ActionIntent, now: Double, action: () throws -> Void) throws {
        let recorded = try store.recordActionIntent(intent, now: now)
        // A pool worker can release the service lock during a slow host action. Its
        // write-ahead record belongs to the live worker until verification/commit ends;
        // watchdog recovery must never settle that record as if its owner had crashed.
        hostActionIntentsInFlight.insert(recorded.id)
        defer { hostActionIntentsInFlight.remove(recorded.id) }
        try Self.finishRecordedIntent(recorded, store: store, now: now, action: action)
    }

    static func performUnderIntent(
        _ intent: ActionIntent, store: JobStore, now: Double, action: () throws -> Void
    ) throws {
        let recorded = try store.recordActionIntent(intent, now: now)
        try finishRecordedIntent(recorded, store: store, now: now, action: action)
    }

    private static func finishRecordedIntent(
        _ recorded: ActionIntent, store: JobStore, now: Double, action: () throws -> Void
    ) throws {
        do {
            try action()
        } catch {
            // Best effort: if this write fails too, recovery finds the target and abandons it.
            try? store.abandonActionIntent(recorded, reason: "\(error)", now: now)
            throw error
        }
        try store.confirmActionIntent(recorded, now: now)
    }

    /// Settles intents with no outcome: a target that's gone was acted on (audited now,
    /// once, with the intent's audit type); one that's still there wasn't (abandoned).
    /// Runs at the start of every reconcile; costs one empty query in normal operation.
    @discardableResult
    public func resolveActionIntents() throws -> ActionIntentRecovery {
        var recovery = ActionIntentRecovery()
        let pending = try store.pendingActionIntents()
        guard !pending.isEmpty else { return recovery }
        let now = environment.clock.now()
        for intent in pending {
            // A template build in progress (its create runs without the service lock).
            if templateBuildsInFlight.contains(intent.id) || hostActionIntentsInFlight.contains(intent.id) { continue }
            // Pool clones have a separate durable phase/proof protocol. The worker
            // cleans interrupted started operations; inventory presence is never success.
            if Self.isPoolCloneOperation(intent) { continue }
            let present: Bool
            switch intent.target {
            case .processGroup(let pgid): present = try environment.processes.liveProcessGroups().contains(pgid)
            case .sim(let udid): present = try environment.sims.listDevices().contains { $0.udid == udid }
            case .path(let path): present = environment.fileSystem.fileExists(path)
            case .simCreate(let name):
                // A create is the other way round: a sim with the name means it happened.
                // Its pool row may be missing; the watchdog then sees an owned-namespace sim
                // without an ownership row and handles it like any other leftover.
                if let device = try environment.sims.listDevices().first(where: { $0.name == name }) {
                    // A template build that died between create and register: register it now.
                    _ = try recoverTemplateCreate(intent, device: device, now: now)
                    try store.confirmActionIntent(intent, detailSuffix: " (confirmed by recovery)", now: now)
                    recovery.confirmed.append(intent)
                } else {
                    try store.abandonActionIntent(intent, reason: "no sim named \(name) at recovery", now: now)
                    recovery.abandoned.append(intent)
                }
                continue
            }
            if present {
                try store.abandonActionIntent(
                    intent, reason: "target still present at recovery; the action never completed", now: now)
                recovery.abandoned.append(intent)
            } else {
                try store.confirmActionIntent(intent, detailSuffix: " (confirmed by recovery)", now: now)
                recovery.confirmed.append(intent)
            }
        }
        return recovery
    }
}
