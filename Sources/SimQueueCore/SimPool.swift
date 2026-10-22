// SPDX-License-Identifier: MIT

/// Where a pool sim is in its life (spec §5e). Only `ready` sims are handed out.
public enum PoolSimPhase: String, Sendable, Codable, CaseIterable {
    /// Created (or shut down), not booted.
    case shutdown
    /// Boot requested, not finished.
    case booting
    /// Booted, waiting for the settle gate before it can be handed out. Counts as a boot.
    case settling
    /// Booted, settled and idle.
    case ready
    /// Handed to a lease holder.
    case leased
    /// Being deleted and re-created.
    case recycling
}

/// One pool sim as the pool manager tracks it.
/// The host operation that produced a pool clone. Missing metadata is never proof
/// that a clone preserved an explicitly slimmed template's service profile.
public enum SimCloneMethod: String, Sendable, Equatable, Codable {
    case simctl
    case simslim
}

/// Immutable source and method captured before a pool create releases the service lock.
public struct SimClonePlan: Sendable, Equatable, Codable {
    public var source: String?
    public var sourceRef: TemplateRef?
    public var method: SimCloneMethod
    public init(source: String?, sourceRef: TemplateRef? = nil, method: SimCloneMethod = .simctl) {
        self.source = source; self.sourceRef = sourceRef; self.method = method
    }
    public var boots: Bool { method == .simslim }
}

/// Read-only host observations, recorded durably before a clone may start.
public struct SimClonePreparation: Sendable, Equatable, Codable {
    public var name: String
    public var plan: SimClonePlan
    public var previousUDIDs: Set<String>
    public var sourceWasShutdown: Bool
    public var expectedTargetUDID: String?
    public init(name: String, plan: SimClonePlan, previousUDIDs: Set<String>, sourceWasShutdown: Bool = false) {
        self.name = name; self.plan = plan; self.previousUDIDs = previousUDIDs;
        self.sourceWasShutdown = sourceWasShutdown
    }
}

public struct PoolSim: Sendable, Equatable, Codable {
    public var udid: String
    public var name: String
    public var phase: PoolSimPhase
    public var createdAt: Double
    /// Last time it was released (or created).
    public var lastUsedAt: Double
    /// When it entered `phase` (settle and boot timers run from here).
    public var phaseSince: Double
    public var leaseID: String?
    /// Released while pre-warm on release is on: boot and settle it before it's needed.
    public var prewarmPending: Bool
    /// Something used it without a lease: never handed out again; recycled once that's gone.
    public var tainted: Bool
    /// Manual (`lease:`) leases: the holder's pid and its identity (start time) when given.
    public var holderPID: Int32?
    public var holderIdentity: String?
    /// Last grant or renew of a manual lease.
    public var heartbeatAt: Double?
    /// When report-only mode last reported this lease as stale (logged once).
    public var staleReportedAt: Double?
    /// The template this sim was cloned from (nil for sims created before this was
    /// recorded, or when the backend clones nothing).
    public var clonedFrom: TemplateRef?
    public var runtime: String?
    public var deviceType: String?
    public var cloneMethod: SimCloneMethod?

    public init(
        udid: String, name: String, phase: PoolSimPhase, createdAt: Double, lastUsedAt: Double? = nil,
        phaseSince: Double? = nil, leaseID: String? = nil, prewarmPending: Bool = false, tainted: Bool = false
    ) {
        self.udid = udid
        self.name = name
        self.phase = phase
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt ?? createdAt
        self.phaseSince = phaseSince ?? createdAt
        self.leaseID = leaseID
        self.prewarmPending = prewarmPending
        self.tainted = tainted
    }

    enum CodingKeys: String, CodingKey {
        case udid, name, phase, tainted
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case phaseSince = "phase_since"
        case leaseID = "lease_id"
        case prewarmPending = "prewarm_pending"
        case holderPID = "holder_pid"
        case holderIdentity = "holder_identity"
        case heartbeatAt = "heartbeat_at"
        case staleReportedAt = "stale_reported_at"
        case clonedFrom = "cloned_from"
        case runtime
        case deviceType = "device_type"
        case cloneMethod = "clone_method"
    }
}

/// A template sim as recorded on what was cloned from it: its UDID and name when
/// known. The backend's clone source can be either one; the other is filled in from the
/// registered templates when it matches one.
public struct TemplateRef: Sendable, Equatable, Codable {
    public var udid: String?
    public var name: String?

