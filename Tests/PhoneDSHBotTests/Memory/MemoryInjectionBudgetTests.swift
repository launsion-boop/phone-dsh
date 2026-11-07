// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class MemoryInjectionBudgetTests: XCTestCase {
    func testProfileKeepsNewestFitWithOmittedCountAndMaintenanceHint() {
        let facts = (0..<60).map { index in
            makeMemoryFact(
                "profile-\(index)",
                "第 \(index) 條畫像：" + String(repeating: "使用者偏好的詳細內容", count: 4),
                tier: .profile,
                learnedAtMS: MemoryTestFixtures.now + Int64(index)
            )
        }
        let injection = BotMemoryInjector.render(
            scopes: [BotMemoryScopeInput(scope: .agent, root: "/fixture/agent", facts: facts)],
            language: .zh,
            now: MemoryTestFixtures.now
        )
        XCTAssertTrue(injection.text.contains("第 59 條畫像"))
        XCTAssertTrue(injection.text.contains("較早的"))
        XCTAssertTrue(injection.text.contains("條未列出，可用 RecallMemory 查詢"))
        XCTAssertTrue(injection.text.contains("profile 已達到上限的 80%"))
        XCTAssertTrue(injection.text.contains("請整理"))
        XCTAssertLessThanOrEqual(injection.text.utf16.count, BotMemoryLimits.standard.total)
    }

    func testBothScopesKeepThreeNewestLogsDuringTotalShrink() {
        var facts: [BotMemoryFact] = []
        for scope in [BotMemoryScope.agent, .user] {
            for index in 0..<60 {
                facts.append(makeMemoryFact(
                    "\(scope.rawValue)-profile-\(index)",
                    "\(scope.rawValue) profile \(index): " + String(repeating: "長期畫像內容", count: 4),
                    tier: .profile,
                    scope: scope,
                    learnedAtMS: MemoryTestFixtures.now + Int64(index)
                ))
            }
            for index in 0..<15 {
                facts.append(makeMemoryFact(
                    "\(scope.rawValue)-log-\(index)",
                    "\(scope.rawValue) log \(index): " + String(repeating: "當天發生的事情", count: 3),
                    scope: scope,
                    learnedAtMS: MemoryTestFixtures.now + Int64(index)
                ))
            }
        }
        let inputs = [BotMemoryScope.agent, .user].map { scope in
            BotMemoryScopeInput(
                scope: scope,
                root: "/fixture/\(scope.rawValue)",
                facts: facts.filter { $0.scope == scope }
            )
        }
        let text = BotMemoryInjector.render(
            scopes: inputs,
            language: .zh,
            now: MemoryTestFixtures.now
        ).text
        XCTAssertLessThanOrEqual(text.utf16.count, BotMemoryLimits.standard.total)
        for scope in [BotMemoryScope.agent, .user] {
            for index in [12, 13, 14] {
                XCTAssertTrue(text.contains("\(scope.rawValue) log \(index):"))
            }
        }
    }

    func testRecentLogUsesNewestTwelveAndExplicitTruncation() {
        let facts = (0..<15).map { index in
            makeMemoryFact(
                "log-\(index)",
                "log entry \(index)",
                learnedAtMS: MemoryTestFixtures.now + Int64(index)
            )
        }
        let text = BotMemoryInjector.render(
            scopes: [BotMemoryScopeInput(scope: .agent, root: "/fixture/agent", facts: facts)],
            language: .zh,
            now: MemoryTestFixtures.now
        ).text
        XCTAssertTrue(text.contains("log entry 14"))
        XCTAssertTrue(text.contains("log entry 3"))
        XCTAssertFalse(text.contains("- [2025-10-09] log entry 2\n"))
        XCTAssertTrue(text.contains("只列出最新 12 / 15 条"))
        XCTAssertTrue(text.contains("RecallMemory"))
    }

    func testApplicabilityHintsShareTheSameBudget() {
        let fact = makeMemoryFact(
            "preference",
            "工作日使用簡短摘要",
            tier: .profile,
            applicableWhen: " 工作日的   早晨 ",
            notApplicableWhen: "正式場合"
        )
        let text = BotMemoryInjector.render(
            scopes: [BotMemoryScopeInput(scope: .agent, root: "/fixture/agent", facts: [fact])],
            language: .zh,
            now: MemoryTestFixtures.now
        ).text
        XCTAssertTrue(text.contains("工作日使用簡短摘要（適用：工作日的 早晨；不適用：正式場合）"))
    }
}
