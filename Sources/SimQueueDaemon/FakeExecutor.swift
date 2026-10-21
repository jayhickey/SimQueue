// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueHost
import SimQueueStore

/// Phase 2 stand-in for real executors. It "runs" admitted jobs inside the fake process
/// table: each job gets a fake process group (an owned resource, like the real thing will
/// be) and finishes after a delay with a result. Nothing touches real processes or sims.
///
/// A job's `payload_json` may steer it, for tests and demos:
/// `{"fake": {"run_seconds": 5, "result": "test_failure", "ignore_term": true}}`.
/// The default is an immediate `success`.
public final class FakeExecutor {
    public struct Plan: Sendable, Equatable {
        public var runSeconds: Double = 0
        public var result: ResultClass = .success
        public var ignoreTerm = false

        public init(runSeconds: Double = 0, result: ResultClass = .success, ignoreTerm: Bool = false) {
            self.runSeconds = runSeconds
            self.result = result
            self.ignoreTerm = ignoreTerm
        }

        public static func parse(_ payloadJSON: String?) -> Plan {
            struct Wrapper: Decodable {
                struct Fake: Decodable {
                    var runSeconds: Double?
                    var result: ResultClass?
                    var ignoreTerm: Bool?

                    enum CodingKeys: String, CodingKey {
                        case runSeconds = "run_seconds"
                        case result
                        case ignoreTerm = "ignore_term"
                    }
                }
                var fake: Fake?
            }
            guard let payloadJSON, let data = payloadJSON.data(using: .utf8),
                let fake = (try? JSONDecoder().decode(Wrapper.self, from: data))?.fake
            else {
                return Plan()
            }
            return Plan(
                runSeconds: max(0, fake.runSeconds ?? 0), result: fake.result ?? .success,
                ignoreTerm: fake.ignoreTerm ?? false)
        }
    }

    private struct Running {
        var pgid: Int32
        var resource: OwnedResource
        var startedAt: Double
        var plan: Plan
    }

    private let processes: FakeProcessTable
    private var running: [String: Running] = [:]
    private var nextPGID: Int32 = 50_000
    /// Admitted jobs not to start yet (their sims are still being prepared).
    public var heldJobIDs: Set<String> = []

    public init(processes: FakeProcessTable) {
        self.processes = processes
    }

    /// Starts admitted jobs and finishes the ones whose fake run time is up.
    public func step(store: JobStore, epoch: Int64, now: Double) throws {
        for job in try store.activeJobs() where job.ownerEpoch == epoch {
            switch job.state {
            case .admitted:
                guard !heldJobIDs.contains(job.id) else { continue }
                let pgid = nextPGID
                nextPGID += 1
                guard try store.markRunning(jobID: job.id, pid: pgid, epoch: epoch, now: now) else { continue }
                let plan = Plan.parse(job.payloadJSON)
                processes.spawn(pgid)
                if plan.ignoreTerm {
                    processes.ignoresTerm.insert(pgid)
                }
                let resource = try store.acquireResource(
                    kind: .processGroup, externalID: "\(pgid)", owner: .job(job.id), epoch: epoch,
                    identity: try processes.processIdentity(pgid), now: now)
                running[job.id] = Running(pgid: pgid, resource: resource, startedAt: now, plan: plan)
            case .running:
                guard let entry = running[job.id], now >= entry.startedAt + entry.plan.runSeconds else { continue }
                guard try processes.liveProcessGroups().contains(entry.pgid) else {
                    // Killed (run timeout or cancel); the daemon's own paths record that.
                    running[job.id] = nil
                    continue
                }
                processes.exit(entry.pgid)
                _ = try store.releaseResource(
                    id: entry.resource.id, generation: entry.resource.generation, reason: "exited", now: now)
                _ = try store.finish(jobID: job.id, result: entry.plan.result, now: now)
                running[job.id] = nil
            default:
                continue
            }
        }
        // Forget jobs that ended some other way (canceled, timed out).
        for id in running.keys where try store.job(id: id)?.state.isTerminal ?? true {
            running[id] = nil
        }
    }
}
