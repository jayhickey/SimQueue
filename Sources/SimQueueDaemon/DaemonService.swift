// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueEngine
import SimQueueHost
import SimQueueProtocol
import SimQueueSim
import SimQueueStore

/// The daemon's single point of truth. One lock serializes the engine, the store and the
/// executor, so socket handlers and the tick loop never interleave inside SQLite or the
/// scheduler.
public final class DaemonService: @unchecked Sendable {
    private let lock = NSLock()
    public let engine: Engine
    public let config: DaemonConfig
    public let info: DaemonInfo
    private let executor: (any JobExecutor)?
    /// Where job logs and `job.json` live.
    public let artifacts: JobArtifacts
    private var hostWorkInFlight = 0
    private let poolQueue = DispatchQueue(label: "simqd.pool-host-work")
    private var poolPassRunning = false
    private var poolFailure: EngineError?
    private let historyQueue = DispatchQueue(label: "simqd.history-archive")
    private var historyRunning = false
    private let artifactQueue = DispatchQueue(label: "simqd.artifact-retention")
    private var artifactCleanupRunning = false
    private var artifactStorage: ArtifactStorageInfo?
    private var lastStorageReviewRequestedAt: Double = -.infinity
    private var artifactCleanupDue = true
    private let artifactRequests = DispatchGroup()
    private var lastHistoryAt: Double = -.infinity
    private var shutdownRequested = false
    public var wakeScheduler: @Sendable () -> Void = {}
    /// At most five seconds idle resource-recovery latency, one normal tick while work
    /// is active or a host operation is outstanding. Controls wake the semaphore at once.
    public var nextTickInterval: Double {
        locked {
            let busy =
                poolPassRunning || artifactCleanupRunning || !engine.artifactWritersInFlight.isEmpty
                || ((try? store.activeJobs().isEmpty) == false)
                || ((try? store.queuedJobs().isEmpty) == false)
                || ((try? store.liveResources(kinds: [.processGroup]).isEmpty) == false)
            return busy ? min(1, config.tickIntervalSeconds) : min(5, max(1, config.tickIntervalSeconds * 5))
        }
    }
    private var lastTick: TickResult?
    /// The last pool pass (nil with the pool off or before the first).
    private(set) var lastPoolPass: PoolPassReport?
    /// `lease_acquire` holders still waiting, by when they last polled. A holder that
    /// stops polling stops counting as demand after `leasePollExpirySeconds`.
    private var pendingLeases: [String: Double] = [:]
    static let leasePollExpirySeconds: Double = 15
    private var lastTickAt: Double?
    /// Last light and full watchdog pass times (loaded from the store at startup).
    private var lastLightPassAt: Double?
    private var lastFullPassAt: Double?
    /// Where `health.json` goes.
    public let healthPath: String
    /// Sim preparation (`reset_apps`, `fresh_sim`) runs here, one job at a time, off the
    /// tick and the service lock: an erase can take minutes.
    private let simPrepQueue = DispatchQueue(label: "simqd.sim-prep")
    private let startPreparationQueue = DispatchQueue(label: "simqd.job-start-preparation")
    private let log: @Sendable (String) -> Void

    public var store: JobStore { engine.store }
    /// Checks a submitted `git_sha` against its worktree (`git rev-parse`, read-only).
    public var gitCheckout = GitCheckout()
    /// `<state dir>/events.jsonl`, appended every tick (nil: off).
    public var storageChecksEnabled = false
    public var eventLog: EventLog?

