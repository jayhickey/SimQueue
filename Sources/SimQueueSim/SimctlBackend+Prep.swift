// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore

/// Per-job sim preparation (`fresh_sim`, `reset_apps`) on the real backend. Owned sims only.
extension SimctlBackend {
    /// Seconds allowed for one app-reset step (uninstall, privacy, keychain).
    public static let appResetTimeoutSeconds: Double = 60
    /// Seconds allowed for `simctl erase`.
    public static let eraseTimeoutSeconds: Double = 300

    public func eraseDevice(udid: String) throws {
        try requireOwnedForPrep(udid)
        _ = try runner.check("xcrun", ["simctl", "erase", udid], timeoutSeconds: Self.eraseTimeoutSeconds)
    }

    public func uninstallApp(udid: String, bundleID: String) throws {
        try requireOwnedForPrep(udid, bundleID: bundleID)
        _ = try runner.check(
            "xcrun", ["simctl", "uninstall", udid, bundleID], timeoutSeconds: Self.appResetTimeoutSeconds)
    }

    /// `simctl privacy reset all` doesn't cover notifications, and uninstalling keeps them, so
    /// the app's notification settings are reset too (`resetNotificationSettings`).
    public func resetAppPrivacy(udid: String, bundleID: String) throws {
        let dataPath = try requireOwnedForPrep(udid, bundleID: bundleID)
        _ = try runner.check(
            "xcrun", ["simctl", "privacy", udid, "reset", "all", bundleID], timeoutSeconds: Self.appResetTimeoutSeconds)
        guard let dataPath else { return }
        try resetNotificationSettings(udid: udid, dataPath: dataPath, bundleID: bundleID)
    }

    /// Drops the app's entry from the sim's BulletinBoard settings so its next request
    /// prompts again (as `notDetermined`). No entry (it never asked): nothing to do. The
    /// settings live in usernotificationsd and SpringBoard, so it stops usernotificationsd
    /// first (it's launched on demand and may not be running), edits the file, then stops
    /// both so they reload it; launchd relaunches SpringBoard.
    func resetNotificationSettings(udid: String, dataPath: String, bundleID: String) throws {
        let file = URL(fileURLWithPath: dataPath).appendingPathComponent(Self.notificationSettingsPath)
        guard try Self.notificationSettings(at: file)?[bundleID] != nil else { return }
        let stop = ["simctl", "spawn", udid, "launchctl", "stop"]
        let usernotificationsd = stop + ["com.apple.usernotificationsd"]
        _ = try runner.run("xcrun", usernotificationsd, timeoutSeconds: Self.appResetTimeoutSeconds)
        try Self.removeNotificationSettings(bundleID: bundleID, at: file)
        _ = try runner.run("xcrun", usernotificationsd, timeoutSeconds: Self.appResetTimeoutSeconds)
        _ = try runner.check("xcrun", stop + ["com.apple.SpringBoard"], timeoutSeconds: Self.appResetTimeoutSeconds)
    }

    /// Per-app notification settings, relative to a sim's data path (iOS 11 and later).
    static let notificationSettingsPath = "Library/BulletinBoard/VersionedSectionInfo.plist"

    /// The `sectionInfo` dictionary (bundle id: archived settings), nil if there's no file.
    static func notificationSettings(at file: URL) throws -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return plist?["sectionInfo"] as? [String: Any]
    }

    static func removeNotificationSettings(bundleID: String, at file: URL) throws {
        guard let data = FileManager.default.contents(atPath: file.path),
            var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            var sections = plist["sectionInfo"] as? [String: Any], sections[bundleID] != nil
        else { return }
        sections[bundleID] = nil
        plist["sectionInfo"] = sections
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: file, options: .atomic)
    }

    public func resetKeychain(udid: String) throws {
        try requireOwnedForPrep(udid)
        _ = try runner.check(
            "xcrun", ["simctl", "keychain", udid, "reset"], timeoutSeconds: Self.appResetTimeoutSeconds)
    }

    /// Returns the sim's data path (`dataPath` in `simctl list -j devices`), if listed.
    @discardableResult
    private func requireOwnedForPrep(_ udid: String, bundleID: String? = nil) throws -> String? {
        let json = try runner.check("xcrun", ["simctl", "list", "-j", "devices"], timeoutSeconds: timeouts.list)
        guard let device = try Self.parseDeviceList(json).first(where: { $0.udid == udid }),
            naming.owns(device.name), !naming.isTemplate(device.name)
        else { throw SimctlBackendError.outsideNamespace(udid) }
        if let bundleID, !SimPrep.isValidBundleID(bundleID) {
            throw SimctlBackendError.outsideNamespace("bundle id \(bundleID)")
        }
        return Self.dataPath(udid: udid, listing: json)
    }

    static func dataPath(udid: String, listing json: String) -> String? {
        struct Listing: Decodable {
            struct Device: Decodable {
                var udid: String
                var dataPath: String?
            }
            var devices: [String: [Device]]
        }
        let listing = try? JSONDecoder().decode(Listing.self, from: Data(json.utf8))
        return listing?.devices.values.joined().first { $0.udid == udid }?.dataPath
    }
}
