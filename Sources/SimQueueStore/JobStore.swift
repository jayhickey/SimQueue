// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore

public enum JobStoreError: Error, Equatable, CustomStringConvertible {
    case queueFull(submitter: String, project: String, limit: Int)
    /// The whole queue would go over `max_queued_total`.
    case queueFullTotal(limit: Int, adding: Int)
    case jobNotFound(String)
    case invalidTransition(jobID: String, from: JobState, action: String)
    case corruptRow(String)
    case staleFence(jobID: String, presented: Int64, current: Int64?)
    case staleEpoch(presented: Int64, current: Int64?)
    case invalidPriority(Int)
    case invalidTimeout(Double)
    case invalidKind(String)
    case invalidRetries(Int)
    case invalidCommand(String)
    case alreadyOwned(kind: OwnedResourceKind, externalID: String)
    case resourceNotFound(Int64)

    public var description: String {
        switch self {
        case .queueFull(let submitter, let project, let limit):
            return "queue_full: \(submitter) already has \(limit) queued jobs for \(project)"
        case .queueFullTotal(let limit, let adding):
            return "queue_full: adding \(adding) queued jobs would go over the queue cap of \(limit)"
        case .jobNotFound(let id): return "job \(id) not found"
        case .invalidTransition(let id, let from, let action):
            return "cannot \(action) job \(id) in state \(from.rawValue)"
        case .corruptRow(let detail): return "corrupt job row: \(detail)"
        case .staleFence(let id, let presented, let current):
            return "stale fencing token \(presented) for job \(id) (current \(current.map(String.init) ?? "none"))"
        case .invalidTimeout(let value):
            return "timeout \(value) must be a positive number of seconds"
        case .invalidKind(let value):
            return "kind \"\(value)\" must be \(JobKindLabel.rule)"
        case .invalidRetries(let value):
            return "max retries \(value) is outside 0...\(JobStore.maxRetriesLimit)"
        case .invalidCommand(let reason): return "invalid command: \(reason)"
        case .invalidPriority(let value):
            return "priority \(value) is outside \(Priority.range.lowerBound)...\(Priority.range.upperBound)"
        case .staleEpoch(let presented, let current):
            return "stale daemon epoch \(presented) (current \(current.map(String.init) ?? "none"))"
        case .alreadyOwned(let kind, let externalID): return "\(kind.rawValue) \(externalID) already has a live owner"
        case .resourceNotFound(let id): return "owned resource \(id) not found"
        }
    }
}

/// Steps of the run-timeout kill schedule.
public enum TerminationStep: Sendable, Equatable {
    case term
    case kill
}

public enum SubmitResult: Equatable, Sendable {
    case created(Job)
    /// A non-terminal job with the same request key already exists; the caller attaches to it.
    case deduplicated(Job)

    public var job: Job {
        switch self {
        case .created(let job), .deduplicated(let job): return job
        }
    }
}

/// What startup recovery did.
public struct RecoveryReport: Equatable, Sendable {
    /// Jobs put back in the queue at their original position (`daemon_restart`).
    public var requeued: [String] = []
    /// Jobs marked `interrupted`: their command may still be running (see `stillRunning`).
    public var interrupted: [String] = []
    /// Jobs that hit `maxRestartRequeues` and ended `infra_failed` instead of a requeue.
    public var restartCapReached: [String] = []
    /// Process ids recorded for recovered jobs. The daemon kills their process groups
    /// (a later phase); the store only reports them.
    public var orphanPIDs: [Int32] = []
    /// Jobs whose run deadline passed while no daemon was running; the engine stops them.
    public var timeoutPending: [String] = []
    /// Jobs whose process group was still alive after the restart (one recovery couldn't
    /// verify as SimQueue's own, so it wasn't stopped). They are marked `interrupted`,
    /// because requeueing would run the command twice at once. The process group is left
    /// alone and its resource is reported by reconcile.
    public var stillRunning: [String] = []
    /// Process groups of recovered jobs that were verified as SimQueue's own (leader
    /// start time matched) and stopped before recovery (set by `Engine.start`).
    public var killedProcessGroups: [Int32] = []
    /// Process groups found by their write-ahead spawn token because the previous daemon
    /// died before recording their pid (set by `Engine.start`).
    public var resolvedSpawnIntents: [Int32] = []

    public init(requeued: [String] = [], interrupted: [String] = [], orphanPIDs: [Int32] = []) {
        self.requeued = requeued
        self.interrupted = interrupted
        self.orphanPIDs = orphanPIDs
    }
}

