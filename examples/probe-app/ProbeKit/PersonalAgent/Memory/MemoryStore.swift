// SPDX-License-Identifier: MIT

import Foundation

public enum MemoryKind: String, Codable, Sendable { case taskContext, event, longTerm }

public enum MemoryStatus: String, Codable, Sendable {
    case candidate, active, rejected, archived, forgotten, withheld, expired
}

public enum MemoryOrigin: String, Codable, Sendable { case userExplicit, modelInference, externalContent }

public enum PersonalContextField: String, Codable, Sendable, CaseIterable {
    case displayName, timeZone, language, responseLength, occupation
    case keyContacts, keyRepositoriesOrLabels, workSchedule
}

public struct MemorySource: Codable, Sendable, Equatable {
    public let kind: SourceKind
    public let reference: String
    public let detail: String
    public let observedAt: Date

    public init(kind: SourceKind, reference: String, detail: String, observedAt: Date = Date()) {
        self.kind = kind
        self.reference = reference
        self.detail = detail
        self.observedAt = observedAt
    }
}

public struct MemoryRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let principal: String
    public let accountScope: String?
    public let kind: MemoryKind
    public let field: PersonalContextField?
    public let text: String
    public let scope: String
    public let source: MemorySource
    public let origin: MemoryOrigin
    public let revision: Int
    public let validFrom: Date
    public let expiresAt: Date?
    public let status: MemoryStatus
    public let supersedes: UUID?
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: UUID = UUID(), principal: String, accountScope: String? = nil, kind: MemoryKind,
                field: PersonalContextField? = nil, text: String, scope: String = "personal",
                source: MemorySource, origin: MemoryOrigin, revision: Int = 1,
                validFrom: Date = Date(), expiresAt: Date? = nil, status: MemoryStatus,
                supersedes: UUID? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.principal = principal
        self.accountScope = accountScope
        self.kind = kind
        self.field = field
        self.text = text
        self.scope = scope
        self.source = source
        self.origin = origin
        self.revision = revision
        self.validFrom = validFrom
        self.expiresAt = expiresAt
        self.status = status
        self.supersedes = supersedes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func isActive(at now: Date = Date()) -> Bool {
        status == .active && validFrom <= now && (expiresAt == nil || expiresAt! > now)
    }

    public func effectiveStatus(at now: Date = Date()) -> MemoryStatus {
        if status == .active, let expiresAt, expiresAt <= now { return .expired }
        return status
    }
}

public enum MemoryError: Error, Sendable, Equatable {
    case emptyContent
    case sensitiveContent
    case externalContentMustBeEvent
    case inferenceMustBeCandidate
    case recordNotFound
}

public struct MemoryContextRequest: Sendable {
    public let accountScope: String?
    public let authenticatedPrincipal: String
    public let conversationID: UUID
    public let source: SourceKind
    public let replyTo: ReplyTarget
    public let grantVersion: Int
    public let query: String
    public let limit: Int
    public let now: Date

    public init(accountScope: String? = nil, authenticatedPrincipal: String, conversationID: UUID,
                source: SourceKind, replyTo: ReplyTarget, grantVersion: Int,
                query: String = "", limit: Int = 12, now: Date = Date()) {
        self.accountScope = accountScope
        self.authenticatedPrincipal = authenticatedPrincipal
        self.conversationID = conversationID
        self.source = source
        self.replyTo = replyTo
        self.grantVersion = grantVersion
        self.query = query
        self.limit = limit
        self.now = now
    }
}

public struct MemoryCitation: Codable, Sendable, Equatable {
    public let memoryID: UUID
    public let sourceRef: String
    public let revision: Int
    public let validFrom: Date
    public let expiresAt: Date?

    public init(record: MemoryRecord) {
        self.memoryID = record.id
        self.sourceRef = record.source.reference
        self.revision = record.revision
        self.validFrom = record.validFrom
        self.expiresAt = record.expiresAt
    }
}

public struct MemoryContext: Sendable, Equatable {
    public let records: [MemoryRecord]
    public let citations: [MemoryCitation]
    public let prompt: String

    public init(records: [MemoryRecord], promptCharacterLimit: Int = 4_000) {
        self.records = records
        self.citations = records.map(MemoryCitation.init)
        var used = 0
        var lines: [String] = []
        for record in records {
            let line = "[\(record.id.uuidString)@\(record.revision)] \(record.text)"
            guard used + line.count <= promptCharacterLimit else { break }
            lines.append(line)
            used += line.count + 1
        }
        self.prompt = lines.joined(separator: "\n")
    }
}

