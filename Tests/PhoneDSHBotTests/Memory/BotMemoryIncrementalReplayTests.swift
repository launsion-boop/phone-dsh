// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// P26 memory replay cache: one full replay per durable log, incremental reads
/// after that, isolated per Bot, shared user scope, and non-fatal bad events.
final class BotMemoryIncrementalReplayTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonedsh-bot-memory-replay-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testWritesAreImmediatelyVisibleAndUserScopeIsShared() async throws {
        let domain = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        let mainStore = SQLiteBotMemoryFactStore(eventLog: domain, botID: "main", now: { 1_000 })
        let botStore = SQLiteBotMemoryFactStore(eventLog: domain, botID: "bot-b", now: { 1_000 })
        let main = BotMemory(store: mainStore, dataRoot: directory.path, botID: "main", now: { 1_000 })
        let bot = BotMemory(store: botStore, dataRoot: directory.path, botID: "bot-b", now: { 1_000 })

        // Prime both authorities so the assertions really exercise the cache.
        let primedMainFacts = try await main.facts()
        let primedBotFacts = try await bot.facts()
        XCTAssertTrue(primedMainFacts.isEmpty)
        XCTAssertTrue(primedBotFacts.isEmpty)

        let userWrite = try await main.writeForTest(BotMemoryWriteRequest(
            text: "shared user fact", scope: .user, source: BotMemorySource(kind: .userTurn)))
        XCTAssertTrue(userWrite.ok)
        let mainUserFacts = try await main.facts(scope: .user)
        XCTAssertEqual(mainUserFacts.map(\.text), ["shared user fact"])
        // A different authority created before the write must see it at once.
        let botUserFacts = try await bot.facts(scope: .user)
        XCTAssertEqual(botUserFacts.map(\.text), ["shared user fact"])

        let agentWrite = try await bot.writeForTest(BotMemoryWriteRequest(
            text: "bot-b agent fact", scope: .agent, source: BotMemorySource(kind: .userTurn)))
        XCTAssertTrue(agentWrite.ok)
        let botAgentFacts = try await bot.facts(scope: .agent)
        XCTAssertEqual(botAgentFacts.map(\.text), ["bot-b agent fact"])
        let mainAgentFacts = try await main.facts(scope: .agent)
        XCTAssertTrue(mainAgentFacts.isEmpty)

