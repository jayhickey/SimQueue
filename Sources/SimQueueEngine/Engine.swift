// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueHost
import SimQueueSim
import SimQueueStore

/// What one tick did.
public struct TickResult: Sendable, Equatable {
    public var plan: SchedulerPlan
    public var timeouts: TimeoutReport = TimeoutReport()
    /// Job ids the store actually admitted (a claim can lose a race).
    public var admitted: [String]
    public var drain: DrainStatus
    public var host: HostSnapshot
    /// Host-wide reasons that blocked every admission on this tick.
    public var globalReasons: [WaitReason] = []
}

/// What the run- and queue-timeout pass did on one tick.
public struct TimeoutReport: Sendable, Equatable {
    /// Queued jobs that passed their queue timeout (now `expired`).
    public var expired: [String] = []
    /// Jobs that got SIGTERM on this tick.
    public var termSent: [String] = []
    /// Jobs escalated to SIGKILL on this tick.
    public var killSent: [String] = []
    /// Jobs recorded as `timed_out` on this tick (teardown done or handed to reconcile).
    public var timedOut: [String] = []
    public var failures: [String] = []

    public init() {}
}

/// Outcome of one reconciliation pass.
public struct ReconcileReport: Sendable, Equatable {
    /// Intents left by an earlier crash or database failure, settled before this pass.
    public var intents = ActionIntentRecovery()
    /// Everything the planner proposed.
    public var actions: [ReconcileAction] = []
    /// Destructive actions performed.
    public var executed: [ReconcileAction] = []
    /// Destructive actions that report-only mode held back.
    public var wouldExecute: [ReconcileAction] = []
    /// Destructive actions still inside the orphan grace period.
    public var deferredGrace: [ReconcileAction] = []
    /// Destructive actions held back by the per-pass or per-hour limit.
    public var deferredRateLimit: [ReconcileAction] = []
    /// Actions that failed or were refused; their rows stay `orphaned` for a retry.
    public var failures: [String] = []
    /// Anomalies still open after this pass (see `AnomalyTracker`).
    public var anomalies: [AnomalyRecord] = []
    /// Destructive actions that failed or could not be verified (not refusals).
    public var failedActions = 0
    /// The hourly destructive limit held an action back.
    public var hourlyLimitHit = false
    /// Anomalies whose level rose on this pass.
    public var escalated: [AnomalyRecord] = []
    /// Lookalike foreign sims first reported on this pass (one alert each).
    public var lookalikeAlerts: [AlertEvent] = []
}

/// Outcome of one watchdog pass.
public struct WatchdogPassReport: Sendable, Equatable {
    public var passID: String
    public var kind: WatchdogPassKind
    public var reconcile: ReconcileReport
    public var breaker: BreakerState
    public var transitions: [BreakerTransition]
    public var health: HealthSummary
    /// Alert events raised by this pass (already recorded in the store).
    public var alerts: [AlertEvent] = []
    /// Stale manual pool leases: reclaimed, reported (report-only) or postponed by a limit.
    public var staleLeases = StaleLeaseReport()
    /// Age rules applied on a full pass (empty on a light pass).
    public var age = AgeRuleReport()
    /// Alerts resolved on this pass (clear for `closeAfterCleanFullPasses` full passes).
    public var alertsCleared: [String] = []
}

public enum EngineError: Error, Equatable, CustomStringConvertible {
    /// Another daemon took the lease. The caller must stop immediately.
    case lostLease(epoch: Int64)
    /// A destructive action returned success but its target is still there.
    case cleanupNotVerified(String)

    public var description: String {
        switch self {
        case .lostLease(let epoch): return "daemon lease lost (epoch \(epoch) is no longer current)"
        case .cleanupNotVerified(let what): return "cleanup reported success but \(what) still exists"
        }
    }
}

/// Everything the engine touches outside the database, injected so tests and soak runs
/// use fakes and a simulated clock.
public struct EngineEnvironment: Sendable {
    public var clock: any Clock
    public var probe: any ResourceProbe
    public var sims: any SimBackend
    public var processes: any ProcessTable
    public var fileSystem: any FileSystem
    public var layout: RunDirectoryLayout
    public var naming: SimNamingScheme
    /// TERM-to-KILL grace when cleaning up an orphaned process group.
    public var processGraceSeconds: Double
    /// Where job logs and artifacts live (`<root>/<YYYY-MM-DD>/<job-id>/`), for retention.
    /// Nil: nothing is ever removed there.
    public var artifactsRoot: String?

    public init(
        clock: any Clock,
        probe: any ResourceProbe,
        sims: any SimBackend,
        processes: any ProcessTable,
        fileSystem: any FileSystem,
        layout: RunDirectoryLayout,
        naming: SimNamingScheme = SimNamingScheme(),
        processGraceSeconds: Double = 10,
        artifactsRoot: String? = nil
    ) {
        self.artifactsRoot = artifactsRoot
        self.clock = clock
        self.probe = probe
        self.sims = sims
        self.processes = processes
        self.fileSystem = fileSystem
        self.layout = layout
        self.naming = naming
        self.processGraceSeconds = processGraceSeconds
    }
}

