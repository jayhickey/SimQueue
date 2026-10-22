// SPDX-License-Identifier: MIT

import Foundation

/// What a job runs (spec section 5b).
/// The job's `kind` is a free-form label (`"build"`, `"lint"`, anything) shown in status,
/// logs and metrics. SimQueue gives no label special meaning: behavior comes from the
/// job's own flags (`exclusive`, `retryable`, sims), never from its kind.
public enum JobKindLabel {
    /// Longest label, in characters (what a reader counts, not bytes).
    public static let maxLength = 100

    /// What a valid label may contain, for error messages.
    public static let rule =
        "at most \(maxLength) characters, with no control characters or line breaks and not only spaces"

    /// The label as stored: surrounding spaces trimmed. Nil when it can't be a label (see
    /// `isValid`). Empty stays empty (no label).
    public static func normalized(_ label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return label.isEmpty ? "" : nil }
        return isValid(trimmed) ? trimmed : nil
    }

    /// Empty, or up to 100 characters of printable text, e.g. `Quotify PR #134 · Unit tests`.
    /// No control characters (tabs, newlines, escapes), line or paragraph separators, or
    /// bidirectional overrides that could disguise how it reads; no surrounding whitespace.
    /// The label is only ever shown (status, logs, dashboard, `SIMQ_KIND`), never used in a
    /// path, so anything readable is fine.
    public static func isValid(_ label: String) -> Bool {
        if label.isEmpty { return true }
        guard label.count <= maxLength, label.trimmingCharacters(in: .whitespaces) == label else { return false }
        return label.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned: return false
            default: return !(0x202A...0x202E).contains(scalar.value) && !(0x2066...0x2069).contains(scalar.value)
            }
        }
    }
}

/// Lifecycle states (spec section 5b).
public enum JobState: String, Sendable, Codable, CaseIterable {
    case queued
    case admitted
    case running
    case succeeded
    case failed
    case canceled
    case interrupted
    case infraFailed = "infra_failed"
    /// Ran longer than its run timeout and was stopped (SIGTERM, then SIGKILL).
    case timedOut = "timed_out"
    /// Waited in the queue longer than its queue timeout and never started.
    case expired

    public var isTerminal: Bool {
        switch self {
        case .queued, .admitted, .running: return false
        default: return true
        }
    }

    /// Admitted or running: holds resources.
    public var isActive: Bool { self == .admitted || self == .running }
}

/// Result classes borrowed from XCSteward. Infra failures never look like test failures.
public enum ResultClass: String, Sendable, Codable, CaseIterable {
    case success
    case buildFailure = "build_failure"
    case testFailure = "test_failure"
    case testTimeout = "test_timeout"
    case runnerBootstrapFailure = "runner_bootstrap_failure"
    case artifactFailure = "artifact_failure"
    case canceled
    /// The job's run timeout expired; the daemon stopped it. Not an infra failure.
    case runTimeout = "run_timeout"
    /// The job's queue timeout expired before it started. Not an infra failure: the host
    /// is busy, not broken.
    case queueTimeout = "queue_timeout"
    /// The job's own command exited non-zero or was killed by a signal it didn't get from
    /// SimQueue. The command's status is kept in `command_exit_code`. Not an infra failure.
    case commandFailure = "command_failure"
    case internalError = "internal_error"

    /// Counted by the infra-failure drain.
    public var isInfraFailure: Bool {
        switch self {
        case .runnerBootstrapFailure, .artifactFailure, .internalError: return true
        default: return false
        }
    }

    /// The terminal state a job ends in for this result (before any infra retry).
    public var terminalState: JobState {
        switch self {
        case .success: return .succeeded
        case .buildFailure, .testFailure, .testTimeout, .commandFailure: return .failed
        case .canceled: return .canceled
        case .runTimeout: return .timedOut
        case .queueTimeout: return .expired
        case .runnerBootstrapFailure, .artifactFailure, .internalError: return .infraFailed
        }
    }
}

/// The command a job runs (`simq submit -- <argv...>`). SimQueue runs it as-is, in its own
/// process group, with `cwd` as its working directory; nothing about the command is
/// interpreted. `environment` is added on top of the daemon's own environment.
public struct JobCommand: Sendable, Codable, Equatable {
    public var argv: [String]
    public var environment: [String: String]
    /// Working directory; nil means the daemon's own working directory.
    public var cwd: String?
    /// Apps to reset on each leased sim before the command runs (`--reset-app`). Nil: none.
    public var resetApps: [String]?
    /// Erase each leased sim before the command runs (`--fresh-sim`). Nil: no.
    public var freshSim: Bool?
    /// Selected host template label, persisted with the command.
    public var template: String?
    /// Daemon-assigned output root; nil on legacy jobs.
    public var artifactsRoot: String?

