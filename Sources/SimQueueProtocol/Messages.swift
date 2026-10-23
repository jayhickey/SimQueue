// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore

// Wire protocol: newline-delimited JSON over a Unix socket (0600, owner only). Each line
// is one envelope. A client sends one request per connection and reads responses until
// it gets a `result` or an `error`; `wait` streams `event` lines first. Field names are
// snake_case and stable: add fields, never rename or remove. See docs/PROTOCOL.md.

public enum Method: String, Sendable, Codable, CaseIterable {
    case submit
    case status
    case drain
    case stop
    case resume
    case jobs
    case explain
    case cancel
    case bump
    case wait
    case doctor
    case logs
    case leaseAcquire = "lease_acquire"
    case leaseRelease = "lease_release"
    case leaseRenew = "lease_renew"
    case templateBuild = "template_build"
    case templateList = "template_list"
    case templateRemove = "template_rm"

    /// The template methods' names before the rename to template (`golden_build`,
    /// `golden_list`, `golden_rm`). Still accepted; the answer then uses the old names too
    /// (`result_kind` `golden`, `goldens`).
    public static let legacyTemplateMethods: [String: Method] = [
        "golden_build": .templateBuild, "golden_list": .templateList, "golden_rm": .templateRemove,
    ]
    case gc
}

/// `gc`: list what artifact retention would remove now; remove it with `apply`.
public struct GCParams: Sendable, Equatable, Codable {
    public var background: Bool?
    /// Nil or false: dry run (changes nothing).
    public var apply: Bool?

    public init(apply: Bool? = nil, background: Bool? = nil) {
        self.background = background
        self.apply = apply
    }
}

public struct GCEntry: Sendable, Equatable, Codable {
    public var path: String
    public var reason: String
    public var bytes: UInt64?

    public init(path: String, reason: String, bytes: UInt64?) {
        self.path = path
        self.reason = reason
        self.bytes = bytes
    }
}

/// Last completed retention pass. Removed bytes are measured logical file sizes,
/// not a claim about free-space deltas on shared/compressed filesystems.
public struct CleanupSummary: Sendable, Equatable, Codable {
    public var finishedAt: Double
    public var automatic: Bool
    public var removedCount: Int
    public var removedBytes: UInt64
    public var unknownRemovedSizes: Int
    public var deferredCount: Int
    public var failureCount: Int
    public var failures: [String]
    public var unavailableRoots: [String]
    public init(
        finishedAt: Double, automatic: Bool, removedCount: Int, removedBytes: UInt64,
        unknownRemovedSizes: Int, deferredCount: Int, failureCount: Int, failures: [String], unavailableRoots: [String]
    ) {
        self.finishedAt = finishedAt; self.automatic = automatic; self.removedCount = removedCount
        self.removedBytes = removedBytes; self.unknownRemovedSizes = unknownRemovedSizes
        self.deferredCount = deferredCount; self.failureCount = failureCount; self.failures = failures
        self.unavailableRoots = unavailableRoots
    }
}

public struct GCResult: Sendable, Equatable, Codable {
    public var cleanup: CleanupSummary?

    public var scheduled: Bool?
    public var applied: Bool
    /// Everything retention (age rules and the size budget) would remove now.
    public var candidates: [GCEntry]
    /// With `apply`: what was removed, and what couldn't be.
    public var removed: [String]
    public var failures: [String]
    /// The config's artifact budget, if any.
    public var budgetBytes: UInt64?

    public init(
        applied: Bool, candidates: [GCEntry], removed: [String] = [], failures: [String] = [],
        budgetBytes: UInt64? = nil, scheduled: Bool? = nil
    ) {
        self.scheduled = scheduled
        self.applied = applied
        self.candidates = candidates
        self.removed = removed
        self.failures = failures
        self.budgetBytes = budgetBytes
    }

    enum CodingKeys: String, CodingKey {
        case applied, candidates, removed, failures, scheduled, cleanup
        case budgetBytes = "budget_bytes"
    }
}

/// `template_build`: build a project's template sim. Unset fields come from the project's
/// `template` entry, then the config's `template` defaults; `profile` defaults to `default`.
public struct TemplateBuildParams: Sendable, Equatable, Codable {
    public var project: String
    public var profile: String?
    public var deviceType: String?
    public var runtime: String?
    public var replace: Bool?
    public var slim: Bool?

    public init(
        project: String, profile: String? = nil, deviceType: String? = nil, runtime: String? = nil,
        replace: Bool? = nil, slim: Bool? = nil
    ) {
        self.project = project
        self.profile = profile
        self.deviceType = deviceType
        self.runtime = runtime
        self.replace = replace
        self.slim = slim
    }

    enum CodingKeys: String, CodingKey {
        case project, profile, runtime, replace, slim
        case deviceType = "device_type"
    }
}

/// `template_rm`: remove a registered template by name or UDID (through the cleanup gate).
public struct TemplateRemoveParams: Sendable, Equatable, Codable {
    public var template: String
    public init(template: String) { self.template = template }

    enum CodingKeys: String, CodingKey {
        case template
        /// The field's name before the rename to template; still accepted.
        case legacyTemplate = "golden"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard
            let template = try container.decodeIfPresent(String.self, forKey: .template)
                ?? container.decodeIfPresent(String.self, forKey: .legacyTemplate)
        else {
            throw DecodingError.keyNotFound(
                CodingKeys.template, .init(codingPath: container.codingPath, debugDescription: "template is required"))
        }
        self.template = template
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(template, forKey: .template)
    }
}

public struct TemplateInfo: Sendable, Equatable, Codable {
    public var project: String
    public var profile: String
    public var name: String
    public var udid: String
    public var deviceType: String
    public var runtime: String
    public var xcodeVersion: String
    public var runtimeVersion: String
    public var builtAt: Double
    /// `ready` or `slim_failed`.
    public var status: String
    /// The host's Xcode or runtime version changed since it was built. Nil: unknown.
    public var stale: Bool?
    public var slimmed: Bool?

    public init(
        project: String, profile: String, name: String, udid: String, deviceType: String, runtime: String,
        xcodeVersion: String, runtimeVersion: String, builtAt: Double, status: String, stale: Bool?,
        slimmed: Bool? = nil
    ) {
        self.project = project
        self.profile = profile
        self.name = name
        self.udid = udid
        self.deviceType = deviceType
        self.runtime = runtime
        self.xcodeVersion = xcodeVersion
        self.runtimeVersion = runtimeVersion
        self.builtAt = builtAt
        self.status = status
        self.stale = stale
        self.slimmed = slimmed
    }

    enum CodingKeys: String, CodingKey {
        case project, profile, name, udid, runtime, status, stale, slimmed
        case deviceType = "device_type"
        case xcodeVersion = "xcode_version"
        case runtimeVersion = "runtime_version"
        case builtAt = "built_at"
    }
}

/// Answer to every template request.
public struct TemplateResult: Sendable, Equatable, Codable {
    /// `built`, `listed`, `removed`, `would_remove` (report-only) or `postponed` (rate limit).
    public var outcome: String
    public var templates: [TemplateInfo]
    public init(outcome: String, templates: [TemplateInfo]) {
        self.outcome = outcome
        self.templates = templates
    }

    enum CodingKeys: String, CodingKey {
        case outcome, templates
        /// `templates` before the rename; sent instead of it to a client that used a legacy
        /// `golden_*` method, and read from an older daemon.
        case legacyTemplates = "goldens"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outcome = try container.decode(String.self, forKey: .outcome)
        templates =
            try container.decodeIfPresent([TemplateInfo].self, forKey: .templates)
            ?? container.decode([TemplateInfo].self, forKey: .legacyTemplates)
    }

    public func encode(to encoder: Encoder) throws {
        try encode(to: encoder, legacyNames: false)
    }