/// Glue for scheduling and recovery: sample the host and pool, read the queue, plan,
/// claim admitted jobs, persist "why waiting" explanations, and reconcile the ownership
/// ledger against reality. Executors, the socket server and the run loop arrive later.
///
/// Watchdog hooks: `reconcile()` is safe to call at any time, `store.livenessReport` is
/// readable from a separate process, and every action lands in the append-only audit log.
public final class Engine {
    /// Report-only leftovers already reported, as of the pass that last checked them in
    /// full: the action, its anomaly text, and when. An unchanged one is carried forward
    /// without re-verifying it until it's due for re-confirmation.
    struct ParkedLeftover {
        var action: ReconcileAction
        var what: String
        var confirmedAt: Double
    }
    var parked = PrefixBuckets<ParkedLeftover>()
    /// How long a parked leftover goes without a full re-check (pgid reuse, namespace).
    static let parkedReconfirmSeconds: Double = 3600
    public let store: JobStore
    public let environment: EngineEnvironment
    public let scheduler: Scheduler
    public let epoch: Int64
    public let reliability: ReliabilityConfig
    public let timeouts: TimeoutConfig
    public private(set) var swapTracker: SwapGrowthTracker
    /// Last load-throttle decision, fed back for hysteresis. Persisted in the store, so a
    /// restart retains the hold until a configured recovery condition clears it.
    public private(set) var loadThrottled = false
    public private(set) var lastAdmissionAt: Double?
    /// The sim pool's settings. Nil (the default) keeps the pool off: sim capacity comes
    /// from the backend's own counts and jobs get no pool sims.
    public var pool: SimPoolConfig?
    /// Planned restart gate. In memory so a fresh daemon resumes the queued work.
    public var maintenanceDraining = false
    public var hasTemplateBuildsInFlight: Bool { !templateBuildsInFlight.isEmpty }
    /// Pool actions already audited as report-only or postponed (by description), so an
    /// unchanged plan is audited once, not every pass. Rebuilt each pool pass.
    var poolReportedActions: Set<String> = []
    /// The load deferral last audited (`pool_boot_deferred`), so an unchanged one isn't
    /// written every pass.
    var bootDeferral: BootDeferral?
    /// What the startup timeout pass did: deadlines that passed while no daemon was
    /// running are enforced before the first reconcile, so those jobs end `timed_out` or
    /// `expired` instead of being requeued.
    public private(set) var startupTimeouts = TimeoutReport()
    /// The host's tool versions for template staleness (the daemon's cache; nil: unknown).
    /// Never probes. Used to prefer a non-stale template as the clone default.
    public var templateVersions: @Sendable () -> TemplateToolVersions? = { nil }
    /// Intents of template builds this daemon is running right now (between
    /// `beginTemplateBuild` and `finishTemplateBuild`, while the service lock is free).
    /// Recovery skips them: only a build no live daemon is running is a crash. In memory
    /// on purpose: after a restart the set is empty, so every earlier build is recovered.
    var templateBuildsInFlight: Set<Int64> = []
    /// Host actions released from the service lock remain owned by their worker.
    var hostActionIntentsInFlight: Set<Int64> = []
    #if DEBUG
        /// Fault injection after the durable marker and before claim. Absent in release builds.
        public var admissionAttemptRecorded: @Sendable (String) -> Void = { _ in }
    #endif

    /// Admitted jobs waiting for sim preparation, and those whose preparation is running
    /// (in memory: after a restart, a job admitted but never started is recovered as usual).
    var simPrepQueue: [String] = []
    var simPrepInFlight: Set<String> = []

    public init(
        store: JobStore,
        environment: EngineEnvironment,
        config: SchedulerConfig,
        reliability: ReliabilityConfig = ReliabilityConfig(),
        timeouts: TimeoutConfig = TimeoutConfig(),
        epoch: Int64
    ) {
        self.store = store
        self.reliability = reliability
        self.timeouts = timeouts
        self.environment = environment
        self.scheduler = Scheduler(config: config)
        self.epoch = epoch
        self.swapTracker = SwapGrowthTracker()
    }

    /// Takes the daemon lease, recovers jobs from the previous epoch, reconciles owned
    /// resources against what actually exists, and returns a ready engine.
    public static func start(
        store: JobStore,
        environment: EngineEnvironment,
        config: SchedulerConfig,
        reliability: ReliabilityConfig = ReliabilityConfig(),
        timeouts: TimeoutConfig = TimeoutConfig(),
        watchdog: WatchdogConfig = WatchdogConfig(),
        ownerID: String,
        pid: Int32
    ) throws -> (Engine, RecoveryReport, ReconcileReport) {
        let now = environment.clock.now()
        let epoch = try store.acquireDaemonLease(ownerID: ownerID, pid: pid, now: now)
        let intents = try resolveSpawnIntents(store: store, environment: environment, epoch: epoch, now: now)
        let killed = try stopVerifiedOrphanGroups(store: store, environment: environment, epoch: epoch, now: now)
        var recovery = try store.recoverAfterRestart(
            epoch: epoch, now: now, liveProcessGroups: try environment.processes.liveProcessGroups())
        recovery.killedProcessGroups = killed
        recovery.resolvedSpawnIntents = intents
        // Jobs whose deadline passed while we were down keep their resources: adopt them
        // into this epoch so reconcile leaves them to the timeout path, which stops the
        // job and tears down on its own schedule.
        for jobID in recovery.timeoutPending {
            for resource in try store.resources(jobID: jobID) where resource.state == .active {
                try store.adoptResource(id: resource.id, epoch: epoch, now: now)
            }
        }
        let engine = Engine(
            store: store, environment: environment, config: config, reliability: reliability, timeouts: timeouts,
            epoch: epoch)
        engine.loadThrottled = try store.loadThrottled()
        engine.lastAdmissionAt = try store.latestAdmissionAt()
        engine.refreshDefaultTemplate()
        engine.startupTimeouts = try engine.enforceTimeouts(now: now)
        // The startup reconcile is the first full watchdog pass of this epoch.
        let reconcile = try engine.watchdogPass(.full, config: watchdog).reconcile
        return (engine, recovery, reconcile)
    }

