// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueSim
import SimQueueStore

/// One admitted job's sim preparation, taken off the scheduling tick (`takeSimPrepWork`),
/// run without the service lock (`performSimPrep`) and recorded under it (`finishSimPrep`).
public struct SimPrepWork: Sendable, Equatable {
    public var jobID: String
    /// The pool sims leased to the job: (udid, name).
    public var sims: [SimPrepTarget]
    public var resetApps: [String]
    public var freshSim: Bool

    public init(jobID: String, sims: [SimPrepTarget], resetApps: [String], freshSim: Bool) {
        self.jobID = jobID
        self.sims = sims
        self.resetApps = resetApps
        self.freshSim = freshSim
    }
}

public struct SimPrepTarget: Sendable, Equatable {
    public var udid: String
    public var name: String

    public init(udid: String, name: String) {
        self.udid = udid
        self.name = name
    }
}

extension Engine {
    /// Audit type of the per-sim preparation record (its detail is a `SimPrepOutcome` JSON).
    public static let simPrepAuditType = "sim_prep"

    /// Admitted jobs whose leased sims still need `fresh_sim` / `reset_apps`. The executor
    /// must not start them (see `JobExecutor.heldJobIDs`) until `finishSimPrep` ran.
    public var jobsAwaitingSimPrep: Set<String> { Set(simPrepQueue).union(simPrepInFlight) }

    /// Called by the tick right after a job leased its pool sims. Queues the job; no
    /// simulator command runs in the tick.
    func queueSimPrepIfNeeded(jobID: String) throws {
        guard let command = try store.job(id: jobID)?.command, command.wantsSimPrep else { return }
        simPrepQueue.append(jobID)
    }

    /// Hands out the queued preparation work (under the service lock) and marks it in flight.
    public func takeSimPrepWork() throws -> [SimPrepWork] {
        var work: [SimPrepWork] = []
        let queued = simPrepQueue
        simPrepQueue = []
        for jobID in queued {
            guard let job = try store.job(id: jobID), job.state == .admitted, let command = job.command else {
                continue
            }
            let lease = Self.poolLeaseID(jobID: jobID)
            let sims = try store.poolSims().filter { $0.leaseID == lease }.map {
                SimPrepTarget(udid: $0.udid, name: $0.name)
            }
            simPrepInFlight.insert(jobID)
            work.append(
                SimPrepWork(
                    jobID: jobID, sims: sims, resetApps: command.resetApps ?? [], freshSim: command.freshSim == true))
        }
        return work
    }

    /// Runs the simulator commands for one job (no store access, no lock: an erase can take
    /// minutes). `fresh_sim` erases each sim (shut down, erase, boot). `reset_apps` uninstalls
    /// each app and resets its privacy and notification permissions, then resets the keychain; if a step fails
    /// the sim is erased instead and the reason recorded. Only owned, non-template sims are
    /// touched; anything else is refused here, before the backend is called. Stops at the
    /// first sim whose preparation failed (its outcome has `error`).
    public static func performSimPrep(_ work: SimPrepWork, sims: any SimBackend, naming: SimNamingScheme)
        -> [SimPrepOutcome]
    {
        var outcomes: [SimPrepOutcome] = []
        for target in work.sims {
            var outcome = SimPrepOutcome(udid: target.udid)
            guard naming.owns(target.name), !naming.isTemplate(target.name) else {
                outcome.error = "refused: \(target.name) (\(target.udid)) is not an owned pool sim"
                outcomes.append(outcome)
                return outcomes
            }
            do {
                if work.freshSim {
                    try erase(target.udid, sims: sims)
                    outcome.erased = true
                } else {
                    do {
                        for app in work.resetApps {
                            try sims.uninstallApp(udid: target.udid, bundleID: app)
                            try sims.resetAppPrivacy(udid: target.udid, bundleID: app)
                            outcome.appsReset.append(app)
                        }
                        try sims.resetKeychain(udid: target.udid)
                        outcome.keychainReset = true
                    } catch {
                        outcome.fallbackReason = "\(error)"
                        outcome.appsReset = []
                        outcome.keychainReset = false
                        try erase(target.udid, sims: sims)
                        outcome.erased = true
                    }
                }
                outcomes.append(outcome)
            } catch {
                outcome.error = "\(error)"
                outcomes.append(outcome)
                return outcomes
            }
        }
        return outcomes
    }

    /// Records the outcomes (under the service lock) and releases the job to the executor.
    /// A failed preparation ends the job as an infra failure (`runner_bootstrap_failure`, so a
    /// retryable job is retried) and taints the sim, so the pool recycles it once the job lets
    /// go. The job's sims stay leased to it until this runs, even if it ended meanwhile
    /// (`releaseSimsOfEndedJobs`). If it did end (canceled, say), any sim whose preparation
    /// failed, was cut short or erased is tainted, and the next pool pass releases them all.
    public func finishSimPrep(_ work: SimPrepWork, outcomes: [SimPrepOutcome]) throws {
        defer { simPrepInFlight.remove(work.jobID) }
        let now = environment.clock.now()
        for outcome in outcomes {
            try recordSimPrep(outcome, jobID: work.jobID, now: now)
        }
        let stillAdmitted = try store.job(id: work.jobID)?.state == .admitted
        let byUDID = Dictionary(outcomes.map { ($0.udid, $0) }, uniquingKeysWith: { first, _ in first })
        let lease = Self.poolLeaseID(jobID: work.jobID)
        for target in work.sims {
            let outcome = byUDID[target.udid]
            let failed = outcome?.error != nil
            let disturbed = failed || outcome == nil || outcome?.erased == true
            guard failed || (!stillAdmitted && disturbed) else { continue }
            if var sim = try store.poolSims().first(where: { $0.udid == target.udid }), sim.leaseID == lease {
                sim.tainted = true
                try store.savePoolSim(sim)
            }
        }
        guard stillAdmitted, let failed = outcomes.first(where: { $0.error != nil }) else { return }
        _ = try store.finish(
            jobID: work.jobID, result: .runnerBootstrapFailure,
            message: "sim preparation failed on \(failed.udid): \(failed.error ?? "")", now: now)
    }

    /// All three steps in one call, for engine tests and callers without a lock.
    public func runSimPrep() throws {
        for work in try takeSimPrepWork() {
            try finishSimPrep(
                work, outcomes: Self.performSimPrep(work, sims: environment.sims, naming: environment.naming))
        }
    }

    /// Shut down, erase, boot: the sim comes back booted and empty.
    private static func erase(_ udid: String, sims: any SimBackend) throws {
        try sims.shutdownDevice(udid: udid)
        try sims.eraseDevice(udid: udid)
        try sims.bootDevice(udid: udid)
    }

    private func recordSimPrep(_ outcome: SimPrepOutcome, jobID: String, now: Double) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try store.audit(
            Self.simPrepAuditType, jobID: jobID, detail: String(decoding: try encoder.encode(outcome), as: UTF8.self),
            now: now)
    }
}
