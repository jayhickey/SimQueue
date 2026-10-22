// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueStore

/// `config.json` in the state directory. Every field is optional; missing fields keep the
/// defaults below. SimQueue ships no named priorities and no per-project rules.
///
/// ```json
/// {
///   "priority_aliases": { "urgent": 90, "background": 10 },
///   "aging_points_per_minute": 0.5,
///   "aging_max_boost": 25,
///   "default_run_timeout_seconds": 0,
///   "default_queue_timeout_seconds": 86400,
///   "kill_grace_seconds": 10,
///   "cleanup_mode": "report-only",
///   "watchdog_light_interval_seconds": 60,
///   "watchdog_full_interval_seconds": 900,
///   "age_rules": { "orphan_process_seconds": 120, "work_dir_after_job_seconds": 3600,
///                  "lease_max_age_seconds": 2700, "queued_alert_seconds": 21600,
///                  "foreign_booted_sim_report_seconds": 86400,
///                  "artifact_retention_days": { "succeeded": 7, "other": 14, "unknown": 30,
///                                               "derived_data": 1, "kept": 90 },
///                  "artifact_budget_gib": 50 },
///   "host": { "min_free_disk_gib": 20 }
/// }
/// ```
/// For both timeouts, 0 means no limit.
public struct DaemonConfig: Sendable, Equatable {
    /// Optional absolute directory containing dated job output directories.
    public var jobOutputRoot: String?
    /// Host template labels mapped to existing template simulator identifiers.
    public var hostTemplates: [String: String] = [:]
    public var defaultHostTemplate: String?
    public var priorityAliases = PriorityAliases()
    public var scheduler = SchedulerConfig()
    public var reliability = ReliabilityConfig()
    public var timeouts = TimeoutConfig()
    /// Seconds between scheduling passes.
    public var tickIntervalSeconds: Double = 1
    /// Watchdog pass cadence and circuit breaker.
    public var watchdog = WatchdogConfig()
    /// Seconds between light watchdog passes (older name, kept for config files).
    public var reconcileIntervalSeconds: Double {
        get { watchdog.lightIntervalSeconds }
        set { watchdog.lightIntervalSeconds = newValue }
    }
    /// Per submitter and project; 0 disables the cap.
    public var maxQueuedPerSubmitterPerProject = 128
    /// Bounded host backlog; default 1024 queued independent jobs.
    public var maxQueuedTotal = 1024
    /// Infra retries for a `--retryable` job that doesn't pass its own `--retries`.
    public var defaultMaxRetries = 1
    /// The sim pool (`pool` in the config file). Nil (the default): the pool is off.
    public var pool: SimPoolConfig?
    /// `simctl` backend settings (used only with the simctl backend).
    public var simctl: SimctlSettings?
    /// `backend` (`fake` or `simctl`): the sim backend when `simqd` gets no `--backend`.
    /// Nil: simctl on macOS, fake elsewhere and for a dry run (`BackendGate.choose`).
    public var backend: BackendKind?
    /// `projects` (written by `simq project add`): onboarding facts per project. The
    /// scheduler doesn't read them; they're for tooling (`simq template build`, docs, agents).
    public var projects: [String: ProjectSettings] = [:]
    /// `host`: per-core load factors and RAM-derived limits, applied by `applyHostSizing`.
    public var host = HostSizing()

    /// One `projects.<name>` entry.
    public struct ProjectSettings: Sendable, Equatable, Codable {
        /// Absolute path of the project's repository (or worktree).
        public var repo: String
        public var scheme: String
        /// `.xcworkspace` or `.xcodeproj`, relative to `repo`. Nil: xcodebuild's own lookup.
        public var container: String?
        public var testPlan: String?
        /// `template`: the device type and runtime this project's template is built from.
        public var template: TemplateTarget?

        public init(
            repo: String, scheme: String, container: String? = nil, testPlan: String? = nil,
            template: TemplateTarget? = nil
        ) {
            self.repo = repo
            self.scheme = scheme
            self.container = container
            self.testPlan = testPlan
            self.template = template
        }

        enum CodingKeys: String, CodingKey {
            case repo, scheme, container, template
            case testPlan = "test_plan"
        }

        /// `golden`: this entry's name before the rename to template, still read
        /// (`template` wins when both are set). Written as `template`.
        enum LegacyCodingKeys: String, CodingKey {
            case template = "golden"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            self.init(
                repo: try container.decode(String.self, forKey: .repo),
                scheme: try container.decode(String.self, forKey: .scheme),
                container: try container.decodeIfPresent(String.self, forKey: .container),
                testPlan: try container.decodeIfPresent(String.self, forKey: .testPlan),
                template: try container.decodeIfPresent(TemplateTarget.self, forKey: .template)
                    ?? legacy.decodeIfPresent(TemplateTarget.self, forKey: .template))
        }

