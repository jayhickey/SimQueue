// SPDX-License-Identifier: MIT

import CoreFoundation
import Foundation

/// The app agent is per user and uses the default state directory. CLI autostart
/// must be disabled before registering it, so clients cannot race its manager.
public enum AppDaemonSettings {
    public static let label = "dev.simqueue.app-daemon"
    public static let plistName = label + ".plist"

    public static func validate(config: Data, stateDirectory: String, home: String) throws {
        guard stateDirectory == home + "/Library/Application Support/SimQueue" else {
            throw SettingsError.customState
        }
        guard let object = try JSONSerialization.jsonObject(with: config) as? [String: Any],
            let enabled = object["autostart"] as? NSNumber,
            CFGetTypeID(enabled) == CFBooleanGetTypeID(), !enabled.boolValue
        else { throw SettingsError.autostartEnabled }
    }

    public enum SettingsError: Error, LocalizedError {
        case customState, autostartEnabled
        public var errorDescription: String? {
            switch self {
            case .customState:
                "The bundled daemon uses the default state directory. Remove SIMQ_STATE_DIR from the app environment first."
            case .autostartEnabled:
                "Set autostart to false in config.json before using the bundled daemon. See the menu bar installation guide."
            }
        }
    }
}
