// SPDX-License-Identifier: MIT

import SimQueueCore

/// Stable `simq` exit codes. Scripts and CI depend on these: add codes, never renumber.
/// Codes below 64 describe the job; 64 and up follow sysexits for tool problems.
public enum SimQExitCode: Int32, Sendable, CaseIterable, Codable {
    /// Command succeeded (or the job succeeded, when waiting).
    case success = 0
    /// The job failed its tests (or failed in another non-build way).
    case testFailure = 1
    /// The job's build failed.
    case buildFailure = 2
    /// The job ran past its run timeout and was stopped (state `timed_out`).
    case timedOut = 3
    /// Infra failure (runner bootstrap, artifacts, internal). Safe to retry.
    case infraFailure = 4
    /// The job was canceled or interrupted.
    case canceled = 5
    /// The job's queue timeout passed before its first start (state `expired`).
    case expired = 6
    /// The client's own `--wait-timeout` ran out. The job itself is unchanged.
    case waitTimeout = 7
    /// Bad command-line usage (ArgumentParser's own validation also exits 64).
    case usage = 64
    /// The daemon rejected the request (malformed, unsupported schema version).
    case protocolError = 65
    /// Unknown job id.
    case notFound = 66
    /// The daemon isn't running or the socket can't be reached.
    case daemonUnavailable = 69
    /// Unexpected internal error.
    case internalError = 70
    /// Submit rejected: the submitter already has the maximum queued jobs for the
    /// project. Retry later.
    case queueFull = 73

    /// Exit code for a job that reached a terminal state.
    public static func forTerminal(state: JobState, result: ResultClass?) -> SimQExitCode {
        switch state {
        case .succeeded: return .success
        case .failed: return result == .buildFailure ? .buildFailure : .testFailure
        case .canceled, .interrupted: return .canceled
        case .infraFailed: return .infraFailure
        case .timedOut: return .timedOut
        case .expired: return .expired
        case .queued, .admitted, .running: return .success
        }
    }
}