        let userFacts = try await main.facts(scope: .user)
        XCTAssertEqual(userFacts.count, 1)
        let agentFacts = try await main.facts(scope: .agent)
        XCTAssertTrue(agentFacts.isEmpty)
        try await domain.close()
    }

    func testReopenReplaysSameFactsWithOneFullReplayPerInstance() async throws {
        let file = directory.appendingPathComponent("domain.sqlite")
        let domain = try SQLiteDomainStore(fileURL: file, now: { 1_000 })
        let store = SQLiteBotMemoryFactStore(eventLog: domain, botID: "main", now: { 1_000 })
        let facts = [
            makeMemoryFact("reopen-agent", "agent fact", learnedAtMS: 1_000),
            makeMemoryFact("reopen-user", "user fact", scope: .user, learnedAtMS: 2_000)
        ]
        for fact in facts { try await store.append(fact) }
        let before = try await store.facts()
        XCTAssertEqual(before, facts)
        let beforeDiagnostics = await store.replayDiagnostics
        XCTAssertEqual(beforeDiagnostics.fullReplayCount, 1)
        XCTAssertEqual(beforeDiagnostics.processedMemoryEventCount, 2)
        try await domain.close()

        let reopened = try SQLiteDomainStore(fileURL: file, now: { 2_000 })
        let replayed = SQLiteBotMemoryFactStore(eventLog: reopened, botID: "main", now: { 2_000 })
        let replayedFacts = try await replayed.facts()
        XCTAssertEqual(replayedFacts, facts)
        let afterDiagnostics = await replayed.replayDiagnostics
        XCTAssertEqual(afterDiagnostics.fullReplayCount, 1)
        XCTAssertEqual(afterDiagnostics.processedMemoryEventCount, 2)
        XCTAssertEqual(afterDiagnostics.skippedEventIDs, [])
        try await reopened.close()
    }

    func testMalformedMemoryEventIsSkippedAndOtherFactsStillReplay() async throws {
        let domain = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        let mainStore = SQLiteBotMemoryFactStore(eventLog: domain, botID: "main", now: { 1_000 })
        let botStore = SQLiteBotMemoryFactStore(eventLog: domain, botID: "bot-b", now: { 1_000 })
        let first = makeMemoryFact("replay-first", "first fact", learnedAtMS: 1_000)
        let second = makeMemoryFact("replay-second", "second fact", learnedAtMS: 2_000)
        let botFact = makeMemoryFact("replay-bot", "bot fact", learnedAtMS: 3_000)
        try await mainStore.append(first)
        let malformed = BotEvent(
            type: "memory.written",
            eventId: "evt-memory-write-malformed",
            time: 1_500,
            origin: .local(source: "memory-service"),
            traceId: "trace-malformed",
            principal: BotPrincipal(botId: "main", sessionId: nil, kind: "ipc"),
            causationId: nil,
            correlationId: nil,
            data: .object(["fact_id": .string("broken")])
        )
        try await domain.append(malformed)
        try await mainStore.append(second)
        try await botStore.append(botFact)

        let mainFacts = try await mainStore.facts(scope: .agent)
        XCTAssertEqual(mainFacts.map(\.factID), [first.factID, second.factID])
        let botFacts = try await botStore.facts(scope: .agent)
        XCTAssertEqual(botFacts.map(\.factID), [botFact.factID])
        let diagnostics = await mainStore.replayDiagnostics
        XCTAssertEqual(diagnostics.skippedEventIDs, [malformed.eventId])
        XCTAssertEqual(diagnostics.processedMemoryEventCount, 4)
        XCTAssertEqual(diagnostics.lastProcessedCommitSeq, 4)
        try await domain.close()

        // A fresh replay must reach the same result (the bad event stays bad).
        let reopened = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 2_000 })
        let replayed = SQLiteBotMemoryFactStore(eventLog: reopened, botID: "main", now: { 2_000 })
        let replayedFacts = try await replayed.facts(scope: .agent)
        XCTAssertEqual(replayedFacts.map(\.factID), [first.factID, second.factID])
        let replayedDiagnostics = await replayed.replayDiagnostics
        XCTAssertEqual(replayedDiagnostics.skippedEventIDs, [malformed.eventId])
        try await reopened.close()
    }

    /// Five Bots, 2,000 agent writes plus 25 shared user writes, then 50
    /// `facts()` and 50 `recall()` calls per Bot. The shared feed must perform
    /// exactly one full scan, and each authority must process each memory event
    /// at most once instead of replaying the log on every read.
    func testIncrementalReplayDoesNotScaleWithCallCount() async throws {
        let domain = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        let botIDs = ["main", "bot-1", "bot-2", "bot-3", "bot-4"]

        for botID in botIDs {
            let store = SQLiteBotMemoryFactStore(eventLog: domain, botID: botID, now: { 1_000 })
            for index in 0..<400 {
                try await store.append(makeMemoryFact(
                    "fact-\(botID)-\(index)",
                    "咖啡 memory \(botID) \(index)",
                    learnedAtMS: 1_000 + Int64(index)))
            }
        }
        let writer = SQLiteBotMemoryFactStore(eventLog: domain, botID: "main", now: { 1_000 })
        for index in 0..<25 {
            try await writer.append(makeMemoryFact(
                "fact-shared-\(index)", "共享 咖啡 \(index)", scope: .user,
                learnedAtMS: 5_000 + Int64(index)))
        }
        let eventCount = 2_025

        let stores = botIDs.map {
            SQLiteBotMemoryFactStore(eventLog: domain, botID: $0, now: { 1_000 })
        }
        let memories = zip(botIDs, stores).map { botID, store in
            BotMemory(store: store, dataRoot: directory.path, botID: botID, now: { 1_000 })
        }

        // First read pays for the only full replay; the other authorities
        // consume the shared feed's history.
        for memory in memories {
            let facts = try await memory.facts(scope: .agent)
            XCTAssertEqual(facts.count, 400)
        }

        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<50 {
            for memory in memories {
                let facts = try await memory.facts(scope: .agent)
                XCTAssertEqual(facts.count, 400)
            }
        }
        for _ in 0..<50 {
            for memory in memories {
                let hits = try await memory.recall("", limit: 40, now: 2_000_000_000_000)
                XCTAssertEqual(hits.count, 40)
            }
        }
        let elapsed = start.duration(to: clock.now)

        for store in stores {
            let diagnostics = await store.replayDiagnostics
            XCTAssertEqual(diagnostics.fullReplayCount, 1,
                           "the shared feed must scan the log from commit 0 exactly once")
            XCTAssertEqual(diagnostics.scannedEventCount, eventCount)
            XCTAssertEqual(diagnostics.processedMemoryEventCount, eventCount,
                           "reads must not process memory events again")
            XCTAssertEqual(diagnostics.lastProcessedCommitSeq, eventCount)
            XCTAssertTrue(diagnostics.skippedEventIDs.isEmpty)
        }
        // Generous ceiling: 250 facts() and 250 recall() calls over 5×425
        // facts. This catches an accidental per-call full replay; it does not
        // assert machine speed.
        XCTAssertLessThan(elapsed, .seconds(60), "repeated reads took \(elapsed)")

        // A new write is read incrementally, not by replaying the whole log.
        let beforeLateWrite = await stores[0].replayDiagnostics
        try await stores[0].append(makeMemoryFact(
            "fact-late", "late 咖啡", learnedAtMS: 9_000))
        for memory in memories { _ = try await memory.facts(scope: .agent) }
        for store in stores {
            let diagnostics = await store.replayDiagnostics
            XCTAssertEqual(diagnostics.fullReplayCount, 1)
            XCTAssertEqual(diagnostics.processedMemoryEventCount, eventCount + 1)
        }
        let afterLateWrite = await stores[0].replayDiagnostics
        XCTAssertEqual(afterLateWrite.incrementalReplayCount,
                       beforeLateWrite.incrementalReplayCount + 1)
        print("bm-memory performance: 250 facts + 250 recall calls over \(eventCount) events in \(elapsed)")
        try await domain.close()
    }
}
