// SPDX-License-Identifier: MIT

import CSQLite
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public enum DatabaseError: Error, Equatable, CustomStringConvertible {
    case openFailed(code: Int32, message: String)
    case prepareFailed(code: Int32, message: String, sql: String)
    case stepFailed(code: Int32, message: String)
    case schemaTooNew(found: Int32, supported: Int32)
    case schemaNotCurrent(found: Int32, expected: Int32)

    public var description: String {
        switch self {
        case .openFailed(let code, let message): return "sqlite open failed (\(code)): \(message)"
        case .prepareFailed(let code, let message, let sql):
            return "sqlite prepare failed (\(code)): \(message) in \(sql)"
        case .stepFailed(let code, let message): return "sqlite step failed (\(code)): \(message)"
        case .schemaTooNew(let found, let supported):
            return "database schema version \(found) is newer than this build supports (\(supported))"
        case .schemaNotCurrent(let found, let expected):
            return "database schema version \(found) isn't v\(expected); start simqd once to migrate it"
        }
    }
}

/// A value bound to or read from SQLite.
public enum SQLValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    public static func optional(_ value: String?) -> SQLValue { value.map(SQLValue.text) ?? .null }
    public static func optional(_ value: Double?) -> SQLValue { value.map(SQLValue.real) ?? .null }
    public static func optional(_ value: Int64?) -> SQLValue { value.map(SQLValue.integer) ?? .null }
}

/// One result row, read by column name.
public struct Row {
    let values: [String: SQLValue]

    public func string(_ column: String) -> String? {
        if case .text(let value) = values[column] { return value }
        return nil
    }

    public func int(_ column: String) -> Int64? {
        switch values[column] {
        case .integer(let value): return value
        case .real(let value): return Int64(value)
        default: return nil
        }
    }

    public func double(_ column: String) -> Double? {
        switch values[column] {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin SQLite connection. One connection per thread; SQLite serializes writers.
public final class Database {
    private var handle: OpaquePointer?
    private var statementDeadline: Double?
    private var archiveAuthorization: (watermark: Int64, cutoff: Double)?
    public let path: String
    public let readOnly: Bool
    /// Bumped on every rollback, so in-process caches built on top know to reload.
    public private(set) var rollbackCount = 0

    /// The linked SQLite library version, e.g. "3.43.2".
    public static var libraryVersion: String {
        String(cString: sqlite3_libversion())
    }

    /// Opens a database. Use ":memory:" for tests. File databases use WAL mode with
    /// `synchronous = FULL`.
    /// `readOnly` opens an existing file without creating or changing anything.
    public init(path: String, readOnly: Bool = false, busyTimeoutMilliseconds: Int32 = 5_000) throws {
        self.path = path
        self.readOnly = readOnly
        let flags =
            readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            handle = nil
            throw DatabaseError.openFailed(code: code, message: message)
        }
        sqlite3_busy_timeout(handle, busyTimeoutMilliseconds)
        // Authorization lives on this connection, never in persistent SQL state. A
        // crash or rollback cannot leave audit deletion enabled for a future opener.
        let registration = sqlite3_create_function_v2(
            handle, "simqueue_archive_allows", 2, SQLITE_UTF8,
            Unmanaged.passUnretained(self).toOpaque(),
            { context, count, arguments in
                guard let context, count == 2, let arguments,
                    let pointer = sqlite3_user_data(context)
                else { return }
                let database = Unmanaged<Database>.fromOpaque(pointer).takeUnretainedValue()
                let allowed =
                    database.archiveAuthorization.map {
                        sqlite3_value_int64(arguments[0]) <= $0.watermark
                            && sqlite3_value_double(arguments[1]) < $0.cutoff
                    } ?? false
                sqlite3_result_int(context, allowed ? 1 : 0)
            }, nil, nil, nil)
        guard registration == SQLITE_OK else {
            throw DatabaseError.openFailed(code: registration, message: "cannot register archive guard")
        }
        if readOnly {
            return
        }
        if try query("SELECT name FROM sqlite_master WHERE type='table' AND name='jobs';").isEmpty {
            try execute("PRAGMA auto_vacuum = INCREMENTAL;")
        }
        try execute("PRAGMA foreign_keys = ON;")
        if path != ":memory:" {
            _ = try query("PRAGMA journal_mode = WAL;")
            // Explicit, not the library's compile-time default: every commit is synced, so
            // a power cut can't drop a job transition that was already acknowledged.
            try execute("PRAGMA synchronous = FULL;")
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    public var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
    }

    /// Rows changed by the last INSERT, UPDATE or DELETE.
    public var changes: Int {
        Int(sqlite3_changes(handle))
    }

    public var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    /// Runs one or more statements with no bindings and no results.
    /// Fault injection for chaos tests: while set, every statement that writes (or opens
    /// a write transaction) throws this instead of running. Reads still work.
    public var writeFault: (any Error)?

    private func checkWriteFault(_ sql: String) throws {
        guard let writeFault else { return }
        let verb = sql.drop { $0.isWhitespace }.prefix(6).uppercased()
        if !verb.hasPrefix("SELECT") && !verb.hasPrefix("PRAGMA") && !verb.hasPrefix("WITH") {
            throw writeFault
        }
    }

    public func execute(_ sql: String) throws {
        try checkWriteFault(sql)
        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard code == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(errorPointer)
            throw DatabaseError.stepFailed(code: code, message: message)
        }
    }

    /// Runs one statement with bindings, ignoring any rows.
    public func run(_ sql: String, _ values: [SQLValue] = []) throws {
        _ = try query(sql, values)
    }

    /// Runs one statement with bindings and returns all rows.
    @discardableResult
    public func query(_ sql: String, _ values: [SQLValue] = []) throws -> [Row] {
        try checkWriteFault(sql)
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            throw DatabaseError.prepareFailed(code: prepareCode, message: errorMessage, sql: sql)
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let integer): sqlite3_bind_int64(statement, index, integer)
            case .real(let real): sqlite3_bind_double(statement, index, real)
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            }
        }
        var rows: [Row] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE {
                break
            }
            guard code == SQLITE_ROW else {
                throw DatabaseError.stepFailed(code: code, message: errorMessage)
            }
            var columns: [String: SQLValue] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: columns[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: columns[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: columns[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                default: columns[name] = .null
                }
            }
            rows.append(Row(values: columns))
        }
        return rows
    }

    /// Runs `body` inside `BEGIN IMMEDIATE ... COMMIT`, rolling back on error. Taking the
    /// write lock up front makes read-then-write sequences atomic across processes.
    private var transactionDepth = 0

    /// Runs `body` in one `BEGIN IMMEDIATE` transaction. Nested calls join the outer
    /// transaction (an error anywhere rolls back the whole thing; there are no savepoints,
    /// so an inner error can't be caught and recovered from inside the outer body).
    ///
    /// `transactionDepth` is plain, unsynchronized state: this relies on one thread using
    /// a `Database` at a time, which the daemon guarantees by serializing every store call
    /// under its service lock (DaemonService). Don't share a `Database` across threads
    /// without that lock.
    public func immediateTransaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        transactionDepth = 1
        defer { transactionDepth = 0 }
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            rollbackCount += 1
            throw error
        }
    }

    public var userVersion: Int32 {
        get throws {
            Int32(try query("PRAGMA user_version;").first?.int("user_version") ?? 0)
        }
    }
}

