// SPDX-License-Identifier: MIT

import Dispatch
import Foundation
import SimQueueCore
import SimQueueHost
import SimQueueSim
import SimQueueStore

/// What one pool pass did.
public struct PoolPassReport: Sendable, Equatable {
    public var actions: [SimPoolAction] = []
    /// Boots held back because host load1 was above the boot gate (`boot_load_per_core` x cores).
    public var bootsDeferredForLoad: [String] = []
    public var bootsDeferredForResources: [String] = []
    public var createsDeferredForResources = 0
    public var createsDeferredForLoad = 0
    public var log: [SimPoolLogEntry] = []
    public var failures: [String] = []
    /// Sims taken back from jobs that ended.
    public var releasedFromJobs: [String] = []
    /// Report-only mode: host actions (create, boot, shutdown, recycle) planned but not taken.
    public var wouldExecute: [SimPoolAction] = []
    /// Recycles (a sim delete) held back by the destructive-action limits.
    public var recyclesPostponed: [String] = []
    /// Boots held back because another tool's sim (`external_sim_patterns`) is booted.
    public var bootsDeferredForExternal: [String] = []
    /// Creates held back for the same reason (counted: they have no UDID yet).
    public var createsDeferredForExternal = 0
    /// Creates held back because the backend has no template to clone yet
    /// (`noTemplateMessage`: run `simq template build`).
    public var createsDeferredNoTemplate = 0
    /// Creates held back because the template they would clone is registered but not
    /// `ready` (`unverified` after a crash mid-build, or `slim_failed`).
    public var createsDeferredUnreadyTemplate = 0
}

/// What a startup pool reconcile changed.
public struct PoolReconcileReport: Sendable, Equatable {
    /// Pool rows whose sim no longer exists (dropped; the sim was deleted outside SimQueue).
    public var vanished: [String] = []
    /// Sims caught mid-boot or mid-settle: re-gated from now.
    public var resettled: [String] = []
    /// Sims caught mid-boot that weren't booted: back to shut down.
    public var resetToShutdown: [String] = []
}

/// What one watchdog pass did with stale manual leases.
public struct StaleLeaseReport: Sendable, Equatable {
    public var reclaimed: [String] = []
    /// Report-only: reported (once) and kept.
    public var reported: [String] = []
    /// Held back by the per-pass or hourly limit until the next window.
    public var postponed: [String] = []
    public var hourlyLimitHit = false
    public init() {}
}

public enum PoolError: Error, Equatable, CustomStringConvertible {
    case notLeased(String)
    case holderNotRunning(Int32)
    case cloneRecoveryBlocked(String)
    public var description: String {
        switch self {
        case .notLeased(let udid): "pool sim \(udid) isn't leased"
        case .holderNotRunning(let pid): "lease holder pid \(pid) isn't running"
        case .cloneRecoveryBlocked(let detail):
            "pool clone recovery blocked: \(detail); inspect doctor and preserve the pending intent"
        }
    }
}

/// Runs a pool pass's slow host work: a sim create (a simslim clone) or a boot. The daemon
/// passes one that drops its service lock for the call, so requests are answered while
/// simctl works; the pass re-reads the state it commits after it. The default runs inline.
public typealias PoolHostWork = (() throws -> Void) throws -> Void

extension Engine {
    /// Runs `body` inline (no lock to drop).
    public static func inlineHostWork(_ body: () throws -> Void) throws { try body() }

    /// Milliseconds since `start` (`DispatchTime` uptime nanoseconds), for audit durations.
    static func elapsedMilliseconds(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
    }

    /// The lease id a job's pool sims carry.
    public static func poolLeaseID(jobID: String) -> String { "job:\(jobID)" }

    /// Check before any ready clone can be counted or leased, including a control
    /// request racing the first pool worker pass after a template change.
    func requireCompatiblePoolTemplate() throws {
        if let selected = environment.sims.templateCloneSource?.cloneTemplate {
            let entries = try templates()
            let selectedID =
                entries.first { $0.record.udid == selected || $0.record.name == selected }?.record.udid ?? selected
            let incompatible = try store.poolSims().filter {
                guard let clone = $0.clonedFrom else { return true }
                if let recordedID = clone.udid { return recordedID != selectedID }
                return clone.name != selected
            }
            guard incompatible.isEmpty else {
                throw TemplateError.poolDisabled(
                    "active template differs from existing pool clones. Drain all jobs and leases, remove the old pool with simq uninstall --yes (templates and state kept), then restart with the selected simctl.template; no old clone was handed out"
                )
            }
        }
    }

    /// Pool counts for the scheduler: ready sims are idle, leased ones busy, and booting
    /// or settling ones count as boots in progress.
    public func poolCapacity() throws -> PoolSnapshot {
        let compatible = (try? requireCompatiblePoolTemplate()) != nil
        let sims = try store.poolSims()
        let unsafe = try unverifiedSlimCloneIDs(sims)
        let pendingBoots = try store.pendingActionIntents().filter {
            guard Self.isPoolCloneOperation($0) else { return false }
            return environment.sims.createBoots || ((try? Self.poolCloneOperation($0).plan.boots) ?? true)
        }.count
        return PoolSnapshot(
            idleRunning: compatible
                ? SimPoolPlanner.handoffCandidates(sims.filter { !unsafe.contains($0.udid) }, unleasedUsers: []).count
                : 0,
            busyRunning: sims.filter { $0.phase == .leased }.count,
            bootsInProgress: sims.filter(\.holdsBootSlot).count + pendingBoots)
    }

    /// Sims waiting jobs need: the minimum sims of every queued job. Given the host's
    /// available memory, a job memory admission would refuse right now (its memory plus its
    /// sims' over what's left above `reserve_bytes`) doesn't count: booting a sim for it
    /// only holds memory and load while it waits (session 3: a 40 GiB job caused a boot).
    /// It counts each job's `min_sims` and raw requested memory and ignores every other
    /// admission rule, so it errs toward counting demand (a sim may boot for a job that
    /// waits for another reason). Near the limit, a sim just handed off is already out of
    /// the available memory and charged again here, so a job can drop out of demand and
    /// the handed-off sim be shut down and booted again later: one extra boot, never an
    /// over-commit.
    public func poolDemand(availableMemoryBytes: UInt64? = nil) throws -> Int {
        let reserve = scheduler.config.reserveBytes
        return try store.queuedJobs().reduce(0) { total, job in
            let resources = job.resources
            if let available = availableMemoryBytes {
                let needed = resources.memoryCost(
                    sims: resources.minSims, minimum: scheduler.config.minimumJobMemoryBytes)
                guard available >= reserve, available - reserve >= needed else { return total }
            }
            let capacity = max(0, pool?.maxSims ?? scheduler.config.maxRunningSims)
            return total + min(max(0, resources.minSims), max(0, capacity - total))
        }
    }

