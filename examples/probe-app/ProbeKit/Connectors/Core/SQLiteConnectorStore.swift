// SPDX-License-Identifier: MIT

import Foundation
import SQLite3

public enum SQLiteConnectorStoreError: Error, Equatable, Sendable {
    case openFailed
    case queryFailed
    case encodingFailed
}

/// Host-owned connector metadata only. Credential values never enter SQLite or its WAL.
public final class SQLiteConnectorStore: ConnectorRegistryPersisting, ConnectorKeyValueStore, @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard sqlite3_open_v2(databaseURL.path, &database,
                              SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            sqlite3_close(database)
            database = nil
            throw SQLiteConnectorStoreError.openFailed
        }
        sqlite3_busy_timeout(database, 5_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS conn_records (
                connector_id TEXT PRIMARY KEY,
                payload TEXT NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS conn_grants (
                connector_id TEXT PRIMARY KEY,
                payload TEXT NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS conn_credentials (
                connector_id TEXT PRIMARY KEY,
                credential_ref TEXT NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS gh_key_values (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """)
    }

    deinit { sqlite3_close(database) }

    public func load() throws -> ConnectorRegistrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ConnectorRegistrySnapshot(records: try loadPayloads("conn_records"),
                                         grants: try loadPayloads("conn_grants"),
                                         credentialRefs: try loadCredentialRefs())
    }

    public func save(record: ConnectorRecord, grant: ConnectorGrant?, credentialRef: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            try upsertPayload(record, table: "conn_records", id: record.connectorID)
            if let grant { try upsertPayload(grant, table: "conn_grants", id: grant.connectorID) }
            if let credentialRef {
                try execute("INSERT OR REPLACE INTO conn_credentials VALUES (?, ?)",
                            bindings: [record.connectorID, credentialRef])
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func save(record: ConnectorRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        try upsertPayload(record, table: "conn_records", id: record.connectorID)
    }

    public func revoke(_ connectorID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM conn_grants WHERE connector_id = ?", bindings: [connectorID])
            try execute("DELETE FROM conn_credentials WHERE connector_id = ?", bindings: [connectorID])
            try execute("DELETE FROM conn_records WHERE connector_id = ?", bindings: [connectorID])
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func string(forKey key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM gh_key_values WHERE key = ?", -1,
                                 &statement, nil) == SQLITE_OK else { throw SQLiteConnectorStoreError.queryFailed }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    public func setString(_ value: String?, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let value {
            try execute("INSERT OR REPLACE INTO gh_key_values VALUES (?, ?)", bindings: [key, value])
        } else {
            try execute("DELETE FROM gh_key_values WHERE key = ?", bindings: [key])
        }
    }

    private func loadPayloads<T: Decodable>(_ table: String) throws -> [String: T] {
        var statement: OpaquePointer?
        let allowed = table == "conn_records" || table == "conn_grants"
        guard allowed, sqlite3_prepare_v2(database, "SELECT connector_id, payload FROM \(table)", -1,
                                          &statement, nil) == SQLITE_OK else {
            throw SQLiteConnectorStoreError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        var result: [String: T] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let payload = sqlite3_column_text(statement, 1) else {
                throw SQLiteConnectorStoreError.queryFailed
            }
            result[String(cString: id)] = try decoder.decode(T.self, from: Data(String(cString: payload).utf8))
        }
        return result
    }

    private func loadCredentialRefs() throws -> [String: String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT connector_id, credential_ref FROM conn_credentials", -1,
                                 &statement, nil) == SQLITE_OK else { throw SQLiteConnectorStoreError.queryFailed }
        defer { sqlite3_finalize(statement) }
        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let ref = sqlite3_column_text(statement, 1) else {
                throw SQLiteConnectorStoreError.queryFailed
            }
            result[String(cString: id)] = String(cString: ref)
        }
        return result
    }

    private func upsertPayload<T: Encodable>(_ value: T, table: String, id: String) throws {
        guard table == "conn_records" || table == "conn_grants" else { throw SQLiteConnectorStoreError.queryFailed }
        let data = try encoder.encode(value)
        guard let payload = String(data: data, encoding: .utf8) else { throw SQLiteConnectorStoreError.encodingFailed }
        try execute("INSERT OR REPLACE INTO \(table) VALUES (?, ?)", bindings: [id, payload])
    }

    private func execute(_ sql: String, bindings: [String] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteConnectorStoreError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), binding, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw SQLiteConnectorStoreError.queryFailed }
    }
}
