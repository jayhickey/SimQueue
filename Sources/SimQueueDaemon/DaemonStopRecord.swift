// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueProtocol

/// Why a daemon stopped, kept in `<state dir>/last-stop.json`.
///
/// The file is written without the service lock or the database, so a daemon that is
/// stopping because it is wedged can still leave it. The next daemon reads it at startup
/// and copies an unaudited reason into the audit log (and so into `events.jsonl`); a
/// previous epoch with no record at all is reported as an unrecorded exit. Either way
/// the reason a daemon went away is on disk, not only in a pipe that died with it.
public struct DaemonStopRecord: Codable, Equatable, Sendable {
    public var epoch: Int64
    public var pid: Int32
    /// Seconds since 1970.
    public var at: Double
    public var reason: String
    public var exitCode: Int32
    public var version: String
    /// Whether the stopping daemon already wrote this to the audit log itself.
    public var audited: Bool

    public init(
        epoch: Int64, pid: Int32, at: Double, reason: String, exitCode: Int32, version: String, audited: Bool = false
    ) {
        self.epoch = epoch
        self.pid = pid
        self.at = at
        self.reason = reason
        self.exitCode = exitCode
        self.version = version
        self.audited = audited
    }

    enum CodingKeys: String, CodingKey {
        case epoch, pid, at, reason, version, audited
        case exitCode = "exit_code"
    }

    /// A deliberate stop, written by the daemon that stopped.
    public static let auditType = "daemon_stopped"
    /// A previous daemon that left no record: killed, crashed, or the host lost power.
    public static let unrecordedAuditType = "daemon_exit_unrecorded"
    /// Audit types without a job that still belong in `events.jsonl`.
    public static let eventLogTypes: Set<String> = [
        auditType, unrecordedAuditType, RestartBreakerPolicy.auditType,
    ]

    /// A stop somebody asked for (a signal, a stop request): the daemon exited with
    /// status 0. Anything else, including no record at all, is an unplanned stop and
    /// counts toward the restart-loop breaker.
    public var planned: Bool { exitCode == 0 }

    public static func path(stateDirectory: String) -> String { stateDirectory + "/last-stop.json" }

    /// Atomic and owner-only. Best effort: a stop is never delayed by a full disk.
    @discardableResult
    public func write(stateDirectory: String) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let path = Self.path(stateDirectory: stateDirectory)
        guard let data = try? encoder.encode(self),
            (try? data.write(to: URL(fileURLWithPath: path), options: [.atomic])) != nil
        else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return true
    }

    public static func read(stateDirectory: String) -> DaemonStopRecord? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path(stateDirectory: stateDirectory))) else {
            return nil
        }
        return try? JSONDecoder().decode(DaemonStopRecord.self, from: data)
    }

    /// The one-line form used in the daemon log and the audit detail.
    public var summary: String {
        "epoch \(epoch) pid \(pid) stopped at \(Timestamp(at).rfc3339) with status \(exitCode): \(reason)"
    }
}