    /// UDIDs of the pool sims leased to a job, oldest first (`SIMQ_SIM_UDIDS`).
    public func poolSimUDIDs(jobID: String) throws -> [String] {
        try store.poolSims().filter { $0.leaseID == Self.poolLeaseID(jobID: jobID) }.map(\.udid)
    }

    /// Leases `count` ready sims to an admitted job. Admission only counts ready sims, so
    /// a shortfall means the pool changed in between: audited, and the job runs with what
    /// it got (its grant stays as admitted).
    func leasePoolSims(count: Int, jobID: String, now: Double) throws {
        var leased = 0
        for _ in 0..<count {
            guard try acquirePoolSim(leaseID: Self.poolLeaseID(jobID: jobID)) != nil else { break }
            leased += 1
        }
        if leased < count {
            try store.audit("pool_short", detail: "\(jobID): leased \(leased) of \(count) sims", now: now)
        }
    }

    /// Releases pool sims whose job is no longer active (finished, failed, timed out or
    /// lost in a crash): whatever path ended the job, the next pool pass gets them back.
    /// While queued jobs wait for sims (`demand` beyond the ready and booting sims), a
    /// released sim is handed off: kept booted and made ready for the next job, not shut
    /// down (session 3: a shutdown at release, then a boot deferred by load for 9 minutes,
    /// while two jobs waited). Tainted sims, and sims due for recycling, still shut down.
    /// A pool that takes no host action (`pool.mode`, or report-only `cleanup_mode` under
    /// `follow-cleanup`) only reports the shutdown (`pool_would_execute`, once); the sim
    /// stays leased to the ended job (still booted, never handed out) until the pool acts.
    /// `reported` collects the dedupe keys.
    func releaseSimsOfEndedJobs(
        config: SimPoolConfig, demand: Int = 0, reported: inout Set<String>
    ) throws -> [String] {
        // A job whose sims are still being prepared keeps its lease even if it ended
        // meanwhile (canceled, say): the sim must not be handed to another job mid-erase.
        let live = Set(try store.activeJobs().map(\.id)).union(jobsAwaitingSimPrep)
            .union(try jobsWithLiveProcessGroups())
        let active = Set(live.map { Self.poolLeaseID(jobID: $0) })
        let reportOnly = !config.actsOnHost(cleanupMode: reliability.cleanupMode)
        var released: [String] = []
        let now = environment.clock.now()
        let all = try store.poolSims()
        let coming = all.filter { ($0.phase == .ready || $0.holdsBootSlot) && !$0.tainted }.count
        var waiting = max(0, demand - coming)
        for sim in all where sim.phase == .leased {
            guard let lease = sim.leaseID, lease.hasPrefix("job:"), !active.contains(lease) else { continue }
            if reportOnly {
                let key = "release(\(sim.udid), \(lease))"
                reported.insert(key)
                if !poolReportedActions.contains(key) {
                    try store.audit(
                        "pool_would_execute", detail: "shutdown \(sim.udid) (released from ended \(lease))",
                        now: environment.clock.now())
                }
                continue
            }
            if waiting > 0, !sim.tainted, now - sim.createdAt < config.recycleAfterSeconds {
                try handOffPoolSim(sim, from: lease, waiting: waiting, now: now)
                waiting -= 1
            } else {
                try releasePoolSim(udid: sim.udid, config: config)
            }
            released.append(sim.udid)
        }
        return released
    }

    /// Ends an ended job's lease without a shutdown: the sim stays booted and is ready for
    /// the next job (the same "as the last job left it" a lease always gets). Every pool sim
    /// has the same device type and runtime today, so any waiting job can take it; a pool
    /// that ever mixes types needs a compatibility check here.
    func handOffPoolSim(_ sim: PoolSim, from lease: String, waiting: Int, now: Double) throws {
        try store.savePoolSim(try sim.applying(.handedOff, now: now))
        try store.audit(
            "pool_handed_off", detail: "\(sim.udid) from ended \(lease) (\(waiting) sims wanted)", now: now)
    }

    /// Brings pool rows in line with the sims that exist, after a restart: rows whose sim
    /// is gone are dropped (and their ownership released), a boot that was in flight is
    /// re-gated from now (booted) or reset (not booted). Leased rows are left to the
    /// lease owner's own recovery.
    @discardableResult
    public func reconcilePool() throws -> PoolReconcileReport {
        let now = environment.clock.now()
        let devices = Dictionary(
            try environment.sims.listDevices().map { ($0.udid, $0) }, uniquingKeysWith: { first, _ in first })
        var report = PoolReconcileReport()
        for var sim in try store.poolSims() {
            guard let device = devices[sim.udid] else {
                try dropPoolSim(sim.udid, reason: "pool sim gone at startup", now: now)
                report.vanished.append(sim.udid)
                continue
            }
            switch sim.phase {
            case .booting, .settling:
                if device.isBooted {
                    sim.phase = .settling
                    report.resettled.append(sim.udid)
                } else {
                    sim.phase = .shutdown
                    report.resetToShutdown.append(sim.udid)
                }
                sim.phaseSince = now
                try store.savePoolSim(sim)
            case .shutdown, .ready, .leased, .recycling:
                break
            }
        }
        if report != PoolReconcileReport() {
            try store.audit(
                "pool_reconciled",
                detail: "vanished=\(report.vanished.count) resettled=\(report.resettled.count) "
                    + "reset=\(report.resetToShutdown.count)", now: now)
        }
        return report
    }