        /// Taken by other sim-name shapes (`simq-template-...`, legacy `simq-golden-...`,
        /// `simq-pool-...`): these names, and any name starting with one plus `-`, are refused.
        public static let reservedNames: Set<String> = ["template", "golden", "pool"]

        public static func isReserved(_ name: String) -> Bool {
            reservedNames.contains { name == $0 || name.hasPrefix($0 + "-") }
        }

        /// Project names become a sim-name segment (`simq-<project>-...`): lowercase
        /// letters, digits and `-`, starting with a letter, at most 32 characters.
        public static func isValidName(_ name: String) -> Bool {
            guard !isReserved(name) else { return false }
            guard let first = name.first, first.isLowercase, first.isASCII, name.count <= 32 else { return false }
            return name.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
        }

        func validate(name: String) throws {
            guard Self.isValidName(name) else {
                throw LoadError.invalid(
                    "project name \"\(name)\" must be lowercase letters, digits and -, starting with a letter (max 32),"
                        + " and not template, golden, pool or start with one of those plus -")
            }
            guard repo.hasPrefix("/") else { throw LoadError.invalid("projects.\(name).repo must be an absolute path") }
            guard !scheme.isEmpty else { throw LoadError.invalid("projects.\(name).scheme is required") }
            if let container {
                guard container.hasSuffix(".xcworkspace") || container.hasSuffix(".xcodeproj"),
                    !container.hasPrefix("/"), !container.split(separator: "/").contains("..")
                else {
                    throw LoadError.invalid(
                        "projects.\(name).container must be a .xcworkspace or .xcodeproj path inside repo")
                }
            }
        }
    }

    /// A template's device type and runtime (simctl identifiers or names).
    public struct TemplateTarget: Sendable, Equatable, Codable {
        public var deviceType: String?
        public var runtime: String?
        public init(deviceType: String? = nil, runtime: String? = nil) {
            self.deviceType = deviceType
            self.runtime = runtime
        }
        enum CodingKeys: String, CodingKey {
            case runtime
            case deviceType = "device_type"
        }
    }

    /// `template` in the config file: defaults for every project, and the slim profiles.
    public struct TemplateSettings: Sendable, Equatable, Codable {
        public static let defaultProfile = "default"
        public var deviceType: String?
        public var runtime: String?
        /// Profile name → simslim arguments. `default` always exists (no arguments unless set).
        public var profiles: [String: [String]]

        public init(deviceType: String? = nil, runtime: String? = nil, profiles: [String: [String]] = [:]) {
            self.deviceType = deviceType
            self.runtime = runtime
            self.profiles = profiles
            if self.profiles[Self.defaultProfile] == nil { self.profiles[Self.defaultProfile] = [] }
        }

