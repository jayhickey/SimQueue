// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueHost
import SimQueueSim
import SimQueueStore

/// `simqd --dry-run`: the daemon plans as usual and logs every host action it would take,
/// but runs none. Reads (sim list, host probe, process scan) pass through, so the plan
/// is real. Writes (sim create/boot/shutdown/delete, signals to process groups, job
/// commands) are logged as `dry-run: would ...` and refused with `DryRunError`, so nothing
/// on the host changes. Cleanup and the pool (`pool.mode`) are also forced to report-only,
/// so reconcile and pool passes report instead of trying (a configured `pool.mode: active`
/// would otherwise plan real creates and boots that only fail at the decorator).
public enum DryRun {
    public static func apply(to config: inout DaemonConfig) {
        config.reliability.cleanupMode = .reportOnly
        config.pool?.mode = .reportOnly
    }

    /// The database a dry run uses: a fresh copy of the real one, so the dry run sees the
    /// real queue and ownership rows but its fake completions, epochs and audits never land
    /// in the real state (#42). Call with the instance lock held (no daemon writes the real
    /// database meanwhile). The copy is replaced on every dry run.
    public static func prepareDatabase(realPath: String) throws -> String {
        let copy = (realPath as NSString).deletingPathExtension + "-dry-run.sqlite"
        let files = FileManager.default
        for suffix in ["", "-wal", "-shm"] where files.fileExists(atPath: copy + suffix) {
            try files.removeItem(atPath: copy + suffix)
        }
        // The -wal file holds commits not yet checkpointed; -shm is rebuilt by SQLite.
        for suffix in ["", "-wal"] where files.fileExists(atPath: realPath + suffix) {
            try files.copyItem(atPath: realPath + suffix, toPath: copy + suffix)
        }
        return copy
    }
}

public enum DryRunError: Error, Equatable, CustomStringConvertible {
    case skipped(String)
    public var description: String {
        switch self {
        case .skipped(let action): "dry run: not running \(action)"
        }
    }
}

public final class DryRunSimBackend: SimBackend, @unchecked Sendable {
    let base: any SimBackend
    let log: @Sendable (String) -> Void
    public var kind: BackendKind { base.kind }
    public var createBoots: Bool { base.createBoots }
    public var cloneSource: String? { base.cloneSource }

    public init(_ base: any SimBackend, log: @escaping @Sendable (String) -> Void) {
        self.base = base
        self.log = log
    }

    public func listDevices() throws -> [SimDevice] { try base.listDevices() }
    public func poolSnapshot() throws -> PoolSnapshot { try base.poolSnapshot() }
    public var templateCloneSource: (any TemplateCloneSource)? { base.templateCloneSource }

    private func skip(_ action: String) -> DryRunError {
        log("dry-run: would \(action)")
        return .skipped(action)
    }

    public func deleteDevice(udid: String) throws { throw skip("delete sim \(udid)") }
    public func createDevice(name: String) throws -> SimDevice { throw skip("create sim \(name)") }
    public func createDevice(name: String, cloneSource: String?) throws -> SimDevice {
        throw skip("create sim \(name)" + (cloneSource.map { " from \($0)" } ?? ""))
    }
    public func prepareClone(name: String, plan: SimClonePlan) throws -> SimClonePreparation {
        try base.prepareClone(name: name, plan: plan)
    }
    public func createPreparedDevice(_ preparation: SimClonePreparation) throws -> SimDevice {
        throw skip("create sim \(preparation.name) via \(preparation.plan.method.rawValue)")
    }
    public func cleanUpInterruptedClone(_ preparation: SimClonePreparation) throws {
        throw skip("recover interrupted clone \(preparation.name)")
    }
    public func bootDevice(udid: String) throws { throw skip("boot sim \(udid)") }
    public func shutdownDevice(udid: String) throws { throw skip("shut down sim \(udid)") }
    public func eraseDevice(udid: String) throws { throw skip("erase sim \(udid)") }
    public func uninstallApp(udid: String, bundleID: String) throws { throw skip("uninstall \(bundleID) from \(udid)") }
    public func resetAppPrivacy(udid: String, bundleID: String) throws {
        throw skip("reset privacy of \(bundleID) on \(udid)")
    }
    public func resetKeychain(udid: String) throws { throw skip("reset keychain of \(udid)") }
}