    /// One pool step: plan, gate boots on host load, carry out the actions on the sim
    /// backend and persist every transition. `demand` is the number of callers waiting
    /// for a sim (default: queued jobs' sims, leaving out jobs memory admission would
    /// refuse now), plus `extraDemand` (pending manual leases); `signals` are settle signals for settling sims (load averages come
    /// from the host probe when not given); `unleasedUsers` are pool sims in use without a lease.
    @discardableResult
    public func poolPass(
        config: SimPoolConfig, demand: Int? = nil, extraDemand: Int = 0, signals: [String: SettleSignals] = [:],
        unleasedUsers: Set<String> = [], host: HostSnapshot? = nil, hostWork: PoolHostWork = Engine.inlineHostWork
    ) throws -> PoolPassReport {
        let now = environment.clock.now()
        var reportedNow: Set<String> = []
        refreshDefaultTemplate()
        try requireCompatiblePoolTemplate()
        let noTemplate = environment.sims.templateCloneSource.map { $0.cloneTemplate == nil } ?? false
        let unreadyTemplate = try unreadyCloneTemplate()
        let clonePlan = try selectedClonePlan()
        let creationBoots = environment.sims.createBoots || clonePlan.boots
        var host = try host ?? environment.probe.sample(now: now)
        let capacity = max(0, config.maxSims)
        let baseDemand = min(
            capacity, max(0, try demand ?? poolDemand(availableMemoryBytes: host.availableMemoryBytes)))
        let demand = baseDemand + min(max(0, extraDemand), capacity - baseDemand)
        // Legacy plain/unknown clones of a slim source are never leased again. Keep
        // existing leases valid for release/drain, then recycle through normal policy.
        let oldRows = try store.poolSims()
        let unsafeOldRows = try unverifiedSlimCloneIDs(oldRows)
        for var sim in oldRows where unsafeOldRows.contains(sim.udid) {
            if !sim.tainted { sim.tainted = true; try store.savePoolSim(sim) }
        }
        let releasedFromJobs = try releaseSimsOfEndedJobs(config: config, demand: demand, reported: &reportedNow)
        let recoveryActions = try recoverInterruptedPoolClones(config: config, hostWork: hostWork)
        let unresolvedClone = try store.pendingActionIntents().contains(where: Self.isPoolCloneOperation)
        var sims = try store.poolSims()
        // Taint sims in use without a lease first, so the planner never hands them out.
        for index in sims.indices where unleasedUsers.contains(sims[index].udid) && !sims[index].tainted {
            sims[index] = try sims[index].applying(.unleasedUseSeen, now: now)
            try store.savePoolSim(sims[index])
            try store.audit("pool_unleased_use", detail: sims[index].udid, now: now)
        }
        var allSignals = signals
        for sim in sims where sim.phase == .settling && allSignals[sim.udid] == nil {
            allSignals[sim.udid] = SettleSignals(load5: host.load5, load1: host.load1)
        }
        let input = SimPoolInput(
            sims: sims, demand: demand, signals: allSignals, unleasedUsers: unleasedUsers, now: now,
            createBoots: creationBoots)
        var report = PoolPassReport()
        report.releasedFromJobs = releasedFromJobs
        report.actions = SimPoolPlanner.plan(input, config: config).filter { action in
            guard unresolvedClone else { return true }
            switch action {
            case .create, .boot: return false;
            default: return true
            }
        }
        report.log = SimPoolPlanner.logEntries(for: report.actions, input: input, config: config)
        for entry in report.log {
            try store.audit(entry.type, detail: "\(entry.udid) \(entry.detail)", now: now)
        }
        var byUDID = Dictionary(sims.map { ($0.udid, $0) }, uniquingKeysWith: { first, _ in first })
        // Boot gate: no boot while load1 is above `boot_load_per_core` x the core count (2 by
        // default, borrowed from manzanas; the scheduler's boot gate uses the same limit), nor
        // while another tool's sim is booted (`external_sim_patterns`; never our own).
        let limits = scheduler.config
        var headroom: UInt64 = 0
        var loadOK = false
        var resourcesOK = false
        func updateResourceGates() {
            headroom = host.availableMemoryBytes - min(host.availableMemoryBytes, limits.reserveBytes)
            loadOK = host.load1 <= limits.bootLoadLimit(cpuCount: host.cpuCount)
            resourcesOK =
                host.memoryPressure < limits.pressureStop
                && host.availableMemoryBytes >= limits.reserveBytes
                && headroom >= limits.simBootCostBytes
                && swapTracker.growthBytesPerMinute <= limits.swapGrowthLimitBytesPerMinute
                && host.thermalState < limits.thermalStop
                && host.freeDiskBytes >= limits.minFreeDiskBytes
        }
        updateResourceGates()
        func refreshResourceGatesIfNeeded() throws {
            let sampledNow = environment.clock.now()
            if sampledNow - host.sampledAt >= 1 {
                host = try environment.probe.sample(now: sampledNow)
                recordSwapSample(host, at: sampledNow)
                updateResourceGates()
            }
        }
        var externalBootedNames: Set<String> = []
        func externalSimsBlockBoot() throws -> Bool {
            guard !config.externalSimPatterns.isEmpty else { return false }
            // Inventory is needed only when an otherwise eligible action would boot a
            // simulator. Query immediately before each such action: an idle pool does no
            // simctl work, and a preceding slow host action cannot leave this gate stale.
            let booted = config.externalBootedSims(in: try environment.sims.listDevices()).filter {
                !environment.naming.owns($0.name)
            }
            externalBootedNames.formUnion(booted.map(\.name))
            // Inventory itself can be slow, so its return must not authorize host work
            // using a resource sample taken before that wait.
            try refreshResourceGatesIfNeeded()
            return !booted.isEmpty
        }
        // A pool that doesn't act (pool.mode, or report-only cleanup_mode under
        // follow-cleanup) takes no host action. When it acts, the destructive-action limits
        // still gate recycles: `active` acts on its own sims only, never on the limits.
        let reportOnly = !config.actsOnHost(cleanupMode: reliability.cleanupMode)
        var poolLimits = reliability
        if !reportOnly { poolLimits.cleanupMode = .enforce }
        var gate = CleanupGate(
            config: poolLimits,
            executedLastHour: try store.auditCount(type: Self.destructiveAuditType, since: now - 3600),
            executedThisPass: recoveryActions)
        for action in report.actions {
            // A preceding clone/boot may have taken minutes. Its old capacity cannot
            // authorize the next host action; the scheduling loop samples independently.
            try refreshResourceGatesIfNeeded()
            if reportOnly, action.touchesHost {
                report.wouldExecute.append(action)
                let key = "\(action)"
                reportedNow.insert(key)
                if !poolReportedActions.contains(key) {
                    try store.audit("pool_would_execute", detail: key, now: now)
                }
                continue
            }
            do {
                switch action {
                case .create:
                    // No template to clone yet: wait (no intent, no failed clone) until one is built.
                    guard !noTemplate else {
                        report.createsDeferredNoTemplate += 1
                        continue
                    }
                    // Never clone a template that isn't ready, even one simctl.template names.
                    guard unreadyTemplate == nil else {
                        report.createsDeferredUnreadyTemplate += 1
                        continue
                    }
                    guard resourcesOK else {
                        report.createsDeferredForResources += 1
                        continue
                    }
                    // Creates wait for other tools' booted sims too, like boots.
                    guard try !externalSimsBlockBoot() else {
                        report.createsDeferredForExternal += 1
                        continue
                    }
                    guard resourcesOK else {
                        report.createsDeferredForResources += 1
                        continue
                    }
                    if creationBoots && !loadOK {
                        report.createsDeferredForLoad += 1
                        continue
                    }
                    // Read-only preflight runs unlocked, then this callback applies all
                    // fresh boot gates immediately before the durable started marker.
                    let sim = try createPreparedPoolSim(
                        slot: Self.freeSlot(in: try store.poolSims()), now: now, plan: clonePlan, hostWork: hostWork
                    ) {
                        try refreshResourceGatesIfNeeded()
                        if creationBoots && !loadOK { report.createsDeferredForLoad += 1; return false }
                        guard resourcesOK else { report.createsDeferredForResources += 1; return false }
                        guard try !externalSimsBlockBoot() else { report.createsDeferredForExternal += 1; return false }
                        if creationBoots && !loadOK { report.createsDeferredForLoad += 1; return false }
                        guard resourcesOK else { report.createsDeferredForResources += 1; return false }
                        return true
                    }
                    if let sim { byUDID[sim.udid] = sim }
                case .boot(let udid, let reason):
                    guard loadOK else {
                        report.bootsDeferredForLoad.append(udid)
                        continue
                    }
                    guard resourcesOK else {
                        report.bootsDeferredForResources.append(udid)
                        continue
                    }
                    guard var sim = try currentRow(udid, planned: byUDID[udid], action: action, now: now) else {
                        byUDID[udid] = nil
                        continue
                    }
                    guard try !externalSimsBlockBoot() else {
                        report.bootsDeferredForExternal.append(udid)
                        continue
                    }
                    guard loadOK else {
                        report.bootsDeferredForLoad.append(udid)
                        continue
                    }
                    guard resourcesOK else {
                        report.bootsDeferredForResources.append(udid)
                        continue
                    }
                    sim = try sim.applying(.bootStarted, now: now)
                    try store.savePoolSim(sim)
                    // The boot runs without the daemon's lock (`hostWork`); `booting` holds
                    // its boot slot meanwhile, and the row is re-read before committing.
                    let start = DispatchTime.now().uptimeNanoseconds
                    var bootError: (any Error)?
                    try hostWork {
                        do { try environment.sims.bootDevice(udid: udid) } catch { bootError = error }
                    }
                    let duration = Self.elapsedMilliseconds(since: start)
                    let finishedAt = environment.clock.now()
                    guard let current = try store.poolSims().first(where: { $0.udid == udid }),
                        current.phase == .booting, current.leaseID == sim.leaseID
                    else {
                        try store.audit(
                            "pool_boot_superseded",
                            detail: "\(udid): its row changed while it booted; not committed duration_ms=\(duration)",
                            now: finishedAt)
                        byUDID[udid] = nil
                        continue
                    }
                    if let bootError {
                        sim = try current.applying(.bootFailed, now: finishedAt)
                        report.failures.append("boot \(udid): \(bootError)")
                        try store.audit(
                            "pool_boot_failed",
                            detail: "\(udid) (\(reason.rawValue)) duration_ms=\(duration): \(bootError)",
                            now: finishedAt)
                    } else {
                        sim = try current.applying(.bootFinished, now: finishedAt)
                        try store.audit(
                            "pool_booted", detail: "\(udid) (\(reason.rawValue)) duration_ms=\(duration)",
                            now: finishedAt)
                    }
                    try store.savePoolSim(sim)
                    byUDID[udid] = sim
                case .settled(let udid, _, _):
                    guard var sim = try currentRow(udid, planned: byUDID[udid], action: action, now: now) else {
                        byUDID[udid] = nil
                        continue
                    }
                    sim = try sim.applying(.settled, now: now)
                    try store.savePoolSim(sim)
                    byUDID[udid] = sim
                case .settleFailed(let udid, _):
                    guard var sim = try currentRow(udid, planned: byUDID[udid], action: action, now: now) else {
                        byUDID[udid] = nil
                        continue
                    }
                    try hostWork { try environment.sims.shutdownDevice(udid: udid) }
                    sim = try sim.applying(.settleFailed, now: now)
                    try store.savePoolSim(sim)
                    byUDID[udid] = sim
                case .shutdown(let udid):
                    guard var sim = try currentRow(udid, planned: byUDID[udid], action: action, now: now) else {
                        byUDID[udid] = nil
                        continue
                    }
                    // Publish the handoff barrier before unlocking for shutdown. A ready
                    // row here would let a lease race the host action and be overwritten.
                    sim = try sim.applying(.shutDown, now: environment.clock.now())
                    try store.savePoolSim(sim)
                    byUDID[udid] = sim
                    try hostWork { try environment.sims.shutdownDevice(udid: udid) }
                    // Do not rewrite the row after host work: a control/recovery request
                    // may have removed it while unlocked. The serial worker owns the next boot.
                    try store.audit("pool_idle_shutdown", detail: udid, now: environment.clock.now())
                case .recycle(let udid, let reason):
                    guard var sim = try currentRow(udid, planned: byUDID[udid], action: action, now: now) else {
                        byUDID[udid] = nil
                        continue
                    }
                    guard case .execute = gate.decide(firstSeenAt: now, now: now, graceSeconds: 0) else {
                        report.recyclesPostponed.append(udid)
                        let key = "\(action)"
                        reportedNow.insert(key)
                        if !poolReportedActions.contains(key) {
                            try store.audit(
                                "pool_recycle_postponed",
                                detail:
                                    "\(udid): \(reason); held by the \(gate.hourlyLimitHit ? "hourly" : "per-pass") limit",
                                now: now)
                        }
                        continue
                    }
                    if sim.phase != .recycling {
                        sim = try sim.applying(.recycleStarted, now: now)
                        try store.savePoolSim(sim)
                    }
                    try recyclePoolSim(sim, reason: reason, now: now, hostWork: hostWork)
                    try store.audit(Self.destructiveAuditType, detail: "recycled pool sim \(udid): \(reason)", now: now)
                    byUDID[udid] = nil
                }
            } catch {
                report.failures.append("\(action): \(error)")
                try store.audit("pool_action_failed", detail: "\(action): \(error)", now: now)
            }
        }
        if !report.bootsDeferredForExternal.isEmpty || report.createsDeferredForExternal > 0 {
            let names = externalBootedNames.sorted()
            let key = "external:" + names.joined(separator: ",")
            if !poolReportedActions.contains(key) {
                try store.audit(
                    "pool_boot_deferred_external",
                    detail: "other tools' sims booted (\(names.joined(separator: ", "))): "
                        + (report.bootsDeferredForExternal.isEmpty
                            ? "" : "boots " + report.bootsDeferredForExternal.joined(separator: ", "))
                        + (report.createsDeferredForExternal > 0
                            ? "\(report.bootsDeferredForExternal.isEmpty ? "" : "; ")\(report.createsDeferredForExternal) creates"
                            : ""),
                    now: now)
            }
            reportedNow.insert(key)
        }
        if report.createsDeferredNoTemplate > 0 {
            if !poolReportedActions.contains("no-template") {
                try store.audit(
                    "pool_create_deferred_no_template",
                    detail: "\(report.createsDeferredNoTemplate) creates: \(noTemplateMessage)", now: now)
            }
            reportedNow.insert("no-template")
        }
        if report.createsDeferredUnreadyTemplate > 0, let template = unreadyTemplate {
            let key = "unready-template:\(template.udid)"
            if !poolReportedActions.contains(key) {
                try store.audit(
                    "pool_create_deferred_unready_template",
                    detail: "\(report.createsDeferredUnreadyTemplate) creates: template \(template.name) is "
                        + "\(template.status), not ready; rebuild it with simq template build --replace, "
                        + "or remove it with simq template rm",
                    now: now)
            }
            reportedNow.insert(key)
        }
        if report.createsDeferredForResources > 0 || !report.bootsDeferredForResources.isEmpty {
            let key =
                "resources:\(report.createsDeferredForResources):"
                + report.bootsDeferredForResources.sorted().joined(separator: ",")
            if !poolReportedActions.contains(key) {
                try store.audit(
                    "pool_deferred_resources",
                    detail:
                        "creates=\(report.createsDeferredForResources) boots=\(report.bootsDeferredForResources.count) "
                        + "pressure=\(host.memoryPressure.rawValue) headroom=\(headroom) boot_cost=\(limits.simBootCostBytes) "
                        + "swap=\(host.swapUsedBytes) thermal=\(host.thermalState.rawValue) disk_free=\(host.freeDiskBytes)",
                    now: now)
            }
            reportedNow.insert(key)
        }
        poolReportedActions = reportedNow
        try auditBootDeferral(report.bootsDeferredForLoad, host: host, now: now)
        return report
    }

