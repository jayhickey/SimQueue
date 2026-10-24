// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore

// `SimDevice` lives in SimQueueCore so the reaper planner can use it.

/// Everything the scheduler and pool manager need from a simulator backend. Grows in
/// later phases (clone, boot, recycle, health check).
public protocol SimBackend: Sendable {
    var kind: BackendKind { get }
    func listDevices() throws -> [SimDevice]
    func poolSnapshot() throws -> PoolSnapshot
    /// Deletes a sim. Only called for sims inside SimQueue's namespace.
    func deleteDevice(udid: String) throws
    /// Creates a shut-down sim named `name` (inside SimQueue's namespace) and returns it.
    func createDevice(name: String) throws -> SimDevice
    /// Like `createDevice(name:)`, but a cloning backend copies exactly `cloneSource` (what
    /// the pool's create intent recorded from `cloneSource` before the unlocked create), so
    /// a default-template switch in between can't make the clone differ from the intent. Nil
    /// on a cloning backend means there was no template. Non-cloning backends ignore it.
    func createDevice(name: String, cloneSource: String?) throws -> SimDevice
    /// Read-only preflight; a slim clone requires the exact registered source shut down.
    func prepareClone(name: String, plan: SimClonePlan) throws -> SimClonePreparation
    func createPreparedDevice(_ preparation: SimClonePreparation) throws -> SimDevice
    /// Removes only the exact interrupted target and restores the recorded slim source
    /// to Shutdown. A failure leaves the intent holding its boot/capacity commitment.
    func cleanUpInterruptedClone(_ preparation: SimClonePreparation) throws
    /// Boots a sim and returns once the boot finished (it may still be settling).
    func bootDevice(udid: String) throws
    func shutdownDevice(udid: String) throws
    /// Erases a shut-down owned sim (all content and settings). Per-job `fresh_sim`.
    func eraseDevice(udid: String) throws
    /// Uninstalls an app from a booted owned sim. Per-job `reset_apps`.
    func uninstallApp(udid: String, bundleID: String) throws
    /// Resets every privacy permission an app has on a booted owned sim, notifications included.
    func resetAppPrivacy(udid: String, bundleID: String) throws
    /// Resets a booted owned sim's keychain.
    func resetKeychain(udid: String) throws
    /// Where pool clones come from, for a backend that clones a template (nil otherwise).
    var templateCloneSource: (any TemplateCloneSource)? { get }
    /// Whether `createDevice` boots a sim itself (simslim clone boots its source). The pool
    /// then counts each create against `max_concurrent_boots` like a boot.
    var createBoots: Bool { get }
    /// The sim `createDevice` clones (the template UDID), if any. A pool create's intent
    /// records it so the template can't be removed while a clone from it is in flight.
    var cloneSource: String? { get }
}

/// The template a cloning backend copies: `simctl.template` when configured, else the default
/// the engine keeps current (the newest `ready` template row). Thread-safe.
public protocol TemplateCloneSource: AnyObject, Sendable {
    /// The configured override (`simctl.template`), if any.
    var configuredTemplate: String? { get }
    /// The default template: the newest ready one SimQueue built (`simq template build`).
    var defaultTemplate: DefaultTemplate? { get }
    func setDefaultTemplate(_ template: DefaultTemplate?)
}

/// A SimQueue-built template that clones copy when no `simctl.template` is configured.
public struct DefaultTemplate: Sendable, Equatable {
    public var name: String
    public var udid: String
    public init(name: String, udid: String) {
        self.name = name
        self.udid = udid
    }
}

extension TemplateCloneSource {
    /// What clones copy (name or UDID), or nil while there is no template yet.
    public var cloneTemplate: String? { configuredTemplate ?? defaultTemplate?.udid }
}

/// Shown by status and doctor, and thrown by a clone, while a cloning backend has no template.
public let noTemplateMessage = "no template yet, run simq template build"

