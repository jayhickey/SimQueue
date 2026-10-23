// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueHost
import SimQueueProtocol
import SimQueueStore

/// Runs admitted jobs and reports how they end. Called from the daemon tick with the
/// service lock held, so it never races the scheduler or socket handlers.
public protocol JobExecutor: AnyObject {
    /// Submissions must carry a command (`simq submit -- <cmd>`).
    var requiresCommand: Bool { get }
    /// The executor drains its own process groups after a job ends (TERM, grace, KILL),
    /// so cancel must not tear them down underneath it.
    var drainsProcessGroups: Bool { get }
    func step(store: JobStore, epoch: Int64, now: Double) throws
    /// Admitted jobs not to start yet (their sims are still being prepared).
    var heldJobIDs: Set<String> { get set }
}

extension FakeExecutor: JobExecutor {
    public var requiresCommand: Bool { false }
    public var drainsProcessGroups: Bool { false }
}

/// Runs each job's command as the leader of its own process group, with stdout and
/// stderr appended to the job's `combined.log`, and records the outcome:
///
/// - exit 0: `success`
/// - any other exit, or a signal SimQueue didn't send: `command_failure` (state `failed`),
///   with the command's status in `command_exit_code`
/// - the log can't be opened: `artifact_failure`; the spawn itself fails:
///   `runner_bootstrap_failure` (both infra failures, retried if the job is retryable)
///
/// Run timeouts and cancels signal the group from elsewhere; the executor still reaps the
/// leader and records its status. Anything left in the group after the job ends (a
/// background child, say) gets SIGTERM, then SIGKILL after the grace period, and the
/// group's ownership record is released only once the group is really gone.
public final class ProcessExecutor: JobExecutor {
    /// Environment variable carrying a job's write-ahead spawn token (see
    /// `JobStore.recordSpawnIntent`).
    public static let spawnTokenKey = JobStore.spawnTokenEnvironmentKey

    public var requiresCommand: Bool { true }
    public var drainsProcessGroups: Bool { true }
    public var heldJobIDs: Set<String> = []
    public var storageCheck: @Sendable (String) throws -> Void = JobStorage.check

    public let artifacts: JobArtifacts
    private let processes: any ProcessTable
    private let baseEnvironment: [String: String]
    private let graceSeconds: Double
    /// Re-checks a job's `git_sha` against its worktree just before the command starts.
    private let gitCheckout: GitCheckout

    private struct Leader {
        var pid: Int32
        var createdAt: Double
    }

    private struct Draining {
        var pgid: Int32
        var termSentAt: Double?
        var killSentAt: Double?
    }

    /// Variables never passed to a job, whoever set them: the daemon's own secrets, such as
    /// the alert token named by `alerts.github.token_env` (#40).
    private let secretEnvironmentKeys: Set<String>
    /// Leaders not yet reaped, by job id.
    private var leaders: [String: Leader] = [:]
    /// Exited leaders retained as zombies until their owned group is no longer
    /// eligible for signals. Separate PIDs preserve an earlier retry's cleanup proof.
    private var retainedLeaders: Set<Int32> = []
    /// Process groups this executor started and still holds a record for, by resource id.
    /// Only these are ever drained: a group from an earlier daemon is left to reconcile.
    private var owned: [Int64: (jobID: String, pgid: Int32)] = [:]
    /// Leftover groups being stopped, by resource id.
    private var draining: [Int64: Draining] = [:]

    /// Service mode prepares filesystem work on its own serial lane. Direct executor
    /// users retain synchronous preparation. All bookkeeping stays under the service lock.
    var asynchronousPreparation = false
    enum PreparationStage: Equatable, Sendable { case directories, logOpen }
    /// Internal deterministic filesystem boundary for concurrency regressions.
    var beforePreparationStage: (@Sendable (PreparationStage) -> Void)?