    /// How often a load deferral that hasn't changed is audited again (`pool_boot_deferred`).
    public static let bootDeferralReminderSeconds: Double = 300

    /// Audits load-deferred boots only when the set of deferred sims changes, plus a reminder
    /// every `bootDeferralReminderSeconds` while it lasts (with how long and how many passes).
    /// Session 3: one row per tick, 662 rows. When nothing is deferred any more, it writes
    /// `pool_boot_resumed` if load1 is back under the gate, else `pool_boot_deferral_ended`
    /// (no sim waits for a boot now, but load is still high). A change in which sims wait
    /// keeps both the start time and the pass count: it's one deferral.
    func auditBootDeferral(_ deferred: [String], host: HostSnapshot, now: Double) throws {
        let current = deferred.sorted()
        let limit = scheduler.config.bootLoadLimit(cpuCount: host.cpuCount)
        let gate = "load1 \(host.load1) above \(limit) (\(scheduler.config.bootLoadFactor)x \(host.cpuCount) cores)"
        guard !current.isEmpty else {
            if let last = bootDeferral {
                let summary = "after \(Int(now - last.since))s (\(last.passes) passes; load1 \(host.load1))"
                if host.load1 <= limit {
                    try store.audit("pool_boot_resumed", detail: "load1 back under \(limit): " + summary, now: now)
                } else {
                    try store.audit(
                        "pool_boot_deferral_ended", detail: "no sim waits for a boot, load still high: " + summary,
                        now: now)
                }
                bootDeferral = nil
            }
            return
        }
        if var last = bootDeferral, last.udids == current {
            last.passes += 1
            if now - last.auditedAt >= Self.bootDeferralReminderSeconds {
                try store.audit(
                    "pool_boot_deferred",
                    detail: "\(gate): " + current.joined(separator: ", ")
                        + " (still deferred after \(Int(now - last.since))s, \(last.passes) passes)", now: now)
                last.auditedAt = now
            }
            bootDeferral = last
            return
        }
        try store.audit("pool_boot_deferred", detail: "\(gate): " + current.joined(separator: ", "), now: now)
        bootDeferral = BootDeferral(
            udids: current, since: bootDeferral?.since ?? now, auditedAt: now, passes: (bootDeferral?.passes ?? 0) + 1)
    }