/// Building template sims (`simq template build`). Separate from `SimBackend` so the pool's
/// backend contract doesn't grow; a backend that can't build templates just doesn't conform.
public protocol TemplateBuilding: Sendable {
    /// Creates a fresh, shut-down sim of `deviceType` on `runtime`, named `name`.
    func createBaseDevice(name: String, deviceType: String, runtime: String) throws -> SimDevice
    /// Whether `slim` is wired. A build is refused up front (nothing created) when not.
    var slimSupported: Bool { get }
    /// Slims the sim with a profile's simslim arguments.
    func slim(udid: String, arguments: [String]) throws
    /// The host's Xcode and runtime versions (read-only).
    func toolVersions() throws -> TemplateToolVersions
    /// What to build when nothing is configured (read-only): the newest available iOS
    /// runtime and the newest iPhone it supports.
    func defaultTemplateTarget() throws -> (deviceType: String, runtime: String)
    /// Deletes a template sim (`simq template rm` only). Separate from `deleteDevice`, which
    /// refuses template names so no pool path can delete one.
    func deleteTemplate(udid: String) throws
}

public enum SimBackendError: Error, Equatable, CustomStringConvertible {
    case unsupported(String)
    public var description: String {
        switch self {
        case .unsupported(let what): "this sim backend can't \(what) yet"
        }
    }
}

extension SimBackend {
    public var templateCloneSource: (any TemplateCloneSource)? { nil }
    public func createDevice(name: String) throws -> SimDevice { throw SimBackendError.unsupported("create sims") }
    public func createDevice(name: String, cloneSource: String?) throws -> SimDevice { try createDevice(name: name) }
    public func prepareClone(name: String, plan: SimClonePlan) throws -> SimClonePreparation {
        guard plan.method == .simctl else { throw SimBackendError.unsupported("preserve a slim template profile") }
        let devices = try listDevices()
        guard !devices.contains(where: { $0.name == name }) else {
            throw SimBackendError.unsupported("clone over an existing simulator")
        }
        return SimClonePreparation(name: name, plan: plan, previousUDIDs: Set(devices.map(\.udid)))
    }
    public func createPreparedDevice(_ preparation: SimClonePreparation) throws -> SimDevice {
        guard preparation.plan.method == .simctl else {
            throw SimBackendError.unsupported("preserve a slim template profile")
        }
        return try createDevice(name: preparation.name, cloneSource: preparation.plan.source)
    }
    public func cleanUpInterruptedClone(_ preparation: SimClonePreparation) throws {
        guard preparation.plan.method == .simctl else { throw SimBackendError.unsupported("recover a slim clone") }
        let inventory = try listDevices()
        if let expected = preparation.expectedTargetUDID,
            inventory.contains(where: { $0.udid == expected && $0.name != preparation.name })
        {
            throw SimBackendError.unsupported("recover a renamed clone")
        }
        let devices = inventory.filter { $0.name == preparation.name }
        guard devices.count <= 1,
            devices.allSatisfy({
                !preparation.previousUDIDs.contains($0.udid)
                    && (preparation.expectedTargetUDID == nil || preparation.expectedTargetUDID == $0.udid)
            })
        else {
            throw SimBackendError.unsupported("recover an ambiguous or pre-existing clone")
        }
        if let device = devices.first { try deleteDevice(udid: device.udid) }
    }
    public func bootDevice(udid: String) throws { throw SimBackendError.unsupported("boot sims") }
    public func shutdownDevice(udid: String) throws { throw SimBackendError.unsupported("shut sims down") }
    public func eraseDevice(udid: String) throws { throw SimBackendError.unsupported("erase sims") }
    public func uninstallApp(udid: String, bundleID: String) throws {
        throw SimBackendError.unsupported("uninstall apps")
    }
    public func resetAppPrivacy(udid: String, bundleID: String) throws {
        throw SimBackendError.unsupported("reset app privacy")
    }
    public func resetKeychain(udid: String) throws { throw SimBackendError.unsupported("reset keychains") }
    public var createBoots: Bool { false }
    public var cloneSource: String? { nil }
}