    func encode(to encoder: Encoder, legacyNames: Bool) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(templates, forKey: legacyNames ? .legacyTemplates : .templates)
    }
}

/// Encodes a `TemplateResult` with the pre-rename field names.
private struct LegacyTemplateResult: Encodable {
    var result: TemplateResult
    func encode(to encoder: Encoder) throws { try result.encode(to: encoder, legacyNames: true) }
}

/// `lease_acquire`: ask for one pool sim for `holder`. Answered at once: `granted` with
/// the sim, or `pending` while none has settled yet. The client polls (each poll keeps
/// its demand alive for the pool) until granted or its own deadline; repeating a granted
/// request returns the same sim.
///
/// A manual lease protects its sim only while its holder is live: with `pid` (a running
/// process; its start time is recorded) until that process is gone, without one until no
/// acquire or `lease_renew` arrived for the orphan grace. Then the watchdog reclaims it
/// (enforce) or reports it (report-only).
public struct LeaseAcquireParams: Sendable, Equatable, Codable {
    public var holder: String
    public var pid: Int32?
    public init(holder: String, pid: Int32? = nil) {
        self.holder = holder
        self.pid = pid
    }
}

public struct LeaseReleaseParams: Sendable, Equatable, Codable {
    public var holder: String
    public var udid: String
    public init(holder: String, udid: String) {
        self.holder = holder
        self.udid = udid
    }
}

public struct LeaseResult: Sendable, Equatable, Codable {
    /// `granted`, `pending` or `released`.
    public var state: String
    public var holder: String
    public var udid: String?
    public var name: String?
    /// While pending: what the pool is doing (`settling`, `booting`, `waiting`).
    public var poolState: String?

    public init(state: String, holder: String, udid: String? = nil, name: String? = nil, poolState: String? = nil) {
        self.state = state
        self.holder = holder
        self.udid = udid
        self.name = name
        self.poolState = poolState
    }

    enum CodingKeys: String, CodingKey {
        case state, holder, udid, name
        case poolState = "pool_state"
    }
}

/// Error codes carried in `error` responses, each with the exit code `simq` uses.
public enum ProtocolErrorCode: String, Sendable, Codable, CaseIterable {
    case badRequest = "bad_request"
    /// A well-formed request with an invalid value (priority, timeout, unknown alias).
    case invalidArgument = "invalid_argument"
    case unsupportedSchemaVersion = "unsupported_schema_version"
    case notFound = "not_found"
    case queueFull = "queue_full"
    case invalidState = "invalid_state"
    case internalError = "internal_error"

    public var exitCode: SimQExitCode {
        switch self {
        case .badRequest, .unsupportedSchemaVersion: return .protocolError
        case .invalidArgument: return .usage
        case .notFound: return .notFound
        case .queueFull: return .queueFull
        case .invalidState: return .protocolError
        case .internalError: return .internalError
        }
    }
}

public struct ProtocolError: Error, Sendable, Equatable, Codable {
    public var code: ProtocolErrorCode
    public var message: String

