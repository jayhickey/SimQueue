// SPDX-License-Identifier: MIT

import Foundation

public struct PhysicalDevice: Sendable, Equatable, Codable {
    public var udid: String
    public var name: String
    public var labels: [String]
    public var enabled: Bool

    public init(udid: String, name: String, labels: [String] = [], enabled: Bool = true) {
        self.udid = udid; self.name = name; self.labels = labels; self.enabled = enabled
    }
    public func matches(_ request: String) -> Bool { enabled && (udid == request || labels.contains(request)) }
    enum CodingKeys: String, CodingKey { case udid, name, labels, enabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            udid: try c.decode(String.self, forKey: .udid), name: try c.decode(String.self, forKey: .name),
            labels: try c.decodeIfPresent([String].self, forKey: .labels) ?? [],
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true)
    }
}

public struct DeviceHealth: Sendable, Equatable, Codable {
    /// ready, device_locked, device_unavailable, device_unpaired, developer_mode_disabled.
    public var state: String
    public var detail: String
    public var thermal: String?
    public init(state: String, detail: String = "", thermal: String? = nil) {
        self.state = state; self.detail = detail; self.thermal = thermal
    }
    public var ready: Bool { state == "ready" }
}

public struct PhysicalDeviceInfo: Sendable, Equatable, Codable {
    public var device: PhysicalDevice
    public var health: DeviceHealth
    public var jobID: String?
    public init(device: PhysicalDevice, health: DeviceHealth, jobID: String? = nil) {
        self.device = device; self.health = health; self.jobID = jobID
    }
}

public struct DeviceArtifact: Sendable, Equatable, Codable {
    public var bundle: String
    public var path: String
    public init(bundle: String, path: String) { self.bundle = bundle; self.path = path }
    public var isValid: Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.utf8.contains(0)
            && !path.split(separator: "/").contains("..") && path != "."
    }
}

extension JobCommand {
    /// Only recognized device operations gain destination arguments. All other commands
    /// retain the existing argv contract and can use SIMQ_UDID from their environment.
    public var executionArgv: [String] {
        guard let udid = physicalUDID else { return argv }
        var args = argv
        if URL(fileURLWithPath: args[0]).lastPathComponent == "xcodebuild" {
            // A physical lease is always the destination, including caller-supplied flags.
            while let index = args.firstIndex(of: "-destination"), index + 1 < args.count {
                args.removeSubrange(index...index + 1)
            }
            args += ["-destination", "id=\(udid)"]
        } else if args.count >= 5, URL(fileURLWithPath: args[0]).lastPathComponent == "xcrun",
            Array(args[1...2]) == ["devicectl", "device"],
            (["install", "app"] == Array(args[3...4]) || ["process", "launch"] == Array(args[3...4])
                || ["info", "processes"] == Array(args[3...4]))
        {
            let separator = args.firstIndex(of: "--") ?? args.count
            var options = Array(args[..<separator])
            while let index = options.firstIndex(of: "--device"), index + 1 < options.count {
                options.removeSubrange(index...index + 1)
            }
            options += ["--device", udid]
            if args[3] == "process", !options.contains("--terminate-existing") {
                options.append("--terminate-existing")
            }
            args = options + args[separator...]
        }
        guard let artifact = deviceArtifact else { return args }
        // Copy runs in the supervised command's process group. Cancel/timeout stops it
        // before the lease is reclaimed, with no independent device-side retry loop.
        let command = args.map(Self.shellQuote).joined(separator: " ")
        let copy = [
            "xcrun", "devicectl", "device", "copy", "from", "--device", udid,
            "--domain-type", "appDataContainer", "--domain-identifier", artifact.bundle,
            "--source", artifact.path, "--destination",
        ].map(Self.shellQuote).joined(separator: " ")
        let script = """
            \(command)
            status=$?
            \(copy) "$SIMQ_RUN_DIR/device-artifacts"
            copied=$?
            if [ "$copied" -ne 0 ]; then
              echo '=== simq: device artifact copy failed' >&2
              if [ "$status" -eq 0 ]; then exit 74; fi
            fi
            exit "$status"
            """
        return ["/bin/sh", "-c", script]
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
