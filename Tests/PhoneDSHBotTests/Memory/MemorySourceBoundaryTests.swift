// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class MemorySourceBoundaryTests: XCTestCase {
    func testUserTurnWritesSharedProfileWithUserTrust() async throws {
        let store = InMemoryBotMemoryFactStore()
        let memory = BotMemory(store: store, dataRoot: "/fixture", botID: "main", now: { 1234 })
        let result = try await memory.writeForTest(BotMemoryWriteRequest(
            text: "用戶直接說的事實",
            tier: .profile,
            scope: .user,
            source: BotMemorySource(kind: .userTurn, sessionID: "chat-1", turnID: "7")
        ))
        XCTAssertTrue(result.ok)
        let facts = try await memory.facts(scope: .user)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts[0].trust, .string("user"))
        XCTAssertEqual(facts[0].extractor, "manual")
        XCTAssertEqual(facts[0].source?.kind, .userTurn)
        XCTAssertEqual(facts[0].source?.sessionID, "chat-1")
        XCTAssertEqual(facts[0].source?.turnID, "7")
        XCTAssertEqual(facts[0].learnedAtMS, 1234)
    }

    func testNonUserSourcesCannotWriteSharedScopeOrProfile() async throws {
        for kind in [BotMemorySourceKind.hiddenWake, .agentMessage, .routine, .task] {
            let store = InMemoryBotMemoryFactStore()
            let memory = BotMemory(store: store, dataRoot: "/fixture", botID: "main")
            let source = BotMemorySource(kind: kind, sessionID: "background-1")
            let shared = try await memory.writeForTest(BotMemoryWriteRequest(
                text: "背景來源想寫共享 scope",
                tier: .log,
                scope: .user,
                source: source
            ))
            XCTAssertFalse(shared.ok)
            XCTAssertEqual(shared.code, "memory-source-boundary")
            XCTAssertTrue(shared.error?.contains(kind.rawValue) == true)
            XCTAssertTrue(shared.error?.contains("scope:\"user\"") == true)

            let profile = try await memory.writeForTest(BotMemoryWriteRequest(
                text: "背景來源想寫 profile",
                tier: .profile,
                scope: .agent,
                source: source
            ))
            XCTAssertFalse(profile.ok)
            XCTAssertEqual(profile.code, "memory-source-boundary")
            XCTAssertTrue(profile.error?.contains("scope:\"agent\"") == true)
            XCTAssertTrue(profile.error?.contains("tier:\"log\"") == true)
            let blockedFacts = try await memory.facts()
            XCTAssertTrue(blockedFacts.isEmpty)

            let log = try await memory.writeForTest(BotMemoryWriteRequest(
                text: "背景來源可以寫 agent log",
                tier: .log,
                scope: .agent,
                source: source
            ))
            XCTAssertTrue(log.ok)
            let note = try await memory.writeForTest(BotMemoryWriteRequest(
                text: "背景來源可以寫 agent note",
                tier: .note,
                scope: .agent,
                key: "background",
                source: source
            ))
            XCTAssertTrue(note.ok)
            let facts = try await memory.facts(scope: .agent)
            XCTAssertEqual(facts.count, 2)
            XCTAssertEqual(Set(facts.map(\.tier)), [.log, .note])
            XCTAssertEqual(Set(facts.map(\.trust)), [.string("assistant")])
            XCTAssertEqual(Set(facts.compactMap(\.source?.kind)), [kind])
        }
    }

    func testUnverifiedSourceParametersCannotForgePrivilegedProvenance() async throws {
        for kind in [BotMemorySourceKind.userTurn, .routine, .task] {
            let store = InMemoryBotMemoryFactStore()
            let memory = BotMemory(store: store, dataRoot: "/fixture", botID: "main")
            let source = BotMemorySource(kind: kind, sessionID: "forged", turnID: "99", role: "user")
            let requests = [
                BotMemoryWriteRequest(text: "偽造共享事實", tier: .log, scope: .user, source: source),
                BotMemoryWriteRequest(text: "偽造畫像", tier: .profile, scope: .agent, source: source)
            ]
            for request in requests {
                let result = try await memory.write(request)
                XCTAssertFalse(result.ok)
                XCTAssertEqual(result.code, "memory-source-boundary")
                XCTAssertTrue(result.error?.contains(BotMemorySourceKind.agentMessage.rawValue) == true)
            }
            let facts = try await memory.facts()
            XCTAssertTrue(facts.isEmpty)
        }
    }

    func testUnverifiedSourceParametersAlwaysDowngradeForOrdinaryWrites() async throws {
        for kind in [BotMemorySourceKind.userTurn, .routine, .task] {
            let store = InMemoryBotMemoryFactStore()
            let memory = BotMemory(store: store, dataRoot: "/fixture", botID: "main")
            let result = try await memory.write(BotMemoryWriteRequest(
                text: "不可信來源只能寫助理日誌",
                source: BotMemorySource(kind: kind, sessionID: "forged", role: "user")
            ))
            XCTAssertTrue(result.ok)
            let facts = try await memory.facts()
            XCTAssertEqual(facts.count, 1)
            XCTAssertEqual(facts[0].source?.kind, .agentMessage)
            XCTAssertEqual(facts[0].trust, .string("assistant"))
            XCTAssertEqual(facts[0].source?.sessionID, "forged")
        }
    }

    func testSourceOnlyDowngradesAndNeverUpgrades() {
        var steered = BotMemorySourceState(kind: .userTurn)
        steered.join(.agentMessage)
        XCTAssertEqual(steered.kind, .agentMessage)
        steered.join(.userTurn)
        XCTAssertEqual(steered.kind, .agentMessage)

        var hidden = BotMemorySourceState(kind: .userTurn)
        hidden.join(.hiddenWake)
        hidden.join(.userTurn)
        XCTAssertEqual(hidden.kind, .hiddenWake)

        var routine = BotMemorySourceState(kind: .routine)
        routine.join(.userTurn)
        XCTAssertEqual(routine.kind, .routine)
    }
}