    /// Hands out the oldest ready sim to `leaseID`, or nil if none is ready (the caller
    /// waits and runs another pool pass; a settling sim is never handed out).
    public func acquirePoolSim(leaseID: String, unleasedUsers: Set<String> = []) throws -> PoolSim? {
        try requireCompatiblePoolTemplate()
        let now = environment.clock.now()
        let rows = try store.poolSims()
        let unsafe = try unverifiedSlimCloneIDs(rows)
        guard
            let candidate = SimPoolPlanner.handoffCandidates(
                rows.filter { !unsafe.contains($0.udid) }, unleasedUsers: unleasedUsers
            ).first
        else { return nil }
        var sim = try candidate.applying(.leased(leaseID: leaseID), now: now)
        sim.lastUsedAt = now
        try store.savePoolSim(sim)
        try store.audit("pool_leased", detail: "\(sim.udid) to \(leaseID)", now: now)
        return sim
    }

    /// Ends a clean lease while retaining the warm simulator state for reuse.
    /// The next pool pass applies taint, recycle and idle-shutdown policies.
    @discardableResult
    public func releasePoolSim(udid: String, config: SimPoolConfig) throws -> PoolSim {
        let now = environment.clock.now()
        guard let current = try store.poolSims().first(where: { $0.udid == udid }), current.phase == .leased else {
            throw PoolError.notLeased(udid)
        }
        let sim: PoolSim
        if current.tainted {
            sim = try current.applying(.released(prewarm: false), now: now).applying(.recycleStarted, now: now)
        } else {
            sim = try current.applying(.handedOff, now: now)
        }
        try store.savePoolSim(sim)
        try store.audit("pool_released", detail: "\(udid)", now: now)
        return sim
    }

