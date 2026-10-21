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

    public func resetAppPrivacy(udid: String, bundleID: String) throws {
        try requireOwnedForPrep(udid, bundleID: bundleID)
        _ = try runner.check(
            "xcrun", ["simctl", "privacy", udid, "reset", "all", bundleID], timeoutSeconds: Self.appResetTimeoutSeconds)
    }

    public func resetKeychain(udid: String) throws {
        try requireOwnedForPrep(udid)
        _ = try runner.check(
            "xcrun", ["simctl", "keychain", udid, "reset"], timeoutSeconds: Self.appResetTimeoutSeconds)
    }

    private func requireOwnedForPrep(_ udid: String, bundleID: String? = nil) throws {
        guard let device = try listDevices().first(where: { $0.udid == udid }), naming.owns(device.name),
            !naming.isTemplate(device.name)
        else { throw SimctlBackendError.outsideNamespace(udid) }
        if let bundleID, !SimPrep.isValidBundleID(bundleID) {
            throw SimctlBackendError.outsideNamespace("bundle id \(bundleID)")
        }
    }
}
