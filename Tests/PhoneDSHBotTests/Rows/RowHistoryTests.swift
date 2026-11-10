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
                                            text: "[SAND_HIDDEN_PROMPT] wake", turn: 2,
                                            sourceKind: "user", rpcId: "routine:run-row-history")
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

    func testProjectionPreservesActionNonceOnlyInMemory() throws {
        let line = #"{"type":"user/message","seq":26,"time":42,"surfaceOp":"append","data":{"role":"user","content":[{"type":"text","text":"测试"}],"source":{"kind":"user","rpcId":"user-action:nonce-26"}}}"#
        let events = BotDSHSessionEvent.parseJSONL(Data(line.utf8)).events
        let rows = BotSessionLogProjector().project(
            botID: "main", sessionID: "gb-main", sessionEvents: events, uiEvents: []).rows
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.chatActionNonce, "nonce-26")
        XCTAssertEqual(row.replacing(updatedSeq: 99).chatActionNonce, "nonce-26")
        let encoded = try JSONEncoder().encode(row)
        XCTAssertNil(try JSONDecoder().decode(BotRow.self, from: encoded).chatActionNonce)
    }

    func testJSONLUsesRealSessionEventDecoder() throws {
        let events = [RowTestSupport.dshText(seq: 7, time: 42, role: "user", text: "日志")]
        let line = try JSONEncoder().encode(events[0])
        let header = Data(#"{"type":"session","version":4,"id":"main","createdAt":40,"cwd":"/dsh/workspace","isSeeded":false,"delegationDepth":0}"#.utf8)
        let newline = Data([0x0A])
        let decoded = BotDSHSessionEvent.parseJSONL(header + newline + line + newline)
        XCTAssertEqual(decoded.events, events)
        XCTAssertEqual(decoded.diagnostics, .empty)
        XCTAssertEqual(BotDSHSessionEvent.parseJSONL(line + newline).events, events)
        // The header is only skipped as the first record; later it is a
        // malformed event and is reported instead of failing the whole log.
        let misplacedHeader = BotDSHSessionEvent.parseJSONL(line + newline + header)
        XCTAssertEqual(misplacedHeader.events, events)
        XCTAssertEqual(misplacedHeader.diagnostics.skippedRecordCount, 1)
        let missingSequence = Data(#"{"type":"user/message","time":42,"data":{}}"#.utf8)
        let skipped = BotDSHSessionEvent.parseJSONL(header + newline + missingSequence)
        XCTAssertTrue(skipped.events.isEmpty)
        XCTAssertEqual(skipped.diagnostics.skippedRecordCount, 1)
        XCTAssertEqual(skipped.diagnostics.skipped.first?.lineNumber, 2)
        XCTAssertNil(skipped.diagnostics.skipped.first?.seq)
        let snapshot = BotSessionLogProjector().project(botID: "main", sessionID: "main",
                                                        sessionEvents: decoded.events, uiEvents: [])
        XCTAssertEqual(snapshot.rows.map(\.id), ["e-main-7"])
    }

    func testReplacementSurfaceOpObjectParsesAndRebuildsRows() async throws {
        // The real post-restart system-prompt replacement uses the canonical
        // v4 object form. Before the decoder accepted it, this single record
        // made `parseJSONL` throw and the whole history rebuild fail.
        let header = Data(#"{"type":"session","version":4,"id":"gb-main","createdAt":40,"cwd":"/dsh/workspace","isSeeded":false,"delegationDepth":0}"#.utf8)
        let records = [
            #"{"type":"system/message","seq":8,"time":41,"surfaceOp":"append","data":{"message":{"role":"system","content":[{"type":"text","text":"旧提示"}]}}}"#,
            #"{"type":"system/message","seq":9,"time":42,"surfaceOp":{"op":"replace","startSeq":8,"endSeq":8},"data":{"message":{"role":"system","content":[{"type":"text","text":"新提示"}]}}}"#,
            #"{"type":"user/message","seq":10,"time":43,"surfaceOp":"append","data":{"role":"user","content":[{"type":"text","text":"重启后仍要显示"}],"source":{"kind":"user","rpcId":"user-action:nonce-10"}}}"#,
            #"{"type":"assistant/message","seq":11,"time":44,"surfaceOp":"append","data":{"message":{"role":"assistant","content":[{"type":"text","text":"已恢复"}]}}}"#,
        ]
        let log = ([header] + records.map { Data($0.utf8) })
            .reduce(into: Data()) { data, record in
                data.append(record)
                data.append(0x0A)
            }
        let parsed = BotDSHSessionEvent.parseJSONL(log)
        XCTAssertEqual(parsed.diagnostics, .empty)
        XCTAssertEqual(parsed.events.count, 4)
        let replacement = parsed.events[1]
        XCTAssertEqual(replacement.surfaceOp, .replace(startSeq: 8, endSeq: 8))
        XCTAssertEqual(replacement.surfaceOp?.op, "replace")
        XCTAssertEqual(replacement.surfaceOp?.range, 8...8)

        let history = BotRowHistory()
        let batch = try await history.rebuild(
            botID: "main", sessionID: "gb-main", sessionEvents: parsed.events, uiEvents: [])
        XCTAssertEqual(batch.rows.map(\.id), ["e-gb-main-10", "e-gb-main-11"])
        XCTAssertEqual(batch.rows.compactMap { $0.body["text"]?.stringValue },
                       ["重启后仍要显示", "已恢复"])
    }

    func testDamagedRecordIsSkippedWithDiagnosticsAndRebuildContinues() async throws {
        let header = Data(#"{"type":"session","version":4,"id":"gb-main","createdAt":40,"isSeeded":false,"delegationDepth":0}"#.utf8)
        let records = [
            Data(#"{"type":"user/message","seq":2,"time":2,"surfaceOp":"append","data":{"role":"user","content":[{"type":"text","text":"第一条"}]}}"#.utf8),
            Data(#"{"type":"assistant/message","seq":3,"time":3,"data":{"message":{"role":"assistant","content":[{"type":"text","text":"坏"}"#.utf8),
            Data(#"{"type":"user/message","seq":7,"time":7}"#.utf8),
            Data(#"{"type":"assistant/message","seq":4,"time":4,"surfaceOp":"append","data":{"message":{"role":"assistant","content":[{"type":"text","text":"第三条"}]}}}"#.utf8),
        ]
        let newline = Data([0x0A])
        let log = ([header] + records).reduce(into: Data()) { data, record in
            data.append(record)
            data.append(newline)
        }
        let parsed = BotDSHSessionEvent.parseJSONL(log)
        XCTAssertEqual(parsed.events.map(\.seq), [2, 4])
        XCTAssertEqual(parsed.diagnostics.skippedRecordCount, 2)
        XCTAssertEqual(parsed.diagnostics.skipped.map(\.lineNumber), [3, 4])
        // The broken JSON line has no readable seq; the semantically invalid
        // record still exposes seq 7 for diagnostics.
        XCTAssertEqual(parsed.diagnostics.skippedSeqs, [7])

        let history = BotRowHistory()
        let batch = try await history.rebuild(
            botID: "main", sessionID: "gb-main", sessionEvents: parsed.events, uiEvents: [])
        XCTAssertEqual(batch.rows.map(\.id), ["e-gb-main-2", "e-gb-main-4"])
        XCTAssertEqual(batch.rows.compactMap { $0.body["text"]?.stringValue }, ["第一条", "第三条"])
    }
}

private extension BotDSHSessionEvent {
    var idDescription: String { "e-main-\(seq)" }
}