    /// Prefix of manual leases (`simq lease acquire`); job leases use `job:`.
    public static let manualLeasePrefix = "lease:"

    /// Grants a manual lease. A `pid` must name a live process; its identity (start time)
    /// is recorded so a reused pid never keeps the lease alive. Nil when no sim is ready.
    public func acquireManualLease(leaseID: String, pid: Int32?) throws -> PoolSim? {
        let identity = try pid.map { pid -> String in
            guard let identity = try environment.processes.processIdentity(pid) else {
                throw PoolError.holderNotRunning(pid)
            }
            return identity
        }
        guard var sim = try acquirePoolSim(leaseID: leaseID) else { return nil }
        sim.holderPID = pid
        sim.holderIdentity = identity
        sim.heartbeatAt = environment.clock.now()
        try store.savePoolSim(sim)
        return sim
    }

    /// Renews a manual lease's heartbeat.
    @discardableResult
    public func renewManualLease(udid: String, leaseID: String) throws -> PoolSim {
        guard var sim = try store.poolSims().first(where: { $0.udid == udid }), sim.phase == .leased,
            sim.leaseID == leaseID
        else { throw PoolError.notLeased(udid) }
        sim.heartbeatAt = environment.clock.now()
        sim.staleReportedAt = nil
        try store.savePoolSim(sim)
        return sim
    }

    /// Why a manual lease no longer protects its sim (nil while its holder is live): the
    /// recorded holder process is gone (pid missing or reused), or, with no pid, its
    /// heartbeat is older than `graceSeconds`.
    public func staleReason(_ sim: PoolSim, now: Double, graceSeconds: Double) throws -> String? {
        guard sim.phase == .leased, let leaseID = sim.leaseID, leaseID.hasPrefix(Self.manualLeasePrefix) else {
            return nil
        }
        if let pid = sim.holderPID {
            let identity = try environment.processes.processIdentity(pid)
            return identity == sim.holderIdentity ? nil : "holder pid \(pid) is gone"
        }
        let beat = sim.heartbeatAt ?? sim.lastUsedAt
        return now - beat > graceSeconds ? "no heartbeat for \(Int(now - beat))s (grace \(Int(graceSeconds))s)" : nil
    }

    /// Watchdog step: manual leases whose holder is gone. Reclaiming shuts a sim down, so
    /// it goes through the same `CleanupGate` as every other cleanup: report-only reports
    /// once, and the per-pass and hourly limits (shared with this pass's other cleanups)
    /// hold a reclaim back to the next window, logged once as `lease_reclaim_postponed`.
    public func reclaimStaleManualLeases(limits: ReliabilityConfig, executedThisPass: Int = 0) throws
        -> StaleLeaseReport
    {
        let now = environment.clock.now()
        var report = StaleLeaseReport()
        var gate = CleanupGate(
            config: limits, executedLastHour: try store.auditCount(type: Self.destructiveAuditType, since: now - 3600),
            executedThisPass: executedThisPass)
        for sim in try store.poolSims() {
            guard let reason = try staleReason(sim, now: now, graceSeconds: limits.orphanGraceSeconds) else { continue }
            let detail = "\(sim.udid) from \(sim.leaseID ?? "?"): \(reason)"
            // The holder check above already applied the grace (heartbeat) or found the
            // holder gone for certain (pid), so the gate only applies mode and limits.
            switch gate.decide(firstSeenAt: now, now: now, graceSeconds: 0) {
            case .execute:
                // A crashed holder may have left unknown state or descendants behind.
                // Recycle through the bounded worker instead of handing it straight out.
                var tainted = sim
                tainted.tainted = true
                try store.savePoolSim(tainted)
                try releasePoolSim(udid: sim.udid, config: pool ?? SimPoolConfig())
                try store.audit("lease_reclaimed", detail: detail, now: now)
                try store.audit(Self.destructiveAuditType, detail: "reclaimed lease \(detail)", now: now)
                report.reclaimed.append(sim.udid)
            case .wouldExecute:
                guard sim.staleReportedAt == nil else { continue }
                try markStaleReported(sim, now: now)
                try store.audit("lease_would_reclaim", detail: detail, now: now)
                report.reported.append(sim.udid)
            case .deferRateLimit, .deferGrace:
                report.postponed.append(sim.udid)
                guard sim.staleReportedAt == nil else { continue }
                try markStaleReported(sim, now: now)
                try store.audit(
                    "lease_reclaim_postponed",
                    detail: "\(detail); held by the \(gate.hourlyLimitHit ? "hourly" : "per-pass") limit", now: now)
            }
        }
        report.hourlyLimitHit = gate.hourlyLimitHit
        return report
    }

    private func markStaleReported(_ sim: PoolSim, now: Double) throws {
        var reported = sim
        reported.staleReportedAt = now
        try store.savePoolSim(reported)
    }

    /// The row for `udid` as the store has it now, or nil (audited `pool_action_skipped_stale`)
    /// unless its phase, lease, `phaseSince` and `lastUsedAt` are still what the pass planned
    /// against. A pass drops the daemon's lock for each boot and create, so a handler can
    /// lease, release or remove a row between the plan and a later action in the same pass;
    /// the timestamps catch a lease and release that land back on the same phase and lease.
    func currentRow(_ udid: String, planned: PoolSim?, action: SimPoolAction, now: Double) throws -> PoolSim? {
        guard let planned else { return nil }
        let current = try store.poolSims().first(where: { $0.udid == udid })
        if let current, current.phase == planned.phase, current.leaseID == planned.leaseID,
            current.phaseSince == planned.phaseSince, current.lastUsedAt == planned.lastUsedAt
        {
            return current
        }
        let found =
            current.map {
                "\($0.phase.rawValue) lease=\($0.leaseID ?? "none") phase_since=\($0.phaseSince) last_used=\($0.lastUsedAt)"
            } ?? "gone"
        try store.audit(
            Self.staleActionAuditType,
            detail:
                "\(action): planned \(planned.phase.rawValue) lease=\(planned.leaseID ?? "none"), found \(found)",
            now: now)
        return nil
    }

    public static let staleActionAuditType = "pool_action_skipped_stale"
    public static let poolCreatedAuditType = "pool_created"
    /// In a pending `pool_created` intent's detail: `clone_of=<template udid>`.
    static let cloneSourceMarker = "clone_of="