/// SQLite-backed job state. The single writer of record: every transition is a
/// transaction, and claims are fenced by the daemon lease epoch.
public final class JobStore {
    public let database: Database
    /// Max runner-bootstrap retries at the same queue position (spec section 5h: once).
    /// Default infra retries for a retryable job that doesn't set its own count.
    public var maxInfraRetries: Int
    /// Upper bound on a job's own retry count.
    public static let maxRetriesLimit = 10
    /// Default for `maxRestartRequeues`.
    public static let defaultMaxRestartRequeues = 3
    /// Requeues after a daemon restart allowed per job, on top of its infra retries. A job
    /// caught by more restarts than this ends `infra_failed` (`internal_error`), so a job
    /// that crashes the daemon can't loop forever.
    public var maxRestartRequeues = JobStore.defaultMaxRestartRequeues
    /// Queued independent jobs per submitter and project; 0 disables this cap.
    public var maxQueuedPerSubmitterPerProject: Int
    /// Queued jobs in total; 0 disables this cap.
    public var maxQueuedTotal = 1024
    /// Watchdog pass in progress; every audit entry written meanwhile carries it.
    public var currentPassID: String?
    /// How often an unchanged anomaly row is re-confirmed in the database (its pass
    /// counter and last-seen time). Level, detail and clean/dirty changes are written at
    /// once; in between, the in-process copy is the truth.
    public var anomalyReconfirmSeconds: Double = 6 * 3600
    /// In-process anomaly book (key -> record) and what the database last got.
    var anomalyCache: [String: AnomalyRecord]? {
        didSet { anomalySorted = nil }
    }
    var anomalyPersisted: [String: AnomalyRecord] = [:]
    /// Write-through copies of the live ownership rows and the cleanup sightings, so a pass
    /// over leftovers that haven't changed doesn't re-read them. Rebuilt after a rollback.
    var liveCache: [Int64: OwnedResource]? {
        didSet { liveSorted = nil }
    }
    var liveSorted: [OwnedResource]?
    /// The same live rows split by kind (kept in step with `liveCache`), each with a sorted
    /// copy built on demand, so a pass over a few kinds doesn't walk every leftover.
    var liveByKind: [OwnedResourceKind: [Int64: OwnedResource]] = [:]
    var liveKindSorted: [OwnedResourceKind: [OwnedResource]] = [:]
    var anomalySorted: [AnomalyRecord]?
    /// Sightings bucketed by key prefix, plus a flattened copy built on demand.
    var sightingCache: PrefixBuckets<Sighting>? {
        didSet { sightingFlat = nil }
    }
    var sightingFlat: [String: Sighting]?
    var cacheRollbackCount = 0
    var cacheDataVersion: Int64?
    /// Write-through copy of the alert book (key -> record).
    var alertCache: [String: AlertRecord]? {
        didSet { alertSorted = nil }
    }
    var alertSorted: [AlertRecord]?

    public init(path: String, maxInfraRetries: Int = 1, maxQueuedPerSubmitterPerProject: Int = 128) throws {
        // Inspect an existing file before opening a writer (including journal-mode
        // changes). Refusal must leave an old installation able to finish its work.
        if path != ":memory:", FileManager.default.fileExists(atPath: path) {
            try Self.preflightLegacyState(Database(path: path, readOnly: true))
        }
        database = try Database(path: path)
        self.maxInfraRetries = maxInfraRetries
        self.maxQueuedPerSubmitterPerProject = maxQueuedPerSubmitterPerProject
        try Self.preflightLegacyState(database)
        try Migrator.migrate(database)
    }

    private static func preflightLegacyState(_ database: Database) throws {
        let version = try database.userVersion
        guard version <= SchemaMigrations.latestVersion else {
            throw DatabaseError.schemaTooNew(found: version, supported: SchemaMigrations.latestVersion)
        }
        if try database.query("SELECT name FROM sqlite_master WHERE type='table' AND name='jobs';").first != nil,
            try database.query("PRAGMA table_info(jobs);").contains(where: { $0.string("name") == "parent_id" }),
            try database.query(
                "SELECT id FROM jobs WHERE state IN ('queued','admitted','running') AND (parent_id IS NOT NULL OR id IN (SELECT parent_id FROM jobs WHERE parent_id IS NOT NULL)) LIMIT 1;"
            ).first != nil
        {
            throw JobStoreError.invalidCommand(
                "unfinished legacy shard group: use the previous SimQueue version to finish or cancel all group work, then drain and upgrade; the queue has not been migrated"
            )
        }
    }

    /// Opens an existing state file read-only (for `simq doctor` without a daemon). Never
    /// migrates or writes; refuses a schema other than the current one.
    public init(readOnlyPath path: String) throws {
        database = try Database(path: path, readOnly: true)
        maxInfraRetries = 1
        maxQueuedPerSubmitterPerProject = 0
        let version = try database.userVersion
        if version > SchemaMigrations.latestVersion {
            throw DatabaseError.schemaTooNew(found: version, supported: SchemaMigrations.latestVersion)
        }
        if version != SchemaMigrations.latestVersion {
            throw DatabaseError.schemaNotCurrent(found: version, expected: SchemaMigrations.latestVersion)
        }
    }

    // MARK: - Submit

    public func submit(_ submission: JobSubmission, now: Double) throws -> SubmitResult {
        try validateSubmission(submission)
        return try database.immediateTransaction { try submitInTransaction(submission, now: now) }
    }

