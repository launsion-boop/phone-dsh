// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class RowRecoveryTests: XCTestCase {
    func testMixedOutOfOrderReconnectAndCacheRebuildConverge() async throws {
        let user = RowTestSupport.dshText(seq: 1, time: 3_000, role: "user", text: "已有用户行")
        let existing = RowTestSupport.dshText(seq: 4, time: 4_000, role: "assistant", text: "已有回复")
        let lateUser = RowTestSupport.dshText(seq: 2, time: 1_000, role: "user", text: "迟到用户行")
        let lateDeleted = RowTestSupport.dshText(seq: 3, time: 2_000, role: "assistant", text: "迟到且删除")
        let progress1 = RowTestSupport.progress(id: "evt-progress-1", commitSeq: 4, time: 5_000, percent: 25)
        let progress2 = RowTestSupport.progress(id: "evt-progress-2", commitSeq: 5, time: 1_500, percent: 100)
        let deletion = RowTestSupport.uiEvent(type: "transcript.row_deleted", id: "evt-delete", commitSeq: 6,
                                              time: 500, data: ["rowID": .string("e-main-3")])
        let initialSession = [user, existing]
        let initialUI = [progress1]
        let allSession = initialSession + [lateUser, lateDeleted]
        let allUI = initialUI + [progress2, deletion]
        let history = BotRowHistory()
        _ = try await history.rebuild(botID: "main", sessionID: "main",
                                      sessionEvents: initialSession, uiEvents: initialUI)
        let initial = await history.watch(after: 0)
        let initialRows = Dictionary(uniqueKeysWithValues: initial.rows.map { ($0.id, $0) })

        let reset = try await history.rebuild(botID: "main", sessionID: "main",
                                              sessionEvents: allSession, uiEvents: allUI)
        let delta = await history.watch(after: initial.cursor)
        XCTAssertTrue(reset.reset)
        XCTAssertFalse(delta.reset)
        XCTAssertEqual(reset.cursor, delta.cursor)
        XCTAssertEqual(reset.rows.map(\.id), ["e-main-2", "e-main-1", "e-main-4", "e-ui-evt-progress-1"])
        XCTAssertEqual(reset.deletes, ["e-main-3"])
        XCTAssertEqual(delta.deletes, ["e-main-3"])
        XCTAssertEqual(Set(delta.rows.map(\.id)), Set(["e-main-2", "e-ui-evt-progress-1"]))
        XCTAssertTrue(delta.rows.allSatisfy { $0.updatedSeq > initial.cursor })
        for id in ["e-main-1", "e-main-4"] {
            XCTAssertEqual(reset.rows.first { $0.id == id }?.updatedSeq, initialRows[id]?.updatedSeq)
        }
        let initialProgress = try XCTUnwrap(initialRows["e-ui-evt-progress-1"])
        let finalProgress = try XCTUnwrap(reset.rows.first { $0.body.cardType == .progress })
        XCTAssertEqual(finalProgress.id, initialProgress.id)
        XCTAssertEqual(finalProgress.body["percent"], .number(100))
        XCTAssertEqual(finalProgress.createdAt, initialProgress.createdAt)
        XCTAssertGreaterThan(finalProgress.updatedSeq, initialProgress.updatedSeq)
        XCTAssertEqual(finalProgress.provenance.eventIDs, ["evt-progress-1", "evt-progress-2"])

        let merged = applying(delta, to: initial.rows)
        XCTAssertEqual(merged, reset.rows)
        let afterZero = await history.watch(after: 0)
        XCTAssertEqual(afterZero, reset)
        let noFurtherChanges = await history.watch(after: reset.cursor)
        XCTAssertEqual(noFurtherChanges, BotRowBatch(rows: [], deletes: [], cursor: reset.cursor, reset: false))

        let cold = BotSessionLogProjector().project(botID: "main", sessionID: "main",
                                                    sessionEvents: allSession, uiEvents: allUI)
        let liveTombstones = await history.tombstones()
        XCTAssertEqual(clearingUpdatedSeq(cold.rows), clearingUpdatedSeq(reset.rows))
        XCTAssertEqual(clearingUpdatedSeq(cold.tombstones), clearingUpdatedSeq(liveTombstones))
        let resetOnlyCache = BotRowProjectionSnapshot(rows: cold.rows, tombstones: cold.tombstones,
                                                      cursor: 0, changes: [])
        try await history.replaceWithRebuiltCache(resetOnlyCache)
        let cacheCursor = await history.cursor()
        let cacheReset = await history.watch(after: 0)
        let cacheDelta = await history.watch(after: initial.cursor)
        XCTAssertEqual(cacheCursor, reset.cursor)
        XCTAssertEqual(cacheReset, reset)
        XCTAssertEqual(cacheDelta, delta)

        try await history.replaceWithRebuiltCache(resetOnlyCache)
        let secondCacheReset = await history.watch(after: 0)
        let secondCacheDelta = await history.watch(after: initial.cursor)
        XCTAssertEqual(secondCacheReset, reset)
        XCTAssertEqual(secondCacheDelta, delta)
        let futureCursor = await history.watch(after: reset.cursor + 100)
        XCTAssertTrue(futureCursor.reset)
        XCTAssertEqual(futureCursor, reset)
    }

    func testLateDeleteIsAppendedAndNeverResurrectsRow() async throws {
        let assistant = RowTestSupport.dshText(seq: 9, time: 1_000, role: "assistant", text: "待删除")
        let deletion = RowTestSupport.uiEvent(type: "transcript.row_deleted", id: "evt-delete-9", commitSeq: 2,
                                              time: 100, data: ["rowID": .string("e-main-9")])
        let history = BotRowHistory()
        _ = try await history.rebuild(botID: "main", sessionID: "main", sessionEvents: [assistant], uiEvents: [])
        let initialCursor = await history.cursor()

        let reset = try await history.rebuild(botID: "main", sessionID: "main",
                                              sessionEvents: [assistant], uiEvents: [deletion])
        XCTAssertTrue(reset.reset)
        XCTAssertEqual(reset.cursor, initialCursor + 1)
        XCTAssertTrue(reset.rows.isEmpty)
        XCTAssertEqual(reset.deletes, ["e-main-9"])
        let delta = await history.watch(after: initialCursor)
        XCTAssertFalse(delta.reset)
        XCTAssertEqual(delta.deletes, ["e-main-9"])
        XCTAssertEqual(delta.cursor, reset.cursor)

        var changedLateDuplicate = RowTestSupport.dshText(seq: 9, time: 2_000, role: "assistant", text: "不得复活")
        changedLateDuplicate.eventID = "evt-late-duplicate"
        let repeatedReset = try await history.rebuild(botID: "main", sessionID: "main",
                                                      sessionEvents: [assistant, changedLateDuplicate],
                                                      uiEvents: [deletion, deletion])
        let repeatedDelta = await history.watch(after: initialCursor)
        let tombstones = await history.tombstones()
        XCTAssertEqual(repeatedReset, reset)
        XCTAssertEqual(repeatedDelta, delta)
        XCTAssertEqual(tombstones.map(\.id), ["e-main-9"])
    }

    func testLateProgressUsesSourceOrderAndKeepsCardKeyIdentity() async throws {
        let first = RowTestSupport.progress(id: "evt-progress-first", commitSeq: 1, time: 5_000, percent: 10)
        let late = RowTestSupport.progress(id: "evt-progress-late", commitSeq: 2, time: 1_000, percent: 100)
        let history = BotRowHistory()
        _ = try await history.rebuild(botID: "main", sessionID: "main", sessionEvents: [], uiEvents: [first])
        let initial = await history.watch(after: 0)
        let initialRow = try XCTUnwrap(initial.rows.first)

        let reset = try await history.rebuild(botID: "main", sessionID: "main",
                                              sessionEvents: [], uiEvents: [first, late])
        let finalRow = try XCTUnwrap(reset.rows.first)
        XCTAssertEqual(reset.rows.count, 1)
        XCTAssertEqual(finalRow.id, initialRow.id)
        XCTAssertEqual(finalRow.body.cardKey, initialRow.body.cardKey)
        XCTAssertEqual(finalRow.body["percent"], .number(100))
        XCTAssertEqual(finalRow.body["state"], .string("done"))
        XCTAssertEqual(finalRow.createdAt, initialRow.createdAt)
        XCTAssertEqual(finalRow.updatedSeq, initial.cursor + 1)
        let delta = await history.watch(after: initial.cursor)
        XCTAssertEqual(delta.rows, [finalRow])
        XCTAssertEqual(delta.cursor, finalRow.updatedSeq)

        let repeated = try await history.rebuild(botID: "main", sessionID: "main",
                                                 sessionEvents: [], uiEvents: [first, late])
        XCTAssertEqual(repeated, reset)
    }

    func testDuplicateEventIDIsIgnoredForDSHAndUI() async throws {
        var dsh = RowTestSupport.dshText(seq: 1, time: 1_000, role: "user", text: "只出现一次")
        dsh.eventID = "evt-duplicate-dsh"
        var duplicateDSH = RowTestSupport.dshText(seq: 2, time: 2_000, role: "user", text: "必须忽略")
        duplicateDSH.eventID = dsh.eventID
        let notice = RowTestSupport.uiEvent(type: "ui.notice", id: "evt-duplicate-ui", commitSeq: 3, time: 3_000,
                                            data: ["tone": .string("error"), "text": .string("一次通知")])
        let duplicateNotice = RowTestSupport.uiEvent(type: "ui.notice", id: "evt-duplicate-ui", commitSeq: 4, time: 4_000,
                                                     data: ["tone": .string("error"), "text": .string("不得覆盖")])
        let history = BotRowHistory()
        let reset = try await history.rebuild(botID: "main", sessionID: "main",
                                              sessionEvents: [dsh, duplicateDSH], uiEvents: [notice, duplicateNotice])
        XCTAssertEqual(reset.rows.map(\.id), ["e-main-1", "e-ui-evt-duplicate-ui"])
        XCTAssertEqual(reset.rows.map { $0.body["text"] }, [.string("只出现一次"), .string("一次通知")])
        XCTAssertEqual(reset.rows.map(\.provenance.eventIDs), [["evt-duplicate-dsh"], ["evt-duplicate-ui"]])
        XCTAssertEqual(reset.cursor, 2)
        let emptyDelta = await history.watch(after: reset.cursor)
        XCTAssertEqual(emptyDelta, BotRowBatch(rows: [], deletes: [], cursor: reset.cursor, reset: false))

        let repeated = try await history.rebuild(botID: "main", sessionID: "main",
                                                 sessionEvents: [dsh, duplicateDSH], uiEvents: [notice, duplicateNotice])
        XCTAssertEqual(repeated, reset)
    }
}

private func applying(_ batch: BotRowBatch, to rows: [BotRow]) -> [BotRow] {
    var merged = batch.reset ? [:] : Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    for id in batch.deletes { merged.removeValue(forKey: id) }
    for row in batch.rows { merged[row.id] = row }
    return RowTestSupport.sorted(Array(merged.values))
}

private func clearingUpdatedSeq(_ rows: [BotRow]) -> [BotRow] {
    rows.map { $0.replacing(updatedSeq: 0) }
}
