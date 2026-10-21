// SPDX-License-Identifier: MIT

/// Ownership model. Every sim, child process group, external lease and run or
/// DerivedData directory SimQueue creates is owned by exactly one database row
/// (`owned_resources`), stamped with the daemon epoch and a generation (fencing token).
/// Anything SimQueue finds on the host that has no active row is either foreign
/// (reported, never touched) or a leak inside SimQueue's own namespace (cleaned up).
public enum OwnedResourceKind: String, Sendable, Codable, CaseIterable {
    case sim
    case processGroup = "process_group"
    case lease
    case runDir = "run_dir"
    case derivedDataDir = "derived_data_dir"
    /// A project's template sim (`simq template build`). Never reaped: it goes away only via
    /// `simq template rm` or a replace, through the cleanup gate. Stored as `golden`, its
    /// name before the rename to template: existing rows keep working, and so does a rollback.
    case template = "golden"
}

public enum OwnedResourceState: String, Sendable, Codable, CaseIterable {
    /// Held by a live owner.
    case active
    /// Owner is gone; cleanup is pending or failed and will be retried (watchdog hook).
    case orphaned
    /// Cleaned up or confirmed gone. Terminal.
    case released
}

/// Who holds a resource: a job, or the daemon itself (pool sims, templates).
public enum ResourceOwner: Sendable, Equatable, Hashable, Codable {
    case job(String)
    case pool

    public var jobID: String? {
        if case .job(let id) = self { return id }
        return nil
    }
}

public struct OwnedResource: Sendable, Equatable, Codable {
    public var id: Int64
    public var kind: OwnedResourceKind
    /// UDID, pgid (decimal), lease job id, or absolute path.
    public var externalID: String
    public var owner: ResourceOwner
    /// Daemon epoch that granted or last adopted the resource.
    public var epoch: Int64
    /// Fencing token; drawn from the same strictly increasing counter as job grants.
    public var generation: Int64
    public var state: OwnedResourceState
    public var acquiredAt: Double
    public var releasedAt: Double?
    public var detail: String?
    /// For a process group: who its leader was when SimQueue recorded it (pid start time,
    /// see `ProcessTable.processIdentity`). Guards against pid and pgid reuse: a group is
    /// only ever signalled if its leader still has this identity.
    public var identity: String?

    public init(
        id: Int64,
        kind: OwnedResourceKind,
        externalID: String,
        owner: ResourceOwner,
        epoch: Int64,
        generation: Int64,
        state: OwnedResourceState,
        acquiredAt: Double,
        releasedAt: Double? = nil,
        detail: String? = nil,
        identity: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.externalID = externalID
        self.owner = owner
        self.epoch = epoch
        self.generation = generation
        self.state = state
        self.acquiredAt = acquiredAt
        self.releasedAt = releasedAt
        self.detail = detail
        self.identity = identity
    }
}

/// Where SimQueue keeps per-job directories. Everything directly under `runsRoot` and
/// `derivedDataRoot` belongs to SimQueue, so an entry with no owner row is a leak.
public struct RunDirectoryLayout: Sendable, Equatable {
    public var root: String

    public init(root: String) {
        self.root = root.hasSuffix("/") ? String(root.dropLast()) : root
    }

    public var runsRoot: String { "\(root)/runs" }
    public var derivedDataRoot: String { "\(root)/derived-data" }

    public func runDir(jobID: String) -> String { "\(runsRoot)/\(jobID)" }
    public func derivedDataDir(jobID: String) -> String { "\(derivedDataRoot)/\(jobID)" }

    /// True for paths directly inside one of the managed roots.
    public func isManaged(_ path: String) -> Bool {
        for parent in [runsRoot, derivedDataRoot] {
            let prefix = parent + "/"
            if path.hasPrefix(prefix), !path.dropFirst(prefix.count).contains("/"), path.count > prefix.count {
                return true
            }
        }
        return false
    }
}