    func validateSubmission(_ submission: JobSubmission) throws {
        guard Priority.isValid(submission.priority) else {
            throw JobStoreError.invalidPriority(submission.priority)
        }
        guard JobKindLabel.isValid(submission.kind) else {
            throw JobStoreError.invalidKind(submission.kind)
        }
        if let retries = submission.maxRetries, !(0...Self.maxRetriesLimit).contains(retries) {
            throw JobStoreError.invalidRetries(retries)
        }
        for value in [submission.runTimeoutSeconds, submission.queueTimeoutSeconds].compactMap({ $0 })
        where !(value > 0) || !value.isFinite {
            throw JobStoreError.invalidTimeout(value)
        }
        if let reason = submission.command?.validationError {
            throw JobStoreError.invalidCommand(reason)
        }
    }

    /// Caller owns an immediate transaction; used by ordinary and protected submission.
    func submitInTransaction(_ submission: JobSubmission, now: Double) throws -> SubmitResult {
        if let key = submission.dedupeKey,
            let existing = try fetchOne(
                "SELECT * FROM jobs WHERE dedupe_key = ? AND state IN ('queued', 'admitted', 'running') LIMIT 1;",
                [.text(key)]
            )
        {
            return .deduplicated(existing)
        }
        let queuedCount =
            try database.query(
                """
                SELECT COUNT(*) AS n FROM jobs
                WHERE project = ? AND submitter = ? AND state = 'queued' AND parent_id IS NULL;
                """,
                [.text(submission.project), .text(submission.submitter)]
            ).first?.int("n") ?? 0
        if maxQueuedPerSubmitterPerProject > 0, queuedCount >= maxQueuedPerSubmitterPerProject {
            throw JobStoreError.queueFull(
                submitter: submission.submitter,
                project: submission.project,
                limit: maxQueuedPerSubmitterPerProject
            )
        }
        try checkHistoryStoragePressure()
        try checkTotalCap(adding: 1)
        let job = try insert(
            project: submission.project,
            kind: submission.kind,
            priority: submission.priority,
            submitter: submission.submitter,
            worktree: submission.worktree,
            gitSHA: submission.gitSHA,
            dedupeKey: submission.dedupeKey,
            resources: submission.resources,
            exclusive: submission.exclusive,
            retryable: submission.retryable,
            maxRetries: submission.maxRetries,
            runTimeoutSeconds: submission.runTimeoutSeconds,
            queueTimeoutSeconds: submission.queueTimeoutSeconds,
            parentID: nil,
            payloadJSON: submission.payloadJSON,
            command: submission.command,
            queueTime: now,
            now: now
        )
        try event(job.id, "queued", detail: "priority=\(job.priority)", at: now)
        return .created(job)
    }

    /// Throws `queueFullTotal` if `adding` more queued rows would go over `maxQueuedTotal`.
    func checkTotalCap(adding: Int) throws {
        guard maxQueuedTotal > 0 else { return }
        let queued = try database.query("SELECT COUNT(*) AS n FROM jobs WHERE state = 'queued';").first?.int("n") ?? 0
        if Int(queued) + adding > maxQueuedTotal {
            throw JobStoreError.queueFullTotal(limit: maxQueuedTotal, adding: adding)
        }
    }

    // MARK: - Reads

    public func job(id: String) throws -> Job? {
        try fetchJob(id: id)
    }

    /// Only independent complete-workload jobs are scheduled.
    public func queuedJobs() throws -> [Job] {
        try fetchAll("SELECT * FROM jobs WHERE state = 'queued' ORDER BY queue_time, seq;")
    }

    public func activeJobs() throws -> [Job] {
        try fetchAll("SELECT * FROM jobs WHERE state IN ('admitted', 'running') ORDER BY seq;")
    }

    /// Newest first, optionally filtered by state and project.
    public func jobs(states: [JobState]? = nil, project: String? = nil, limit: Int = 100) throws -> [Job] {
        var clauses: [String] = []
        var values: [SQLValue] = []
        if let states, !states.isEmpty {
            clauses.append("state IN (\(states.map { _ in "?" }.joined(separator: ", ")))")
            values += states.map { .text($0.rawValue) }
        }
        if let project {
            clauses.append("project = ?")
            values.append(.text(project))
        }
        let filter = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        values.append(.integer(Int64(max(1, limit))))
        return try fetchAll("SELECT * FROM jobs \(filter) ORDER BY seq DESC LIMIT ?;", values)
    }

    /// Jobs admitted at or after `since` (for queue-wait statistics).
    public func jobsAdmitted(since: Double) throws -> [Job] {
        try fetchAll("SELECT * FROM jobs WHERE admitted_at >= ? ORDER BY seq;", [.real(since)])
    }

    public func allJobs() throws -> [Job] {
        try fetchAll("SELECT * FROM jobs ORDER BY seq;")
    }

    /// Finish times of infra failures since `since` (for the drain).
    public func infraFailureTimes(since: Double) throws -> [Double] {
        let classes = ResultClass.allCases.filter(\.isInfraFailure).map { "'\($0.rawValue)'" }.joined(separator: ", ")
        return try database.query(
            "SELECT finished_at FROM jobs WHERE result_class IN (\(classes)) AND finished_at >= ? ORDER BY finished_at;",
            [.real(since)]
        ).compactMap { $0.double("finished_at") }
    }

    public func events(jobID: String) throws -> [String] {
        try database.query("SELECT type FROM audit_log WHERE job_id = ? ORDER BY seq;", [.text(jobID)])
            .compactMap { $0.string("type") }
    }