    /// Startup step before any recovery: every write-ahead spawn intent whose pid never got
    /// recorded (the previous daemon died between spawn and record) is looked up by its
    /// token in process environments.
    /// - Found: the row gets the group's pgid, plus the leader's identity if the leader is
    ///   still alive, and the job's pid is set. The group then goes through the normal
    ///   verified restart path (stopped in enforce mode, reported in report-only mode) and
    ///   the job is not requeued beside its running command.
    /// - Not found: it may have exited after side effects. Interrupt rather than guess
    ///   it never started; process scanning cannot prove that negative.
    /// - The host can't scan environments: nobody can tell, so the job ends `interrupted`
    ///   (never requeued) and the row is released with the reason.
    /// Returns the pgids found.
    static func resolveSpawnIntents(store: JobStore, environment: EngineEnvironment, epoch: Int64, now: Double)
        throws -> [Int32]
    {
        var found: [Int32] = []
        let processes = environment.processes
        for intent in try store.unresolvedSpawnIntents() {
            let token = String(intent.externalID.dropFirst(JobStore.spawnIntentPrefix.count))
            guard processes.supportsEnvironmentScan else {
                try store.markResourceOrphaned(
                    id: intent.id,
                    reason:
                        "command may still run but its PID is unknown; inspect artifacts and verify its processes are gone before manually releasing ownership or resetting the pool (simq doctor)",
                    now: now)
                if let jobID = intent.owner.jobID {
                    try store.interruptActiveJob(
                        jobID: jobID,
                        message: "daemon restarted before recording the command's pid; can't tell if it started"
                            + " (it may still be running, untracked)",
                        now: now)
                }
                try store.audit(
                    "spawn_intent_unresolved", jobID: intent.owner.jobID, resourceID: intent.id,
                    detail: "\(intent.externalID): this host can't scan process environments", now: now)
                continue
            }
            let matches = try processes.processes(
                withEnvironmentEntry: "\(JobStore.spawnTokenEnvironmentKey)=\(token)")
            // The job command leads its own group; descendants inherit the token too.
            guard let pgid = (matches.first(where: \.isGroupLeader) ?? matches.first)?.pgid else {
                try store.markResourceReleased(
                    id: intent.id, reason: "spawn intent: command never started or already exited", now: now)
                if let jobID = intent.owner.jobID {
                    try store.interruptActiveJob(
                        jobID: jobID,
                        message:
                            "daemon restarted in the spawn/pid-recording window; the command may have started and exited with side effects. No process carries its token now; inspect artifacts before explicitly resubmitting.",
                        now: now)
                }
                try store.audit(
                    "spawn_intent_not_found", jobID: intent.owner.jobID, resourceID: intent.id,
                    detail: "\(intent.externalID): no process carries the token", now: now)
                continue
            }
            let leaderAlive = matches.contains { $0.pid == pgid }
            try store.resolveSpawnIntent(
                id: intent.id, pgid: pgid, identity: leaderAlive ? try processes.processIdentity(pgid) : nil, now: now)
            if let jobID = intent.owner.jobID {
                try store.setOwnerPIDIfUnset(jobID: jobID, pid: pgid, observedAt: now)
            }
            try store.audit(
                "spawn_intent_found", jobID: intent.owner.jobID, resourceID: intent.id,
                detail:
                    "\(intent.externalID) is process group \(pgid)"
                    + (leaderAlive ? "" : " (leader gone; members can't be verified)"),
                now: now)
            found.append(pgid)
        }
        return found
    }

    /// Audit type for a process group stopped at startup because its job lost its daemon.
    public static let restartKillAuditType = "restart_kill"

    /// Startup half of crash recovery, in every cleanup mode: each process group of a job
    /// that lost its daemon is stopped (SIGTERM, grace, SIGKILL) if and only if its leader
    /// still has the identity recorded when it was spawned. These are SimQueue's own job
    /// commands, never sims or foreign processes, so `cleanup_mode` doesn't hold them back:
    /// stopping them is what lets recovery requeue the job (`daemon_restart`) without
    /// running a second copy beside the first. A reused pgid is never signalled (the row
    /// is released: our group is gone); a group whose leader has exited, or that has no
    /// recorded identity, is left alone and its job ends `interrupted` (reported by
    /// reconcile). Jobs already past their run deadline are left to the timeout path.
    /// Returns the groups that were stopped.
    static func stopVerifiedOrphanGroups(
        store: JobStore, environment: EngineEnvironment, epoch: Int64, now: Double
    ) throws -> [Int32] {
        var killed: [Int32] = []
        let live = try environment.processes.liveProcessGroups()
        for job in try store.activeJobs() where (job.ownerEpoch ?? 0) < epoch {
            if let deadline = job.runDeadline, now >= deadline { continue }
            for resource in try store.resources(jobID: job.id)
            where resource.kind == .processGroup && resource.state == .active {
                guard let pgid = Int32(resource.externalID) else { continue }
                switch try environment.processes.verifyGroup(pgid, identity: resource.identity, live: live) {
                case .gone:
                    continue
                case .reused:
                    try store.markResourceReleased(
                        id: resource.id, reason: "process group \(pgid) gone (pgid reused by another process)",
                        now: now)
                    try store.audit(
                        "restart_kill_skipped", jobID: job.id, resourceID: resource.id,
                        detail: "pgid \(pgid) now leads a different process; not signalled", now: now)
                case .unverifiable(let reason):
                    try store.audit(
                        "restart_kill_skipped", jobID: job.id, resourceID: resource.id, detail: reason, now: now)
                case .verified:
                    let intent = ActionIntent(
                        target: .processGroup(pgid), auditType: Self.restartKillAuditType,
                        detail: "stopped process group \(pgid) (leader identity verified)", jobID: job.id,
                        resourceID: resource.id, releaseReason: "stopped after restart")
                    do {
                        try performUnderIntent(intent, store: store, now: now) {
                            try environment.processes.terminateGroup(
                                pgid, graceSeconds: environment.processGraceSeconds)
                            if try environment.processes.liveProcessGroups().contains(pgid) {
                                throw EngineError.cleanupNotVerified("process group \(pgid)")
                            }
                        }
                        killed.append(pgid)
                    } catch EngineError.cleanupNotVerified {
                        try store.markResourceOrphaned(
                            id: resource.id, reason: "survived SIGKILL after restart", now: now)
                        try store.audit(
                            "cleanup_failed", jobID: job.id, resourceID: resource.id,
                            detail: "process group \(pgid) survived SIGKILL after restart", now: now)
                    } catch let error where !(error is DatabaseError) {
                        // The signal itself failed (or a dry run skipped it): the group is left
                        // alone, and recovery marks its job `interrupted` because it's still live.
                        try store.audit(
                            "restart_kill_skipped", jobID: job.id, resourceID: resource.id,
                            detail: "stopping process group \(pgid) failed: \(error)", now: now)
                    }
                }
            }
        }
        return killed
    }

