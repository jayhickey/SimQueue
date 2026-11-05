// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore

/// Read-only health probes. ToolRunner's environment permits a fake xcrun on PATH.
public struct Devicectl: Sendable {
    public var runner: ToolRunner
    public init(runner: ToolRunner = ToolRunner()) { self.runner = runner }

    private func json(_ arguments: [String]) throws -> [String: Any] {
        // JSON files work across Xcode versions, including versions without stdout JSON.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "simq-device-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try runner.check(
            "xcrun", ["devicectl"] + arguments + ["--timeout", "10", "--json-output", file.path], timeoutSeconds: 15)
        let data = try Data(contentsOf: file)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = root["result"] as? [String: Any]
        else {
            throw DeviceProbeError.invalidJSON
        }
        return result
    }

    public func health(udid: String) -> DeviceHealth {
        do {
            let details = try json(["device", "info", "details", "--device", udid])
            let device = details["device"] as? [String: Any] ?? details
            let properties = device["properties"] as? [String: Any] ?? [:]
            let connection =
                device["connectionProperties"] as? [String: Any]
                ?? properties["connection"] as? [String: Any] ?? [:]
            let features =
                device["deviceProperties"] as? [String: Any]
                ?? properties["state"] as? [String: Any] ?? [:]
            let mode = features["developerModeStatus"]
            let enabled = (mode as? [String: Any])?["enabled"] as? [String: Any]
            let modeEnabled = (mode as? String == "enabled") || enabled != nil
            let thermal = features["thermalState"] as? String
            guard connection["pairingState"] as? String == "paired" else {
                return DeviceHealth(
                    state: "device_unpaired", detail: "devicectl did not confirm pairing", thermal: thermal)
            }
            guard modeEnabled else {
                return DeviceHealth(
                    state: "developer_mode_disabled", detail: "devicectl did not confirm Developer Mode",
                    thermal: thermal)
            }
            // Details may return cached properties even when connection failed.
            guard (connection["tunnelState"] ?? connection["state"]) as? String == "connected" else {
                return DeviceHealth(
                    state: "device_unavailable", detail: "devicectl did not confirm a connected tunnel",
                    thermal: thermal)
            }
            let lock = try json(["device", "info", "lockState", "--device", udid])
            // CoreDevice's LockStateProtocol uses these fields on current Xcode.
            // Older adapters can expose isLocked directly. An unlocked-since-boot
            // flag alone does not establish the device's current lock state.
            let required = lock["isPasscodeRequired"] as? Bool
            let unlocked = lock["hasBeenUnlockedSinceBoot"] as? Bool
            let locked =
                lock["isLocked"] as? Bool
                ?? required.map { $0 || unlocked != true }
            guard let locked else {
                return DeviceHealth(
                    state: "device_unavailable", detail: "devicectl lock state unavailable; unlock cannot be verified",
                    thermal: thermal)
            }
            return DeviceHealth(
                state: locked ? "device_locked" : "ready",
                detail: locked
                    ? "unlock the device before leasing" : "connected, paired, Developer Mode enabled, unlocked",
                thermal: thermal)
        } catch {
            let detail = String(describing: error)
            let lower = detail.lowercased()
            let state =
                lower.contains("locked")
                ? "device_locked" : lower.contains("unpaired") ? "device_unpaired" : "device_unavailable"
            return DeviceHealth(state: state, detail: detail)
        }
    }
}

private enum DeviceProbeError: Error { case invalidJSON }