    public init(_ code: ProtocolErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - Request parameters

public struct SubmitParams: Sendable, Equatable, Codable {
    public var project: String
    /// Free-form label (status, logs, metrics only). Nil or empty: no label.
    public var kind: String?
    public var template: String?
    /// 0...100; nil means the daemon's default (50).
    public var priority: Int?
    /// A user-defined alias from the daemon's config, used instead of `priority`.
    public var priorityName: String?
    public var submitter: String
    public var worktree: String?
    public var gitSHA: String?
    public var dedupeKey: String?
    public var minSims: Int
    public var maxSims: Int?
    public var memoryBytes: UInt64
    public var memoryBytesPerSim: UInt64
    /// Take the single exclusive slot (run one at a time). Nil: false.
    public var exclusive: Bool?
    /// May be retried after an infra failure and requeued after a daemon restart. Nil: false.
    public var retryable: Bool?
    /// Infra retries for a retryable job (0...10). Nil: the daemon default (1).
    public var maxRetries: Int?
    /// Run timeout from job start. Nil: the config default; 0: no limit.
    public var runTimeoutSeconds: Double?
    /// Queue timeout before first start. Nil: the config default (24 h); 0: no limit.
    public var queueTimeoutSeconds: Double?
    public var payloadJSON: String?
    /// The command to run (argv; the first element is resolved on `PATH`). Required by
    /// the process executor.
    public var command: [String]?
    /// Extra environment for the command. Names must match `[A-Za-z_][A-Za-z0-9_]*`;
    /// `SIMQ_*` is reserved. Values are never echoed back in job output.
    public var environment: [String: String]?
    /// Absolute working directory for the command. Nil: the daemon's working directory.
    public var cwd: String?
    /// Bundle ids to reset on each leased sim before the command (`--reset-app`).
    public var resetApps: [String]?
    /// Erase each leased sim before the command (`--fresh-sim`).
    public var freshSim: Bool?
    /// Pin the job's artifacts (`--keep`): kept longest by retention, never removed for the
    /// size budget. Nil: false.
    public var keep: Bool?

    public init(
        project: String,
        kind: String? = nil,
        template: String? = nil,
        priority: Int? = nil,
        priorityName: String? = nil,
        submitter: String,
        worktree: String? = nil,
        gitSHA: String? = nil,
        dedupeKey: String? = nil,
        minSims: Int = 0,
        maxSims: Int? = nil,
        memoryBytes: UInt64 = 0,
        memoryBytesPerSim: UInt64 = 0,
        exclusive: Bool? = nil,
        retryable: Bool? = nil,
        maxRetries: Int? = nil,
        runTimeoutSeconds: Double? = nil,
        queueTimeoutSeconds: Double? = nil,
        payloadJSON: String? = nil,
        command: [String]? = nil,
        environment: [String: String]? = nil,
        cwd: String? = nil,
        resetApps: [String]? = nil,
        freshSim: Bool? = nil,
        keep: Bool? = nil
    ) {
        self.keep = keep
        self.resetApps = resetApps
        self.freshSim = freshSim
        self.command = command
        self.environment = environment
        self.cwd = cwd
        self.exclusive = exclusive
        self.retryable = retryable
        self.maxRetries = maxRetries
        self.project = project
        self.kind = kind
        self.template = template
        self.priority = priority
        self.priorityName = priorityName
        self.queueTimeoutSeconds = queueTimeoutSeconds
        self.submitter = submitter
        self.worktree = worktree
        self.gitSHA = gitSHA
        self.dedupeKey = dedupeKey
        self.minSims = minSims
        self.maxSims = maxSims
        self.memoryBytes = memoryBytes
        self.memoryBytesPerSim = memoryBytesPerSim
        self.runTimeoutSeconds = runTimeoutSeconds
        self.payloadJSON = payloadJSON
    }

    enum CodingKeys: String, CodingKey {
        case project, kind, template, submitter, worktree
        case priority, exclusive, retryable
        case command, environment, cwd
        case maxRetries = "max_retries"
        case priorityName = "priority_name"
        case queueTimeoutSeconds = "queue_timeout_seconds"
        case gitSHA = "git_sha"
        case dedupeKey = "dedupe_key"
        case minSims = "min_sims"
        case maxSims = "max_sims"
        case memoryBytes = "memory_bytes"
        case memoryBytesPerSim = "memory_bytes_per_sim"
        case runTimeoutSeconds = "run_timeout_seconds"
        case payloadJSON = "payload_json"
        case resetApps = "reset_apps"
        case freshSim = "fresh_sim"
        case keep
    }
}

public struct JobsParams: Sendable, Equatable, Codable {
    public var states: [JobState]?
    public var project: String?
    public var limit: Int?

    public init(states: [JobState]? = nil, project: String? = nil, limit: Int? = nil) {
        self.states = states
        self.project = project
        self.limit = limit
    }
}

public struct JobRef: Sendable, Equatable, Codable {
    public var jobID: String

    public init(jobID: String) {
        self.jobID = jobID
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
    }
}

public struct CancelParams: Sendable, Equatable, Codable {
    public var jobID: String

    public init(jobID: String) {
        self.jobID = jobID
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
    }
}

/// Changes only a waiting job's base priority; higher values run first.
public struct BumpParams: Sendable, Equatable, Codable {
    public var jobID: String
    public var priority: Int

    public init(jobID: String, priority: Int) {
        self.jobID = jobID
        self.priority = priority
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case priority
    }
}

public struct WaitParams: Sendable, Equatable, Codable {
    public var jobID: String
    /// Send an `event` line on every state, position or reason change.
    public var stream: Bool
    /// Stop waiting (without canceling) once the job is admitted.
    public var untilAdmitted: Bool

    public init(jobID: String, stream: Bool = false, untilAdmitted: Bool = false) {
        self.jobID = jobID
        self.stream = stream
        self.untilAdmitted = untilAdmitted
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case stream
        case untilAdmitted = "until_admitted"
    }
}

/// Reads a job's combined output log from `offset`. Poll with `next_offset` to follow.
public struct LogsParams: Sendable, Equatable, Codable {
    public static let defaultMaxBytes = 64 * 1024
    /// Upper bound per response, so a line stays well under `LineCodec.maxLineBytes` even
    /// after JSON escaping.
    public static let maxBytesLimit = 128 * 1024

    public var jobID: String
    public var offset: Int64
    public var maxBytes: Int?
    /// Read a bounded window at the current end; offset is ignored when present.
    public var tailBytes: Int?

    public init(jobID: String, offset: Int64 = 0, maxBytes: Int? = nil, tailBytes: Int? = nil) {
        self.jobID = jobID
        self.offset = offset
        self.maxBytes = maxBytes
        self.tailBytes = tailBytes
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case offset
        case maxBytes = "max_bytes"
        case tailBytes = "tail_bytes"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try container.decode(String.self, forKey: .jobID)
        offset = try container.decodeIfPresent(Int64.self, forKey: .offset) ?? 0
        maxBytes = try container.decodeIfPresent(Int.self, forKey: .maxBytes)
        tailBytes = try container.decodeIfPresent(Int.self, forKey: .tailBytes)
    }
}

public struct StopParams: Sendable, Equatable, Codable {
    public var epoch: Int64
    public var exitDaemon: Bool
    public init(epoch: Int64, exitDaemon: Bool = true) {
        self.epoch = epoch
        self.exitDaemon = exitDaemon
    }
    enum CodingKeys: String, CodingKey {
        case epoch
        case exitDaemon = "exit_daemon"
    }
}

public enum RequestParams: Sendable, Equatable {
    case submit(SubmitParams)
    case status
    case drain
    case stop(StopParams)
    case resume
    case jobs(JobsParams)
    case explain(JobRef)
    case cancel(CancelParams)
    case bump(BumpParams)
    case wait(WaitParams)
    case doctor
    case logs(LogsParams)
    case leaseAcquire(LeaseAcquireParams)
    case leaseRelease(LeaseReleaseParams)
    /// Heartbeat for a held lease (same params as release).
    case leaseRenew(LeaseReleaseParams)
    case templateBuild(TemplateBuildParams)
    case templateList
    case templateRemove(TemplateRemoveParams)
    case gc(GCParams)

    public var method: Method {
        switch self {
        case .submit: return .submit
        case .stop: return .stop
        case .drain: return .drain
        case .resume: return .resume
        case .status: return .status
        case .jobs: return .jobs
        case .explain: return .explain
        case .cancel: return .cancel
        case .bump: return .bump
        case .wait: return .wait
        case .doctor: return .doctor
        case .logs: return .logs
        case .leaseAcquire: return .leaseAcquire
        case .leaseRelease: return .leaseRelease
        case .leaseRenew: return .leaseRenew
        case .templateBuild: return .templateBuild
        case .templateList: return .templateList
        case .templateRemove: return .templateRemove
        case .gc: return .gc
        }
    }
}

public struct Request: Sendable, Equatable, Codable {
    public var schemaVersion: Int
    public var id: String
    public var params: RequestParams
    /// The client named a template method by its pre-rename name (`golden_*`), so the answer
    /// uses the old names too. Never encoded: this client always sends the new names.
    public var usesLegacyTemplateNames = false

    public init(
        id: String = UUID().uuidString, params: RequestParams, schemaVersion: Int = Envelope.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.params = params
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id, method, params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        guard schemaVersion <= Envelope.currentSchemaVersion else {
            // Leave params undecoded; the server answers unsupported_schema_version.
            params = .status
            return
        }
        let methodName = try container.decode(String.self, forKey: .method)
        guard let method = Method(rawValue: methodName) ?? Method.legacyTemplateMethods[methodName] else {
            throw DecodingError.dataCorruptedError(
                forKey: .method, in: container, debugDescription: "unknown method \(methodName)")
        }
        usesLegacyTemplateNames = Method(rawValue: methodName) == nil
        switch method {
        case .submit:
            let legacy = try container.nestedContainer(keyedBy: RemovedSubmitKeys.self, forKey: .params)
            guard legacy.allKeys.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .params, in: container,
                    debugDescription: "test sharding/build groups were removed in v1; submit independent complete jobs")
            }
            params = .submit(try container.decode(SubmitParams.self, forKey: .params))
        case .stop: params = .stop(try container.decode(StopParams.self, forKey: .params))
        case .drain: params = .drain
        case .resume: params = .resume
        case .status: params = .status
        case .jobs: params = .jobs(try container.decodeIfPresent(JobsParams.self, forKey: .params) ?? JobsParams())
        case .explain: params = .explain(try container.decode(JobRef.self, forKey: .params))
        case .cancel: params = .cancel(try container.decode(CancelParams.self, forKey: .params))
        case .bump: params = .bump(try container.decode(BumpParams.self, forKey: .params))
        case .wait: params = .wait(try container.decode(WaitParams.self, forKey: .params))
        case .doctor: params = .doctor
        case .logs: params = .logs(try container.decode(LogsParams.self, forKey: .params))
        case .leaseAcquire: params = .leaseAcquire(try container.decode(LeaseAcquireParams.self, forKey: .params))
        case .leaseRelease: params = .leaseRelease(try container.decode(LeaseReleaseParams.self, forKey: .params))
        case .leaseRenew: params = .leaseRenew(try container.decode(LeaseReleaseParams.self, forKey: .params))
        case .templateBuild: params = .templateBuild(try container.decode(TemplateBuildParams.self, forKey: .params))
        case .templateList: params = .templateList
        case .templateRemove: params = .templateRemove(try container.decode(TemplateRemoveParams.self, forKey: .params))
        case .gc: params = .gc(try container.decodeIfPresent(GCParams.self, forKey: .params) ?? GCParams())
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(params.method, forKey: .method)
        switch params {
        case .submit(let value): try container.encode(value, forKey: .params)
        case .jobs(let value): try container.encode(value, forKey: .params)
        case .explain(let value): try container.encode(value, forKey: .params)
        case .cancel(let value): try container.encode(value, forKey: .params)
        case .bump(let value): try container.encode(value, forKey: .params)
        case .wait(let value): try container.encode(value, forKey: .params)
        case .logs(let value): try container.encode(value, forKey: .params)
        case .leaseAcquire(let value): try container.encode(value, forKey: .params)
        case .leaseRelease(let value): try container.encode(value, forKey: .params)
        case .leaseRenew(let value): try container.encode(value, forKey: .params)
        case .templateBuild(let value): try container.encode(value, forKey: .params)
        case .templateRemove(let value): try container.encode(value, forKey: .params)
        case .stop(let p): try container.encode(p, forKey: .params)
        case .status, .doctor, .templateList, .drain, .resume: break
        case .gc(let value): try container.encode(value, forKey: .params)
        }
    }
}

// MARK: - Response payloads

public struct WaitReasonInfo: Sendable, Equatable, Codable {
    public var code: String
    public var summary: String

