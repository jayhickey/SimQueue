// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueHost
import SimQueueStore

/// Internal routing history. Old roots remain eligible for retention, never migrated.
public struct JobOutputConfiguration: Codable {
    public var root: String
    public var roots: [String]
    public var drained: Bool

    public static func prepare(stateDirectory: String, root: String, store: JobStore, persist: Bool = true) throws
        -> Self
    {
        let path = stateDirectory + "/job-output.json"
        let legacy = stateDirectory + "/jobs"
        let old: Self?
        if FileManager.default.fileExists(atPath: path) {
            old = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } else {
            old = nil
        }
        let previous = old?.root ?? legacy
        // Validate persisted history even when the requested root has not changed.
        // Include the recorded current root if an older file omitted it from roots.
        let roots = Array(Set((old?.roots ?? [legacy]) + [previous, root])).sorted()
        try JobStorage.validateDisjointRoots(roots)
        if previous != root {
            guard old?.drained == true || old == nil,
                try store.activeJobs().isEmpty,
                try !store.poolSims().contains(where: { $0.phase == .leased }),
                try store.pendingActionIntents().isEmpty,
                try store.liveResources(kinds: [.processGroup]).isEmpty
            else {
                throw JobStorage.Failure(
                    "job_output_root changed without a completed drain; restart with the previous root, drain, then change the root and restart"
                )
            }
        }
        let value = Self(root: root, roots: roots, drained: false)
        if persist { try value.save(stateDirectory: stateDirectory) }
        return value
    }

    public func save(stateDirectory: String) throws {
        try JSONEncoder().encode(self).write(
            to: URL(fileURLWithPath: stateDirectory + "/job-output.json"), options: .atomic)
    }

    public static func markDrained(_ drained: Bool, stateDirectory: String) throws {
        let url = URL(fileURLWithPath: stateDirectory + "/job-output.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.drained != drained else { return }
        value.drained = drained
        try value.save(stateDirectory: stateDirectory)
    }
}
