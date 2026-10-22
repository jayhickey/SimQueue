// SPDX-License-Identifier: MIT

import SimQueueCore
import SimQueueHost
import SimQueueStore

/// `simq gc` (spec §5i): what retention would remove, and what it removed with `--apply`.
public struct GarbageCollection: Sendable, Equatable {
    public struct Candidate: Sendable, Equatable {
        public var path: String
        public var reason: String
        /// Nil when the size couldn't be read.
        public var bytes: UInt64?
    }

    public var candidates: [Candidate]
    public var removed: [String] = []
    public var failures: [String] = []
}

/// What the age rules did on one full watchdog pass (spec §8a.3).
public struct AgeRuleReport: Sendable, Equatable {
    /// Job artifact directories removed (enforce mode).
    public var artifactsRemoved: [String] = []
    /// Directories past retention that report-only mode (or an open breaker) kept.
    public var artifactsWouldRemove: [String] = []
    /// Past retention, but over this pass's removal cap: next pass.
    public var artifactsPostponed: [String] = []
    public var failures: [String] = []
    /// Queued jobs past `queuedAlertSeconds` that got a new alert on this pass.
    public var longQueuedAlerted: [String] = []

    public init() {}
}

extension Engine {
    /// Audit type for each removed job artifact directory.
    public static let artifactRemovedAuditType = "artifact_removed"

    /// The age rules that run on a full pass besides reconcile's per-kind grace periods
    /// and lease max age: job artifact retention (destructive, so only in `enforce` mode
    /// with the breaker not open) and the queued-job alert (never cancels anything).
    func applyAgeRules(now: Double, mode: CleanupMode, includeArtifacts: Bool = true) throws -> (
        AgeRuleReport, [AlertEvent]
    ) {
        let rules = reliability.ageRules
        var report = AgeRuleReport()
        var events: [AlertEvent] = []
        for job in try store.queuedJobs() where now - job.createdAt >= rules.queuedAlertSeconds {
            let key = "queued:\(job.id)"
            guard try store.alert(key: key) == nil else { continue }
            events.append(
                AlertEvent(
                    key: key, level: .warn, title: "Job queued over \(Self.hours(rules.queuedAlertSeconds))",
                    detail:
                        "\(job.id) (\(job.project)\(job.kind.isEmpty ? "" : " \(job.kind)")) has waited "
                        + "\(Self.hours(now - job.createdAt)); it is not canceled"))
            report.longQueuedAlerted.append(job.id)
        }

        guard includeArtifacts else { return (report, events) }
        let reasoned = try retentionCandidates(now: now)
        let candidates = reasoned.map(\.path)
        if mode != .enforce {
            report.artifactsWouldRemove = candidates
            return (report, events)
        }
        let cap = max(0, rules.artifactRetention.maxRemovalsPerPass)
        report.artifactsPostponed = Array(candidates.dropFirst(cap))
        let outcome = try removeArtifacts(Array(reasoned.prefix(cap)), now: now)
        report.artifactsRemoved = outcome.removed
        report.failures = outcome.failures
        try removeEmptyDayDirectories(after: report.artifactsRemoved, now: now)
        return (report, events)
    }

    /// Removes retention candidates under write-ahead intents, verifying each is gone.
    func removeArtifacts(_ reasoned: [(path: String, reason: String)], now: Double) throws -> (
        removed: [String], failures: [String]
    ) {
        var removed: [String] = []
        var failures: [String] = []
        let fileSystem = environment.fileSystem
        for (path, reason) in reasoned {
            do {
                let intent = ActionIntent(
                    target: .path(path), auditType: Self.artifactRemovedAuditType,
                    detail: "removed \(path) (\(reason))")
                try performUnderIntent(intent, now: now) {
                    try fileSystem.removeItem(path)
                    if fileSystem.fileExists(path) { throw EngineError.cleanupNotVerified(path) }
                }
                removed.append(path)
            } catch {
                failures.append("\(path): \(error)")
                try store.audit("cleanup_failed", detail: "remove \(path): \(error)", now: now)
            }
        }
        return (removed, failures)
    }

