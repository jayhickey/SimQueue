// SPDX-License-Identifier: MIT

import Foundation

public struct DashboardSettings: Equatable, Sendable {
    public var bindAddress: String
    public var port: UInt16
    private static let addressKey = "DashboardBindAddress"
    private static let portKey = "DashboardPort"

    public init(bindAddress: String = "127.0.0.1", port: UInt16 = 0) {
        self.bindAddress = bindAddress
        self.port = port
    }

    public init(address: String, portText: String) throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0).map { String($0) } == String($0) }) else {
            throw SettingsError.address
        }
        let text = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let port = UInt16(text) else {
            throw SettingsError.port
        }
        self.init(bindAddress: address, port: port)
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        let address = defaults.string(forKey: addressKey) ?? "127.0.0.1"
        let port = defaults.object(forKey: portKey).map { String(describing: $0) } ?? "0"
        return (try? Self(address: address, portText: port)) ?? Self()
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(bindAddress, forKey: Self.addressKey)
        defaults.set(Int(port), forKey: Self.portKey)
    }

    public enum SettingsError: Error, LocalizedError {
        case address, port
        public var errorDescription: String? {
            switch self {
            case .address: "Enter a numeric IPv4 address, such as 127.0.0.1 or this Mac’s Tailscale IP."
            case .port: "Enter a port from 0 to 65535. Use 0 to choose an available port."
            }
        }
    }
}
