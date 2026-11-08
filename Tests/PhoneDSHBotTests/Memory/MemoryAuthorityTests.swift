// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class MemoryAuthorityTests: XCTestCase {
    func testWriteFoldsEveryLineBreakAndStoreRemainsAuthoritative() async throws {
        let store = InMemoryBotMemoryFactStore()
        let memory = BotMemory(store: store, dataRoot: "/fixture", botID: "main", now: { MemoryTestFixtures.now })
        let source = BotMemorySource(kind: .userTurn)
        let written = try await memory.writeForTest(BotMemoryWriteRequest(
            text: " 第一行\r\n第二行\u{2028}第三行\u{2029}第四行\u{0085}第五行\u{000B}第六行\u{000C}第七行 ",
            tier: .profile,
            source: source
        ))
        XCTAssertTrue(written.ok)
        var facts = try await memory.facts(scope: .agent)
        XCTAssertEqual(facts.map(\.text), ["第一行；第二行；第三行；第四行；第五行；第六行；第七行"])
        var prompt = try await memory.promptBlock(scopes: [.agent])
        let line = "- 第一行；第二行；第三行；第四行；第五行；第六行；第七行"
        XCTAssertEqual(prompt.components(separatedBy: .newlines).filter { $0 == line }.count, 1)

        try await store.append(makeMemoryFact("external", "直接由權威存儲新增", tier: .profile))
        prompt = try await memory.promptBlock(scopes: [.agent])
        XCTAssertTrue(prompt.contains("直接由權威存儲新增"))
        facts = try await memory.facts(scope: .agent)
        XCTAssertEqual(facts.count, 2)

        let empty = try await memory.writeForTest(BotMemoryWriteRequest(text: " \r\n\t ", source: source))
        XCTAssertFalse(empty.ok)
        XCTAssertEqual(empty.code, "empty")
        let long = try await memory.writeForTest(BotMemoryWriteRequest(
            text: String(repeating: "字", count: 2001),
            source: source
        ))
        XCTAssertFalse(long.ok)
        XCTAssertEqual(long.code, "too-long")
        let afterRejectedWrites = try await memory.facts()
        XCTAssertEqual(afterRejectedWrites.count, 2)
    }

    func testForgetUsesNormalizedExactTextAndRemovesEveryMatchOnlyInScope() async throws {
        let store = InMemoryBotMemoryFactStore(facts: [
            makeMemoryFact("agent-log-1", "第一行；第二行", learnedAtMS: 1),
            makeMemoryFact("agent-log-2", "第一行；第二行", learnedAtMS: 2),
            makeMemoryFact("agent-profile", "第一行；第二行", tier: .profile, learnedAtMS: 3),
            makeMemoryFact("agent-other", "第一行；第二行不同", learnedAtMS: 4),
            makeMemoryFact("user-log", "第一行；第二行", scope: .user, learnedAtMS: 5)
        ])
        let memory = BotMemory(store: store, dataRoot: "/fixture", botID: "main")
        let result = try await memory.forget(text: "- 第一行\r\n第二行", scope: .agent)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.removedFacts, 3)
        XCTAssertEqual(Set(result.factIDs), ["agent-log-1", "agent-log-2", "agent-profile"])
        let remaining = try await memory.facts()
        XCTAssertEqual(remaining.map(\.factID), ["agent-other", "user-log"])
        let forgetTombstones = await store.allTombstones()
        XCTAssertTrue(forgetTombstones.isEmpty)

        let fallback = try await memory.forget(factID: "user-log", scope: .agent)
        XCTAssertTrue(fallback.ok)
        XCTAssertEqual(fallback.scope, .user)
        XCTAssertEqual(fallback.removedFacts, 1)
        let afterFallback = try await memory.facts()
        XCTAssertEqual(afterFallback.map(\.factID), ["agent-other"])
    }

    func testWriteDeduplicationMatchesTierRules() async throws {
        let store = InMemoryBotMemoryFactStore(facts: [
            makeMemoryFact("profile", "相同事實", tier: .profile),
            makeMemoryFact("log", "相同事實"),
            makeMemoryFact("note", "相同事實", tier: .note, key: "key"),
            makeMemoryFact("imported-note", "無 key 筆記", tier: .note)
        ])
        let memory = BotMemory(store: store, dataRoot: "/fixture", botID: "main", now: { MemoryTestFixtures.now })
        let source = BotMemorySource(kind: .userTurn)
        let profile = try await memory.writeForTest(BotMemoryWriteRequest(text: "相同事實", tier: .profile, source: source))
        XCTAssertTrue(profile.duplicated)
        XCTAssertEqual(profile.factID, "profile")
        XCTAssertEqual(profile.count, 4)

        let log = try await memory.writeForTest(BotMemoryWriteRequest(text: "相同事實", source: source))
        XCTAssertTrue(log.ok)
        XCTAssertFalse(log.duplicated)
        XCTAssertEqual(log.count, 5)

        let note = try await memory.writeForTest(BotMemoryWriteRequest(text: "相同事實", tier: .note, key: "key", source: source))
        XCTAssertTrue(note.duplicated)
        XCTAssertEqual(note.factID, "note")
        XCTAssertEqual(note.count, 5)

        let imported = try await memory.writeForTest(BotMemoryWriteRequest(text: "無 key 筆記", tier: .note, source: source))
        XCTAssertTrue(imported.ok)
        XCTAssertFalse(imported.duplicated)
        XCTAssertEqual(imported.count, 6)
        let facts = try await memory.facts()
        XCTAssertEqual(facts.count, 6)
    }

    func testConcurrentProfileAndNoteWritesDeduplicateWithinOneMemoryInstance() async throws {
        for tier in [BotMemoryTier.profile, .note] {
            let store = InMemoryBotMemoryFactStore(yields: true)
            let memory = BotMemory(
                store: store,
                dataRoot: "/fixture",
                botID: "main",
                now: { MemoryTestFixtures.now }
            )
            let request = BotMemoryWriteRequest(
                text: "同一則並發事實",
                tier: tier,
                key: tier == .note ? "shared" : nil,
                source: BotMemorySource(kind: .userTurn)
            )
            let results = try await withThrowingTaskGroup(of: BotMemoryWriteResult.self) { group in
                for _ in 0..<24 {
                    group.addTask { try await memory.writeForTest(request) }
                }
                var results: [BotMemoryWriteResult] = []
                for try await result in group { results.append(result) }
                return results
            }
            XCTAssertEqual(results.count, 24)
            XCTAssertEqual(results.filter { !$0.duplicated }.count, 1)
            XCTAssertEqual(results.filter { $0.duplicated }.count, 23)
            XCTAssertEqual(Set(results.compactMap(\.factID)).count, 1)
            let facts = try await memory.facts()
            XCTAssertEqual(facts.count, 1)
            XCTAssertEqual(facts[0].tier, tier)
        }
    }

    func testNonPositiveExpiryIsNotPersisted() async throws {
        let store = InMemoryBotMemoryFactStore()
        let memory = BotMemory(store: store, dataRoot: "/fixture", botID: "main", now: { 1000 })
        let result = try await memory.writeForTest(BotMemoryWriteRequest(
            text: "沒有有效到期時間",
            source: BotMemorySource(kind: .userTurn),
            expiresAt: 0
        ))
        XCTAssertTrue(result.ok)
        let facts = try await memory.facts()
        XCTAssertEqual(facts.count, 1)
        XCTAssertNil(facts[0].expiresAt)
    }

    func testEraseWritesTextFreeTombstoneAndCannotResurrectFact() async throws {
        let store = InMemoryBotMemoryFactStore(facts: [
            makeMemoryFact("erase-me", "需要徹底抹除的代號", tier: .profile),
            makeMemoryFact("user-other", "其他 scope 保留", scope: .user)
        ])
        let memory = BotMemory(store: store, dataRoot: "/fixture", botID: "main", now: { 9999 })
        let erased = try await memory.erase(factID: "erase-me")
        XCTAssertTrue(erased.ok)
        XCTAssertTrue(erased.erased)
        XCTAssertEqual(erased.erasedAtMS, 9999)
        XCTAssertEqual(erased.count, 0)
        let afterErase = try await memory.facts()
        XCTAssertEqual(afterErase.map(\.factID), ["user-other"])
        let promptAfterErase = try await memory.promptBlock(scopes: [.agent])
        XCTAssertFalse(promptAfterErase.contains("需要徹底抹除的代號"))
        let tombstones = await store.allTombstones()
        XCTAssertEqual(tombstones, [BotMemoryTombstone(factID: "erase-me", erasedAtMS: 9999)])

        let repeated = try await memory.erase(factID: "erase-me")
        XCTAssertTrue(repeated.ok)
        XCTAssertTrue(repeated.alreadyErased)
        XCTAssertFalse(repeated.erased)
        XCTAssertEqual(repeated.count, 0)
        do {
            try await store.append(makeMemoryFact("erase-me", "復活"))
            XCTFail("an erased fact id must not be appended")
        } catch {
            XCTAssertEqual(error as? BotMemoryFactStoreError, .erasedFactID("erase-me"))
        }
        let missing = try await memory.erase(factID: "missing")
        XCTAssertFalse(missing.ok)
        XCTAssertEqual(missing.error, "fact not found: missing")
        XCTAssertEqual(missing.count, 1)
    }

    func testInactiveFactsStayStoredButNeverReachInjection() async throws {
        let facts = [
            makeMemoryFact("archived", "已歸檔事實", tier: .profile, archived: true),
            makeMemoryFact("superseded", "已取代事實", supersededBy: "new"),
            makeMemoryFact("expired", "已過期事實", expiresAt: 1000),
            makeMemoryFact("expired-note", "已過期筆記", tier: .note, key: "old", expiresAt: 1000),
            makeMemoryFact("active-profile", "有效畫像", tier: .profile),
            makeMemoryFact("active-note", "有效筆記", tier: .note, key: "current"),
            makeMemoryFact("active-log", "有效日誌")
        ]
        let store = InMemoryBotMemoryFactStore(facts: facts)
        let memory = BotMemory(store: store, dataRoot: "/fixture", botID: "main", now: { 2000 })
        let prompt = try await memory.promptBlock()
        for inactive in ["已歸檔事實", "已取代事實", "已過期事實", "已過期筆記"] {
            XCTAssertFalse(prompt.contains(inactive))
        }
        for active in ["有效畫像", "有效筆記", "有效日誌"] {
            XCTAssertTrue(prompt.contains(active))
        }
        let storedFacts = try await memory.facts()
        XCTAssertEqual(storedFacts.count, facts.count)
    }
}