    /// Atomic empty-only removal stays safe if a new job creates files concurrently.
    public static func removeEmptyArtifactDays(roots: [String], fileSystem: any FileSystem) throws -> [String] {
        var removed: [String] = []
        for root in roots {
            for day in try fileSystem.children(of: root) {
                guard let name = day.split(separator: "/").last, Self.dayStart(name) != nil,
                    day == "\(root)/\(name)"
                else { continue }
                if try fileSystem.removeEmptyDirectory(day) { removed.append(day) }
            }
        }
        return removed
    }

    /// Single-threaded engine callers; the daemon runs the disk half outside its lock.
    public func removeEmptyDayDirectories(after removed: [String], now: Double) throws {
        guard !removed.isEmpty else { return }
        for day in try Self.removeEmptyArtifactDays(
            roots: environment.allArtifactsRoots, fileSystem: environment.fileSystem)
        {
            try store.audit(Self.artifactRemovedAuditType, detail: "removed empty \(day)", now: now)
        }
    }

    /// Audit type that pins a job's artifacts (`simq submit --keep`).
    public static let artifactKeepAuditType = "artifact_keep"

    /// Whether the job was submitted with `--keep`.
    func isPinned(_ job: Job) throws -> Bool {
        if try !store.auditEntries(jobID: job.id, type: Self.artifactKeepAuditType).isEmpty { return true }
        return false
    }

    /// Immutable filesystem discovery, gathered without the daemon state lock.
    public struct GCInventory: Sendable {
        public struct Directory: Sendable {
            public let root: String
            public let path: String
            public let jobID: String
            public let dayStart: Double
            public let hasDerivedData: Bool
        }
        public let roots: [String]
        public let directories: [Directory]
    }

    public static func gcInventory(roots: [String], fileSystem: any FileSystem) throws -> GCInventory {
        var directories: [GCInventory.Directory] = []
        for root in roots {
            for day in try fileSystem.children(of: root) {
                guard let name = day.split(separator: "/").last, let dayStart = Self.dayStart(name),
                    day == "\(root)/\(name)"
                else { continue }
                for path in try fileSystem.children(of: day) {
                    guard let id = path.split(separator: "/").last.map(String.init), path == "\(day)/\(id)"
                    else { continue }
                    directories.append(
                        .init(
                            root: root, path: path, jobID: id, dayStart: dayStart,
                            hasDerivedData: fileSystem.fileExists(path + "/DerivedData")))
                }
            }
        }
        return GCInventory(roots: roots, directories: directories)
    }

    /// The store half consumes an immutable inventory: no directory, existence or size I/O.
    public struct GCPlan: Sendable {
        public var aged: [(path: String, reason: String)]
        public var entries: [BudgetEntry]
        public var budget: UInt64?
    }

    public func gcPlan(now: Double) throws -> GCPlan {
        try gcPlan(
            now: now,
            inventory: Self.gcInventory(
                roots: environment.allArtifactsRoots, fileSystem: environment.fileSystem))
    }

    public func gcPlan(now: Double, inventory: GCInventory) throws -> GCPlan {
        let aged = try inventory.roots.flatMap { root in
            try ageCandidates(directories: inventory.directories.filter { $0.root == root }, now: now)
        }
        let budget = reliability.ageRules.artifactRetention.budgetBytes
        var entries: [BudgetEntry] = []
        if budget != nil {
            entries = try budgetEntries(directories: inventory.directories, already: aged.map(\.path))
        }
        return GCPlan(aged: aged, entries: entries, budget: budget)
    }

