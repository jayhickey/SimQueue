// SPDX-License-Identifier: MIT

/// Per-job sim preparation before the command runs. By default a job gets a warm, booted
/// pool sim as the previous job left it (no erase per lease). `reset_apps` resets named
/// apps in place; `fresh_sim` erases the sim first. Both apply to every pool sim the job
/// leases.
public enum SimPrep {
    /// Most `reset_apps` entries per job.
    public static let maxResetApps = 16
    public static let maxBundleIDLength = 255

    /// A bundle identifier as simctl takes it: letters, digits, `.` and `-`, starting with
    /// a letter or digit. Never passed through a shell.
    public static func isValidBundleID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, id.utf8.count <= maxBundleIDLength else { return false }
        func alnum(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        return alnum(first) && id.unicodeScalars.allSatisfy { alnum($0) || $0 == "." || $0 == "-" }
    }
}

/// What the notification part of one app's privacy reset found, so a permission that still
/// carried into a job can be traced (`sim_prep.notification_reset`).
public struct NotificationResetRecord: Sendable, Codable, Equatable {
    public var bundleID: String
    /// The app had an entry in the sim's notification settings. Nil: not checked (the sim's
    /// data path wasn't listed).
    public var found: Bool?
    /// The entry was gone when the reset finished (false when there was none to remove).
    public var removed: Bool

    public init(bundleID: String, found: Bool?, removed: Bool) {
        self.bundleID = bundleID
        self.found = found
        self.removed = removed
    }

    enum CodingKeys: String, CodingKey {
        case found, removed
        case bundleID = "bundle_id"
    }
}

/// What preparation did to one leased sim, recorded in the job result (`sim_prep`).
public struct SimPrepOutcome: Sendable, Codable, Equatable {
    public var udid: String
    /// Apps reset in place (uninstalled, privacy reset); empty after a fallback erase.
    public var appsReset: [String]
    public var keychainReset: Bool
    /// Per reset app, what the notification settings reset found and removed (kept after a
    /// fallback erase, as a record of what ran). Nil when the backend doesn't report it.
    public var notificationReset: [NotificationResetRecord]?
    /// The sim was erased (and booted again) before the command ran.
    public var erased: Bool
    /// Why an app reset fell back to an erase: the failing step's error. Nil when it didn't.
    public var fallbackReason: String?
    /// Preparation failed (the erase itself failed): the job ended as an infra failure and
    /// the sim is recycled.
    public var error: String?

    public init(
        udid: String, appsReset: [String] = [], keychainReset: Bool = false, erased: Bool = false,
        fallbackReason: String? = nil, error: String? = nil, notificationReset: [NotificationResetRecord]? = nil
    ) {
        self.udid = udid
        self.appsReset = appsReset
        self.keychainReset = keychainReset
        self.erased = erased
        self.fallbackReason = fallbackReason
        self.error = error
        self.notificationReset = notificationReset
    }

    enum CodingKeys: String, CodingKey {
        case udid, erased, error
        case appsReset = "apps_reset"
        case keychainReset = "keychain_reset"
        case fallbackReason = "fallback_reason"
        case notificationReset = "notification_reset"
    }
}
