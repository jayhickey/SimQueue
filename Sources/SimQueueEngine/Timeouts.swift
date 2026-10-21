// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueHost
import SimQueueSim
import SimQueueStore

/// Queue and run timeouts. All timing comes from the injected clock and from times
/// persisted in the store (`created_at`, `started_at`, `term_sent_at`, `kill_sent_at`),
/// so a restarted daemon keeps the exact same deadlines and kill schedule.
extension Engine {
    /// Audit type for resources removed by normal job teardown (not orphan cleanup, so it
    /// doesn't count toward the reconcile rate limits).
    public static let teardownAuditType = "teardown_executed"

    /// Expires queued jobs past their queue timeout, then walks every active job past its
    /// run deadline through SIGTERM -> grace -> SIGKILL -> teardown -> `timed_out`.
    public func enforceTimeouts(now: Double) throws -> TimeoutReport {
        var report = TimeoutReport()
        for job in try store.queuedJobs() where job.isQueueExpired(now: now) {
            if try store.expire(jobID: job.id, now: now) {
                report.expired.append(job.id)
            }
        }
        for job in try store.activeJobs() where job.ownerEpoch == epoch && job.isRunTimedOut(now: now) {
            try stopTimedOutJob(job, now: now, report: &report)
        }
        return report
    }

    /// The job's live process groups. A pgid now led by a different process (reused
    /// while no daemon was watching) is not the job's: it counts as gone and is never
    /// signalled.
    private func liveGroups(of job: Job) throws -> [(resource: OwnedResource, pgid: Int32)] {
        let live = try environment.processes.liveProcessGroups()
        return try store.resources(jobID: job.id).compactMap { resource in
            guard resource.kind == .processGroup, resource.state == .active, let pgid = Int32(resource.externalID),
                live.contains(pgid)
            else {
                return nil
            }
            if try environment.processes.verifyGroup(pgid, identity: resource.identity, live: live) != .verified {
                return nil
            }
            return (resource, pgid)
        }
    }

    private func signal(
        _ groups: [(resource: OwnedResource, pgid: Int32)],
        _ signal: ProcessSignal,
        job: Job,
        now: Double,
        report: inout TimeoutReport
    ) throws {
        for group in groups {
            do {
                try environment.processes.signalGroup(group.pgid, signal)
            } catch {
                report.failures.append("\(job.id): \(signal.rawValue) to \(group.pgid) failed: \(error)")
                try store.audit(
                    "timeout_signal_failed", resourceID: group.resource.id,
                    detail: "\(signal.rawValue) to process group \(group.pgid): \(error)", now: now)
            }
        }
    }

    private func stopTimedOutJob(_ job: Job, now: Double, report: inout TimeoutReport) throws {
        let grace = timeouts.killGraceSeconds
        var groups = try liveGroups(of: job)
        var killSentAt = job.killSentAt

        if job.termSentAt == nil {
            // Persist first: if we crash right after signalling, the next daemon must not
            // restart the grace period.
            guard try store.markTerminationSignal(jobID: job.id, signal: .term, epoch: epoch, now: now) else {
                return
            }
            try signal(groups, .term, job: job, now: now, report: &report)
            report.termSent.append(job.id)
            groups = try liveGroups(of: job)
        } else if let termSentAt = job.termSentAt, killSentAt == nil, now >= termSentAt + grace, !groups.isEmpty {
            guard try store.markTerminationSignal(jobID: job.id, signal: .kill, epoch: epoch, now: now) else {
                return
            }
            try signal(groups, .kill, job: job, now: now, report: &report)
            report.killSent.append(job.id)
            killSentAt = now
            groups = try liveGroups(of: job)
        }

        var message = "run timeout of \(Self.format(job.runTimeoutSeconds)) exceeded"
        if !groups.isEmpty {
            // Still running. Wait for TERM or KILL to land, unless KILL itself has had a
            // full grace period: then the group is stuck. Leave it orphaned (reconcile and
            // the watchdog keep retrying) and record the timeout anyway.
            guard let killSentAt, now >= killSentAt + grace else {
                return
            }
            for group in groups {
                try store.markResourceOrphaned(
                    id: group.resource.id, reason: "survived SIGKILL after run timeout", now: now)
                try store.audit(
                    "cleanup_failed", resourceID: group.resource.id,
                    detail: "process group \(group.pgid) survived SIGKILL after run timeout", now: now)
                report.failures.append("\(job.id): process group \(group.pgid) survived SIGKILL")
            }
            message += "; process group survived SIGKILL, left for reconcile"
        }
        let teardownFailures = try teardown(job, now: now)
        report.failures.append(contentsOf: teardownFailures.map { "\(job.id): \($0)" })
        if !teardownFailures.isEmpty {
            message += "; \(teardownFailures.count) resource(s) left for reconcile"
        }
        do {
            _ = try store.finish(jobID: job.id, result: .runTimeout, message: message, now: now)
            report.timedOut.append(job.id)
        } catch JobStoreError.invalidTransition {
            // Finished or canceled concurrently; nothing more to do.
        }
    }

