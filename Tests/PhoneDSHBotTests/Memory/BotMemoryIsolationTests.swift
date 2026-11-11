// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// P26 per-Bot memory scope: agent facts are isolated by principal botId,
/// user facts are shared, and historical events with no bot id belong to
/// `"main"`. The SQLite event log stays the only durable authority.
final class BotMemoryIsolationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-bot-memory-isolation-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testRuntimeToolsWriteMemoryUnderTheCallerBotAndIsolateAgentFacts() async throws {
        let domain = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        let runtime = BotMCPRuntime(store: domain, recordEvidence: FixedRecordEvidenceResolver(), now: { 1_000 })
        _ = try await runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        _ = try await runtime.issueSession(botId: "bot-b", sessionId: "gb-bot-b", kind: .chat)
        await runtime.beginTurn(
            sessionId: "gb-main", hidden: false,
            origin: BotTurnOrigin(rpcId: BotTurnOrigin.userActionRequestId(nonce: "isolation-user")))

        let mainAgent = try await registerAndExecute(
            runtime, name: "UpdateMemory",
            arguments: .object([
                "action": .string("write"), "scope": .string("agent"),
                "fact": .string("main-only agent fact"),
            ]),
            sessionId: "gb-main")
        XCTAssertEqual(mainAgent.structuredContent?["ok"], .bool(true))

        let sharedUser = try await registerAndExecute(
            runtime, name: "UpdateMemory",
            arguments: .object([
                "action": .string("write"), "scope": .string("user"),
                "fact": .string("shared user fact"),
                "evidence": .array([.string("record://session/gb-main#1")]),
            ]),
            sessionId: "gb-main")
        XCTAssertEqual(sharedUser.structuredContent?["ok"], .bool(true))

        let botAgent = try await registerAndExecute(
            runtime, name: "UpdateMemory",
            arguments: .object([
                "action": .string("write"), "scope": .string("agent"),
                "fact": .string("bot-b agent fact"),
            ]),
            sessionId: "gb-bot-b")
        XCTAssertEqual(botAgent.structuredContent?["ok"], .bool(true))

        let mainMemory = await runtime.memory(for: "main")
        let botMemory = await runtime.memory(for: "bot-b")
        let mainAgentFacts = try await mainMemory.facts(scope: .agent)
        let botAgentFacts = try await botMemory.facts(scope: .agent)
        let mainUserFacts = try await mainMemory.facts(scope: .user)
        let botUserFacts = try await botMemory.facts(scope: .user)
        XCTAssertEqual(mainAgentFacts.map(\.text), ["main-only agent fact"])
        XCTAssertEqual(botAgentFacts.map(\.text), ["bot-b agent fact"])
        XCTAssertEqual(mainUserFacts.map(\.text), ["shared user fact"])
        XCTAssertEqual(botUserFacts.map(\.text), ["shared user fact"])

        // RecallMemory also uses the caller's principal, not the runtime-wide
        // compatibility memory for "main".
        let crossRecall = try await registerAndExecute(
            runtime, name: "RecallMemory",
            arguments: .object(["query": .string("main-only"), "scope": .string("agent")]),
            sessionId: "gb-bot-b")
        XCTAssertEqual(crossRecall.structuredContent?["count"], .number(0))
        let ownRecall = try await registerAndExecute(
            runtime, name: "RecallMemory",
            arguments: .object(["query": .string("bot-b agent"), "scope": .string("agent")]),
            sessionId: "gb-bot-b")
        XCTAssertEqual(ownRecall.structuredContent?["count"], .number(1))

