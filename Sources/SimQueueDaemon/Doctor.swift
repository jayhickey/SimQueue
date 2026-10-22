// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueEngine
import SimQueueProtocol
import SimQueueSim
import SimQueueStore

/// Builds `simq doctor` reports. Strictly read-only: it never writes to the database,
/// the socket or anything on the host. Used by the daemon (online) and by the CLI when
/// the daemon is down (offline, straight from the state file).
public enum DoctorBuilder {
    /// Heartbeats older than this, with no daemon answering, mean a dead daemon.
    public static let staleHeartbeatSeconds: Double = 30

    /// What only a running daemon can check (the host and the world it observes).
    public struct LiveContext {
        public var engine: Engine
        public var watchdog: WatchdogConfig
        public var health: HealthInfo?
        /// The host's tool versions from the daemon's cache (never probed here).
        public var templateVersions: TemplateToolVersions?

        public init(
            engine: Engine, watchdog: WatchdogConfig, health: HealthInfo?, templateVersions: TemplateToolVersions? = nil
        ) {
            self.engine = engine
            self.watchdog = watchdog
            self.health = health
            self.templateVersions = templateVersions
        }
    }

    public static func build(
        store: JobStore, now: Double, daemon: DaemonInfo?, socketPath: String?, live: LiveContext? = nil
    ) throws -> DoctorReport {
        var checks: [DoctorCheck] = []
        let liveness = try store.livenessReport(now: now)
        let anomalies = try store.anomalies()

        if let daemon {
            checks.append(
                DoctorCheck(
                    name: "daemon", level: .ok,
                    detail:
                        "simqd \(daemon.version) pid \(daemon.pid) epoch \(daemon.epoch), cleanup \(daemon.cleanupMode)"
                ))
            checks.append(
                DoctorCheck(
                    name: "backend", level: .ok,
                    detail: "sims \(daemon.backend)\(daemon.backend == "fake" ? "" : " (real simulators)"), "
                        + "probe \(daemon.probe ?? "fake")\(daemon.dryRun == true ? ", dry run (host actions logged, not run)" : "")"
                ))
            if let live, let source = live.engine.environment.sims.templateCloneSource {
                if !live.engine.hostTemplates.isEmpty {
                    checks.append(
                        DoctorCheck(
                            name: "template", level: .ok,
                            detail: "named host templates: "
                                + live.engine.hostTemplates.keys.sorted().map {
                                    $0 + "=" + live.engine.hostTemplates[$0, default: "?"]
                                }.joined(separator: ", ")))
                } else if source.cloneTemplate == nil {
                    checks.append(DoctorCheck(name: "template", level: .warn, detail: noTemplateMessage))
                } else if let configured = source.configuredTemplate {
                    checks.append(
                        DoctorCheck(name: "template", level: .ok, detail: "clones copy \(configured) (simctl.template)")
                    )
                } else {
                    let entry = try? live.engine.newestReadyTemplate(versions: live.templateVersions)
                    let name = entry?.record.name ?? source.defaultTemplate?.name ?? "?"
                    checks.append(
                        entry?.stale == true
                            ? DoctorCheck(
                                name: "template", level: .warn,
                                detail: "clones copy \(name), but every ready template is stale (Xcode or runtime "
                                    + "changed); run simq template build --replace")
                            : DoctorCheck(
                                name: "template", level: .ok, detail: "clones copy \(name) (newest ready template)"))
                }
            }
        } else if let age = liveness.heartbeatAgeSeconds, age < staleHeartbeatSeconds {
            checks.append(
                DoctorCheck(name: "daemon", level: .warn, detail: "socket not answering; heartbeat \(Int(age))s ago"))
        } else {
            checks.append(
                DoctorCheck(name: "daemon", level: .warn, detail: "not running (report built from the state file)"))
        }

        if let socketPath, let mode = socketPermissions(socketPath) {
            let ok = mode & 0o077 == 0
            checks.append(
                DoctorCheck(
                    name: "socket", level: ok ? .ok : .fail,
                    detail: String(format: "%@ mode %03o", socketPath, mode)))
        }

        let integrity = try store.database.query("PRAGMA quick_check;").first?.string("quick_check") ?? "unknown"
        checks.append(
            DoctorCheck(name: "database", level: integrity == "ok" ? .ok : .fail, detail: "quick_check: \(integrity)"))

        checks.append(
            DoctorCheck(
                name: "orphaned_resources", level: liveness.orphanedResources == 0 ? .ok : .warn,
                detail: "\(liveness.orphanedResources) awaiting cleanup, \(liveness.activeResources) active"))
        let uncertain = try store.unresolvedSpawnIntents()
        if !uncertain.isEmpty {
            checks.append(
                DoctorCheck(
                    name: "uncertain_command_start", level: .fail,
                    detail:
                        "\(uncertain.compactMap { $0.owner.jobID }.joined(separator: ", ")): command start could not be verified; capacity and simulator leases remain held. Inspect owned processes and side effects before any manual recovery; do not resubmit or delete state blindly."
                ))
        }
        checks.append(
            DoctorCheck(
                name: "overdue_jobs", level: liveness.overdueJobs.isEmpty ? .ok : .warn,
                detail: liveness.overdueJobs.isEmpty ? "none" : liveness.overdueJobs.joined(separator: ", ")))

        let worst = anomalies.map(\.level).max()
        let anomalyLevel: DoctorCheck.Level =
            switch worst {
            case .needsHuman: .fail
            case .sustained: .warn
            default: .ok
            }
        checks.append(
            DoctorCheck(
                name: "anomalies", level: anomalyLevel,
                detail: anomalies.isEmpty
                    ? "none" : anomalies.map { "\($0.key)=\($0.level.rawValue)" }.joined(separator: ", ")))

        let pool = try poolSection(store, now: now)
        // A pool that takes no host action (pool.mode report-only, or follow-cleanup under
        // report-only cleanup_mode) creates, boots and shuts down nothing, so pool jobs wait.
        // Said even with no pool sims yet (that is exactly what it leaves).
        let poolConfig = live?.engine.pool
        let poolReportOnly =
            live.map { live in
                poolConfig.map { !$0.actsOnHost(cleanupMode: live.engine.reliability.cleanupMode) } ?? false
            } ?? false
        if pool != nil || poolReportOnly {
            let sims = pool?.sims.count ?? 0
            let settling = pool?.settling.count ?? 0
            let unleased = pool?.unleasedUsers.count ?? 0
            let capHits = pool?.settleCapHitsLastHour ?? 0
            let level: DoctorCheck.Level = poolReportOnly || capHits > 0 || unleased > 0 ? .warn : .ok
            let why =
                poolConfig?.mode == .reportOnly
                ? "pool.mode is report-only" : "pool.mode is follow-cleanup and cleanup_mode is report-only"
            checks.append(
                DoctorCheck(
                    name: "pool", level: level,
                    detail: (poolReportOnly
                        ? "\(why): the pool creates and boots no sims and shuts down only ones released with "
                            + "simq lease release, so jobs that need a pool sim wait (set pool.mode to active to "
                            + "run the pool while cleanup stays report-only); " : "")
                        + (poolConfig.map { "mode \($0.mode.rawValue), " } ?? "")
                        + "\(sims) sims, \(settling) settling, \(unleased) unleased users, "
                        + "\(capHits) settle cap hits in the last hour"))
        }

        checks += try liveChecks(live, now: now)
        checks += try watchdogChecks(
            store.watchdogState(), now: now, staleAfter: 3 * (live?.watchdog ?? WatchdogConfig()).lightIntervalSeconds)

        return DoctorReport(
            daemon: daemon,
            ownedUDIDs: try store.ownedSimUDIDs(),
            activeResources: liveness.activeResources,
            orphanedResources: liveness.orphanedResources,
            heartbeatAgeSeconds: liveness.heartbeatAgeSeconds,
            overdueJobs: liveness.overdueJobs,
            anomalies: anomalies.map(AnomalyInfo.init),
            checks: checks,
            health: live?.health,
            pool: pool
        )
    }