    public init(udid: String?, name: String?) {
        self.udid = udid
        self.name = name
    }
}

/// A pool sim a job held while it ran, as recorded at its start (`sims` in job results).
public struct JobSim: Sendable, Equatable, Codable {
    public var runtime: String?
    public var deviceType: String?
    public var udid: String
    public var name: String
    public var clonedFrom: TemplateRef?

    public init(udid: String, name: String, clonedFrom: TemplateRef?, runtime: String? = nil, deviceType: String? = nil)
    {
        self.runtime = runtime; self.deviceType = deviceType
        self.udid = udid
        self.name = name
        self.clonedFrom = clonedFrom
    }

    enum CodingKeys: String, CodingKey {
        case udid, name, runtime
        case deviceType = "device_type"
        case clonedFrom = "cloned_from"
    }
}

/// What the executor observed while a job ran: the sims it held and the sampled peak
/// resident memory of its process group.
public struct JobRunInfo: Sendable, Equatable {
    public var sims: [JobSim]
    /// Sampled at the executor's step cadence, so approximate (a short spike between
    /// samples is missed). Nil when nothing was sampled.
    public var peakResidentBytes: UInt64?

    public init(sims: [JobSim] = [], peakResidentBytes: UInt64? = nil) {
        self.sims = sims
        self.peakResidentBytes = peakResidentBytes
    }
}

/// Which signals decide that a freshly booted sim has settled.
public enum SettleMode: String, Sendable, Codable, CaseIterable {
    /// Host load (`load5`) below `load_below`.
    case load
    /// No gate: ready as soon as it's booted.
    case off
}

/// What happens when settling hits `max_wait`.
public enum SettleCapAction: String, Sendable, Codable, CaseIterable {
    /// Log `settle_cap_hit` and hand the sim off anyway.
    case handoff
    /// Log `settle_cap_hit`, shut the sim down and fail whoever was waiting (infra failure).
    case fail
}

/// The readiness gate between boot and handoff (spec §5e, §6 `[settle]`). Defaults are
/// proposals; check them on each host.
public struct SettleConfig: Sendable, Equatable, Codable {
    public var mode: SettleMode
    public var loadBelow: Double
    public var maxWaitSeconds: Double
    public var onCap: SettleCapAction
    /// Derived at startup for default load settling only. Explicit load5 settings
    /// remain strict. Deliberately excluded from Codable: this is not a config knob.
    public var load1RecoveryBelow: Double? = nil

    public init(
        mode: SettleMode = .load, loadBelow: Double = 20,
        maxWaitSeconds: Double = 180, onCap: SettleCapAction = .handoff
    ) {
        self.mode = mode
        self.loadBelow = loadBelow
        self.maxWaitSeconds = maxWaitSeconds
        self.onCap = onCap
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case loadBelow = "load_below"
        case maxWaitSeconds = "max_wait_seconds"
        case onCap = "on_cap"
    }
}

/// Signal values for one settling sim. Nil means unknown, which never counts as settled.
public struct SettleSignals: Sendable, Equatable, Codable {
    public var load5: Double?
    public var load1: Double?

    public init(load5: Double? = nil, load1: Double? = nil) {
        self.load5 = load5
        self.load1 = load1
    }

    enum CodingKeys: String, CodingKey {
        case load5
        case load1
    }
}

public enum SettleVerdict: Sendable, Equatable {
    case wait
    case settled
    case capHit
}

public enum SettleGate {
    public static func evaluate(_ config: SettleConfig, signals: SettleSignals, waitedSeconds: Double) -> SettleVerdict
    {
        let historicalLoadOK = signals.load5.map { $0 < config.loadBelow } ?? false
        let recovered = config.load1RecoveryBelow.flatMap { limit in signals.load1.map { $0 <= limit } } ?? false
        let settled: Bool
        switch config.mode {
        case .off: settled = true
        case .load: settled = historicalLoadOK || recovered
        }
        if settled { return .settled }
        return waitedSeconds >= config.maxWaitSeconds ? .capHit : .wait
    }
}

/// Pool settings (spec §5e, §6). Generic: no project or job type is special.
/// Whether the pool acts on its own `simq-*` sims (`pool.mode`). It never widens what
/// the watchdog may do: foreign and orphaned resources still follow `cleanup_mode`.
public enum PoolMode: String, Sendable, Codable, CaseIterable {
    /// Follow `cleanup_mode` (the default): report-only plans pool actions but takes none.
    case followCleanup = "follow-cleanup"
    /// Create, boot, lease, release and recycle the pool's own sims whatever `cleanup_mode`
    /// says. Recycles still go through the destructive-action limits; the boot gates, the
    /// host lock and `external_sim_patterns` still apply.
    case active
    /// Plan and report only; never touch a sim, whatever `cleanup_mode` says.
    case reportOnly = "report-only"