        enum CodingKeys: String, CodingKey {
            case runtime, profiles
            case deviceType = "device_type"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                deviceType: try container.decodeIfPresent(String.self, forKey: .deviceType),
                runtime: try container.decodeIfPresent(String.self, forKey: .runtime),
                profiles: try container.decodeIfPresent([String: [String]].self, forKey: .profiles) ?? [:])
        }
    }

    /// `template` (device type, runtime defaults and slim profiles).
    public var template = TemplateSettings()

    public enum TemplateResolveError: Error, Equatable, CustomStringConvertible {
        case unknownProject(String)
        case unknownProfile(String)
        case missing(String)
        public var description: String {
            switch self {
            case .unknownProject(let name): "no project \(name) in the config (simq project add)"
            case .unknownProfile(let name): "no slim profile \(name) in template.profiles"
            case .missing(let what):
                "no \(what) for the template: pass it, set it in the project's template entry, or in template"
            }
        }
    }

    /// Resolves what to build: flags win for this run, then the project's `template` entry,
    /// then the top-level `template` defaults, then `hostDefault` (the host's newest iOS
    /// runtime and iPhone, read only when something is missing). A project needn't be in
    /// the config: any valid project name builds with the defaults.
    public func templateTarget(
        project: String, profile: String?, deviceType: String?, runtime: String?,
        hostDefault: () throws -> (deviceType: String, runtime: String)? = { nil }
    ) throws -> (
        profile: String, arguments: [String], deviceType: String, runtime: String
    ) {
        let settings = projects[project]
        guard settings != nil || ProjectSettings.isValidName(project) else {
            throw TemplateResolveError.unknownProject(project)
        }
        let profile = profile ?? TemplateSettings.defaultProfile
        guard let arguments = template.profiles[profile] else { throw TemplateResolveError.unknownProfile(profile) }
        var deviceType = deviceType ?? template.deviceType
        var runtime = runtime ?? template.runtime
        if deviceType == nil || runtime == nil, let host = try hostDefault() {
            deviceType = deviceType ?? host.deviceType
            runtime = runtime ?? host.runtime
        }
        guard let deviceType else { throw TemplateResolveError.missing("device type") }
        guard let runtime else { throw TemplateResolveError.missing("runtime") }
        return (profile, arguments, deviceType, runtime)
    }

    /// `autostart`: `simq` starts `simqd` itself (detached, same state dir and config) if no
    /// daemon answers on the socket. On by default; `"autostart": false` turns it off.
    public var autostart = AutostartSettings()

    public struct AutostartSettings: Sendable, Equatable {
        /// False for `"autostart": false`.
        public var enabled = true
        /// `simqd run --backend`; nil passes none, so simqd picks (config `backend`, else
        /// the platform default).
        public var backend: String?
        /// `simqd run --probe`; nil follows the backend.
        public var probe: String?
        /// `simqd run --executor`; nil means process.
        public var executor: String?
        /// How long `simq` waits for the new daemon to answer. Default 30 s.
        public var timeoutSeconds: Double = 30
        public init() {}
    }

    public struct SimctlSettings: Sendable, Equatable {
        /// The template sim `simctl clone` copies (name or UDID). Optional: without it, clones
        /// simulator jobs wait for an explicit host-wide template selection.
        public var template: String?
        public init(template: String? = nil) { self.template = template }
    }

    public init() {}

    struct File: Decodable {
        var jobOutputRoot: String?
        var hostTemplates: [String: String]?
        var defaultHostTemplate: String?
        var priorityAliases: [String: Int]?
        var agingPointsPerMinute: Double?
        var agingMaxBoost: Double?
        var defaultRunTimeoutSeconds: Double?
        var defaultQueueTimeoutSeconds: Double?
        var killGraceSeconds: Double?
        var cleanupMode: CleanupMode?
        var orphanGraceSeconds: Double?
        var tickIntervalSeconds: Double?
        var reconcileIntervalSeconds: Double?
        var watchdogLightIntervalSeconds: Double?
        var watchdogFullIntervalSeconds: Double?
        var maxRunningPerProject: Int?
        var maxQueuedPerSubmitterPerProject: Int?
        var maxQueuedTotal: Int?
        var defaultMaxRetries: Int?
        var maxConcurrentExclusive: Int?
        var maxLoad5: Double?
        var resumeBelowLoad5: Double?
        var autostart: AutostartFile?
        var backend: String?
        var ageRules: AgeRulesFile?
        var pool: PoolFile?
        var simctl: SimctlFile?
        var projects: [String: ProjectSettings]?
        var template: TemplateSettings?
        /// `golden`: the `template` section's name before the rename, still read (`template`
        /// wins when both are set).
        var legacyTemplate: TemplateSettings?
        var host: HostFile?
        struct SimctlFile: Decodable {
            var template: String?
            /// `simctl.golden`, read when `simctl.template` isn't set.
            var legacyTemplate: String?

            enum CodingKeys: String, CodingKey {
                case template
                case legacyTemplate = "golden"
            }
        }

        /// `"autostart": false`, `true`, or an object (which means on).
        struct AutostartFile: Decodable {
            var enabled = true
            var backend: String?
            var probe: String?
            var executor: String?
            var timeoutSeconds: Double?

            enum CodingKeys: String, CodingKey {
                case backend, probe, executor
                case timeoutSeconds = "timeout_seconds"
            }

            init(from decoder: Decoder) throws {
                if let flag = try? decoder.singleValueContainer().decode(Bool.self) {
                    enabled = flag
                    return
                }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                backend = try container.decodeIfPresent(String.self, forKey: .backend)
                probe = try container.decodeIfPresent(String.self, forKey: .probe)
                executor = try container.decodeIfPresent(String.self, forKey: .executor)
                timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
            }
        }

        /// `host`: per-core load factors and RAM-derived limits (`HostSizing`).
        struct HostFile: Decodable {
            var throttleLoad5PerCore: Double?
            var throttleLoad1PerCore: Double?
            var throttleLoad5WithLoad1PerCore: Double?
            var throttleClearLoad5PerCore: Double?
            var bootLoadPerCore: Double?
            var settleLoad5PerCore: Double?
            var reservePercent: Double?
            var minReserveMiB: UInt64?
            var reserveMiB: UInt64?
            var simBootCostMiB: UInt64?
            var ramPerRunningSimMiB: UInt64?
            var maxRunningSims: Int?
            var ramPerPoolSimMiB: UInt64?
            var minFreeDiskGiB: Double?

            enum CodingKeys: String, CodingKey {
                case throttleLoad5PerCore = "throttle_load5_per_core"
                case throttleLoad1PerCore = "throttle_load1_per_core"
                case throttleLoad5WithLoad1PerCore = "throttle_load5_with_load1_per_core"
                case throttleClearLoad5PerCore = "throttle_clear_load5_per_core"
                case bootLoadPerCore = "boot_load_per_core"
                case settleLoad5PerCore = "settle_load5_per_core"
                case reservePercent = "reserve_percent"
                case minReserveMiB = "min_reserve_mib"
                case reserveMiB = "reserve_mib"
                case simBootCostMiB = "sim_boot_cost_mib"
                case ramPerRunningSimMiB = "ram_per_running_sim_mib"
                case maxRunningSims = "max_running_sims"
                case ramPerPoolSimMiB = "ram_per_pool_sim_mib"
                case minFreeDiskGiB = "min_free_disk_gib"
            }
        }

        struct PoolFile: Decodable {
            var enabled: Bool?
            var mode: String?
            var maxSims: Int?
            var warmMin: Int?
            var maxConcurrentBoots: Int?
            var idleShutdownSeconds: Double?
            var recycleAfterSeconds: Double?
            var bootTimeoutSeconds: Double?
            var settle: SettleFile?
            var externalSimPatterns: [String]?

            struct SettleFile: Decodable {
                var mode: SettleMode?
                var loadBelow: Double?
                var maxWaitSeconds: Double?
                var onCap: SettleCapAction?

                enum CodingKeys: String, CodingKey {
                    case mode
                    case loadBelow = "load_below"
                    case maxWaitSeconds = "max_wait_seconds"
                    case onCap = "on_cap"
                }
            }

            enum CodingKeys: String, CodingKey {
                case enabled, settle, mode
                case maxSims = "max_sims"
                case warmMin = "warm_min"
                case maxConcurrentBoots = "max_concurrent_boots"
                case idleShutdownSeconds = "idle_shutdown_seconds"
                case recycleAfterSeconds = "recycle_after_seconds"
                case bootTimeoutSeconds = "boot_timeout_seconds"
                case externalSimPatterns = "external_sim_patterns"
            }
        }

        struct AgeRulesFile: Decodable {
            var orphanProcessSeconds: Double?
            var workDirAfterJobSeconds: Double?
            var leaseMaxAgeSeconds: Double?
            var queuedAlertSeconds: Double?
            var foreignBootedSimReportSeconds: Double?
            var artifactRetentionDays: Retention?
            var artifactBudgetGiB: Double?

            struct Retention: Decodable {
                var succeeded: Double?
                var other: Double?
                var unknown: Double?
                var derivedData: Double?
                var kept: Double?

                enum CodingKeys: String, CodingKey {
                    case succeeded, other, unknown, kept
                    case derivedData = "derived_data"
                }
            }

            enum CodingKeys: String, CodingKey {
                case orphanProcessSeconds = "orphan_process_seconds"
                case workDirAfterJobSeconds = "work_dir_after_job_seconds"
                case leaseMaxAgeSeconds = "lease_max_age_seconds"
                case queuedAlertSeconds = "queued_alert_seconds"
                case foreignBootedSimReportSeconds = "foreign_booted_sim_report_seconds"
                case artifactRetentionDays = "artifact_retention_days"
                case artifactBudgetGiB = "artifact_budget_gib"
            }
        }

        enum CodingKeys: String, CodingKey {
            case jobOutputRoot = "job_output_root"
            case hostTemplates = "host_templates"
            case defaultHostTemplate = "default_host_template"
            case priorityAliases = "priority_aliases"
            case agingPointsPerMinute = "aging_points_per_minute"
            case agingMaxBoost = "aging_max_boost"
            case defaultRunTimeoutSeconds = "default_run_timeout_seconds"
            case defaultQueueTimeoutSeconds = "default_queue_timeout_seconds"
            case killGraceSeconds = "kill_grace_seconds"
            case cleanupMode = "cleanup_mode"
            case orphanGraceSeconds = "orphan_grace_seconds"
            case tickIntervalSeconds = "tick_interval_seconds"
            case reconcileIntervalSeconds = "reconcile_interval_seconds"
            case watchdogLightIntervalSeconds = "watchdog_light_interval_seconds"
            case watchdogFullIntervalSeconds = "watchdog_full_interval_seconds"
            case maxRunningPerProject = "max_running_per_project"
            case maxQueuedPerSubmitterPerProject = "max_queued_per_submitter_per_project"
            case maxQueuedTotal = "max_queued_total"
            case defaultMaxRetries = "default_max_retries"
            case maxConcurrentExclusive = "max_concurrent_exclusive"
            case maxLoad5 = "max_load5"
            case resumeBelowLoad5 = "resume_below_load5"
            case autostart, backend
            case ageRules = "age_rules"
            case pool
            case simctl
            case projects
            case template
            case legacyTemplate = "golden"
            case host
        }
    }

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case unreadable(String, String)
        case invalid(String)

        public var description: String {
            switch self {
            case .unreadable(let path, let why): return "can't read config \(path): \(why)"
            case .invalid(let why): return "invalid config: \(why)"
            }
        }
    }

    /// Loads `path` if it exists; a missing file means all defaults.
    public static func load(path: String) throws -> DaemonConfig {
        guard FileManager.default.fileExists(atPath: path) else {
            return DaemonConfig()
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw LoadError.unreadable(path, "\(error)")
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> DaemonConfig {
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pool = object["pool"] as? [String: Any], let settle = pool["settle"] as? [String: Any],
            (settle["quiet_window_seconds"] != nil || ["quiet", "both"].contains(settle["mode"] as? String ?? ""))
        {
            throw LoadError.invalid("quiet/both settling was removed; use implemented load/off readiness")
        }
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pool = object["pool"] as? [String: Any], pool["prewarm_on_release"] != nil
        {
            throw LoadError.invalid(
                "pool.prewarm_on_release was removed: healthy sims stay warm automatically; use --fresh-sim or --reset-app for job state reset"
            )
        }
        let removed = ["drift", "alerts"]
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let key = removed.first(where: { object[$0] != nil })
        {
            throw LoadError.invalid(
                "\(key) was removed in v1; remove that section from config.json. Current health remains in simq doctor."
            )
        }
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw LoadError.invalid("\(error)")
        }
        if let projects = file.projects, projects.values.contains(where: { $0.template != nil }) {
            throw LoadError.invalid(
                "project.template/golden was removed: configure one host-wide template target and explicit simctl.template; project labels do not route simulators"
            )
        }
        var config = DaemonConfig()
        if let root = file.jobOutputRoot {
            let normalized = URL(fileURLWithPath: root).standardizedFileURL.path
            guard root.hasPrefix("/"), normalized != "/", !root.utf8.contains(0),
                !root.split(separator: "/").contains("..")
            else {
                throw LoadError.invalid(
                    "job_output_root must be an absolute dedicated directory, not / or a path containing ..")
            }
            config.jobOutputRoot = normalized
        }
        config.hostTemplates = file.hostTemplates ?? [:]
        for (name, source) in config.hostTemplates {
            guard ProjectSettings.isValidName(name), !source.isEmpty, !source.utf8.contains(0) else {
                throw LoadError.invalid("host_templates requires valid labels and nonempty simulator identifiers")
            }
        }
        guard Set(config.hostTemplates.values).count == config.hostTemplates.count else {
            throw LoadError.invalid("host_templates entries must select distinct simulator identifiers")
        }
        if let name = file.defaultHostTemplate {
            guard config.hostTemplates[name] != nil else {
                throw LoadError.invalid("default_host_template must name a host_templates entry")
            }
            config.defaultHostTemplate = name
        }

        if let aliases = file.priorityAliases {
            for (name, value) in aliases where !Priority.isValid(value) || Int(name) != nil || name.isEmpty {
                throw LoadError.invalid("priority alias \"\(name)\" = \(value) (needs a non-numeric name and 0...100)")
            }
            config.priorityAliases = PriorityAliases(aliases)
        }
        if let rate = file.agingPointsPerMinute {
            guard rate >= 0 else { throw LoadError.invalid("aging_points_per_minute must be >= 0") }
            config.scheduler.priority.agingPointsPerMinute = rate
        }
        if let cap = file.agingMaxBoost {
            guard cap >= 0 else { throw LoadError.invalid("aging_max_boost must be >= 0") }
            config.scheduler.priority.maxBoost = cap
        }
        for (name, value) in [
            ("default_run_timeout_seconds", file.defaultRunTimeoutSeconds),
            ("default_queue_timeout_seconds", file.defaultQueueTimeoutSeconds),
        ] {
            if let value, value < 0 || !value.isFinite {
                throw LoadError.invalid("\(name) must be >= 0 (0 = no limit)")
            }
        }
        if let value = file.defaultRunTimeoutSeconds {
            config.timeouts.defaultRunTimeoutSeconds = value
        }
        if let value = file.defaultQueueTimeoutSeconds {
            config.timeouts.defaultQueueTimeoutSeconds = value
        }
        if let grace = file.killGraceSeconds {
            guard grace >= 0 else { throw LoadError.invalid("kill_grace_seconds must be >= 0") }
            config.timeouts.killGraceSeconds = grace
        }
        if let grace = file.orphanGraceSeconds {
            guard grace > 0 else { throw LoadError.invalid("orphan_grace_seconds must be > 0") }
            config.reliability.orphanGraceSeconds = grace
        }
        if let mode = file.cleanupMode {
            config.reliability.cleanupMode = mode
        }
        if let interval = file.tickIntervalSeconds {
            guard interval > 0 else { throw LoadError.invalid("tick_interval_seconds must be > 0") }
            config.tickIntervalSeconds = interval
        }
        if let interval = file.reconcileIntervalSeconds {
            guard interval > 0 else { throw LoadError.invalid("reconcile_interval_seconds must be > 0") }
            config.reconcileIntervalSeconds = interval
        }
        if let interval = file.watchdogLightIntervalSeconds {
            guard interval > 0 else { throw LoadError.invalid("watchdog_light_interval_seconds must be > 0") }
            config.watchdog.lightIntervalSeconds = interval
        }
        if let interval = file.watchdogFullIntervalSeconds {
            guard interval > 0 else { throw LoadError.invalid("watchdog_full_interval_seconds must be > 0") }
            config.watchdog.fullIntervalSeconds = interval
        }
        if let cap = file.maxRunningPerProject {
            guard cap >= 0 else {
                throw LoadError.invalid("max_running_per_project must be >= 0 (0 means no project cap)")
            }
            config.scheduler.maxRunningPerProject = cap
        }
        if let cap = file.maxQueuedPerSubmitterPerProject {
            guard cap >= 0 else { throw LoadError.invalid("max_queued_per_submitter_per_project must be >= 0") }
            config.maxQueuedPerSubmitterPerProject = cap
        }
        if let cap = file.maxQueuedTotal {
            guard cap >= 0 else { throw LoadError.invalid("max_queued_total must be >= 0") }
            config.maxQueuedTotal = cap
        }
        if let limit = file.maxLoad5 {
            guard limit > 0, limit.isFinite else { throw LoadError.invalid("max_load5 must be > 0") }
            config.scheduler.loadThrottle.maxLoad5 = limit
        }
        if let resume = file.resumeBelowLoad5 {
            guard let limit = file.maxLoad5 else {
                throw LoadError.invalid("resume_below_load5 needs max_load5")
            }
            guard resume >= 0, resume <= limit else {
                throw LoadError.invalid("resume_below_load5 must be 0...max_load5")
            }
            config.scheduler.loadThrottle.resumeBelowLoad5 = resume
        }
        if let host = file.host {
            config.host = try hostSizing(host)
            if let gib = host.minFreeDiskGiB {
                // One floor, measured on the state-directory volume. 0 turns the disk gate off.
                guard gib >= 0, gib.isFinite, gib < 1_000_000 else {
                    throw LoadError.invalid("host.min_free_disk_gib must be 0...999999 (0 turns the disk gate off)")
                }
                config.scheduler.minFreeDiskBytes = UInt64(gib * 1_073_741_824)
            }
        }
        if let autostart = file.autostart {
            var settings = AutostartSettings()
            settings.enabled = autostart.enabled
            for (name, value, allowed) in [
                ("backend", autostart.backend, ["fake", "simctl"]),
                ("probe", autostart.probe, ["fake", "system"]),
                ("executor", autostart.executor, ["process", "fake"]),
            ] {
                if let value, !allowed.contains(value) {
                    throw LoadError.invalid("autostart.\(name) must be one of \(allowed.joined(separator: ", "))")
                }
            }
            settings.backend = autostart.backend
            settings.probe = autostart.probe
            settings.executor = autostart.executor
            if let timeout = autostart.timeoutSeconds {
                guard timeout > 0, timeout <= 600 else {
                    throw LoadError.invalid("autostart.timeout_seconds must be > 0 and <= 600")
                }
                settings.timeoutSeconds = timeout
            }
            config.autostart = settings
        }
        if let retries = file.defaultMaxRetries {
            guard (0...JobStore.maxRetriesLimit).contains(retries) else {
                throw LoadError.invalid("default_max_retries must be 0...\(JobStore.maxRetriesLimit)")
            }
            config.defaultMaxRetries = retries
        }
        if let age = file.ageRules {
            var rules = config.reliability.ageRules
            for (name, value, path) in [
                ("orphan_process_seconds", age.orphanProcessSeconds, \AgeRules.orphanProcessSeconds),
                ("work_dir_after_job_seconds", age.workDirAfterJobSeconds, \AgeRules.workDirAfterJobSeconds),
                ("lease_max_age_seconds", age.leaseMaxAgeSeconds, \AgeRules.leaseMaxAgeSeconds),
                ("queued_alert_seconds", age.queuedAlertSeconds, \AgeRules.queuedAlertSeconds),
                (
                    "foreign_booted_sim_report_seconds", age.foreignBootedSimReportSeconds,
                    \AgeRules.foreignBootedSimReportSeconds
                ),
            ] {
                guard let value else { continue }
                guard value > 0, value.isFinite else { throw LoadError.invalid("age_rules.\(name) must be > 0") }
                rules[keyPath: path] = value
            }
            if let retention = age.artifactRetentionDays {
                for (name, value, path) in [
                    ("succeeded", retention.succeeded, \ArtifactRetention.succeededSeconds),
                    ("other", retention.other, \ArtifactRetention.otherSeconds),
                    ("unknown", retention.unknown, \ArtifactRetention.unknownSeconds),
                    ("derived_data", retention.derivedData, \ArtifactRetention.derivedDataSeconds),
                ] {
                    guard let value else { continue }
                    guard value > 0, value.isFinite else {
                        throw LoadError.invalid("age_rules.artifact_retention_days.\(name) must be > 0")
                    }
                    rules.artifactRetention[keyPath: path] = value * 86_400
                }
                if let kept = retention.kept {
                    guard kept > 0, kept.isFinite else {
                        throw LoadError.invalid("age_rules.artifact_retention_days.kept must be > 0")
                    }
                    rules.artifactRetention.keptSeconds = kept * 86_400
                }
            }
            if let budget = age.artifactBudgetGiB {
                guard budget > 0, budget.isFinite, budget < 1_000_000 else {
                    throw LoadError.invalid("age_rules.artifact_budget_gib must be > 0")
                }
                rules.artifactRetention.budgetBytes = UInt64(budget * 1_073_741_824)
            }
            config.reliability.ageRules = rules
        }
        if let backend = file.backend {
            guard let kind = BackendKind(rawValue: backend) else {
                throw LoadError.invalid("backend must be one of fake, simctl")
            }
            config.backend = kind
        }
        if let simctl = file.simctl {
            // `simctl.golden` (the name before the rename) still works; `simctl.template` wins.
            let key = simctl.template != nil || simctl.legacyTemplate == nil ? "simctl.template" : "simctl.golden"
            let template = simctl.template ?? simctl.legacyTemplate
            if let template, template.isEmpty {
                throw LoadError.invalid("\(key) must not be empty (omit it to clone the newest template)")
            }
            config.simctl = SimctlSettings(template: template)
        }
        if let projects = file.projects {
            for (name, project) in projects { try project.validate(name: name) }
            config.projects = projects
        }
        // `golden` (the section's name before the rename) still works; `template` wins.
        if let template = file.template ?? file.legacyTemplate {
            for name in template.profiles.keys where !DaemonConfig.ProjectSettings.isValidName(name) || name.count > 16
            {
                throw LoadError.invalid(
                    "template profile name \"\(name)\" must be lowercase letters, digits and - (max 16)")
            }
            config.template = template
        }
        if let pool = file.pool, pool.enabled ?? true {
            var settings = SimPoolConfig()
            if let value = pool.maxSims {
                settings.maxSims = value
                config.host.poolMaxSimsIsExplicit = true
            }
            if let value = pool.warmMin { settings.warmMin = value }
            if let value = pool.maxConcurrentBoots { settings.maxConcurrentBoots = value }
            if let value = pool.idleShutdownSeconds { settings.idleShutdownSeconds = value }
            if let value = pool.recycleAfterSeconds { settings.recycleAfterSeconds = value }
            if let value = pool.bootTimeoutSeconds { settings.bootTimeoutSeconds = value }
            if let value = pool.mode {
                guard let mode = PoolMode(rawValue: value) else {
                    throw LoadError.invalid(
                        "pool.mode must be one of " + PoolMode.allCases.map(\.rawValue).joined(separator: ", "))
                }
                settings.mode = mode
            }
            if let patterns = pool.externalSimPatterns {
                // A pattern of only wildcards ("*", "?", "??*") matches nearly every sim and
                // would hold the pool forever.
                guard patterns.allSatisfy({ $0.contains(where: { $0 != "*" && $0 != "?" }) }) else {
                    throw LoadError.invalid(
                        "pool.external_sim_patterns entries need at least one literal character (not only * and ?)")
                }
                settings.externalSimPatterns = patterns
            }
            if let settle = pool.settle {
                if let value = settle.mode {
                    guard value == .load || value == .off else {
                        throw LoadError.invalid("pool.settle.mode supports only load/off in v1; remove quiet/both")
                    }
                    settings.settle.mode = value
                }
                if let value = settle.loadBelow {
                    settings.settle.loadBelow = value
                    config.host.settleLoadBelowIsExplicit = true
                }
                if let value = settle.maxWaitSeconds { settings.settle.maxWaitSeconds = value }
                if let value = settle.onCap { settings.settle.onCap = value }
            }
            guard settings.maxSims >= 1 else { throw LoadError.invalid("pool.max_sims must be >= 1") }
            guard settings.maxConcurrentBoots >= 1 else {
                throw LoadError.invalid("pool.max_concurrent_boots must be >= 1")
            }
            guard settings.warmMin >= 0, settings.warmMin <= settings.maxSims else {
                throw LoadError.invalid("pool.warm_min must be between 0 and max_sims")
            }
            guard settings.settle.maxWaitSeconds > 0 else {
                throw LoadError.invalid("pool.settle.max_wait_seconds must be > 0")
            }
            config.pool = settings
        }
        if let slots = file.maxConcurrentExclusive {
            guard slots >= 1 else { throw LoadError.invalid("max_concurrent_exclusive must be >= 1") }
            config.scheduler.maxConcurrentExclusive = slots
        }
        return config
    }

    private static func hostSizing(_ file: File.HostFile) throws -> HostSizing {
        var sizing = HostSizing()
        func factor(_ value: Double?, _ key: String, _ keyPath: WritableKeyPath<HostSizing, Double>) throws {
            guard let value else { return }
            guard value > 0, value.isFinite else { throw LoadError.invalid("host.\(key) must be > 0") }
            sizing[keyPath: keyPath] = value
        }
        try factor(file.throttleLoad5PerCore, "throttle_load5_per_core", \.throttleLoad5PerCore)
        try factor(file.throttleLoad1PerCore, "throttle_load1_per_core", \.throttleLoad1PerCore)
        try factor(
            file.throttleLoad5WithLoad1PerCore, "throttle_load5_with_load1_per_core", \.throttleLoad5WithLoad1PerCore)
        try factor(file.throttleClearLoad5PerCore, "throttle_clear_load5_per_core", \.throttleClearLoad5PerCore)
        try factor(file.bootLoadPerCore, "boot_load_per_core", \.bootLoadPerCore)
        try factor(file.settleLoad5PerCore, "settle_load5_per_core", \.settleLoad5PerCore)
        sizing.settleLoad5PerCoreIsExplicit = file.settleLoad5PerCore != nil
        guard sizing.throttleClearLoad5PerCore <= sizing.throttleLoad5PerCore else {
            throw LoadError.invalid("host.throttle_clear_load5_per_core must be <= throttle_load5_per_core")
        }
        if let percent = file.reservePercent {
            guard percent >= 0, percent < 100 else { throw LoadError.invalid("host.reserve_percent must be 0..<100") }
            sizing.reservePercent = percent
        }
        // Bounded so `mib * 1 MiB` can't overflow (and trap): 16 TiB is far above any host.
        let maxReserveMiB: UInt64 = 16 << 20
        if let mib = file.minReserveMiB {
            guard mib <= maxReserveMiB else {
                throw LoadError.invalid("host.min_reserve_mib must be <= \(maxReserveMiB)")
            }
            sizing.minReserveBytes = mib * ByteSize.mebibyte
        }
        if let mib = file.reserveMiB {
            // 0 is allowed and means what it says: no reserve at all (admission may use all
            // available memory). Omit the key for the derived reserve.
            guard mib <= maxReserveMiB else { throw LoadError.invalid("host.reserve_mib must be <= \(maxReserveMiB)") }
            sizing.reserveBytes = mib * ByteSize.mebibyte
        }
        if let mib = file.simBootCostMiB {
            guard mib <= maxReserveMiB else {
                throw LoadError.invalid("host.sim_boot_cost_mib must be <= \(maxReserveMiB)")
            }
            sizing.simBootCostBytes = mib * ByteSize.mebibyte
        }
        if let mib = file.ramPerRunningSimMiB {
            guard mib >= 1, mib <= maxReserveMiB else {
                throw LoadError.invalid("host.ram_per_running_sim_mib must be 1...\(maxReserveMiB)")
            }
            sizing.ramPerRunningSimBytes = mib * ByteSize.mebibyte
        }
        if let count = file.maxRunningSims {
            guard count >= 1 else { throw LoadError.invalid("host.max_running_sims must be >= 1") }
            sizing.maxRunningSims = count
        }
        if let mib = file.ramPerPoolSimMiB {
            guard mib >= 1, mib <= maxReserveMiB else {
                throw LoadError.invalid("host.ram_per_pool_sim_mib must be 1...\(maxReserveMiB)")
            }
            sizing.ramPerPoolSimBytes = mib * ByteSize.mebibyte
        }
        return sizing
    }

    /// The startup log line for the derived limits. Built from parts: one long interpolated
    /// concatenation exceeded the macOS compiler's type-check time limit.
    public func hostSizingSummary(cpuCount: Int, totalMemoryBytes: UInt64) -> String {
        let mib = ByteSize.mebibyte
        let throttle = scheduler.loadThrottle
        var parts = [
            "reserve \(scheduler.reserveBytes / mib) MiB",
            "max_running_sims \(scheduler.maxRunningSims)",
            "boot gate load1 <= \(scheduler.bootLoadLimit(cpuCount: cpuCount))",
            "default throttle load5 > \(throttle.load5Above) or load1 > \(throttle.load1Above) with load5 > "
                + "\(throttle.load5WithLoad1Above), recovery at load1 <= \(throttle.clearBelowLoad5); "
                + "otherwise load5 <= \(throttle.clearBelowLoad5) after entry triggers clear",
        ]
        if let pool {
            parts.append("pool max_sims \(pool.maxSims)")
            if pool.settle.mode == .off {
                parts.append("settle off (boot status required)")
            } else {
                var settling = "settle load5 < \(pool.settle.loadBelow)"
                if let recovery = pool.settle.load1RecoveryBelow {
                    settling += " or load1 <= \(recovery) (default recovery)"
                }
                parts.append(settling)
            }
        }
        let head = "simqd: host sizing for \(cpuCount) cores, \(totalMemoryBytes / mib) MiB: "
        return head + parts.joined(separator: ", ")
    }

    /// Sets the limits `host` derives from this host's cores and RAM (`HostSizing.apply`).
    /// `simqd` calls it once at start, before the scheduler and pool read their configs.
    public mutating func applyHostSizing(cpuCount: Int, totalMemoryBytes: UInt64) {
        host.apply(cpuCount: cpuCount, totalMemoryBytes: totalMemoryBytes, to: &scheduler, pool: &pool)
    }
}
