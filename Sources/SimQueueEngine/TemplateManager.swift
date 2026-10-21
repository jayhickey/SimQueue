// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueSim
import SimQueueStore

/// What to build: everything already resolved from flags, the project entry and config.
public struct TemplateBuildRequest: Sendable, Equatable {
    public var project: String
    public var profile: String
    public var slimArguments: [String]
    public var deviceType: String
    public var runtime: String
    public var replace: Bool
    public var slim: Bool

    public init(
        project: String, profile: String, slimArguments: [String], deviceType: String, runtime: String,
        replace: Bool = false, slim: Bool = false
    ) {
        self.project = project
        self.profile = profile
        self.slimArguments = slimArguments
        self.deviceType = deviceType
        self.runtime = runtime
        self.replace = replace
        self.slim = slim
    }
}

/// A build between step 1 (intent recorded) and step 3 (registered).
public struct PendingTemplate: Sendable, Equatable {
    public var intent: ActionIntent
    public var record: TemplateRecord
    public var request: TemplateBuildRequest
}

public enum TemplateBuildOutcome: Sendable, Equatable {
    case createFailed(String)
    case built(SimDevice, slimFailure: String?)
}

/// A registered template and its ownership row.
public struct TemplateEntry: Sendable, Equatable {
    public var resourceID: Int64
    public var record: TemplateRecord
    /// Nil when the tool versions couldn't be read.
    public var stale: Bool?
}

public enum TemplateError: Error, Equatable, CustomStringConvertible {
    case notSupported
    case alreadyExists(project: String, profile: String, name: String)
    case notFound(String)
    case slimFailed(name: String, reason: String)
    case createFailed(String)
    case inProgress(project: String, profile: String)
    case slimNotWired
    /// The pool is off or doesn't act on the host, so a template build (a sim create) is refused.
    case poolDisabled(String)
    case poolCreateInFlight(template: String, clones: [String])

    public var description: String {
        switch self {
        case .notSupported: "this sim backend can't build templates"
        case .alreadyExists(let project, let profile, let name):
            "\(project)/\(profile) already has a template (\(name)); pass --replace to build a new one"
        case .notFound(let what): "no template matches \(what) (registered or not)"
        case .createFailed(let reason): "creating the template failed: \(reason)"
        case .inProgress(let project, let profile): "a template build for \(project)/\(profile) is already running"
        case .poolCreateInFlight(let template, let clones):
            "pool sim \(clones.joined(separator: ", ")) is being cloned from template \(template); retry once the create finishes"
        case .slimNotWired:
            "this sim backend can't slim a template; install simslim or build without --slim"
        case .poolDisabled(let reason): "template build refused: \(reason)"
        case .slimFailed(let name, let reason):
            "built \(name) but slimming it failed (\(reason)); it stays registered as slim_failed, remove it with simq template rm"
        }
    }
}

/// What `removeTemplate` did.
public enum TemplateRemoval: String, Sendable, Equatable {
    case removed
    /// Report-only mode: audited, nothing deleted.
    case wouldRemove = "would_remove"
    /// Held by the destructive-action rate limits; try again later.
    case postponed
}

extension Engine {
    public static let templateBuiltAuditType = "template_built"
    public static let templateRemovedAuditType = "template_removed"

    var templateBuilder: TemplateBuilding? { environment.sims as? TemplateBuilding }

    /// The clone default: the newest `ready` template row of any project (by build time),
    /// preferring ones that aren't stale against `versions` (stale or unknown ones are used
    /// only when nothing fresh exists). Nil when there's no ready template. Never runs a tool.
    public func newestReadyTemplate(versions: TemplateToolVersions? = nil) throws -> TemplateEntry? {
        let ready = try templates(versions: versions).filter { $0.record.status == "ready" }
        let fresh = ready.filter { $0.stale != true }
        return (fresh.isEmpty ? ready : fresh).max { $0.record.builtAt < $1.record.builtAt }
    }

    /// Candidate creation never selects a host template. Only explicit backend
    /// configuration may select one; clear legacy implicit defaults on every refresh.
    public func refreshDefaultTemplate() {
        guard let source = environment.sims.templateCloneSource else { return }
        source.setDefaultTemplate(nil)
    }

