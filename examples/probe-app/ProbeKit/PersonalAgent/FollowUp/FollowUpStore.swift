// SPDX-License-Identifier: MIT

import Foundation

public struct FollowUpRecord: Codable, Sendable, Equatable, Identifiable {
    public var followUp: FollowUp
    public var cursor: String?
    public var needsAttention: Bool
    public var lastChangeSummary: String?
    public var lastNotificationAt: Date?
    public var lastNotifiedCursor: String?
    public var endedAt: Date?
    public var revision: Int

    public var id: UUID { followUp.id }

    public init(followUp: FollowUp, cursor: String? = nil, needsAttention: Bool = false,
                lastChangeSummary: String? = nil, lastNotificationAt: Date? = nil,
                lastNotifiedCursor: String? = nil, endedAt: Date? = nil, revision: Int = 1) {
        self.followUp = followUp
        self.cursor = cursor
        self.needsAttention = needsAttention
        self.lastChangeSummary = lastChangeSummary
        self.lastNotificationAt = lastNotificationAt
        self.lastNotifiedCursor = lastNotifiedCursor
        self.endedAt = endedAt
        self.revision = revision
    }
}

public struct FollowUpCheckOutcome: Sendable, Equatable {
    public let record: FollowUpRecord
    public let notification: PersonalNotification?

    public init(record: FollowUpRecord, notification: PersonalNotification?) {
        self.record = record
        self.notification = notification
    }
}

public struct FollowUpStore: Sendable {
    public static let migrationOwner = "s3.followup"
    private let domain: any DomainStore

    public init(domain: any DomainStore) {
        self.domain = domain
    }

    public func prepare() async throws {
        try await domain.register([FollowUpMigration(version: 1)])
    }

