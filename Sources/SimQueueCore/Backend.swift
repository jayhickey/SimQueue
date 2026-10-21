// SPDX-License-Identifier: MIT

/// Which simulator backend the daemon drives.
public enum BackendKind: String, Sendable, CaseIterable {
    /// In-process fake simulators: tests, demos, dry runs, and Linux.
    case fake
    /// Real `xcrun simctl` + `simslim`. macOS only; the default there.
    case simctl

    /// True where `xcrun simctl` exists (macOS).
    public static var simctlAvailable: Bool {
        #if os(macOS)
            return true
        #else
            return false
        #endif
    }

    /// The backend `simqd` uses when nothing picks one (no `--backend`, no config
    /// `backend`): simctl on macOS, fake elsewhere.
    public static var platformDefault: BackendKind { simctlAvailable ? .simctl : .fake }
}

public enum BackendGateError: Error, Equatable, CustomStringConvertible {
    case simctlNeedsMacOS

    public var description: String {
        switch self {
        case .simctlNeedsMacOS:
            return "The simctl backend needs macOS (xcrun simctl). Use --backend fake on this platform."
        }
    }
}

/// Decides whether a requested backend may start. Pure, so it is unit-tested everywhere.
public enum BackendGate {
    /// The backend `simqd` runs: `--backend`, else fake for a dry run (whatever the config
    /// says), else the config's `backend`, else the platform default (simctl on macOS).
    public static func choose(flag: BackendKind?, config: BackendKind?, dryRun: Bool) -> BackendKind {
        flag ?? (dryRun ? .fake : config ?? .platformDefault)
    }

    public static func resolve(
        requested: BackendKind, simctlAvailable: Bool = BackendKind.simctlAvailable
    ) throws -> BackendKind {
        switch requested {
        case .fake:
            return .fake
        case .simctl:
            guard simctlAvailable else { throw BackendGateError.simctlNeedsMacOS }
            return .simctl
        }
    }
}