    /// `simq gc`'s disk half (no lock needed): sizes, the budget's picks, and each
    /// candidate's size.
    public func gcCandidates(_ plan: GCPlan) -> [GarbageCollection.Candidate] {
        Self.gcCandidates(plan, fileSystem: environment.fileSystem)
    }

    public static func gcCandidates(_ plan: GCPlan, fileSystem: any FileSystem) -> [GarbageCollection.Candidate] {
        let picked = plan.budget.map { Self.overBudget(plan.entries, budget: $0, size: fileSystem.sizeOfItem) } ?? []
        return (plan.aged + picked).map {
            .init(path: $0.path, reason: $0.reason, bytes: fileSystem.sizeOfItem($0.path))
        }
    }

    /// Re-checked under the lock just before a removal: the job may have been pinned,
    /// requeued since the plan. A `DerivedData` path needs its job
    /// and its directory both need `isRemovable`; a directory with no job record goes.
    public func stillRemovable(_ path: String, now: Double? = nil) throws -> Bool {
        let isDerived = path.hasSuffix("/DerivedData")
        let dir = isDerived ? String(path.dropLast("/DerivedData".count)) : path
        guard let id = dir.split(separator: "/").last.map(String.init) else { return false }
        guard !artifactWritersInFlight.contains(id) else { return false }
        guard let job = try store.job(id: id) else { return !isDerived }
        if let now, try isPinned(job) {
            // Pins expire by age, but never by the budget or DerivedData's shorter TTL.
            guard !isDerived, job.state.isTerminal, try !hasOwnedCommandProcesses(job),
                let keep = reliability.ageRules.artifactRetention.keepSeconds(for: job.state, pinned: true)
            else { return false }
            return now - (job.finishedAt ?? job.createdAt) >= keep
        }
        return try isRemovable(job)
    }

    /// Record under the service lock, then keep recovery from settling this live worker's
    /// intent while it removes files without the lock. The caller must finish the intent.
    public func beginArtifactRemoval(path: String, reason: String, now: Double) throws -> ActionIntent? {
        guard try stillRemovable(path, now: now) else { return nil }
        let directory = path.hasSuffix("/DerivedData") ? String(path.dropLast("/DerivedData".count)) : path
        let jobID = directory.split(separator: "/").last.map(String.init)
        let intent = try store.recordActionIntent(
            ActionIntent(
                target: .path(path), auditType: Self.artifactRemovedAuditType,
                detail: "removed \(path) (\(reason))", jobID: try jobID.flatMap { try store.job(id: $0)?.id }),
            now: now)
        hostActionIntentsInFlight.insert(intent.id)
        return intent
    }

    public func finishArtifactRemoval(_ intent: ActionIntent, failure: String?, now: Double) throws {
        defer { hostActionIntentsInFlight.remove(intent.id) }
        if let failure {
            try? store.abandonActionIntent(intent, reason: failure, now: now)
            try store.audit("cleanup_failed", detail: "remove \(intent.target): \(failure)", now: now)
        } else {
            try store.confirmActionIntent(intent, now: now)
        }
    }

    /// `simq gc` in one go (tests and single-threaded callers): plan, size, then remove
    /// each candidate that's still removable, under write-ahead intents.
    public func garbageCollect(apply: Bool, now: Double) throws -> GarbageCollection {
        var result = GarbageCollection(candidates: gcCandidates(try gcPlan(now: now)))
        guard apply else { return result }
        let still = try result.candidates.filter { try stillRemovable($0.path, now: now) }
        let outcome = try removeArtifacts(still.map { ($0.path, $0.reason) }, now: now)
        result.removed = outcome.removed
        result.failures = outcome.failures
        try removeEmptyDayDirectories(after: outcome.removed, now: now)
        return result
    }

    /// Paths retention would remove this pass (`retentionCandidates`), under job artifact
    /// directories shaped `<root>/<YYYY-MM-DD>/<job-id>`. Anything else is never touched.
    func expiredArtifacts(now: Double) throws -> [String] {
        try retentionCandidates(now: now).map(\.path)
    }

