// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueHost

public enum SimctlBackendError: Error, Equatable, CustomStringConvertible {
    case simslimUnsupported(String)
    case outsideNamespace(String)
    case unparseable(String)
    case createNotConfirmed(String)
    case deleteNotConfirmed(String)
    case noTemplate

    public var description: String {
        switch self {
        case .simslimUnsupported(let why): "simslim can't be used: \(why)"
        case .outsideNamespace(let what): "refused: \(what) is outside SimQueue's sim namespace"
        case .unparseable(let what): "couldn't parse \(what)"
        case .createNotConfirmed(let name): "simctl clone returned but \(name) isn't listed"
        case .deleteNotConfirmed(let udid): "simctl delete returned but \(udid) is still listed"
        case .noTemplate: noTemplateMessage
        }
    }
}

/// Real simulators via `xcrun simctl`, with optional simslim template slimming. Every call
/// has a timeout. Creating and deleting are confirmed against a fresh `simctl list`, so a
/// failed delete is never reported as done. It only ever touches sims named inside
/// SimQueue's namespace (`simq-`).
public final class SimctlBackend: SimBackend, @unchecked Sendable {
    public let kind: BackendKind = .simctl
    /// The default stock clone does not boot. Explicit slim clones carry per-operation
    /// boot reservations in their immutable plan instead of changing this backend default.
    public var createBoots: Bool { false }
    /// The explicitly selected source; creation never selects a template implicitly.
    public var cloneSource: String? { cloneTemplate }

    public struct Timeouts: Sendable, Equatable {
        public var list: Double = 30
        public var clone: Double = 600
        public var boot: Double = 120
        public var bootStatus: Double = 600
        public var shutdown: Double = 120
        public var delete: Double = 120
        public var probe: Double = 15
        public init() {}
    }

    public let runner: ToolRunner
    /// `simctl.template`, the configured override. Nil: clones copy `defaultTemplate`.
    public let template: String?
    private var defaultTemplateValue: DefaultTemplate?
    public let naming: SimNamingScheme
    public let timeouts: Timeouts
    private let lock = NSLock()
    private var capabilities: SimslimCapabilities?
    private var canSlim: Bool?

    /// `template` (optional) is the template sim `simctl clone` copies (name or UDID).
    /// The engine requires explicit selection for managed cloning; building a template
    /// never changes that selection. The daemon uses this backend by default on macOS
    /// (`BackendGate`); nothing here runs a tool.
    public init(
        template: String? = nil, runner: ToolRunner, naming: SimNamingScheme = SimNamingScheme(),
        timeouts: Timeouts = Timeouts()
    ) throws {
        self.template = template
        self.runner = runner
        self.naming = naming
        self.timeouts = timeouts
    }

    // MARK: - Reads

    public func listDevices() throws -> [SimDevice] {
        try Self.parseDeviceList(
            try runner.check("xcrun", ["simctl", "list", "-j", "devices"], timeoutSeconds: timeouts.list))
    }

    /// `xcrun simctl list -j devices`: `{"devices": {"<runtime>": [{"udid", "name", "state", ...}]}}`.
    public static func parseDeviceList(_ json: String) throws -> [SimDevice] {
        struct Listing: Decodable {
            struct Device: Decodable {
                var udid: String
                var name: String
                var state: String
                var deviceTypeIdentifier: String?
            }
            var devices: [String: [Device]]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: Data(json.utf8)) else {
            throw SimctlBackendError.unparseable("simctl list -j devices")
        }
        return listing.devices.keys.sorted().flatMap { runtime in
            listing.devices[runtime, default: []].map {
                SimDevice(
                    udid: $0.udid, name: $0.name, isBooted: $0.state == "Booted", state: $0.state, runtime: runtime,
                    deviceType: $0.deviceTypeIdentifier)
            }
        }
    }

    public func poolSnapshot() throws -> PoolSnapshot {
        PoolSnapshot(idleRunning: try listDevices().filter { naming.owns($0.name) && $0.isBooted }.count)
    }

    // MARK: - simslim capability check

    /// `simslim --version` must work and `simslim --help` must list `clone`; `verify` is
    /// optional (recorded). Checked once, before the first clone.
    public func simslimCapabilities() throws -> SimslimCapabilities {
        if let cached = lock.withLock({ capabilities }) { return cached }
        let version: String
        let help: String
        do {
            version = try runner.check("simslim", ["--version"], timeoutSeconds: timeouts.probe)
            help = try runner.check("simslim", ["--help"], timeoutSeconds: timeouts.probe)
        } catch {
            throw SimctlBackendError.simslimUnsupported("\(error)")
        }
        let found = SimslimCapabilities.parse(version: version, help: help)
        guard found.clone else { throw SimctlBackendError.simslimUnsupported("no clone command in simslim --help") }
        lock.withLock { capabilities = found }
        return found
    }