    public init(code: String, summary: String) {
        self.code = code
        self.summary = summary
    }

    public init(_ reason: WaitReason) {
        self.init(code: reason.code, summary: reason.summary)
    }
}

public struct JobInfo: Sendable, Equatable, Codable {
    public var id: String
    public var template: String?
    public var project: String
    /// Free-form label; empty when none was given.
    public var kind: String
    public var priority: Int
    public var exclusive: Bool
    public var retryable: Bool
    public var maxRetries: Int?
    public var submitter: String
    public var state: JobState
    public var resultClass: ResultClass?
    public var attempt: Int
    public var queueTime: Timestamp
    public var admittedAt: Timestamp?
    public var startedAt: Timestamp?
    public var finishedAt: Timestamp?
    public var grantedSims: Int
    public var runTimeoutSeconds: Double?
    public var queueTimeoutSeconds: Double?
    /// When the run timeout fires (start + run timeout); nil before start or without one.
    public var runDeadlineAt: Timestamp?
    /// When a queued first attempt expires; nil once started or without a queue timeout.
    public var queueDeadlineAt: Timestamp?
    public var termSentAt: Timestamp?
    public var killSentAt: Timestamp?
    public var parentID: String?
    public var dedupeKey: String?
    public var message: String?
    /// The command (argv) for the process executor; nil when the job has none.
    public var command: [String]?
    public var cwd: String?
    /// Names of the extra environment variables (values are never echoed).
    public var environmentKeys: [String]?
    /// The command's own exit status (exit code, or 128 + signal) once it ended.
    public var commandExitCode: Int32?
    /// Where the job's combined stdout and stderr are written (set by the daemon).
    public var logPath: String?
    /// The `simq` exit code for this job once it is terminal (nil while active).
    public var exitCodeValue: Int32?
    /// 1-based dispatch position while queued, from the last scheduling pass.
    public var position: Int?
    public var effectiveScore: Double?
    public var waitReasons: [WaitReasonInfo]
    /// What `reset_apps` / `fresh_sim` asked for (nil when neither).
    public var resetApps: [String]?
    public var freshSim: Bool?
    /// What preparation did to each leased sim (set by the daemon once it ran).
    public var simPrep: [SimPrepOutcome]?
    /// The job's run directory (`SIMQ_RUN_DIR`), once it has started (set by the daemon).
    public var runDir: String?
    /// Files in the run directory, on `explain` and `wait` (nil elsewhere); see `ArtifactInfo`.
    public var artifacts: [ArtifactInfo]?
    /// True when the listing stopped early: at its cap (`ArtifactInfo.listCap`) or at the
    /// walk bound on file-system nodes.
    public var artifactsTruncated: Bool?
    /// Pool sims the job held, as recorded when it started, each with the template it was
    /// cloned from (`sims[].cloned_from`), for the latest attempt. Nil before the start or
    /// with no pool sims.
    public var sims: [JobSim]?
    /// Sampled peak resident memory of the job's process group, in MiB (approximate; see
    /// `JobRunInfo.peakResidentBytes`), for the latest attempt. The sims' own processes are
    /// not counted.
    public var peakMemoryMiB: Double?
    /// Absolute paths of the `*.xcresult` bundles in the run directory (with `artifacts`).
    /// Taken from the listing, so it can be incomplete when `artifactsTruncated` is true.
    public var resultBundles: [String]?
    /// The submitted worktree and the full commit sha the daemon verified was checked out
    /// there (at submit, and again just before the command started).
    public var worktree: String?
    public var gitSHA: String?
    /// True while owned command processes still need verified cleanup.
    public var cleanupPending: Bool?
    /// Cleanup could not be verified; capacity stays held and manual inspection is required.
    public var cleanupBlocked: Bool?

    public init(job: Job, explanation: QueueExplanation?) {
        id = job.id
        project = job.project
        kind = job.kind
        priority = job.priority
        exclusive = job.exclusive
        retryable = job.retryable
        maxRetries = job.maxRetries
        template = job.command?.template
        submitter = job.submitter
        state = job.state
        resultClass = job.resultClass
        attempt = job.attempt
        queueTime = Timestamp(job.queueTime)
        admittedAt = Timestamp(job.admittedAt)
        startedAt = Timestamp(job.startedAt)
        finishedAt = Timestamp(job.finishedAt)
        grantedSims = job.grantedSims
        runTimeoutSeconds = job.runTimeoutSeconds
        queueTimeoutSeconds = job.queueTimeoutSeconds
        runDeadlineAt = job.state.isTerminal ? nil : Timestamp(job.runDeadline)
        queueDeadlineAt = job.state == .queued ? Timestamp(job.queueDeadline) : nil
        termSentAt = Timestamp(job.termSentAt)
        killSentAt = Timestamp(job.killSentAt)
        exitCodeValue =
            job.state.isTerminal ? SimQExitCode.forTerminal(state: job.state, result: job.resultClass).rawValue : nil
        parentID = job.parentID
        dedupeKey = job.dedupeKey
        worktree = job.worktree
        gitSHA = job.gitSHA
        message = job.message
        command = job.command?.argv
        cwd = job.command?.cwd
        environmentKeys = job.command.map { $0.environment.keys.sorted() }.flatMap { $0.isEmpty ? nil : $0 }
        commandExitCode = job.commandExitCode
        resetApps = job.command?.resetApps.flatMap { $0.isEmpty ? nil : $0 }
        freshSim = job.command?.freshSim == true ? true : nil
        logPath = nil
        let queued = job.state == .queued
        position = queued ? explanation?.position : nil
        effectiveScore = queued ? explanation?.effectiveScore : nil
        waitReasons = queued ? (explanation?.reasons.map(WaitReasonInfo.init) ?? []) : []
    }

    public var exitCode: SimQExitCode {
        if cleanupBlocked == true { return .infraFailure }
        return SimQExitCode.forTerminal(state: state, result: resultClass)
    }

    enum CodingKeys: String, CodingKey {
        case id, project, kind, template, submitter, state, attempt, message, position
        case priority, exclusive, retryable
        case command, cwd
        case cleanupPending = "cleanup_pending"
        case cleanupBlocked = "cleanup_blocked"
        case environmentKeys = "environment_keys"
        case commandExitCode = "command_exit_code"
        case logPath = "log_path"
        case maxRetries = "max_retries"
        case resultClass = "result_class"
        case queueTime = "queue_time"
        case admittedAt = "admitted_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case grantedSims = "granted_sims"
        case runTimeoutSeconds = "run_timeout_seconds"
        case queueTimeoutSeconds = "queue_timeout_seconds"
        case runDeadlineAt = "run_deadline_at"
        case queueDeadlineAt = "queue_deadline_at"
        case termSentAt = "term_sent_at"
        case killSentAt = "kill_sent_at"
        case exitCodeValue = "exit_code"
        case parentID = "parent_id"
        case dedupeKey = "dedupe_key"
        case effectiveScore = "effective_score"
        case waitReasons = "wait_reasons"
        case resetApps = "reset_apps"
        case freshSim = "fresh_sim"
        case simPrep = "sim_prep"
        case runDir = "run_dir"
        case artifacts
        case artifactsTruncated = "artifacts_truncated"
        case resultBundles = "result_bundles"
        case sims
        case peakMemoryMiB = "peak_memory_mib"
        case worktree
        case gitSHA = "git_sha"
    }
}

/// One entry in a job's run directory (`SIMQ_RUN_DIR`). Bundles such as `*.xcresult` are a
/// single entry (their total size); the `DerivedData` directory, symlinks and dot files
/// are left out.
public struct ArtifactInfo: Sendable, Equatable, Codable {
    /// Most entries listed per job; `artifacts_truncated` says when more exist.
    public static let listCap = 200