    /// Job owners whose ledger still names a live group. Unverifiable groups and
    /// unresolved spawn intents retain capacity; reused PIDs never hold our resources.
    public func jobsWithLiveProcessGroups() throws -> Set<String> {
        let resources = try store.liveResources(kinds: [.processGroup])
        guard !resources.isEmpty else { return [] }
        let live = try environment.processes.liveProcessGroups()
        var owners: Set<String> = []
        for resource in resources {
            guard let jobID = resource.owner.jobID else { continue }
            guard let pgid = Int32(resource.externalID) else {
                if resource.externalID.hasPrefix(JobStore.spawnIntentPrefix) { owners.insert(jobID) }
                continue
            }
            switch try environment.processes.verifyGroup(pgid, identity: resource.identity, live: live) {
            case .verified, .unverifiable: owners.insert(jobID)
            case .gone, .reused: break
            }
        }
        return owners
    }

    /// Pool host work can outlast a tick, so its refreshed samples must also update
    /// the shared swap-growth gate before authorizing another host action.
    func recordSwapSample(_ host: HostSnapshot, at now: Double) {
        swapTracker.add(at: now, swapUsedBytes: host.swapUsedBytes)
    }

    @discardableResult
    public func tick(host snapshot: HostSnapshot? = nil) throws -> TickResult {
        var now = environment.clock.now()
        guard try store.heartbeat(epoch: epoch, now: now) else {
            throw EngineError.lostLease(epoch: epoch)
        }
        var timeoutReport = try enforceTimeouts(now: now)
        var host = try snapshot ?? environment.probe.sample(now: now)
        recordSwapSample(host, at: now)

        let cleanupOwners = try jobsWithLiveProcessGroups()
        var active = try store.activeJobs()
        let activeIDs = Set(active.map(\.id))
        let leases = try store.poolSims()
        for jobID in cleanupOwners.subtracting(activeIDs) {
            guard var job = try store.job(id: jobID) else { continue }
            // An infra retry clears grants, but its old process and simulator lease
            // remain a real capacity commitment until verified cleanup finishes.
            job.grantedSims = max(job.grantedSims, leases.filter { $0.leaseID == Self.poolLeaseID(jobID: jobID) }.count)
            active.append(job)
        }
        var queued = try store.queuedJobs()
        let availablePool: PoolSnapshot
        if pool != nil {
            availablePool = try poolCapacity()
        } else if queued.contains(where: { $0.resources.needsSims }) {
            availablePool = try environment.sims.poolSnapshot()
        } else {
            // No simulator allocation can be made this pass. Active jobs still feed
            // CapacityState's committed grants and project/exclusive accounting; a
            // backend inventory cannot change admission of simulator-free work.
            availablePool = PoolSnapshot()
        }
        // Legacy backend inventory can be slow too. Refresh both the resource sample
        // and admission timestamp rather than authorizing work from the caller's old
        // sample; jobs whose queue deadline passed during that wait cannot be admitted.
        now = environment.clock.now()
        if now - host.sampledAt >= 1 {
            host = try environment.probe.sample(now: now)
            recordSwapSample(host, at: now)
        }
        for job in queued where job.isQueueExpired(now: now) {
            if try store.expire(jobID: job.id, now: now) { timeoutReport.expired.append(job.id) }
        }
        queued.removeAll { $0.isQueueExpired(now: now) }
        var control = try store.queueControl()
        control.paused = control.paused || maintenanceDraining
        let drainPolicy = scheduler.config.drain
        let failures = try store.allInfraFailureTimes(since: now - drainPolicy.windowSeconds)
        let drain = drainPolicy.status(failureTimes: failures, clearedAt: control.drainClearedAt, now: now)
        let input = SchedulerInput(
            now: now,
            queued: queued,
            active: active,
            host: host,
            swapGrowthBytesPerMinute: swapTracker.growthBytesPerMinute,
            pool: availablePool,
            control: control,
            drain: drain,
            loadThrottledPreviously: loadThrottled,
            allowNewBoots: pool == nil,
            lastAdmissionAt: lastAdmissionAt,
            cleanupJobIDs: cleanupOwners
        )
        let plan = scheduler.plan(input)
        if plan.loadThrottled != loadThrottled {
            try store.setLoadThrottled(plan.loadThrottled, detail: "load1=\(host.load1) load5=\(host.load5)", now: now)
        }
        loadThrottled = plan.loadThrottled

        var admitted: [String] = []
        for admission in plan.admissions {
            guard try store.recordAdmissionAttempt(jobID: admission.jobID, epoch: epoch, now: now) else { continue }
            #if DEBUG
                admissionAttemptRecorded(admission.jobID)
            #endif
            if try store.claim(jobID: admission.jobID, grantedSims: admission.grantedSims, epoch: epoch, now: now)
                != nil
            {
                admitted.append(admission.jobID)
                lastAdmissionAt = now
                if pool != nil, admission.grantedSims > 0 {
                    try leasePoolSims(count: admission.grantedSims, jobID: admission.jobID, now: now)
                    try queueSimPrepIfNeeded(jobID: admission.jobID)
                }
            }
        }
        try store.saveExplanations(plan.waiting, at: now)
        return TickResult(
            plan: plan, timeouts: timeoutReport, admitted: admitted, drain: drain, host: host,
            globalReasons: scheduler.globalWaitReasons(input))
    }

    /// What exists right now, according to the injected backends.
    public func observeWorld() throws -> ObservedWorld {
        let fileSystem = environment.fileSystem
        let layout = environment.layout
        let directories = try fileSystem.children(of: layout.runsRoot) + fileSystem.children(of: layout.derivedDataRoot)
        let protectedCreates = Set(
            try store.pendingActionIntents().compactMap { intent -> String? in
                guard hostActionIntentsInFlight.contains(intent.id) || Self.isPoolCloneOperation(intent),
                    case .simCreate(let name) = intent.target,
                    environment.naming.owns(name), !environment.naming.isTemplate(name)
                else { return nil }
                return name
            })
        // Unregistered partial clones belong to their durable operation, including
        // after restart or while cleanup is rate-limited. Registered partial resources
        // remain visible so normal reconciliation cannot falsely mark them gone.
        let registeredSims =
            protectedCreates.isEmpty ? Set<String>() : Set(try store.liveResources(kinds: [.sim]).map(\.externalID))
        return ObservedWorld(
            sims: try environment.sims.listDevices().filter {
                !protectedCreates.contains($0.name) || registeredSims.contains($0.udid)
            },
            liveProcessGroups: try environment.processes.liveProcessGroups(),
            managedDirectories: Set(directories)
        )
    }