/// What actually exists on the host, from the sim backend, process table and file
/// system (all fakes in Phase 1).
public struct ObservedWorld: Sendable, Equatable {
    public var sims: [SimDevice]
    public var liveProcessGroups: Set<Int32>
    /// Entries found under the managed run and DerivedData roots (absolute paths).
    public var managedDirectories: Set<String>

    public init(sims: [SimDevice] = [], liveProcessGroups: Set<Int32> = [], managedDirectories: Set<String> = []) {
        self.sims = sims
        self.liveProcessGroups = liveProcessGroups
        self.managedDirectories = managedDirectories
    }
}

public enum ReconcileAction: Sendable, Equatable {
    /// Row says active or orphaned, but the thing is gone: mark released.
    case markGone(resourceID: Int64)
    /// Pool resource still present after a restart: re-stamp it with the new epoch.
    case adopt(resourceID: Int64)
    /// TERM then KILL the group. Always ordered before sim and directory cleanup.
    case killProcessGroup(pgid: Int32, resourceID: Int64)
    /// Delete a sim. `resourceID` is nil for an unknown sim inside SimQueue's namespace.
    case deleteSim(udid: String, resourceID: Int64?)
    /// Delete a directory. `resourceID` is nil for an unknown entry under a managed root.
    case removeDirectory(path: String, resourceID: Int64?)
    /// A lease whose holder is gone: revoke it (bumping nothing else).
    case revokeLease(resourceID: Int64)
    /// Something outside SimQueue's namespace. Report only; never touched.
    case reportForeignSim(udid: String, name: String)

    /// Cleanup order: kill process trees before freeing sims, sims before directories.
    var phase: Int {
        switch self {
        case .markGone, .adopt, .reportForeignSim: return 0
        case .killProcessGroup, .revokeLease: return 1
        case .deleteSim: return 2
        case .removeDirectory: return 3
        }
    }
}

/// Spelled out by hand, in exactly the form Swift's default reflection prints, because
/// reflection is slow and report-only passes describe every leftover they carry.
extension ReconcileAction: CustomStringConvertible {
    public var description: String {
        func optional(_ id: Int64?) -> String { id.map { "Optional(\($0))" } ?? "nil" }
        switch self {
        case .markGone(let id): return "markGone(resourceID: \(id))"
        case .adopt(let id): return "adopt(resourceID: \(id))"
        case .killProcessGroup(let pgid, let id): return "killProcessGroup(pgid: \(pgid), resourceID: \(id))"
        case .deleteSim(let udid, let id):
            return "deleteSim(udid: \(String(reflecting: udid)), resourceID: \(optional(id)))"
        case .removeDirectory(let path, let id):
            return "removeDirectory(path: \(String(reflecting: path)), resourceID: \(optional(id)))"
        case .revokeLease(let id): return "revokeLease(resourceID: \(id))"
        case .reportForeignSim(let udid, let name):
            return "reportForeignSim(udid: \(String(reflecting: udid)), name: \(String(reflecting: name)))"
        }
    }
}