    struct PreparationWork: Sendable {
        let job: Job
        let directory: String
        let logPath: String
        let root: String
        let now: Double
        let hook: (@Sendable (PreparationStage) -> Void)?
        let environment: [String: String]
        let gitCheckout: GitCheckout
        let storageCheck: @Sendable (String) throws -> Void
    }

    /// Immutable descriptor ownership transferred from the serial preparation worker to
    /// the state-locked consumer. No worker touches it after publishing its result.
    final class PreparedStart: @unchecked Sendable {
        let descriptor: Int32
        let executable: String
        init(descriptor: Int32, executable: String) {
            self.descriptor = descriptor; self.executable = executable
        }
        deinit { close(descriptor) }
    }

    struct PreparationFailure: Error {
        let result: ResultClass
        let message: String
        var exitCode: Int32? = nil
        var storageUnavailable = false
    }

    private struct StorageUnavailable: Error { let message: String }

    private enum PreparationState {
        case queued(PreparationWork)
        case working(PreparationWork)
        case ready(PreparationWork, Result<PreparedStart, PreparationFailure>)
        var work: PreparationWork {
            switch self {
            case .queued(let work), .working(let work), .ready(let work, _): return work
            }
        }
    }
    private var preparations: [String: PreparationState] = [:]
    var preparingJobIDs: Set<String> { Set(preparations.keys) }

    func takePreparationWork() -> [PreparationWork] {
        var work: [PreparationWork] = []
        for id in preparations.keys.sorted() {
            if case .queued(let item) = preparations[id] {
                preparations[id] = .working(item); work.append(item)
            }
        }
        return work
    }

    func finishPreparation(_ work: PreparationWork, result: Result<PreparedStart, PreparationFailure>) {
        guard let current = preparations[work.job.id], Self.sameAttempt(current.work.job, work.job) else { return }
        preparations[work.job.id] = .ready(work, result)
    }

    private static func sameAttempt(_ left: Job, _ right: Job) -> Bool {
        left.id == right.id && left.attempt == right.attempt && left.ownerEpoch == right.ownerEpoch
            && left.fenceToken == right.fenceToken
    }

    private func discardStalePreparations(store: JobStore, epoch: Int64) throws {
        for (id, state) in preparations {
            let current = try store.job(id: id)
            let valid =
                current.map {
                    $0.state == .admitted && $0.ownerEpoch == epoch && Self.sameAttempt($0, state.work.job)
                } ?? false
            if !valid {
                // The live writer retains its GC/drain fence until its syscall returns.
                if case .working = state { continue }
                preparations[id] = nil
            }
        }
    }

    public init(
        artifacts: JobArtifacts,
        processes: any ProcessTable,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        graceSeconds: Double = 10,
        secretEnvironmentKeys: Set<String> = [],
        gitCheckout: GitCheckout = GitCheckout(timeoutSeconds: 2)
    ) {
        self.gitCheckout = gitCheckout
        self.artifacts = artifacts
        self.processes = processes
        self.baseEnvironment = baseEnvironment.filter {
            !$0.key.hasPrefix(JobCommand.reservedEnvironmentPrefix) && !secretEnvironmentKeys.contains($0.key)
        }
        self.graceSeconds = graceSeconds
        self.secretEnvironmentKeys = secretEnvironmentKeys
    }

    /// Jobs whose command is still running (for tests and status).
    public var runningJobIDs: [String] { leaders.keys.sorted() }

    public func step(store: JobStore, epoch: Int64, now: Double) throws {
        try discardStalePreparations(store: store, epoch: epoch)
        samplePeakMemory(store: store)
        try reapLeaders(store: store, now: now)
        for job in try store.activeJobs()
        where job.ownerEpoch == epoch && job.state == .admitted && !heldJobIDs.contains(job.id) {
            try start(job, store: store, epoch: epoch, now: now)
        }
        try drainGroups(store: store, now: now)
        reapRetainedLeaders()
    }