    static let poolClonePrefix = "pool-clone-v1 "
    struct PoolCloneOperation: Codable {
        enum Phase: String, Codable { case recorded, prepared, started }
        var plan: SimClonePlan
        var phase: Phase = .recorded
        var preparation: SimClonePreparation?
        var createdUDID: String?
    }
    static func isPoolCloneOperation(_ intent: ActionIntent) -> Bool {
        intent.auditType == poolCreatedAuditType && intent.detail.hasPrefix("pool-clone-")
    }
    static func poolCloneOperation(_ intent: ActionIntent) throws -> PoolCloneOperation {
        guard intent.detail.hasPrefix(poolClonePrefix),
            let value = try? JSONDecoder().decode(
                PoolCloneOperation.self, from: Data(intent.detail.dropFirst(poolClonePrefix.count).utf8))
        else { throw PoolError.cloneRecoveryBlocked("unknown or incomplete clone metadata for intent \(intent.id)") }
        return value
    }
    static func poolCloneDetail(_ operation: PoolCloneOperation) throws -> String {
        poolClonePrefix + String(decoding: try JSONEncoder.sorted.encode(operation), as: UTF8.self)
    }

    func selectedClonePlan() throws -> SimClonePlan {
        guard let selected = environment.sims.cloneSource else { return SimClonePlan(source: nil) }
        if let entry = try templates().first(where: { $0.record.udid == selected || $0.record.name == selected }) {
            return SimClonePlan(
                source: entry.record.udid,
                sourceRef: TemplateRef(udid: entry.record.udid, name: entry.record.name),
                method: entry.record.slimmed == true ? .simslim : .simctl)
        }
        let unreadable = try store.liveResources(kinds: [.template]).filter { resource in
            guard let detail = resource.detail else { return true }
            return (try? JSONDecoder().decode(TemplateRecord.self, from: Data(detail.utf8))) == nil
        }
        if unreadable.contains(where: { $0.externalID == selected })
            || (UUID(uuidString: selected) == nil && !unreadable.isEmpty)
        {
            throw PoolError.cloneRecoveryBlocked(
                "selected template metadata is unreadable or ambiguous; rebuild or select a verified template by UUID")
        }
        return SimClonePlan(source: selected, sourceRef: try cloneSourceRef(selected))
    }

    func unverifiedSlimCloneIDs(_ sims: [PoolSim]) throws -> Set<String> {
        guard try selectedClonePlan().boots else { return [] }
        return Set(sims.filter { $0.cloneMethod != .simslim }.map(\.udid))
    }

    func poolCreatesInFlight(fromTemplate templateName: String, udid templateUDID: String) throws -> [String] {
        try store.pendingActionIntents().compactMap { intent in
            guard intent.auditType == Self.poolCreatedAuditType, case .simCreate(let name) = intent.target else {
                return nil
            }
            if Self.isPoolCloneOperation(intent) {
                guard let plan = try? Self.poolCloneOperation(intent).plan else { return name }
                return plan.source == templateUDID || plan.source == templateName
                    || plan.sourceRef?.name == templateName ? name : nil
            }
            let recorded = intent.detail.components(separatedBy: " ").first { $0.hasPrefix(Self.cloneSourceMarker) }
                .map { String($0.dropFirst(Self.cloneSourceMarker.count)) }
            guard let source = recorded ?? environment.sims.cloneSource else { return nil }
            return source == templateUDID || source == templateName ? name : nil
        }
    }

    /// An interrupted helper never yields a ready clone. Only a durable started
    /// record with preflight proof permits scoped cleanup; unstarted work touched no sim.
    @discardableResult
    func recoverInterruptedPoolClones(config: SimPoolConfig, hostWork: PoolHostWork) throws -> Int {
        var limits = reliability; limits.cleanupMode = .enforce
        var gate = CleanupGate(
            config: limits,
            executedLastHour: try store.auditCount(
                type: Self.destructiveAuditType, since: environment.clock.now() - 3600))
        for intent in try store.pendingActionIntents()
        where Self.isPoolCloneOperation(intent) && !hostActionIntentsInFlight.contains(intent.id) {
            let operation = try Self.poolCloneOperation(intent)
            guard operation.phase == .started else {
                try store.abandonActionIntent(
                    intent, reason: "clone never started; no host mutation", now: environment.clock.now())
                continue
            }
            guard case .simCreate(let name) = intent.target, let prepared = operation.preparation,
                prepared.name == name, prepared.plan == operation.plan,
                !operation.plan.boots || prepared.sourceWasShutdown,
                operation.createdUDID.map({ !prepared.previousUDIDs.contains($0) }) ?? true
            else { throw PoolError.cloneRecoveryBlocked("missing started-operation proof for intent \(intent.id)") }
            guard config.actsOnHost(cleanupMode: reliability.cleanupMode) else { continue }
            guard gate.decide(firstSeenAt: intent.createdAt, now: environment.clock.now(), graceSeconds: 0) == .execute
            else { continue }
            let partialRows = try store.poolSims().filter { $0.name == name }
            guard partialRows.allSatisfy({ $0.phase != .leased && $0.leaseID == nil }) else {
                throw PoolError.cloneRecoveryBlocked("interrupted clone \(name) still has a lease")
            }
            for var row in partialRows {
                row.phase = .recycling; row.tainted = true
                try store.savePoolSim(row)
            }
            hostActionIntentsInFlight.insert(intent.id)
            defer { hostActionIntentsInFlight.remove(intent.id) }
            var cleanupProof = prepared
            cleanupProof.expectedTargetUDID = operation.createdUDID
            try hostWork { try self.environment.sims.cleanUpInterruptedClone(cleanupProof) }
            let now = environment.clock.now()
            try store.database.immediateTransaction {
                for row in partialRows {
                    if let current = try store.poolSims().first(where: { $0.udid == row.udid }) {
                        guard current.name == name, current.phase == .recycling, current.leaseID == nil else {
                            throw PoolError.cloneRecoveryBlocked("clone row changed during cleanup")
                        }
                        try store.deletePoolSim(udid: row.udid)
                    }
                }
                let removedIDs = Set(partialRows.map(\.udid) + (operation.createdUDID.map { [$0] } ?? []))
                for resource in try store.liveResources(kinds: [.sim]) where removedIDs.contains(resource.externalID) {
                    try store.markResourceReleased(id: resource.id, reason: "interrupted clone removed", now: now)
                }
                try store.audit(Self.destructiveAuditType, detail: "cleaned interrupted clone \(name)", now: now)
                try store.abandonActionIntent(
                    intent, reason: "interrupted clone removed; source restored; never handed out", now: now)
            }
        }
        return gate.executedThisPass
    }

