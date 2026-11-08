// SPDX-License-Identifier: MIT

import Foundation
import SQLite3

public enum SQLiteDomainStoreError: Error, Sendable, Equatable {
    case closed
    case invalidConfiguration(String)
    case invalidCursor(String)
    case commitGap(expected: Int, actual: Int)
    case corrupted(String)
    case schemaTooNew(Int)
    case sqlite(String)
    case unknownEffect(String)
    case staleLease(String)
    case invalidTransition(String)
    case simulatedCrash(String)
}

enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var text: String? {
        if case let .text(value) = self { return value }
        return nil
    }

    var integer: Int64? {
        if case let .integer(value) = self { return value }
        return nil
    }

    var blob: Data? {
        if case let .blob(value) = self { return value }
        return nil
    }

    var bool: Bool? {
        integer.map { $0 != 0 }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDatabase: @unchecked Sendable {
    let fileURL: URL
    private var handle: OpaquePointer?

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path)

        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            fileURL.path, &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else {
            let detail = opened.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "SQLite open failed"
            if let opened { sqlite3_close_v2(opened) }
            throw SQLiteDomainStoreError.sqlite(detail)
        }
        handle = opened
        sqlite3_busy_timeout(opened, 5_000)

        do {
            try Self.applyFileAttributes(to: fileURL)
            let journal = try query("PRAGMA journal_mode=WAL")
            guard journal.first?["journal_mode"]?.text?.lowercased() == "wal" else {
                throw SQLiteDomainStoreError.sqlite("unable to enable SQLite WAL")
            }
            _ = try query("PRAGMA synchronous=FULL")
            _ = try query("PRAGMA foreign_keys=ON")
            let version = try query("PRAGMA user_version").first?["user_version"]?.integer ?? 0
            guard version <= 2 else { throw SQLiteDomainStoreError.schemaTooNew(Int(version)) }
            let check = try query("PRAGMA quick_check")
            guard check.count == 1, check[0]["quick_check"]?.text?.lowercased() == "ok" else {
                throw SQLiteDomainStoreError.corrupted(check.first?["quick_check"]?.text ?? "quick_check failed")
            }
            try execute(Self.schemaSQL)
            _ = try query("PRAGMA user_version=2")
            try Self.applyFileAttributes(to: fileURL)
        } catch {
            sqlite3_close_v2(opened)
            handle = nil
            throw error
        }
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    var isOpen: Bool { handle != nil }

    func close() throws {
        guard let handle else { return }
        let result = sqlite3_close_v2(handle)
        guard result == SQLITE_OK else {
            throw Self.error(handle: handle, result: result)
        }
        self.handle = nil
    }

    func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        guard let handle else { throw SQLiteDomainStoreError.closed }
        if bindings.isEmpty {
            var error: UnsafeMutablePointer<Int8>?
            let result = sqlite3_exec(handle, sql, nil, nil, &error)
            let message = error.map { String(cString: $0) }
            sqlite3_free(error)
            guard result == SQLITE_OK else {
                throw Self.error(handle: handle, result: result, fallback: message)
            }
            return
        }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw Self.error(handle: handle, result: prepared)
        }
        defer { sqlite3_finalize(statement) }
        try Self.bind(bindings, to: statement, handle: handle)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw Self.error(handle: handle, result: result) }
    }

    func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        guard let handle else { throw SQLiteDomainStoreError.closed }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw Self.error(handle: handle, result: prepared)
        }
        defer { sqlite3_finalize(statement) }
        try Self.bind(bindings, to: statement, handle: handle)
        var rows: [[String: SQLiteValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw Self.error(handle: handle, result: result) }
            var row: [String: SQLiteValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = sqlite3_column_name(statement, index).map { String(cString: $0) } ?? "column\(index)"
                row[name] = Self.value(statement: statement, index: index)
            }
            rows.append(row)
        }
    }

    static func applyFileAttributes(to fileURL: URL) throws {
        let manager = FileManager.default
        let candidates = [
            fileURL,
            URL(fileURLWithPath: fileURL.path + "-wal"),
            URL(fileURLWithPath: fileURL.path + "-shm"),
        ]
        for candidate in candidates where manager.fileExists(atPath: candidate.path) {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.path)
            try? manager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: candidate.path)
        }
    }

    private static func bind(_ values: [SQLiteValue], to statement: OpaquePointer, handle: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case let .integer(value):
                result = sqlite3_bind_int64(statement, index, value)
            case let .real(value):
                result = sqlite3_bind_double(statement, index, value)
            case let .text(value):
                result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case let .blob(value):
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), sqliteTransient)
                }
            }
            guard result == SQLITE_OK else { throw error(handle: handle, result: result) }
        }
    }

    private static func value(statement: OpaquePointer, index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            let bytes = sqlite3_column_blob(statement, index)
            return .blob(bytes.map { Data(bytes: $0, count: count) } ?? Data())
        default:
            return .text(sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "")
        }
    }

    private static func error(handle: OpaquePointer, result: Int32, fallback: String? = nil) -> SQLiteDomainStoreError {
        let detail = fallback ?? sqlite3_errmsg(handle).map { String(cString: $0) } ?? "SQLite \(result)"
        if result == SQLITE_CORRUPT || result == SQLITE_NOTADB {
            return .corrupted(detail)
        }
        return .sqlite(detail)
    }

    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS bot_events (
            commit_seq INTEGER PRIMARY KEY CHECK (commit_seq > 0),
            event_id TEXT NOT NULL UNIQUE,
            event_type TEXT NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE TRIGGER IF NOT EXISTS bot_events_reject_update
        BEFORE UPDATE ON bot_events BEGIN
            SELECT RAISE(ABORT, 'bot_events is append-only');
        END;
        CREATE TRIGGER IF NOT EXISTS bot_events_reject_delete
        BEFORE DELETE ON bot_events BEGIN
            SELECT RAISE(ABORT, 'bot_events is append-only');
        END;
        CREATE TABLE IF NOT EXISTS bot_effects (
            effect_key TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            operation TEXT NOT NULL,
            target TEXT NOT NULL,
            canonical_resource TEXT NOT NULL,
            args_digest TEXT NOT NULL,
            payload_digest TEXT NOT NULL,
            logical_key TEXT NOT NULL,
            idempotent INTEGER NOT NULL,
            retry_policy TEXT NOT NULL,
            max_attempts INTEGER NOT NULL CHECK (max_attempts > 0),
            generation INTEGER NOT NULL CHECK (generation > 0),
            not_before INTEGER,
            state TEXT NOT NULL,
            attempt INTEGER NOT NULL DEFAULT 0,
            attempts INTEGER NOT NULL DEFAULT 0,
            enqueued_commit_seq INTEGER,
            lease_owner TEXT,
            lease_expires_at INTEGER,
            started_at INTEGER,
            last_error TEXT,
            error_class TEXT,
            result_ref TEXT,
            applied_at INTEGER,
            reconciliation_reason TEXT,
            updated_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS bot_effects_lease_candidates
        ON bot_effects(state, not_before, enqueued_commit_seq, effect_key);
        CREATE TABLE IF NOT EXISTS bot_effect_inbox (
            receiver TEXT NOT NULL,
            effect_key TEXT NOT NULL,
            generation INTEGER NOT NULL CHECK (generation > 0),
            attempt INTEGER NOT NULL CHECK (attempt > 0),
            applied_at INTEGER NOT NULL,
            result_ref TEXT,
            PRIMARY KEY(receiver, effect_key, generation)
        );
        CREATE INDEX IF NOT EXISTS bot_effect_inbox_lookup
        ON bot_effect_inbox(receiver, effect_key, generation DESC);
        CREATE TABLE IF NOT EXISTS bot_user_action_nonces (
            bot_id TEXT NOT NULL,
            nonce TEXT NOT NULL,
            event_id TEXT NOT NULL UNIQUE REFERENCES bot_events(event_id),
            created_commit_seq INTEGER NOT NULL CHECK (created_commit_seq > 0),
            PRIMARY KEY(bot_id, nonce)
        );
        """
}

public actor SQLiteDomainStore {
    public nonisolated let fileURL: URL
    let database: SQLiteDatabase
    let clock: @Sendable () -> Int64
    let defaultLeaseTTLms: Int64
    let ephemeralCapacity: Int
    var closed = false
    var ephemeralBuffer: [BotEvent] = []
    var droppedEphemeral = 0
    var crashPoint: String?
    var inboxFlights: [BotEffectInboxFlightKey: Task<BotEffectInboxEntry, Error>] = [:]

    public init(
        fileURL: URL,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        leaseTTLms: Int64 = 30_000,
        ephemeralCapacity: Int = 256
    ) throws {
        guard leaseTTLms > 0 else {
            throw SQLiteDomainStoreError.invalidConfiguration("leaseTTLms must be positive")
        }
        guard ephemeralCapacity > 0 else {
            throw SQLiteDomainStoreError.invalidConfiguration("ephemeralCapacity must be positive")
        }
        self.fileURL = fileURL
        self.clock = now
        self.defaultLeaseTTLms = leaseTTLms
        self.ephemeralCapacity = ephemeralCapacity
        self.database = try SQLiteDatabase(fileURL: fileURL)
        try Self.verifyIntegrity(database: database)
    }

    public static func applicationSupport() throws -> SQLiteDomainStore {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try SQLiteDomainStore(fileURL: root.appendingPathComponent("PhoneDSHBot/domain.sqlite"))
    }

    public func close() throws {
        guard !closed else { return }
        closed = true
        try database.close()
        try? SQLiteDatabase.applyFileAttributes(to: fileURL)
    }

    public func verifyIntegrity() throws {
        try ensureOpen()
        try Self.verifyIntegrity(database: database)
    }

    private static func verifyIntegrity(database: SQLiteDatabase) throws {
        let check = try database.query("PRAGMA quick_check")
        guard check.count == 1, check[0]["quick_check"]?.text?.lowercased() == "ok" else {
            throw SQLiteDomainStoreError.corrupted(check.first?["quick_check"]?.text ?? "quick_check failed")
        }
        let foreignKeyErrors = try database.query("PRAGMA foreign_key_check")
        guard foreignKeyErrors.isEmpty else {
            throw SQLiteDomainStoreError.corrupted("SQLite foreign key check failed")
        }
        let rows = try database.query(
            "SELECT commit_seq, event_id, payload FROM bot_events ORDER BY commit_seq ASC")
        let codec = BotEventEnvelopeCodec()
        var expected = 1
        var eventSequences: [String: Int64] = [:]
        var eventBotIDs: [String: String] = [:]
        for row in rows {
            guard let sequence = row["commit_seq"]?.integer, sequence == Int64(expected) else {
                throw SQLiteDomainStoreError.commitGap(
                    expected: expected, actual: Int(row["commit_seq"]?.integer ?? -1))
            }
            guard let payload = row["payload"]?.blob else {
                throw SQLiteDomainStoreError.corrupted("event \(expected) has no payload")
            }
            let event = try codec.decode(payload)
            guard event.commitSeq == expected, event.eventId == row["event_id"]?.text else {
                throw SQLiteDomainStoreError.corrupted("event payload mismatch at commitSeq \(expected)")
            }
            eventSequences[event.eventId] = sequence
            eventBotIDs[event.eventId] = event.principal.botId
            expected += 1
        }
        let nonces = try database.query(
            "SELECT bot_id, nonce, event_id, created_commit_seq FROM bot_user_action_nonces")
        for nonce in nonces {
            guard let botID = nonce["bot_id"]?.text, !botID.isEmpty,
                  nonce["nonce"]?.text?.isEmpty == false,
                  let eventID = nonce["event_id"]?.text,
                  let createdCommitSeq = nonce["created_commit_seq"]?.integer,
                  eventSequences[eventID] == createdCommitSeq,
                  eventBotIDs[eventID] == botID else {
                throw SQLiteDomainStoreError.corrupted("invalid user action nonce reference")
            }
        }
    }

    func ensureOpen() throws {
        guard !closed, database.isOpen else { throw SQLiteDomainStoreError.closed }
    }

    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try ensureOpen()
        try database.execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try checkCrashPoint("abort-before-commit")
            try checkCrashPoint("before-commit")
            try database.execute("COMMIT")
            try checkCrashPoint("abort-after-commit")
            try? SQLiteDatabase.applyFileAttributes(to: fileURL)
            return result
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    func checkCrashPoint(_ point: String) throws {
        guard crashPoint == point else { return }
        crashPoint = nil
        if point.hasPrefix("abort-") {
            try database.close()
            closed = true
        }
        throw SQLiteDomainStoreError.simulatedCrash(point)
    }

    func armCrashPoint(_ point: String) {
        crashPoint = point
    }
}