    public func save(_ record: FollowUpRecord) async throws {
        let data = try Self.encoder.encode(record)
        try await domain.write { database in
            let db = try Self.database(database)
            try db.execute("""
                INSERT OR REPLACE INTO fu_followups(id, target_kind, goal, cursor, needs_attention,
                    last_verified_at, last_notification_at, ended_at, revision, record_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, bindings: Self.bindings(record, data: data))
        }
    }

    public func create(_ followUp: FollowUp) async throws -> FollowUpRecord {
        let record = FollowUpRecord(followUp: followUp)
        try await save(record)
        return record
    }

    public func record(_ id: UUID) async throws -> FollowUpRecord? {
        try await domain.read { database in
            let rows = try Self.database(database).query("SELECT record_json FROM fu_followups WHERE id = ?",
                                                          bindings: [.text(id.uuidString)])
            return try rows.first.flatMap { $0["recordJson"]?.blob }
                .map { try Self.decoder.decode(FollowUpRecord.self, from: $0) }
        }
    }

    public func records(includeEnded: Bool = false) async throws -> [FollowUpRecord] {
        try await domain.read { database in
            let rows = try Self.database(database).query(
                "SELECT record_json FROM fu_followups ORDER BY needs_attention DESC, last_verified_at DESC, id")
            return try rows.compactMap { $0["recordJson"]?.blob }
                .map { try Self.decoder.decode(FollowUpRecord.self, from: $0) }
                .filter { includeEnded || $0.endedAt == nil }
        }
    }

    public func pause(_ id: UUID, until: Date, now: Date = Date()) async throws -> FollowUpRecord {
        guard until > now, var record = try await record(id) else { throw FollowUpError.notFound }
        record.followUp.pausedUntil = until
        record.revision += 1
        try await save(record)
        return record
    }

    public func updateConditions(_ id: UUID, check: CheckCondition, stop: StopCondition,
                                 notificationPolicy: NotificationPolicy? = nil) async throws -> FollowUpRecord {
        guard var record = try await record(id) else { throw FollowUpError.notFound }
        record.followUp.nextCheckCondition = check
        record.followUp.stopCondition = stop
        if let notificationPolicy { record.followUp.notificationPolicy = notificationPolicy }
        record.revision += 1
        try await save(record)
        return record
    }

    public func end(_ id: UUID, now: Date = Date()) async throws {
        guard var record = try await record(id) else { throw FollowUpError.notFound }
        record.endedAt = now
        record.needsAttention = false
        record.revision += 1
        try await save(record)
    }

    public func markSeen(_ id: UUID) async throws {
        guard var record = try await record(id) else { throw FollowUpError.notFound }
        record.needsAttention = false
        try await save(record)
    }

    public func apply(_ result: FollowUpCheckResult, to id: UUID) async throws -> FollowUpRecord {
        guard var record = try await record(id) else { throw FollowUpError.notFound }
        record.followUp.lastVerifiedAt = result.lastVerifiedAt
        record.followUp.pausedUntil = nil
        if let cursor = result.cursor { record.cursor = cursor }
        if result.changed {
            record.needsAttention = result.needsAttention
            record.lastChangeSummary = result.summary
        }
        record.revision += 1
        try await save(record)
        return record
    }

    public func markNotified(_ id: UUID, at date: Date) async throws {
        guard var record = try await record(id) else { throw FollowUpError.notFound }
        record.lastNotificationAt = date
        record.lastNotifiedCursor = record.cursor
        try await save(record)
    }

    private static func bindings(_ record: FollowUpRecord, data: Data) -> [SQLiteValue] {
        [.text(record.id.uuidString), .text(record.followUp.target.kind.rawValue),
         .text(record.followUp.goal), record.cursor.map(SQLiteValue.text) ?? .null,
         .integer(record.needsAttention ? 1 : 0),
         record.followUp.lastVerifiedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
         record.lastNotificationAt.map { .real($0.timeIntervalSince1970) } ?? .null,
         record.endedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
         .integer(Int64(record.revision)), .blob(data)]
    }

    private static func database(_ database: DomainDatabase) throws -> SQLiteDomainDatabase {
        guard let database = database as? SQLiteDomainDatabase else {
            throw DomainStoreError.sqlite("FollowUpStore 需要 SQLiteDomainDatabase")
        }
        return database
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

public enum FollowUpError: Error, Sendable, Equatable { case notFound }

public protocol FollowUpNotificationDelivering: Sendable {
    func deliver(_ notification: PersonalNotification) async throws
}

public actor FollowUpCoordinator {
    private let store: FollowUpStore
    private var checkers: [FollowUpTarget.Kind: any FollowUpChecker]
    private let notifier: any FollowUpNotificationDelivering

    public init(store: FollowUpStore, checkers: [any FollowUpChecker],
                notifier: any FollowUpNotificationDelivering) {
        self.store = store
        self.checkers = Dictionary(uniqueKeysWithValues: checkers.map { ($0.targetKind, $0) })
        self.notifier = notifier
    }

    public func register(_ checker: any FollowUpChecker) {
        checkers[checker.targetKind] = checker
    }

    public func checkAll(now: Date = Date()) async throws -> [FollowUpCheckOutcome] {
        let records = try await store.records()
        var outcomes: [FollowUpCheckOutcome] = []
        for record in records {
            if let validUntil = record.followUp.validUntil, validUntil <= now {
                try await store.end(record.id, now: now)
                continue
            }
            if let pausedUntil = record.followUp.pausedUntil, pausedUntil > now { continue }
            guard let checker = checkers[record.followUp.target.kind] else { continue }
            let result = await checker.check(record.followUp, since: record.cursor)
            let updated = try await store.apply(result, to: record.id)
            var notification: PersonalNotification?
            if result.changed, let summary = result.summary,
               updated.followUp.notificationPolicy != .quiet,
               updated.lastNotifiedCursor != updated.cursor {
                let candidate = PersonalNotification(
                    id: updated.id, title: "跟进有变化", body: "\(summary) 打开查看下一步。",
                    route: .chat(focus: .followUp(updated.id)), verifiedAt: result.lastVerifiedAt)
                try await notifier.deliver(candidate)
                try await store.markNotified(updated.id, at: now)
                notification = candidate
            }
            let final = try await store.record(updated.id) ?? updated
            outcomes.append(FollowUpCheckOutcome(record: final, notification: notification))
        }
        return outcomes
    }
}

private struct FollowUpMigration: DomainMigration {
    let owner = FollowUpStore.migrationOwner
    let version: Int
    let tablePrefix = "fu_"

    func apply(_ db: DomainDatabase) throws {
        guard let db = db as? SQLiteDomainDatabase else { throw DomainStoreError.sqlite("FollowUp 迁移需要 SQLite") }
        try db.execute("""
            CREATE TABLE fu_followups (
                id TEXT PRIMARY KEY, target_kind TEXT NOT NULL, goal TEXT NOT NULL, cursor TEXT,
                needs_attention INTEGER NOT NULL, last_verified_at REAL, last_notification_at REAL,
                ended_at REAL, revision INTEGER NOT NULL, record_json BLOB NOT NULL
            )
            """)
        try db.execute("CREATE INDEX fu_active ON fu_followups(ended_at, needs_attention)")
    }
}
