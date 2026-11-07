// SPDX-License-Identifier: MIT

import Foundation
@testable import PhoneDSHBot

actor InMemoryBotMemoryFactStore: BotMemoryFactStore {
    private var records: [BotMemoryFact]
    private var erased: [String: [String: BotMemoryTombstone]] = [:]
    private let yields: Bool

    init(facts: [BotMemoryFact] = [], yields: Bool = false) {
        records = facts
        self.yields = yields
    }

    func facts(scope: BotMemoryScope?) async throws -> [BotMemoryFact] {
        if yields { await Task.yield() }
        guard let scope else { return records }
        return records.filter { $0.scope == scope }
    }

    @discardableResult
    func append(_ fact: BotMemoryFact) async throws -> BotMemoryFact {
        if yields { await Task.yield() }
        if records.contains(where: { $0.factID == fact.factID }) {
            throw BotMemoryFactStoreError.duplicateFactID(fact.factID)
        }
        if erased.values.contains(where: { $0[fact.factID] != nil }) {
            throw BotMemoryFactStoreError.erasedFactID(fact.factID)
        }
        records.append(fact)
        return fact
    }

    @discardableResult
    func remove(
        factIDs: [String],
        scope: BotMemoryScope,
        tombstone: BotMemoryTombstone?
    ) async throws -> BotMemoryRemoval {
        let ids = Set(factIDs)
        let removed = records.filter { $0.scope == scope && ids.contains($0.factID) }
        records.removeAll { $0.scope == scope && ids.contains($0.factID) }
        if let tombstone {
            erased[scope.rawValue, default: [:]][tombstone.factID] = tombstone
        }
        return BotMemoryRemoval(
            removed: removed,
            count: records.filter { $0.scope == scope }.count,
            tombstone: tombstone
        )
    }

    func touch(factIDs: [String], lastUsedMS: Int64) async throws {
        let ids = Set(factIDs)
        for index in records.indices where ids.contains(records[index].factID) {
            records[index].lastUsedMS = lastUsedMS
        }
    }

    func tombstone(factID: String, scope: BotMemoryScope) async throws -> BotMemoryTombstone? {
        erased[scope.rawValue]?[factID]
    }

    func allTombstones() -> [BotMemoryTombstone] {
        erased.values.flatMap { Array($0.values) }
    }
}

enum MemoryTestFixtures {
    static let now: Int64 = 1_760_000_000_000

    static func data(_ name: String) throws -> Data {
        var candidate = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            candidate.deleteLastPathComponent()
            let fixture = candidate
                .appendingPathComponent("spec", isDirectory: true)
                .appendingPathComponent("bot", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
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

struct MemoryFactGolden: Decodable {
    let valid: [BotMemoryFact]
    let invalid: [BotMemoryFactNormalization]
}

struct MemoryInjectionGolden: Decodable {
    struct Valid: Decodable {
        let text: String
        let limits: BotMemoryLimits
    }

    let valid: Valid
    let invalid: [BotMemoryFactNormalization]
}

struct MemoryRecallExpected: Decodable {
    let factID: String
    let text: String
    let learnedAtMS: Int64
    let tier: BotMemoryTier
    let scope: BotMemoryScope
    let score: Double
    let relevance: Double
    let recency: Double
    let importance: Double
    let matched: Bool

    enum CodingKeys: String, CodingKey {
        case factID = "fact_id"
        case text
        case learnedAtMS = "learned_at_ms"
        case tier
        case scope
        case score
        case relevance
        case recency
        case importance
        case matched
    }
}

struct MemoryRecallGolden: Decodable {
    let valid: [MemoryRecallExpected]
    let invalid: [MemoryRecallExpected]
}

extension BotMemory {
    func writeForTest(_ request: BotMemoryWriteRequest) async throws -> BotMemoryWriteResult {
        try await write(request, context: BotMemoryWriteContext(source: request.source))
    }
}

func makeMemoryFact(
    _ id: String,
    _ text: String,
    tier: BotMemoryTier = .log,
    scope: BotMemoryScope = .agent,
    learnedAtMS: Int64 = MemoryTestFixtures.now,
    key: String? = nil,
    trust: BotJSONValue? = .string("import"),
    importance: Double = 0.5,
    source: BotMemorySource? = nil,
    supersededBy: String? = nil,
    expiresAt: Int64? = nil,
    applicableWhen: String? = nil,
    notApplicableWhen: String? = nil,
    archived: Bool? = nil,
    l2: Bool? = nil
) -> BotMemoryFact {
    BotMemoryFact(
        factID: id,
        text: text,
        learnedAtMS: learnedAtMS,
        tier: tier,
        scope: scope,
        key: key,
        trust: trust,
        importance: importance,
        extractor: "import",
        source: source,
        supersededBy: supersededBy,
        expiresAt: expiresAt,
        applicableWhen: applicableWhen,
        notApplicableWhen: notApplicableWhen,
        archived: archived,
        l2: l2
    )
}