extension Database {
    /// Scope authorization to the verified archive's pruning transaction.
    func withArchiveAuthorization<T>(watermark: Int64, cutoff: Double, _ body: () throws -> T) rethrows -> T {
        precondition(archiveAuthorization == nil)
        archiveAuthorization = (watermark, cutoff)
        defer { archiveAuthorization = nil }
        return try body()
    }

    /// Bound archival SQL work so a large protected history cannot monopolize the
    /// writer lock. An interrupted write transaction rolls back and a later pass retries.
    func withStatementDeadline<T>(seconds: Double, _ body: () throws -> T) rethrows -> T {
        precondition(statementDeadline == nil)
        statementDeadline = ProcessInfo.processInfo.systemUptime + seconds
        sqlite3_progress_handler(
            handle, 1000,
            { pointer in
                guard let pointer else { return 0 }
                let database = Unmanaged<Database>.fromOpaque(pointer).takeUnretainedValue()
                return database.statementDeadline.map { ProcessInfo.processInfo.systemUptime > $0 ? 1 : 0 } ?? 0
            }, Unmanaged.passUnretained(self).toOpaque())
        defer {
            sqlite3_progress_handler(handle, 0, nil, nil)
            statementDeadline = nil
        }
        return try body()
    }

    static func withArchiveLock<T>(path: String, _ body: () throws -> T) throws -> T? {
        let descriptor = open(path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return nil }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    public static func snapshot(
        source: String, destination: String, maxBytes: UInt64 = 512 * 1024 * 1024, afterStep: (() throws -> Void)? = nil
    ) throws {
        let sourceDB = try Database(path: source, readOnly: true)
        // The C backup retains SQLite handles, not these Swift owners. Keep the source
        // alive until backup_finish; close-before-finish returns BUSY and leaks a handle.
        defer { withExtendedLifetime(sourceDB) {} }
        let pageCount = try sourceDB.query("PRAGMA page_count;").first?.int("page_count") ?? 0
        let pageSize = try sourceDB.query("PRAGMA page_size;").first?.int("page_size") ?? 4096
        guard UInt64(max(0, pageCount)) <= maxBytes / UInt64(max(1, pageSize)) else {
            throw JobStoreError.invalidCommand(
                "history snapshot exceeds 512 MiB; drain, export state, remove unneeded pins/artifacts and compact the database before resuming"
            )
        }
        let targetDB = try Database(path: destination)
        // The archive must be self-contained before fsync/rename; no WAL sidecar may
        // contain pages which are missing from the immutable .sqlite file.
        _ = try targetDB.query("PRAGMA journal_mode = DELETE;")
        try targetDB.execute("PRAGMA max_page_count = \(maxBytes / UInt64(max(1, pageSize)));")
        guard let backup = sqlite3_backup_init(targetDB.handle, "main", sourceDB.handle, "main") else {
            throw DatabaseError.openFailed(code: SQLITE_ERROR, message: "cannot start history snapshot")
        }
        var finished = false
        defer { if !finished { sqlite3_backup_finish(backup) } }
        let deadline = Date().addingTimeInterval(30)
        while true {
            let code = sqlite3_backup_step(backup, 100)
            if code == SQLITE_DONE { break }
            if code == SQLITE_OK { try afterStep?() }
            guard [SQLITE_OK, SQLITE_BUSY, SQLITE_LOCKED].contains(code), Date() < deadline else {
                throw DatabaseError.stepFailed(code: code, message: "history snapshot failed; live state unchanged")
            }
            usleep(1000)
        }
        let finishCode = sqlite3_backup_finish(backup)
        finished = true
        guard finishCode == SQLITE_OK else {
            throw DatabaseError.stepFailed(
                code: finishCode, message: "history snapshot finalization failed; live state unchanged")
        }
        // sqlite3_backup copies the source's WAL format bytes too. Convert AFTER
        // finalizing the backup, not only before it, so read-only use and later rename
        // cannot require sidecars under the old temporary filename.
        _ = try targetDB.query("PRAGMA journal_mode = DELETE;")
    }
    public static func syncDirectory(_ path: String) throws {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