    /// Live template rows, decoded. Rows whose detail doesn't decode are skipped. `versions`
    /// (the host's tool versions, from a cache the caller keeps) decides `stale`; nil
    /// leaves it unknown. Never runs a tool.
    public func templates(versions: TemplateToolVersions? = nil) throws -> [TemplateEntry] {
        try store.liveResources(kinds: [.template]).compactMap { resource in
            guard let detail = resource.detail,
                let record = try? JSONDecoder().decode(TemplateRecord.self, from: Data(detail.utf8))
            else { return nil }
            return TemplateEntry(
                resourceID: resource.id, record: record, stale: versions.map { record.isStale(current: $0) })
        }
    }

    /// `simq-template-...` sims with no template row (a build that died between create and
    /// register, or one made by hand). Never reaped; doctor lists them and `simq template
    /// rm <udid>` removes one through the cleanup gate.
    /// Pass `devices` to reuse a listing the caller already has.
    public func unregisteredTemplateSims(in devices: [SimDevice]? = nil) throws -> [SimDevice] {
        let registered = Set(try store.liveResources(kinds: [.template]).map(\.externalID))
        return try (devices ?? environment.sims.listDevices()).filter {
            environment.naming.isTemplate($0.name) && !registered.contains($0.udid)
        }
    }

    /// Prefix of a template create intent's detail; the rest is the pending record (JSON,
    /// `udid` empty), so recovery can register a create that finished before a crash.
    static let pendingTemplatePrefix = "template-pending "
    /// The prefix before the rename to template; a pending intent written by an older simqd
    /// is still recovered.
    static let legacyPendingTemplatePrefix = "golden-pending "

    /// Step 1 of a build (under the service lock): checks, then the write-ahead intent
    /// carrying the pending record. Nothing is created yet.
    public func beginTemplateBuild(_ request: TemplateBuildRequest, versions: TemplateToolVersions) throws
        -> PendingTemplate
    {
        guard let builder = templateBuilder else { throw TemplateError.notSupported }
        guard !request.slim || builder.slimSupported else { throw TemplateError.slimNotWired }
        try checkPoolAllowsTemplateBuild()
        let now = environment.clock.now()
        if !request.replace,
            let existing = try templates().first(where: {
                $0.record.project == request.project && $0.record.profile == request.profile
            })
        {
            throw TemplateError.alreadyExists(
                project: request.project, profile: request.profile, name: existing.record.name)
        }
        let naming = environment.naming
        // Matched on the pending record's fields, not a name prefix: with hyphens allowed,
        // "a-b"/"c" and "a"/"b-c" share one.
        if try store.pendingActionIntents().contains(where: {
            guard let pending = Self.pendingRecord(in: $0) else { return false }
            return pending.project == request.project && pending.profile == request.profile
        }) {
            throw TemplateError.inProgress(project: request.project, profile: request.profile)
        }
        var record = TemplateRecord(
            project: request.project, profile: request.profile, name: "", udid: "", deviceType: request.deviceType,
            runtime: request.runtime, xcodeVersion: versions.xcode,
            runtimeVersion: versions.runtimeVersion(for: request.runtime), builtAt: now, status: "pending")
        let intent = try store.recordActionIntent(
            ActionIntent(target: .simCreate(name: ""), auditType: Self.templateBuiltAuditType, detail: ""), now: now
        ) { .simCreate(name: naming.templateName(project: request.project, profile: request.profile, intentID: $0)) }
        guard case .simCreate(let name) = intent.target else { preconditionFailure("create intent target") }
        record.name = name
        var pending = intent
        pending.detail =
            Self.pendingTemplatePrefix + String(decoding: try JSONEncoder.sorted.encode(record), as: UTF8.self)
        try store.updateActionIntentDetail(pending)
        templateBuildsInFlight.insert(pending.id)
        return PendingTemplate(intent: pending, record: record, request: request)
    }