    /// Whether the job asks for any sim preparation.
    public var wantsSimPrep: Bool { freshSim == true || !(resetApps ?? []).isEmpty }

    public static let maxArguments = 4096
    public static let maxTotalBytes = 256 * 1024
    /// Variables the daemon sets for every job; a job may not override them.
    public static let reservedEnvironmentPrefix = "SIMQ_"

    public init(
        argv: [String], environment: [String: String] = [:], cwd: String? = nil, resetApps: [String]? = nil,
        freshSim: Bool? = nil
    ) {
        self.argv = argv
        self.environment = environment
        self.cwd = cwd
        self.resetApps = resetApps
        self.freshSim = freshSim
    }

    /// Nil if the command is acceptable, else a reason it isn't.
    public var validationError: String? {
        guard let first = argv.first, !first.isEmpty else {
            return "command must not be empty"
        }
        guard argv.count <= Self.maxArguments else {
            return "command has more than \(Self.maxArguments) arguments"
        }
        let pieces = argv + environment.keys + environment.values + [cwd ?? ""]
        guard !pieces.contains(where: { $0.utf8.contains(0) }) else {
            return "command, environment and cwd must not contain NUL bytes"
        }
        guard pieces.reduce(0, { $0 + $1.utf8.count }) <= Self.maxTotalBytes else {
            return "command and environment exceed \(Self.maxTotalBytes) bytes"
        }
        for key in environment.keys.sorted() {
            guard Self.isValidEnvironmentName(key) else {
                return "environment name \"\(key)\" must match [A-Za-z_][A-Za-z0-9_]*"
            }
            guard !key.hasPrefix(Self.reservedEnvironmentPrefix) else {
                return "environment name \"\(key)\" is reserved (SIMQ_* is set by the daemon)"
            }
        }
        if let cwd, !cwd.hasPrefix("/") {
            return "cwd must be an absolute path"
        }
        if let apps = resetApps {
            guard apps.count <= SimPrep.maxResetApps else {
                return "at most \(SimPrep.maxResetApps) reset_apps entries"
            }
            if let bad = apps.first(where: { !SimPrep.isValidBundleID($0) }) {
                return "reset_apps entry \"\(bad)\" is not a bundle id (letters, digits, . and -)"
            }
        }
        return nil
    }

    public static func isValidEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        func isLetter(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || scalar == "_"
        }
        return isLetter(first) && name.unicodeScalars.allSatisfy { isLetter($0) || ("0"..."9").contains($0) }
    }
}

/// What a job asks for. Simulator count is a min...max range; the scheduler grants the
/// largest count in range that fits right now.
public struct ResourceRequest: Sendable, Codable, Equatable {
    public var minSims: Int
    public var maxSims: Int
    /// Host-side memory the job itself needs (for example an `xcodebuild` tree).
    public var memoryBytes: UInt64
    /// Extra memory per granted simulator while the job runs (the app under test).
    public var memoryBytesPerSim: UInt64

    public init(minSims: Int = 0, maxSims: Int? = nil, memoryBytes: UInt64 = 0, memoryBytesPerSim: UInt64 = 0) {
        let lower = max(0, minSims)
        self.minSims = lower
        self.maxSims = max(lower, maxSims ?? lower)
        self.memoryBytes = memoryBytes
        self.memoryBytesPerSim = memoryBytesPerSim
    }

    public var needsSims: Bool { maxSims > 0 }
}

