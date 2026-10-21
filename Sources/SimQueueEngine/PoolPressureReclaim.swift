// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueStore

extension Engine {
    static let pressureShutdownAuditType = "pool_pressure_shutdown"
    private static let pressureShutdownPrefix = "pressure-shutdown-v1 "

    private struct PressureShutdown: Codable {
        var original: PoolSim
        var barrier: PoolSim
        var owner: OwnedResource
        var pressure: MemoryPressure
    }

    /// Pressure relief is independent of queued demand and warm_min. Limit each pass
    /// to one shutdown so the next fresh host sample decides whether more is needed.
    /// Leased/tainted/unknown sims and pending host work are never relief candidates.
    func reclaimPoolMemory(
        config: SimPoolConfig, unleasedUsers: Set<String>, reported: inout Set<String>, hostWork: PoolHostWork
    ) throws
        -> PoolPassReport
    {
        var report = PoolPassReport()
        guard try store.pendingActionIntents().isEmpty else { return report }
        let candidates = try store.poolSims().filter {
            $0.phase == .ready && $0.leaseID == nil && $0.holderPID == nil && $0.holderIdentity == nil
                && !$0.tainted && !unleasedUsers.contains($0.udid) && environment.naming.owns($0.name)
                && !environment.naming.isTemplate($0.name) && $0.name != environment.sims.cloneSource
        }.sorted { ($0.lastUsedAt, $0.udid) < ($1.lastUsedAt, $1.udid) }
        for candidate in candidates {
            guard let owner = try pressureShutdownOwner(udid: candidate.udid) else { continue }
            var devices: [SimDevice] = []
            try hostWork { devices = try self.environment.sims.listDevices() }
            // Inventory runs unlocked: a caller may have leased/removed/replaced the
            // row or ownership while it ran. Require the complete original snapshot.
            guard try store.poolSims().first(where: { $0.udid == candidate.udid }) == candidate,
                try pressureShutdownOwner(udid: candidate.udid) == owner,
                try store.pendingActionIntents().isEmpty,
                devices.filter({ $0.udid == candidate.udid }).count == 1,
                let device = devices.first(where: { $0.udid == candidate.udid }),
                device.name == candidate.name, device.state == "Booted", device.isBooted
            else { continue }
            let now = environment.clock.now()
            let fresh = try environment.probe.sample(now: now)
            recordSwapSample(fresh, at: now)
            guard fresh.memoryPressure >= scheduler.config.pressureStop else { return report }
            let action = SimPoolAction.shutdown(udid: candidate.udid)
            report.actions = [action]
            guard config.actsOnHost(cleanupMode: reliability.cleanupMode) else {
                report.wouldExecute = [action]
                let key = "pressure-shutdown(\(candidate.udid))"
                reported.insert(key)
                if !poolReportedActions.contains(key) {
                    try store.audit("pool_would_execute", detail: key, now: now)
                }
                return report
            }
            let barrier = try candidate.applying(.shutDown, now: now)
            let proof = PressureShutdown(
                original: candidate, barrier: barrier, owner: owner, pressure: fresh.memoryPressure)
            let detail = Self.pressureShutdownPrefix + String(decoding: try JSONEncoder().encode(proof), as: UTF8.self)
            let intent = try store.database.immediateTransaction {
                let intent = try store.recordActionIntent(
                    ActionIntent(
                        target: .sim(udid: candidate.udid), auditType: Self.pressureShutdownAuditType,
                        detail: detail, resourceID: owner.id), now: now)
                try store.savePoolSim(barrier)
                return intent
            }
            hostActionIntentsInFlight.insert(intent.id)
            defer { hostActionIntentsInFlight.remove(intent.id) }
            do {
                // The persisted barrier prevents lease acquisition before unlocking.
                try hostWork { try self.environment.sims.shutdownDevice(udid: candidate.udid) }
                try recoverPressureShutdown(intent, proof: proof, hostWork: hostWork)
                let sampledAt = environment.clock.now()
                recordSwapSample(try environment.probe.sample(now: sampledAt), at: sampledAt)
            } catch {
                // Keep durable proof and its barrier if verification/database work
                // failed. The next serialized pass resolves it before any pool action.
                report.failures.append("pressure shutdown \(candidate.udid): \(error)")
            }
            return report
        }
        return report
    }