    static func poolSection(_ store: JobStore, now: Double) throws -> DoctorPool? {
        let sims = try store.poolSims().sorted { $0.name < $1.name }
        let recent = try store.database.query(
            "SELECT at, detail FROM audit_log WHERE type = 'settle_cap_hit' ORDER BY seq DESC LIMIT 5;"
        ).map { row in
            "\(Timestamp(row.double("at") ?? 0).rfc3339) \(row.string("detail") ?? "")"
        }
        guard !sims.isEmpty || !recent.isEmpty else { return nil }
        return DoctorPool(
            sims: sims.map {
                DoctorPoolSim(
                    udid: $0.udid, name: $0.name, phase: $0.phase.rawValue, phaseSeconds: max(0, now - $0.phaseSince),
                    leaseID: $0.leaseID, tainted: $0.tainted, clonedFrom: $0.clonedFrom)
            },
            settling: sims.filter { $0.phase == .settling }.map(\.udid),
            unleasedUsers: sims.filter(\.tainted).map(\.udid),
            settleCapHitsLastHour: try store.auditCount(type: "settle_cap_hit", since: now - 3600),
            recentSettleCapHits: recent)
    }

    /// Registry vs reality, foreign resources, disk, memory and swap, and the checks that
    /// arrive with template images. Read-only: plans a reconcile without running it.
    static func liveChecks(_ live: LiveContext?, now: Double) throws -> [DoctorCheck] {
        let liveNames = ["registry_vs_reality", "foreign_resources", "disk", "memory_swap"]
        guard let live else {
            return liveNames.map { DoctorCheck(name: $0, level: .warn, detail: "not checked: daemon not running") }
                + pendingChecks()
        }
        var checks: [DoctorCheck] = []
        // One sim listing for the whole check (reconcile plan and templates).
        let world = try live.engine.observeWorld()
        let actions = try live.engine.plannedReconcile(world: world)
        var gone = 0
        var leftovers: [String: Int] = [:]
        var foreign: [String] = []
        for action in actions {
            switch action {
            case .markGone: gone += 1
            case .killProcessGroup: leftovers["process groups", default: 0] += 1
            case .deleteSim: leftovers["sims", default: 0] += 1
            case .removeDirectory: leftovers["dirs", default: 0] += 1
            case .reportForeignSim(let udid, let name): foreign.append("\(name) (\(udid))")
            case .adopt, .revokeLease: break
            }
        }
        let leftoverText = leftovers.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }
        checks.append(
            DoctorCheck(
                name: "registry_vs_reality", level: gone == 0 && leftovers.isEmpty ? .ok : .warn,
                detail: gone == 0 && leftovers.isEmpty
                    ? "registry matches sims, process groups and dirs"
                    : "resource gone for \(gone) registry row\(gone == 1 ? "" : "s"); leftovers awaiting cleanup: "
                        + (leftoverText.isEmpty ? "none" : leftoverText.joined(separator: ", "))))
        checks.append(
            DoctorCheck(
                name: "foreign_resources", level: .ok,
                detail: foreign.isEmpty
                    ? "none"
                    : "\(foreign.count) foreign sims (report-only, never touched): "
                        + foreign.sorted().prefix(5).joined(separator: ", ") + (foreign.count > 5 ? ", ..." : "")))