/// A job as stored and scheduled.
public struct Job: Sendable, Equatable, Codable {
    /// Human-readable id, e.g. `J-0142`.
    public var id: String
    /// Monotonic submit sequence. Final tie-breaker, like Buildkite's internal id.
    public var sequence: Int64
    public var project: String
    /// Free-form label for status, logs and metrics. No behavior depends on it.
    public var kind: String
    public var priority: Int
    public var submitter: String
    public var worktree: String?
    public var gitSHA: String?
    public var dedupeKey: String?
    public var resources: ResourceRequest
    /// Takes the single exclusive slot (`max_concurrent_exclusive`, default 1): exclusive
    /// jobs run one at a time, for example builds that saturate the machine.
    public var exclusive: Bool
    /// May be retried automatically after an infra failure. Off by default: a non-retryable
    /// job that hits an infra failure ends `infra_failed`. After restart, started work
    /// requires explicit retry permission and remaining budget; unknown starts are not replayed.
    public var retryable: Bool
    /// Infra retries allowed for a retryable job. Nil: the daemon default (1).
    public var maxRetries: Int?
    /// Run wall-time limit, measured from job start (`started_at`). Time spent admitted
    /// (sim boot) doesn't count. Nil means no limit.
    public var runTimeoutSeconds: Double?
    /// Longest the job may wait in the queue before its first start. Measured from
    /// `created_at` to admission; applies only to a first attempt, so a job requeued after
    /// a crash or infra retry is never expired for time it already waited. Nil means no
    /// limit.
    public var queueTimeoutSeconds: Double?
    /// When the daemon sent SIGTERM because the run timeout passed (persisted, so a
    /// restarted daemon keeps the same kill schedule).
    public var termSentAt: Double?
    /// When the daemon escalated to SIGKILL.
    public var killSentAt: Double?
    public var parentID: String?
    /// Caller payload as JSON; retained history is not interpreted as orchestration.
    public var payloadJSON: String?
    /// What the process executor runs. Nil for jobs that only hold resources or run on
    /// the fake executor.
    public var command: JobCommand?
    /// The command's own exit status once it ended: its exit code, or 128 + signal number
    /// if a signal killed it (the shell convention). Nil if it never ran or never ended.
    public var commandExitCode: Int32?
    /// Retry attempt, 0 for the first run. Counts infra retries and restart requeues.
    public var attempt: Int
    /// How many of `attempt` were requeues after a daemon restart (`daemon_restart`). They
    /// have their own cap and never use up the job's infra retries (`max_retries`).
    public var restartRequeues: Int
    /// The time this job's place in the queue is measured from. Retries
    /// inherit their parent's queue time, so they never fall behind newer jobs.
    public var queueTime: Double
    public var createdAt: Double
    public var admittedAt: Double?
    public var startedAt: Double?
    public var finishedAt: Double?
    public var state: JobState
    public var resultClass: ResultClass?
    public var grantedSims: Int
    public var ownerPID: Int32?
    /// Daemon lease epoch that admitted this job (fencing).
    public var ownerEpoch: Int64?
    /// Fencing token issued when the job was admitted. Strictly increasing across all
    /// grants; a holder presenting an older token is rejected.
    public var fenceToken: Int64?
    public var message: String?

    public init(
        id: String,
        sequence: Int64,
        project: String,
        kind: String = "",
        priority: Int = Priority.defaultValue,
        submitter: String,
        worktree: String? = nil,
        gitSHA: String? = nil,
        dedupeKey: String? = nil,
        resources: ResourceRequest = ResourceRequest(),
        exclusive: Bool = false,
        retryable: Bool = false,
        maxRetries: Int? = nil,
        runTimeoutSeconds: Double? = nil,
        queueTimeoutSeconds: Double? = nil,
        parentID: String? = nil,
        payloadJSON: String? = nil,
        command: JobCommand? = nil,
        commandExitCode: Int32? = nil,
        attempt: Int = 0,
        restartRequeues: Int = 0,
        queueTime: Double,
        createdAt: Double,
        admittedAt: Double? = nil,
        startedAt: Double? = nil,
        finishedAt: Double? = nil,
        state: JobState = .queued,
        resultClass: ResultClass? = nil,
        grantedSims: Int = 0,
        ownerPID: Int32? = nil,
        ownerEpoch: Int64? = nil,
        fenceToken: Int64? = nil,
        termSentAt: Double? = nil,
        killSentAt: Double? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.project = project
        self.kind = kind
        self.priority = priority
        self.submitter = submitter
        self.worktree = worktree
        self.gitSHA = gitSHA
        self.dedupeKey = dedupeKey
        self.resources = resources
        self.exclusive = exclusive
        self.retryable = retryable
        self.maxRetries = maxRetries
        self.runTimeoutSeconds = runTimeoutSeconds
        self.queueTimeoutSeconds = queueTimeoutSeconds
        self.parentID = parentID
        self.payloadJSON = payloadJSON
        self.command = command
        self.commandExitCode = commandExitCode
        self.attempt = attempt
        self.restartRequeues = restartRequeues
        self.queueTime = queueTime
        self.createdAt = createdAt
        self.admittedAt = admittedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.state = state
        self.resultClass = resultClass
        self.grantedSims = grantedSims
        self.ownerPID = ownerPID
        self.ownerEpoch = ownerEpoch
        self.fenceToken = fenceToken
        self.termSentAt = termSentAt
        self.killSentAt = killSentAt
        self.message = message
    }
}

/// What a client submits. The store assigns id, sequence and times.
public struct JobSubmission: Sendable, Equatable {
    public var project: String
    public var kind: String
    public var priority: Int
    public var submitter: String
    public var worktree: String?
    public var gitSHA: String?
    public var dedupeKey: String?
    public var resources: ResourceRequest
    public var exclusive: Bool
    public var retryable: Bool
    public var maxRetries: Int?
    public var runTimeoutSeconds: Double?
    public var queueTimeoutSeconds: Double?
    public var payloadJSON: String?
    public var command: JobCommand?