    /// Normal job teardown: release what the job holds. Exited process groups and leases
    /// are released; the job's own sims and directories are deleted, and each delete is
    /// verified before it is logged as done. Anything that fails is marked `orphaned` and
    /// audited as `cleanup_failed`, so reconcile retries it under its usual rules.
    /// Returns a description of each failure. Resources of a kind in `skipping` are left
    /// for their owner (the process executor drains its own process groups).
    @discardableResult
    public func teardown(_ job: Job, now: Double, skipping: Set<OwnedResourceKind> = []) throws -> [String] {
        var failures: [String] = []
        let live = try environment.processes.liveProcessGroups()
        let cleanupPending = try jobsWithLiveProcessGroups().contains(job.id)
        let resources = try store.resources(jobID: job.id).filter {
            $0.state == .active && !skipping.contains($0.kind)
        }
        let needsSimulatorCleanup = !cleanupPending && resources.contains { $0.kind == .sim }
        let simNames: [String: String] =
            needsSimulatorCleanup
            ? Dictionary(
                try environment.sims.listDevices().map { ($0.udid, $0.name) }, uniquingKeysWith: { first, _ in first })
            : [:]
        for resource in resources {
            do {
                if cleanupPending && resource.kind != .processGroup {
                    // Descendants may still use these leases, devices or paths. The
                    // watchdog retries dependent cleanup only after their groups are gone.
                    continue
                }
                switch resource.kind {
                case .processGroup:
                    guard let pgid = Int32(resource.externalID) else {
                        throw EngineError.cleanupNotVerified("unresolved process identity \(resource.externalID)")
                    }
                    if live.contains(pgid) {
                        throw EngineError.cleanupNotVerified("process group \(pgid)")
                    }
                    try store.markResourceReleased(id: resource.id, reason: "process group exited", now: now)
                case .lease:
                    try store.markResourceReleased(id: resource.id, reason: "job ended", now: now)
                case .template:
                    // Templates are owned by the pool, never by a job; never torn down here.
                    continue
                case .sim:
                    let udid = resource.externalID
                    guard let name = simNames[udid] else {
                        try store.markResourceReleased(id: resource.id, reason: "sim already gone", now: now)
                        continue
                    }
                    guard environment.naming.owns(name) else {
                        throw TeardownRefusal("sim \(udid) is outside the namespace")
                    }
                    let intent = ActionIntent(
                        target: .sim(udid: udid), auditType: Self.teardownAuditType, detail: "deleted sim \(udid)",
                        resourceID: resource.id, releaseReason: "sim deleted")
                    try performUnderIntent(intent, now: now) {
                        try environment.sims.deleteDevice(udid: udid)
                        if try environment.sims.listDevices().contains(where: { $0.udid == udid }) {
                            throw EngineError.cleanupNotVerified("sim \(udid)")
                        }
                    }
                case .runDir, .derivedDataDir:
                    let path = resource.externalID
                    guard environment.layout.isManaged(path) else {
                        throw TeardownRefusal("\(path) is outside managed roots")
                    }
                    if environment.fileSystem.fileExists(path) {
                        let intent = ActionIntent(
                            target: .path(path), auditType: Self.teardownAuditType, detail: "removed \(path)",
                            resourceID: resource.id, releaseReason: "directory removed")
                        try performUnderIntent(intent, now: now) {
                            try environment.fileSystem.removeItem(path)
                            if environment.fileSystem.fileExists(path) {
                                throw EngineError.cleanupNotVerified(path)
                            }
                        }
                    } else {
                        try store.markResourceReleased(id: resource.id, reason: "directory removed", now: now)
                    }
                }
            } catch {
                failures.append("\(resource.kind.rawValue) \(resource.externalID): \(error)")
                try store.markResourceOrphaned(id: resource.id, reason: "teardown failed: \(error)", now: now)
                try store.audit(
                    "cleanup_failed", resourceID: resource.id,
                    detail: "teardown of \(resource.kind.rawValue) \(resource.externalID): \(error)", now: now)
            }
        }
        return failures
    }

    static func format(_ seconds: Double?) -> String {
        guard let seconds else { return "none" }
        return seconds == seconds.rounded() ? "\(Int(seconds))s" : "\(seconds)s"
    }
}

struct TeardownRefusal: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = "refused: \(description)"
    }
}