    /// Relative to the run directory, `/`-separated.
    public var path: String
    public var bytes: UInt64
    /// From the extension: `video`, `image`, `xcresult`, `log`, `json`, `text`, `archive`,
    /// `bundle` or `other`.
    public var type: String

    public init(path: String, bytes: UInt64, type: String) {
        self.path = path
        self.bytes = bytes
        self.type = type
    }

    /// The type for a file or bundle name.
    public static func type(forName name: String) -> String {
        let parts = name.split(separator: ".")
        let ext = parts.count > 1 ? (parts.last.map { $0.lowercased() } ?? "") : ""
        switch ext {
        case "mp4", "mov", "m4v": return "video"
        case "png", "jpg", "jpeg", "heic", "gif", "webp": return "image"
        case "xcresult": return "xcresult"
        case "log": return "log"
        case "json", "ndjson", "jsonl": return "json"
        case "txt", "md", "csv", "xml", "junit", "html": return "text"
        case "zip", "tar", "gz", "tgz", "xz": return "archive"
        case "app", "bundle", "framework", "xctest": return "bundle"
        default: return "other"
        }
    }

    /// Directories listed as one entry instead of being walked.
    public static func isBundle(_ name: String) -> Bool {
        ["xcresult", "bundle"].contains(type(forName: name))
    }
}

public struct SubmitResponse: Sendable, Equatable, Codable {
    public var job: JobInfo
    /// True if an active job with the same dedupe key absorbed this submit.
    public var deduplicated: Bool

    public init(job: JobInfo, deduplicated: Bool) {
        self.job = job
        self.deduplicated = deduplicated
    }
}

public struct DaemonInfo: Sendable, Equatable, Codable {
    public var version: String
    public var pid: Int32
    public var epoch: Int64
    public var backend: String
    public var startedAt: Timestamp
    public var statePath: String
    public var socketPath: String
    public var cleanupMode: String
    /// Host probe in use: `fake` or `system`.
    public var probe: String?
    /// Host actions are planned and logged, never run.
    public var dryRun: Bool?

    public init(
        version: String,
        pid: Int32,
        epoch: Int64,
        backend: String,
        startedAt: Double,
        statePath: String,
        socketPath: String,
        cleanupMode: String,
        probe: String? = nil,
        dryRun: Bool? = nil
    ) {
        self.probe = probe
        self.dryRun = dryRun
        self.version = version
        self.pid = pid
        self.epoch = epoch
        self.backend = backend
        self.startedAt = Timestamp(startedAt)
        self.statePath = statePath
        self.socketPath = socketPath
        self.cleanupMode = cleanupMode
    }

    enum CodingKeys: String, CodingKey {
        case version, pid, epoch, backend
        case startedAt = "started_at"
        case statePath = "state_path"
        case socketPath = "socket_path"
        case cleanupMode = "cleanup_mode"
        case probe
        case dryRun = "dry_run"
    }
}

public struct StorageInfo: Sendable, Equatable, Codable {
    public var systemFreeBytes: UInt64?
    public var minimumFreeBytes: UInt64?
    public var stateDirectory: String
    public var jobOutputRoot: String
    public var available: Bool
    public var freeBytes: UInt64?
    public var failure: String?
    public init(
        stateDirectory: String, jobOutputRoot: String, available: Bool, freeBytes: UInt64?, failure: String?,
        systemFreeBytes: UInt64? = nil, minimumFreeBytes: UInt64? = nil
    ) {
        self.systemFreeBytes = systemFreeBytes; self.minimumFreeBytes = minimumFreeBytes
        self.stateDirectory = stateDirectory; self.jobOutputRoot = jobOutputRoot
        self.available = available; self.freeBytes = freeBytes; self.failure = failure
    }
    enum CodingKeys: String, CodingKey {
        case systemFreeBytes = "system_free_bytes"
        case minimumFreeBytes = "minimum_free_bytes"
        case stateDirectory = "state_directory"
        case jobOutputRoot = "job_output_root"
        case available
        case freeBytes = "free_bytes"
        case failure
    }
}

public struct ArtifactStorageInfo: Sendable, Equatable, Codable {
    public var notes: [String]?
    /// Independent of the composition categories: includes protected subtrees too.
    public var protected: [Category]?
    public struct Category: Sendable, Equatable, Codable {
        public var name: String
        public var bytes: UInt64
        public var count: Int
        public var unknownSizes: Int
        public init(name: String, bytes: UInt64 = 0, count: Int = 0, unknownSizes: Int = 0) {
            self.name = name; self.bytes = bytes; self.count = count; self.unknownSizes = unknownSizes
        }
    }
    public var sampledAt: Double
    public var categories: [Category]
    public var candidates: [GCEntry]
    public var candidateCount: Int
    public var reclaimableBytes: UInt64
    public var unknownCandidateSizes: Int
    public var retention: ArtifactRetention
    public var cleanupMode: String
    public var cleanupAt: Double?
    public var removedCount: Int
    public var failureCount: Int
    public var error: String?
    public init(
        sampledAt: Double, categories: [Category], candidates: [GCEntry], candidateCount: Int,
        reclaimableBytes: UInt64, unknownCandidateSizes: Int, retention: ArtifactRetention, cleanupMode: String,
        removedCount: Int = 0, failureCount: Int = 0, error: String? = nil
    ) {
        self.sampledAt = sampledAt; self.categories = categories; self.candidates = candidates
        self.candidateCount = candidateCount; self.reclaimableBytes = reclaimableBytes
        self.unknownCandidateSizes = unknownCandidateSizes; self.retention = retention; self.cleanupMode = cleanupMode
        self.cleanupAt = nil
        self.removedCount = removedCount; self.failureCount = failureCount; self.error = error
    }
}

public struct StatusResult: Sendable, Equatable, Codable {
    public var host: HostSnapshot?
    public var artifactStorage: ArtifactStorageInfo?
    public var lastCleanup: CleanupSummary?
    public var storageReviewRunning: Bool?
    public var storage: StorageInfo?
    public var daemon: DaemonInfo
    public var queued: Int
    public var admitted: Int
    public var running: Int
    public var paused: Bool
    public var draining: Bool
    /// Planned drain has no jobs, leases, process groups or host work left. Nil on older daemons.
    public var drainComplete: Bool?
    public var loadThrottled: Bool
    /// Host-wide reasons currently blocking all admissions.
    public var globalWaitReasons: [WaitReasonInfo]
    public var lastTickAt: Timestamp?
    /// Watchdog health (nil from daemons that predate it).
    public var health: HealthInfo?
    /// Set while a cloning backend has no template: "no template yet, run simq template build".
    public var templateHint: String?

    public init(
        daemon: DaemonInfo,
        queued: Int,
        admitted: Int,
        running: Int,
        paused: Bool,
        draining: Bool,
        loadThrottled: Bool,
        globalWaitReasons: [WaitReasonInfo],
        lastTickAt: Double?,
        health: HealthInfo? = nil,
        templateHint: String? = nil,
        drainComplete: Bool? = nil,
        storage: StorageInfo? = nil, host: HostSnapshot? = nil, artifactStorage: ArtifactStorageInfo? = nil,
        storageReviewRunning: Bool? = nil, lastCleanup: CleanupSummary? = nil
    ) {
        self.lastCleanup = lastCleanup
        self.host = host; self.artifactStorage = artifactStorage; self.storageReviewRunning = storageReviewRunning
        self.storage = storage
        self.templateHint = templateHint
        self.drainComplete = drainComplete
        self.daemon = daemon
        self.queued = queued
        self.admitted = admitted
        self.running = running
        self.paused = paused
        self.draining = draining
        self.loadThrottled = loadThrottled
        self.globalWaitReasons = globalWaitReasons
        self.lastTickAt = Timestamp(lastTickAt)
        self.health = health
    }

