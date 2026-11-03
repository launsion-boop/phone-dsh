// SPDX-License-Identifier: MIT

import Foundation

public enum ConversationRole: String, Codable, Sendable { case user, assistant }

public enum ConversationTurnState: String, Codable, Sendable {
    case queued, running, waitingForUser, completed, failed, interrupted
}

public struct ConversationArtifactRef: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let title: String
    public let locator: String
    public let createdAt: Date

    public init(id: String, kind: String, title: String, locator: String, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.locator = locator
        self.createdAt = createdAt
    }
}

public struct ConversationMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let conversationID: UUID
    public let turnID: UUID?
    public let role: ConversationRole
    public let source: SourceEnvelope?
    public let text: String
    public let evidenceRefs: [EvidenceRef]
    public let artifacts: [ConversationArtifactRef]
    public let createdAt: Date
    public let sequence: Int64

    public init(id: UUID = UUID(), conversationID: UUID, turnID: UUID?, role: ConversationRole,
                source: SourceEnvelope? = nil, text: String, evidenceRefs: [EvidenceRef] = [],
                artifacts: [ConversationArtifactRef] = [], createdAt: Date = Date(), sequence: Int64 = 0) {
        self.id = id
        self.conversationID = conversationID
        self.turnID = turnID
        self.role = role
        self.source = source
        self.text = text
        self.evidenceRefs = evidenceRefs
        self.artifacts = artifacts
        self.createdAt = createdAt
        self.sequence = sequence
    }
}

public struct ConversationTurn: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let conversationID: UUID
    public let requestID: UUID
    public let principal: String
    public let userMessageID: UUID
    public let text: String
    public var state: ConversationTurnState
    public var terminalStatus: String?
    public var failure: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), conversationID: UUID, requestID: UUID, principal: String,
                userMessageID: UUID, text: String, state: ConversationTurnState = .queued,
                terminalStatus: String? = nil, failure: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.conversationID = conversationID
        self.requestID = requestID
        self.principal = principal
        self.userMessageID = userMessageID
        self.text = text
        self.state = state
        self.terminalStatus = terminalStatus
        self.failure = failure
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var input: MainTurnInput {
        MainTurnInput(turnID: id, requestID: requestID, principal: principal,
                      conversationID: conversationID, text: text)
    }
}

public struct ConversationSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let conversationID: UUID
    public let coveredRange: ClosedRange<Int64>
    public let revision: Int
    public let sourceCursor: Int64
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), conversationID: UUID, coveredRange: ClosedRange<Int64>,
                revision: Int, sourceCursor: Int64, text: String, createdAt: Date = Date()) {
        self.id = id
        self.conversationID = conversationID
        self.coveredRange = coveredRange
        self.revision = revision
        self.sourceCursor = sourceCursor
        self.text = text
        self.createdAt = createdAt
    }
}

public struct ConversationRecovery: Sendable, Equatable {
    public let queuedTurns: [ConversationTurn]
    public let interruptedTurns: [ConversationTurn]

    public init(queuedTurns: [ConversationTurn], interruptedTurns: [ConversationTurn]) {
        self.queuedTurns = queuedTurns
        self.interruptedTurns = interruptedTurns
    }
}

public struct ConversationContext: Sendable, Equatable {
    public let recentMessages: [ConversationMessage]
    public let summary: ConversationSummary?
    public let pendingQuestions: [PendingQuestion]

    public init(recentMessages: [ConversationMessage], summary: ConversationSummary?,
                pendingQuestions: [PendingQuestion]) {
        self.recentMessages = recentMessages
        self.summary = summary
        self.pendingQuestions = pendingQuestions
    }
}

public struct ConversationStore: Sendable {
    public static let migrationOwner = "s3.conversation"
    private let domain: any DomainStore

    public init(domain: any DomainStore) {
        self.domain = domain
    }

    public func prepare() async throws {
        try await domain.register([ConversationMigration(version: 1)])
    }