    // MARK: - Daemon lease and recovery

    /// Takes the singleton daemon lease and returns a new, strictly larger epoch.
    /// Claims made with an older epoch are rejected (fencing).
    public func acquireDaemonLease(ownerID: String, pid: Int32, now: Double) throws -> Int64 {
        try database.immediateTransaction {
            let previous =
                try database.query("SELECT epoch FROM daemon_lease WHERE singleton = 1;").first?.int("epoch") ?? 0
            let epoch = previous + 1
            try database.run(
                """
                INSERT INTO daemon_lease (singleton, owner_id, pid, epoch, heartbeat) VALUES (1, ?, ?, ?, ?)
                ON CONFLICT(singleton) DO UPDATE SET owner_id = excluded.owner_id, pid = excluded.pid,
                    epoch = excluded.epoch, heartbeat = excluded.heartbeat;
                """,
                [.text(ownerID), .integer(Int64(pid)), .integer(epoch), .real(now)]
            )
            try event(nil, "daemon_lease_acquired", detail: "owner=\(ownerID) pid=\(pid)", at: now)
            return epoch
        }
    }

    public func currentEpoch() throws -> Int64? {
        try database.query("SELECT epoch FROM daemon_lease WHERE singleton = 1;").first?.int("epoch")
    }

    /// Startup recovery (order borrowed from XCSteward): after taking a new lease, every
    /// admitted/running job, or queued job with an admission-attempt marker, from an older
    /// epoch has lost its supervisor. Each one goes
    /// back to the queue at its original position (same queue time and sequence, attempt
    /// + 1, `restart_requeues` + 1), retryable or not: a daemon restart is SimQueue's
    /// infra problem, not the job's. A job past `maxRestartRequeues` ends `infra_failed`.
    ///
    /// Deadlines survive restarts: a job whose run deadline (persisted start time plus run
    /// timeout) has already passed is neither requeued nor interrupted. It stays active,
    /// moves to the new epoch, and is listed in `timeoutPending`, so the engine stops it
    /// and records `timed_out` exactly as if the daemon had never gone away.
    ///
    /// `liveProcessGroups` is the host's view of live process groups. A job whose recorded
    /// process group is still alive is never requeued (its command is still running, so a
    /// second copy would run beside it); it is marked `interrupted` and listed in
    /// `stillRunning`.
    public func recoverAfterRestart(epoch: Int64, now: Double, liveProcessGroups: Set<Int32> = []) throws
        -> RecoveryReport
    {
        try database.immediateTransaction {
            var report = RecoveryReport()
            let orphans = try fetchAll(
                """
                SELECT * FROM jobs
                WHERE (state IN ('admitted', 'running') AND (owner_epoch IS NULL OR owner_epoch < ?))
                   OR (state = 'queued' AND owner_epoch IS NOT NULL AND owner_epoch < ?)
                ORDER BY seq;
                """,
                [.integer(epoch), .integer(epoch)]
            )
            for job in orphans {
                if let deadline = job.runDeadline, now >= deadline {
                    try database.run(
                        "UPDATE jobs SET owner_epoch = ? WHERE id = ?;", [.integer(epoch), .text(job.id)])
                    try event(job.id, "run_deadline_passed_during_restart", detail: "deadline=\(deadline)", at: now)
                    report.timeoutPending.append(job.id)
                    continue
                }
                if let pid = job.ownerPID {
                    report.orphanPIDs.append(pid)
                }
                if let pid = job.ownerPID, liveProcessGroups.contains(pid) {
                    try database.run(
                        "UPDATE jobs SET state = 'interrupted', finished_at = ?, owner_pid = NULL, message = ? WHERE id = ?;",
                        [
                            .real(now),
                            .text("daemon restarted; process group \(pid) was still running and was left alone"),
                            .text(job.id),
                        ]
                    )
                    try event(
                        job.id, "interrupted", detail: "daemon restart; process group \(pid) still alive", at: now)
                    report.interrupted.append(job.id)
                    report.stillRunning.append(job.id)
                } else if job.startedAt != nil && (!job.retryable || job.attempt >= (job.maxRetries ?? maxInfraRetries))
                {
                    let message =
                        "daemon restarted after command start; side effects may have occurred. Automatic replay is disabled or its retry budget is exhausted; inspect artifacts before explicitly resubmitting."
                    try database.run(
                        "UPDATE jobs SET state='interrupted', result_class='internal_error', finished_at=?, message=?, owner_pid=NULL WHERE id=?;",
                        [.real(now), .text(message), .text(job.id)])
                    try event(job.id, "interrupted", detail: message, at: now)
                    report.interrupted.append(job.id)
                } else if job.restartRequeues < maxRestartRequeues {
                    try database.run(
                        """
                        UPDATE jobs SET state = 'queued', attempt = attempt + 1, restart_requeues = restart_requeues + 1,
                            admitted_at = NULL, started_at = NULL, granted_sims = 0, owner_pid = NULL, owner_epoch = NULL,
                            fence_token = NULL, term_sent_at = NULL, kill_sent_at = NULL WHERE id = ?;
                        """,
                        [.text(job.id)]
                    )
                    try event(
                        job.id, "requeued_after_restart",
                        detail: "daemon_restart \(job.restartRequeues + 1)/\(maxRestartRequeues)", at: now)
                    report.requeued.append(job.id)
                } else {
                    let message =
                        "daemon_restart: daemon restarted \(job.restartRequeues + 1) times while this job was active"
                        + " (cap \(maxRestartRequeues)); not requeued again"
                    try database.run(
                        """
                        UPDATE jobs SET state = 'infra_failed', result_class = ?, finished_at = ?, owner_pid = NULL,
                            message = ? WHERE id = ?;
                        """,
                        [.text(ResultClass.internalError.rawValue), .real(now), .text(message), .text(job.id)]
                    )
                    try event(job.id, "infra_failed", detail: "daemon_restart cap", at: now)
                    report.restartCapReached.append(job.id)
                }
            }
            return report
        }
    }