        // Templates built with an Xcode or runtime that has since changed (only when any exist).
        let templates = try live.engine.templates(versions: live.templateVersions)
        let unregistered = try live.engine.unregisteredTemplateSims(in: world.sims).map { "\($0.name) (\($0.udid))" }
            .sorted()
        if !templates.isEmpty || !unregistered.isEmpty {
            let stale = templates.filter { $0.stale == true }.map(\.record.name).sorted()
            let failed = templates.filter { $0.record.status != "ready" }.map(\.record.name).sorted()
            let unknown = templates.contains { $0.stale == nil }
            var problems: [String] = []
            if !stale.isEmpty {
                problems.append(
                    "stale (Xcode or runtime changed; simq template build --replace): " + stale.joined(separator: ", "))
            }
            if !failed.isEmpty { problems.append("slim failed: " + failed.joined(separator: ", ")) }
            if unknown { problems.append("tool versions unreadable; staleness unknown") }
            if !unregistered.isEmpty {
                problems.append(
                    "unregistered template sims (never reaped; simq template rm <udid> removes one): "
                        + unregistered.joined(separator: ", "))
            }
            checks.append(
                DoctorCheck(
                    name: "templates", level: problems.isEmpty ? .ok : .warn,
                    detail: problems.isEmpty
                        ? "\(templates.count) template(s), current" : problems.joined(separator: "; "))
            )
        }