    @discardableResult
    public func enqueue(text: String, source: SourceEnvelope, conversationID: UUID,
                        now: Date = Date()) async throws -> ConversationTurn {
        let turnID = UUID()
        let messageID = UUID()
        let turn = ConversationTurn(id: turnID, conversationID: conversationID,
                                    requestID: source.requestID, principal: source.principal,
                                    userMessageID: messageID, text: text,
                                    createdAt: now, updatedAt: now)
        let sourceData = try Self.encoder.encode(source)
        return try await domain.write { database in
            let db = try Self.database(database)
            try db.execute("BEGIN IMMEDIATE")
            do {
                try db.execute("""
                    INSERT INTO conv_turns(id, conversation_id, request_id, principal, user_message_id,
                        text, state, terminal_status, failure, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, 'queued', NULL, NULL, ?, ?)
                    """, bindings: [.text(turnID.uuidString), .text(conversationID.uuidString),
                                    .text(source.requestID.uuidString), .text(source.principal),
                                    .text(messageID.uuidString), .text(text),
                                    .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
                try db.execute("""
                    INSERT INTO conv_messages(id, conversation_id, turn_id, role, source_json, text,
                        evidence_json, artifacts_json, created_at)
                    VALUES (?, ?, ?, 'user', ?, ?, '[]', '[]', ?)
                    """, bindings: [.text(messageID.uuidString), .text(conversationID.uuidString),
                                    .text(turnID.uuidString), .blob(sourceData), .text(text),
                                    .real(now.timeIntervalSince1970)])
                try db.execute("COMMIT")
                return turn
            } catch {
                try? db.execute("ROLLBACK")
                throw error
            }
        }
    }

    public func markRunning(_ turnID: UUID, now: Date = Date()) async throws {
        try await updateTurn(turnID, state: .running, terminalStatus: nil, failure: nil, now: now)
    }

    public func recordStatus(_ status: StatusLine, turnID: UUID, now: Date = Date()) async throws {
        try await updateTurn(turnID, state: .running, terminalStatus: status.text, failure: nil, now: now)
    }

    public func complete(_ turn: ConversationTurn, message: AssistantMessage,
                         now: Date = Date()) async throws {
        let text = PersonalAgentTextPolicy.visibleAssistantText(message.text)
        let evidence = try Self.encoder.encode(message.evidenceRefs.sorted { $0.id < $1.id })
        try await domain.write { database in
            let db = try Self.database(database)
            try db.execute("BEGIN IMMEDIATE")
            do {
                try db.execute("""
                    INSERT OR REPLACE INTO conv_messages(id, conversation_id, turn_id, role, source_json,
                        text, evidence_json, artifacts_json, created_at)
                    VALUES (?, ?, ?, 'assistant', NULL, ?, ?, '[]', ?)
                    """, bindings: [.text(message.id.uuidString), .text(turn.conversationID.uuidString),
                                    .text(turn.id.uuidString), .text(text), .blob(evidence),
                                    .real(now.timeIntervalSince1970)])
                try db.execute("""
                    UPDATE conv_turns SET state = 'completed', terminal_status = NULL,
                        failure = NULL, updated_at = ? WHERE id = ?
                    """, bindings: [.real(now.timeIntervalSince1970), .text(turn.id.uuidString)])
                try db.execute("DELETE FROM conv_questions WHERE turn_id = ? AND resolved_at IS NULL",
                               bindings: [.text(turn.id.uuidString)])
                try db.execute("COMMIT")
            } catch {
                try? db.execute("ROLLBACK")
                throw error
            }
        }
    }

    public func fail(_ turnID: UUID, reason: String, interrupted: Bool = false,
                     now: Date = Date()) async throws {
        try await updateTurn(turnID, state: interrupted ? .interrupted : .failed,
                             terminalStatus: nil, failure: reason, now: now)
    }

    public func recordQuestion(_ question: PendingQuestion, turnID: UUID, now: Date = Date()) async throws {
        let data = try Self.encoder.encode(question)
        try await domain.write { database in
            let db = try Self.database(database)
            try db.execute("BEGIN IMMEDIATE")
            do {
                try db.execute("""
                    INSERT OR REPLACE INTO conv_questions(id, turn_id, question_json, created_at, resolved_at)
                    VALUES (?, ?, ?, ?, NULL)
                    """, bindings: [.text(question.id.uuidString), .text(turnID.uuidString), .blob(data),
                                    .real(now.timeIntervalSince1970)])
                try db.execute("""
                    UPDATE conv_turns SET state = 'waitingForUser', terminal_status = NULL,
                        updated_at = ? WHERE id = ?
                    """, bindings: [.real(now.timeIntervalSince1970), .text(turnID.uuidString)])
                try db.execute("COMMIT")
            } catch {
                try? db.execute("ROLLBACK")
                throw error
            }
        }
    }

    public func resolveQuestion(_ id: UUID, now: Date = Date()) async throws {
        try await domain.write { database in
            try Self.database(database).execute(
                "UPDATE conv_questions SET resolved_at = ? WHERE id = ?",
                bindings: [.real(now.timeIntervalSince1970), .text(id.uuidString)])
        }
    }

    public func appendArtifact(_ artifact: ConversationArtifactRef, conversationID: UUID,
                               text: String, now: Date = Date()) async throws {
        let data = try Self.encoder.encode([artifact])
        try await domain.write { database in
            try Self.database(database).execute("""
                INSERT INTO conv_messages(id, conversation_id, turn_id, role, source_json, text,
                    evidence_json, artifacts_json, created_at)
                VALUES (?, ?, NULL, 'assistant', NULL, ?, '[]', ?, ?)
                """, bindings: [.text(UUID().uuidString), .text(conversationID.uuidString), .text(text),
                                .blob(data), .real(now.timeIntervalSince1970)])
        }
    }

    public func messages(conversationID: UUID, before cursor: Int64? = nil,
                         limit: Int = 50) async throws -> [ConversationMessage] {
        guard limit > 0, limit <= 200 else { throw DomainStoreError.invalidMigration("分页 limit 超出范围") }
        return try await domain.read { database in
            let db = try Self.database(database)
            let rows: [[String: SQLiteValue]]
            if let cursor {
                rows = try db.query("""
                    SELECT * FROM conv_messages WHERE conversation_id = ? AND seq < ?
                    ORDER BY seq DESC LIMIT ?
                    """, bindings: [.text(conversationID.uuidString), .integer(cursor), .integer(Int64(limit))])
            } else {
                rows = try db.query("""
                    SELECT * FROM conv_messages WHERE conversation_id = ? ORDER BY seq DESC LIMIT ?
                    """, bindings: [.text(conversationID.uuidString), .integer(Int64(limit))])
            }
            return try rows.reversed().map(Self.message)
        }
    }

    public func turn(_ id: UUID) async throws -> ConversationTurn? {
        try await domain.read { database in
            let rows = try Self.database(database).query("SELECT * FROM conv_turns WHERE id = ?",
                                                          bindings: [.text(id.uuidString)])
            return try rows.first.map(Self.turn)
        }
    }

    public func turns(conversationID: UUID) async throws -> [ConversationTurn] {
        try await domain.read { database in
            let rows = try Self.database(database).query(
                "SELECT * FROM conv_turns WHERE conversation_id = ? ORDER BY created_at, id",
                bindings: [.text(conversationID.uuidString)])
            return try rows.map(Self.turn)
        }
    }

    public func recover(conversationID: UUID, now: Date = Date()) async throws -> ConversationRecovery {
        try await domain.write { database in
            let db = try Self.database(database)
            try db.execute("BEGIN IMMEDIATE")
            do {
                let rows = try db.query(
                    "SELECT * FROM conv_turns WHERE conversation_id = ? ORDER BY created_at, id",
                    bindings: [.text(conversationID.uuidString)])
                var queued: [ConversationTurn] = []
                var interrupted: [ConversationTurn] = []
                for row in rows {
                    var turn = try Self.turn(row)
                    switch turn.state {
                    case .queued:
                        queued.append(turn)
                    case .running:
                        turn.state = .interrupted
                        turn.terminalStatus = nil
                        turn.failure = "上次执行被中断，未自动重放。请确认状态后再继续。"
                        turn.updatedAt = now
                        try db.execute("""
                            UPDATE conv_turns SET state = 'interrupted', terminal_status = NULL,
                                failure = ?, updated_at = ? WHERE id = ?
                            """, bindings: [.text(turn.failure!), .real(now.timeIntervalSince1970),
                                            .text(turn.id.uuidString)])
                        interrupted.append(turn)
                    default:
                        break
                    }
                }
                try db.execute("COMMIT")
                return ConversationRecovery(queuedTurns: queued, interruptedTurns: interrupted)
            } catch {
                try? db.execute("ROLLBACK")
                throw error
            }
        }
    }

    public func saveSummary(_ summary: ConversationSummary) async throws {
        guard summary.revision > 0, summary.sourceCursor >= summary.coveredRange.upperBound else {
            throw DomainStoreError.invalidMigration("滚动摘要游标无效")
        }
        try await domain.write { database in
            try Self.database(database).execute("""
                INSERT OR REPLACE INTO conv_summaries(id, conversation_id, covered_start, covered_end,
                    revision, source_cursor, text, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, bindings: [.text(summary.id.uuidString), .text(summary.conversationID.uuidString),
                                .integer(summary.coveredRange.lowerBound), .integer(summary.coveredRange.upperBound),
                                .integer(Int64(summary.revision)), .integer(summary.sourceCursor),
                                .text(summary.text), .real(summary.createdAt.timeIntervalSince1970)])
        }
    }

    public func latestSummary(conversationID: UUID) async throws -> ConversationSummary? {
        try await domain.read { database in
            let rows = try Self.database(database).query("""
                SELECT * FROM conv_summaries WHERE conversation_id = ?
                ORDER BY revision DESC LIMIT 1
                """, bindings: [.text(conversationID.uuidString)])
            return try rows.first.map(Self.summary)
        }
    }

    public func context(conversationID: UUID, recentLimit: Int = 20) async throws -> ConversationContext {
        async let recent = messages(conversationID: conversationID, limit: recentLimit)
        async let summary = latestSummary(conversationID: conversationID)
        async let questions = pendingQuestions(conversationID: conversationID)
        return try await ConversationContext(recentMessages: recent, summary: summary, pendingQuestions: questions)
    }

    public func pendingQuestions(conversationID: UUID) async throws -> [PendingQuestion] {
        try await domain.read { database in
            let rows = try Self.database(database).query("""
                SELECT q.question_json FROM conv_questions q
                JOIN conv_turns t ON t.id = q.turn_id
                WHERE t.conversation_id = ? AND q.resolved_at IS NULL ORDER BY q.created_at
                """, bindings: [.text(conversationID.uuidString)])
            return try rows.compactMap { $0["question_json"]?.blob }
                .map { try Self.decoder.decode(PendingQuestion.self, from: $0) }
        }
    }

    private func updateTurn(_ id: UUID, state: ConversationTurnState, terminalStatus: String?,
                            failure: String?, now: Date) async throws {
        try await domain.write { database in
            try Self.database(database).execute("""
                UPDATE conv_turns SET state = ?, terminal_status = ?, failure = ?, updated_at = ? WHERE id = ?
                """, bindings: [.text(state.rawValue), terminalStatus.map(SQLiteValue.text) ?? .null,
                                failure.map(SQLiteValue.text) ?? .null, .real(now.timeIntervalSince1970),
                                .text(id.uuidString)])
        }
    }

    private static func message(_ row: [String: SQLiteValue]) throws -> ConversationMessage {
        ConversationMessage(
            id: try uuid(row["id"]), conversationID: try uuid(row["conversationID"]),
            turnID: try optionalUUID(row["turnID"]),
            role: ConversationRole(rawValue: try string(row["role"])) ?? .assistant,
            source: try decodeOptional(SourceEnvelope.self, row["sourceJSON"]),
            text: try string(row["text"]),
            evidenceRefs: try decodeOptional([EvidenceRef].self, row["evidenceJSON"]) ?? [],
            artifacts: try decodeOptional([ConversationArtifactRef].self, row["artifactsJSON"]) ?? [],
            createdAt: Date(timeIntervalSince1970: try real(row["createdAt"])),
            sequence: row["seq"]?.integer ?? 0)
    }

    private static func turn(_ row: [String: SQLiteValue]) throws -> ConversationTurn {
        ConversationTurn(
            id: try uuid(row["id"]), conversationID: try uuid(row["conversationID"]),
            requestID: try uuid(row["requestID"]), principal: try string(row["principal"]),
            userMessageID: try uuid(row["userMessageID"]), text: try string(row["text"]),
            state: ConversationTurnState(rawValue: try string(row["state"])) ?? .interrupted,
            terminalStatus: row["terminalStatus"]?.text, failure: row["failure"]?.text,
            createdAt: Date(timeIntervalSince1970: try real(row["createdAt"])),
            updatedAt: Date(timeIntervalSince1970: try real(row["updatedAt"])))
    }

    private static func summary(_ row: [String: SQLiteValue]) throws -> ConversationSummary {
        let lower = try integer(row["coveredStart"])
        let upper = try integer(row["coveredEnd"])
        return ConversationSummary(
            id: try uuid(row["id"]), conversationID: try uuid(row["conversationID"]),
            coveredRange: lower...upper, revision: Int(try integer(row["revision"])),
            sourceCursor: try integer(row["sourceCursor"]), text: try string(row["text"]),
            createdAt: Date(timeIntervalSince1970: try real(row["createdAt"])))
    }

    private static func database(_ database: DomainDatabase) throws -> SQLiteDomainDatabase {
        guard let database = database as? SQLiteDomainDatabase else {
            throw DomainStoreError.sqlite("ConversationStore 需要 SQLiteDomainDatabase")
        }
        return database
    }

    private static func uuid(_ value: SQLiteValue?) throws -> UUID {
        guard let text = value?.text, let uuid = UUID(uuidString: text) else {
            throw DomainStoreError.sqlite("持久化 UUID 无效")
        }
        return uuid
    }

    private static func optionalUUID(_ value: SQLiteValue?) throws -> UUID? {
        guard case .text(let text)? = value else { return nil }
        guard let uuid = UUID(uuidString: text) else { throw DomainStoreError.sqlite("持久化 UUID 无效") }
        return uuid
    }

    private static func string(_ value: SQLiteValue?) throws -> String {
        guard let value = value?.text else { throw DomainStoreError.sqlite("持久化字符串无效") }
        return value
    }

    private static func integer(_ value: SQLiteValue?) throws -> Int64 {
        guard let value = value?.integer else { throw DomainStoreError.sqlite("持久化整数无效") }
        return value
    }

    private static func real(_ value: SQLiteValue?) throws -> Double {
        guard let value = value?.real else { throw DomainStoreError.sqlite("持久化时间无效") }
        return value
    }

    private static func decodeOptional<T: Decodable>(_ type: T.Type, _ value: SQLiteValue?) throws -> T? {
        guard let data = value?.blob else { return nil }
        return try decoder.decode(type, from: data)
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

private struct ConversationMigration: DomainMigration {
    let owner = ConversationStore.migrationOwner
    let version: Int
    let tablePrefix = "conv_"

    func apply(_ db: DomainDatabase) throws {
        guard let db = db as? SQLiteDomainDatabase else {
            throw DomainStoreError.sqlite("会话迁移需要 SQLite")
        }
        try db.execute("""
            CREATE TABLE conv_turns (
                id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, request_id TEXT NOT NULL UNIQUE,
                principal TEXT NOT NULL, user_message_id TEXT NOT NULL, text TEXT NOT NULL,
                state TEXT NOT NULL, terminal_status TEXT, failure TEXT,
                created_at REAL NOT NULL, updated_at REAL NOT NULL
            )
            """)
        try db.execute("""
            CREATE TABLE conv_messages (
                seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
                conversation_id TEXT NOT NULL, turn_id TEXT, role TEXT NOT NULL,
                source_json BLOB, text TEXT NOT NULL, evidence_json BLOB NOT NULL,
                artifacts_json BLOB NOT NULL, created_at REAL NOT NULL
            )
            """)
        try db.execute("CREATE INDEX conv_messages_page ON conv_messages(conversation_id, seq)")
        try db.execute("CREATE INDEX conv_turns_queue ON conv_turns(conversation_id, state, created_at)")
        try db.execute("""
            CREATE TABLE conv_summaries (
                id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, covered_start INTEGER NOT NULL,
                covered_end INTEGER NOT NULL, revision INTEGER NOT NULL, source_cursor INTEGER NOT NULL,
                text TEXT NOT NULL, created_at REAL NOT NULL,
                UNIQUE(conversation_id, revision)
            )
            """)
        try db.execute("""
            CREATE TABLE conv_questions (
                id TEXT PRIMARY KEY, turn_id TEXT NOT NULL, question_json BLOB NOT NULL,
                created_at REAL NOT NULL, resolved_at REAL
            )
            """)
    }
}