    // MARK: - Transitions

    /// Persist the selected job before claim starts. On a queued row, owner_epoch is an
    /// admission-attempt marker, not a grant: no fence token or resources exist yet.
    /// Claim replaces it with actual ownership; recovery clears it while counting one
    /// interrupted attempt. An ordinary queued job has no owner epoch and is untouched.
    public func recordAdmissionAttempt(jobID: String, epoch: Int64, now: Double) throws -> Bool {
        try database.immediateTransaction {
            try database.run(
                """
                UPDATE jobs SET owner_epoch = ? WHERE id = ? AND state = 'queued'
                  AND (SELECT epoch FROM daemon_lease WHERE singleton = 1) = ?;
                """,
                [.integer(epoch), .text(jobID), .integer(epoch)])
            guard database.changes == 1 else { return false }
            try event(jobID, "admission_attempted", detail: "epoch=\(epoch)", at: now)
            return true
        }
    }

    /// Atomically moves a queued job to `admitted` and issues it a fresh fencing token.
    /// Returns nil if the job is no longer queued or `epoch` isn't the current daemon epoch.
    public func claim(jobID: String, grantedSims: Int, epoch: Int64, now: Double) throws -> Int64? {
        try database.immediateTransaction {
            try database.run(
                """
                UPDATE jobs SET state = 'admitted', admitted_at = ?, granted_sims = ?, owner_epoch = ?
                WHERE id = ? AND state = 'queued'
                  AND (SELECT epoch FROM daemon_lease WHERE singleton = 1) = ?;
                """,
                [.real(now), .integer(Int64(grantedSims)), .integer(epoch), .text(jobID), .integer(epoch)]
            )
            guard database.changes == 1 else {
                return nil
            }
            try database.run("UPDATE fence_counter SET value = value + 1 WHERE singleton = 1;")
            guard
                let token = try database.query("SELECT value FROM fence_counter WHERE singleton = 1;").first?.int(
                    "value")
            else {
                throw JobStoreError.corruptRow("fence_counter missing")
            }
            try database.run("UPDATE jobs SET fence_token = ? WHERE id = ?;", [.integer(token), .text(jobID)])
            try event(jobID, "admitted", detail: "sims=\(grantedSims) fence=\(token)", at: now)
            return token
        }
    }

    /// True if `token` is the job's current fencing token and the job is still active.
    /// External lease holders present this on every heartbeat and release.
    public func isFenceValid(jobID: String, token: Int64) throws -> Bool {
        let rows = try database.query(
            "SELECT 1 FROM jobs WHERE id = ? AND fence_token = ? AND state IN ('admitted', 'running');",
            [.text(jobID), .integer(token)]
        )
        return !rows.isEmpty
    }

    public func markRunning(jobID: String, pid: Int32?, epoch: Int64, now: Double) throws -> Bool {
        try database.immediateTransaction {
            try database.run(
                """
                UPDATE jobs SET state = 'running', started_at = ?, owner_pid = ?
                WHERE id = ? AND state = 'admitted' AND owner_epoch = ?;
                """,
                [.real(now), .optional(pid.map(Int64.init)), .text(jobID), .integer(epoch)]
            )
            guard database.changes == 1 else {
                return false
            }
            try event(jobID, "running", detail: nil, at: now)
            return true
        }
    }