    deinit {
        // These leaders were already observed exited; reap only our exact PIDs and
        // never wait for a still-running job when releasing the executor.
        let children = retainedLeaders.union(leaders.values.map(\.pid))
        for pid in children { _ = try? ProcessSpawner.reap(pid) }
    }

    private func reapRetainedLeaders() {
        let held = Set(owned.values.map(\.pgid))
        for pid in retainedLeaders where !held.contains(pid) {
            _ = try? ProcessSpawner.reap(pid)
            retainedLeaders.remove(pid)
        }
    }

    // MARK: - Start

    /// `SIMQ_DERIVED_DATA` and `SIMQ_RESULT_BUNDLE` for a job directory.
    public static func suggestedPaths(directory: String) -> [String: String] {
        [
            "SIMQ_DERIVED_DATA": directory + "/DerivedData",
            "SIMQ_RESULT_BUNDLE": directory + "/Result.xcresult",
        ]
    }

    /// The job's own TMPDIR: `<run dir>/tmp`.
    public static func tmpDirectory(directory: String) -> String { directory + "/tmp" }

    /// Removes a finished job's TMPDIR, never following symlinks and never outside the
    /// jobs root. Failures are audited, not fatal: retention removes the run dir later.
    private func removeTmpDirectory(jobID: String, store: JobStore, now: Double) throws {
        guard let job = try store.job(id: jobID), !job.state.isActive else { return }
        let tmp = Self.tmpDirectory(directory: artifacts.directory(for: job))
        let root = job.command?.artifactsRoot ?? artifacts.legacyRoot ?? artifacts.root
        guard (try? storageCheck(root)) != nil else { return }
        let fileSystem = RootedFileSystem(roots: [root])
        guard fileSystem.fileExists(tmp) else { return }
        do {
            try fileSystem.removeItem(tmp)
        } catch {
            try store.audit("cleanup_failed", detail: "remove \(tmp): \(error)", now: now)
        }
    }

    private func preparationWork(_ job: Job, now: Double) -> PreparationWork {
        var environment = baseEnvironment.merging(job.command?.environment ?? [:]) { _, job in job }
        for key in secretEnvironmentKeys { environment[key] = nil }
        return PreparationWork(
            job: job, directory: artifacts.directory(for: job), logPath: artifacts.logPath(for: job),
            root: job.command?.artifactsRoot ?? artifacts.legacyRoot ?? artifacts.root,
            now: now, hook: beforePreparationStage, environment: environment, gitCheckout: gitCheckout,
            storageCheck: storageCheck)
    }

    /// Only immutable inputs and host I/O: never touches the store or executor state.
    func prepareStart(_ work: PreparationWork) -> Result<PreparedStart, PreparationFailure> {
        Self.performPreparation(work)
    }