    /// A template is a pool resource, so building one follows `pool.mode` (not the watchdog's
    /// `cleanup_mode`): it's refused when there is no pool or the pool doesn't act on the
    /// host. Removal (`removeTemplate`) stays behind the cleanup gate.
    public func checkPoolAllowsTemplateBuild() throws {
        guard !maintenanceDraining else { throw TemplateError.poolDisabled("daemon is draining") }
        guard let pool else {
            throw TemplateError.poolDisabled(
                "the sim pool is off (no pool section in config.json); configure pool, with pool.mode active")
        }
        guard !pool.actsOnHost(cleanupMode: reliability.cleanupMode) else { return }
        switch pool.mode {
        case .reportOnly:
            throw TemplateError.poolDisabled("pool.mode is report-only; set pool.mode to active to build templates")
        case .followCleanup, .active:
            throw TemplateError.poolDisabled(
                "pool.mode is follow-cleanup and cleanup_mode is report-only; set pool.mode to active "
                    + "(or cleanup_mode to enforce) to build templates")
        }
    }

    /// The pending record a template create intent carries, if it is one.
    static func pendingRecord(in intent: ActionIntent) -> TemplateRecord? {
        guard
            let prefix = [pendingTemplatePrefix, legacyPendingTemplatePrefix].first(where: intent.detail.hasPrefix)
        else { return nil }
        return try? JSONDecoder().decode(TemplateRecord.self, from: Data(intent.detail.dropFirst(prefix.count).utf8))
    }

    /// Step 2 (outside the service lock: it runs simctl and simslim): create and slim.
    /// Touches no state; a crash here leaves the intent for recovery.
    public static func performTemplateBuild(_ pending: PendingTemplate, builder: TemplateBuilding)
        -> TemplateBuildOutcome
    {
        let device: SimDevice
        do {
            device = try builder.createBaseDevice(
                name: pending.record.name, deviceType: pending.request.deviceType, runtime: pending.request.runtime)
        } catch {
            return .createFailed("\(error)")
        }
        guard pending.request.slim else { return .built(device, slimFailure: nil) }
        do {
            try builder.slim(udid: device.udid, arguments: pending.request.slimArguments)
            return .built(device, slimFailure: nil)
        } catch {
            return .built(device, slimFailure: "\(error)")
        }
    }

    /// Step 3 (under the service lock): register the template row and settle the intent.
    @discardableResult
    public func finishTemplateBuild(_ pending: PendingTemplate, outcome: TemplateBuildOutcome) throws -> TemplateRecord
    {
        defer { templateBuildsInFlight.remove(pending.intent.id) }
        let now = environment.clock.now()
        // Re-checked under the lock: only a still-pending intent is settled here. Recovery
        // skips in-flight builds, but this never confirms or abandons an intent twice.
        let stillPending = try store.pendingActionIntents().contains { $0.id == pending.intent.id }
        switch outcome {
        case .createFailed(let reason):
            // The sim may exist anyway; then it's an unregistered template (doctor lists it).
            if stillPending { try? store.abandonActionIntent(pending.intent, reason: reason, now: now) }
            throw TemplateError.createFailed(reason)
        case .built(let device, let slimFailure):
            var record = pending.record
            record.udid = device.udid
            record.status = slimFailure == nil ? "ready" : "slim_failed"
            record.slimmed = pending.request.slim && slimFailure == nil
            try registerTemplate(record, now: now)
            if stillPending {
                var confirmed = pending.intent
                confirmed.detail = "\(record.name) \(device.udid) \(record.status)"
                try store.confirmActionIntent(confirmed, now: now)
            }
            if let slimFailure { throw TemplateError.slimFailed(name: record.name, reason: slimFailure) }
            refreshDefaultTemplate()
            return record
        }
    }

    /// Registers `record`, or rewrites the live template row for its UDID if there is one
    /// (recovery may have registered it as `unverified`).
    func registerTemplate(_ record: TemplateRecord, now: Double) throws {
        let detail = String(decoding: try JSONEncoder.sorted.encode(record), as: UTF8.self)
        if let existing = try store.liveResources(kinds: [.template]).first(where: { $0.externalID == record.udid }) {
            try store.updateResourceDetail(id: existing.id, detail: detail)
            return
        }
        _ = try store.acquireResource(
            kind: .template, externalID: record.udid, owner: .pool, epoch: epoch, detail: detail, now: now)
    }

