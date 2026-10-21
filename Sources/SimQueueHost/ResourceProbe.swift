// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore

/// Samples host resources. The real Darwin probe (host_statistics64, sysctl, getloadavg,
/// statfs, thermal state) arrives with the real backend; it only reads, never changes.
public protocol ResourceProbe: Sendable {
    func sample(now: Double) throws -> HostSnapshot
}

/// Always returns the same snapshot, re-stamped with the sample time.
public struct FakeResourceProbe: ResourceProbe {
    public var fixed: HostSnapshot

    public init(fixed: HostSnapshot) {
        self.fixed = fixed
    }

    public func sample(now: Double) throws -> HostSnapshot {
        var snapshot = fixed
        snapshot.sampledAt = now
        return snapshot
    }
}

/// Plays back a scripted timeline of snapshots, then repeats the last one. Lets tests
/// replay situations such as "swap starts growing" or "a boot storm pushes load up".
public final class ScriptedResourceProbe: ResourceProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [HostSnapshot]
    private var last: HostSnapshot

    public init(timeline: [HostSnapshot]) {
        precondition(!timeline.isEmpty, "ScriptedResourceProbe needs at least one snapshot")
        remaining = timeline
        last = timeline[0]
    }

    public func sample(now: Double) throws -> HostSnapshot {
        lock.lock()
        defer { lock.unlock() }
        if !remaining.isEmpty {
            last = remaining.removeFirst()
        }
        var snapshot = last
        snapshot.sampledAt = now
        return snapshot
    }
}

/// Snapshot that a test or soak harness updates between ticks.
public final class SettableResourceProbe: ResourceProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var current: HostSnapshot

    public init(_ snapshot: HostSnapshot) {
        current = snapshot
    }

    public func set(_ snapshot: HostSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        current = snapshot
    }

    public func update(_ change: (inout HostSnapshot) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&current)
    }

    public func sample(now: Double) throws -> HostSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = current
        snapshot.sampledAt = now
        return snapshot
    }
}
