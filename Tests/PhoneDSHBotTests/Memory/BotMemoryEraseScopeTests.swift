// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// P26 whole-scope erase: agent erase is private to the current Bot, user erase
/// is shared by every Bot, and deleting a Bot only tombstones its own agent
/// facts before dropping the cached authority.
final class BotMemoryEraseScopeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-bot-memory-erase-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testEraseAllAgentOnlyAffectsCurrentBotAndSurvivesReopen() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let domain = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let mainStore = SQLiteBotMemoryFactStore(eventLog: domain, botID: "main", now: { 1_000 })
        let botStore = SQLiteBotMemoryFactStore(eventLog: domain, botID: "bot-b", now: { 1_000 })
        let main = BotMemory(store: mainStore, dataRoot: directory.path, botID: "main", now: { 1_000 })
        let bot = BotMemory(store: botStore, dataRoot: directory.path, botID: "bot-b", now: { 1_000 })

        let mainAgent = try await main.writeForTest(BotMemoryWriteRequest(
            text: "main private", scope: .agent, source: BotMemorySource(kind: .userTurn)))
        let mainAgentID = try XCTUnwrap(mainAgent.factID)
        let mainAgentTwo = try await main.writeForTest(BotMemoryWriteRequest(
            text: "main private two", scope: .agent, source: BotMemorySource(kind: .userTurn)))
        let mainAgentTwoID = try XCTUnwrap(mainAgentTwo.factID)
        _ = try await bot.writeForTest(BotMemoryWriteRequest(
            text: "bot private", scope: .agent, source: BotMemorySource(kind: .userTurn)))
        _ = try await main.writeForTest(BotMemoryWriteRequest(
            text: "shared user", scope: .user, source: BotMemorySource(kind: .userTurn)))

        let erased = try await main.eraseAll(scope: .agent)
        XCTAssertTrue(erased.ok)
        XCTAssertEqual(erased.scope, .agent)
        XCTAssertEqual(erased.botID, "main")
        XCTAssertEqual(erased.removed, 2)
        XCTAssertEqual(erased.count, 0)
        XCTAssertEqual(Set(erased.factIDs), Set([mainAgentID, mainAgentTwoID]))
        let mainAfterErase = try await main.facts(scope: .agent)
        let mainUserAfterErase = try await main.facts(scope: .user)
        let botAgentAfterErase = try await bot.facts(scope: .agent)
        let botUserAfterErase = try await bot.facts(scope: .user)
        XCTAssertTrue(mainAfterErase.isEmpty)
        XCTAssertEqual(mainUserAfterErase.map(\.text), ["shared user"])
        XCTAssertEqual(botAgentAfterErase.map(\.text), ["bot private"])
        XCTAssertEqual(botUserAfterErase.map(\.text), ["shared user"])

        // The erase tombstone is durable and blocks resurrection by fact id.
        do {
            try await mainStore.append(makeMemoryFact(mainAgentID, "resurrected"))
            XCTFail("an erased agent fact id must not be resurrected")
        } catch {
            XCTAssertEqual(error as? BotMemoryFactStoreError, .erasedFactID(mainAgentID))
        }
        try await domain.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        let replayed = SQLiteBotMemoryFactStore(eventLog: reopened, botID: "main", now: { 2_000 })
        let replayedMemory = BotMemory(
            store: replayed, dataRoot: directory.path, botID: "main", now: { 2_000 })
        let replayedAgent = try await replayedMemory.facts(scope: .agent)
        let replayedUser = try await replayedMemory.facts(scope: .user)
        XCTAssertTrue(replayedAgent.isEmpty)
        XCTAssertEqual(replayedUser.map(\.text), ["shared user"])
        let tombstone = try await replayed.tombstone(factID: mainAgentID, scope: .agent)
        XCTAssertNotNil(tombstone)
        try await reopened.close()
    }

    func testEraseAllUserAffectsSharedScopeButNotAgentFacts() async throws {
        let domain = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        let main = BotMemory(
            store: SQLiteBotMemoryFactStore(eventLog: domain, botID: "main", now: { 1_000 }),
            dataRoot: directory.path, botID: "main", now: { 1_000 })
        let bot = BotMemory(
            store: SQLiteBotMemoryFactStore(eventLog: domain, botID: "bot-b", now: { 1_000 }),
            dataRoot: directory.path, botID: "bot-b", now: { 1_000 })

        _ = try await main.writeForTest(BotMemoryWriteRequest(
            text: "main private", scope: .agent, source: BotMemorySource(kind: .userTurn)))
        _ = try await bot.writeForTest(BotMemoryWriteRequest(
            text: "bot private", scope: .agent, source: BotMemorySource(kind: .userTurn)))
        _ = try await main.writeForTest(BotMemoryWriteRequest(
            text: "shared user", scope: .user, source: BotMemorySource(kind: .userTurn)))
        let botUserBefore = try await bot.facts(scope: .user)
        XCTAssertEqual(botUserBefore.count, 1)

        let erased = try await bot.eraseAll(scope: .user)
        XCTAssertEqual(erased.scope, .user)
        XCTAssertEqual(erased.botID, "bot-b")
        XCTAssertEqual(erased.removed, 1)
        XCTAssertEqual(erased.count, 0)
        let mainUserAfter = try await main.facts(scope: .user)
        let botUserAfter = try await bot.facts(scope: .user)
        let mainAgentAfter = try await main.facts(scope: .agent)
        let botAgentAfter = try await bot.facts(scope: .agent)
        XCTAssertTrue(mainUserAfter.isEmpty)
        XCTAssertTrue(botUserAfter.isEmpty)
        XCTAssertEqual(mainAgentAfter.map(\.text), ["main private"])
        XCTAssertEqual(botAgentAfter.map(\.text), ["bot private"])

        // A no-op erase stays successful and reports zero.
        let again = try await main.eraseAll(scope: .user)
        XCTAssertTrue(again.ok)
        XCTAssertEqual(again.removed, 0)
        try await domain.close()
    }

    func testRuntimeDeleteBotMemoryOnlyTombstonesThatBotAndDropsCache() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        _ = try await fixture.runtime.issueSession(botId: "bot-b", sessionId: "gb-bot-b", kind: .chat)

        let write = { (sessionId: String, scope: String, fact: String) async throws -> String in
            let result = try await registerAndExecute(
                fixture.runtime, name: "UpdateMemory",
                arguments: .object([
                    "action": .string("write"), "scope": .string(scope), "fact": .string(fact),
                ]),
                sessionId: sessionId)
            return try XCTUnwrap(result.structuredContent?["fact_id"]?.stringValue)
        }
        let mainFactID = try await write("gb-main", "agent", "main private")
        let botFactID = try await write("gb-bot-b", "agent", "bot private")
        await fixture.runtime.beginTurn(
            sessionId: "gb-main", hidden: false,
            origin: BotTurnOrigin(rpcId: BotTurnOrigin.userActionRequestId(nonce: "erase-user")))
        _ = try await write("gb-main", "user", "shared user")

        let cachedBot = await fixture.runtime.memory(for: "bot-b")
        let deleted = try await fixture.runtime.deleteBotMemory(for: "bot-b")
        XCTAssertTrue(deleted.ok)
        XCTAssertEqual(deleted.scope, .agent)
        XCTAssertEqual(deleted.botID, "bot-b")
        XCTAssertEqual(deleted.removed, 1)
        XCTAssertEqual(deleted.factIDs, [botFactID])
        XCTAssertEqual(deleted.count, 0)

        let freshBot = await fixture.runtime.memory(for: "bot-b")
        XCTAssertFalse(cachedBot === freshBot, "deleteBotMemory must drop the cached authority")
        let freshBotAgent = try await freshBot.facts(scope: .agent)
        let freshBotUser = try await freshBot.facts(scope: .user)
        XCTAssertTrue(freshBotAgent.isEmpty)
        XCTAssertEqual(freshBotUser.map(\.text), ["shared user"])

        let main = await fixture.runtime.memory(for: "main")
        let mainAgent = try await main.facts(scope: .agent)
        let mainUser = try await main.facts(scope: .user)
        XCTAssertEqual(mainAgent.map(\.factID), [mainFactID])
        XCTAssertEqual(mainUser.map(\.text), ["shared user"])

        // `freshBot` re-cached the authority; forgetMemory drops it and is
        // idempotent afterwards.
        let dropped = await fixture.runtime.forgetMemory(for: "bot-b")
        XCTAssertTrue(dropped)
        let droppedAgain = await fixture.runtime.forgetMemory(for: "bot-b")
        XCTAssertFalse(droppedAgain)
        let mainDropped = await fixture.runtime.forgetMemory(for: "main")
        XCTAssertTrue(mainDropped)
        let recreatedMain = await fixture.runtime.memory(for: "main")
        XCTAssertFalse(main === recreatedMain)
        // Forgetting the cache does not erase durable facts.
        let recreatedAgent = try await recreatedMain.facts(scope: .agent)
        XCTAssertEqual(recreatedAgent.map(\.factID), [mainFactID])
    }
}
