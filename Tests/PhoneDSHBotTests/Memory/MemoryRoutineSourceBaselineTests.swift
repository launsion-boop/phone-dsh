// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// Routine-run writes have no `current-user-turn`. The durable routine
/// definition is the basis of the standing instruction and the run-start event
/// is the trigger; neither is content evidence. P accepts those roles and
/// persists them without inventing evidence or trust.
final class MemoryRoutineSourceBaselineTests: XCTestCase {
    private var store: SQLiteDomainStore!
    private var root: URL!

    override func setUp() async throws {
        (store, root) = try makeMemoryTestStore()
    }

    override func tearDown() async throws {
        try? await store?.close()
        cleanupMemoryTestStore(root)
    }

    func testRoutineBasisAndTriggerArePersistedWithoutEvidence() async throws {
        let definitionSeq = try await store.append(BotEvent(
            type: "routine.defined", eventId: "routine-defined:test", time: 1_000,
            origin: .local(source: "mcp"), traceId: "trace-routine-defined",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-routine", kind: "routine"),
            causationId: nil, correlationId: "routine-1",
            data: .object([
                "id": .string("routine-1"), "title": .string("每日整理"),
                "prompt": .string("整理今天的笔记"),
            ])))
        let startSeq = try await store.append(BotEvent(
            type: "routine.run_started", eventId: "routine-started:test", time: 1_001,
            origin: .local(source: "scheduler"), traceId: "trace-routine-started",
            principal: BotPrincipal(botId: "bot-a", sessionId: "gb-routine", kind: "routine"),
            causationId: nil, correlationId: "routine-1",
            data: .object([
                "runId": .string("run-1"), "routineId": .string("routine-1"),
                "attempt": .number(1),
            ])))
        let definitionRef = "record://event/\(definitionSeq)"
        let startRef = "record://event/\(startSeq)"
        let memory = makeMemory(store: store, botID: "bot-a")
        let result = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: "agent/inbox/gb-routine/daily.md",
                content: "# 每日整理\n- 先收集今天的笔记",
                expectedVersion: 0, evidence: [],
                sourceBaselines: [
                    BotSourceBaseline(record: startRef, role: .trigger, sourceVersion: nil),
                    BotSourceBaseline(record: definitionRef, role: .basis, sourceVersion: nil),
                ]),
            context: BotMemoryWriteContext(
                botID: "bot-a", sessionID: "gb-routine", authorKind: .routine,
                source: BotMemorySource(kind: .routine, sessionID: "gb-routine"),
                trust: .assistant, isMainBot: false))
        XCTAssertTrue(result.ok, "\(String(describing: result.code))")

        let events = try await store.events(after: 0, limit: 50)
        let written = try XCTUnwrap(events.first {
            $0.type == "memory.document_written"
                && $0.data["path"]?.stringValue == "agent/inbox/gb-routine/daily.md"
        })
        XCTAssertEqual(written.data["evidence"]?.arrayValue?.compactMap(\.stringValue), [],
                       "routine trigger/basis are roles, not content evidence")
        XCTAssertEqual(written.data["trust"]?.stringValue, "assistant")
        let sources = try XCTUnwrap(written.data["derivation"]?["sources"]?.arrayValue)
        XCTAssertEqual(sources.compactMap { $0["role"]?.stringValue }, ["trigger", "basis"])
        XCTAssertEqual(sources.compactMap { $0["record"]?.stringValue },
                       [startRef, definitionRef])
        XCTAssertTrue(sources.allSatisfy { $0["sourceVersion"] == nil })
    }

    func testRoutineWithoutAnyRealSourceStillHasNoDerivation() async throws {
        let memory = makeMemory(store: store, botID: "bot-a")
        let result = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: "agent/inbox/gb-routine/unsourced.md",
                content: "# unsourced", expectedVersion: 0),
            context: BotMemoryWriteContext(
                botID: "bot-a", sessionID: "gb-routine", authorKind: .routine,
                source: BotMemorySource(kind: .routine, sessionID: "gb-routine"),
                trust: .assistant, isMainBot: false))
        XCTAssertTrue(result.ok)
        let events = try await store.events(after: 0, limit: 50)
        let written = try XCTUnwrap(events.first {
            $0.type == "memory.document_written"
                && $0.data["path"]?.stringValue == "agent/inbox/gb-routine/unsourced.md"
        })
        XCTAssertNil(written.data["derivation"],
                     "no real source means unknown, not a fabricated ref")
        XCTAssertEqual(written.data["evidence"]?.arrayValue?.compactMap(\.stringValue), [])
    }
}