    /// What a full reconcile would propose right now. Read-only: no store writes and
    /// nothing on the host changes (for `simq doctor`).
    public func plannedReconcile(world: ObservedWorld? = nil) throws -> [ReconcileAction] {
        let activeJobs = Set(try store.activeJobs().filter { $0.ownerEpoch == epoch }.map(\.id))
        let resources = try store.liveResources()
        let planned = Reconciler.plan(
            resources: resources, activeJobs: activeJobs, epoch: epoch,
            world: try world ?? observeWorld(),
            naming: environment.naming, layout: environment.layout, foreignAllowlist: reliability.foreignAllowlist,
            leaseMaxAgeSeconds: reliability.ageRules.leaseMaxAgeSeconds, now: environment.clock.now())
        return try protectingCleanupResources(planned, resources: resources)
    }

    /// Process cleanup must be proven complete before releasing its files or devices.
    /// PG actions remain eligible; dependent cleanup resumes on the following pass.
    private func protectingCleanupResources(_ actions: [ReconcileAction], resources: [OwnedResource]) throws
        -> [ReconcileAction]
    {
        let owners = try jobsWithLiveProcessGroups()
        let held = Set(
            resources.filter { $0.kind != .processGroup && $0.owner.jobID.map(owners.contains) == true }.map(\.id))
        return actions.filter { action in
            let id: Int64?
            switch action {
            case .markGone(let value), .adopt(let value), .revokeLease(let value): id = value
            case .deleteSim(_, let value), .removeDirectory(_, let value): id = value
            case .killProcessGroup, .reportForeignSim: return true
            }
            return id.map { !held.contains($0) } ?? true
        }
    }

    /// Audit type recorded for each executed destructive action (drives the hourly limit).
    public static let destructiveAuditType = "cleanup_executed"

    /// Compares the ownership ledger with reality and cleans up, without surprises:
    /// - bookkeeping (rows gone, pool adoption, lease revocation) applies at once;
    /// - a destructive action runs only after its target has been a candidate for the
    ///   orphan grace period, only in `enforce` mode, and only within the per-pass and
    ///   per-hour limits; otherwise it is deferred and retried on a later pass;
    /// - process groups go before sims, sims before directories;
    /// - each action is re-checked against the namespace (and the foreign allowlist)
    ///   right before it runs, so a bad row can't touch a foreign sim or unmanaged path.
    /// - every destructive action is verified (the target is gone) before it is audited
    ///   as executed; a failed or unverified action is audited as `cleanup_failed`;
    /// - anything that keeps failing, being refused, rate limited or held back by
    ///   report-only mode escalates through `AnomalyTracker` (sustained, needs_human).
    /// Safe to call at startup and periodically (watchdog hook).
    @discardableResult
    public func reconcile() throws -> ReconcileReport {
        // Outside a watchdog pass the breaker isn't stepped, but an open one still holds.
        let phase = try store.watchdogState().breaker.phase
        return try reconcile(scope: .full, limits: Breaker.limit(reliability, phase: phase))
    }

    /// One watchdog pass (spec §8a.2). It gets a pass id stamped on every audit entry it
    /// writes, runs reconcile for its scope under the circuit breaker's limits (report-only
    /// while open, one action while half-open), steps the breaker and persists the
    /// watchdog state. The cleanup mode still decides whether anything is destroyed.
    @discardableResult
    public func watchdogPass(_ kind: WatchdogPassKind, config: WatchdogConfig) throws -> WatchdogPassReport {
        let now = environment.clock.now()
        var state = try store.watchdogState()
        state.passCount += 1
        let passID = "\(kind.rawValue)-\(epoch)-\(state.passCount)"
        store.currentPassID = passID
        defer { store.currentPassID = nil }

        var transitions: [BreakerTransition] = []
        let (current, timed) = Breaker.advance(state.breaker, now: now, policy: config.breaker)
        if let timed { transitions.append(timed) }
        let limits = Breaker.limit(reliability, phase: current.phase)
        let report = try reconcile(scope: kind, limits: limits)
        // Manual pool leases protect a sim only while their holder is live.
        let staleLeases = try reclaimStaleManualLeases(limits: limits, executedThisPass: report.executed.count)
        let (age, ageAlerts) =
            kind == .full ? try applyAgeRules(now: now, mode: limits.cleanupMode) : (AgeRuleReport(), [])
        let outcome = BreakerPassOutcome(
            executedTargets: report.executed.compactMap(\.targetKey), failures: report.failedActions)
        let (after, recorded) = Breaker.record(outcome, state: current, now: now, policy: config.breaker)
        if let recorded { transitions.append(recorded) }
        for transition in transitions {
            switch transition {
            case .opened(let reason):
                try store.audit("breaker_opened", detail: reason, now: now)
            case .halfOpened:
                try store.audit("breaker_half_open", detail: current.reason, now: now)
            case .closed:
                try store.audit("breaker_closed", now: now)
            }
        }

        state.breaker = after
        // A light pass doesn't list sims or directories, so it only clears a light pass's
        // failure; a full pass clears either. (A hung `simctl` keeps health degraded.)
        if kind == .full || state.lastPassError?.hasPrefix("\(WatchdogPassKind.light.rawValue) pass:") == true {
            state.lastPassError = nil
            state.lastPassErrorAt = nil
        }
        state.lastPassID = passID
        state.lastPassKind = kind
        state.lastPassAt = now
        switch kind {
        case .light: state.lastLightPassAt = now
        case .full: state.lastFullPassAt = now
        }
        // A backlog held by the per-pass or hourly limit waits for the next window. Log
        // newly postponed targets once; a pass only replaces the targets it covers.
        let postponed = Set(report.deferredRateLimit.compactMap(\.targetKey))
        let previous = Set(state.postponedTargets)
        let newlyPostponed = postponed.subtracting(previous)
        if !newlyPostponed.isEmpty {
            try store.audit(
                "cleanup_postponed",
                detail: "\(postponed.count) held by the \(report.hourlyLimitHit ? "hourly" : "per-pass") limit: "
                    + newlyPostponed.sorted().joined(separator: ", "),
                now: now)
        }
        state.postponedTargets = (previous.filter { !kind.covers(targetKey: $0) }.union(postponed)).sorted()
        try store.saveWatchdogState(state, now: now)
        let health = HealthSummary.evaluate(
            breaker: after, anomalies: report.anomalies, draining: try drainActive(now: now), lastPassAt: now,
            now: now, staleAfterSeconds: .infinity, postponed: state.postponedTargets.count)
        let alerts =
            Self.alertEvents(escalated: report.escalated, transitions: transitions) + report.lookalikeAlerts
            + ageAlerts
        try store.recordAlerts(alerts, now: now, policy: config.alerts)
        var cleared: [String] = []
        if kind == .full {
            let active = try activeAlertKeys(report: report, breaker: after).union(alerts.map(\.key))
            cleared = try store.stepAlertClearance(activeKeys: active, now: now, policy: config.alerts).map(\.key)
        }
        var passReport = WatchdogPassReport(
            passID: passID, kind: kind, reconcile: report, breaker: after, transitions: transitions, health: health,
            alerts: alerts, age: age)
        passReport.alertsCleared = cleared
        passReport.staleLeases = staleLeases
        return passReport
    }