/// In-memory fake. Never touches CoreSimulator. Tests set its pool counts directly.
public final class FakeSimBackend: SimBackend, @unchecked Sendable {
    public let kind: BackendKind = .fake
    private let lock = NSLock()
    private var devices: [SimDevice]
    private var pool: PoolSnapshot

    public init(devices: [SimDevice] = [], pool: PoolSnapshot = PoolSnapshot()) {
        self.devices = devices
        self.pool = pool
    }

    /// Thrown by `listDevices` while set (a hung or failing `simctl`; a real backend
    /// bounds every call with a timeout and throws instead of blocking).
    public var listFailure: FakeSimError?

    public func listDevices() throws -> [SimDevice] {
        lock.lock()
        defer { lock.unlock() }
        if let listFailure { throw listFailure }
        return devices
    }

    public func poolSnapshot() throws -> PoolSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return pool
    }

    /// UDIDs passed to `deleteDevice`, in order.
    public private(set) var deletedUDIDs: [String] = []
    /// UDIDs whose delete throws.
    public var deleteFails: Set<String> = []
    /// UDIDs whose delete "succeeds" but leaves the sim in place.
    public var deleteHasNoEffect: Set<String> = []
    /// Called after a delete took effect (chaos tests: fail the database right after).
    public var afterDelete: ((String) -> Void)?

    public func deleteDevice(udid: String) throws {
        lock.lock()
        if deleteFails.contains(udid) {
            lock.unlock()
            throw FakeSimError.deleteFailed(udid)
        }
        deletedUDIDs.append(udid)
        if deleteHasNoEffect.contains(udid) {
            lock.unlock()
            return
        }
        devices.removeAll { $0.udid == udid }
        let hook = afterDelete
        lock.unlock()
        hook?(udid)
    }

    private var created = 0
    /// Reported as `createBoots` (a fake standing in for simslim clone).
    public var createBoots = false
    private var cloneSourceValue: String?
    /// Reported as `cloneSource`. With `clonesTemplate` it follows the template a create would
    /// copy (the configured one, else the default UDID), like the real backend.
    public var cloneSource: String? {
        get {
            guard clonesTemplate else { return cloneSourceValue }
            lock.lock()
            defer { lock.unlock() }
            return configuredTemplateValue ?? defaultTemplateValue?.udid
        }
        set { cloneSourceValue = newValue }
    }
    /// Real seconds `createDevice` and `bootDevice` sleep before acting (slow-host tests).
    public var createDelaySeconds: Double = 0
    public var bootDelaySeconds: Double = 0
    /// UDIDs passed to `bootDevice`, in order.
    public private(set) var bootedUDIDs: [String] = []
    /// UDIDs whose boot throws.
    public var bootFails: Set<String> = []

    /// Acts like a backend that clones a template (`TemplateCloneSource`): creates need one.
    public var clonesTemplate = false
    /// With `clonesTemplate`: the override (`simctl.template`).
    public var configuredTemplateValue: String?
    private var defaultTemplateValue: DefaultTemplate?
    /// With `clonesTemplate`: the template each create copied, in order.
    public private(set) var clonedFrom: [String] = []

    public func createDevice(name: String) throws -> SimDevice {
        try create(name: name, source: { $0.configuredTemplateValue ?? $0.defaultTemplateValue?.udid })
    }

    /// With `clonesTemplate`, copies `cloneSource` as given (like the real backend), never the
    /// template current at create time.
    public func createDevice(name: String, cloneSource: String?) throws -> SimDevice {
        try create(name: name, source: { _ in cloneSource })
    }

    public private(set) var clonePlans: [SimClonePlan] = []
    public func prepareClone(name: String, plan: SimClonePlan) throws -> SimClonePreparation {
        let devices = try listDevices()
        guard !devices.contains(where: { $0.name == name }) else { throw FakeSimError.noTemplate }
        return SimClonePreparation(
            name: name, plan: plan, previousUDIDs: Set(devices.map(\.udid)), sourceWasShutdown: plan.boots)
    }
    public func createPreparedDevice(_ preparation: SimClonePreparation) throws -> SimDevice {
        lock.withLock { clonePlans.append(preparation.plan) }
        return try createDevice(name: preparation.name, cloneSource: preparation.plan.source)
    }
    public func cleanUpInterruptedClone(_ preparation: SimClonePreparation) throws {
        let inventory = try listDevices()
        if let expected = preparation.expectedTargetUDID,
            inventory.contains(where: { $0.udid == expected && $0.name != preparation.name })
        {
            throw FakeSimError.noTemplate
        }
        let targets = inventory.filter { $0.name == preparation.name }
        guard targets.count <= 1,
            targets.allSatisfy({
                !preparation.previousUDIDs.contains($0.udid)
                    && (preparation.expectedTargetUDID == nil || preparation.expectedTargetUDID == $0.udid)
            })
        else {
            throw FakeSimError.noTemplate
        }
        for target in targets { try deleteDevice(udid: target.udid) }
        if preparation.plan.boots, let source = preparation.plan.source { try shutdownDevice(udid: source) }
    }

    /// Runs before a create reads its source, without the lock (tests switch the default
    /// template here to race a create).
    public var beforeCreate: (@Sendable () -> Void)?

    private func create(name: String, source: (FakeSimBackend) -> String?) throws -> SimDevice {
        if createDelaySeconds > 0 { Thread.sleep(forTimeInterval: createDelaySeconds) }
        beforeCreate?()
        lock.lock()
        defer { lock.unlock() }
        if clonesTemplate {
            guard let source = source(self) else { throw FakeSimError.noTemplate }
            clonedFrom.append(source)
        }
        return makeDevice(name: name)
    }

    /// Adds a shut-down sim (callers hold `lock`).
    private func makeDevice(name: String) -> SimDevice {
        created += 1
        let device = SimDevice(udid: String(format: "FAKE-POOL-%04d", created), name: name, isBooted: false)
        devices.append(device)
        return device
    }

    public func bootDevice(udid: String) throws {
        if bootDelaySeconds > 0 { Thread.sleep(forTimeInterval: bootDelaySeconds) }
        lock.lock()
        defer { lock.unlock() }
        if bootFails.contains(udid) { throw FakeSimError.bootFailed(udid) }
        guard let index = devices.firstIndex(where: { $0.udid == udid }) else { throw FakeSimError.noSuchDevice(udid) }
        devices[index].isBooted = true
        devices[index].state = "Booted"
        bootedUDIDs.append(udid)
    }

    /// UDIDs passed to `shutdownDevice`, in order.
    public private(set) var shutdownUDIDs: [String] = []

    public func shutdownDevice(udid: String) throws {
        lock.lock()
        defer { lock.unlock() }
        shutdownUDIDs.append(udid)
        guard let index = devices.firstIndex(where: { $0.udid == udid }) else { throw FakeSimError.noSuchDevice(udid) }
        devices[index].isBooted = false
        devices[index].state = "Shutdown"
    }

    /// Sim prep calls in order, as "erase U", "uninstall U B", "privacy U B", "keychain U".
    public private(set) var prepCalls: [String] = []
    /// Bundle ids whose uninstall or privacy reset throws.
    public var appResetFails: Set<String> = []
    /// UDIDs whose erase throws.
    public var eraseFails: Set<String> = []

    public func eraseDevice(udid: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let index = devices.firstIndex(where: { $0.udid == udid }) else { throw FakeSimError.noSuchDevice(udid) }
        // Like simctl: erasing needs a shut-down sim.
        guard !devices[index].isBooted, !eraseFails.contains(udid) else { throw FakeSimError.eraseFailed(udid) }
        prepCalls.append("erase \(udid)")
    }

    public func uninstallApp(udid: String, bundleID: String) throws {
        try appStep("uninstall", udid: udid, bundleID: bundleID)
    }

    public func resetAppPrivacy(udid: String, bundleID: String) throws {
        try appStep("privacy", udid: udid, bundleID: bundleID)
    }

    public func resetKeychain(udid: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard devices.contains(where: { $0.udid == udid && $0.isBooted }) else { throw FakeSimError.noSuchDevice(udid) }
        prepCalls.append("keychain \(udid)")
    }

    private func appStep(_ step: String, udid: String, bundleID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard devices.contains(where: { $0.udid == udid && $0.isBooted }) else { throw FakeSimError.noSuchDevice(udid) }
        guard !appResetFails.contains(bundleID) else { throw FakeSimError.appResetFailed(bundleID) }
        prepCalls.append("\(step) \(udid) \(bundleID)")
    }

    public func setDevices(_ newDevices: [SimDevice]) {
        lock.lock()
        defer { lock.unlock() }
        devices = newDevices
    }

    public func setPool(_ snapshot: PoolSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        pool = snapshot
    }

    // MARK: Template building (fake)

    /// `(udid, arguments)` for every `slim` call, in order.
    public private(set) var slimCalls: [(udid: String, arguments: [String])] = []
    /// Set to make `slim` throw.
    public var slimFails = false
    /// Cleared to act like a backend whose slim isn't wired (builds refused up front).
    public var slimWired = true
    /// Runs inside `createBaseDevice` before the sim exists (concurrency tests).
    public var beforeBaseCreate: (@Sendable () -> Void)?
    /// Set to make `createBaseDevice` create the sim and then throw (a create that
    /// half-failed: the sim exists, the caller got an error).
    public var baseCreateFailsAfterCreating = false
    /// What `toolVersions` reports.
    public var versions = TemplateToolVersions(xcode: "Xcode 26.0 (fake)", runtimes: ["iOS-26-0": "26.0 (fake)"])
    /// `(name, deviceType, runtime)` for every base create.
    public private(set) var baseCreates: [(name: String, deviceType: String, runtime: String)] = []
}