    private func pressureShutdownOwner(udid: String) throws -> OwnedResource? {
        guard try !store.liveResources(kinds: [.template]).contains(where: { $0.externalID == udid }),
            environment.sims.cloneSource?.caseInsensitiveCompare(udid) != .orderedSame
        else { return nil }
        let owners = try store.liveResources(kinds: [.sim]).filter { $0.externalID == udid }
        guard owners.count == 1, let owner = owners.first, owner.owner == .pool,
            owner.state == .active, owner.epoch == epoch
        else { return nil }
        return owner
    }

    /// Unlike delete intents, a shutdown is successful with its target still present.
    /// Recovery only observes: it never shuts down or adopts an ambiguous device.
    func recoverPressureShutdowns(hostWork: PoolHostWork) throws {
        for intent in try store.pendingActionIntents() where intent.auditType == Self.pressureShutdownAuditType {
            if hostActionIntentsInFlight.contains(intent.id) { continue }
            guard intent.detail.hasPrefix(Self.pressureShutdownPrefix),
                let proof = try? JSONDecoder().decode(
                    PressureShutdown.self, from: Data(intent.detail.dropFirst(Self.pressureShutdownPrefix.count).utf8)),
                intent.target == .sim(udid: proof.original.udid),
                proof.original.phase == .ready, proof.original.leaseID == nil,
                proof.original.holderPID == nil, proof.original.holderIdentity == nil, !proof.original.tainted,
                proof.owner.kind == .sim, proof.owner.externalID == proof.original.udid,
                proof.owner.owner == .pool, proof.owner.state == .active,
                environment.naming.owns(proof.original.name), !environment.naming.isTemplate(proof.original.name),
                (try? proof.original.applying(.shutDown, now: proof.barrier.phaseSince)) == proof.barrier
            else { throw PoolError.pressureRecoveryBlocked("invalid pressure-shutdown proof") }
            try recoverPressureShutdown(intent, proof: proof, hostWork: hostWork)
        }
    }

    private func recoverPressureShutdown(_ intent: ActionIntent, proof: PressureShutdown, hostWork: PoolHostWork) throws
    {
        var devices: [SimDevice] = []
        try hostWork { devices = try self.environment.sims.listDevices() }
        let current = try store.poolSims().first(where: { $0.udid == proof.original.udid })
        let targets = devices.filter { $0.udid == proof.original.udid }
        // Startup reconciliation may already have dropped a vanished pool row and
        // released its ledger entry. Absence verifies the old operation without
        // recreating that row or requiring an ownership entry for a missing device.
        if targets.isEmpty, current == nil || current == proof.barrier {
            let oldOwner = try store.resource(id: proof.owner.id)
            let liveOwners = try store.liveResources(kinds: [.sim]).filter { $0.externalID == proof.original.udid }
            guard
                oldOwner.map({
                    $0.kind == .sim && $0.externalID == proof.original.udid && $0.owner == .pool
                        && $0.generation >= proof.owner.generation
                }) ?? true,
                liveOwners.allSatisfy({ $0.id == proof.owner.id && $0.owner == .pool })
            else {
                throw PoolError.pressureRecoveryBlocked("pressure-shutdown absent target has replacement ownership")
            }
            var confirmed = intent
            confirmed.detail =
                "\(proof.original.udid) pressure=\(proof.pressure.rawValue); target absent at verification"
            try store.confirmActionIntent(confirmed, now: environment.clock.now())
            return
        }
        guard current == proof.barrier,
            let owner = try pressureShutdownOwner(udid: proof.original.udid),
            owner.id == proof.owner.id, owner.generation >= proof.owner.generation,
            environment.naming.owns(proof.original.name), !environment.naming.isTemplate(proof.original.name)
        else { throw PoolError.pressureRecoveryBlocked("pressure-shutdown ownership or row changed") }
        guard targets.count <= 1,
            targets.allSatisfy({
                $0.name == proof.original.name && ["Booted", "Shutdown"].contains($0.state ?? "")
                    && $0.isBooted == ($0.state == "Booted")
            })
        else { throw PoolError.pressureRecoveryBlocked("pressure-shutdown target has an unknown identity or state") }
        let now = environment.clock.now()
        if targets.first?.state == "Booted" {
            try store.database.immediateTransaction {
                try store.savePoolSim(proof.original)
                try store.abandonActionIntent(
                    intent, reason: "simulator is still booted; ready state restored", now: now)
            }
        } else {
            var confirmed = intent
            confirmed.detail = "\(proof.original.udid) pressure=\(proof.pressure.rawValue); idle pool memory reclaimed"
            try store.confirmActionIntent(confirmed, now: now)
        }
    }
}