    /// Everything retention removes this pass: whole job directories past their retention
    /// (oldest first), then the `DerivedData` of ended jobs whose directory stays, once the
    /// job ended `derived_data` ago, then (with `budgetBytes`) ended jobs' directories over
    /// the size budget. An active job's directory is never a candidate.
    func retentionCandidates(now: Double) throws -> [(path: String, reason: String)] {
        let plan = try gcPlan(now: now)
        guard let budget = plan.budget else { return plan.aged }
        return plan.aged + Self.overBudget(plan.entries, budget: budget, size: environment.fileSystem.sizeOfItem)
    }

    /// The age rules' candidates: whole directories past retention, then DerivedData.
    private func ageCandidates(directories: [GCInventory.Directory], now: Double) throws -> [(
        path: String, reason: String
    )] {
        let expired = try expiredJobDirectories(directories: directories, now: now)
        var result = expired.map { (path: $0, reason: "past retention") }
        let removed = Set(expired)
        let retention = reliability.ageRules.artifactRetention
        for directory in directories where !removed.contains(directory.path) {
            guard let job = try store.job(id: directory.jobID), retention.keepSeconds(for: job.state) != nil,
                try !isPinned(job), try !hasOwnedCommandProcesses(job),
                now - (job.finishedAt ?? job.createdAt) >= retention.derivedDataSeconds
            else { continue }
            if directory.hasDerivedData {
                result.append((directory.path + "/DerivedData", "DerivedData past retention"))
            }
        }
        return result
    }

    /// One job directory as the size budget sees it (from the store, no sizes yet).
    public struct BudgetEntry: Sendable, Equatable {
        public var path: String
        /// Ended and not pinned: the budget may remove it.
        public var removable: Bool
        public var failed: Bool
        public var endedAt: Double
        /// Its `DerivedData` is already a candidate (doesn't count against the budget).
        public var derivedAlreadyRemoved: Bool
    }

    /// Store lookups only; paths came from the unlocked filesystem inventory.
    private func budgetEntries(directories: [GCInventory.Directory], already: [String]) throws -> [BudgetEntry] {
        let removed = Set(already)
        var entries: [BudgetEntry] = []
        for directory in directories where !directory.jobID.hasPrefix(".") && !removed.contains(directory.path) {
            let job = try store.job(id: directory.jobID)
            entries.append(
                BudgetEntry(
                    path: directory.path, removable: try job.map(isRemovable) ?? true, failed: job?.state != .succeeded,
                    endedAt: job.map { $0.finishedAt ?? $0.createdAt } ?? directory.dayStart + 86_400,
                    derivedAlreadyRemoved: removed.contains(directory.path + "/DerivedData")))
        }
        return entries
    }

    /// Whether retention may remove a whole job directory: the job ended and is not pinned.
    func isRemovable(_ job: Job) throws -> Bool {
        try job.state.isTerminal && !artifactWritersInFlight.contains(job.id) && !isPinned(job)
            && !hasOwnedCommandProcesses(job)
    }

    private func hasOwnedCommandProcesses(_ job: Job) throws -> Bool {
        try store.resources(jobID: job.id).contains { $0.kind == .processGroup && $0.state != .released }
    }