    /// Records a result. A runner-bootstrap failure is retried at the same queue position
    /// until `maxInfraRetries` is used up (XCSteward pattern; spec section 5h).
    @discardableResult
    ///
    /// When `fenceToken` is given (external lease holders), it must match the job's current
    /// token, or the call throws `staleFence` and changes nothing.
    ///
    /// `commandExitCode` records the job command's own status (process executor).
    public func finish(
        jobID: String, result: ResultClass, message: String? = nil, fenceToken: Int64? = nil,
        commandExitCode: Int32? = nil, now: Double
    ) throws -> Job {
        try database.immediateTransaction {
            guard let job = try fetchJob(id: jobID) else {
                throw JobStoreError.jobNotFound(jobID)
            }
            guard job.state.isActive else {
                throw JobStoreError.invalidTransition(jobID: jobID, from: job.state, action: "finish")
            }
            if let fenceToken, fenceToken != job.fenceToken {
                throw JobStoreError.staleFence(jobID: jobID, presented: fenceToken, current: job.fenceToken)
            }
            if job.retryable, result.isInfraFailure,
                job.attempt - job.restartRequeues < (job.maxRetries ?? maxInfraRetries)
            {
                try database.run(
                    """
                    UPDATE jobs SET state = 'queued', attempt = attempt + 1, admitted_at = NULL, started_at = NULL,
                        granted_sims = 0, owner_pid = NULL, owner_epoch = NULL, fence_token = NULL, term_sent_at = NULL,
                        kill_sent_at = NULL, message = ?, command_exit_code = ? WHERE id = ?;
                    """,
                    [.optional(message), commandExitCode.map { .integer(Int64($0)) } ?? .null, .text(jobID)]
                )
                // Record the failure for the drain without ending the job.
                try event(jobID, "infra_retry", detail: result.rawValue, at: now)
                try event(jobID, "infra_failure", detail: result.rawValue, at: now)
            } else {
                try database.run(
                    """
                    UPDATE jobs SET state = ?, result_class = ?, finished_at = ?, owner_pid = NULL, message = ?,
                        command_exit_code = COALESCE(?, command_exit_code)
                    WHERE id = ?;
                    """,
                    [
                        .text(result.terminalState.rawValue), .text(result.rawValue), .real(now), .optional(message),
                        commandExitCode.map { .integer(Int64($0)) } ?? .null, .text(jobID),
                    ]
                )
                try event(jobID, result.terminalState.rawValue, detail: result.rawValue, at: now)
            }
            guard let updated = try fetchJob(id: jobID) else {
                throw JobStoreError.jobNotFound(jobID)
            }
            return updated
        }
    }

    /// Records a command's exit status after the job already ended some other way (it was
    /// canceled or timed out and the process exited afterwards). Never changes the state.
    /// Records the pid of a job whose group was found by a spawn-intent scan after a restart.
    public func setOwnerPIDIfUnset(jobID: String, pid: Int32, observedAt: Double) throws {
        try database.run(
            "UPDATE jobs SET owner_pid = ?, started_at=COALESCE(started_at,admitted_at,?), state='running' WHERE id = ? AND owner_pid IS NULL AND state IN ('admitted','running');",
            [.integer(Int64(pid)), .real(observedAt), .text(jobID)])
    }

    /// Ends an active job `interrupted` (used when a restart can't tell whether its
    /// command started, so requeueing it could run a second copy).
    public func interruptActiveJob(jobID: String, message: String, now: Double) throws {
        try database.immediateTransaction {
            guard let job = try fetchJob(id: jobID), job.state.isActive else { return }
            try database.run(
                "UPDATE jobs SET state = 'interrupted', finished_at = ?, owner_pid = NULL, message = ? WHERE id = ?;",
                [.real(now), .text(message), .text(jobID)])
            try event(jobID, "interrupted", detail: message, at: now)
        }
    }

    public func recordCommandExit(jobID: String, code: Int32, now: Double) throws {
        try database.immediateTransaction {
            try database.run(
                "UPDATE jobs SET command_exit_code = ? WHERE id = ? AND command_exit_code IS NULL;",
                [.integer(Int64(code)), .text(jobID)]
            )
            if database.changes == 1 {
                try event(jobID, "command_exited", detail: "status=\(code)", at: now)
            }
        }
    }

    /// Cancels a queued, admitted or running job. Returns false if it already ended.
    public func cancel(jobID: String, now: Double) throws -> Bool {
        try database.immediateTransaction {
            try database.run(
                """
                UPDATE jobs SET state = 'canceled', result_class = 'canceled', finished_at = ?
                WHERE id = ? AND state IN ('queued', 'admitted', 'running');
                """,
                [.real(now), .text(jobID)]
            )
            guard database.changes == 1 else {
                return false
            }
            try event(jobID, "canceled", detail: nil, at: now)
            return true
        }
    }

    /// Ends a queued job whose queue timeout passed: state `expired`, result
    /// `queue_timeout`. Returns false if the job is no longer queued.
    public func expire(jobID: String, now: Double) throws -> Bool {
        try database.immediateTransaction {
            try database.run(
                """
                UPDATE jobs SET state = 'expired', result_class = 'queue_timeout', finished_at = ?,
                    message = 'queue timeout expired before the job started'
                WHERE id = ? AND state = 'queued';
                """,
                [.real(now), .text(jobID)]
            )
            guard database.changes == 1 else {
                return false
            }
            try event(jobID, "expired", detail: "queue_timeout", at: now)
            return true
        }
    }

    /// Records that SIGTERM (or SIGKILL) went out for a timed-out job, so a restarted
    /// daemon continues the same schedule. Only the owning epoch may write it.
    public func markTerminationSignal(
        jobID: String, signal: TerminationStep, epoch: Int64, now: Double
    ) throws -> Bool {
        let column = signal == .term ? "term_sent_at" : "kill_sent_at"
        return try database.immediateTransaction {
            try database.run(
                """
                UPDATE jobs SET \(column) = ? WHERE id = ? AND state IN ('admitted', 'running')
                    AND owner_epoch = ? AND \(column) IS NULL;
                """,
                [.real(now), .text(jobID), .integer(epoch)]
            )
            guard database.changes == 1 else {
                return false
            }
            try event(jobID, signal == .term ? "timeout_sigterm" : "timeout_sigkill", detail: nil, at: now)
            return true
        }
    }