        let config = live.engine.scheduler.config
        if let host = try? live.engine.environment.probe.sample(now: now) {
            let free = host.freeDiskBytes
            // Same floor the scheduler uses: warn below it, fail below half of it (0: always ok).
            let diskLevel: DoctorCheck.Level =
                free < config.minFreeDiskBytes / 2 ? .fail : free < config.minFreeDiskBytes ? .warn : .ok
            checks.append(
                DoctorCheck(
                    name: "disk", level: diskLevel,
                    detail: "\(gibibytes(free)) free (minimum \(gibibytes(config.minFreeDiskBytes)))"))
            var memoryLevel: DoctorCheck.Level =
                switch host.memoryPressure {
                case .critical: .fail
                case .warn: .warn
                case .normal: .ok
                }
            if host.swapUsedBytes > config.maxSwapUsedBytes, memoryLevel == .ok { memoryLevel = .warn }
            checks.append(
                DoctorCheck(
                    name: "memory_swap", level: memoryLevel,
                    detail:
                        "pressure \(host.memoryPressure.rawValue), \(gibibytes(host.availableMemoryBytes)) available, "
                        + "swap \(gibibytes(host.swapUsedBytes)) (limit \(gibibytes(config.maxSwapUsedBytes)))"))
        } else {
            for name in ["disk", "memory_swap"] {
                checks.append(DoctorCheck(name: name, level: .warn, detail: "host probe failed"))
            }
        }
        return checks + pendingChecks()
    }

    /// Checks whose subject doesn't exist yet (no Xcode pin or template images configured).
    static func pendingChecks() -> [DoctorCheck] {
        [
            DoctorCheck(name: "xcode_pin", level: .ok, detail: "not checked: no Xcode version pinned"),
            DoctorCheck(name: "simslim_verify", level: .ok, detail: "not checked: no template images configured"),
        ]
    }

    /// Breaker state and the age of the last watchdog pass (from the state file, so these
    /// work offline too).
    static func watchdogChecks(_ state: WatchdogState, now: Double, staleAfter: Double) -> [DoctorCheck] {
        let breaker = state.breaker
        let breakerCheck: DoctorCheck
        switch breaker.phase {
        case .closed:
            breakerCheck = DoctorCheck(name: "breaker", level: .ok, detail: "closed")
        case .halfOpen:
            breakerCheck = DoctorCheck(
                name: "breaker", level: .warn, detail: "half-open (one action allowed): \(breaker.reason ?? "unknown")")
        case .open:
            let since = breaker.openedAt.map { " since \(Timestamp($0).rfc3339)" } ?? ""
            breakerCheck = DoctorCheck(
                name: "breaker", level: .fail,
                detail: "open\(since): \(breaker.reason ?? "unknown"); watchdog is report-only")
        }
        let passCheck: DoctorCheck
        if let at = state.lastPassAt {
            let age = now - at
            let what = "\(state.lastPassKind?.rawValue ?? "?") pass \(state.lastPassID ?? "?") \(Int(age))s ago"
            passCheck = DoctorCheck(
                name: "watchdog", level: age > staleAfter ? .warn : .ok,
                detail: what + (state.lastFullPassAt.map { ", last full pass \(Int(now - $0))s ago" } ?? ""))
        } else {
            passCheck = DoctorCheck(name: "watchdog", level: .warn, detail: "no watchdog pass yet")
        }
        return [breakerCheck, passCheck]
    }

    static func gibibytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GiB", Double(bytes) / Double(ByteSize.gibibyte))
    }

    /// Offline report from the state file, opened read-only.
    public static func offline(paths: SimQueuePaths, now: Double) throws -> DoctorReport {
        let store = try JobStore(readOnlyPath: paths.databasePath)
        return try build(store: store, now: now, daemon: nil, socketPath: paths.socketPath)
    }

    static func socketPermissions(_ path: String) -> UInt32? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let mode = attributes[.posixPermissions] as? NSNumber
        else {
            return nil
        }
        return mode.uint32Value & 0o777
    }
}