    /// Recovery for a template create intent whose sim exists: register it from the pending
    /// record as `unverified` (the slim may not have run). Returns false if the intent
    /// isn't a template build.
    func recoverTemplateCreate(_ intent: ActionIntent, device: SimDevice, now: Double) throws -> Bool {
        guard var record = Self.pendingRecord(in: intent) else { return false }
        record.udid = device.udid
        record.status = "unverified"
        if try !store.liveResources(kinds: [.template]).contains(where: { $0.externalID == device.udid }) {
            try registerTemplate(record, now: now)
        }
        try store.audit(
            "template_recovered",
            detail: "\(record.name) \(device.udid): registered after a crash; rebuild with --replace",
            now: now)
        return true
    }

    /// All three steps in one call (engine tests; the daemon runs step 2 unlocked).
    @discardableResult
    public func buildTemplate(_ request: TemplateBuildRequest) throws -> TemplateRecord {
        guard let builder = templateBuilder else { throw TemplateError.notSupported }
        let pending = try beginTemplateBuild(request, versions: try builder.toolVersions())
        return try finishTemplateBuild(pending, outcome: Self.performTemplateBuild(pending, builder: builder))
    }

    /// Removes a template (by name or UDID) through the cleanup gate: report-only mode
    /// audits it and keeps it; the destructive-action limits can postpone it.
    @discardableResult
    public func removeTemplate(_ nameOrUDID: String) throws -> TemplateRemoval {
        guard let builder = templateBuilder else { throw TemplateError.notSupported }
        let registered = try templates().first { $0.record.name == nameOrUDID || $0.record.udid == nameOrUDID }
        let unregistered =
            registered == nil
            ? try unregisteredTemplateSims().first { $0.name == nameOrUDID || $0.udid == nameOrUDID } : nil
        guard
            let target = registered.map({ ($0.record.name, $0.record.udid, Optional($0.resourceID)) })
                ?? unregistered.map({ ($0.name, $0.udid, nil) })
        else { throw TemplateError.notFound(nameOrUDID) }
        let entry = (record: (name: target.0, udid: target.1), resourceID: target.2)
        let now = environment.clock.now()
        let udid = entry.record.udid
        var gate = CleanupGate(
            config: reliability,
            executedLastHour: try store.auditCount(type: Self.destructiveAuditType, since: now - 3600),
            executedThisPass: 0)
        let what = "template \(entry.record.name) (\(udid))"
        // A pool create clones this template unlocked; deleting it mid-clone would break the
        // clone and the intent's recovery. Refused, not postponed: the caller retries.
        let clones = try poolCreatesInFlight(fromTemplate: entry.record.name, udid: udid)
        guard clones.isEmpty else {
            try store.audit("template_remove_refused", detail: "\(what): pool create in flight", now: now)
            throw TemplateError.poolCreateInFlight(template: entry.record.name, clones: clones)
        }
        switch gate.decide(firstSeenAt: now, now: now, graceSeconds: 0) {
        case .execute:
            guard environment.naming.owns(entry.record.name) else {
                throw EngineError.cleanupNotVerified("\(what) is outside the namespace")
            }
            let present = try environment.sims.listDevices().contains { $0.udid == udid }
            if present {
                let intent = ActionIntent(
                    target: .sim(udid: udid), auditType: Self.templateRemovedAuditType, detail: "removed \(what)",
                    resourceID: entry.resourceID, releaseReason: "template removed")
                try performUnderIntent(intent, now: now) {
                    try builder.deleteTemplate(udid: udid)
                    if try environment.sims.listDevices().contains(where: { $0.udid == udid }) {
                        throw EngineError.cleanupNotVerified("sim \(udid)")
                    }
                }
            } else {
                if let id = entry.resourceID {
                    try store.markResourceReleased(id: id, reason: "template already gone", now: now)
                }
            }
            try store.audit(Self.destructiveAuditType, detail: "removed \(what)", now: now)
            refreshDefaultTemplate()
            return .removed
        case .wouldExecute:
            try store.audit("template_would_remove", detail: what, now: now)
            return .wouldRemove
        case .deferRateLimit, .deferGrace:
            try store.audit("template_remove_postponed", detail: what, now: now)
            return .postponed
        }
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
