// SPDX-License-Identifier: MIT

import Foundation
import SimQueueCore
import SimQueueProtocol
import SimQueueStore

/// The readable files next to `job.json` in a job's run dir (spec §5i): `summary.md` for
/// humans and bots, and `events.jsonl`, the job's state changes one JSON object per line.
public enum JobReport {
    public static let summaryName = "summary.md"
    public static let eventsName = "events.jsonl"
    /// Lines of `combined.log` quoted at the end of a summary of a job that didn't succeed.
    public static let logTailLines = 40

    /// `summary.md` for a finished (or running) job.
    public static func markdown(_ info: JobInfo, logTail: String? = nil) -> String {
        var lines = ["# \(info.id): \(info.state.rawValue)", ""]
        func row(_ name: String, _ value: String?) {
            if let value, !value.isEmpty { lines.append("- **\(name):** \(value)") }
        }
        row("Project", info.project)
        row("Kind", info.kind)
        row("Result", info.resultClass?.rawValue)
        row("Exit code", info.exitCodeValue.map(String.init))
        row("Command exit code", info.commandExitCode.map(String.init))
        row("Message", info.message)
        row("Priority", String(info.priority))
        row("Submitter", info.submitter)
        row("Attempt", info.attempt > 0 ? String(info.attempt) : nil)
        row("Command", info.command.map { $0.map(shellQuoted).joined(separator: " ") })
        row("Working directory", info.cwd)
        row("Queued", info.queueTime.rfc3339)
        row("Started", info.startedAt?.rfc3339)
        row("Finished", info.finishedAt?.rfc3339)
        if let started = info.startedAt?.epochSeconds {
            row("Queue wait", duration(started - info.queueTime.epochSeconds))
            if let finished = info.finishedAt?.epochSeconds { row("Run time", duration(finished - started)) }
        }
        row("Sims", info.sims.map { $0.map { "\($0.name) (\($0.udid))" }.joined(separator: ", ") })
        row("Peak memory", info.peakMemoryMiB.map { String(format: "%.1f MiB", $0) })
        row("Run dir", info.runDir)
        if let bundles = info.resultBundles, !bundles.isEmpty {
            lines += ["", "## Result bundles", ""] + bundles.map { "- `\($0)`" }
        }
        if let artifacts = info.artifacts, !artifacts.isEmpty {
            lines += ["", "## Artifacts", ""]
            lines += artifacts.map { "- `\($0.path)` (\($0.type), \(bytes($0.bytes)))" }
            if info.artifactsTruncated == true { lines.append("- (more not listed)") }
        }
        if let logTail, !logTail.isEmpty, info.state != .succeeded {
            lines += ["", "## Log tail", "", "```", logTail, "```"]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The last `count` lines of the file at `path` (reads at most its last 64 KiB).
    public static func tail(of path: String, lines count: Int = logTailLines) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > 65_536 ? size - 65_536 : 0
        try? handle.seek(toOffset: start)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(count + 1).joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// One audit entry as an event line: `{"at", "seq", "job_id", "type", "detail"}`.
    public static func eventLine(_ entry: AuditEntry) -> String {
        var object: [String: Any] = [
            "seq": entry.seq, "at": Timestamp(entry.at).rfc3339, "type": entry.type,
        ]
        if let jobID = entry.jobID { object["job_id"] = jobID }
        if let detail = entry.detail { object["detail"] = detail }
        if let epoch = entry.epoch { object["epoch"] = epoch }
        if let resource = entry.resourceID { object["resource_id"] = resource }
        let data =
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total / 60 % 60)m"
    }

    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB"]
        var size = Double(value)
        var unit = 0
        while size >= 1024, unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        return unit == 0 ? "\(value) B" : String(format: "%.1f %@", size, units[unit])
    }
}

/// The daemon-wide append-only event log, `<state dir>/events.jsonl` (spec §5i): every
/// job's state changes (queued, admitted, started, retried, finished, ...) as they're
/// recorded, one JSON object per line, for debugging and metrics. Appended from the audit
/// log once per tick; resumes after the last `seq` already in the file, so a restart never
/// writes a line twice. Past `rotateBytes` the file moves to `events.jsonl.1` (one old
/// generation is kept).
public final class EventLog {
    public let path: String
    public let rotateBytes: UInt64
    /// How far back the startup scans look for a newline (see `scanLimit`).
    public let scanLimit: UInt64
    private var lastSeq: Int64?

    public init(path: String, rotateBytes: UInt64 = 64 * 1024 * 1024, scanLimit: UInt64 = EventLog.scanLimit) {
        self.path = path
        self.rotateBytes = rotateBytes
        self.scanLimit = scanLimit
    }