    /// Whether pool passes take host actions under this mode and the watchdog's mode.
    public func actsOnHost(cleanupMode: CleanupMode) -> Bool {
        switch self {
        case .followCleanup: cleanupMode == .enforce
        case .active: true
        case .reportOnly: false
        }
    }
}

public struct SimPoolConfig: Sendable, Equatable, Codable {
    /// Hard ceiling on pool sims (any phase).
    public var maxSims: Int
    /// Booted idle sims kept ready without demand. 0 by default: nothing boots until asked.
    public var warmMin: Int
    /// Boots in flight at once. A settling sim still counts as booting.
    public var maxConcurrentBoots: Int
    /// A ready sim unused this long is shut down, beyond `warmMin`.
    public var idleShutdownSeconds: Double
    /// An idle sim older than this is deleted and re-created.
    public var recycleAfterSeconds: Double
    /// A boot that hasn't finished after this long is treated as failed (the sim is recycled).
    public var bootTimeoutSeconds: Double
    public var settle: SettleConfig
    /// Names of other tools' simulators (globs: `*` any run, `?` one character). While a
    /// sim matching one is booted, pool boots wait: that tool is using the host. Empty
    /// (the default): no external users are tracked. Config only; not persisted.
    public var externalSimPatterns: [String] = []
    /// `pool.mode`: whether the pool acts on its own sims. Config only; not persisted.
    public var mode: PoolMode = .followCleanup

    /// Whether pool passes take host actions, given the watchdog's `cleanup_mode`.
    public func actsOnHost(cleanupMode: CleanupMode) -> Bool { mode.actsOnHost(cleanupMode: cleanupMode) }

    /// The booted sims (not SimQueue's) that match `externalSimPatterns`.
    public func externalBootedSims(in devices: [SimDevice]) -> [SimDevice] {
        guard !externalSimPatterns.isEmpty else { return [] }
        return devices.filter { device in
            device.isBooted && externalSimPatterns.contains { Glob.matches(pattern: $0, device.name) }
        }
    }

    public init(
        maxSims: Int = 2, warmMin: Int = 0, maxConcurrentBoots: Int = 1, idleShutdownSeconds: Double = 30 * 60,
        recycleAfterSeconds: Double = 7 * 24 * 60 * 60, bootTimeoutSeconds: Double = 300,
        settle: SettleConfig = SettleConfig()
    ) {
        self.maxSims = maxSims
        self.warmMin = warmMin
        self.maxConcurrentBoots = maxConcurrentBoots
        self.idleShutdownSeconds = idleShutdownSeconds
        self.recycleAfterSeconds = recycleAfterSeconds
        self.bootTimeoutSeconds = bootTimeoutSeconds
        self.settle = settle
    }

    enum CodingKeys: String, CodingKey {
        case settle
        case maxSims = "max_sims"
        case warmMin = "warm_min"
        case maxConcurrentBoots = "max_concurrent_boots"
        case idleShutdownSeconds = "idle_shutdown_seconds"
        case recycleAfterSeconds = "recycle_after_seconds"
        case bootTimeoutSeconds = "boot_timeout_seconds"
    }
}

/// Why a boot was started.
public enum PoolBootReason: String, Sendable, Codable, Equatable {
    /// Someone is waiting for a sim.
    case demand
    /// Keeping `warm_min` sims ready.
    case warmMin = "warm_min"
    /// Pre-warm on release.
    case prewarm
}

public enum SimPoolAction: Sendable, Equatable {
    /// Create one more pool sim (it starts shut down).
    case create
    case boot(udid: String, reason: PoolBootReason)
    /// The settle gate passed (or the cap hit with `on_cap = handoff`): the sim is ready.
    case settled(udid: String, capHit: Bool, waitedSeconds: Double)
    /// The cap hit with `on_cap = fail`: shut the sim down and fail whoever was waiting.
    case settleFailed(udid: String, waitedSeconds: Double)
    /// Idle beyond `warm_min` for `idle_shutdown`. Not destructive.
    case shutdown(udid: String)
    /// Delete and re-create (age, a boot that never finished, or an unleased user that's gone).
    case recycle(udid: String, reason: String)
}