    enum CodingKeys: String, CodingKey {
        case daemon, queued, admitted, running, paused, draining, health, storage, host, artifactStorage,
            storageReviewRunning, lastCleanup
        case drainComplete = "drain_complete"
        case loadThrottled = "load_throttled"
        case globalWaitReasons = "global_wait_reasons"
        case lastTickAt = "last_tick_at"
        case templateHint = "template_hint"
        /// `template_hint` before the rename. Sent too (same value), since the wire format
        /// only adds fields; read from an older daemon.
        case legacyTemplateHint = "golden_hint"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastCleanup = try container.decodeIfPresent(CleanupSummary.self, forKey: .lastCleanup)
        host = try container.decodeIfPresent(HostSnapshot.self, forKey: .host)
        artifactStorage = try container.decodeIfPresent(ArtifactStorageInfo.self, forKey: .artifactStorage)
        storageReviewRunning = try container.decodeIfPresent(Bool.self, forKey: .storageReviewRunning)
        storage = try container.decodeIfPresent(StorageInfo.self, forKey: .storage)
        daemon = try container.decode(DaemonInfo.self, forKey: .daemon)
        queued = try container.decode(Int.self, forKey: .queued)
        admitted = try container.decode(Int.self, forKey: .admitted)
        running = try container.decode(Int.self, forKey: .running)
        paused = try container.decode(Bool.self, forKey: .paused)
        draining = try container.decode(Bool.self, forKey: .draining)
        drainComplete = try container.decodeIfPresent(Bool.self, forKey: .drainComplete)
        loadThrottled = try container.decode(Bool.self, forKey: .loadThrottled)
        globalWaitReasons = try container.decode([WaitReasonInfo].self, forKey: .globalWaitReasons)
        lastTickAt = try container.decodeIfPresent(Timestamp.self, forKey: .lastTickAt)
        health = try container.decodeIfPresent(HealthInfo.self, forKey: .health)
        templateHint =
            try container.decodeIfPresent(String.self, forKey: .templateHint)
            ?? container.decodeIfPresent(String.self, forKey: .legacyTemplateHint)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(lastCleanup, forKey: .lastCleanup)
        try container.encodeIfPresent(host, forKey: .host)
        try container.encodeIfPresent(artifactStorage, forKey: .artifactStorage)
        try container.encodeIfPresent(storageReviewRunning, forKey: .storageReviewRunning)
        try container.encodeIfPresent(storage, forKey: .storage)
        try container.encode(daemon, forKey: .daemon)
        try container.encode(queued, forKey: .queued)
        try container.encode(admitted, forKey: .admitted)
        try container.encode(running, forKey: .running)
        try container.encode(paused, forKey: .paused)
        try container.encode(draining, forKey: .draining)
        try container.encodeIfPresent(drainComplete, forKey: .drainComplete)
        try container.encode(loadThrottled, forKey: .loadThrottled)
        try container.encode(globalWaitReasons, forKey: .globalWaitReasons)
        try container.encodeIfPresent(lastTickAt, forKey: .lastTickAt)
        try container.encodeIfPresent(health, forKey: .health)
        try container.encodeIfPresent(templateHint, forKey: .templateHint)
        try container.encodeIfPresent(templateHint, forKey: .legacyTemplateHint)
    }
}

public struct AnomalyInfo: Sendable, Equatable, Codable {
    public var key: String
    public var level: AnomalyLevel
    public var detail: String
    public var firstSeenAt: Timestamp
    public var lastSeenAt: Timestamp
    public var consecutivePasses: Int

    public init(_ record: AnomalyRecord) {
        key = record.key
        level = record.level
        detail = record.detail
        firstSeenAt = Timestamp(record.firstSeenAt)
        lastSeenAt = Timestamp(record.lastSeenAt)
        consecutivePasses = record.consecutivePasses
    }

    enum CodingKeys: String, CodingKey {
        case key, level, detail
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
        case consecutivePasses = "consecutive_passes"
    }
}

public struct DoctorCheck: Sendable, Equatable, Codable {
    public enum Level: String, Sendable, Codable {
        case ok
        case warn
        case fail
    }

    public var name: String
    public var level: Level
    public var detail: String

    public init(name: String, level: Level, detail: String) {
        self.name = name
        self.level = level
        self.detail = detail
    }
}

extension JobInfo {
    /// Fills `sims` and `peak_memory_mib` from what the executor recorded.
    public mutating func attachRunInfo(_ run: JobRunInfo?) {
        guard let run else { return }
        sims = run.sims.isEmpty ? nil : run.sims
        peakMemoryMiB = run.peakResidentBytes.map { (Double($0) / 1_048_576 * 10).rounded() / 10 }
    }
}

/// `simq doctor --json`. Read-only. `owned_udids` is a stable contract for external
/// reapers (sims SimQueue owns, active or awaiting cleanup); it is present even when the
/// daemon is down, read straight from the state file.
/// One pool sim as `simq doctor` shows it.
public struct DoctorPoolSim: Sendable, Equatable, Codable {
    public var udid: String
    public var name: String
    public var phase: String
    /// How long it has been in `phase`.
    public var phaseSeconds: Double
    public var leaseID: String?
    /// In use without a lease (an unleased user): handed to no one until recycled.
    public var tainted: Bool
    /// The template it was cloned from (`udid`, `name`), when recorded.
    public var clonedFrom: TemplateRef?

    public init(
        udid: String, name: String, phase: String, phaseSeconds: Double, leaseID: String?, tainted: Bool,
        clonedFrom: TemplateRef? = nil
    ) {
        self.udid = udid
        self.name = name
        self.phase = phase
        self.phaseSeconds = phaseSeconds
        self.leaseID = leaseID
        self.tainted = tainted
        self.clonedFrom = clonedFrom
    }

    enum CodingKeys: String, CodingKey {
        case udid, name, phase, tainted
        case phaseSeconds = "phase_seconds"
        case leaseID = "lease_id"
        case clonedFrom = "cloned_from"
    }
}

/// The sim pool in `simq doctor` (nil when the pool has never held a sim).
public struct DoctorPool: Sendable, Equatable, Codable {
    public var sims: [DoctorPoolSim]
    /// Sims settling now (never handed out until settled).
    public var settling: [String]
    /// Sims in use without a lease.
    public var unleasedUsers: [String]
    public var settleCapHitsLastHour: Int
    /// The latest `settle_cap_hit` entries, newest first (at most 5).
    public var recentSettleCapHits: [String]

    public init(
        sims: [DoctorPoolSim], settling: [String], unleasedUsers: [String], settleCapHitsLastHour: Int,
        recentSettleCapHits: [String]
    ) {
        self.sims = sims
        self.settling = settling
        self.unleasedUsers = unleasedUsers
        self.settleCapHitsLastHour = settleCapHitsLastHour
        self.recentSettleCapHits = recentSettleCapHits
    }