public protocol MemoryPort: Sendable {
    func context(for request: MemoryContextRequest) async throws -> MemoryContext
}

public struct MemoryStore: MemoryPort {
    public static let migrationOwner = "s3.memory"
    private let domain: any DomainStore

    public init(domain: any DomainStore) {
        self.domain = domain
    }

    public func prepare() async throws {
        try await domain.register([MemoryMigration(version: 1)])
    }

    @discardableResult
    public func ingestUserInstruction(_ instruction: String, principal: String,
                                      source: MemorySource, scope: String = "personal",
                                      field: PersonalContextField? = nil, accountScope: String? = nil,
                                      now: Date = Date()) async throws -> MemoryRecord? {
        guard let content = Self.explicitMemoryContent(instruction) else { return nil }
        let record = MemoryRecord(principal: principal, accountScope: accountScope, kind: .longTerm,
                                  field: field, text: content, scope: scope, source: source,
                                  origin: .userExplicit, validFrom: now, status: .active,
                                  createdAt: now, updatedAt: now)
        try await save(record)
        return record
    }

    @discardableResult
    public func infer(_ text: String, principal: String, source: MemorySource,
                      scope: String = "personal", field: PersonalContextField? = nil,
                      accountScope: String? = nil, now: Date = Date()) async throws -> MemoryRecord {
        let record = MemoryRecord(principal: principal, accountScope: accountScope, kind: .longTerm,
                                  field: field, text: text, scope: scope, source: source,
                                  origin: .modelInference, validFrom: now, status: .candidate,
                                  createdAt: now, updatedAt: now)
        try await save(record)
        return record
    }

    @discardableResult
    public func recordExternalEvent(_ text: String, principal: String, source: MemorySource,
                                    scope: String, accountScope: String? = nil,
                                    validFrom: Date = Date(), expiresAt: Date? = nil,
                                    now: Date = Date()) async throws -> MemoryRecord {
        let record = MemoryRecord(principal: principal, accountScope: accountScope, kind: .event,
                                  text: text, scope: scope, source: source, origin: .externalContent,
                                  validFrom: validFrom, expiresAt: expiresAt, status: .active,
                                  createdAt: now, updatedAt: now)
        try await save(record)
        return record
    }

