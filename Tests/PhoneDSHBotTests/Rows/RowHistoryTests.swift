// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class RowHistoryTests: XCTestCase {
    func testCacheRebuildIsIdenticalAndTombstoneDoesNotResurrect() async throws {
        let user = RowTestSupport.dshText(seq: 1, time: 1_000, role: "user", text: "你好")
        let assistant = RowTestSupport.dshText(seq: 2, time: 2_000, role: "assistant", text: "可见回复")
        let turnStart = BotDSHSessionEvent(type: "turn/start", seq: 3, time: 3_000,
                                           data: ["turn": .number(2)])
        let hidden = RowTestSupport.dshText(seq: 4, time: 4_000, role: "user",
                                            text: "[SAND_HIDDEN_PROMPT] wake", turn: 2)
        let hiddenAssistant = RowTestSupport.dshText(seq: 5, time: 5_000, role: "assistant",
                                                     text: "隐藏散文", turn: 2)
        let progress1 = RowTestSupport.progress(id: "evt-progress-1", commitSeq: 1, time: 6_000, percent: 50)
        let progress2 = RowTestSupport.progress(id: "evt-progress-2", commitSeq: 2, time: 7_000, percent: 100)
        let deletion = RowTestSupport.uiEvent(type: "transcript.row_deleted", id: "evt-delete", commitSeq: 3,
                                              time: 8_000, data: ["rowID": .string(assistant.idDescription)])
        let sessionEvents = [user, assistant, turnStart, hidden, hiddenAssistant]
        let uiEvents = [progress1, progress2, deletion]
        let projector = BotSessionLogProjector()

        let first = projector.project(botID: "main", sessionID: "main",
                                      sessionEvents: sessionEvents, uiEvents: uiEvents)
        let rebuilt = projector.project(botID: "main", sessionID: "main",
                                        sessionEvents: sessionEvents, uiEvents: uiEvents)
        XCTAssertEqual(first, rebuilt)
        XCTAssertEqual(first.rows.map(\.id), [user.idDescription, "e-ui-evt-progress-1"])
        XCTAssertEqual(first.tombstones.map(\.id), [assistant.idDescription])
        XCTAssertFalse(first.rows.contains { $0.body["text"] == .string("隐藏散文") })
        XCTAssertFalse(first.rows.contains { $0.body["text"] == .string("[SAND_HIDDEN_PROMPT] wake") })

        let progress = try XCTUnwrap(first.rows.first { $0.body.cardType == .progress })
        XCTAssertEqual(progress.body["percent"], .number(100))
        XCTAssertEqual(progress.provenance.eventIDs, ["evt-progress-1", "evt-progress-2"])
        XCTAssertTrue(BotDisplayContract.project(progress).renderable)
        XCTAssertGreaterThan(progress.updatedSeq, first.rows[0].updatedSeq)

        let liveCache = BotRowHistory(snapshot: first)
        let rebuiltCache = BotRowHistory(snapshot: rebuilt)
        let liveRows = await liveCache.history()
        let rebuiltRows = await rebuiltCache.history()
        let liveTombstones = await liveCache.tombstones()
        let rebuiltTombstones = await rebuiltCache.tombstones()
        let liveBatch = await liveCache.watch(after: 0)
        let rebuiltBatch = await rebuiltCache.watch(after: 0)
        XCTAssertEqual(liveRows, rebuiltRows)
        XCTAssertEqual(liveTombstones, rebuiltTombstones)
        XCTAssertEqual(liveBatch, rebuiltBatch)

        let replayWithLateDuplicate = projector.project(botID: "main", sessionID: "main",
                                                        sessionEvents: sessionEvents + [assistant], uiEvents: uiEvents)
        XCTAssertEqual(replayWithLateDuplicate.rows, first.rows)
        XCTAssertEqual(replayWithLateDuplicate.tombstones.map(\.id), first.tombstones.map(\.id))
    }

    func testReconnectWatchConvergesWithUninterruptedProjection() async throws {
        let user = RowTestSupport.dshText(seq: 1, time: 1_000, role: "user", text: "开始")
        let progress1 = RowTestSupport.progress(id: "evt-progress-1", commitSeq: 1, time: 2_000, percent: 25)
        let assistant = RowTestSupport.dshText(seq: 2, time: 3_000, role: "assistant", text: "中间结果")
        let progress2 = RowTestSupport.progress(id: "evt-progress-2", commitSeq: 2, time: 4_000, percent: 100)
        let deletion = RowTestSupport.uiEvent(type: "transcript.row_deleted", id: "evt-delete", commitSeq: 3,
                                              time: 5_000, data: ["rowID": .string(assistant.idDescription)])
        let initialSession = [user]
        let initialUI = [progress1]
        let allSession = initialSession + [assistant]
        let allUI = initialUI + [progress2, deletion]
        let projector = BotSessionLogProjector()
        let uninterrupted = projector.project(botID: "main", sessionID: "main",
                                              sessionEvents: allSession, uiEvents: allUI)

        let reconnected = BotRowHistory()
        _ = try await reconnected.rebuild(botID: "main", sessionID: "main",
                                          sessionEvents: initialSession, uiEvents: initialUI)
        let initial = await reconnected.watch(after: 0)
        XCTAssertTrue(initial.reset)
        let reset = try await reconnected.rebuild(botID: "main", sessionID: "main",
                                                  sessionEvents: allSession, uiEvents: allUI)
        let delta = await reconnected.watch(after: initial.cursor)
        XCTAssertFalse(delta.reset)
        XCTAssertEqual(delta.cursor, reset.cursor)
        XCTAssertGreaterThan(delta.cursor, initial.cursor)
        XCTAssertEqual(delta.rows.map(\.id), ["e-ui-evt-progress-1"])
        XCTAssertEqual(delta.deletes, [assistant.idDescription])

        var merged = Dictionary(uniqueKeysWithValues: initial.rows.map { ($0.id, $0) })
        for id in delta.deletes { merged.removeValue(forKey: id) }
        for row in delta.rows { merged[row.id] = row }
        let mergedRows = RowTestSupport.sorted(Array(merged.values))
        XCTAssertEqual(mergedRows.map { $0.replacing(updatedSeq: 0) },
                       uninterrupted.rows.map { $0.replacing(updatedSeq: 0) })
        XCTAssertEqual(reset.rows, mergedRows)

        let noFurtherChanges = await reconnected.watch(after: delta.cursor)
        XCTAssertEqual(noFurtherChanges, BotRowBatch(rows: [], deletes: [], cursor: delta.cursor, reset: false))
    }

    func testLateSourceAppendsChangeAndSecondRebuildIsStable() async throws {
        let first = RowTestSupport.dshText(seq: 1, time: 2_000, role: "user", text: "后发生")
        let late = RowTestSupport.dshText(seq: 2, time: 1_000, role: "assistant", text: "迟到")
        let history = BotRowHistory()
        _ = try await history.rebuild(botID: "main", sessionID: "main", sessionEvents: [first], uiEvents: [])
        let initialCursor = await history.cursor()
        let initialRows = await history.history()
        let initialFirst = try XCTUnwrap(initialRows.first)

        let reset = try await history.rebuild(botID: "main", sessionID: "main",
                                              sessionEvents: [first, late], uiEvents: [])
        XCTAssertTrue(reset.reset)
        XCTAssertEqual(reset.cursor, initialCursor + 1)
        XCTAssertEqual(reset.rows.map(\.id), ["e-main-2", "e-main-1"])
        XCTAssertEqual(reset.rows.last?.updatedSeq, initialFirst.updatedSeq)
        let delta = await history.watch(after: initialCursor)
        XCTAssertFalse(delta.reset)
        XCTAssertEqual(delta.cursor, reset.cursor)
        XCTAssertEqual(delta.rows.map(\.id), ["e-main-2"])
        XCTAssertEqual(delta.rows.first?.updatedSeq, initialCursor + 1)

        let secondReset = try await history.rebuild(botID: "main", sessionID: "main",
                                                    sessionEvents: [first, late], uiEvents: [])
        let repeatedDelta = await history.watch(after: initialCursor)
        XCTAssertEqual(secondReset, reset)
        XCTAssertEqual(repeatedDelta, delta)
    }

    func testJSONLUsesRealSessionEventDecoder() throws {
        let events = [RowTestSupport.dshText(seq: 7, time: 42, role: "user", text: "日志")]
        let line = try JSONEncoder().encode(events[0])
        let decoded = try BotDSHSessionEvent.parseJSONL(line + Data([0x0A]))
        XCTAssertEqual(decoded, events)
        let snapshot = BotSessionLogProjector().project(botID: "main", sessionID: "main",
                                                        sessionEvents: decoded, uiEvents: [])
        XCTAssertEqual(snapshot.rows.map(\.id), ["e-main-7"])
    }
}

private extension BotDSHSessionEvent {
    var idDescription: String { "e-main-\(seq)" }
}