    // MARK: - Writes

    public func createDevice(name: String) throws -> SimDevice {
        try createDevice(name: name, cloneSource: cloneTemplate)
    }

    /// Clones exactly `cloneSource` (the pool passes what its create intent recorded), not
    /// whatever `cloneTemplate` says by the time the clone runs.
    public func createDevice(name: String, cloneSource: String?) throws -> SimDevice {
        guard naming.owns(name) else { throw SimctlBackendError.outsideNamespace(name) }
        guard let source = cloneSource else { throw SimctlBackendError.noTemplate }
        let previous = Set(try listDevices().map(\.udid))
        let output = try runner.check("xcrun", ["simctl", "clone", source, name], timeoutSeconds: timeouts.clone)

        return try confirmCreated(name: name, output: output, excluding: previous)
    }

    public func prepareClone(name: String, plan: SimClonePlan) throws -> SimClonePreparation {
        guard naming.owns(name), !naming.isTemplate(name) else { throw SimctlBackendError.outsideNamespace(name) }
        if plan.boots { _ = try simslimCapabilities() }
        let devices = try listDevices()
        guard !devices.contains(where: { $0.name == name }) else { throw SimctlBackendError.createNotConfirmed(name) }
        if plan.boots { _ = try slimCloneSource(plan, in: devices, requireShutdown: true) }
        return SimClonePreparation(
            name: name, plan: plan, previousUDIDs: Set(devices.map(\.udid)), sourceWasShutdown: plan.boots)
    }

    private func slimCloneSource(_ plan: SimClonePlan, in devices: [SimDevice], requireShutdown: Bool) throws
        -> SimDevice
    {
        guard let source = plan.source, let ref = plan.sourceRef,
            ref.udid == source, let expectedName = ref.name,
            naming.isTemplate(expectedName), naming.owns(expectedName),
            let device = devices.first(where: { $0.udid == source && $0.name == expectedName })
        else { throw SimctlBackendError.unparseable("slim clone needs an exact registered template source") }
        guard !requireShutdown || device.state == "Shutdown" else {
            throw SimctlBackendError.unparseable("shut down the selected slim template before cloning it")
        }
        return device
    }

    public func createPreparedDevice(_ prepared: SimClonePreparation) throws -> SimDevice {
        let name = prepared.name; let plan = prepared.plan
        guard naming.owns(name), !naming.isTemplate(name) else { throw SimctlBackendError.outsideNamespace(name) }
        guard let source = plan.source else { throw SimctlBackendError.noTemplate }
        let output: String
        if plan.boots {
            guard prepared.sourceWasShutdown, let sourceID = plan.sourceRef?.udid,
                sourceID == source, prepared.previousUDIDs.contains(sourceID)
            else { throw SimctlBackendError.unparseable("missing slim clone preflight proof") }
            // All slow preflight finished before the engine's final fresh boot gates.
            output = try runner.check("simslim", ["clone", source, name, "--json"], timeoutSeconds: timeouts.clone)
        } else {
            output = try runner.check("xcrun", ["simctl", "clone", source, name], timeoutSeconds: timeouts.clone)
        }
        let reported: String
        if plan.boots {
            struct Cloned: Decodable { var action: String; var udid: String; var name: String; var sourceUdid: String }
            guard let result = try? JSONDecoder().decode(Cloned.self, from: Data(output.utf8)),
                result.action == "clone", result.name == name,
                result.sourceUdid.caseInsensitiveCompare(source) == .orderedSame,
                let identifier = UUID(uuidString: result.udid),
                identifier.uuidString.caseInsensitiveCompare(result.udid) == .orderedSame
            else { throw SimctlBackendError.unparseable("simslim clone --json result") }
            // JSON contains both UUIDs: never feed it to lastUDID(in:).
            reported = identifier.uuidString
        } else {
            reported = output
        }
        let device = try confirmCreated(name: name, output: reported, excluding: prepared.previousUDIDs)
        if plan.boots {
            guard device.state == "Shutdown" else { throw SimctlBackendError.createNotConfirmed(name) }
            _ = try slimCloneSource(plan, in: listDevices(), requireShutdown: true)
        }
        return device
    }