    /// Human override (`simq bump`): changes the priority but keeps the queue position data.
    public func bump(jobID: String, to priority: Int, now: Double) throws -> Bool {
        guard Priority.isValid(priority) else {
            throw JobStoreError.invalidPriority(priority)
        }
        return try database.immediateTransaction {
            try database.run(
                "UPDATE jobs SET priority = ? WHERE id = ? AND state = 'queued';",
                [.integer(Int64(priority)), .text(jobID)]
            )
            guard database.changes == 1 else {
                return false
            }
            try event(jobID, "bumped", detail: "priority=\(priority)", at: now)
            return true
        }
    }

    // MARK: - Queue control

    public func queueControl() throws -> QueueControl {
        let row = try database.query("SELECT paused, drain_cleared_at FROM queue_control WHERE singleton = 1;").first
        return QueueControl(paused: (row?.int("paused") ?? 0) != 0, drainClearedAt: row?.double("drain_cleared_at"))
    }

    public func setPaused(_ paused: Bool) throws {
        try database.run("UPDATE queue_control SET paused = ? WHERE singleton = 1;", [.integer(paused ? 1 : 0)])
    }

    /// `simq resume`: unpauses and forgets infra failures so far.
    public func resume(now: Double) throws {
        try database.run("UPDATE queue_control SET paused = 0, drain_cleared_at = ? WHERE singleton = 1;", [.real(now)])
    }

    /// Last load-throttle decision (hysteresis state), persisted across restarts.
    public func loadThrottled() throws -> Bool {
        (try database.query("SELECT load_throttled FROM queue_control WHERE singleton = 1;").first?.int(
            "load_throttled") ?? 0) != 0
    }

    /// Stores the throttle decision; audits only transitions.
    public func setLoadThrottled(_ throttled: Bool, detail: String? = nil, now: Double) throws {
        try database.immediateTransaction {
            guard try loadThrottled() != throttled else { return }
            try database.run(
                "UPDATE queue_control SET load_throttled = ? WHERE singleton = 1;", [.integer(throttled ? 1 : 0)])
            try event(nil, throttled ? "load_throttle_on" : "load_throttle_off", detail: detail, at: now)
        }
    }

    /// Infra failure times including retried ones (which don't end the job).
    public func allInfraFailureTimes(since: Double) throws -> [Double] {
        let retried = try database.query(
            "SELECT at FROM audit_log WHERE type = 'infra_failure' AND at >= ?;",
            [.real(since)]
        ).compactMap { $0.double("at") }
        return (try infraFailureTimes(since: since) + retried).sorted()
    }

    // MARK: - Explanations