    public init(
        engine: Engine, config: DaemonConfig, info: DaemonInfo, executor: (any JobExecutor)?,
        artifacts: JobArtifacts? = nil,
        log: @escaping @Sendable (String) -> Void = {
            FileHandle.standardError.write(Data(("simqd: " + $0 + "\n").utf8))
        }
    ) {
        self.log = log
        self.engine = engine
        self.config = config
        engine.pool = config.pool
        engine.hostTemplates = config.hostTemplates
        engine.defaultHostTemplate = config.defaultHostTemplate
        if config.pool != nil {
            // A restart may leave pool rows mid-boot or pointing at sims that are gone.
            do {
                try engine.reconcilePool()
            } catch {
                log("pool reconcile failed: \(error)")
            }
        }
        self.info = info
        self.executor = executor
        (executor as? ProcessExecutor)?.asynchronousPreparation = true
        self.eventLog = EventLog(
            path: ((info.statePath as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("events.jsonl"))
        self.artifacts =
            artifacts
            ?? JobArtifacts(
                root: ((info.statePath as NSString).deletingLastPathComponent as NSString)
                    .appendingPathComponent("jobs"))
        let stateDir = (info.statePath as NSString).deletingLastPathComponent
        self.healthPath = SimQueuePaths(stateDir: stateDir).healthPath
        let state = (try? engine.store.watchdogState()) ?? WatchdogState()
        // `Engine.start` ran the first full pass, so the next light pass is one interval out.
        self.lastLightPassAt = state.lastLightPassAt
        self.lastFullPassAt = state.lastFullPassAt
        try? writeHealth(now: engine.environment.clock.now())
        engine.templateVersions = { [weak self] in self?.templateVersions }
    }

    /// The host's Xcode and runtime versions for template staleness, probed outside the
    /// service lock (it runs xcodebuild and simctl) and read under it.
    private let versionsLock = NSLock()
    private var cachedTemplateVersions: TemplateToolVersions?

    var templateVersions: TemplateToolVersions? {
        versionsLock.lock()
        defer { versionsLock.unlock() }
        return cachedTemplateVersions
    }

    /// Re-probes the tool versions. Call without the service lock held.
    @discardableResult
    func refreshTemplateVersions() -> TemplateToolVersions? {
        guard let builder = engine.environment.sims as? TemplateBuilding,
            let versions = try? builder.toolVersions()
        else { return templateVersions }
        versionsLock.lock()
        cachedTemplateVersions = versions
        versionsLock.unlock()
        return versions
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// For the pool pass's slow host work (a simslim clone, a boot): called with the service
    /// lock held, it drops the lock for `body` and takes it back after, so requests are
    /// answered meanwhile. The serial pool worker owns one pass, so no second pass starts.
    private func withoutLock(_ body: () throws -> Void) throws {
        hostWorkInFlight += 1
        lock.unlock()
        defer { lock.lock(); hostWorkInFlight -= 1 }
        try body()
    }

    /// Called after server loops stop, outside the state lock. The normal upgrade
    /// path drains first, so these bounded host workers are already empty.
    public func waitForBackgroundWork() {
        poolQueue.sync {}
        historyQueue.sync {}
        artifactQueue.sync {}
        artifactRequests.wait()
        simPrepQueue.sync {}
        startPreparationQueue.sync {}
    }

    // MARK: - Run loop step

    /// One scheduling pass: timeouts, admission, the executor, and a watchdog pass when one
    /// is due (light every `watchdog.lightIntervalSeconds`, full every
    /// `watchdog.fullIntervalSeconds`), each followed by a fresh `health.json`.
    /// Throws `EngineError.lostLease` if another daemon took over; the caller must stop.
    @discardableResult
    public func tick() throws -> TickResult {
        try locked {
            if shutdownRequested, let lastTick { return lastTick }
            if let failure = poolFailure { throw failure }
            let nowForProbe = engine.environment.clock.now()
            let host = try engine.environment.probe.sample(now: nowForProbe)
            if var pool = config.pool, !poolPassRunning {
                if engine.maintenanceDraining { pool.warmMin = 0 }
                let settings = pool
                let extra = engine.maintenanceDraining ? 0 : pendingLeaseDemand()
                poolPassRunning = true
                poolQueue.async { [self] in
                    locked {
                        defer { poolPassRunning = false }
                        do {
                            let now = engine.environment.clock.now()
                            let fresh = now - host.sampledAt <= 1 ? host : try engine.environment.probe.sample(now: now)
                            lastPoolPass = try engine.poolPass(
                                config: settings, demand: engine.maintenanceDraining ? 0 : nil,
                                extraDemand: extra, host: fresh, hostWork: { try withoutLock($0) })
                        } catch let error as EngineError { poolFailure = error } catch {
                            log("pool pass failed: \(error)")
                        }
                    }
                }
            }
            if storageChecksEnabled {
                do {
                    let roots = Set(
                        [artifacts.root] + (try store.queuedJobs()).compactMap { $0.command?.artifactsRoot })
                    try JobStorage.ensureFreeSpace(
                        JobStorage.freeBytes("/"), minimum: config.scheduler.minFreeDiskBytes)
                    for root in roots {
                        try JobStorage.check(root)
                        try JobStorage.ensureFreeSpace(
                            JobStorage.freeBytes(root), minimum: config.scheduler.minFreeDiskBytes)
                    }
                    engine.admissionStorageFailure = nil
                } catch {
                    engine.admissionStorageFailure = String(describing: error)
                }
            }
            let result = try engine.tick(host: host)
            let now = engine.environment.clock.now()
            if !historyRunning, now - lastHistoryAt >= 3600, info.statePath != ":memory:" {
                historyRunning = true; lastHistoryAt = now
                let statePath = info.statePath; let artifactRoot = artifacts.legacyRoot ?? artifacts.root
                let outputRoots = engine.environment.allArtifactsRoots
                historyQueue.async { [self] in
                    do {
                        for root in outputRoots { try JobStorage.check(root) }
                        _ = try JobStore.archiveHistory(path: statePath, artifactsRoot: artifactRoot, now: now)
                    } catch { log("history archival deferred: \(error)") }
                    locked { historyRunning = false }
                }
            }
            startSimPrep()
            executor?.heldJobIDs = engine.jobsAwaitingSimPrep
            do {
                try executor?.step(store: store, epoch: engine.epoch, now: now)
            } catch {
                startProcessPreparations()
                throw error
            }
            startProcessPreparations()
            do {
                try eventLog?.append(from: store)
            } catch {
                log("event log append failed: \(error)")
            }
            lastTick = result
            lastTickAt = now
            if let kind = config.watchdog.due(lastLightAt: lastLightPassAt, lastFullAt: lastFullPassAt, now: now) {
                // A failed pass (hung backend, database error) is recorded and retried at
                // the next interval, not on every tick; scheduling carries on.
                do {
                    try engine.watchdogPass(kind, config: config.watchdog, includeArtifactRetention: false)
                } catch let error as EngineError {
                    throw error
                } catch {
                    log("watchdog \(kind.rawValue) pass failed: \(error)")
                    engine.recordWatchdogFailure(kind, error: error)
                }
                switch kind {
                case .light: lastLightPassAt = now
                case .full:
                    lastFullPassAt = now
                    artifactCleanupDue = true
                }
                try? writeHealth(now: now)
            }
            if artifactCleanupDue && !artifactCleanupRunning && !engine.maintenanceDraining && !shutdownRequested {
                artifactCleanupDue = false
                artifactCleanupRunning = true
                artifactQueue.async { [self] in
                    defer { locked { artifactCleanupRunning = false } }
                    do {
                        let outcome = try collectArtifacts(apply: true, automatic: true)
                        if !outcome.candidates.isEmpty {
                            log(
                                "artifact retention: \(outcome.removed.count) removed, \(outcome.failures.count) failed; "
                                    + "simq gc lists remaining candidates (including report-only/breaker holds)"
                            )
                        }
                    } catch {
                        log("artifact retention deferred: \(error)")
                    }
                }
            }
            return result
        }
    }

    // MARK: - Requests

    /// Answers every method except `wait`, which the server streams with `jobInfo`.
    public func handle(_ request: Request) -> Response {
        guard request.schemaVersion <= Envelope.currentSchemaVersion else {
            return error(
                request,
                ProtocolError(
                    .unsupportedSchemaVersion,
                    "schema_version \(request.schemaVersion) is newer than this daemon (\(Envelope.currentSchemaVersion))"
                ))
        }
        // Template requests probe tools and simctl outside the service lock, and a job's
        // artifacts are listed (a disk walk) after the lock is released.
        switch request.params {
        case .templateBuild(let params): return respond(request) { try templateBuild(params) }
        case .explain(let ref):
            return respond(request) { .job(ArtifactListing.attach(to: try locked { try requireJob(ref.jobID) })) }
        case .wait(let params):
            return respond(request) { .job(ArtifactListing.attach(to: try locked { try requireJob(params.jobID) })) }
        case .templateList: refreshTemplateVersions()
        case .doctor: if templateVersions == nil { refreshTemplateVersions() }
        case .gc(let params):
            // Sizing and removal run outside the lock: a big jobs dir never stalls the scheduler.
            return respond(request) { .gc(try garbageCollect(params)) }
        case .submit(let params):
            // git runs outside the lock: a slow checkout never stalls the scheduler.
            return respond(request) {
                let checked = try verifiedGitSHA(params)
                return try locked {
                    guard !shutdownRequested else { throw ProtocolError(.invalidState, "daemon is stopping") }
                    return .submit(try submit(checked))
                }
            }
        default: break
        }
        return respond(request) {
            try locked {
                if shutdownRequested {
                    switch request.params {
                    case .status, .stop, .jobs, .logs, .doctor, .templateList: break
                    default: throw ProtocolError(.invalidState, "daemon is stopping")
                    }
                }
                switch request.params {
                case .submit: throw ProtocolError(.internalError, "submit is handled above")
                case .status: return .status(try status())
                case .drain:
                    engine.maintenanceDraining = true
                    return .status(try status())
                case .stop(let params):
                    guard params.epoch == info.epoch else { throw ProtocolError(.invalidState, "daemon epoch changed") }
                    let current = try status()
                    guard current.drainComplete == true, lastTick != nil else {
                        throw ProtocolError(.invalidState, "drain must complete before stopping")
                    }
                    shutdownRequested = true
                    return .status(current)
                case .resume:
                    guard !shutdownRequested else { throw ProtocolError(.invalidState, "daemon is stopping") }
                    try JobOutputConfiguration.markDrained(
                        false, stateDirectory: (info.statePath as NSString).deletingLastPathComponent)
                    engine.maintenanceDraining = false
                    try store.resume(now: engine.environment.clock.now())
                    return .status(try status())
                case .jobs(let params): return .jobs(try jobs(params))
                case .explain, .wait: throw ProtocolError(.internalError, "explain and wait are handled above")
                case .cancel(let params): return .job(try cancel(params))
                case .bump(let params): return .job(try bump(params))
                case .logs(let params): return .logs(try logs(params))
                case .leaseAcquire(let params): return .lease(try leaseAcquire(params))
                case .leaseRelease(let params): return .lease(try leaseRelease(params))
                case .leaseRenew(let params): return .lease(try leaseRenew(params))
                case .templateBuild: throw ProtocolError(.internalError, "template_build is handled outside the lock")
                case .templateList: return .template(TemplateResult(outcome: "listed", templates: try templateInfos()))
                case .templateRemove(let params): return .template(try templateRemove(params))
                case .gc: throw ProtocolError(.internalError, "gc is handled outside the lock")
                case .doctor:
                    let now = engine.environment.clock.now()
                    var result = try DoctorBuilder.build(
                        store: store, now: now, daemon: info, socketPath: info.socketPath,
                        live: DoctorBuilder.LiveContext(
                            engine: engine, watchdog: config.watchdog, health: try health(now: now),
                            templateVersions: templateVersions))
                    result.checks.append(storageCheck())
                    return .doctor(result)
                }
            }
        }
    }

    /// Runs `body` and wraps its payload or error as the response to `request`.
    private func respond(_ request: Request, _ body: () throws -> ResultPayload) -> Response {
        do {
            var response = Response(id: request.id, body: .result(try body()))
            response.usesLegacyTemplateNames = request.usesLegacyTemplateNames
            return response
        } catch let failure as TemplateError {
            return error(request, Self.map(failure))
        } catch let failure as ProtocolError {
            return error(request, failure)
        } catch let failure as JobStoreError {
            return error(request, Self.map(failure))
        } catch {
            return self.error(request, ProtocolError(.internalError, "\(error)"))
        }
    }

    // MARK: - Templates

    func templateInfos() throws -> [TemplateInfo] {
        try engine.templates(versions: templateVersions).map { entry in
            let record = entry.record
            return TemplateInfo(
                project: record.project, profile: record.profile, name: record.name, udid: record.udid,
                deviceType: record.deviceType, runtime: record.runtime, xcodeVersion: record.xcodeVersion,
                runtimeVersion: record.runtimeVersion, builtAt: record.builtAt, status: record.status,
                stale: entry.stale, slimmed: record.slimmed)
        }
    }

    static func map(_ failure: TemplateError) -> ProtocolError {
        switch failure {
        case .notSupported, .slimNotWired, .inProgress, .poolDisabled, .poolCreateInFlight:
            ProtocolError(.invalidState, failure.description)
        case .createFailed: ProtocolError(.internalError, failure.description)
        case .alreadyExists: ProtocolError(.invalidState, failure.description)
        case .notFound: ProtocolError(.notFound, failure.description)
        case .slimFailed: ProtocolError(.internalError, failure.description)
        }
    }

    /// Three steps: record the intent (locked), create and slim (unlocked: simctl and
    /// simslim can take minutes), register (locked).
    func templateBuild(_ params: TemplateBuildParams) throws -> ResultPayload {
        guard let builder = engine.environment.sims as? TemplateBuilding else { throw TemplateError.notSupported }
        guard params.slim != true || builder.slimSupported else { throw TemplateError.slimNotWired }
        try locked { try engine.checkPoolAllowsTemplateBuild() }
        let target: (profile: String, arguments: [String], deviceType: String, runtime: String)
        do {
            target = try config.templateTarget(
                project: params.project, profile: params.profile, deviceType: params.deviceType,
                runtime: params.runtime, hostDefault: { try builder.defaultTemplateTarget() })
        } catch let failure as DaemonConfig.TemplateResolveError {
            throw ProtocolError(.invalidArgument, failure.description)
        } catch {
            throw ProtocolError(.internalError, "couldn't pick a default device type and runtime: \(error)")
        }
        guard let versions = refreshTemplateVersions() else {
            throw ProtocolError(.internalError, "couldn't read the Xcode and runtime versions")
        }
        let request = TemplateBuildRequest(
            project: params.project, profile: target.profile, slimArguments: target.arguments,
            deviceType: target.deviceType, runtime: target.runtime, replace: params.replace ?? false,
            slim: params.slim ?? false)
        let pending = try locked { try engine.beginTemplateBuild(request, versions: versions) }
        let outcome = Engine.performTemplateBuild(pending, builder: builder)
        return try locked {
            let record = try engine.finishTemplateBuild(pending, outcome: outcome)
            return .template(
                TemplateResult(outcome: "built", templates: try templateInfos().filter { $0.udid == record.udid }))
        }
    }

    /// `simq gc`: a dry run unless `apply`. Applying is refused while cleanup_mode is
    /// report-only (the same gate the watchdog's retention goes through).
    func garbageCollect(_ params: GCParams) throws -> GCResult {
        if params.background == true {
            return try locked {
                guard !shutdownRequested, !engine.maintenanceDraining else {
                    throw ProtocolError(.invalidState, "Finish maintenance before reviewing or cleaning storage.")
                }
                if params.apply == true, config.reliability.cleanupMode != .enforce {
                    throw ProtocolError(.invalidState, "Cleanup is disabled by cleanup_mode; review only.")
                }
                guard !artifactCleanupRunning else {
                    throw ProtocolError(.invalidState, "Storage review or cleanup is already running.")
                }
                let now = engine.environment.clock.now()
                guard now - lastStorageReviewRequestedAt >= 10 else {
                    throw ProtocolError(.invalidState, "Wait ten seconds between storage requests.")
                }
                lastStorageReviewRequestedAt = now
                artifactCleanupRunning = true
                artifactRequests.enter()
                artifactQueue.async { [self] in
                    defer { locked { artifactCleanupRunning = false }; artifactRequests.leave() }
                    do {
                        _ = try collectArtifacts(apply: params.apply == true, automatic: false, accounting: true)
                    } catch {
                        locked {
                            artifactStorage = ArtifactStorageInfo(
                                sampledAt: engine.environment.clock.now(), categories: [],
                                candidates: [], candidateCount: 0, reclaimableBytes: 0, unknownCandidateSizes: 0,
                                retention: config.reliability.ageRules.artifactRetention,
                                cleanupMode: config.reliability.cleanupMode.rawValue, error: String(describing: error))
                        }
                    }
                }
                return GCResult(applied: false, candidates: [], scheduled: true)
            }
        }
        // Manual GC and the automatic worker share one serial lane: no duplicate
        // removals or concurrent whole-tree walks, and neither holds the tick lock.
        try locked {
            guard !shutdownRequested else { throw ProtocolError(.invalidState, "daemon is stopping") }
            hostWorkInFlight += 1
            artifactRequests.enter()
        }
        defer {
            locked { hostWorkInFlight -= 1 }
            artifactRequests.leave()
        }
        return try artifactQueue.sync {
            try collectArtifacts(apply: params.apply ?? false, automatic: false)
        }
    }

    private func collectArtifacts(apply: Bool, automatic: Bool, accounting: Bool = false) throws -> GCResult {
        if apply, config.reliability.cleanupMode != .enforce, !automatic {
            throw ProtocolError(
                .invalidState,
                "cleanup_mode is \(config.reliability.cleanupMode.rawValue): nothing removed (run without --apply to list)"
            )
        }
        let disk = locked { () -> (roots: [String], fileSystem: any FileSystem)? in
            guard !automatic || (!engine.maintenanceDraining && !shutdownRequested) else { return nil }
            return (engine.environment.allArtifactsRoots, engine.environment.fileSystem)
        }
        guard let disk else { return GCResult(applied: apply, candidates: [], budgetBytes: nil) }
        let sized = SizingFileSystem(disk.fileSystem)
        let inventory = try Engine.gcInventory(roots: disk.roots, fileSystem: sized, includeStorageDetails: accounting)
        let plan = try locked { () -> Engine.GCPlan? in
            guard !automatic || (!engine.maintenanceDraining && !shutdownRequested) else { return nil }
            return try engine.gcPlan(
                now: engine.environment.clock.now(), inventory: inventory, includeStorageAccounting: accounting)
        }
        guard let plan else { return GCResult(applied: apply, candidates: [], budgetBytes: nil) }
        let candidates = Engine.gcCandidates(plan, fileSystem: sized)
        if accounting {
            var categories = StorageAccounting.categories(plan.storageEntries, fileSystem: sized)
            let owned = try locked { try store.liveResources(kinds: [.sim, .template]) }
            var notes: [String] = []
            var devices: [SimDevice] = []
            if !owned.isEmpty {
                do { devices = try engine.environment.sims.listDevices() } catch {
                    notes.append("Simulator inventory unavailable; owned device sizes are unknown.")
                }
            }
            categories += StorageAccounting.simulators(resources: owned, devices: devices)
            let reclaimable = StorageAccounting.reclaimable(
                candidates.map { GCEntry(path: $0.path, reason: $0.reason, bytes: $0.bytes) })
            locked {
                artifactStorage = ArtifactStorageInfo(
                    sampledAt: engine.environment.clock.now(), categories: categories,
                    candidates: candidates.prefix(100).map {
                        GCEntry(path: $0.path, reason: $0.reason, bytes: $0.bytes)
                    },
                    candidateCount: candidates.count, reclaimableBytes: reclaimable.bytes,
                    unknownCandidateSizes: reclaimable.unknown,
                    retention: config.reliability.ageRules.artifactRetention,
                    cleanupMode: config.reliability.cleanupMode.rawValue)
                artifactStorage?.notes = notes
            }
        }
        var result = GCResult(
            applied: apply, candidates: candidates.map { GCEntry(path: $0.path, reason: $0.reason, bytes: $0.bytes) },
            budgetBytes: plan.budget)
        defer {
            if apply {
                locked {
                    artifactStorage?.cleanupAt = engine.environment.clock.now()
                    artifactStorage?.removedCount = result.removed.count
                    artifactStorage?.failureCount = result.failures.count
                    if !accounting, !result.removed.isEmpty, artifactStorage != nil {
                        artifactStorage?.error =
                            "Automatic cleanup ran since this inventory. Review storage to refresh sizes."
                    }
                }
            }
        }
        guard apply else { return result }
        let limit =
            automatic || accounting
            ? min(20, max(0, config.reliability.ageRules.artifactRetention.maxRemovalsPerPass)) : Int.max
        let fileSystem = disk.fileSystem
        var attempted = 0
        for candidate in candidates.prefix(limit) {
            let path = candidate.path
            let intent: ActionIntent? = try locked {
                if automatic {
                    guard !engine.maintenanceDraining && !shutdownRequested else { return nil }
                    let phase = try store.watchdogState().breaker.phase
                    guard config.reliability.cleanupMode == .enforce, phase != .open,
                        phase != .halfOpen || attempted == 0
                    else { return nil }
                }
                return try engine.beginArtifactRemoval(
                    path: path, reason: candidate.reason, now: engine.environment.clock.now())
            }
            guard let intent else { continue }
            attempted += 1
            var failure: String?
            do {
                try fileSystem.removeItem(path)
                if fileSystem.fileExists(path) { throw EngineError.cleanupNotVerified(path) }
            } catch { failure = "\(error)" }
            try locked {
                try engine.finishArtifactRemoval(intent, failure: failure, now: engine.environment.clock.now())
            }
            if let failure { result.failures.append("\(path): \(failure)") } else { result.removed.append(path) }
        }
        let finishDays = locked { !automatic || (!engine.maintenanceDraining && !shutdownRequested) }
        if !result.removed.isEmpty && finishDays {
            let days = try Engine.removeEmptyArtifactDays(roots: disk.roots, fileSystem: fileSystem)
            try locked {
                for day in days {
                    try store.audit(
                        Engine.artifactRemovedAuditType, detail: "removed empty \(day)",
                        now: engine.environment.clock.now())
                }
            }
        }
        return result
    }

    func templateRemove(_ params: TemplateRemoveParams) throws -> TemplateResult {
        let before = try templateInfos().filter { $0.name == params.template || $0.udid == params.template }
        let outcome = try engine.removeTemplate(params.template)
        return TemplateResult(outcome: outcome.rawValue, templates: before)
    }

    /// Holders waiting on `lease_acquire` that polled recently (pool demand).
    func pendingLeaseDemand() -> Int {
        let now = engine.environment.clock.now()
        pendingLeases = pendingLeases.filter { now - $0.value < Self.leasePollExpirySeconds }
        return pendingLeases.count
    }

    static func leaseID(holder: String) -> String { "lease:\(holder)" }

    func leaseAcquire(_ params: LeaseAcquireParams) throws -> LeaseResult {
        guard config.pool != nil else { throw ProtocolError(.invalidState, "the sim pool is off (no pool config)") }
        guard !params.holder.isEmpty else { throw ProtocolError(.invalidArgument, "holder is required") }
        let leaseID = Self.leaseID(holder: params.holder)
        let sims = try store.poolSims()
        if let held = sims.first(where: { $0.leaseID == leaseID }) {
            pendingLeases[params.holder] = nil
            try engine.renewManualLease(udid: held.udid, leaseID: leaseID)
            return LeaseResult(state: "granted", holder: params.holder, udid: held.udid, name: held.name)
        }
        guard !engine.maintenanceDraining else { throw ProtocolError(.invalidState, "daemon is draining") }
        let granted: PoolSim?
        do {
            granted = try engine.acquireManualLease(leaseID: leaseID, pid: params.pid)
        } catch let failure as PoolError {
            throw ProtocolError(.invalidArgument, failure.description)
        }
        if let sim = granted {
            pendingLeases[params.holder] = nil
            return LeaseResult(state: "granted", holder: params.holder, udid: sim.udid, name: sim.name)
        }
        pendingLeases[params.holder] = engine.environment.clock.now()
        let poolState =
            sims.contains { $0.phase == .settling }
            ? "settling" : sims.contains { $0.phase == .booting } ? "booting" : "waiting"
        return LeaseResult(state: "pending", holder: params.holder, poolState: poolState)
    }

    func leaseRenew(_ params: LeaseReleaseParams) throws -> LeaseResult {
        guard config.pool != nil else { throw ProtocolError(.invalidState, "the sim pool is off (no pool config)") }
        do {
            let sim = try engine.renewManualLease(udid: params.udid, leaseID: Self.leaseID(holder: params.holder))
            return LeaseResult(state: "granted", holder: params.holder, udid: sim.udid, name: sim.name)
        } catch let failure as PoolError {
            throw ProtocolError(.invalidState, "\(failure.description) to \(params.holder) (reclaimed or released)")
        }
    }

    func leaseRelease(_ params: LeaseReleaseParams) throws -> LeaseResult {
        guard let pool = config.pool else { throw ProtocolError(.invalidState, "the sim pool is off (no pool config)") }
        guard let sim = try store.poolSims().first(where: { $0.udid == params.udid }) else {
            throw ProtocolError(.notFound, "no pool sim \(params.udid)")
        }
        guard sim.leaseID == Self.leaseID(holder: params.holder) else {
            throw ProtocolError(.invalidState, "pool sim \(params.udid) isn't leased to \(params.holder)")
        }
        _ = try engine.releasePoolSim(udid: params.udid, config: pool)
        return LeaseResult(state: "released", holder: params.holder, udid: sim.udid, name: sim.name)
    }

    /// Current view of a job (nil if unknown). Used for `wait` polling.
    public func jobInfo(_ id: String) throws -> JobInfo? {
        try locked { try info(for: id) }
    }

    private func error(_ request: Request, _ failure: ProtocolError) -> Response {
        Response(id: request.id, body: .error(failure))
    }

    static func map(_ failure: JobStoreError) -> ProtocolError {
        switch failure {
        case .queueFull, .queueFullTotal: return ProtocolError(.queueFull, failure.description)
        case .jobNotFound: return ProtocolError(.notFound, failure.description)
        case .invalidPriority, .invalidTimeout, .invalidKind, .invalidRetries, .invalidCommand:
            return ProtocolError(.invalidArgument, failure.description)
        case .invalidTransition: return ProtocolError(.invalidState, failure.description)
        default: return ProtocolError(.internalError, failure.description)
        }
    }

    /// The run directory listing is added outside the lock (`ArtifactListing.attach`), for
    /// `explain` and `wait` only: a job list stays cheap.
    private func info(for id: String) throws -> JobInfo? {
        guard let job = try store.job(id: id) else { return nil }
        var info = JobInfo(job: job, explanation: job.state == .queued ? try store.explanation(jobID: id) : nil)
        let groups = try store.liveResources(kinds: [.processGroup]).filter { $0.owner.jobID == id }
        info.cleanupPending = groups.contains { $0.state == .active } ? true : nil
        info.cleanupBlocked = groups.contains { $0.state == .orphaned } ? true : nil
        if info.cleanupBlocked == true {
            info.message =
                (info.message.map { $0 + "; " } ?? "")
                + "owned processes could not be verified as stopped; capacity remains held. Inspect simq doctor before recovery."
            if job.state.isTerminal { info.exitCodeValue = SimQExitCode.infraFailure.rawValue }
        }
        if job.command != nil {
            info.logPath = artifacts.logPath(for: job)
            if job.command?.wantsSimPrep == true {
                let outcomes = try store.auditEntries(jobID: job.id, type: Engine.simPrepAuditType).compactMap {
                    $0.detail.flatMap { try? JSONDecoder().decode(SimPrepOutcome.self, from: Data($0.utf8)) }
                }
                info.simPrep = outcomes.isEmpty ? nil : outcomes
            }
            if job.startedAt != nil {
                let runDir = artifacts.directory(for: job)
                info.runDir = runDir
                info.attachRunInfo(try store.jobRunInfo(jobID: id))
            }
        }
        return info
    }

    private func requireJob(_ id: String) throws -> JobInfo {
        guard let info = try info(for: id) else {
            throw ProtocolError(.notFound, "no job \(id)")
        }
        return info
    }

    /// Resolves priority and timeouts, applies config defaults, and queues the job.
    func submissionFor(_ params: SubmitParams) throws -> JobSubmission {
        let priority: Int
        if let name = params.priorityName {
            guard let resolved = config.priorityAliases.resolve(name) else {
                let known = config.priorityAliases.values.keys.sorted()
                throw ProtocolError(
                    .invalidArgument,
                    "unknown priority \"\(name)\"; use 0...100"
                        + (known.isEmpty ? " (no aliases configured)" : " or one of: \(known.joined(separator: ", "))"))
            }
            priority = resolved
        } else {
            priority = params.priority ?? Priority.defaultValue
        }
        guard Priority.isValid(priority) else {
            throw ProtocolError(.invalidArgument, "priority \(priority) is outside 0...100")
        }
        for (name, value) in [("timeout", params.runTimeoutSeconds), ("queue timeout", params.queueTimeoutSeconds)] {
            if let value, value < 0 || !value.isFinite {
                throw ProtocolError(.invalidArgument, "\(name) must be >= 0 seconds (0 = no limit)")
            }
        }
        guard !params.project.isEmpty, !params.submitter.isEmpty else {
            throw ProtocolError(.invalidArgument, "project and submitter are required")
        }
        guard let kind = JobKindLabel.normalized(params.kind ?? "") else {
            throw ProtocolError(.invalidArgument, "kind must be \(JobKindLabel.rule)")
        }
        if let retries = params.maxRetries {
            guard (0...JobStore.maxRetriesLimit).contains(retries) else {
                throw ProtocolError(.invalidArgument, "max_retries must be 0...\(JobStore.maxRetriesLimit)")
            }
        }
        guard params.minSims >= 0, (params.maxSims ?? params.minSims) >= params.minSims else {
            throw ProtocolError(.invalidArgument, "sims must be >= 0 and max_sims >= min_sims")
        }
        var command: JobCommand?
        if let argv = params.command, !argv.isEmpty {
            command = JobCommand(
                argv: argv, environment: params.environment ?? [:], cwd: params.cwd,
                resetApps: params.resetApps.flatMap { $0.isEmpty ? nil : $0 },
                freshSim: params.freshSim == true ? true : nil)
        } else if params.environment?.isEmpty == false || params.cwd != nil {
            throw ProtocolError(.invalidArgument, "environment and cwd need a command")
        }
        if let template = params.template ?? (params.minSims > 0 ? config.defaultHostTemplate : nil) {
            guard config.hostTemplates[template] != nil else {
                throw ProtocolError(.invalidArgument, "unknown host template \(template)")
            }
            guard params.minSims > 0, engine.pool != nil, command != nil else {
                throw ProtocolError(
                    .invalidArgument, "template selection requires a command and simulator pool (min_sims >= 1)")
            }
            command?.template = template
        }
        command?.artifactsRoot = artifacts.root
        if params.freshSim == true || params.resetApps?.isEmpty == false {
            guard command != nil else {
                throw ProtocolError(.invalidArgument, "reset_apps and fresh_sim need a command")
            }
            guard max(params.minSims, params.maxSims ?? 0) > 0 else {
                throw ProtocolError(.invalidArgument, "reset_apps and fresh_sim need a sim (min_sims >= 1)")
            }
            guard engine.pool != nil else {
                throw ProtocolError(.invalidArgument, "reset_apps and fresh_sim need the sim pool (pool is off)")
            }
        }
        if let reason = command?.validationError {
            throw ProtocolError(.invalidArgument, reason)
        }
        if command == nil, executor?.requiresCommand == true {
            throw ProtocolError(
                .invalidArgument, "this daemon runs commands: pass one after -- (simq submit ... -- <command>)")
        }
        let submission = JobSubmission(
            project: params.project,
            kind: kind,
            priority: priority,
            submitter: params.submitter,
            worktree: params.worktree,
            gitSHA: params.gitSHA,
            dedupeKey: params.dedupeKey,
            resources: ResourceRequest(
                minSims: params.minSims, maxSims: params.maxSims, memoryBytes: params.memoryBytes,
                memoryBytesPerSim: params.memoryBytesPerSim),
            exclusive: params.exclusive ?? false,
            // Asking for a retry count implies the job is retryable.
            retryable: params.retryable ?? ((params.maxRetries ?? 0) > 0),
            maxRetries: params.maxRetries,
            runTimeoutSeconds: params.runTimeoutSeconds,
            queueTimeoutSeconds: params.queueTimeoutSeconds,
            payloadJSON: params.payloadJSON,
            command: command
        )
        return config.timeouts.apply(to: submission)
    }

    /// A submit's `git_sha` must be what's checked out in its `worktree` (or, with no
    /// worktree, the command's `cwd`). Returns the params with the full sha, so the job
    /// records the exact commit and the executor can re-check it at start.
    func verifiedGitSHA(_ params: SubmitParams) throws -> SubmitParams {
        guard let sha = params.gitSHA else { return params }
        guard GitCheckout.isPlausibleSHA(sha) else {
            throw ProtocolError(.invalidArgument, "git_sha must be 4...64 hex digits, got \"\(sha.prefix(80))\"")
        }
        guard let tree = params.worktree ?? params.cwd else {
            throw ProtocolError(
                .invalidArgument, "git_sha needs a worktree (or a command cwd) to check it against")
        }
        var checked = params
        do {
            checked.gitSHA = try gitCheckout.verify(sha: sha, in: tree)
        } catch let failure as GitCheckout.Failure {
            throw ProtocolError(.invalidArgument, failure.description)
        }
        return checked
    }

    private func submit(_ params: SubmitParams) throws -> SubmitResponse {
        let submission = try submissionFor(params)
        let now = engine.environment.clock.now()
        let result = try store.submit(submission, now: now)
        let deduplicated: Bool
        if case .deduplicated = result { deduplicated = true } else { deduplicated = false }
        // A deduplicated submit with --keep pins the job it returned. The pin is its own
        // write after the submit: a crash between the two leaves the job unpinned (it then
        // just follows normal retention); resubmitting with the same dedupe key pins it.
        if params.keep == true,
            try store.auditEntries(jobID: result.job.id, type: Engine.artifactKeepAuditType).isEmpty
        {
            try store.audit(
                Engine.artifactKeepAuditType, jobID: result.job.id,
                detail: deduplicated ? "--keep (deduplicated submit)" : "--keep", now: now)
        }
        return SubmitResponse(job: try requireJob(result.job.id), deduplicated: deduplicated)
    }

    private func logs(_ params: LogsParams) throws -> LogsResult {
        guard let job = try store.job(id: params.jobID) else {
            throw ProtocolError(.notFound, "no job \(params.jobID)")
        }
        guard params.offset >= 0 else {
            throw ProtocolError(.invalidArgument, "offset must be >= 0")
        }
        if let tailBytes = params.tailBytes, tailBytes <= 0 {
            throw ProtocolError(.invalidArgument, "tail_bytes must be positive")
        }
        var offset = params.tailBytes == nil ? params.offset : 0
        let limit = min(max(1, params.maxBytes ?? LogsParams.defaultMaxBytes), LogsParams.maxBytesLimit)
        let path = artifacts.logPath(for: job)
        let preparing = (executor as? ProcessExecutor)?.preparingJobIDs.contains(job.id) ?? false
        if preparing {
            // A log reader must not reopen the same stalled output root while its
            // writer prepares it. Preserve the cursor until a complete chunk exists.
            return LogsResult(
                jobID: job.id, path: path, offset: params.offset, nextOffset: params.offset,
                data: "", jobFinished: false, atEnd: true,
                tailBytes: params.tailBytes.map { min($0, limit) })
        }
        let groups = try store.liveResources(kinds: [.processGroup]).filter { $0.owner.jobID == job.id }
        let cleanupPending = groups.contains { $0.state == .active }
        let cleanupBlocked = groups.contains { $0.state == .orphaned }
        let finished =
            job.state.isTerminal && !preparing && (cleanupBlocked || (!executorBusy(job.id) && !cleanupPending))
        var bytes = Data()
        var size: Int64 = 0
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            size = Int64(try handle.seekToEnd())
            if let tailBytes = params.tailBytes {
                offset = max(0, size - Int64(min(tailBytes, limit)))
            }
            if offset < size {
                try handle.seek(toOffset: UInt64(offset))
                bytes = try handle.read(upToCount: limit) ?? Data()
                size = Int64(try handle.seekToEnd())
            }
        }
        if params.tailBytes != nil, offset > 0 {
            // A tail window can start inside a UTF-8 scalar. Skip its remaining bytes.
            var leading = 0
            while leading < min(3, bytes.count), bytes[bytes.startIndex + leading] & 0xC0 == 0x80 {
                leading += 1
            }
            bytes.removeFirst(leading)
            offset += Int64(leading)
        }
        // Don't split a multi-byte character: back off over trailing continuation bytes
        // when the chunk ends inside one (unless that would return nothing).
        var cut = bytes.count
        if Int64(bytes.count) + offset < size || bytes.count == limit {
            var lead = cut
            while lead > 0, lead > cut - 4, bytes[bytes.startIndex + lead - 1] & 0xC0 == 0x80 { lead -= 1 }
            if lead > 0 {
                let first = bytes[bytes.startIndex + lead - 1]
                let expected = first >= 0xF0 ? 4 : first >= 0xE0 ? 3 : first >= 0xC0 ? 2 : 1
                if expected > 1, cut - (lead - 1) < expected { cut = lead - 1 }
            }
            if cut == 0 { cut = bytes.count }
        }
        let chunk = bytes.prefix(cut)
        let next = offset + Int64(chunk.count)
        return LogsResult(
            jobID: job.id, path: path, offset: offset, nextOffset: max(next, offset),
            data: String(decoding: chunk, as: UTF8.self),
            jobFinished: finished,
            atEnd: next >= size, tailBytes: params.tailBytes.map { min($0, limit) })
    }

    /// True while the executor still owns the job's command (it can still write output).
    private func executorBusy(_ jobID: String) -> Bool {
        guard let real = executor as? ProcessExecutor else { return false }
        return real.runningJobIDs.contains(jobID) || real.preparingJobIDs.contains(jobID)
    }

    /// Registers the artifact writer before releasing the state lock. A canceled
    /// job's directory remains protected until its blocked preparation actually exits.
    private func startProcessPreparations() {
        guard let real = executor as? ProcessExecutor else { return }
        engine.artifactWritersInFlight = real.preparingJobIDs
        for work in real.takePreparationWork() {
            startPreparationQueue.async { [self] in
                let result = ProcessExecutor.performPreparation(work)
                locked {
                    guard let current = executor as? ProcessExecutor else { return }
                    current.finishPreparation(work, result: result)
                    engine.artifactWritersInFlight = current.preparingJobIDs
                }
                wakeScheduler()
            }
        }
    }

    // MARK: - Alerts

    /// Hands newly admitted jobs' sim preparation to `simPrepQueue` (called under the lock).
    /// The executor holds those jobs until `finishSimPrep` records the outcome.
    /// Not gated by `pool.mode` (or `cleanup_mode`), on purpose: prep acts for the job, on a
    /// sim the job itself holds, at its request (`--reset-app`/`--fresh-sim`), so it isn't a
    /// host-cleanup action. A dry run still refuses it at the backend decorator.
    private func startSimPrep() {
        let work: [SimPrepWork]
        do {
            work = try engine.takeSimPrepWork()
        } catch {
            log("sim prep: couldn't read pending work: \(error)")
            return
        }
        let sims = engine.environment.sims
        let naming = engine.environment.naming
        for item in work {
            simPrepQueue.async { [self] in
                let outcomes = Engine.performSimPrep(item, sims: sims, naming: naming)
                locked {
                    do {
                        try engine.finishSimPrep(item, outcomes: outcomes)
                    } catch {
                        log("sim prep for \(item.jobID) not recorded: \(error)")
                    }
                    executor?.heldJobIDs = engine.jobsAwaitingSimPrep
                }
            }
        }
    }

    /// Current health. Stale when no pass ran for three light intervals.
    func health(now: Double) throws -> HealthInfo {
        let state = try store.watchdogState()
        let anomalies = try store.anomalies()
        let summary = HealthSummary.evaluate(
            breaker: state.breaker, anomalies: anomalies, draining: try engine.drainActive(now: now),
            lastPassAt: state.lastPassAt, now: now, staleAfterSeconds: 3 * config.watchdog.lightIntervalSeconds,
            postponed: state.postponedTargets.count, lastPassError: state.lastPassError)
        return HealthInfo(
            summary: summary, state: state, anomalies: anomalies, cleanupMode: config.reliability.cleanupMode.rawValue,
            now: now,
            alerts: try store.alerts().filter { now - $0.lastSeenAt < 7 * 86_400 }.prefix(20).map(AlertInfo.init),
            alertDelivery: "local")
    }

    /// Atomically rewrites `health.json` (0600).
    func writeHealth(now: Double) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(try health(now: now))
        try data.write(to: URL(fileURLWithPath: healthPath), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: healthPath)
    }

    private func storageDiagnostics() -> StorageInfo {
        let failure: String?
        do { try JobStorage.check(artifacts.root); failure = nil } catch { failure = String(describing: error) }
        return StorageInfo(
            stateDirectory: (info.statePath as NSString).deletingLastPathComponent,
            jobOutputRoot: artifacts.root, available: failure == nil,
            freeBytes: failure == nil ? JobStorage.freeBytes(artifacts.root) : nil, failure: failure,
            systemFreeBytes: storageChecksEnabled ? JobStorage.freeBytes("/") : nil,
            minimumFreeBytes: config.scheduler.minFreeDiskBytes)
    }

    private func storageCheck() -> DoctorCheck {
        let value = storageDiagnostics()
        return DoctorCheck(
            name: "job_storage", level: value.available ? .ok : .fail,
            detail: "state: \(value.stateDirectory); job output: \(value.jobOutputRoot); "
                + (value.failure ?? "available, writable; free bytes: \(value.freeBytes.map(String.init) ?? "unknown")")
        )
    }

    private func status() throws -> StatusResult {
        let control = try store.queueControl()
        let active = try store.activeJobs()
        var drainComplete = false
        if engine.maintenanceDraining && active.isEmpty && !historyRunning && !artifactCleanupRunning
            && !poolPassRunning && hostWorkInFlight == 0
            && !engine.hasTemplateBuildsInFlight && engine.artifactWritersInFlight.isEmpty
        {
            let groups = try store.liveResources(kinds: [.processGroup])
            let sims = try store.poolSims()
            let intents = try store.pendingActionIntents()
            drainComplete = groups.isEmpty && intents.isEmpty && !sims.contains { $0.phase == .leased }
        }
        if drainComplete, info.statePath != ":memory:" {
            try JobOutputConfiguration.markDrained(
                true, stateDirectory: (info.statePath as NSString).deletingLastPathComponent)
        }
        return StatusResult(
            daemon: info,
            queued: try store.queuedJobs().count,
            admitted: active.filter { $0.state == .admitted }.count,
            running: active.filter { $0.state == .running }.count,
            paused: control.paused || engine.maintenanceDraining,
            draining: engine.maintenanceDraining
                || { if case .draining = lastTick?.drain { return true } else { return false } }(),
            loadThrottled: engine.loadThrottled,
            globalWaitReasons: (lastTick?.globalReasons ?? []).map(WaitReasonInfo.init),
            lastTickAt: lastTickAt,
            health: try health(now: engine.environment.clock.now()),
            templateHint: !config.hostTemplates.isEmpty
                ? "named host templates: " + config.hostTemplates.keys.sorted().joined(separator: ", ")
                    + "; default: " + (config.defaultHostTemplate ?? config.simctl?.template ?? "none")
                : engine.environment.sims.templateCloneSource.flatMap {
                    $0.cloneTemplate.map {
                        "host-wide active template: " + $0
                            + "; warm reuse retains previous job state (use --reset-app or --fresh-sim)"
                    } ?? "no active host template; build one, set simctl.template to its UDID, then restart simqd"
                },
            drainComplete: drainComplete,
            storage: storageDiagnostics(), host: lastTick?.host, artifactStorage: artifactStorage,
            storageReviewRunning: artifactCleanupRunning
        )
    }

    private func jobs(_ params: JobsParams) throws -> [JobInfo] {
        try store.jobs(states: params.states, project: params.project, limit: params.limit ?? 100).compactMap {
            try info(for: $0.id)
        }
    }

    private func bump(_ params: BumpParams) throws -> JobInfo {
        guard let job = try store.job(id: params.jobID) else {
            throw ProtocolError(.notFound, "no job \(params.jobID)")
        }
        guard job.state == .queued else {
            throw ProtocolError(
                .invalidState, "\(job.id) is \(job.state.rawValue); only queued jobs can change priority")
        }
        guard try store.bump(jobID: job.id, to: params.priority, now: engine.environment.clock.now()) else {
            throw ProtocolError(.invalidState, "\(job.id) is no longer queued")
        }
        return try requireJob(job.id)
    }

    /// Cancels a job. An active job's process groups get SIGTERM and its resources go
    /// through normal teardown; anything still alive is left orphaned for reconcile.
    private func cancel(_ params: CancelParams) throws -> JobInfo {
        guard let job = try store.job(id: params.jobID) else {
            throw ProtocolError(.notFound, "no job \(params.jobID)")
        }
        guard !job.state.isTerminal else {
            throw ProtocolError(.invalidState, "\(job.id) already ended (\(job.state.rawValue))")
        }
        let now = engine.environment.clock.now()
        _ = try store.cancel(jobID: job.id, now: now)
        if job.state.isActive {
            let live = try engine.environment.processes.liveProcessGroups()
            for resource in try store.resources(jobID: job.id)
            where resource.kind == .processGroup && resource.state == .active {
                // Never a pgid now led by a different process (#38).
                if let pgid = Int32(resource.externalID), live.contains(pgid),
                    try engine.environment.processes.verifyGroup(pgid, identity: resource.identity, live: live)
                        == .verified
                {
                    try? engine.environment.processes.signalGroup(pgid, .term)
                }
            }
            // A process executor reaps the leader and escalates to SIGKILL on its own
            // schedule; everything else is torn down now.
            try engine.teardown(job, now: now, skipping: executor?.drainsProcessGroups == true ? [.processGroup] : [])
        }
        return try requireJob(job.id)
    }
}