    public init(
        project: String,
        kind: String = "",
        priority: Int = Priority.defaultValue,
        submitter: String,
        worktree: String? = nil,
        gitSHA: String? = nil,
        dedupeKey: String? = nil,
        resources: ResourceRequest = ResourceRequest(),
        exclusive: Bool = false,
        retryable: Bool = false,
        maxRetries: Int? = nil,
        runTimeoutSeconds: Double? = nil,
        queueTimeoutSeconds: Double? = nil,
        payloadJSON: String? = nil,
        command: JobCommand? = nil
    ) {
        self.project = project
        self.kind = kind
        self.priority = priority
        self.submitter = submitter
        self.worktree = worktree
        self.gitSHA = gitSHA
        self.dedupeKey = dedupeKey
        self.resources = resources
        self.exclusive = exclusive
        self.retryable = retryable
        self.maxRetries = maxRetries
        self.runTimeoutSeconds = runTimeoutSeconds
        self.queueTimeoutSeconds = queueTimeoutSeconds
        self.payloadJSON = payloadJSON
        self.command = command
    }
}

extension Job {
    /// When the run timeout expires: `started_at` plus the run timeout. Time spent
    /// admitted but not yet started (sim boot) doesn't count. Nil before start or without
    /// a limit.
    public var runDeadline: Double? {
        guard let start = startedAt, let runTimeoutSeconds else {
            return nil
        }
        return start + runTimeoutSeconds
    }

    /// When a queued first attempt expires, if it has a queue timeout.
    public var queueDeadline: Double? {
        guard attempt == 0, let queueTimeoutSeconds else {
            return nil
        }
        return createdAt + queueTimeoutSeconds
    }

    public func isQueueExpired(now: Double) -> Bool {
        guard state == .queued, let deadline = queueDeadline else {
            return false
        }
        return now >= deadline
    }

    public func isRunTimedOut(now: Double) -> Bool {
        guard state.isActive, let deadline = runDeadline else {
            return false
        }
        return now >= deadline
    }
}

/// Client-side wait budget (`--wait-timeout`, exit 7). It only bounds how long one client
/// waits; giving up never changes the job. Server-side limits are the job's queue and
/// run timeouts.
public struct ClientWait: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case keepWaiting
        case admitted
        case finished(JobState)
        case stoppedWaiting
    }

    public var timeoutSeconds: Double?
    public var startedAt: Double

    public init(timeoutSeconds: Double?, startedAt: Double) {
        self.timeoutSeconds = timeoutSeconds
        self.startedAt = startedAt
    }

    public func outcome(for job: Job, now: Double) -> Outcome {
        if job.state.isTerminal {
            return .finished(job.state)
        }
        if job.state.isActive {
            return .admitted
        }
        if let timeoutSeconds, now - startedAt >= timeoutSeconds {
            return .stoppedWaiting
        }
        return .keepWaiting
    }
}

/// Timeout defaults applied at submit, and the kill schedule for run timeouts.
///
/// A value of 0 means "no limit", both here and per job (`--timeout none` and
/// `--queue-timeout none` send 0). A per-job nil means "use the default".
public struct TimeoutConfig: Sendable, Equatable, Codable {
    /// Default queue timeout: 24 hours.
    public static let standardQueueTimeoutSeconds: Double = 24 * 60 * 60

    /// Run timeout for jobs that don't pass `--timeout`. Nil or 0: no limit (the default).
    public var defaultRunTimeoutSeconds: Double?
    /// Queue timeout for jobs that don't pass `--queue-timeout`. Defaults to 24 h; nil or
    /// 0 means no limit.
    public var defaultQueueTimeoutSeconds: Double?
    /// Time between SIGTERM and SIGKILL when a run timeout fires. Placeholder: 10 s.
    public var killGraceSeconds: Double

    public init(
        defaultRunTimeoutSeconds: Double? = nil,
        defaultQueueTimeoutSeconds: Double? = TimeoutConfig.standardQueueTimeoutSeconds,
        killGraceSeconds: Double = 10
    ) {
        self.defaultRunTimeoutSeconds = defaultRunTimeoutSeconds
        self.defaultQueueTimeoutSeconds = defaultQueueTimeoutSeconds
        self.killGraceSeconds = killGraceSeconds
    }

    /// Resolves one timeout: per-job value if given, else the default; 0 becomes nil
    /// (no limit).
    public static func resolve(_ perJob: Double?, default fallback: Double?) -> Double? {
        let value = perJob ?? fallback
        guard let value, value != 0 else {
            return nil
        }
        return value
    }

    /// Fills unset timeouts from the defaults and turns 0 ("no limit") into nil.
    public func apply(to submission: JobSubmission) -> JobSubmission {
        var copy = submission
        copy.runTimeoutSeconds = Self.resolve(submission.runTimeoutSeconds, default: defaultRunTimeoutSeconds)
        copy.queueTimeoutSeconds = Self.resolve(submission.queueTimeoutSeconds, default: defaultQueueTimeoutSeconds)
        return copy
    }
}