    /// Alert keys whose condition still holds after a full pass (see `AlertBook.isCheckable`):
    /// an anomaly still being seen, a breaker that isn't closed, a lookalike sim that still
    /// exists or a job still queued.
    func activeAlertKeys(report: ReconcileReport, breaker: BreakerState) throws -> Set<String> {
        var keys = Set(report.anomalies.filter { $0.cleanPasses == 0 }.map { "anomaly:\($0.key)" })
        if breaker.phase != .closed { keys.insert("breaker") }
        for action in report.actions {
            if case .reportForeignSim(let udid, _) = action { keys.insert("lookalike_sim:\(udid)") }
        }
        for job in try store.queuedJobs() { keys.insert("queued:\(job.id)") }
        return keys
    }

    /// Records a watchdog pass that threw (a hung or failing backend, a database error):
    /// audited as `watchdog_pass_failed` and shown in health until a pass that covers it
    /// completes (a full pass, or a light pass for a light pass's failure). Best
    /// effort, since the database may be what failed.
    public func recordWatchdogFailure(_ kind: WatchdogPassKind, error: any Error) {
        let now = environment.clock.now()
        let detail = "\(kind.rawValue) pass: \(error)"
        try? store.audit("watchdog_pass_failed", detail: detail, now: now)
        if var state = try? store.watchdogState() {
            state.lastPassError = detail
            state.lastPassErrorAt = now
            try? store.saveWatchdogState(state, now: now)
        }
    }

    /// Alert-worthy events of one pass (spec §8a.4): a sustained anomaly is a `warn`, one
    /// that needs a human is a `page`, and a circuit-breaker trip is a `page` that needs a
    /// human. Keys are stable, so repeats update one alert.
    static func alertEvents(escalated: [AnomalyRecord], transitions: [BreakerTransition]) -> [AlertEvent] {
        var events = escalated.map { anomaly in
            let human = anomaly.level == .needsHuman
            return AlertEvent(
                key: "anomaly:\(anomaly.key)", level: human ? .page : .warn,
                title: "\(human ? "Needs a human" : "Sustained anomaly"): \(anomaly.key)",
                detail: "\(anomaly.detail) (seen on \(anomaly.consecutivePasses) passes in a row)", needsHuman: human)
        }
        for transition in transitions {
            if case .opened(let reason) = transition {
                events.append(
                    AlertEvent(
                        key: "breaker", level: .page, title: "Circuit breaker open",
                        detail: "\(reason); the watchdog is report-only until it half-opens", needsHuman: true))
            }
        }
        return events
    }

    /// Whether the infra-failure drain is holding admissions.
    public func drainActive(now: Double) throws -> Bool {
        let control = try store.queueControl()
        let drainPolicy = scheduler.config.drain
        let failures = try store.allInfraFailureTimes(since: now - drainPolicy.windowSeconds)
        if case .draining = drainPolicy.status(failureTimes: failures, clearedAt: control.drainClearedAt, now: now) {
            return true
        }
        return false
    }

    /// Reconcile limited to what a `scope` pass checks, under `limits` (the breaker may
    /// tighten the configured ones). A light pass only looks at process groups and leases
    /// and leaves other targets' grace periods and anomalies untouched.
    /// The anomaly key for recurring pool settle cap hits (outside every light-pass prefix).
    public static let settleCapAnomalyKey = "pool:settle_cap"