    /// Replaces the stored "why waiting" snapshot with this pass's.
    public func saveExplanations(_ explanations: [QueueExplanation], at time: Double) throws {
        if explanations.isEmpty, try database.query("SELECT 1 FROM explanations LIMIT 1;").isEmpty { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try database.immediateTransaction {
            try database.run("DELETE FROM explanations;")
            for explanation in explanations {
                let json = String(decoding: try encoder.encode(explanation.reasons), as: UTF8.self)
                try database.run(
                    "INSERT INTO explanations (job_id, position, effective_score, reasons_json, at) VALUES (?, ?, ?, ?, ?);",
                    [
                        .text(explanation.jobID), .integer(Int64(explanation.position)),
                        .real(explanation.effectiveScore), .text(json), .real(time),
                    ]
                )
            }
        }
    }

    public func explanation(jobID: String) throws -> QueueExplanation? {
        guard let row = try database.query("SELECT * FROM explanations WHERE job_id = ?;", [.text(jobID)]).first,
            let json = row.string("reasons_json"),
            let position = row.int("position"),
            let score = row.double("effective_score")
        else {
            return nil
        }
        let reasons = try JSONDecoder().decode([WaitReason].self, from: Data(json.utf8))
        return QueueExplanation(jobID: jobID, position: Int(position), effectiveScore: score, reasons: reasons)
    }

    // MARK: - Private

    private func insert(
        project: String,
        kind: String,
        priority: Int,
        submitter: String,
        worktree: String?,
        gitSHA: String?,
        dedupeKey: String?,
        resources: ResourceRequest,
        exclusive: Bool,
        retryable: Bool,
        maxRetries: Int?,
        runTimeoutSeconds: Double?,
        queueTimeoutSeconds: Double? = nil,
        parentID: String?,
        payloadJSON: String?,
        command: JobCommand? = nil,
        queueTime: Double,
        now: Double
    ) throws -> Job {
        let commandJSON = try command.map { String(decoding: try Self.commandEncoder.encode($0), as: UTF8.self) }
        let placeholder = "pending-\(UUID().uuidString)"
        try database.run(
            """
            INSERT INTO jobs (id, project, kind, priority, submitter, worktree, git_sha, dedupe_key,
                min_sims, max_sims, memory_bytes, memory_bytes_per_sim, run_timeout_seconds, parent_id, payload_json,
                attempt, queue_time, created_at, state, granted_sims, queue_timeout_seconds, exclusive, retryable,
                max_retries, command_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, 'queued', 0, ?, ?, ?, ?, ?);
            """,
            [
                .text(placeholder), .text(project), .text(kind), .integer(Int64(priority)),
                .text(submitter), .optional(worktree), .optional(gitSHA), .optional(dedupeKey),
                .integer(Int64(resources.minSims)), .integer(Int64(resources.maxSims)),
                .integer(Int64(clamping: resources.memoryBytes)),
                .integer(Int64(clamping: resources.memoryBytesPerSim)),
                .optional(runTimeoutSeconds), .optional(parentID), .optional(payloadJSON), .real(queueTime), .real(now),
                .optional(queueTimeoutSeconds), .integer(exclusive ? 1 : 0), .integer(retryable ? 1 : 0),
                maxRetries.map { .integer(Int64($0)) } ?? .null, .optional(commandJSON),
            ]
        )
        let sequence = database.lastInsertRowID
        let id = String(format: "J-%04lld", sequence)
        try database.run("UPDATE jobs SET id = ? WHERE seq = ?;", [.text(id), .integer(sequence)])
        guard let job = try fetchJob(id: id) else {
            throw JobStoreError.jobNotFound(id)
        }
        return job
    }

    func event(_ jobID: String?, _ type: String, detail: String?, resourceID: Int64? = nil, at time: Double) throws {
        try database.run(
            """
            INSERT INTO audit_log (at, epoch, job_id, resource_id, type, detail, pass_id)
            VALUES (?, (SELECT epoch FROM daemon_lease WHERE singleton = 1), ?, ?, ?, ?, ?);
            """,
            [
                .real(time), .optional(jobID), .optional(resourceID), .text(type), .optional(detail),
                .optional(currentPassID),
            ]
        )
    }

    private func fetchJob(id: String) throws -> Job? {
        try fetchOne("SELECT * FROM jobs WHERE id = ?;", [.text(id)])
    }

    private func fetchOne(_ sql: String, _ values: [SQLValue]) throws -> Job? {
        try fetchAll(sql, values).first
    }

    private func fetchAll(_ sql: String, _ values: [SQLValue] = []) throws -> [Job] {
        try database.query(sql, values).map(Self.job(from:))
    }

    private static let commandEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func job(from row: Row) throws -> Job {
        guard let id = row.string("id"),
            let sequence = row.int("seq"),
            let project = row.string("project"),
            let kind = row.string("kind"),
            let priority = row.int("priority").map(Int.init),
            let submitter = row.string("submitter"),
            let queueTime = row.double("queue_time"),
            let createdAt = row.double("created_at"),
            let state = row.string("state").flatMap(JobState.init(rawValue:))
        else {
            throw JobStoreError.corruptRow(row.string("id") ?? "unknown")
        }
        return Job(
            id: id,
            sequence: sequence,
            project: project,
            kind: kind,
            priority: priority,
            submitter: submitter,
            worktree: row.string("worktree"),
            gitSHA: row.string("git_sha"),
            dedupeKey: row.string("dedupe_key"),
            resources: ResourceRequest(
                minSims: Int(row.int("min_sims") ?? 0),
                maxSims: Int(row.int("max_sims") ?? 0),
                memoryBytes: UInt64(max(0, row.int("memory_bytes") ?? 0)),
                memoryBytesPerSim: UInt64(max(0, row.int("memory_bytes_per_sim") ?? 0))
            ),
            exclusive: (row.int("exclusive") ?? 0) != 0,
            retryable: (row.int("retryable") ?? 0) != 0,
            maxRetries: row.int("max_retries").map(Int.init),
            runTimeoutSeconds: row.double("run_timeout_seconds"),
            queueTimeoutSeconds: row.double("queue_timeout_seconds"),
            parentID: row.string("parent_id"),
            payloadJSON: row.string("payload_json"),
            command: try row.string("command_json").map {
                do {
                    return try JSONDecoder().decode(JobCommand.self, from: Data($0.utf8))
                } catch {
                    throw JobStoreError.corruptRow("\(id): command_json")
                }
            },
            commandExitCode: row.int("command_exit_code").map { Int32(truncatingIfNeeded: $0) },
            attempt: Int(row.int("attempt") ?? 0),
            restartRequeues: Int(row.int("restart_requeues") ?? 0),
            queueTime: queueTime,
            createdAt: createdAt,
            admittedAt: row.double("admitted_at"),
            startedAt: row.double("started_at"),
            finishedAt: row.double("finished_at"),
            state: state,
            resultClass: row.string("result_class").flatMap(ResultClass.init(rawValue:)),
            grantedSims: Int(row.int("granted_sims") ?? 0),
            ownerPID: row.int("owner_pid").map { Int32(truncatingIfNeeded: $0) },
            ownerEpoch: row.int("owner_epoch"),
            fenceToken: row.int("fence_token"),
            termSentAt: row.double("term_sent_at"),
            killSentAt: row.double("kill_sent_at"),
            message: row.string("message")
        )
    }
}
