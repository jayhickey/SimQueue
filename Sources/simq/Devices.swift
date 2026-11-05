// SPDX-License-Identifier: MIT

import ArgumentParser
import SimQueueCore

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List configured physical devices, health and leases.")
    @OptionGroup var connection: Connection
    func run() throws {
        guard case .status(let status) = try call(connection, .status) else { throw failure(.protocolError) }
        guard let devices = status.devices else { throw ValidationError("daemon does not support physical devices") }
        if connection.json { return try printJSON(devices) }
        if devices.isEmpty { print("no configured physical devices") }
        for device in devices { printDevice(device) }
    }
}

func printDevice(_ info: PhysicalDeviceInfo) {
    print(
        "physical \(info.device.udid) \(info.device.name): \(info.health.state) \(info.health.detail)"
            + (info.jobID.map { " leased by " + $0 } ?? "")
            + (info.health.thermal.map { " thermal=" + $0 } ?? "")
            + " labels=" + info.device.labels.joined(separator: ","))
}