    func createPoolSim(slot: Int, now: Double, hostWork: PoolHostWork = Engine.inlineHostWork) throws -> PoolSim {
        guard let sim = try createPreparedPoolSim(slot: slot, now: now, plan: selectedClonePlan(), hostWork: hostWork)
        else {
            throw PoolError.cloneRecoveryBlocked("clone was not authorized")
        }
        return sim
    }

    func createPreparedPoolSim(
        slot: Int, now: Double, plan: SimClonePlan, hostWork: PoolHostWork = Engine.inlineHostWork,
        authorize: () throws -> Bool = { true }
    ) throws -> PoolSim? {
        var operation = PoolCloneOperation(plan: plan)
        var intent = try store.recordActionIntent(
            ActionIntent(
                target: .simCreate(name: ""), auditType: Self.poolCreatedAuditType,
                detail: try Self.poolCloneDetail(operation)), now: now
        ) { .simCreate(name: environment.naming.poolSimName(slot: slot, intentID: $0)) }
        guard case .simCreate(let name) = intent.target else { preconditionFailure("create intent target") }
        hostActionIntentsInFlight.insert(intent.id)
        defer { hostActionIntentsInFlight.remove(intent.id) }
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            var prepared: SimClonePreparation?
            try hostWork { prepared = try self.environment.sims.prepareClone(name: name, plan: plan) }
            guard let prepared, prepared.name == name, prepared.plan == plan,
                !plan.boots || prepared.sourceWasShutdown
            else { throw PoolError.cloneRecoveryBlocked("invalid clone preparation") }
            operation.preparation = prepared; operation.phase = .prepared
            intent.detail = try Self.poolCloneDetail(operation)
            try store.updateActionIntentDetail(intent)
            guard try authorize() else {
                try store.abandonActionIntent(
                    intent, reason: "fresh clone resource/load gate held", now: environment.clock.now())
                return nil
            }
            operation.phase = .started
            intent.detail = try Self.poolCloneDetail(operation)
            try store.updateActionIntentDetail(intent)
            var device: SimDevice?
            try hostWork { device = try self.environment.sims.createPreparedDevice(prepared) }
            guard let device else { throw PoolError.cloneRecoveryBlocked("clone returned no device") }
            let finishedAt = environment.clock.now()
            operation.createdUDID = device.udid
            intent.detail = try Self.poolCloneDetail(operation)
            try store.updateActionIntentDetail(intent)
            _ = try store.acquireResource(
                kind: .sim, externalID: device.udid, owner: .pool, epoch: epoch, now: finishedAt)
            var sim = PoolSim(udid: device.udid, name: device.name, phase: .shutdown, createdAt: finishedAt)
            sim.clonedFrom = plan.sourceRef; sim.cloneMethod = plan.method
            try store.savePoolSim(sim)
            var confirmed = intent
            confirmed.detail =
                "\(name) \(device.udid) clone_method=\(plan.method.rawValue) duration_ms=\(Self.elapsedMilliseconds(since: start))"
            try store.confirmActionIntent(confirmed, now: finishedAt)
            return sim
        } catch {
            if operation.phase != .started {
                try? store.abandonActionIntent(
                    intent, reason: "preflight failed before host mutation: \(error)", now: environment.clock.now())
            }
            // Started failures retain their durable proof and boot reservation until
            // the worker verifies cleanup. Generic name-present recovery cannot adopt it.
            throw error
        }
    }

    /// The registered template the backend would clone (matched by UDID or name, as
    /// `simctl.template` accepts either) when it isn't `ready`. Nil when the source is ready,
    /// unregistered (a hand-made template), or there's none.
    func unreadyCloneTemplate() throws -> TemplateRecord? {
        guard let source = environment.sims.cloneSource else { return nil }
        let entry = try templates().first { $0.record.udid == source || $0.record.name == source }
        guard let record = entry?.record, record.status != "ready" else { return nil }
        return record
    }

    /// The clone source as a template ref: the UDID and name of the registered template it
    /// names (by either), else just what the backend gave (a UDID unless it's an owned
    /// sim name). Nil when the backend clones nothing.
    func cloneSourceRef(_ source: String?) throws -> TemplateRef? {
        guard let source else { return nil }
        if let entry = try templates().first(where: { $0.record.udid == source || $0.record.name == source }) {
            return TemplateRef(udid: entry.record.udid, name: entry.record.name)
        }
        return environment.naming.owns(source)
            ? TemplateRef(udid: nil, name: source) : TemplateRef(udid: source, name: nil)
    }

    /// The lowest slot number (from 1) no current pool sim uses.
    static func freeSlot(in sims: [PoolSim]) -> Int {
        let used = Set(
            sims.compactMap { SimNamingScheme.poolSlot(of: $0.name) })
        var slot = 1
        while used.contains(slot) { slot += 1 }
        return slot
    }

    /// Deletes a pool sim under a write-ahead intent and drops its rows; the planner
    /// creates a replacement when one is needed.
    func recyclePoolSim(_ sim: PoolSim, reason: String, now: Double, hostWork: PoolHostWork = Engine.inlineHostWork)
        throws
    {
        let resource = try store.liveResources(kinds: [.sim]).first { $0.externalID == sim.udid }
        let intent = ActionIntent(
            target: .sim(udid: sim.udid), auditType: "pool_recycled", detail: "\(sim.udid): \(reason)",
            resourceID: resource?.id, releaseReason: resource == nil ? nil : "pool sim recycled")
        try performUnderIntent(intent, now: now) {
            try hostWork {
                try environment.sims.deleteDevice(udid: sim.udid)
                if try environment.sims.listDevices().contains(where: { $0.udid == sim.udid }) {
                    throw EngineError.cleanupNotVerified("sim \(sim.udid)")
                }
            }
        }
        try store.deletePoolSim(udid: sim.udid)
    }

    func dropPoolSim(_ udid: String, reason: String, now: Double) throws {
        if let resource = try store.liveResources(kinds: [.sim]).first(where: { $0.externalID == udid }) {
            _ = try store.releaseResource(id: resource.id, generation: resource.generation, reason: reason, now: now)
        }
        try store.deletePoolSim(udid: udid)
    }
}

extension SimPoolAction {
    /// Whether carrying it out touches a simulator (everything but marking a sim settled).
    public var touchesHost: Bool {
        if case .settled = self { return false }
        return true
    }
}
