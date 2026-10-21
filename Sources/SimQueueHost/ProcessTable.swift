// SPDX-License-Identifier: MIT

import Foundation

/// Process-group view and control. Phase 1 ships only the fake; the real implementation
/// (TERM, grace period, KILL) arrives with executors and is never exercised on a host
/// where killing processes is off limits.
public protocol ProcessTable: Sendable {
    func liveProcessGroups() throws -> Set<Int32>
    /// TERM the group, wait up to `graceSeconds`, then KILL. Returns once the group is gone.
    func terminateGroup(_ pgid: Int32, graceSeconds: Double) throws
    /// Sends one signal to a process group and returns at once (the run-timeout path
    /// drives TERM -> grace -> KILL from the injected clock instead of sleeping).
    func signalGroup(_ pgid: Int32, _ signal: ProcessSignal) throws
    /// Who the process with this pid is: a token built from its start time (and boot), so
    /// a reused pid never has the same identity. Nil if no such process exists.
    func processIdentity(_ pid: Int32) throws -> String?
    /// Whether `processes(withEnvironmentEntry:)` can actually see other processes'
    /// environments on this host.
    var supportsEnvironmentScan: Bool { get }
    /// Live processes whose initial environment contains `entry` exactly (`KEY=value`).
    /// Used to find a group spawned under a write-ahead intent whose pid never got
    /// recorded. Empty when unsupported.
    func processes(withEnvironmentEntry entry: String) throws -> [ProcessMatch]
    /// Total resident memory of the live members of each of `groups`, in bytes, right now,
    /// from one walk of the process table (bucketed by pgid). A group with no live member
    /// (or one the host can't read) is absent. Read-only; sampled for `peak_memory_mib`.
    func residentBytes(ofGroups groups: Set<Int32>) throws -> [Int32: UInt64]
}

/// One process found by an environment scan.
public struct ProcessMatch: Sendable, Equatable {
    public var pid: Int32
    public var pgid: Int32

    public init(pid: Int32, pgid: Int32) {
        self.pid = pid
        self.pgid = pgid
    }

    /// A process-group leader (what SimQueue spawns: the job command leads its own group).
    public var isGroupLeader: Bool { pid == pgid }
}

extension ProcessTable {
    public var supportsEnvironmentScan: Bool { false }
    public func processes(withEnvironmentEntry entry: String) throws -> [ProcessMatch] { [] }
    public func residentBytes(ofGroups groups: Set<Int32>) throws -> [Int32: UInt64] { [:] }
}

/// Whether a recorded process group is still the one SimQueue started.
public enum GroupVerification: Sendable, Equatable {
    /// Live, and its leader still has the recorded identity: safe to signal.
    case verified
    /// No live member: nothing to do.
    case gone
    /// Live, but led by a different process (the pgid was reused): not ours, and ours is gone.
    case reused
    /// Live, but its identity can't be confirmed (no identity recorded, or the leader has
    /// exited and only other members remain). Never signalled; reported instead.
    case unverifiable(String)
}

extension ProcessTable {
    /// Checks `pgid` against the identity recorded for it. Pass `live` to reuse one scan.
    public func verifyGroup(_ pgid: Int32, identity: String?, live: Set<Int32>? = nil) throws -> GroupVerification {
        guard try (live ?? liveProcessGroups()).contains(pgid) else { return .gone }
        guard let identity else { return .unverifiable("no leader start time recorded for process group \(pgid)") }
        guard let current = try processIdentity(pgid) else {
            return .unverifiable("leader of process group \(pgid) has exited; the other members can't be verified")
        }
        return current == identity ? .verified : .reused
    }
}

public enum ProcessSignal: String, Sendable, Codable {
    case term = "SIGTERM"
    case kill = "SIGKILL"
}