/// Pure reconciliation of the ownership table against the observed world. Used at
/// startup and safe to run periodically (a watchdog can call the same planner).
public enum Reconciler {
    /// - Parameters:
    ///   - resources: rows in state `active` or `orphaned`.
    ///   - activeJobs: ids of jobs that are admitted or running under `epoch`.
    ///   - epoch: the current daemon epoch.
    public static func plan(
        resources: [OwnedResource],
        activeJobs: Set<String>,
        epoch: Int64,
        world: ObservedWorld,
        naming: SimNamingScheme,
        layout: RunDirectoryLayout,
        foreignAllowlist: ForeignResourceAllowlist = ForeignResourceAllowlist(),
        leaseMaxAgeSeconds: Double = .infinity,
        now: Double = 0
    ) -> [ReconcileAction] {
        var actions: [ReconcileAction] = []
        let simsByUDID = Dictionary(world.sims.map { ($0.udid, $0) }, uniquingKeysWith: { first, _ in first })
        var claimedSims = Set<String>()
        var claimedDirectories = Set<String>()

        for resource in resources.sorted(by: { $0.id < $1.id }) where resource.state != .released {
            let ownerAlive: Bool
            switch resource.owner {
            case .job(let jobID):
                ownerAlive = activeJobs.contains(jobID) && resource.epoch == epoch && resource.state == .active
            case .pool: ownerAlive = true
            }
            switch resource.kind {
            case .sim:
                claimedSims.insert(resource.externalID)
                let present = simsByUDID[resource.externalID] != nil
                if !present {
                    actions.append(.markGone(resourceID: resource.id))
                } else if !ownerAlive {
                    actions.append(.deleteSim(udid: resource.externalID, resourceID: resource.id))
                } else if resource.epoch != epoch {
                    actions.append(.adopt(resourceID: resource.id))
                }
            case .template:
                // A registered template is never reaped, whatever its owner's state.
                claimedSims.insert(resource.externalID)
                if simsByUDID[resource.externalID] == nil {
                    actions.append(.markGone(resourceID: resource.id))
                } else if resource.epoch != epoch {
                    actions.append(.adopt(resourceID: resource.id))
                }
            case .processGroup:
                // A write-ahead spawn intent has no recorded PID. Absence from a
                // numeric process snapshot cannot prove that its command never ran.
                guard let pgid = Int32(resource.externalID) else { continue }
                let present = world.liveProcessGroups.contains(pgid)
                if !present {
                    if !ownerAlive {
                        actions.append(.markGone(resourceID: resource.id))
                    }
                } else if !ownerAlive {
                    actions.append(.killProcessGroup(pgid: pgid, resourceID: resource.id))
                }
            case .lease:
                // A lease past its max age is revoked even if its holder looks alive.
                if !ownerAlive || now - resource.acquiredAt >= leaseMaxAgeSeconds {
                    actions.append(.revokeLease(resourceID: resource.id))
                }
            case .runDir, .derivedDataDir:
                claimedDirectories.insert(resource.externalID)
                let present = world.managedDirectories.contains(resource.externalID)
                if !present {
                    if !ownerAlive {
                        actions.append(.markGone(resourceID: resource.id))
                    }
                } else if !ownerAlive {
                    actions.append(.removeDirectory(path: resource.externalID, resourceID: resource.id))
                }
            }
        }

        // Leaks inside SimQueue's namespace, and foreign sims (report only). Ownership is
        // decided by rows, with one name exemption: `simq-template-...` sims (and legacy
        // `simq-golden-...` ones) are never reaped, registered or not (a registered one is
        // claimed above; an unregistered one, e.g. a hand-made simslim template, is left
        // alone). The foreign allowlist (disabled by default) can only widen what is managed,
        // never exempt. Another daemon's pool sims (tagged with its owner tag) are left alone
        // entirely: not reaped, and not reported as foreign either (they are SimQueue's, just
        // not ours).
        for sim in world.sims.sorted(by: { $0.udid < $1.udid })
        where !claimedSims.contains(sim.udid) && !naming.isTemplate(sim.name)
            && !naming.belongsToAnotherDaemon(sim.name)
        {
            if naming.owns(sim.name) || foreignAllowlist.allowsSim(named: sim.name) {
                actions.append(.deleteSim(udid: sim.udid, resourceID: nil))
            } else {
                actions.append(.reportForeignSim(udid: sim.udid, name: sim.name))
            }
        }
        for path in world.managedDirectories.sorted() where !claimedDirectories.contains(path) && layout.isManaged(path)
        {
            actions.append(.removeDirectory(path: path, resourceID: nil))
        }

        return actions.enumerated()
            .sorted { ($0.element.phase, $0.offset) < ($1.element.phase, $1.offset) }
            .map(\.element)
    }
}