    enum CodingKeys: String, CodingKey {
        case sims, settling
        case unleasedUsers = "unleased_users"
        case settleCapHitsLastHour = "settle_cap_hits_last_hour"
        case recentSettleCapHits = "recent_settle_cap_hits"
    }
}

public struct DoctorReport: Sendable, Equatable, Codable {
    public var schemaVersion: Int
    /// Nil when the report was built offline from the state file.
    public var daemon: DaemonInfo?
    public var ownedUDIDs: [String]
    public var activeResources: Int
    public var orphanedResources: Int
    public var heartbeatAgeSeconds: Double?
    public var overdueJobs: [String]
    /// Open reconcile anomalies (`sustained` and `needs_human` want attention).
    public var anomalies: [AnomalyInfo]
    public var checks: [DoctorCheck]
    /// Watchdog health, the same verdict `health.json` and `simq status` show.
    public var health: HealthInfo?
    public var pool: DoctorPool?

    public init(
        daemon: DaemonInfo?,
        ownedUDIDs: [String],
        activeResources: Int,
        orphanedResources: Int,
        heartbeatAgeSeconds: Double?,
        overdueJobs: [String],
        anomalies: [AnomalyInfo] = [],
        checks: [DoctorCheck],
        health: HealthInfo? = nil,
        pool: DoctorPool? = nil,
        schemaVersion: Int = Envelope.currentSchemaVersion
    ) {
        self.pool = pool
        self.schemaVersion = schemaVersion
        self.daemon = daemon
        self.ownedUDIDs = ownedUDIDs.sorted()
        self.activeResources = activeResources
        self.orphanedResources = orphanedResources
        self.heartbeatAgeSeconds = heartbeatAgeSeconds
        self.overdueJobs = overdueJobs
        self.anomalies = anomalies
        self.checks = checks
        self.health = health
    }

    /// `simq doctor` exit status: 0 healthy, 1 warnings, 2 unhealthy.
    public var exitStatus: Int32 {
        if checks.contains(where: { $0.level == .fail }) { return 2 }
        if checks.contains(where: { $0.level == .warn }) { return 1 }
        return 0
    }

    public var ownership: DoctorOwnership {
        DoctorOwnership(ownedUDIDs: ownedUDIDs, schemaVersion: schemaVersion)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case daemon, checks, anomalies, health, pool
        case ownedUDIDs = "owned_udids"
        case activeResources = "active_resources"
        case orphanedResources = "orphaned_resources"
        case heartbeatAgeSeconds = "heartbeat_age_seconds"
        case overdueJobs = "overdue_jobs"
    }
}

/// A slice of a job's output log. `data` is UTF-8 text cut on a character boundary
/// (invalid bytes are replaced), so `next_offset` may stop short of `max_bytes`.
public struct LogsResult: Sendable, Equatable, Codable {
    public var jobID: String
    public var path: String
    public var offset: Int64
    public var nextOffset: Int64
    public var data: String
    /// The job is terminal: once `next_offset` reaches the file size, no more output comes.
    public var jobFinished: Bool
    /// True when `next_offset` is the current end of the file.
    public var atEnd: Bool
    /// Present when the daemon honored a tail-window request.
    public var tailBytes: Int?

    public init(
        jobID: String, path: String, offset: Int64, nextOffset: Int64, data: String, jobFinished: Bool, atEnd: Bool,
        tailBytes: Int? = nil
    ) {
        self.jobID = jobID
        self.path = path
        self.offset = offset
        self.nextOffset = nextOffset
        self.data = data
        self.jobFinished = jobFinished
        self.atEnd = atEnd
        self.tailBytes = tailBytes
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case path, offset, data
        case nextOffset = "next_offset"
        case jobFinished = "job_finished"
        case atEnd = "at_end"
        case tailBytes = "tail_bytes"
    }
}

public enum ResultPayload: Sendable, Equatable {
    case submit(SubmitResponse)
    case status(StatusResult)
    case jobs([JobInfo])
    case job(JobInfo)
    case doctor(DoctorReport)
    case logs(LogsResult)
    case lease(LeaseResult)
    case template(TemplateResult)
    case gc(GCResult)
}

public enum ResponseBody: Sendable, Equatable {
    case result(ResultPayload)
    case event(JobInfo)
    case error(ProtocolError)
}

public struct Response: Sendable, Equatable, Codable {
    public var schemaVersion: Int
    /// The request id this answers.
    public var id: String
    public var body: ResponseBody
    /// Answering a legacy `golden_*` request: a template result goes out with the pre-rename
    /// names (`result_kind` `golden`, `goldens`). Never decoded.
    public var usesLegacyTemplateNames = false

    public init(id: String, body: ResponseBody, schemaVersion: Int = Envelope.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.body = body
    }

    public var isFinal: Bool {
        if case .event = body { return false }
        return true
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id, type, result, event, error
        case resultKind = "result_kind"
    }

    private enum ResultKind: String, Codable {
        case submit, status, jobs, job, doctor, logs, lease, template, gc
        /// `template` before the rename: read from an older daemon, and sent to a client
        /// that used a legacy `golden_*` method.
        case legacyTemplate = "golden"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "event":
            body = .event(try container.decode(JobInfo.self, forKey: .event))
        case "error":
            body = .error(try container.decode(ProtocolError.self, forKey: .error))
        case "result":
            switch try container.decode(ResultKind.self, forKey: .resultKind) {
            case .submit: body = .result(.submit(try container.decode(SubmitResponse.self, forKey: .result)))
            case .status: body = .result(.status(try container.decode(StatusResult.self, forKey: .result)))
            case .jobs: body = .result(.jobs(try container.decode([JobInfo].self, forKey: .result)))
            case .job: body = .result(.job(try container.decode(JobInfo.self, forKey: .result)))
            case .doctor: body = .result(.doctor(try container.decode(DoctorReport.self, forKey: .result)))
            case .logs: body = .result(.logs(try container.decode(LogsResult.self, forKey: .result)))
            case .lease: body = .result(.lease(try container.decode(LeaseResult.self, forKey: .result)))
            case .template, .legacyTemplate:
                body = .result(.template(try container.decode(TemplateResult.self, forKey: .result)))
            case .gc: body = .result(.gc(try container.decode(GCResult.self, forKey: .result)))
            }
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown response type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        switch body {
        case .event(let job):
            try container.encode("event", forKey: .type)
            try container.encode(job, forKey: .event)
        case .error(let error):
            try container.encode("error", forKey: .type)
            try container.encode(error, forKey: .error)
        case .result(let payload):
            try container.encode("result", forKey: .type)
            switch payload {
            case .submit(let value):
                try container.encode(ResultKind.submit, forKey: .resultKind)
                try container.encode(value, forKey: .result)
            case .status(let value):
                try container.encode(ResultKind.status, forKey: .resultKind)
                try container.encode(value, forKey: .result)
            case .jobs(let value):
                try container.encode(ResultKind.jobs, forKey: .resultKind)
                try container.encode(value, forKey: .result)
            case .job(let value):
                try container.encode(ResultKind.job, forKey: .resultKind)
                try container.encode(value, forKey: .result)
            case .doctor(let value):
                try container.encode(ResultKind.doctor, forKey: .resultKind)
                try container.encode(value, forKey: .result)
            case .logs(let value):
                try container.encode(ResultKind.logs, forKey: .resultKind)
                try container.encode(value, forKey: .result)
            case .lease(let value):
                try container.encode(ResultKind.lease, forKey: .resultKind)
                try container.encode(value, forKey: .result)
            case .template(let value) where usesLegacyTemplateNames:
                try container.encode(ResultKind.legacyTemplate, forKey: .resultKind)
                try container.encode(LegacyTemplateResult(result: value), forKey: .result)
            case .template(let value):
                try container.encode(ResultKind.template, forKey: .resultKind)
                try container.encode(value, forKey: .result)
            case .gc(let value):
                try container.encode(ResultKind.gc, forKey: .resultKind)
                try container.encode(value, forKey: .result)
            }
        }
    }
}

// MARK: - Framing

/// One JSON object per line. Sorted keys keep output stable for diffs and tests.
public enum LineCodec {
    /// Lines longer than this are rejected (protects the daemon from a runaway client).
    public static let maxLineBytes = 1 << 20

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}

// MARK: - Durations

/// Parses "90", "90s", "10m", "1h", "1h30m" into seconds.
public enum DurationParser {
    public static func seconds(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if let plain = Double(trimmed), plain >= 0 {
            return plain
        }
        var total = 0.0
        var number = ""
        for character in trimmed {
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            guard let value = Double(number) else { return nil }
            switch character {
            case "s": total += value
            case "m": total += value * 60
            case "h": total += value * 3600
            default: return nil
            }
            number = ""
        }
        guard number.isEmpty else { return nil }
        return total
    }
}

public struct BreakerInfo: Sendable, Equatable, Codable {
    /// `closed`, `open` or `half-open`.
    public var state: String
    public var reason: String?
    public var openedAt: Timestamp?