public final class FakeProcessTable: ProcessTable, @unchecked Sendable {
    private let lock = NSLock()
    private var groups: Set<Int32>
    public private(set) var terminated: [Int32] = []
    /// Every signal sent with `signalGroup`, in order.
    public private(set) var signals: [(pgid: Int32, signal: ProcessSignal)] = []
    /// Groups that ignore SIGTERM (only SIGKILL stops them).
    public var ignoresTerm: Set<Int32> = []
    /// Groups that survive even SIGKILL (stuck in the kernel, say), from either path.
    public var unkillable: Set<Int32> = []
    /// Groups whose signal (or terminate) call throws.
    public var signalFails: Set<Int32> = []
    /// Leader identity per group (`fake:<pgid>` unless a test changes it). A group with
    /// no entry is live but leaderless.
    public var identities: [Int32: String] = [:]
    /// Environment entries per pid, for `processes(withEnvironmentEntry:)` (see `tag`).
    private var environments: [Int32: (pgid: Int32, entries: [String])] = [:]
    public var supportsEnvironmentScan = true
    /// Resident bytes per live group, for `residentBytes(ofGroups:)` (absent when unset).
    public var residentBytesByGroup: [Int32: UInt64] = [:]
    /// How many times `residentBytes(ofGroups:)` was called (one walk each).
    public private(set) var residentScans = 0

    public func residentBytes(ofGroups wanted: Set<Int32>) throws -> [Int32: UInt64] {
        lock.lock()
        defer { lock.unlock() }
        residentScans += 1
        return residentBytesByGroup.filter { wanted.contains($0.key) && groups.contains($0.key) }
    }

    public init(groups: Set<Int32> = []) {
        self.groups = groups
        for pgid in groups {
            identities[pgid] = Self.defaultIdentity(pgid)
        }
    }

    public static func defaultIdentity(_ pgid: Int32) -> String { "fake:\(pgid)" }

    public func processIdentity(_ pid: Int32) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return groups.contains(pid) ? identities[pid] : nil
    }

    /// The leader exits but other members keep the group alive.
    public func leaderExited(_ pgid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        identities[pgid] = nil
    }

    /// The pgid now belongs to an unrelated process group with a different leader.
    public func reuse(_ pgid: Int32, identity: String) {
        lock.lock()
        defer { lock.unlock() }
        groups.insert(pgid)
        identities[pgid] = identity
    }

    public func liveProcessGroups() throws -> Set<Int32> {
        lock.lock()
        defer { lock.unlock() }
        return groups
    }

    public func terminateGroup(_ pgid: Int32, graceSeconds: Double) throws {
        lock.lock()
        defer { lock.unlock() }
        if signalFails.contains(pgid) {
            throw FakeFault.injected("terminate \(pgid)")
        }
        if !unkillable.contains(pgid) {
            groups.remove(pgid)
        }
        terminated.append(pgid)
    }

    public func signalGroup(_ pgid: Int32, _ signal: ProcessSignal) throws {
        lock.lock()
        defer { lock.unlock() }
        signals.append((pgid, signal))
        if signalFails.contains(pgid) {
            throw FakeFault.injected("signal \(signal.rawValue) to \(pgid)")
        }
        switch signal {
        case .term where !ignoresTerm.contains(pgid) && !unkillable.contains(pgid):
            groups.remove(pgid)
        case .kill where !unkillable.contains(pgid):
            groups.remove(pgid)
        default:
            break
        }
    }

    /// A process `pid` in group `pgid` (live while the group is) whose environment
    /// includes `entries`.
    public func tag(pid: Int32, pgid: Int32, entries: [String]) {
        lock.lock()
        defer { lock.unlock() }
        environments[pid] = (pgid, entries)
    }

    public func processes(withEnvironmentEntry entry: String) throws -> [ProcessMatch] {
        lock.lock()
        defer { lock.unlock() }
        guard supportsEnvironmentScan else { return [] }
        return environments.filter { groups.contains($0.value.pgid) && $0.value.entries.contains(entry) }
            .map { ProcessMatch(pid: $0.key, pgid: $0.value.pgid) }.sorted { $0.pid < $1.pid }
    }

    public func spawn(_ pgid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        groups.insert(pgid)
        identities[pgid] = Self.defaultIdentity(pgid)
    }

    public func exit(_ pgid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        groups.remove(pgid)
    }
}

/// Error thrown by fakes when a test injects a failure.
public enum FakeFault: Error, Equatable, CustomStringConvertible {
    case injected(String)

    public var description: String {
        switch self {
        case .injected(let what): return "injected failure: \(what)"
        }
    }
}