    func reconcile(scope: WatchdogPassKind, limits: ReliabilityConfig) throws -> ReconcileReport {
        let intents = try resolveActionIntents()
        let now = environment.clock.now()
        // A light pass only acts on process groups and leases, so it neither lists sims
        // and directories nor plans for the rows that track them (that would make its cost
        // grow with every leftover a report-only full pass carries).
        let world =
            scope == .light
            ? ObservedWorld(liveProcessGroups: try environment.processes.liveProcessGroups()) : try observeWorld()
        let activeJobs = Set(try store.activeJobs().filter { $0.ownerEpoch == epoch }.map(\.id))
        let liveResources =
            scope == .light
            ? try store.liveResources(kinds: [.processGroup, .lease]) : try store.liveResources()
        let kinds = Dictionary(liveResources.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        let planned = Reconciler.plan(
            resources: liveResources,
            activeJobs: activeJobs,
            epoch: epoch,
            world: world,
            naming: environment.naming,
            layout: environment.layout,
            foreignAllowlist: reliability.foreignAllowlist,
            leaseMaxAgeSeconds: reliability.ageRules.leaseMaxAgeSeconds,
            now: now
        )
        let safePlanned = try protectingCleanupResources(planned, resources: liveResources)
        let actions = safePlanned.filter { action in
            switch (scope, action) {
            case (.full, _), (.light, .killProcessGroup), (.light, .revokeLease): return true
            case (.light, .markGone(let id)), (.light, .adopt(let id)):
                return kinds[id] == .processGroup || kinds[id] == .lease
            case (.light, _): return false
            }
        }
        let simNames = Dictionary(world.sims.map { ($0.udid, $0.name) }, uniquingKeysWith: { first, _ in first })
        let resourcesByID = Dictionary(liveResources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ownedSimNames = Set(
            liveResources.filter { $0.kind == .sim }.compactMap { simNames[$0.externalID] })
        let sightings = try store.syncSightings(
            Set(actions.compactMap(\.sightingKey)), scopePrefix: scope.targetKeyPrefix,
            inScope: scope.covers(targetKey:), now: now)
        var gate = CleanupGate(
            config: limits,
            executedLastHour: try store.auditCount(type: Self.destructiveAuditType, since: now - 3600)
        )
        var report = ReconcileReport(actions: actions)
        report.intents = intents
        // Target key -> description, for every action that failed, was refused, is rate
        // limited, or is held back by report-only mode on this pass.
        var anomalous: [String: String] = [:]
        func noteAnomaly(_ action: ReconcileAction, _ what: String) {
            anomalous[action.sightingKey ?? "\(action)"] = what
        }
        // Rows already orphaned stay as they are: a pass over old leftovers writes nothing.
        func markOrphaned(_ id: Int64?) throws {
            guard let id, resourcesByID[id]?.state != .orphaned else { return }
            try store.markResourceOrphaned(id: id, reason: "owner gone", now: now)
        }

        let reportOnly = limits.cleanupMode == .reportOnly
        // A light pass only re-checks what it covers; the rest stay parked.
        // Entries this pass re-parks; at the end they replace the covered part of `parked`
        // in place, so a light pass doesn't copy the full pass's parked leftovers.
        var stillParked: [String: ParkedLeftover] = [:]
        defer {
            if !reportOnly {
                parked = PrefixBuckets()
            } else if let prefix = scope.targetKeyPrefix {
                // Only the covered bucket is replaced; the others aren't walked.
                parked.setBucket(prefix, stillParked.filter { $0.key.hasPrefix(prefix) })
                for (key, entry) in stillParked where !key.hasPrefix(prefix) { parked[key] = entry }
            } else {
                parked = PrefixBuckets(stillParked)
            }
        }
        for action in actions {
            // Fast path: the same report-only leftover as last pass, already reported.
            if reportOnly, let key = action.sightingKey, let entry = parked[key], entry.action == action,
                sightings[key]?.reported == true, now - entry.confirmedAt < Self.parkedReconfirmSeconds
            {
                report.wouldExecute.append(action)
                anomalous[key] = entry.what
                stillParked[key] = entry
                continue
            }
            do {
                switch action {
                case .markGone(let id):
                    try store.markResourceReleased(id: id, reason: "gone at reconcile", now: now)
                    continue
                case .adopt(let id):
                    try store.adoptResource(id: id, epoch: epoch, now: now)
                    continue
                case .revokeLease(let id):
                    let age = now - (resourcesByID[id]?.acquiredAt ?? now)
                    let reason =
                        age >= reliability.ageRules.leaseMaxAgeSeconds
                        ? "lease revoked: older than \(Int(reliability.ageRules.leaseMaxAgeSeconds)) s"
                        : "lease revoked: holder gone"
                    try store.markResourceReleased(id: id, reason: reason, now: now)
                    continue
                case .reportForeignSim(let udid, let name):
                    // Audited once per sighting, not on every pass.
                    if let key = action.sightingKey, let sighting = sightings[key], !sighting.reported {
                        try store.audit("foreign_sim_seen", detail: "\(name) \(udid)", now: now)
                        // A lookalike (a name that resembles SimQueue's namespace, or an owned
                        // sim's name) is how a sim gets wrongly adopted: alert once. It is
                        // still never adopted or touched.
                        if environment.naming.isLookalike(name) || ownedSimNames.contains(name) {
                            report.lookalikeAlerts.append(
                                AlertEvent(
                                    key: "lookalike_sim:\(udid)", level: .warn,
                                    title: "Lookalike sim outside SimQueue's ownership",
                                    detail:
                                        "\(name) (\(udid)) looks like a SimQueue sim but has no ownership record; "
                                        + "it is never adopted or touched"))
                        }
                        try store.markSightingReported(key)
                    }
                    continue
                case .killProcessGroup(let pgid, let id):
                    // Only a group whose leader still has the recorded identity is ours to
                    // signal; a reused pgid means ours is gone.
                    switch try environment.processes.verifyGroup(
                        pgid, identity: resourcesByID[id]?.identity, live: world.liveProcessGroups)
                    {
                    case .verified:
                        try markOrphaned(id)
                    case .gone:
                        try store.markResourceReleased(id: id, reason: "gone at reconcile", now: now)
                        continue
                    case .reused:
                        try store.markResourceReleased(
                            id: id, reason: "process group \(pgid) gone (pgid reused by another process)", now: now)
                        try store.audit(
                            "pgid_reused", resourceID: id, detail: "pgid \(pgid) leads a different process", now: now)
                        continue
                    case .unverifiable(let reason):
                        try markOrphaned(id)
                        report.failures.append("refused to stop process group \(pgid): \(reason)")
                        noteAnomaly(action, "refused: \(reason)")
                        try auditRefusalOnce(action, sightings: sightings, resourceID: id, detail: reason, now: now)
                        continue
                    }
                case .deleteSim(let udid, let id):
                    // Templates are never reaped (the planner already skips them); no
                    // failure, anomaly or budget spent on one.
                    if let name = simNames[udid], environment.naming.isTemplate(name) { continue }
                    try markOrphaned(id)
                    guard let name = simNames[udid],
                        environment.naming.owns(name) || reliability.foreignAllowlist.allowsSim(named: name)
                    else {
                        report.failures.append("refused to delete sim \(udid): outside the namespace and allowlist")
                        noteAnomaly(action, "refused: sim \(udid) outside the namespace")
                        try auditRefusalOnce(
                            action, sightings: sightings, resourceID: id, detail: "sim \(udid)", now: now)
                        continue
                    }
                case .removeDirectory(let path, let id):
                    try markOrphaned(id)
                    guard environment.layout.isManaged(path) else {
                        report.failures.append("refused to remove \(path): outside managed roots")
                        noteAnomaly(action, "refused: \(path) outside managed roots")
                        try auditRefusalOnce(action, sightings: sightings, resourceID: id, detail: path, now: now)
                        continue
                    }
                }

                guard let key = action.sightingKey, let sighting = sightings[key] else { continue }
                let grace = reliability.ageRules.graceSeconds(forTargetKey: key, default: limits.orphanGraceSeconds)
                switch gate.decide(firstSeenAt: sighting.firstSeenAt, now: now, graceSeconds: grace) {
                case .deferGrace:
                    report.deferredGrace.append(action)
                case .deferRateLimit:
                    report.deferredRateLimit.append(action)
                    noteAnomaly(action, "rate limited: \(action)")
                case .wouldExecute:
                    report.wouldExecute.append(action)
                    let what = "report-only: \(action)"
                    anomalous[key] = what
                    if !sighting.reported {
                        try store.audit("cleanup_would_execute", detail: "\(action)", now: now)
                        try store.markSightingReported(key)
                    }
                    stillParked[key] = ParkedLeftover(action: action, what: what, confirmedAt: now)
                case .execute:
                    try perform(action, now: now)
                    try store.clearSighting(key)
                    report.executed.append(action)
                }
            } catch {
                report.failedActions += 1
                report.failures.append("\(action): \(error)")
                noteAnomaly(action, "failed: \(action): \(error)")
                try store.audit("cleanup_failed", detail: "\(action): \(error)", now: now)
            }
        }
        // Pool settle cap hits since the previous full pass count as one host-level
        // anomaly, judged by full passes only (a light pass never touches its key, and the
        // full pass's rewrite of the book keeps it while hits recur). It escalates and
        // clears like any other anomaly, so recurring cap hits reach the sustained alert.
        if scope == .full {
            let since = try store.watchdogState().lastFullPassAt ?? (now - WatchdogConfig().fullIntervalSeconds)
            let hits = try store.auditCount(type: "settle_cap_hit", since: since)
            if hits > 0 {
                anomalous[Self.settleCapAnomalyKey] =
                    "\(hits) pool settle cap hit\(hits == 1 ? "" : "s") since the previous full pass"
            }
        }
        // A light pass only judges the targets it checks; the rest carry over unchanged.
        if let prefix = scope.targetKeyPrefix {
            // A light pass steps and saves only its own key range (sorted keys share a
            // prefix contiguously); the rest of the book isn't copied or re-diffed.
            let update = AnomalyTracker.step(
                previous: try store.anomalies(withPrefix: prefix), seen: anomalous, now: now,
                policy: reliability.anomalies)
            try store.saveAnomalies(update, now: now, prefix: prefix)
            report.escalated = update.escalated
        } else {
            let update = AnomalyTracker.step(
                previous: try store.anomalies(), seen: anomalous, now: now, policy: reliability.anomalies)
            try store.saveAnomalies(update, now: now)
            report.escalated = update.escalated
        }
        report.anomalies = try store.anomalies()
        report.hourlyLimitHit = gate.hourlyLimitHit
        return report
    }

    private func auditRefusalOnce(
        _ action: ReconcileAction,
        sightings: [String: JobStore.Sighting],
        resourceID: Int64?,
        detail: String,
        now: Double
    ) throws {
        guard let key = action.sightingKey, sightings[key]?.reported == false else { return }
        try store.audit("cleanup_refused", resourceID: resourceID, detail: detail, now: now)
        try store.markSightingReported(key)
    }

    private func perform(_ action: ReconcileAction, now: Double) throws {
        switch action {
        case .killProcessGroup(let pgid, let id):
            let intent = ActionIntent(
                target: .processGroup(pgid), auditType: Self.destructiveAuditType,
                detail: "terminated process group \(pgid)", resourceID: id, releaseReason: "process group terminated")
            try performUnderIntent(intent, now: now) {
                try environment.processes.terminateGroup(pgid, graceSeconds: environment.processGraceSeconds)
                if try environment.processes.liveProcessGroups().contains(pgid) {
                    throw EngineError.cleanupNotVerified("process group \(pgid)")
                }
            }
        case .deleteSim(let udid, let id):
            let intent = ActionIntent(
                target: .sim(udid: udid), auditType: Self.destructiveAuditType, detail: "deleted sim \(udid)",
                resourceID: id, releaseReason: id == nil ? nil : "sim deleted")
            try performUnderIntent(intent, now: now) {
                try environment.sims.deleteDevice(udid: udid)
                if try environment.sims.listDevices().contains(where: { $0.udid == udid }) {
                    throw EngineError.cleanupNotVerified("sim \(udid)")
                }
            }
        case .removeDirectory(let path, let id):
            let intent = ActionIntent(
                target: .path(path), auditType: Self.destructiveAuditType, detail: "removed \(path)",
                resourceID: id, releaseReason: id == nil ? nil : "directory removed")
            try performUnderIntent(intent, now: now) {
                try environment.fileSystem.removeItem(path)
                if environment.fileSystem.fileExists(path) {
                    throw EngineError.cleanupNotVerified(path)
                }
            }
        case .markGone, .adopt, .revokeLease, .reportForeignSim:
            break
        }
    }
}

/// A run of pool passes deferring the same boots for load.
struct BootDeferral: Equatable {
    var udids: [String]
    /// When boots were first deferred (kept across changes in which sims, like `passes`).
    var since: Double
    var auditedAt: Double
    var passes: Int
}