extension FakeSimBackend: TemplateBuilding {
    public func defaultTemplateTarget() throws -> (deviceType: String, runtime: String) {
        ("Fake-iPhone", "iOS-26-0")
    }
    public var slimSupported: Bool { slimWired }
    public func createBaseDevice(name: String, deviceType: String, runtime: String) throws -> SimDevice {
        lock.lock()
        baseCreates.append((name, deviceType, runtime))
        let hook = beforeBaseCreate
        let failAfter = baseCreateFailsAfterCreating
        lock.unlock()
        hook?()
        lock.lock()
        let device = makeDevice(name: name)
        lock.unlock()
        if failAfter { throw FakeSimError.timedOut("create \(name)") }
        return device
    }

    public func slim(udid: String, arguments: [String]) throws {
        lock.lock()
        defer { lock.unlock() }
        slimCalls.append((udid, arguments))
        if slimFails { throw FakeSimError.slimFailed(udid) }
    }

    public func toolVersions() throws -> TemplateToolVersions {
        lock.lock()
        defer { lock.unlock() }
        return versions
    }

    public func deleteTemplate(udid: String) throws { try deleteDevice(udid: udid) }
}

public enum FakeSimError: Error, Equatable {
    case deleteFailed(String)
    case timedOut(String)
    case bootFailed(String)
    case slimFailed(String)
    case noSuchDevice(String)
    case eraseFailed(String)
    case appResetFailed(String)
    case noTemplate
}

extension FakeSimBackend: TemplateCloneSource {
    public var templateCloneSource: (any TemplateCloneSource)? { clonesTemplate ? self : nil }
    public var configuredTemplate: String? { configuredTemplateValue }
    public var defaultTemplate: DefaultTemplate? {
        lock.lock()
        defer { lock.unlock() }
        return defaultTemplateValue
    }
    public func setDefaultTemplate(_ template: DefaultTemplate?) {
        lock.lock()
        defaultTemplateValue = template
        lock.unlock()
    }
}
