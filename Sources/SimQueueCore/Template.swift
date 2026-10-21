// SPDX-License-Identifier: MIT

import Foundation

/// What a template sim was built from and with. Stored as the `template` ownership row's
/// detail, so the row alone says what the sim is.
public struct TemplateRecord: Sendable, Equatable, Codable {
    public var project: String
    public var profile: String
    public var name: String
    public var udid: String
    public var deviceType: String
    public var runtime: String
    /// `xcodebuild -version` and the runtime's version when it was built.
    public var xcodeVersion: String
    public var runtimeVersion: String
    public var builtAt: Double
    /// `ready`, or `slim_failed` (registered and kept; remove it with `simq template rm`).
    public var status: String
    /// Nil for templates recorded before explicit slimming metadata.
    public var slimmed: Bool?

    public init(
        project: String, profile: String, name: String, udid: String, deviceType: String, runtime: String,
        xcodeVersion: String, runtimeVersion: String, builtAt: Double, status: String = "ready", slimmed: Bool? = nil
    ) {
        self.project = project
        self.profile = profile
        self.name = name
        self.udid = udid
        self.deviceType = deviceType
        self.runtime = runtime
        self.xcodeVersion = xcodeVersion
        self.runtimeVersion = runtimeVersion
        self.builtAt = builtAt
        self.status = status
        self.slimmed = slimmed
    }

    enum CodingKeys: String, CodingKey {
        case project, profile, name, udid, runtime, status, slimmed
        case deviceType = "device_type"
        case xcodeVersion = "xcode_version"
        case runtimeVersion = "runtime_version"
        case builtAt = "built_at"
    }

    /// Stale when the host's Xcode or runtime version differs from the build's.
    public func isStale(current: TemplateToolVersions) -> Bool {
        current.xcode != xcodeVersion || current.runtimeVersion(for: runtime) != runtimeVersion
    }
}

/// The host's Xcode version and installed runtime versions (by runtime identifier).
public struct TemplateToolVersions: Sendable, Equatable {
    public var xcode: String
    public var runtimes: [String: String]

    public init(xcode: String, runtimes: [String: String]) {
        self.xcode = xcode
        self.runtimes = runtimes
    }

    /// The runtime's version, or `missing` when it isn't installed.
    public func runtimeVersion(for runtime: String) -> String { runtimes[runtime] ?? "missing" }
}