public struct SimPoolInput: Sendable {
    public var sims: [PoolSim]
    /// Callers waiting for a sim right now (pending lease requests).
    public var demand: Int
    /// Signals for sims in `settling`, by UDID.
    public var signals: [String: SettleSignals]
    /// Pool sims a process is using right now without a lease.
    public var unleasedUsers: Set<String>
    public var now: Double
    /// The backend's create boots a sim too (simslim clone boots the template), so a create
    /// takes a boot slot like a boot does.
    public var createBoots: Bool

    public init(
        sims: [PoolSim], demand: Int, signals: [String: SettleSignals] = [:], unleasedUsers: Set<String> = [],
        now: Double, createBoots: Bool = false
    ) {
        self.sims = sims
        self.demand = demand
        self.signals = signals
        self.unleasedUsers = unleasedUsers
        self.now = now
        self.createBoots = createBoots
    }
}

/// Pure pool planning, one step per pool pass. The caller executes the actions in order.
public enum SimPoolPlanner {
    public static func plan(_ input: SimPoolInput, config: SimPoolConfig) -> [SimPoolAction] {
        var actions: [SimPoolAction] = []
        let now = input.now
        var sims = input.sims.sorted { ($0.createdAt, $0.udid) < ($1.createdAt, $1.udid) }
        func blocked(_ sim: PoolSim) -> Bool { sim.tainted || input.unleasedUsers.contains(sim.udid) }

        // 1. Settling sims: pass the gate, or hit the cap. A sim that fails its gate isn't
        //    booted again on the same pass.
        var settleFailed = Set<String>()
        for index in sims.indices where sims[index].phase == .settling {
            let sim = sims[index]
            let waited = now - sim.phaseSince
            switch SettleGate.evaluate(
                config.settle, signals: input.signals[sim.udid] ?? SettleSignals(), waitedSeconds: waited)
            {
            case .wait: break
            case .settled:
                actions.append(.settled(udid: sim.udid, capHit: false, waitedSeconds: waited))
                sims[index].phase = .ready
            case .capHit:
                if config.settle.onCap == .handoff {
                    actions.append(.settled(udid: sim.udid, capHit: true, waitedSeconds: waited))
                    sims[index].phase = .ready
                } else {
                    actions.append(.settleFailed(udid: sim.udid, waitedSeconds: waited))
                    sims[index].phase = .shutdown
                    settleFailed.insert(sim.udid)
                }
            }
        }

        // 2. Recycle: a boot that never finished, a tainted sim whose unleased user is gone,
        //    and idle sims past their age.
        var recycled = Set<String>()
        for sim in sims {
            var reason: String?
            if sim.phase == .recycling {
                // One serialized pool worker owns host operations. A recycling row
                // visible to a new pass is unfinished work from an earlier failure/restart.
                reason = "unfinished recycle or failed boot"
            } else if sim.phase == .booting, now - sim.phaseSince >= config.bootTimeoutSeconds {
                reason = "boot didn't finish in \(Int(config.bootTimeoutSeconds)) s"
            } else if sim.tainted, !input.unleasedUsers.contains(sim.udid), sim.phase != .leased,
                sim.phase != .recycling
            {
                reason = "used without a lease"
            } else if [.shutdown, .ready].contains(sim.phase), !blocked(sim),
                now - sim.createdAt >= config.recycleAfterSeconds
            {
                reason = "older than \(Int(config.recycleAfterSeconds)) s"
            }
            if let reason {
                actions.append(.recycle(udid: sim.udid, reason: reason))
                recycled.insert(sim.udid)
            }
        }
        sims.removeAll { recycled.contains($0.udid) }

        // 3. Boots: demand first, then warm_min, then pre-warm (which yields to demand).
        var bootSlots = max(
            0, config.maxConcurrentBoots - sims.filter { [.booting, .settling].contains($0.phase) }.count)
        let ready = sims.filter { $0.phase == .ready && !blocked($0) }.count
        let coming = sims.filter { [.booting, .settling].contains($0.phase) && !blocked($0) }.count
        var unmet = max(0, input.demand - ready - coming)
        // Shut-down sims that can be booted, most recently used (or pending pre-warm) first.
        var bootable = sims.filter { $0.phase == .shutdown && !blocked($0) && !settleFailed.contains($0.udid) }
            .sorted {
                ($0.prewarmPending ? 1 : 0, $0.lastUsedAt, $0.udid) > (
                    $1.prewarmPending ? 1 : 0, $1.lastUsedAt, $1.udid
                )
            }
        var total = sims.count + recycled.count  // a recycled sim is re-created in its place
        var booted = Set<String>()
        while unmet > 0 {
            if bootSlots > 0, !bootable.isEmpty {
                let sim = bootable.removeFirst()
                actions.append(.boot(udid: sim.udid, reason: .demand))
                booted.insert(sim.udid)
                bootSlots -= 1
                unmet -= 1
            } else if bootable.isEmpty, total < config.maxSims, !input.createBoots || bootSlots > 0 {
                // Created shut down; the next pass boots it if it's still needed. A create
                // that boots (simslim clone) takes a boot slot.
                actions.append(.create)
                total += 1
                unmet -= 1
                if input.createBoots { bootSlots -= 1 }
            } else {
                break
            }
        }
        let warm = ready + coming + booted.count
        if input.demand == 0 || unmet == 0 {
            var missing = max(0, config.warmMin - warm)
            while missing > 0, bootSlots > 0, let next = bootable.first {
                bootable.removeFirst()
                actions.append(.boot(udid: next.udid, reason: .warmMin))
                booted.insert(next.udid)
                bootSlots -= 1
                missing -= 1
            }
            if missing > 0, bootable.isEmpty, total < config.maxSims, !input.createBoots || bootSlots > 0 {
                actions.append(.create)
                total += 1
                if input.createBoots { bootSlots -= 1 }
            }
        }
        if unmet == 0 {
            for sim in bootable where sim.prewarmPending && bootSlots > 0 {
                actions.append(.boot(udid: sim.udid, reason: .prewarm))
                booted.insert(sim.udid)
                bootSlots -= 1
            }
        }

        // 4. Idle shutdown: ready sims unused for `idle_shutdown`, keeping the `warm_min`
        //    most recently used. Never while someone is waiting.
        if input.demand == 0 {
            let idle = sims.filter { $0.phase == .ready && !blocked($0) }
                .sorted { ($0.lastUsedAt, $0.udid) > ($1.lastUsedAt, $1.udid) }
            for sim in idle.dropFirst(max(0, config.warmMin))
            where now - max(sim.lastUsedAt, sim.phaseSince) >= config.idleShutdownSeconds {
                actions.append(.shutdown(udid: sim.udid))
            }
        }
        return actions
    }