    static func performPreparation(_ work: PreparationWork) -> Result<PreparedStart, PreparationFailure> {
        guard let command = work.job.command else {
            return .failure(.init(result: .commandFailure, message: "job has no command"))
        }
        @Sendable func validateStorage(_ root: String) throws {
            do { try work.storageCheck(root) } catch {
                throw StorageUnavailable(message: String(describing: error))
            }
        }
        do {
            try validateStorage(work.root)
            work.hook?(.directories)
            let fileSystem = StorageFileSystem(
                base: RootedFileSystem(roots: [work.root]), roots: [work.root], validate: validateStorage)
            try fileSystem.createDirectory(work.directory)
            try fileSystem.createDirectory(Self.tmpDirectory(directory: work.directory))
            let header =
                "=== simq \(work.job.id) attempt \(work.job.attempt) at \(Timestamp(work.now).rfc3339): "
                + command.argv.joined(separator: " ") + (command.cwd.map { " (in \($0))" } ?? "") + "\n"
            work.hook?(.logOpen)
            try validateStorage(work.root)
            let descriptor = open(work.logPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else {
                throw ProcessControlError.system(call: "open \(work.logPath)", errno: errno)
            }
            var transferred = false
            defer { if !transferred { close(descriptor) } }
            try Self.append(header, descriptor: descriptor)
            func preparationFailure(_ result: ResultClass, _ message: String, exitCode: Int32? = nil) -> Result<
                PreparedStart, PreparationFailure
            > {
                try? Self.append("=== simq: \(message)\n", descriptor: descriptor)
                return .failure(.init(result: result, message: message, exitCode: exitCode))
            }
            if let cwd = command.cwd {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue
                else {
                    return preparationFailure(.commandFailure, "working directory \(cwd) does not exist")
                }
            }
            if let sha = work.job.gitSHA, let tree = work.job.worktree ?? command.cwd {
                do { try work.gitCheckout.requireHead(sha, in: tree) } catch let failure as GitCheckout.Failure {
                    switch failure {
                    case .mismatch, .unknownCommit:
                        return preparationFailure(.commandFailure, "worktree changed since submit: \(failure)")
                    case .notACheckout, .gitUnavailable:
                        return preparationFailure(
                            .runnerBootstrapFailure, "could not check git_sha before start: \(failure)")
                    }
                }
            }
            guard
                let executable = ProcessSpawner.resolveExecutable(
                    command.argv[0], path: work.environment["PATH"], cwd: command.cwd)
            else {
                return preparationFailure(.commandFailure, "command not found: \(command.argv[0])", exitCode: 127)
            }
            transferred = true
            return .success(PreparedStart(descriptor: descriptor, executable: executable))
        } catch let failure as StorageUnavailable {
            return .failure(.init(result: .artifactFailure, message: failure.message, storageUnavailable: true))
        } catch {
            return .failure(.init(result: .artifactFailure, message: "cannot write \(work.logPath): \(error)"))
        }
    }

    private func start(_ job: Job, store: JobStore, epoch: Int64, now: Double) throws {
        guard let command = job.command else {
            _ = try store.finish(
                jobID: job.id, result: .commandFailure, message: "job has no command; this daemon runs commands",
                now: now)
            return
        }
        // A transient disconnect must not turn an admitted, unstarted job into a
        // failed attempt. Retry preparation when the bound filesystem returns.
        guard (try? storageCheck(job.command?.artifactsRoot ?? artifacts.legacyRoot ?? artifacts.root)) != nil else {
            // A live worker keeps its writer fence until its syscall returns. Ready
            // descriptors belong to the old mount and must be closed, not reused.
            if case .working = preparations[job.id] {} else { preparations[job.id] = nil }
            return
        }
        let directory = artifacts.directory(for: job)
        let prepared: PreparedStart
        let outcome: Result<PreparedStart, PreparationFailure>
        if asynchronousPreparation {
            if let state = preparations[job.id] {
                guard Self.sameAttempt(state.work.job, job) else { return }
                guard case .ready(_, let result) = state else { return }
                outcome = result
                preparations[job.id] = nil
            } else {
                preparations[job.id] = .queued(preparationWork(job, now: now))
                return
            }
        } else {
            outcome = prepareStart(preparationWork(job, now: now))
        }
        // Preparation may have yielded to cancellation, retry or lease recovery. The
        // caller holds the state lock here; no stale attempt may cross the spawn barrier.
        guard let current = try store.job(id: job.id), current.state == .admitted,
            current.ownerEpoch == epoch, Self.sameAttempt(current, job),
            try store.currentEpoch() == epoch, !heldJobIDs.contains(job.id)
        else { return }

        switch outcome {
        case .success(let value): prepared = value
        case .failure(let failure):
            // The drive may already be back by the time this off-lock result is
            // consumed. Storage availability failures never spend a job attempt.
            if failure.storageUnavailable { return }
            _ = try store.finish(
                jobID: job.id, result: failure.result, message: failure.message,
                commandExitCode: failure.exitCode, now: now)
            // Preserve pre-start command/git failure artifacts. Completion summary I/O
            // is still synchronous, as it is for a normally completed command.
            if failure.result != .artifactFailure { try writeSummary(jobID: job.id, store: store) }
            return
        }
        do { try storageCheck(job.command?.artifactsRoot ?? artifacts.legacyRoot ?? artifacts.root) } catch {
            // Discard a prepared descriptor from a disconnected mount. Keep the job
            // admitted, then prepare again when the original volume becomes available.
            return
        }
        // The off-lock check may be older than this tick. Preserve the existing bounded
        // start-time SHA check rather than accepting a moved worktree after preparation.
        if let sha = job.gitSHA, let tree = job.worktree ?? command.cwd {
            do { try gitCheckout.requireHead(sha, in: tree) } catch let failure as GitCheckout.Failure {
                let result: ResultClass
                let message: String
                switch failure {
                case .mismatch, .unknownCommit:
                    result = .commandFailure; message = "worktree changed since submit: \(failure)"
                case .notACheckout, .gitUnavailable:
                    result = .runnerBootstrapFailure; message = "could not check git_sha before start: \(failure)"
                }
                try? Self.append("=== simq: \(message)\n", descriptor: prepared.descriptor)
                _ = try store.finish(jobID: job.id, result: result, message: message, now: now)
                try writeSummary(jobID: job.id, store: store)
                return
            }
        }
        var environment = baseEnvironment.merging(command.environment) { _, job in job }
        for key in secretEnvironmentKeys { environment[key] = nil }
        environment["SIMQ_JOB_ID"] = job.id
        environment["SIMQ_ATTEMPT"] = String(job.attempt)
        environment["SIMQ_PROJECT"] = job.project
        environment["SIMQ_KIND"] = job.kind
        environment["SIMQ_SIMS"] = String(job.grantedSims)
        // Pool sims leased to this job (empty when the pool is off).
        let poolSims = try store.poolSims().filter { $0.leaseID == "job:\(job.id)" }
        let poolUDIDs = poolSims.map(\.udid)
        // Which sims (and templates) this attempt runs on, for `sims` in its results, and a
        // fresh peak: both describe this attempt, not an earlier (retried) one.
        peaks[job.id] = nil
        try? store.beginJobRun(
            jobID: job.id,
            sims: poolSims.map {
                JobSim(
                    udid: $0.udid, name: $0.name, clonedFrom: $0.clonedFrom, runtime: $0.runtime,
                    deviceType: $0.deviceType)
            })
        if !poolUDIDs.isEmpty { environment["SIMQ_SIM_UDIDS"] = poolUDIDs.joined(separator: ",") }
        // The first leased sim, for the common one-sim case (`simq run`).
        if let first = poolUDIDs.first { environment["SIMQ_UDID"] = first }
        environment["SIMQ_RUN_DIR"] = directory
        // Suggested xcodebuild paths inside the job's own directory, so concurrent jobs
        // never share them. Paths only: nothing is created.
        environment.merge(Self.suggestedPaths(directory: directory)) { _, suggested in suggested }
        // A private temp directory per job, inside its run dir, removed once the job's
        // process group is gone. A TMPDIR the job sets itself wins.
        let tmp = Self.tmpDirectory(directory: directory)
        environment["SIMQ_TMPDIR"] = tmp
        if command.environment["TMPDIR"] == nil { environment["TMPDIR"] = tmp }

        // Write-ahead: the group's row exists before the spawn, tagged with a token the
        // child inherits, so a daemon that dies before recording the pid can still find
        // (and fence) the group after a restart instead of leaking it or running a copy.
        let token = "\(epoch)-\(job.id)-\(job.attempt)-\(UUID().uuidString.prefix(8).lowercased())"
        let intent: OwnedResource
        do {
            intent = try store.recordSpawnIntent(
                jobID: job.id, token: token, epoch: epoch, detail: command.argv.first, now: now)
        } catch {
            _ = try store.finish(
                jobID: job.id, result: .runnerBootstrapFailure,
                message: "could not record the process group before starting it: \(error)", now: now)
            return
        }
        environment[Self.spawnTokenKey] = token
        let pid: Int32
        do {
            pid = try ProcessSpawner.spawn(
                executable: prepared.executable, argv: command.argv, environment: environment, cwd: command.cwd,
                outputDescriptor: prepared.descriptor)
        } catch {
            try? store.markResourceReleased(id: intent.id, reason: "never started", now: now)
            try? Self.append("=== simq: could not start the command: \(error)\n", descriptor: prepared.descriptor)
            _ = try store.finish(
                jobID: job.id, result: .runnerBootstrapFailure, message: "could not start the command: \(error)",
                now: now)
            return
        }
        leaders[job.id] = Leader(pid: pid, createdAt: job.createdAt)
        guard try store.markRunning(jobID: job.id, pid: pid, epoch: epoch, now: now) else {
            // Lost the job between admission and start (canceled, or the lease moved on).
            try? processes.signalGroup(pid, .kill)
            try? store.markResourceReleased(id: intent.id, reason: "job lost before start; group killed", now: now)
            return
        }
        do {
            // The leader can't be reaped (and its pid reused) before we wait for it, so
            // reading its start time now is race-free.
            try store.resolveSpawnIntent(
                id: intent.id, pgid: pid, identity: try? processes.processIdentity(pid), now: now)
            owned[intent.id] = (job.id, pid)
        } catch {
            // Without an ownership record nothing could stop or account for this group:
            // kill it now rather than run it unsupervised.
            try? processes.signalGroup(pid, .kill)
            try? store.markResourceReleased(id: intent.id, reason: "could not record pid \(pid); killed", now: now)
            _ = try? store.finish(
                jobID: job.id, result: .runnerBootstrapFailure,
                message: "could not record process group \(pid): \(error)", now: now)
        }
    }

    // MARK: - Peak memory

    /// Highest resident size sampled so far, by job id (the store keeps the same peak).
    private var peaks: [String: UInt64] = [:]
    /// A new peak is written to the store only once it beats the stored one by this much.
    static let peakWriteStepBytes: UInt64 = 1 << 20

    /// Samples each running job's process group once per step (the executor's cadence), so
    /// `peak_memory_mib` is approximate: a spike between two samples is missed. Best effort:
    /// a failed read skips the sample. The peak is per attempt: `start` resets it.
    private func samplePeakMemory(store: JobStore) {
        guard !leaders.isEmpty else { return }
        // One walk of the process table per step, bucketed by group, for every running job.
        guard let sampled = try? processes.residentBytes(ofGroups: Set(leaders.values.map(\.pid))) else { return }
        for (jobID, leader) in leaders {
            guard let bytes = sampled[leader.pid] else { continue }
            let previous = peaks[jobID]
            guard previous.map({ bytes >= $0 + Self.peakWriteStepBytes }) ?? true else { continue }
            if (try? store.recordPeakResidentBytes(jobID: jobID, bytes: bytes)) != nil { peaks[jobID] = bytes }
        }
    }

    // MARK: - Reap

    private func reapLeaders(store: JobStore, now: Double) throws {
        for (jobID, leader) in leaders.sorted(by: { $0.key < $1.key }) {
            let exit: ChildExit
            do {
                guard let ended = try ProcessSpawner.peekExit(leader.pid) else { continue }
                exit = ended
            } catch {
                // Not our child any more (should not happen). Stop tracking it; the group,
                // if any, is drained below like any other leftover.
                leaders[jobID] = nil
                if let job = try store.job(id: jobID), job.state.isActive {
                    _ = try store.finish(
                        jobID: jobID, result: .internalError, message: "lost track of pid \(leader.pid): \(error)",
                        now: now)
                }
                continue
            }
            leaders[jobID] = nil
            retainedLeaders.insert(leader.pid)
            peaks[jobID] = nil
            guard let job = try store.job(id: jobID) else { continue }
            let logPath = artifacts.logPath(for: job)
            try? Self.append("=== simq: command \(exit.description) at \(Timestamp(now).rfc3339)\n", to: logPath)
            // A run timeout already signalled this job (`term_sent_at`): the exit is
            // SimQueue's doing, and the timeout path records `timed_out` once the whole
            // group is gone. Only note the command's status here.
            if job.state == .running, job.termSentAt == nil {
                let result: ResultClass = exit == .exited(0) ? .success : .commandFailure
                _ = try store.finish(
                    jobID: jobID, result: result, message: result == .success ? nil : "command \(exit.description)",
                    commandExitCode: exit.shellStatus, now: now)
            } else {
                try store.recordCommandExit(jobID: jobID, code: exit.shellStatus, now: now)
            }
            try writeSummary(jobID: jobID, store: store)
        }
    }

    // MARK: - Drain leftovers

    private func drainGroups(store: JobStore, now: Double) throws {
        guard !owned.isEmpty else { return }
        let live = try processes.liveProcessGroups()
        for (resourceID, holder) in owned.sorted(by: { $0.key < $1.key }) {
            guard let resource = try store.resource(id: resourceID), resource.state == .active else {
                // Released or orphaned elsewhere (run-timeout teardown, reconcile).
                owned[resourceID] = nil
                draining[resourceID] = nil
                if try store.resource(id: resourceID)?.state == .released {
                    try removeTmpDirectory(jobID: holder.jobID, store: store, now: now)
                }
                continue
            }
            // Still the job's own group. Once the job ends (finished, canceled), whatever is
            // left of the group, leader included, is stopped here.
            if let job = try store.job(id: holder.jobID), job.state.isActive { continue }
            let pgid = holder.pgid
            if !live.contains(pgid) {
                _ = try store.releaseResource(
                    id: resource.id, generation: resource.generation, reason: "process group exited", now: now)
                owned[resourceID] = nil
                draining[resourceID] = nil
                try removeTmpDirectory(jobID: holder.jobID, store: store, now: now)
                continue
            }
            // An exited leader remains unreaped while this executor owns its group.
            // Its original start time therefore still proves the group identity. Refuse
            // genuinely unverifiable or reused groups exactly as recovery does.
            let verification = try processes.verifyGroup(pgid, identity: resource.identity, live: live)
            if case .unverifiable(let reason) = verification {
                try store.markResourceOrphaned(id: resource.id, reason: reason, now: now)
                owned[resourceID] = nil; draining[resourceID] = nil
                continue
            }
            if verification == .reused {
                _ = try store.releaseResource(
                    id: resource.id, generation: resource.generation,
                    reason: "process group exited (pgid \(pgid) reused by another process)", now: now)
                try store.audit(
                    "leftover_skipped", resourceID: resource.id,
                    detail: "process group \(pgid) is led by a different process now; not signalled", now: now)
                owned[resourceID] = nil
                draining[resourceID] = nil
                continue
            }
            var entry = draining[resourceID] ?? Draining(pgid: pgid)
            if entry.termSentAt == nil {
                try? processes.signalGroup(pgid, .term)
                entry.termSentAt = now
                try store.audit(
                    "leftover_term", resourceID: resource.id,
                    detail: "process group \(pgid) outlived job \(holder.jobID); sent SIGTERM", now: now)
            } else if entry.killSentAt == nil, let term = entry.termSentAt, now >= term + graceSeconds {
                try? processes.signalGroup(pgid, .kill)
                entry.killSentAt = now
                try store.audit(
                    "leftover_kill", resourceID: resource.id,
                    detail: "process group \(pgid) ignored SIGTERM; sent SIGKILL", now: now)
            } else if let kill = entry.killSentAt, now >= kill + graceSeconds {
                try store.markResourceOrphaned(
                    id: resource.id, reason: "process group survived SIGKILL after job ended", now: now)
                try store.audit(
                    "cleanup_failed", resourceID: resource.id,
                    detail: "process group \(pgid) survived SIGKILL after job \(holder.jobID) ended", now: now)
                owned[resourceID] = nil
                draining[resourceID] = nil
                continue
            }
            draining[resourceID] = entry
        }
    }

    // MARK: - Files

    /// The `.xctestrun` a build step produced: the first by name under
    /// `DerivedData/Build/Products` (where `build-for-testing -derivedDataPath
    /// $SIMQ_DERIVED_DATA` writes it), else anywhere in the run dir at most 4 levels down.
    /// Never follows symlinks or descends into bundles.
    static func findXCTestRun(in directory: String) -> String? {
        let fileManager = FileManager.default
        let products = directory + "/DerivedData/Build/Products"
        if let names = try? fileManager.contentsOfDirectory(atPath: products),
            let name = names.filter({ $0.hasSuffix(".xctestrun") }).sorted().first
        {
            return products + "/" + name
        }
        var level = [directory]
        for _ in 0..<4 {
            var next: [String] = []
            for path in level {
                guard let names = try? fileManager.contentsOfDirectory(atPath: path) else { continue }
                for name in names.sorted() where !name.hasPrefix(".") && name != "tmp" {
                    let child = path + "/" + name
                    if name.hasSuffix(".xctestrun") { return child }
                    guard !name.contains("."),
                        let type = try? fileManager.attributesOfItem(atPath: child)[.type] as? FileAttributeType,
                        type == .typeDirectory
                    else { continue }
                    next.append(child)
                }
            }
            level = next
        }
        return nil
    }

    private func writeSummary(jobID: String, store: JobStore) throws {
        guard let job = try store.job(id: jobID) else { return }
        guard (try? storageCheck(job.command?.artifactsRoot ?? artifacts.legacyRoot ?? artifacts.root)) != nil
        else { return }
        var info = JobInfo(job: job, explanation: nil)
        info.logPath = artifacts.logPath(for: job)
        info.runDir = artifacts.directory(for: job)
        info.attachRunInfo(try store.jobRunInfo(jobID: job.id))
        info = ArtifactListing.attach(to: info)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let path = artifacts.summaryPath(for: job)
        try? (try encoder.encode(info) + Data("\n".utf8)).write(to: URL(fileURLWithPath: path), options: .atomic)
        // summary.md and the job's own events.jsonl, best effort like job.json.
        let directory = artifacts.directory(for: job)
        let markdown = JobReport.markdown(info, logTail: info.logPath.flatMap { JobReport.tail(of: $0) })
        try? Data(markdown.utf8).write(
            to: URL(fileURLWithPath: directory + "/" + JobReport.summaryName), options: .atomic)
        if let events = try? store.auditEntries(jobID: job.id) {
            let lines = events.map(JobReport.eventLine).joined(separator: "\n")
            try? Data((lines.isEmpty ? "" : lines + "\n").utf8).write(
                to: URL(fileURLWithPath: directory + "/" + JobReport.eventsName), options: .atomic)
        }
    }

    static func append(_ text: String, to path: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw ProcessControlError.system(call: "open \(path)", errno: errno)
        }
        defer { close(descriptor) }
        try append(text, descriptor: descriptor)
    }

    private static func append(_ text: String, descriptor: Int32) throws {
        let bytes = Array(text.utf8)
        var written = 0
        while written < bytes.count {
            let result = bytes[written...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if result < 0 {
                if errno == EINTR { continue }
                throw ProcessControlError.system(call: "write log", errno: errno)
            }
            written += result
        }
    }
}
