// SPDX-License-Identifier: MIT

import Foundation
@testable import PhoneDSHBot

enum MemoryTestFixtures {
    static let now: Int64 = 1_760_000_000_000

    static func data(_ name: String) throws -> Data {
        var candidate = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            candidate.deleteLastPathComponent()
            let fixture = candidate
                .appendingPathComponent("spec", isDirectory: true)
                .appendingPathComponent("bot", isDirectory: true)
                .appendingPathComponent("v2", isDirectory: true)
                .appendingPathComponent("golden", isDirectory: true)
                .appendingPathComponent("\(name).json")
            if FileManager.default.fileExists(atPath: fixture.path) {
                return try Data(contentsOf: fixture)
            }
        }
        throw FixtureError.missing(name)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: data(name))
    }

    enum FixtureError: Error {
        case missing(String)
    }
}

struct MemoryDocumentGolden: Decodable {
    struct Invalid: Decodable {
        let reason: String
        let document: BotMemoryDocument
    }

    let valid: [BotMemoryDocument]
    let invalid: [Invalid]
}

struct MemoryInjectionGolden: Decodable {
    struct Value: Decodable {
        let text: String
        let limits: BotMemoryLimits
    }

    struct Index: Decodable {
        let path: String
        let version: Int
        let content: String
    }

    struct Indexes: Decodable {
        let user: Index
        let agent: Index
    }

    let valid: Value
    let indexes: Indexes
    let emptyIndex: Value
}

struct MemoryRecallExpected: Decodable {
    struct Query: Decodable {
        let name: String
        let query: String
        let limit: Int
        let scope: String
        let expectedPaths: [String]
        let snippetContains: [String]?
    }

    let documents: [BotMemoryDocument]
    let queries: [Query]
    let hits: [BotMemoryRecallHit]
}

struct MemoryLegacyFactGolden: Decodable {
    struct Invalid: Decodable {
        let reason: String
        let fact: BotMemoryFact
    }

    let valid: [BotMemoryFact]
    let invalid: [Invalid]
}

struct MemoryMigrationGolden: Decodable {
    struct Fact: Decodable {
        let owner: String
        let factID: String
        let text: String
        let learnedAtMS: Int64
        let tier: BotMemoryTier
        let scope: BotMemoryScope
        let key: String?
        let trust: String?
        let evidence: [String]?

        enum CodingKeys: String, CodingKey {
            case owner
            case factID = "fact_id"
            case text
            case learnedAtMS = "learned_at_ms"
            case tier
            case scope
            case key
            case trust
            case evidence
        }
    }

    struct Expected {
        let documents: [String: String]
        let evidence: [String: [String]]
    }

    struct BotCase: Decodable {
        let documents: [String: String]
        let evidence: [String: [String]]
    }

    let bots: [String]
    let facts: [Fact]
    let expected: [String: BotCase]
}

func makeMemoryTestStore(
    _ file: StaticString = #filePath,
    _ line: UInt = #line
) throws -> (store: SQLiteDomainStore, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("memory-v2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SQLiteDomainStore(
        fileURL: root.appendingPathComponent("domain.sqlite"),
        now: { MemoryTestFixtures.now })
    return (store, root)
}

func cleanupMemoryTestStore(_ root: URL?) {
    if let root {
        try? FileManager.default.removeItem(at: root)
    }
}

func makeMemory(
    store: SQLiteDomainStore,
    botID: String = "main",
    now: Int64 = MemoryTestFixtures.now
) -> BotMemory {
    BotMemory(
        store: SQLiteBotMemoryDocumentStore(eventLog: store, botID: botID, now: { now }),
        botID: botID,
        now: { now })
}

func makeDocument(
    _ path: String,
    _ content: String,
    version: Int = 1,
    updatedAtMS: Int64 = MemoryTestFixtures.now,
    author: BotMemoryAuthor = BotMemoryAuthor(botID: "main", kind: .system),
    evidence: [String] = [],
    trust: String = "assistant"
) -> BotMemoryDocument {
    BotMemoryDocument(
        path: path,
        scope: BotMemoryAuthorizer.scope(of: path) ?? .agent,
        content: content,
        version: version,
        updatedAtMS: updatedAtMS,
        author: author,
        evidence: evidence,
        trust: trust)
}

@discardableResult
func seedDocument(
    _ document: BotMemoryDocument,
    store: SQLiteDomainStore,
    botID: String = "main",
    atMS: Int64 = MemoryTestFixtures.now
) async throws -> BotMemoryDocument {
    let writer = SQLiteBotMemoryDocumentStore(eventLog: store, botID: botID, now: { atMS })
    let author = BotMemoryAuthor(
        botID: botID,
        sessionID: document.author.sessionID,
        kind: document.author.kind)
    var current = try await writer.document(path: document.path)?.version ?? 0
    var latest: BotMemoryDocument?
    while current < document.version {
        let outcome = try await writer.write(BotMemoryStoreWriteRequest(
            action: .write,
            path: document.path,
            content: document.content,
            expectedVersion: current,
            author: author,
            evidence: document.evidence,
            trust: nil,
            source: nil,
            atMS: atMS))
        guard case let .written(written, _) = outcome else {
            throw BotMemoryTestError.seedFailed("\(document.path): \(outcome)")
        }
        latest = written
        current = written.version
    }
    if let latest { return latest }
    if let existing = try await writer.document(path: document.path) { return existing }
    throw BotMemoryTestError.seedFailed("\(document.path): no version")
}

func appendLegacyFact(
    _ fact: BotMemoryFact,
    ownerBotID: String?,
    store: SQLiteDomainStore,
    atMS: Int64 = MemoryTestFixtures.now
) async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try BotJSONValue.parse(encoder.encode(fact))
    let event = BotEvent(
        type: "memory.written",
        eventId: "legacy-\(ownerBotID ?? "main")-\(fact.factID)",
        time: max(0, atMS),
        origin: .local(source: "memory-service"),
        traceId: "trace-legacy-\(fact.factID)",
        principal: BotPrincipal(botId: ownerBotID, sessionId: nil, kind: "ipc"),
        causationId: nil,
        correlationId: nil,
        data: data)
    _ = try await store.append(event)
}

func makeLegacyFact(
    _ id: String,
    _ text: String,
    tier: BotMemoryTier = .log,
    scope: BotMemoryScope = .agent,
    learnedAtMS: Int64 = MemoryTestFixtures.now,
    key: String? = nil,
    evidence: [String]? = nil
) -> BotMemoryFact {
    BotMemoryFact(
        factID: id,
        text: text,
        learnedAtMS: learnedAtMS,
        tier: tier,
        scope: scope,
        key: key,
        trust: .string("import"),
        extractor: "import",
        evidence: evidence)
}

enum BotMemoryTestError: Error, CustomStringConvertible {
    case seedFailed(String)
    case unexpected(String)

    var description: String {
        switch self {
        case .seedFailed(let message): return "seed failed: \(message)"
        case .unexpected(let message): return message
        }
    }
}