    /// Ready sims that can be handed out now, in handoff order (most recently settled
    /// first is not needed; oldest ready first keeps the pool cycling).
    public static func handoffCandidates(_ sims: [PoolSim], unleasedUsers: Set<String>) -> [PoolSim] {
        sims.filter { $0.phase == .ready && !$0.tainted && !unleasedUsers.contains($0.udid) }
            .sorted { ($0.phaseSince, $0.udid) < ($1.phaseSince, $1.udid) }
    }
}

// MARK: - State machine

/// Something that happened to one pool sim. `PoolSim.applying` moves it to its next phase.
public enum SimPoolEvent: Sendable, Equatable {
    /// A boot was started (`shutdown` → `booting`).
    case bootStarted
    /// The boot finished (`booting` → `settling`). The sim still holds the boot slot.
    case bootFinished
    /// The boot failed or timed out (`booting` → `recycling`).
    case bootFailed
    /// The settle gate passed, or the cap hit with `on_cap = handoff` (`settling` → `ready`).
    case settled
    /// The cap hit with `on_cap = fail` (`settling` → `shutdown`).
    case settleFailed
    /// Handed to a lease holder (`ready` → `leased`).
    case leased(leaseID: String)
    /// The lease ended (`leased` → `shutdown`, the sim gets reset). `prewarm` marks it for pre-warm.
    case released(prewarm: Bool)
    /// The lease ended while queued jobs wait for a sim (`leased` → `ready`): kept booted
    /// and handed to the next job instead of shut down and booted again.
    case handedOff
    /// Idle shutdown done (`ready` → `shutdown`).
    case shutDown
    /// Delete and re-create started (any phase but `leased` → `recycling`).
    case recycleStarted
    /// Re-created as a fresh sim (`recycling` → `shutdown`).
    case recreated(udid: String)
    /// Used without a lease: marked, never handed out again. Phase unchanged.
    case unleasedUseSeen
}

public struct SimPoolTransitionError: Error, Equatable, CustomStringConvertible {
    public var udid: String
    public var phase: PoolSimPhase
    public var event: SimPoolEvent
    public var description: String { "pool sim \(udid): \(event) isn't allowed while \(phase.rawValue)" }
}