    /// Appends job events newer than the file's last complete line. Best effort: errors
    /// are thrown for the caller to log, never retried in a loop.
    ///
    /// The first call repairs a torn tail (a daemon killed mid-write, `kill -9`): a last
    /// line without its newline is cut off, so the next line never glues onto it and the
    /// resume point is the last line that parses. Those events are written again, once.
    ///
    /// If a scan gives up (no newline within `scanLimit` bytes), the file's last `seq` is
    /// unknown. Then nothing is cut, the torn fragment is ended with a newline instead, and
    /// the log resumes after the store's newest event: no duplicates, at the cost of a
    /// gap (events recorded since the last whole line aren't written).
    public func append(from store: JobStore, limit: Int = 5_000) throws {
        let after: Int64
        if let lastSeq {
            after = lastSeq
        } else {
            try Self.truncateTornTail(path, limit: scanLimit)
            switch Self.scanLastSeq(in: path, limit: scanLimit) {
            case .seq(let seq): after = seq
            case .gaveUp: after = try store.latestAuditSeq() ?? 0
            case .none:
                switch Self.scanLastSeq(in: path + ".1", limit: scanLimit) {
                case .seq(let seq): after = seq
                case .gaveUp: after = try store.latestAuditSeq() ?? 0
                case .none: after = 0
                }
            }
        }
        let entries = try store.auditEntries(afterSeq: after, limit: limit)
        guard let last = entries.last else {
            lastSeq = after
            return
        }
        let lines = entries.filter { $0.jobID != nil }.map(JobReport.eventLine)
        if !lines.isEmpty {
            try rotateIfNeeded()
            try ProcessExecutor.append(lines.joined(separator: "\n") + "\n", to: path)
        }
        lastSeq = last.seq
    }

    private func rotateIfNeeded() throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard size >= rotateBytes else { return }
        try? FileManager.default.removeItem(atPath: path + ".1")
        try FileManager.default.moveItem(atPath: path, toPath: path + ".1")
    }

    /// Bytes read per step when scanning an event log backwards.
    static let scanBlock: UInt64 = 64 * 1024
    /// How far back a scan looks for a newline (lines are small; details can be big).
    public static let scanLimit: UInt64 = 16 * 1024 * 1024

    /// Where a backwards scan for a newline ended.
    enum NewlineScan: Equatable {
        /// The offset of the newline.
        case found(UInt64)
        /// Reached the start of the file without one.
        case startOfFile
        /// Looked back `limit` bytes without one; what's before is unknown.
        case gaveUp
    }

    /// What `scanLastSeq` found.
    public enum LastSeq: Equatable {
        /// The `seq` of the last line that parses.
        case seq(Int64)
        /// No line parses (or the file is missing or empty), scanned to the start.
        case none
        /// A scan gave up at `limit`: the last `seq` is unknown.
        case gaveUp
    }

    /// Cuts a last line that has no newline (a torn write), back to the previous newline,
    /// or to empty when the scan reached the start of the file without one. If the scan
    /// gave up at `limit`, nothing is cut (that could wipe good lines): the fragment is
    /// ended with a newline so the next line never glues onto it. A file that ends in a
    /// newline is left alone.
    public static func truncateTornTail(_ path: String, limit: UInt64 = scanLimit) throws {
        guard let handle = FileHandle(forUpdatingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0 else { return }
        try handle.seek(toOffset: size - 1)
        guard try handle.read(upToCount: 1) != Data("\n".utf8) else { return }
        switch try lastNewline(in: handle, before: size, limit: limit) {
        case .found(let offset): try handle.truncate(atOffset: offset + 1)
        case .startOfFile: try handle.truncate(atOffset: 0)
        case .gaveUp:
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\n".utf8))
        }
    }

    /// Reads `count` bytes from the current offset (fewer only at end of file); a single
    /// `read(upToCount:)` can come back short.
    private static func read(_ handle: FileHandle, _ count: Int) throws -> Data {
        var data = Data()
        while data.count < count, let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty {
            data.append(chunk)
        }
        return data
    }

    /// The last `\n` before `end`, scanning back in blocks, at most `limit` bytes.
    static func lastNewline(in handle: FileHandle, before end: UInt64, limit: UInt64) throws -> NewlineScan {
        var upper = end
        while upper > 0 {
            let scanned = end - upper
            guard scanned < limit else { return .gaveUp }
            let step = min(scanBlock, limit - scanned, upper)
            let lower = upper - step
            try handle.seek(toOffset: lower)
            let block = try read(handle, Int(step))
            if let index = block.lastIndex(of: UInt8(ascii: "\n")) {
                return .found(lower + UInt64(index - block.startIndex))
            }
            upper = lower
        }
        return .startOfFile
    }

    /// The `seq` of the last line that parses, scanning back from the end. A line is read
    /// only once both its ends are found, so a scan that gives up reads nothing more.
    public static func scanLastSeq(in path: String, limit: UInt64 = scanLimit) -> LastSeq {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .none }
        defer { try? handle.close() }
        guard var end = try? handle.seekToEnd() else { return .none }
        while end > 0 {
            // Skip the newline that ends this line.
            try? handle.seek(toOffset: end - 1)
            if (try? handle.read(upToCount: 1)) == Data("\n".utf8) { end -= 1 }
            guard end > 0 else { return .none }
            let start: UInt64
            switch (try? lastNewline(in: handle, before: end, limit: limit)) ?? .gaveUp {
            case .found(let offset): start = offset + 1
            case .startOfFile: start = 0
            case .gaveUp: return .gaveUp
            }
            try? handle.seek(toOffset: start)
            let line = (try? read(handle, Int(end - start))) ?? Data()
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let seq = (object["seq"] as? NSNumber)?.int64Value
            {
                return .seq(seq)
            }
            end = start
        }
        return .none
    }

    /// `scanLastSeq` as an optional (nil unless a line parses).
    public static func lastSeq(in path: String, limit: UInt64 = scanLimit) -> Int64? {
        if case .seq(let seq) = scanLastSeq(in: path, limit: limit) { return seq }
        return nil
    }
}

private func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
