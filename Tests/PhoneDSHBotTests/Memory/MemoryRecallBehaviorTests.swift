// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class MemoryRecallBehaviorTests: XCTestCase {
    func testCJKAndShortLatinQueriesUseTokenizerFallbacks() {
        let index = BotMemoryRecallIndex(facts: [
            makeMemoryFact("coffee", "我喜欢咖啡，also drink Coffee daily"),
            makeMemoryFact("tea", "我喜欢红茶，tea daily"),
            makeMemoryFact("bread", "早餐吃面包，bread daily")
        ])
        XCTAssertEqual(index.search("咖", now: MemoryTestFixtures.now).map(\.fact.factID), ["coffee"])
        XCTAssertEqual(index.search("咖啡", now: MemoryTestFixtures.now).map(\.fact.factID), ["coffee"])
        XCTAssertEqual(index.search("co", now: MemoryTestFixtures.now).map(\.fact.factID), ["coffee"])
        XCTAssertTrue(index.search("coffee tea bread", now: MemoryTestFixtures.now).isEmpty)
    }

    func testRecallFiltersInactiveFactsAndOnlyIncludesArchivesOnRequest() {
        let facts = [
            makeMemoryFact("active", "有效咖啡记忆"),
            makeMemoryFact("archived", "归档咖啡记忆", archived: true),
            makeMemoryFact("superseded", "取代咖啡记忆", supersededBy: "active"),
            makeMemoryFact("expired", "过期咖啡记忆", expiresAt: MemoryTestFixtures.now)
        ]
        let index = BotMemoryRecallIndex(facts: facts)
        XCTAssertEqual(
            index.search("咖啡", now: MemoryTestFixtures.now).map(\.fact.factID),
            ["active"]
        )
        XCTAssertEqual(
            Set(index.search("咖啡", now: MemoryTestFixtures.now, includeArchived: true).map(\.fact.factID)),
            ["active", "archived"]
        )
    }

    func testScopedRecallReservesMissingScopeAndTouchesOnlyMatchedHits() async throws {
        let store = InMemoryBotMemoryFactStore(facts: [
            makeMemoryFact("agent-1", "咖啡", learnedAtMS: 1_760_000_003_000, importance: 1),
            makeMemoryFact("agent-2", "咖啡", learnedAtMS: 1_760_000_002_000, importance: 1),
            makeMemoryFact("agent-3", "咖啡", learnedAtMS: 1_760_000_001_000, importance: 1),
            makeMemoryFact("user-1", "咖啡", scope: .user, learnedAtMS: 1_760_000_000_000, importance: 0)
        ])
        let memory = BotMemory(store: store, dataRoot: "/fixture", botID: "main")
        let touchTime: Int64 = 2_000_000_000_000
        let hits = try await memory.recall("咖啡", limit: 2, now: touchTime)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(Set(hits.map { $0.scope }), Set([BotMemoryScope.agent, .user]))
        XCTAssertTrue(hits.contains { $0.factID == "user-1" })
        XCTAssertTrue(hits.allSatisfy { $0.lastUsedMS == touchTime })
        let stored = try await memory.facts()
        XCTAssertEqual(stored.filter { $0.lastUsedMS == touchTime }.map { $0.factID }.sorted(), ["agent-1", "agent-2", "user-1"])
        XCTAssertEqual(stored.first { $0.factID == "agent-3" }?.lastUsedMS, 0)

        _ = try await memory.recall("", limit: 10, now: touchTime + 1000)
        let afterBlank = try await memory.facts()
        XCTAssertEqual(afterBlank.first { $0.factID == "agent-3" }?.lastUsedMS, 0)
        XCTAssertEqual(afterBlank.first { $0.factID == "agent-1" }?.lastUsedMS, touchTime)
    }

    func testImportanceAcceptsBothUpstreamScales() {
        XCTAssertEqual(BotMemoryRecallIndex.normalizeImportance(0.4), 0.4, accuracy: 0.000001)
        XCTAssertEqual(BotMemoryRecallIndex.normalizeImportance(4), 0.8, accuracy: 0.000001)
        XCTAssertEqual(BotMemoryRecallIndex.normalizeImportance(-1), 0)
        XCTAssertEqual(BotMemoryRecallIndex.normalizeImportance(9), 1)
        XCTAssertEqual(BotMemoryRecallIndex.normalizeImportance(.nan), 0.5)
    }
}