    public func cleanUpInterruptedClone(_ prepared: SimClonePreparation) throws {
        let name = prepared.name; let plan = prepared.plan
        guard naming.owns(name), !naming.isTemplate(name) else { throw SimctlBackendError.outsideNamespace(name) }
        let devices = try listDevices()
        if let expected = prepared.expectedTargetUDID,
            devices.contains(where: { $0.udid == expected && $0.name != name })
        {
            throw SimctlBackendError.createNotConfirmed(name)
        }
        let targets = devices.filter { $0.name == name }
        guard targets.count <= 1,
            targets.allSatisfy({
                !prepared.previousUDIDs.contains($0.udid)
                    && (prepared.expectedTargetUDID == nil || prepared.expectedTargetUDID == $0.udid)
            })
        else {
            throw SimctlBackendError.createNotConfirmed(name)
        }
        if plan.boots {
            guard prepared.sourceWasShutdown, let sourceID = plan.sourceRef?.udid, sourceID == plan.source,
                prepared.previousUDIDs.contains(sourceID)
            else { throw SimctlBackendError.unparseable("missing source Shutdown proof") }
            _ = try slimCloneSource(plan, in: devices, requireShutdown: false)
        }
        for target in targets { try deleteDevice(udid: target.udid) }
        if plan.boots {
            let source = try slimCloneSource(plan, in: listDevices(), requireShutdown: false)
            if source.state != "Shutdown" { try shutdownDevice(udid: source.udid) }
            _ = try slimCloneSource(plan, in: listDevices(), requireShutdown: true)
        }
        guard try !listDevices().contains(where: { $0.name == name || $0.udid == prepared.expectedTargetUDID }) else {
            throw SimctlBackendError.deleteNotConfirmed(name)
        }
    }

    /// The UDID the create command reported must be listed under the name. No fallback to
    /// "any sim with that name": a mismatch could adopt a lookalike (#43). With no UDID in
    /// the output, the name must match exactly one sim.
    func confirmCreated(name: String, output: String, excluding previous: Set<String> = []) throws -> SimDevice {
        let listed = try listDevices().filter { $0.name == name && !previous.contains($0.udid) }
        if let reported = Self.lastUDID(in: output) {
            guard let device = listed.first(where: { $0.udid == reported }) else {
                throw SimctlBackendError.createNotConfirmed(name)
            }
            return device
        }
        guard listed.count == 1, let device = listed.first else {
            throw SimctlBackendError.createNotConfirmed(name)
        }
        return device
    }

    public func bootDevice(udid: String) throws {
        let device = try requireOwned(udid)
        if !device.isBooted {
            let result = try runner.run("xcrun", ["simctl", "boot", udid], timeoutSeconds: timeouts.boot)
            guard result.succeeded || result.stderr.contains("current state: Booted") else {
                throw ToolError.failed(
                    command: "xcrun simctl boot \(udid)", status: result.status, stderr: result.stderr)
            }
        }
        _ = try runner.check("xcrun", ["simctl", "bootstatus", udid, "-b"], timeoutSeconds: timeouts.bootStatus)
    }

    public func shutdownDevice(udid: String) throws {
        _ = try requireOwned(udid)
        let result = try runner.run("xcrun", ["simctl", "shutdown", udid], timeoutSeconds: timeouts.shutdown)
        guard result.succeeded || result.stderr.contains("current state: Shutdown") else {
            throw ToolError.failed(
                command: "xcrun simctl shutdown \(udid)", status: result.status, stderr: result.stderr)
        }
    }

    /// Deletes an owned sim and confirms it is gone from a fresh list. Throws (never
    /// returns) on a non-zero exit, a timeout, or a sim that is still listed.
    public func deleteDevice(udid: String) throws {
        guard let device = try listDevices().first(where: { $0.udid == udid }) else { return }  // already gone
        guard naming.owns(device.name), !naming.isTemplate(device.name) else {
            throw SimctlBackendError.outsideNamespace("\(device.name) (\(udid))")
        }
        _ = try runner.check("xcrun", ["simctl", "delete", udid], timeoutSeconds: timeouts.delete)
        guard try !listDevices().contains(where: { $0.udid == udid }) else {
            throw SimctlBackendError.deleteNotConfirmed(udid)
        }
    }

    private func requireOwned(_ udid: String) throws -> SimDevice {
        guard let device = try listDevices().first(where: { $0.udid == udid }), naming.owns(device.name) else {
            throw SimctlBackendError.outsideNamespace(udid)
        }
        return device
    }

    static func lastUDID(in text: String) -> String? {
        let pattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last, let found = Range(match.range, in: text) else {
            return nil
        }
        return String(text[found]).uppercased()
    }
}