    /// The budget's picks: removable directories, passes before failures, oldest first,
    /// until the total fits. The total counts every directory, pinned and running ones
    /// too, so pins can keep the jobs directory over budget. Sizes come from `size` (a
    /// disk walk), so callers may run this without the service lock.
    static func overBudget(
        _ entries: [BudgetEntry], budget: UInt64, size: (String) -> UInt64?
    ) -> [(path: String, reason: String)] {
        var total: UInt64 = 0
        var removable: [(entry: BudgetEntry, bytes: UInt64)] = []
        for entry in entries {
            let bytes = size(entry.path) ?? 0
            let derived = entry.derivedAlreadyRemoved ? size(entry.path + "/DerivedData") ?? 0 : 0
            let kept = bytes > derived ? bytes - derived : 0
            total += kept
            if entry.removable { removable.append((entry, kept)) }
        }
        guard total > budget else { return [] }
        let reason = "over the \(gib(budget)) artifact budget (\(gib(total)) used)"
        var result: [(path: String, reason: String)] = []
        let ordered = removable.sorted {
            ($0.entry.failed ? 1 : 0, $0.entry.endedAt, $0.entry.path)
                < ($1.entry.failed ? 1 : 0, $1.entry.endedAt, $1.entry.path)
        }
        for (entry, bytes) in ordered {
            guard total > budget else { break }
            result.append((entry.path, reason))
            total -= min(total, bytes)
        }
        return result
    }

    /// A size for a reason line: GiB down to 0.1 GiB, then MiB, then KiB.
    static func gib(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= 0.1 * 1_073_741_824 { return String(format: "%.1f GiB", value / 1_073_741_824) }
        if value >= 0.1 * 1_048_576 { return String(format: "%.1f MiB", value / 1_048_576) }
        return String(format: "%.1f KiB", value / 1024)
    }

    /// Whole job directories past their age-based retention, oldest first.
    private func expiredJobDirectories(directories: [GCInventory.Directory], now: Double) throws -> [String] {
        let retention = reliability.ageRules.artifactRetention
        var expired: [(endedAt: Double, path: String)] = []
        for directory in directories where !directory.jobID.hasPrefix(".") {
            let job = try store.job(id: directory.jobID)
            if let job, try hasOwnedCommandProcesses(job) { continue }
            let pinned = try job.map { try isPinned($0) } ?? false
            guard let keep = retention.keepSeconds(for: job?.state, pinned: pinned) else { continue }
            let endedAt = job.map { $0.finishedAt ?? $0.createdAt } ?? directory.dayStart + 86_400
            if now - endedAt >= keep { expired.append((endedAt, directory.path)) }
        }
        return expired.sorted { ($0.endedAt, $0.path) < ($1.endedAt, $1.path) }.map(\.path)
    }

    /// Report-only age findings: foreign booted sims seen past their limit and jobs queued
    /// past theirs. Nothing here is ever acted on.
    public func ageFindings(now: Double) throws -> [String] {
        let rules = reliability.ageRules
        var findings: [String] = []
        let sightings = try store.sightings()
        let owned = Set(try store.liveResources().filter { $0.kind == .sim }.map(\.externalID))
        for sim in try environment.sims.listDevices().sorted(by: { $0.udid < $1.udid })
        where sim.isBooted && !owned.contains(sim.udid) && !environment.naming.owns(sim.name) {
            guard let first = sightings["foreign_sim:\(sim.udid)"]?.firstSeenAt,
                now - first >= rules.foreignBootedSimReportSeconds
            else { continue }
            findings.append("foreign booted sim \(sim.name) (\(sim.udid)) seen for \(Self.hours(now - first))")
        }
        for job in try store.queuedJobs() where now - job.createdAt >= rules.queuedAlertSeconds {
            findings.append("job \(job.id) queued for \(Self.hours(now - job.createdAt))")
        }
        return findings
    }

    static func hours(_ seconds: Double) -> String {
        let hours = seconds / 3600
        return hours == hours.rounded() ? "\(Int(hours)) h" : "\((hours * 10).rounded() / 10) h"
    }

    /// Epoch seconds at UTC midnight for a `YYYY-MM-DD` path component; nil otherwise.
    static func dayStart(_ component: Substring?) -> Double? {
        guard let component, component.count == 10 else { return nil }
        let parts = component.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]), (1...12).contains(month),
            (1...31).contains(day)
        else { return nil }
        // Days from civil (Howard Hinnant).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return Double(era * 146_097 + doe - 719_468) * 86_400
    }
}