    public init(_ breaker: BreakerState) {
        state = breaker.phase.rawValue
        reason = breaker.reason
        openedAt = Timestamp(breaker.openedAt)
    }

    enum CodingKeys: String, CodingKey {
        case state, reason
        case openedAt = "opened_at"
    }
}

/// Watchdog health: the body of `health.json` (rewritten after every pass) and the
/// `health` field of `simq status` and `simq doctor`. Additive changes only.
public struct HealthInfo: Sendable, Equatable, Codable {
    public var schemaVersion: Int
    /// `ok`, `degraded` or `breaker_open`.
    public var health: String
    public var reasons: [String]
    public var generatedAt: Timestamp
    public var cleanupMode: String
    public var breaker: BreakerInfo
    public var lastPassID: String?
    /// `light` or `full`.
    public var lastPassKind: String?
    public var lastPassAt: Timestamp?
    public var lastFullPassAt: Timestamp?
    public var sustainedAnomalies: Int
    public var needsHumanAnomalies: Int
    /// Cleanups the per-pass or hourly limit postponed to a later pass (not a problem).
    public var postponedActions: Int
    public var notes: [String]
    /// Local health alerts seen in the last 7 days, newest first.
    public var alerts: [AlertInfo]
    /// Legacy wire field; current health alerts remain local.
    public var alertDelivery: String
    /// Why the last attempted watchdog pass failed; nil once a pass completes.
    public var lastPassError: String?

    public init(
        summary: HealthSummary, state: WatchdogState, anomalies: [AnomalyRecord], cleanupMode: String, now: Double,
        alerts: [AlertInfo] = [], alertDelivery: String = "none", schemaVersion: Int = Envelope.currentSchemaVersion
    ) {
        self.alerts = alerts
        self.alertDelivery = alertDelivery
        self.schemaVersion = schemaVersion
        health = summary.level.rawValue
        reasons = summary.reasons
        generatedAt = Timestamp(now)
        self.cleanupMode = cleanupMode
        breaker = BreakerInfo(state.breaker)
        lastPassID = state.lastPassID
        lastPassKind = state.lastPassKind?.rawValue
        lastPassAt = Timestamp(state.lastPassAt)
        lastFullPassAt = Timestamp(state.lastFullPassAt)
        sustainedAnomalies = anomalies.filter { $0.level == .sustained }.count
        needsHumanAnomalies = anomalies.filter { $0.level == .needsHuman }.count
        postponedActions = state.postponedTargets.count
        notes = summary.notes
        lastPassError = state.lastPassError
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        health = try container.decode(String.self, forKey: .health)
        reasons = try container.decode([String].self, forKey: .reasons)
        generatedAt = try container.decode(Timestamp.self, forKey: .generatedAt)
        cleanupMode = try container.decode(String.self, forKey: .cleanupMode)
        breaker = try container.decode(BreakerInfo.self, forKey: .breaker)
        lastPassID = try container.decodeIfPresent(String.self, forKey: .lastPassID)
        lastPassKind = try container.decodeIfPresent(String.self, forKey: .lastPassKind)
        lastPassAt = try container.decodeIfPresent(Timestamp.self, forKey: .lastPassAt)
        lastFullPassAt = try container.decodeIfPresent(Timestamp.self, forKey: .lastFullPassAt)
        sustainedAnomalies = try container.decode(Int.self, forKey: .sustainedAnomalies)
        needsHumanAnomalies = try container.decode(Int.self, forKey: .needsHumanAnomalies)
        postponedActions = try container.decodeIfPresent(Int.self, forKey: .postponedActions) ?? 0
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        alerts = try container.decodeIfPresent([AlertInfo].self, forKey: .alerts) ?? []
        alertDelivery = try container.decodeIfPresent(String.self, forKey: .alertDelivery) ?? "none"
        lastPassError = try container.decodeIfPresent(String.self, forKey: .lastPassError)
    }

    /// The `simq status` line: `health: ok`, `health: degraded (<reasons>)` or
    /// `health: breaker open (<reason>)`, plus the age of the last watchdog pass.
    public func line(now: Double) -> String {
        var text: String
        switch health {
        case HealthLevel.breakerOpen.rawValue: text = "health: breaker open (\(breaker.reason ?? "unknown"))"
        case HealthLevel.degraded.rawValue: text = "health: degraded (\(reasons.joined(separator: "; ")))"
        default: text = "health: \(health)"
        }
        for note in notes { text += "; \(note)" }
        if let lastPassAt {
            text += "; last watchdog pass \(Self.age(now - lastPassAt.epochSeconds)) ago"
        } else {
            text += "; no watchdog pass yet"
        }
        return text
    }

    static func age(_ seconds: Double) -> String {
        let seconds = max(0, Int(seconds))
        if seconds < 120 { return "\(seconds)s" }
        if seconds < 7200 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }

    enum CodingKeys: String, CodingKey {
        case health, reasons, breaker
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case cleanupMode = "cleanup_mode"
        case lastPassID = "last_pass_id"
        case lastPassKind = "last_pass_kind"
        case lastPassAt = "last_pass_at"
        case lastFullPassAt = "last_full_pass_at"
        case sustainedAnomalies = "sustained_anomalies"
        case needsHumanAnomalies = "needs_human_anomalies"
        case postponedActions = "postponed_actions"
        case notes, alerts
        case alertDelivery = "alert_delivery"
        case lastPassError = "last_pass_error"
    }
}

/// One alert in `health.json` (and `status`/`doctor` `health`).
public struct AlertInfo: Sendable, Equatable, Codable {
    public var key: String
    /// `warn` or `page`.
    public var level: String
    public var title: String
    public var detail: String
    public var count: Int
    public var needsHuman: Bool
    public var firstSeenAt: Timestamp
    public var lastSeenAt: Timestamp
    public var issueURL: String?
    /// `delivered`, or `pending` (owed to the configured sink, or kept here when none is set).
    public var delivery: String
    public var lastError: String?
    /// When the alert's condition cleared for good (its issue is closed); nil while open.
    public var resolvedAt: Timestamp?

    public init(_ record: AlertRecord) {
        key = record.key
        level = record.level.rawValue
        title = record.title
        detail = record.detail
        count = record.count
        needsHuman = record.needsHuman
        firstSeenAt = Timestamp(record.firstSeenAt)
        lastSeenAt = Timestamp(record.lastSeenAt)
        issueURL = nil
        delivery = "local"
        lastError = nil
        resolvedAt = record.resolvedAt.map(Timestamp.init)
    }

    enum CodingKeys: String, CodingKey {
        case key, level, title, detail, count, delivery
        case needsHuman = "needs_human"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
        case issueURL = "issue_url"
        case lastError = "last_error"
        case resolvedAt = "resolved_at"
    }
}

private enum RemovedSubmitKeys: String, CodingKey {
    case shards, shardRetries = "shard_retries", buildCommand = "build_command", buildTimeout = "build_timeout_seconds"
}