extension DryRunSimBackend: TemplateBuilding {
    /// Passes the check so the dry run logs what it would create (and then refuses).
    public var slimSupported: Bool { true }
    public func createBaseDevice(name: String, deviceType: String, runtime: String) throws -> SimDevice {
        throw skip("create template \(name) (\(deviceType), \(runtime))")
    }
    public func slim(udid: String, arguments: [String]) throws { throw skip("slim template \(udid)") }
    public func toolVersions() throws -> TemplateToolVersions {
        guard let builder = base as? TemplateBuilding else { throw SimBackendError.unsupported("build templates") }
        return try builder.toolVersions()
    }
    public func deleteTemplate(udid: String) throws { throw skip("delete template \(udid)") }
    public func defaultTemplateTarget() throws -> (deviceType: String, runtime: String) {
        guard let builder = base as? TemplateBuilding else { throw SimBackendError.unsupported("build templates") }
        return try builder.defaultTemplateTarget()
    }
}

public final class DryRunProcessTable: ProcessTable, @unchecked Sendable {
    let base: any ProcessTable
    let log: @Sendable (String) -> Void

    public init(_ base: any ProcessTable, log: @escaping @Sendable (String) -> Void) {
        self.base = base
        self.log = log
    }

    public var supportsEnvironmentScan: Bool { base.supportsEnvironmentScan }
    public func liveProcessGroups() throws -> Set<Int32> { try base.liveProcessGroups() }
    public func processIdentity(_ pid: Int32) throws -> String? { try base.processIdentity(pid) }
    public func residentBytes(ofGroups groups: Set<Int32>) throws -> [Int32: UInt64] {
        try base.residentBytes(ofGroups: groups)
    }
    public func processes(withEnvironmentEntry entry: String) throws -> [ProcessMatch] {
        try base.processes(withEnvironmentEntry: entry)
    }

    public func terminateGroup(_ pgid: Int32, graceSeconds: Double) throws {
        log("dry-run: would terminate process group \(pgid)")
        throw DryRunError.skipped("terminate process group \(pgid)")
    }

    public func signalGroup(_ pgid: Int32, _ signal: ProcessSignal) throws {
        log("dry-run: would send \(signal) to process group \(pgid)")
        throw DryRunError.skipped("signal process group \(pgid)")
    }
}

/// Reads pass through to the real (rooted) file system; writes are logged and refused.
public struct DryRunFileSystem: FileSystem {
    let base: any FileSystem
    let log: @Sendable (String) -> Void

    public init(_ base: any FileSystem, log: @escaping @Sendable (String) -> Void) {
        self.base = base
        self.log = log
    }

    public func fileExists(_ path: String) -> Bool { base.fileExists(path) }
    public func children(of path: String) throws -> [String] { try base.children(of: path) }
    public func sizeOfItem(_ path: String) -> UInt64? { base.sizeOfItem(path) }

    public func createDirectory(_ path: String) throws {
        log("dry-run: would create \(path)")
        throw DryRunError.skipped("create \(path)")
    }

    public func removeItem(_ path: String) throws {
        log("dry-run: would remove \(path)")
        throw DryRunError.skipped("remove \(path)")
    }
}

/// Runs no job command: logs what it would run, then completes the job through the fake
/// executor (on its own fake process table, never the host's).
public final class DryRunExecutor: JobExecutor {
    let fake = FakeExecutor(processes: FakeProcessTable())
    let log: (String) -> Void
    private var logged: Set<String> = []
    public var heldJobIDs: Set<String> = []
    public var requiresCommand: Bool { false }
    public var drainsProcessGroups: Bool { false }

    public init(log: @escaping (String) -> Void) {
        self.log = log
    }

    public func step(store: JobStore, epoch: Int64, now: Double) throws {
        for job in try store.activeJobs() where job.state != .queued && !logged.contains(job.id) {
            logged.insert(job.id)
            log("dry-run: would run \(job.id): \(job.command?.argv.joined(separator: " ") ?? "(no command)")")
        }
        fake.heldJobIDs = heldJobIDs
        try fake.step(store: store, epoch: epoch, now: now)
    }
}