    public func save(_ record: MemoryRecord) async throws {
        let trimmed = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MemoryError.emptyContent }
        guard !Self.containsSensitiveContent(trimmed) else { throw MemoryError.sensitiveContent }
        if record.origin == .externalContent, record.kind != .event {
            throw MemoryError.externalContentMustBeEvent
        }
        if record.origin == .modelInference, record.status != .candidate {
            throw MemoryError.inferenceMustBeCandidate
        }
        let data = try Self.encoder.encode(record)
        try await domain.write { database in
            let db = try Self.database(database)
            try db.execute("""
                INSERT OR REPLACE INTO mem_records(id, principal, account_scope, kind, field, text, scope,
                    source_json, origin, revision, valid_from, expires_at, status, supersedes,
                    created_at, updated_at, record_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, bindings: Self.bindings(record, data: data))
        }
    }

    @discardableResult
    public func acceptCandidate(_ id: UUID, now: Date = Date()) async throws -> MemoryRecord {
        guard var record = try await record(id) else { throw MemoryError.recordNotFound }
        record = MemoryRecord(id: record.id, principal: record.principal, accountScope: record.accountScope,
                              kind: record.kind, field: record.field, text: record.text, scope: record.scope,
                              source: record.source, origin: .userExplicit, revision: record.revision,
                              validFrom: record.validFrom, expiresAt: record.expiresAt, status: .active,
                              supersedes: record.supersedes, createdAt: record.createdAt, updatedAt: now)
        try await save(record)
        return record
    }

    public func rejectCandidate(_ id: UUID, now: Date = Date()) async throws {
        try await setStatus(id, status: .rejected, now: now)
    }

    public func archive(_ id: UUID, now: Date = Date()) async throws {
        try await setStatus(id, status: .archived, now: now)
    }

    public func forget(_ id: UUID, now: Date = Date()) async throws {
        try await setStatus(id, status: .forgotten, now: now)
    }

    @discardableResult
    public func supersede(_ id: UUID, with text: String, scope: String? = nil,
                          validFrom: Date = Date(), expiresAt: Date? = nil,
                          source: MemorySource? = nil, now: Date = Date()) async throws -> MemoryRecord {
        guard let previous = try await record(id), previous.status == .active else {
            throw MemoryError.recordNotFound
        }
        let replacement = MemoryRecord(principal: previous.principal, accountScope: previous.accountScope,
                                       kind: previous.kind, field: previous.field, text: text,
                                       scope: scope ?? previous.scope, source: source ?? previous.source,
                                       origin: .userExplicit, revision: previous.revision + 1,
                                       validFrom: validFrom, expiresAt: expiresAt, status: .active,
                                       supersedes: previous.id, createdAt: now, updatedAt: now)
        guard !Self.containsSensitiveContent(text) else { throw MemoryError.sensitiveContent }
        let data = try Self.encoder.encode(replacement)
        let archived = MemoryRecord(id: previous.id, principal: previous.principal,
                                    accountScope: previous.accountScope, kind: previous.kind,
                                    field: previous.field, text: previous.text, scope: previous.scope,
                                    source: previous.source, origin: previous.origin, revision: previous.revision,
                                    validFrom: previous.validFrom, expiresAt: previous.expiresAt, status: .archived,
                                    supersedes: previous.supersedes, createdAt: previous.createdAt, updatedAt: now)
        let archivedData = try Self.encoder.encode(archived)
        try await domain.write { database in
            let db = try Self.database(database)
            try db.execute("BEGIN IMMEDIATE")
            do {
                try db.execute("""
                    UPDATE mem_records SET status = 'archived', updated_at = ?, record_json = ? WHERE id = ?
                    """, bindings: [.real(now.timeIntervalSince1970), .blob(archivedData), .text(id.uuidString)])
                try db.execute("""
                    INSERT INTO mem_records(id, principal, account_scope, kind, field, text, scope,
                        source_json, origin, revision, valid_from, expires_at, status, supersedes,
                        created_at, updated_at, record_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, bindings: Self.bindings(replacement, data: data))
                try db.execute("COMMIT")
                return
            } catch {
                try? db.execute("ROLLBACK")
                throw error
            }
        }
        return replacement
    }

    public func record(_ id: UUID) async throws -> MemoryRecord? {
        try await domain.read { database in
            let rows = try Self.database(database).query("SELECT record_json FROM mem_records WHERE id = ?",
                                                          bindings: [.text(id.uuidString)])
            return try rows.first.flatMap { $0["recordJson"]?.blob }
                .map { try Self.decoder.decode(MemoryRecord.self, from: $0) }
        }
    }

    public func records(principal: String, statuses: Set<MemoryStatus>? = nil) async throws -> [MemoryRecord] {
        try await domain.read { database in
            let rows = try Self.database(database).query(
                "SELECT record_json FROM mem_records WHERE principal = ? ORDER BY updated_at DESC, id",
                bindings: [.text(principal)])
            let records = try rows.compactMap { $0["recordJson"]?.blob }
                .map { try Self.decoder.decode(MemoryRecord.self, from: $0) }
            return records.filter { statuses?.contains($0.status) ?? true }
        }
    }

    public func active(principal: String, accountScope: String? = nil,
                       query: String = "", limit: Int = 12, now: Date = Date()) async throws -> [MemoryRecord] {
        guard limit > 0, limit <= 100 else { return [] }
        let candidates = try await records(principal: principal, statuses: [.active])
            .filter { $0.isActive(at: now) }
            .filter { $0.accountScope == nil || $0.accountScope == accountScope }
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        let ranked = candidates.sorted { left, right in
            let leftProfile = left.field == nil ? 0 : 1
            let rightProfile = right.field == nil ? 0 : 1
            if leftProfile != rightProfile { return leftProfile > rightProfile }
            let leftScore = terms.reduce(into: 0) { $0 += left.text.lowercased().contains($1) ? 1 : 0 }
            let rightScore = terms.reduce(into: 0) { $0 += right.text.lowercased().contains($1) ? 1 : 0 }
            if leftScore != rightScore { return leftScore > rightScore }
            return left.updatedAt > right.updatedAt
        }
        return Array(ranked.prefix(limit))
    }

    public func context(for request: MemoryContextRequest) async throws -> MemoryContext {
        let records = try await active(principal: request.authenticatedPrincipal,
                                       accountScope: request.accountScope, query: request.query,
                                       limit: request.limit, now: request.now)
        return MemoryContext(records: records)
    }

    public func pendingCandidates(principal: String, limit: Int = 2) async throws -> [MemoryRecord] {
        Array(try await records(principal: principal, statuses: [.candidate]).prefix(max(0, min(limit, 2))))
    }

    private func setStatus(_ id: UUID, status: MemoryStatus, now: Date) async throws {
        guard let current = try await record(id) else { throw MemoryError.recordNotFound }
        let updated = MemoryRecord(id: current.id, principal: current.principal,
                                   accountScope: current.accountScope, kind: current.kind, field: current.field,
                                   text: current.text, scope: current.scope, source: current.source,
                                   origin: current.origin, revision: current.revision,
                                   validFrom: current.validFrom, expiresAt: current.expiresAt, status: status,
                                   supersedes: current.supersedes, createdAt: current.createdAt, updatedAt: now)
        let data = try Self.encoder.encode(updated)
        try await domain.write { database in
            let db = try Self.database(database)
            try db.execute("BEGIN IMMEDIATE")
            do {
                try db.execute("UPDATE mem_records SET status = ?, updated_at = ?, record_json = ? WHERE id = ?",
                               bindings: [.text(status.rawValue), .real(now.timeIntervalSince1970),
                                          .blob(data), .text(id.uuidString)])
                try db.execute("COMMIT")
            } catch {
                try? db.execute("ROLLBACK")
                throw error
            }
        }
    }

    private static func explicitMemoryContent(_ instruction: String) -> String? {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["记住：", "记住:", "记住 ", "记住"] where trimmed.hasPrefix(prefix) {
            let content = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? nil : content
        }
        let lower = trimmed.lowercased()
        for prefix in ["remember that ", "remember ", "please remember "] where lower.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func containsSensitiveContent(_ text: String) -> Bool {
        let patterns = [
            #"(?i)(password|passwd|api[_ -]?key|access[_ -]?token|refresh[_ -]?token|secret|private[_ -]?key)\s*[:=]"#,
            #"(?i)(密码|口令|密钥|令牌|token)\s*[:：=]"#,
            #"(?i)[?&](x-amz-signature|signature|sig|access_token|token)="#,
            #"(?i)bearer\s+[a-z0-9._~+/=-]{12,}"#,
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func bindings(_ record: MemoryRecord, data: Data) -> [SQLiteValue] {
        [.text(record.id.uuidString), .text(record.principal),
         record.accountScope.map(SQLiteValue.text) ?? .null, .text(record.kind.rawValue),
         record.field.map { .text($0.rawValue) } ?? .null, .text(record.text), .text(record.scope),
         .blob((try? Self.encoder.encode(record.source)) ?? Data()), .text(record.origin.rawValue),
         .integer(Int64(record.revision)), .real(record.validFrom.timeIntervalSince1970),
         record.expiresAt.map { .real($0.timeIntervalSince1970) } ?? .null, .text(record.status.rawValue),
         record.supersedes.map { .text($0.uuidString) } ?? .null,
         .real(record.createdAt.timeIntervalSince1970), .real(record.updatedAt.timeIntervalSince1970), .blob(data)]
    }

    private static func database(_ database: DomainDatabase) throws -> SQLiteDomainDatabase {
        guard let database = database as? SQLiteDomainDatabase else {
            throw DomainStoreError.sqlite("MemoryStore 需要 SQLiteDomainDatabase")
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

private struct MemoryMigration: DomainMigration {
    let owner = MemoryStore.migrationOwner
    let version: Int
    let tablePrefix = "mem_"

    func apply(_ db: DomainDatabase) throws {
        guard let db = db as? SQLiteDomainDatabase else { throw DomainStoreError.sqlite("Memory 迁移需要 SQLite") }
        try db.execute("""
            CREATE TABLE mem_records (
                id TEXT PRIMARY KEY, principal TEXT NOT NULL, account_scope TEXT, kind TEXT NOT NULL,
                field TEXT, text TEXT NOT NULL, scope TEXT NOT NULL, source_json BLOB NOT NULL,
                origin TEXT NOT NULL, revision INTEGER NOT NULL, valid_from REAL NOT NULL,
                expires_at REAL, status TEXT NOT NULL, supersedes TEXT, created_at REAL NOT NULL,
                updated_at REAL NOT NULL, record_json BLOB NOT NULL
            )
            """)
        try db.execute("CREATE INDEX mem_active ON mem_records(principal, status, valid_from, expires_at)")
        try db.execute("CREATE INDEX mem_revision ON mem_records(supersedes, revision)")
    }
}