// MARK: - Template building

/// A template is `simctl create` plus `simslim on <udid> --preserve-boot-state <profile args>`
/// (slims it, boots it slim once, returns it to shutdown) only when explicitly requested.
/// Stock templates do not require simslim. Only `simq-template-` sims are touched.
extension SimctlBackend: TemplateBuilding {
    public func createBaseDevice(name: String, deviceType: String, runtime: String) throws -> SimDevice {
        guard naming.owns(name), naming.isTemplate(name) else { throw SimctlBackendError.outsideNamespace(name) }
        let output = try runner.check(
            "xcrun", ["simctl", "create", name, deviceType, runtime], timeoutSeconds: timeouts.clone)
        return try confirmCreated(name: name, output: output)  // same rule as clones (#43)
    }

    /// True only when the installed simslim can slim (`simslim --help` lists `on`).
    public var slimSupported: Bool { simslimCanSlim() }

    /// Whether the installed simslim can slim a sim (`simslim --help` lists `on <udid>`).
    /// A missing or failing simslim is false. Only a yes is cached: a no is checked again
    /// next time, so installing or upgrading simslim takes effect without a daemon restart.
    public func simslimCanSlim() -> Bool {
        if lock.withLock({ canSlim == true }) { return true }
        let help = try? runner.run("simslim", ["--help"], timeoutSeconds: timeouts.probe)
        let found = help.map { $0.succeeded && Self.listsOnCommand($0.stdout + $0.stderr) } ?? false
        if found { lock.withLock { canSlim = true } }
        return found
    }

    /// Whether `simslim --help` lists the `on` command. First the 0.12.x command table: an
    /// indented `on <udid>` line. If no line matches, a fallback for other help layouts: a
    /// usage line (`simslim on ...`), an indented `on` followed by an argument placeholder
    /// (`on [options] <udid>`, `on UDID`), or a column-aligned `on` with a description (two
    /// or more spaces or a tab after it). Prose such as "on failure, ..." doesn't match.
    public static func listsOnCommand(_ help: String) -> Bool {
        let lines = help.split(whereSeparator: \.isNewline)
        let strict = lines.contains { line in
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return words.count >= 2 && words[0] == "on" && words[1].hasPrefix("<")
                && (line.hasPrefix(" ") || line.hasPrefix("\t"))
        }
        return strict || lines.contains(where: listsOnCommandFallback)
    }

    /// The fallback in `listsOnCommand`, for one help line.
    private static func listsOnCommandFallback(_ line: Substring) -> Bool {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        // A usage line: `simslim on <udid>`, `Usage: simslim on UDID`.
        if let at = words.firstIndex(where: { $0.lowercased() == "simslim" }), words.index(after: at) < words.endIndex,
            words[words.index(after: at)] == "on"
        {
            return true
        }
        // The rest are command-table lines: indented, `on` first.
        guard line.first == " " || line.first == "\t", words.first == "on" else { return false }
        guard words.count >= 2 else { return false }
        let argument = words[1]
        if argument.hasPrefix("<") || argument.hasPrefix("[") { return true }
        if ["udid", "device", "sim", "simulator"].contains(argument.lowercased()) { return true }
        // Column-aligned: `on` then a tab or two spaces, then a capitalized description.
        guard let on = line.range(of: "on") else { return false }
        let after = line[on.upperBound...]
        let gap = after.prefix(while: { $0 == " " || $0 == "\t" })
        return (gap.contains("\t") || gap.count >= 2) && argument.first?.isUppercase == true
    }

    /// Slims the template with `simslim on` and leaves it shut down. On failure the sim is
    /// shut down (best effort) and the error is reported; the caller registers it as
    /// `slim_failed`.
    public func slim(udid: String, arguments: [String]) throws {
        let device = try requireOwned(udid)
        guard naming.isTemplate(device.name) else { throw SimctlBackendError.outsideNamespace(device.name) }
        guard simslimCanSlim() else { throw SimctlBackendError.simslimUnsupported("no `on` command in simslim --help") }
        do {
            _ = try runner.check(
                "simslim", ["on", udid, "--preserve-boot-state"] + arguments, timeoutSeconds: timeouts.clone)
            if try listDevices().first(where: { $0.udid == udid })?.isBooted == true {
                try shutdownDevice(udid: udid)
            }
        } catch {
            try? shutdownDevice(udid: udid)
            throw error
        }
    }