        let events = try await domain.events(after: 0, limit: 1_000)
        let written = events.filter {
            $0.type == "memory.written" && $0.eventId.hasPrefix("evt-memory-write-")
        }
        XCTAssertEqual(written.count, 3)
        XCTAssertEqual(Set(written.compactMap(\.principal.botId)), ["main", "bot-b"])
        try await domain.close()
    }

    func testLegacyNilBotIdAgentFactsBelongToMain() async throws {
        let domain = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        let legacyStore = SQLiteBotMemoryFactStore(eventLog: domain, now: { 1_000 })
        try await legacyStore.append(BotMemoryFact(
            factID: "fact-legacy", text: "legacy main fact", learnedAtMS: 1_000,
            tier: .log, scope: .agent))
        try await legacyStore.append(BotMemoryFact(
            factID: "fact-legacy-user", text: "legacy shared fact", learnedAtMS: 1_000,
            tier: .log, scope: .user))

        let domainEvents = try await domain.events(after: 0, limit: 10)
        XCTAssertEqual(domainEvents.map { $0.principal.botId }, [nil, nil])

        let runtime = BotMCPRuntime(store: domain, recordEvidence: FixedRecordEvidenceResolver(), now: { 1_000 })
        let mainMemory = await runtime.memory(for: "main")
        let botMemory = await runtime.memory(for: "bot-b")
        let mainAgentFacts = try await mainMemory.facts(scope: .agent)
        let botAgentFacts = try await botMemory.facts(scope: .agent)
        let mainUserFacts = try await mainMemory.facts(scope: .user)
        let botUserFacts = try await botMemory.facts(scope: .user)
        XCTAssertEqual(mainAgentFacts.map(\.text), ["legacy main fact"])
        XCTAssertTrue(botAgentFacts.isEmpty)
        XCTAssertEqual(mainUserFacts.map(\.text), ["legacy shared fact"])
        XCTAssertEqual(botUserFacts.map(\.text), ["legacy shared fact"])
        try await domain.close()
    }

    func testPerBotIsolationSurvivesSQLiteReopen() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let first = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let mainStore = SQLiteBotMemoryFactStore(eventLog: first, botID: "main", now: { 1_000 })
        let botStore = SQLiteBotMemoryFactStore(eventLog: first, botID: "bot-b", now: { 1_000 })
        // The same fact id in two agent scopes is valid because the Bot id is
        // part of the event id namespace.
        try await mainStore.append(BotMemoryFact(
            factID: "fact-same-id", text: "main copy", learnedAtMS: 1_000,
            tier: .log, scope: .agent))
        try await botStore.append(BotMemoryFact(
            factID: "fact-same-id", text: "bot copy", learnedAtMS: 1_000,
            tier: .log, scope: .agent))
        try await mainStore.append(BotMemoryFact(
            factID: "fact-shared-user", text: "shared across bots", learnedAtMS: 1_000,
            tier: .log, scope: .user))
        let agentBeforeReopen = try await mainStore.facts(scope: .agent)
        let botBeforeReopen = try await botStore.facts(scope: .agent)
        let userBeforeReopen = try await botStore.facts(scope: .user)
        XCTAssertEqual(agentBeforeReopen.map(\.text), ["main copy"])
        XCTAssertEqual(botBeforeReopen.map(\.text), ["bot copy"])
        XCTAssertEqual(userBeforeReopen.map(\.text), ["shared across bots"])
        try await first.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        let runtime = BotMCPRuntime(store: reopened, now: { 2_000 })
        let mainMemory = await runtime.memory(for: "main")
        let botMemory = await runtime.memory(for: "bot-b")
        let mainAgentFacts = try await mainMemory.facts(scope: .agent)
        let botAgentFacts = try await botMemory.facts(scope: .agent)
        let mainUserFacts = try await mainMemory.facts(scope: .user)
        let botUserFacts = try await botMemory.facts(scope: .user)
        XCTAssertEqual(mainAgentFacts.map(\.text), ["main copy"])
        XCTAssertEqual(botAgentFacts.map(\.text), ["bot copy"])
        XCTAssertEqual(mainUserFacts.map(\.text), ["shared across bots"])
        XCTAssertEqual(botUserFacts.map(\.text), ["shared across bots"])
        try await reopened.close()
    }
}
