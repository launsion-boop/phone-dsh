// SPDX-License-Identifier: MIT

import ProbeKit
import XCTest

final class PA_StoreMigrationTests: XCTestCase {
    func testOwnersMigrateInVersionOrderAndRegistrationIsIdempotent() async throws {
        let store = try SQLiteDomainStore(fileURL: temporaryURL())
        let recorder = PA_MigrationRecorder()
        let migrations = [
            PA_TestMigration(owner: "s3.a", version: 1, tablePrefix: "a_", recorder: recorder),
            PA_TestMigration(owner: "s3.b", version: 1, tablePrefix: "b_", recorder: recorder),
            PA_TestMigration(owner: "s3.a", version: 2, tablePrefix: "a_", recorder: recorder),
            PA_TestMigration(owner: "s3.a", version: 2, tablePrefix: "a_", recorder: recorder),
        ]
        try await store.register(migrations)
        try await store.register(migrations)
        XCTAssertEqual(recorder.values, ["s3.a:1", "s3.b:1", "s3.a:2"])
        let journal = try await store.read { try ($0 as! SQLiteDomainDatabase).query("PRAGMA journal_mode") }
        XCTAssertEqual(journal.first?["journal_mode"]?.text?.lowercased(), "wal")
    }

    func testMigrationCannotCreateAnotherOwnersTable() async throws {
        let store = try SQLiteDomainStore(fileURL: temporaryURL())
        let migration = PA_TestMigration(owner: "s3.a", version: 1, tablePrefix: "a_",
                                         sql: "CREATE TABLE b_secret(id INTEGER)")
        do {
            try await store.register([migration])
            XCTFail("越权建表应失败")
        } catch let error as DomainStoreError {
            guard case .unauthorizedTable = error else {
                return XCTFail("错误类型不正确：\(error)")
            }
        }
        let tables = try await store.read {
            try ($0 as! SQLiteDomainDatabase).query("SELECT name FROM sqlite_master WHERE name = 'b_secret'")
        }
        XCTAssertTrue(tables.isEmpty)
        try await store.register([PA_TestMigration(owner: "s3.a", version: 1, tablePrefix: "a_")])
    }

    func testCorruptionOpensDiagnosticReadOnlyWithoutRebuilding() async throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(to: url)
        let store = try SQLiteDomainStore(fileURL: url)
        let health = await store.health
        guard case .readOnlyDiagnostic = health else { return XCTFail("应进入损坏诊断状态") }
        do {
            try await store.write { _ in }
            XCTFail("损坏数据库不能写入")
        } catch let error as DomainStoreError {
            guard case .corrupted = error else { return XCTFail("错误类型不正确：\(error)") }
        }
        do {
            _ = try await store.read { try ($0 as! SQLiteDomainDatabase).execute("DELETE FROM domain_migrations") }
            XCTFail("只读诊断不能通过 read 闭包写入")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), Data("not a sqlite database".utf8))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PA-StoreMigration-\(UUID().uuidString)/domain.sqlite")
    }
}

private final class PA_MigrationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
}

private struct PA_TestMigration: DomainMigration {
    let owner: String
    let version: Int
    let tablePrefix: String
    var recorder: PA_MigrationRecorder?
    var sql: String?

    init(owner: String, version: Int, tablePrefix: String,
         recorder: PA_MigrationRecorder? = nil, sql: String? = nil) {
        self.owner = owner
        self.version = version
        self.tablePrefix = tablePrefix
        self.recorder = recorder
        self.sql = sql
    }

    func apply(_ db: DomainDatabase) throws {
        recorder?.append("\(owner):\(version)")
        try (db as! SQLiteDomainDatabase).execute(sql ?? "CREATE TABLE \(tablePrefix)data_v\(version)(id INTEGER PRIMARY KEY, value TEXT)")
    }
}
