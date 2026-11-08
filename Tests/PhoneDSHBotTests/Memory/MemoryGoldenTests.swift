// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class MemoryGoldenTests: XCTestCase {
    func testMemoryFactGoldenAndNormalizationVectors() throws {
        let golden = try MemoryTestFixtures.decode(MemoryFactGolden.self, "memory-fact")
        XCTAssertEqual(golden.valid.map(\.factID), [
            "profile-concise",
            "log-multiline",
            "log-ios",
            "note-routine"
        ])
        for fact in golden.valid {
            let normalized = BotMemoryNormalizer.normalizeFactText(fact.text)
            XCTAssertTrue(normalized.ok)
            XCTAssertEqual(normalized.text, fact.text)
            let encoded = try JSONEncoder().encode(fact)
            XCTAssertEqual(try JSONDecoder().decode(BotMemoryFact.self, from: encoded), fact)
        }
        for expected in golden.invalid {
            XCTAssertEqual(BotMemoryNormalizer.normalizeFactText(expected.text), expected)
        }
    }

    func testMemoryInjectionGoldenIsVerbatim() throws {
        let facts = try MemoryTestFixtures.decode(MemoryFactGolden.self, "memory-fact")
        let golden = try MemoryTestFixtures.decode(MemoryInjectionGolden.self, "memory-injection")
        let inputs = [
            BotMemoryScopeInput(
                scope: .agent,
                root: "<FIXTURE_ROOT>/agents/main/memory",
                facts: facts.valid
            ),
            BotMemoryScopeInput(
                scope: .user,
                root: "<FIXTURE_ROOT>/memory-user",
                facts: [
                    makeMemoryFact(
                        "profile-user",
                        "我叫小林",
                        tier: .profile,
                        scope: .user,
                        learnedAtMS: 1_760_000_000_000
                    ),
                    makeMemoryFact(
                        "log-coffee",
                        "我喜欢咖啡",
                        tier: .log,
                        scope: .user,
                        learnedAtMS: 1_760_000_001_000
                    )
                ]
            )
        ]
        let rendered = BotMemoryInjector.render(
            scopes: inputs,
            language: .zh,
            now: MemoryTestFixtures.now
        )
        XCTAssertEqual(rendered.limits, golden.valid.limits)
        XCTAssertEqual(rendered.text, golden.valid.text)
        for expected in golden.invalid {
            XCTAssertEqual(BotMemoryNormalizer.normalizeFactText(expected.text), expected)
        }
    }

    func testMemoryRecallGoldenScoresAndNoAnswerVector() throws {
        let facts = try MemoryTestFixtures.decode(MemoryFactGolden.self, "memory-fact")
        let golden = try MemoryTestFixtures.decode(MemoryRecallGolden.self, "memory-recall")
        let index = BotMemoryRecallIndex(facts: facts.valid)
        let hits = index.search("简洁 回复", limit: 5, now: MemoryTestFixtures.now)
        XCTAssertEqual(hits.count, golden.valid.count)
        for (hit, expected) in zip(hits, golden.valid) {
            XCTAssertEqual(hit.fact.factID, expected.factID)
            XCTAssertEqual(hit.fact.text, expected.text)
            XCTAssertEqual(hit.fact.learnedAtMS, expected.learnedAtMS)
            XCTAssertEqual(hit.fact.tier, expected.tier)
            XCTAssertEqual(hit.fact.scope, expected.scope)
            XCTAssertEqual(hit.score, expected.score, accuracy: 0.000000000001)
            XCTAssertEqual(hit.relevance, expected.relevance, accuracy: 0.000000000001)
            XCTAssertEqual(hit.recency, expected.recency, accuracy: 0.000000000001)
            XCTAssertEqual(hit.importance, expected.importance, accuracy: 0.000000000001)
            XCTAssertEqual(hit.matched, expected.matched)
        }
        XCTAssertTrue(golden.invalid.isEmpty)
        XCTAssertTrue(index.search("不存在的内容", limit: 5, now: MemoryTestFixtures.now).isEmpty)
    }
}