    public func toolVersions() throws -> TemplateToolVersions {
        let xcode = try runner.check("xcodebuild", ["-version"], timeoutSeconds: timeouts.probe)
        let runtimes = try runner.check("xcrun", ["simctl", "list", "-j", "runtimes"], timeoutSeconds: timeouts.probe)
        return try Self.parseToolVersions(xcode: xcode, runtimesJSON: runtimes)
    }

    /// `xcodebuild -version` (its lines joined by spaces) and `simctl list -j runtimes`
    /// (`identifier` → `version`, keyed by the identifier's last component too, so a
    /// config may name `iOS-26-0` or the full identifier).
    public static func parseToolVersions(xcode: String, runtimesJSON: String) throws -> TemplateToolVersions {
        struct Listing: Decodable {
            struct Runtime: Decodable {
                var identifier: String
                var version: String
            }
            var runtimes: [Runtime]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: Data(runtimesJSON.utf8)) else {
            throw SimctlBackendError.unparseable("simctl list -j runtimes")
        }
        var runtimes: [String: String] = [:]
        for runtime in listing.runtimes {
            runtimes[runtime.identifier] = runtime.version
            if let short = runtime.identifier.split(separator: ".").last { runtimes[String(short)] = runtime.version }
        }
        let version = xcode.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return TemplateToolVersions(xcode: version, runtimes: runtimes)
    }

    public func defaultTemplateTarget() throws -> (deviceType: String, runtime: String) {
        let json = try runner.check("xcrun", ["simctl", "list", "-j", "runtimes"], timeoutSeconds: timeouts.probe)
        return try Self.parseDefaultTemplateTarget(runtimesJSON: json)
    }

    /// From `simctl list -j runtimes`: the available iOS runtime with the highest version,
    /// and the last iPhone in its supported device types (simctl lists them oldest first).
    public static func parseDefaultTemplateTarget(runtimesJSON: String) throws -> (deviceType: String, runtime: String)
    {
        struct Listing: Decodable {
            struct DeviceType: Decodable {
                var identifier: String
                var productFamily: String?
            }
            struct Runtime: Decodable {
                var identifier: String
                var version: String
                var platform: String?
                var isAvailable: Bool?
                var supportedDeviceTypes: [DeviceType]?
            }
            var runtimes: [Runtime]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: Data(runtimesJSON.utf8)) else {
            throw SimctlBackendError.unparseable("simctl list -j runtimes")
        }
        func parts(_ version: String) -> [Int] { version.split(separator: ".").map { Int($0) ?? 0 } }
        let candidates = listing.runtimes.filter { runtime in
            runtime.isAvailable != false
                && (runtime.platform == "iOS" || runtime.identifier.contains(".SimRuntime.iOS-"))
                && runtime.supportedDeviceTypes?.contains { $0.productFamily == "iPhone" } == true
        }
        guard
            let runtime = candidates.max(by: { parts($0.version).lexicographicallyPrecedes(parts($1.version)) }),
            let device = runtime.supportedDeviceTypes?.last(where: { $0.productFamily == "iPhone" })
        else { throw SimctlBackendError.unparseable("no available iOS runtime with an iPhone in simctl list") }
        return (device.identifier, runtime.identifier)
    }

    public func deleteTemplate(udid: String) throws {
        guard let device = try listDevices().first(where: { $0.udid == udid }) else { return }  // already gone
        guard naming.owns(device.name), naming.isTemplate(device.name) else {
            throw SimctlBackendError.outsideNamespace("\(device.name) (\(udid))")
        }
        _ = try runner.check("xcrun", ["simctl", "delete", udid], timeoutSeconds: timeouts.delete)
        guard try !listDevices().contains(where: { $0.udid == udid }) else {
            throw SimctlBackendError.deleteNotConfirmed(udid)
        }
    }
}

/// What the installed simslim supports.
public struct SimslimCapabilities: Sendable, Equatable {
    public var version: String
    public var clone: Bool
    public var verify: Bool

    public init(version: String, clone: Bool, verify: Bool) {
        self.version = version
        self.clone = clone
        self.verify = verify
    }

    public static func parse(version: String, help: String) -> SimslimCapabilities {
        let words = Set(help.split(whereSeparator: { !$0.isLetter && $0 != "-" }).map { $0.lowercased() })
        return SimslimCapabilities(
            version: version.trimmingCharacters(in: .whitespacesAndNewlines), clone: words.contains("clone"),
            verify: words.contains("verify"))
    }
}

extension SimctlBackend: TemplateCloneSource {
    public var templateCloneSource: (any TemplateCloneSource)? { self }
    public var configuredTemplate: String? { template }
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
