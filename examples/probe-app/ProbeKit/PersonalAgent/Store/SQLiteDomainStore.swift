// SPDX-License-Identifier: MIT

import Foundation
import SQLite3

public enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    public var integer: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    public var real: Double? {
        switch self {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    public var blob: Data? {
        if case .blob(let value) = self { return value }
        return nil
    }
}

public enum DomainStoreError: Error, Sendable, Equatable {
    case invalidMigration(String)
    case unauthorizedTable(String)
    case corrupted(String)
    case sqlite(String)
}

extension DomainStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidMigration(let detail): return "数据库迁移无效：\(detail)"
        case .unauthorizedTable(let table): return "迁移越权访问表：\(table)"
        case .corrupted(let detail): return "Personal Agent 数据库已损坏，当前仅可诊断读取：\(detail)"
        case .sqlite(let detail): return "Personal Agent 数据库错误：\(detail)"
        }
    }
}

public enum DomainStoreHealth: Sendable, Equatable {
    case ready
    case readOnlyDiagnostic(String)
}

public final class SQLiteDomainDatabase: DomainDatabase, @unchecked Sendable {
    fileprivate let handle: OpaquePointer
    fileprivate let authorizer: SQLiteMigrationAuthorizer
    fileprivate var readOnly = false

    fileprivate init(handle: OpaquePointer) {
        self.handle = handle
        self.authorizer = SQLiteMigrationAuthorizer()
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    public func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        if readOnly { throw DomainStoreError.corrupted("数据库处于只读诊断状态") }
        if bindings.isEmpty {
            try withAuthorizer {
                var error: UnsafeMutablePointer<Int8>?
                let result = sqlite3_exec(handle, sql, nil, nil, &error)
                let message = error.map { String(cString: $0) }
                sqlite3_free(error)
                guard result == SQLITE_OK else {
                    throw Self.error(handle: handle, result: result, fallback: message)
                }
            }
            return
        }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw Self.error(handle: handle, result: prepared)
        }
        defer { sqlite3_finalize(statement) }
        do {
            try bind(bindings, to: statement)
            let result = try withAuthorizer { sqlite3_step(statement) }
            guard result == SQLITE_DONE else { throw Self.error(handle: handle, result: result) }
        } catch {
            throw error
        }
    }

    public func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw Self.error(handle: handle, result: prepared)
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var rows: [[String: SQLiteValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw Self.error(handle: handle, result: result) }
            var row: [String: SQLiteValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = sqlite3_column_name(statement, index).map { String(cString: $0) } ?? "column\(index)"
                let value = Self.value(statement: statement, index: index)
                row[name] = value
                let components = name.split(separator: "_")
                if components.count > 1, let first = components.first {
                    var camelName = first.lowercased() + components.dropFirst()
                        .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
                    if camelName.hasSuffix("Id") {
                        camelName = String(camelName.dropLast(2)) + "ID"
                    }
                    row[camelName] = value
                }
            }
            rows.append(row)
        }
    }

    fileprivate func setMigrationPrefix(_ prefix: String?) {
        authorizer.prefix = prefix
        if prefix == nil {
            sqlite3_set_authorizer(handle, nil, nil)
        } else {
            let context = Unmanaged.passUnretained(authorizer).toOpaque()
            sqlite3_set_authorizer(handle, { context, action, first, second, _, _ in
                guard let context else { return SQLITE_DENY }
                let authorizer = Unmanaged<SQLiteMigrationAuthorizer>.fromOpaque(context).takeUnretainedValue()
                return authorizer.authorize(action: action, first: first, second: second)
            }, context)
        }
    }

    private func withAuthorizer<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as DomainStoreError {
            throw error
        } catch {
            if let prefix = authorizer.prefix, let table = authorizer.deniedTable {
                throw DomainStoreError.unauthorizedTable("\(prefix): \(table)")
            }
            throw error
        }
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case .blob(let value):
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), sqliteTransient)
                }
            }
            guard result == SQLITE_OK else { throw Self.error(handle: handle, result: result) }
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

    private static func error(handle: OpaquePointer, result: Int32, fallback: String? = nil) -> DomainStoreError {
        let detail = fallback ?? sqlite3_errmsg(handle).map { String(cString: $0) } ?? "SQLite \(result)"
        if result == SQLITE_CORRUPT || result == SQLITE_NOTADB {
            return .corrupted(detail)
        }
        return .sqlite(detail)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteMigrationAuthorizer {
    var prefix: String?
    var deniedTable: String?

    func authorize(action: Int32, first: UnsafePointer<Int8>?, second: UnsafePointer<Int8>?) -> Int32 {
        guard let prefix else { return SQLITE_OK }
        let firstName = first.map { String(cString: $0) }
        let secondName = second.map { String(cString: $0) }
        let table: String?
        switch action {
        case SQLITE_CREATE_TABLE, SQLITE_DROP_TABLE, SQLITE_ALTER_TABLE,
             SQLITE_CREATE_TEMP_TABLE, SQLITE_DROP_TEMP_TABLE,
             SQLITE_CREATE_VIEW, SQLITE_DROP_VIEW,
             SQLITE_CREATE_TEMP_VIEW, SQLITE_DROP_TEMP_VIEW,
             SQLITE_CREATE_TRIGGER, SQLITE_DROP_TRIGGER,
             SQLITE_CREATE_TEMP_TRIGGER, SQLITE_DROP_TEMP_TRIGGER,
             SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE:
            table = firstName
        case SQLITE_CREATE_INDEX, SQLITE_DROP_INDEX,
             SQLITE_CREATE_TEMP_INDEX, SQLITE_DROP_TEMP_INDEX:
            table = secondName
            if let firstName, !firstName.hasPrefix(prefix),
               !firstName.hasPrefix("sqlite_autoindex_") {
                deniedTable = firstName
                return SQLITE_DENY
            }
        default:
            return SQLITE_OK
        }
        if table == "sqlite_master" || table == "sqlite_sequence" { return SQLITE_OK }
        guard let table, table.hasPrefix(prefix) else {
            deniedTable = table ?? firstName ?? "unknown"
            return SQLITE_DENY
        }
        return SQLITE_OK
    }
}

public actor SQLiteDomainStore: DomainStore {
    public private(set) var health: DomainStoreHealth
    private let database: SQLiteDomainDatabase

    public init(fileURL: URL) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                   ofItemAtPath: directory.path)

        var handle: OpaquePointer?
        var result = sqlite3_open_v2(fileURL.path, &handle,
                                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        if result != SQLITE_OK {
            let detail = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "无法打开数据库"
            if let handle { sqlite3_close_v2(handle) }
            handle = nil
            result = sqlite3_open_v2(fileURL.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
            guard result == SQLITE_OK, let handle else {
                if let handle { sqlite3_close_v2(handle) }
                throw DomainStoreError.sqlite(detail)
            }
            self.database = SQLiteDomainDatabase(handle: handle)
            database.readOnly = true
            self.health = .readOnlyDiagnostic(detail)
            return
        }
        guard let handle else { throw DomainStoreError.sqlite("无法打开数据库") }
        self.database = SQLiteDomainDatabase(handle: handle)
        self.health = .ready
        try? manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                   ofItemAtPath: fileURL.path)
        sqlite3_busy_timeout(handle, 5_000)

        do {
            let check = try database.query("PRAGMA quick_check")
            guard check.count == 1, check[0]["quick_check"]?.text?.lowercased() == "ok" else {
                throw DomainStoreError.corrupted(check.first?["quick_check"]?.text ?? "quick_check 失败")
            }
            let journal = try database.query("PRAGMA journal_mode=WAL")
            guard journal.first?["journal_mode"]?.text?.lowercased() == "wal" else {
                throw DomainStoreError.sqlite("无法启用 WAL")
            }
            _ = try database.query("PRAGMA foreign_keys=ON")
            _ = try database.query("PRAGMA synchronous=NORMAL")
            try database.execute("""
                CREATE TABLE IF NOT EXISTS domain_migrations (
                    owner TEXT NOT NULL,
                    version INTEGER NOT NULL,
                    table_prefix TEXT NOT NULL,
                    applied_at REAL NOT NULL,
                    PRIMARY KEY (owner, version)
                )
                """)
        } catch {
            database.readOnly = true
            self.health = .readOnlyDiagnostic(error.localizedDescription)
        }
    }

    public static func applicationSupport() throws -> SQLiteDomainStore {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return try SQLiteDomainStore(
            fileURL: root.appendingPathComponent("PersonalAgent/domain.sqlite", isDirectory: false))
    }

    public func register(_ migrations: [DomainMigration]) async throws {
        guard health == .ready else { throw DomainStoreError.corrupted(health.diagnostic) }
        var seen = Set<String>()
        let unique = migrations.filter { migration in
            let key = "\(migration.owner):\(migration.version)"
            return seen.insert(key).inserted
        }
        for migration in unique { try Self.validate(migration) }
        let indexed = unique.enumerated().map { ($0.offset, $0.element) }
        let ordered = indexed.sorted {
            if $0.1.version == $1.1.version { return $0.0 < $1.0 }
            return $0.1.version < $1.1.version
        }
        for (_, migration) in ordered {
            let rows = try database.query(
                "SELECT version, table_prefix FROM domain_migrations WHERE owner = ? ORDER BY version",
                bindings: [.text(migration.owner)])
            if let prefix = rows.first?["table_prefix"]?.text, prefix != migration.tablePrefix {
                throw DomainStoreError.invalidMigration("\(migration.owner) 的表前缀发生变化")
            }
            if rows.contains(where: { $0["version"]?.integer == Int64(migration.version) }) {
                continue
            }
            if let current = rows.compactMap({ $0["version"]?.integer }).max(),
               migration.version <= current {
                continue
            }
            if let current = rows.compactMap({ $0["version"]?.integer }).max(),
               migration.version != current + 1 {
                throw DomainStoreError.invalidMigration("\(migration.owner) 缺少版本 \(current + 1)")
            }
            try database.execute("BEGIN IMMEDIATE")
            do {
                database.setMigrationPrefix(migration.tablePrefix)
                try migration.apply(database)
                database.setMigrationPrefix(nil)
                try database.execute(
                    "INSERT INTO domain_migrations(owner, version, table_prefix, applied_at) VALUES (?, ?, ?, ?)",
                    bindings: [.text(migration.owner), .integer(Int64(migration.version)),
                               .text(migration.tablePrefix), .real(Date().timeIntervalSince1970)])
                try database.execute("COMMIT")
            } catch {
                database.setMigrationPrefix(nil)
                try? database.execute("ROLLBACK")
                if case DomainStoreError.sqlite = error, let denied = database.migrationDeniedTable {
                    throw DomainStoreError.unauthorizedTable(denied)
                }
                throw error
            }
        }
    }

    public func read<T>(_ body: @Sendable (DomainDatabase) throws -> T) async throws -> T {
        try body(database)
    }

    public func write<T>(_ body: @Sendable (DomainDatabase) throws -> T) async throws -> T {
        guard health == .ready else { throw DomainStoreError.corrupted(health.diagnostic) }
        return try body(database)
    }

    private static func validate(_ migration: DomainMigration) throws {
        guard !migration.owner.isEmpty, migration.version > 0,
              migration.tablePrefix.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
              migration.tablePrefix.hasSuffix("_") else {
            throw DomainStoreError.invalidMigration("owner、version 或 tablePrefix 不合法")
        }
    }
}

private extension DomainStoreHealth {
    var diagnostic: String {
        switch self {
        case .ready: return "未知错误"
        case .readOnlyDiagnostic(let detail): return detail
        }
    }
}

private extension SQLiteDomainDatabase {
    var migrationDeniedTable: String? { authorizer.deniedTable }
}