extension PoolSim {
    /// Phases that hold a boot slot (a settling sim still counts as a boot).
    public var holdsBootSlot: Bool { phase == .booting || phase == .settling }

    /// The sim after `event`, or a `SimPoolTransitionError` if `event` isn't allowed now.
    public func applying(_ event: SimPoolEvent, now: Double) throws -> PoolSim {
        var next = self
        func move(_ from: Set<PoolSimPhase>, to phase: PoolSimPhase) throws {
            guard from.contains(self.phase) else {
                throw SimPoolTransitionError(udid: udid, phase: self.phase, event: event)
            }
            next.phase = phase
            next.phaseSince = now
        }
        switch event {
        case .bootStarted:
            guard !tainted else { throw SimPoolTransitionError(udid: udid, phase: phase, event: event) }
            try move([.shutdown], to: .booting)
            next.prewarmPending = false
        case .bootFinished: try move([.booting], to: .settling)
        case .bootFailed: try move([.booting], to: .recycling)
        case .settled: try move([.settling], to: .ready)
        case .settleFailed: try move([.settling], to: .shutdown)
        case .leased(let leaseID):
            guard !tainted else { throw SimPoolTransitionError(udid: udid, phase: phase, event: event) }
            try move([.ready], to: .leased)
            next.leaseID = leaseID
        case .released(let prewarm):
            try move([.leased], to: .shutdown)
            next.leaseID = nil
            next.holderPID = nil
            next.holderIdentity = nil
            next.heartbeatAt = nil
            next.staleReportedAt = nil
            next.lastUsedAt = now
            next.prewarmPending = prewarm
        case .handedOff:
            guard !tainted else { throw SimPoolTransitionError(udid: udid, phase: phase, event: event) }
            try move([.leased], to: .ready)
            next.leaseID = nil
            next.holderPID = nil
            next.holderIdentity = nil
            next.heartbeatAt = nil
            next.staleReportedAt = nil
            next.lastUsedAt = now
            next.prewarmPending = false
        case .shutDown: try move([.ready], to: .shutdown)
        case .recycleStarted:
            try move([.shutdown, .booting, .settling, .ready], to: .recycling)
            next.prewarmPending = false
        case .recreated(let udid):
            try move([.recycling], to: .shutdown)
            next.udid = udid
            next.createdAt = now
            next.lastUsedAt = now
            next.leaseID = nil
            next.tainted = false
        case .unleasedUseSeen:
            next.tainted = true
        }
        return next
    }
}

// MARK: - Log entries

/// One line for the daemon's event log and audit trail.
public struct SimPoolLogEntry: Sendable, Equatable {
    public var type: String
    public var udid: String
    public var detail: String

    public init(type: String, udid: String, detail: String) {
        self.type = type
        self.udid = udid
        self.detail = detail
    }
}

extension SimPoolPlanner {
    /// Log entries for a pass's actions. A settle cap hit logs `settle_cap_hit` with the sim,
    /// its signal values and the wait, whether it then hands off or fails.
    public static func logEntries(
        for actions: [SimPoolAction], input: SimPoolInput, config: SimPoolConfig
    ) -> [SimPoolLogEntry] {
        func signals(_ udid: String) -> String {
            let s = input.signals[udid] ?? SettleSignals()
            return
                "load1=\(s.load1.map { String($0) } ?? "unknown") load5=\(s.load5.map { String($0) } ?? "unknown")"
        }
        func capHit(_ udid: String, _ waited: Double, outcome: String) -> SimPoolLogEntry {
            SimPoolLogEntry(
                type: "settle_cap_hit", udid: udid,
                detail: "mode=\(config.settle.mode.rawValue) \(signals(udid)) waited=\(Int(waited))s "
                    + "max_wait=\(Int(config.settle.maxWaitSeconds))s on_cap=\(outcome)")
        }
        return actions.compactMap { action in
            switch action {
            case .settled(let udid, true, let waited): capHit(udid, waited, outcome: "handoff")
            case .settleFailed(let udid, let waited): capHit(udid, waited, outcome: "fail")
            default: nil
            }
        }
    }
}

/// Minimal glob: `*` matches any run of characters, `?` exactly one; everything else is
/// literal (case-sensitive). Enough for simulator names; no character classes.
public enum Glob {
    public static func matches(pattern: String, _ text: String) -> Bool {
        let p = Array(pattern)
        let t = Array(text)
        var (pi, ti) = (0, 0)
        var star = -1
        var mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
