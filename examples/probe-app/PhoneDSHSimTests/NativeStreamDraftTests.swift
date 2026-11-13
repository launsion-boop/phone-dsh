// SPDX-License-Identifier: MIT
// Interrupted-stream draft: persistence, reload policy and cache lifecycle.
//
// DSH keeps unfinished assistant streams transient and repairs an abandoned
// turn with `turn/end{kind:'interrupted'}`. The App's draft is display-only; it
// must survive repeated kills and reloads, stay visible until durable text
// replaces it, and never reach the model.

import Foundation
import ProbeKit
import XCTest

final class NativeStreamDraftStoreTests: XCTestCase {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
    }

    private var directory: URL!
    private var clock: Clock!
    private var store: NativeStreamDraftStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-stream-draft-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clock = Clock()
        self.clock = clock
        store = NativeStreamDraftStore(documentsDirectory: directory,
                                       writeInterval: 1,
                                       now: { clock.now })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        store = nil
        clock = nil
        directory = nil
        super.tearDown()
    }

    private let sessionID = "session-draft-1"

    private func row(_ text: String,
                     id: String = "session-draft-1:10:part-0",
                     kind: NativeStreamDraftKind = .assistant,
                     turn: Int? = 1) -> NativeStreamDraftItem {
        NativeStreamDraftItem(itemID: id, kind: kind, turn: turn, step: nil, text: text)
    }

    private func draftURL() throws -> URL {
        try XCTUnwrap(WorkspaceStorage.streamDraftURL(for: .phone,
                                                      sessionID: sessionID,
                                                      documentsDirectory: directory))
    }

    private func load() throws -> NativeStreamDraftFile? {
        store.load(backend: .phone, sessionID: sessionID)
    }

    func testDraftWrittenWhileStreamingRespectsTheOneSecondThrottle() throws {
        store.submit(rows: [row("Hel")], backend: .phone, sessionID: sessionID)
        store.waitForIdle()
        XCTAssertEqual(try load()?.items.map(\.text), ["Hel"])
        XCTAssertEqual(store.stats().writes, 1)

        clock.now = clock.now.addingTimeInterval(0.2)
        store.submit(rows: [row("Hello")], backend: .phone, sessionID: sessionID)
        store.waitForIdle()
        XCTAssertEqual(try load()?.items.map(\.text), ["Hel"],
                       "a second write inside the throttle window must not land")
        XCTAssertEqual(store.stats().writes, 1)

        clock.now = clock.now.addingTimeInterval(1.1)
        store.submit(rows: [row("Hello world")], backend: .phone, sessionID: sessionID)
        store.waitForIdle()
        XCTAssertEqual(try load()?.items.map(\.text), ["Hello world"])
        XCTAssertEqual(store.stats().writes, 2)
    }

    func testBackgroundFlushBypassesTheThrottle() throws {
        store.submit(rows: [row("first")], backend: .phone, sessionID: sessionID)
        store.waitForIdle()

        clock.now = clock.now.addingTimeInterval(0.1)
        store.submit(rows: [row("first, second")], backend: .phone, sessionID: sessionID)
        store.waitForIdle()
        XCTAssertEqual(try load()?.items.map(\.text), ["first"])

        // ChatModel calls this on `.inactive` / `.background`; the write itself
        // is queued and never runs on the main actor.
        store.submit(rows: [row("first, second, third")], backend: .phone,
                     sessionID: sessionID, flushNow: true)
        store.waitForIdle()
        XCTAssertEqual(try load()?.items.map(\.text), ["first, second, third"])
        XCTAssertEqual(store.stats().writes, 2)
    }

    func testNormalSettleDeletesTheDraftFile() throws {
        store.submit(rows: [row("partial")], backend: .phone, sessionID: sessionID)
        store.waitForIdle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: try draftURL().path))

        // `.assistantMessage` / a normal turn end submits the now-empty tracker.
        store.submit(rows: [], backend: .phone, sessionID: sessionID, flushNow: true)
        store.waitForIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try draftURL().path))
        XCTAssertNil(try load())
    }

    func testFirstDraftOfTheNextTurnWritesImmediatelyAfterASettle() throws {
        store.submit(rows: [row("turn one")], backend: .phone, sessionID: sessionID)
        store.waitForIdle()
        store.submit(rows: [], backend: .phone, sessionID: sessionID, flushNow: true)
        store.waitForIdle()
        XCTAssertNil(try load())

        // Same clock: a normal settle must not throttle the next turn's first
        // partial text behind the previous write.
        store.submit(rows: [row("turn two")], backend: .phone, sessionID: sessionID)
        store.waitForIdle()
        XCTAssertEqual(try load()?.items.map(\.text), ["turn two"])
        XCTAssertEqual(store.stats().writes, 2)
    }

    func testConsumeRemovesOnlyTheHandledRows() throws {
        store.submit(rows: [row("assistant", id: "session-draft-1:10:part-0"),
                            row("reasoning", id: "session-draft-1:9:part-0",
                                 kind: .reasoning)],
                     backend: .phone, sessionID: sessionID)
        store.waitForIdle()

        store.consume(backend: .phone, sessionID: sessionID,
                      itemIDs: ["session-draft-1:10:part-0"])
        store.waitForIdle()
        XCTAssertEqual(try load()?.items.map(\.itemID), ["session-draft-1:9:part-0"])
        XCTAssertEqual(store.stats().consumed, 1)

        store.consume(backend: .phone, sessionID: sessionID,
                      itemIDs: ["session-draft-1:9:part-0"])
        store.waitForIdle()
        XCTAssertNil(try load())
    }

    func testDeleteDropsQueuedTextAndTheFile() throws {
        store.submit(rows: [row("live")], backend: .phone, sessionID: sessionID)
        store.waitForIdle()
        store.delete(backend: .phone, sessionID: sessionID)
        store.waitForIdle()
        XCTAssertNil(try load())
    }
}

final class NativeStreamDraftPolicyTests: XCTestCase {
    private let sessionID = "session-draft-2"

    private func historyItem(_ id: String,
                             _ kind: ChatItem.Kind,
                             text: String,
                             turn: Int?) -> ChatItem {
        var item = ChatItem(id: id, kind: kind, title: "row", text: text)
        item.turn = turn
        return item
    }

    private func draft(_ id: String = "session-draft-2:10:part-0",
                       kind: NativeStreamDraftKind = .assistant,
                       turn: Int? = 2,
                       text: String = "partial answer") -> NativeStreamDraftItem {
        NativeStreamDraftItem(itemID: id, kind: kind, turn: turn, step: nil, text: text)
    }

    private var interruptedHistory: [ChatItem] {
        [historyItem("session-draft-2:1", .user, text: "question", turn: 1),
         historyItem("session-draft-2:9", .assistant, text: "settled step", turn: 1),
         historyItem("session-draft-2:11", .user, text: "second question", turn: 2)]
    }

    func testReloadWithInterruptedTurnShowsOneRowWithTheVisibleNote() {
        let result = NativeStreamDraftPolicy.resolve(
            drafts: [draft()],
            history: interruptedHistory,
            turnEndReasons: [2: "interrupted"],
            engineReportsRunningTurn: false,
            sessionID: sessionID)

        XCTAssertTrue(result.consumedItemIDs.isEmpty)
        XCTAssertEqual(result.keptItemIDs, ["session-draft-2:10:part-0"])
        XCTAssertEqual(result.verdict, .kept)
        XCTAssertEqual(result.items.count, interruptedHistory.count + 1)
        let shown = result.items[3]
        XCTAssertEqual(shown.id, "session-draft-2:draft-2-assistant")
        XCTAssertEqual(shown.kind, .assistant)
        XCTAssertEqual(shown.text, "partial answer")
        XCTAssertEqual(shown.turn, 2)
        XCTAssertFalse(shown.streaming)
        XCTAssertTrue(shown.isInterruptedDraft)
        XCTAssertFalse(shown.isInterruptedDraftTruncated)
        XCTAssertEqual(NativeStreamDraftPolicy.interruptedNotice,
                       "已中断：以下是中断前已收到的部分输出，未写入会话，模型看不到")
    }

    func testReloadingTwiceKeepsOneStableRowWithoutDuplication() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-draft-twice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeStreamDraftStore(documentsDirectory: directory)
        let id = "session-draft-twice"
        let item = NativeStreamDraftItem(itemID: "\(id):10:part-0", kind: .assistant,
                                         turn: 2, step: nil, text: "still here")
        store.submit(rows: [item], backend: .phone, sessionID: id)
        store.waitForIdle()

        var question = ChatItem(id: "\(id):1", kind: .user, title: "row", text: "question")
        question.turn = 1
        var settled = ChatItem(id: "\(id):9", kind: .assistant, title: "row",
                               text: "settled step")
        settled.turn = 1
        var secondQuestion = ChatItem(id: "\(id):11", kind: .user, title: "row",
                                      text: "second question")
        secondQuestion.turn = 2
        let history = [question, settled, secondQuestion]

        let first = NativeStreamDraftPolicy.resolve(
            drafts: try XCTUnwrap(store.load(backend: .phone, sessionID: id)).items,
            history: history,
            turnEndReasons: [2: "interrupted"],
            engineReportsRunningTurn: false,
            sessionID: id)
        XCTAssertEqual(first.keptItemIDs, ["\(id):10:part-0"])
        XCTAssertTrue(first.consumedItemIDs.isEmpty)
        XCTAssertEqual(first.items.filter(\.isInterruptedDraft).map(\.id),
                       ["\(id):draft-2-assistant"])

        // A second load sees the same draft and a history that already carries
        // the first load's painted row. It must update that row, not append.
        let second = NativeStreamDraftPolicy.resolve(
            drafts: try XCTUnwrap(store.load(backend: .phone, sessionID: id)).items,
            history: first.items,
            turnEndReasons: [2: "interrupted"],
            engineReportsRunningTurn: false,
            sessionID: id)
        XCTAssertEqual(second.keptItemIDs, ["\(id):10:part-0"])
        XCTAssertTrue(second.consumedItemIDs.isEmpty)
        XCTAssertEqual(second.items.count, first.items.count)
        XCTAssertEqual(second.items.filter(\.isInterruptedDraft).count, 1)
        XCTAssertEqual(second.items.filter(\.isInterruptedDraft).first?.id,
                       "\(id):draft-2-assistant")
        XCTAssertNotNil(store.load(backend: .phone, sessionID: id),
                        "a shown draft stays on disk until a durable replacement")
    }

    func testShownDraftIsConsumedOnlyWhenDurableTextCoversIt() {
        let first = NativeStreamDraftPolicy.resolve(
            drafts: [draft()],
            history: interruptedHistory,
            turnEndReasons: [2: "interrupted"],
            engineReportsRunningTurn: false,
            sessionID: sessionID)
        XCTAssertTrue(first.consumedItemIDs.isEmpty)
        XCTAssertTrue(first.items.contains(where: { $0.isInterruptedDraft }))

        let settled = historyItem("session-draft-2:10:block-0", .assistant,
                                  text: "full settled answer", turn: 2)
        let second = NativeStreamDraftPolicy.resolve(
            drafts: [draft()],
            history: first.items + [settled],
            turnEndReasons: [2: "interrupted"],
            engineReportsRunningTurn: false,
            sessionID: sessionID)
        XCTAssertFalse(second.items.contains(where: { $0.isInterruptedDraft }))
        XCTAssertEqual(second.consumedItemIDs, ["session-draft-2:10:part-0"])
        XCTAssertTrue(second.keptItemIDs.isEmpty)
        XCTAssertEqual(second.verdict, .superseded)
        XCTAssertEqual(second.items.last?.text, "full settled answer")
    }

    func testSettledHistoryAtTheSamePositionWinsAndDeletesTheDraftSilently() {
        let settled = historyItem("session-draft-2:10:block-0", .assistant,
                                  text: "full settled answer", turn: 2)
        let result = NativeStreamDraftPolicy.resolve(
            drafts: [draft()],
            history: interruptedHistory + [settled],
            turnEndReasons: [2: "interrupted"],
            engineReportsRunningTurn: false,
            sessionID: sessionID)

        XCTAssertFalse(result.items.contains(where: { $0.isInterruptedDraft }))
        XCTAssertEqual(result.consumedItemIDs, ["session-draft-2:10:part-0"])
        XCTAssertTrue(result.keptItemIDs.isEmpty)
        XCTAssertEqual(result.verdict, .superseded)
        XCTAssertEqual(result.items.last?.text, "full settled answer")
    }

    func testSettledHistoryDeletesTheDraftFileOnReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-draft-settled-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeStreamDraftStore(documentsDirectory: directory)
        let id = "session-draft-settled"
        store.submit(rows: [NativeStreamDraftItem(itemID: "\(id):10:part-0",
                                                  kind: .assistant, turn: 2, step: nil,
                                                  text: "partial")],
                     backend: .phone, sessionID: id)
        store.waitForIdle()
        XCTAssertNotNil(store.load(backend: .phone, sessionID: id))

        var question = ChatItem(id: "\(id):1", kind: .user, title: "row", text: "question")
        question.turn = 1
        var settled = ChatItem(id: "\(id):10:block-0", kind: .assistant, title: "row",
                               text: "durable answer")
        settled.turn = 2
        let result = NativeStreamDraftPolicy.resolve(
            drafts: try XCTUnwrap(store.load(backend: .phone, sessionID: id)).items,
            history: [question, settled],
            turnEndReasons: [2: "interrupted"],
            engineReportsRunningTurn: false,
            sessionID: id)
        XCTAssertFalse(result.items.contains(where: { $0.isInterruptedDraft }))
        store.consume(backend: .phone, sessionID: id, itemIDs: result.consumedItemIDs)
        store.waitForIdle()
        XCTAssertNil(store.load(backend: .phone, sessionID: id),
                     "settled history silently removes the draft file")
    }

    func testSettledTextBeforeTheDraftPositionDoesNotCoverIt() {
        let earlier = historyItem("session-draft-2:8:block-0", .assistant,
                                  text: "earlier step", turn: 2)
        let result = NativeStreamDraftPolicy.resolve(
            drafts: [draft()],
            history: interruptedHistory + [earlier],
            turnEndReasons: [2: "interrupted"],
            engineReportsRunningTurn: false,
            sessionID: sessionID)
        XCTAssertTrue(result.items.contains(where: { $0.isInterruptedDraft }),
                      "only text at/after the draft position supersedes it")
        XCTAssertTrue(result.consumedItemIDs.isEmpty)
        XCTAssertEqual(result.keptItemIDs, ["session-draft-2:10:part-0"])
    }

    func testRunningTurnStillShowsAndKeepsTheDraft() {
        let result = NativeStreamDraftPolicy.resolve(
            drafts: [draft()],
            history: interruptedHistory,
            turnEndReasons: [:],
            engineReportsRunningTurn: true,
            sessionID: sessionID)
        XCTAssertTrue(result.items.contains(where: { $0.isInterruptedDraft }))
        XCTAssertEqual(result.keptItemIDs, ["session-draft-2:10:part-0"])
        XCTAssertTrue(result.consumedItemIDs.isEmpty)
        XCTAssertEqual(result.verdict, .kept)
    }

    func testUnendedTurnOnAnIdleEngineShowsAndKeepsTheDraft() {
        let result = NativeStreamDraftPolicy.resolve(
            drafts: [draft()],
            history: interruptedHistory,
            turnEndReasons: [:],
            engineReportsRunningTurn: false,
            sessionID: sessionID)
        XCTAssertTrue(result.items.contains(where: { $0.isInterruptedDraft }))
        XCTAssertEqual(result.keptItemIDs, ["session-draft-2:10:part-0"])
        XCTAssertTrue(result.consumedItemIDs.isEmpty)
    }

    func testCancelledFailedAndAbortedTurnsAreKeptButCompletedIsNot() {
        for kind in ["interrupted", "failed", "error", "cancelled", "aborted"] {
            XCTAssertTrue(NativeStreamDraftPolicy.isNonNormalTurnEnd(kind), kind)
            XCTAssertFalse(NativeStreamDraftPolicy.isNormalTurnEnd(kind), kind)
        }
        XCTAssertTrue(NativeStreamDraftPolicy.isNormalTurnEnd("completed"))
        XCTAssertTrue(NativeStreamDraftPolicy.isNormalTurnEnd(nil))
    }

    func testNormalEndDeletesAStaleDraft() {
        let result = NativeStreamDraftPolicy.resolve(
            drafts: [draft()],
            history: interruptedHistory,
            turnEndReasons: [2: "completed"],
            engineReportsRunningTurn: false,
            sessionID: sessionID)
        XCTAssertFalse(result.items.contains(where: { $0.isInterruptedDraft }))
        XCTAssertEqual(result.consumedItemIDs, ["session-draft-2:10:part-0"])
        XCTAssertTrue(result.keptItemIDs.isEmpty)
        XCTAssertEqual(result.verdict, .settled)
    }

    func testDraftIsInsertedAtTheEndOfItsTurnNotTheSessionTail() {
        let status = ChatItem(id: "session-draft-2:status", kind: .status,
                              title: "Host", text: "ready")
        let result = NativeStreamDraftPolicy.resolve(
            drafts: [draft(turn: 1)],
            history: Array(interruptedHistory.prefix(2)) + [status],
            turnEndReasons: [1: "interrupted"],
            engineReportsRunningTurn: false,
            sessionID: sessionID)
        XCTAssertEqual(result.items.prefix(3).map(\.id), [
            "session-draft-2:1", "session-draft-2:9",
            "session-draft-2:draft-1-assistant",
        ])
        XCTAssertEqual(result.items.last?.id, "session-draft-2:status")
    }

    func testANewerDurableTurnSupersedesTheOlderDraft() {
        let result = NativeStreamDraftPolicy.resolve(
            drafts: [draft(turn: 1)],
            history: interruptedHistory,
            turnEndReasons: [1: "interrupted"],
            engineReportsRunningTurn: false,
            sessionID: sessionID)
        XCTAssertFalse(result.items.contains(where: { $0.isInterruptedDraft }))
        XCTAssertEqual(result.consumedItemIDs, ["session-draft-2:10:part-0"])
        XCTAssertTrue(result.keptItemIDs.isEmpty)
        XCTAssertEqual(result.verdict, .superseded)
    }

    func testEvidenceLineFormatsKeptDraftAndVerdict() {
        let item = draft()
        let result = NativeStreamDraftPolicy.resolve(
            drafts: [item],
            history: interruptedHistory,
            turnEndReasons: [2: "interrupted"],
            engineReportsRunningTurn: false,
            sessionID: sessionID)
        let line = NativeStreamDraftEvidence.evidenceLine(
            sessionID: sessionID,
            dshLastSeq: 42,
            snapshotLastSeq: 99,
            drafts: [item],
            resolution: result,
            activeTurn: 2)
        XCTAssertEqual(line, "draft-evidence session=session-draft-2 "
                       + "dsh_last_seq=42 snapshot_last_seq=99 drafts=1 "
                       + "kept=session-draft-2:10:part-0 consumed=- "
                       + "active_turn=2 draft_turn=2 draft_seq=10 verdict=kept")
    }

    func testEvidenceLineFormatsConsumedAndNoneVerdicts() {
        let item = draft()
        let settled = historyItem("session-draft-2:10:block-0", .assistant,
                                  text: "full settled answer", turn: 2)
        let superseded = NativeStreamDraftPolicy.resolve(
            drafts: [item],
            history: interruptedHistory + [settled],
            turnEndReasons: [2: "interrupted"],
            engineReportsRunningTurn: false,
            sessionID: sessionID)
        let consumedLine = NativeStreamDraftEvidence.evidenceLine(
            sessionID: sessionID,
            dshLastSeq: nil,
            snapshotLastSeq: nil,
            drafts: [item],
            resolution: superseded,
            activeTurn: nil)
        XCTAssertEqual(consumedLine, "draft-evidence session=session-draft-2 "
                       + "dsh_last_seq=none snapshot_last_seq=none drafts=1 "
                       + "kept=- consumed=session-draft-2:10:part-0 "
                       + "active_turn=none draft_turn=2 draft_seq=10 "
                       + "verdict=superseded")

        let none = NativeStreamDraftPolicy.resolve(
            drafts: [],
            history: [],
            turnEndReasons: [:],
            engineReportsRunningTurn: false,
            sessionID: sessionID)
        let noneLine = NativeStreamDraftEvidence.evidenceLine(
            sessionID: sessionID,
            dshLastSeq: 7,
            snapshotLastSeq: 8,
            drafts: [],
            resolution: none,
            activeTurn: nil)
        XCTAssertEqual(noneLine, "draft-evidence session=session-draft-2 "
                       + "dsh_last_seq=7 snapshot_last_seq=8 drafts=0 "
                       + "kept=- consumed=- active_turn=none draft_turn=none "
                       + "draft_seq=none verdict=none")

        let settledResult = NativeStreamDraftPolicy.resolve(
            drafts: [item],
            history: interruptedHistory,
            turnEndReasons: [2: "completed"],
            engineReportsRunningTurn: false,
            sessionID: sessionID)
        let settledLine = NativeStreamDraftEvidence.evidenceLine(
            sessionID: sessionID,
            dshLastSeq: 42,
            snapshotLastSeq: 41,
            drafts: [item],
            resolution: settledResult,
            activeTurn: nil)
        XCTAssertTrue(settledLine.hasSuffix(" verdict=settled"), settledLine)
    }

    func testTruncatedDraftKeepsTheTail() throws {
        let tail = "TAIL-MARK"
        let huge = String(repeating: "x", count: 700_000) + tail
        let data = try XCTUnwrap(NativeStreamDraftCodec.encode(
            items: [NativeStreamDraftItem(itemID: "session-draft-2:10:part-0",
                                          kind: .assistant, turn: 2, step: nil,
                                          text: huge)],
            backend: .phone, sessionID: sessionID))
        XCTAssertLessThanOrEqual(data.count, NativeStreamDraftCodec.maxFileBytes)
        let file = try XCTUnwrap(NativeStreamDraftCodec.decode(
            data, backend: .phone, sessionID: sessionID))
        let item = try XCTUnwrap(file.items.first)
        XCTAssertTrue(item.truncated)
        XCTAssertTrue(item.text.hasSuffix(tail))
        XCTAssertLessThan(item.text.count, huge.count)
        XCTAssertGreaterThan(item.text.count, 0)
    }

    func testCodecRejectsAnotherScopeOrCorruptBytes() throws {
        let data = try XCTUnwrap(NativeStreamDraftCodec.encode(
            items: [draft()], backend: .phone, sessionID: sessionID))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"v\":1"))
        XCTAssertTrue(json.contains("\"updatedAt\""))
        XCTAssertTrue(json.contains("\"itemID\""))
        XCTAssertNil(NativeStreamDraftCodec.decode(data, backend: .pc(machineId: "pc-one"),
                                                   sessionID: sessionID))
        XCTAssertNil(NativeStreamDraftCodec.decode(data, backend: .phone,
                                                   sessionID: "session-draft-3"))
        XCTAssertNil(NativeStreamDraftCodec.decode(Data("not json".utf8),
                                                   backend: .phone, sessionID: sessionID))
    }

    func testDisplayOnlyDraftIsNotModelContext() {
        let settled = ChatItem(id: "settled", kind: .assistant, title: "Assistant",
                               text: "settled")
        var draftRow = ChatItem(id: "draft", kind: .assistant, title: "Assistant",
                                text: "display only")
        draftRow.isInterruptedDraft = true
        XCTAssertEqual(NativeStreamDraftPolicy.modelContextItems([settled, draftRow]),
                       [settled])
        XCTAssertTrue(draftRow.isInterruptedDraft)
    }

    func testScenePhaseFlushesOnInactiveAndBackgroundOnly() {
        XCTAssertFalse(NativeStreamDraftPolicy.shouldFlushOnScenePhase(active: true))
        XCTAssertTrue(NativeStreamDraftPolicy.shouldFlushOnScenePhase(active: false))
    }

    func testTrackerKeepsOnlyTheCurrentStreamRows() {
        var tracker = NativeStreamDraftTracker()
        tracker.begin(itemID: "a", kind: .assistant, turn: 1, step: nil)
        tracker.begin(itemID: "r", kind: .reasoning, turn: 1, step: nil)
        tracker.append("hello", to: "a")
        tracker.append("think", to: "r")
        XCTAssertEqual(tracker.items.map(\.text), ["hello", "think"])

        tracker.clear(kind: .reasoning, turn: 1)
        XCTAssertEqual(tracker.items.map(\.itemID), ["a"])
        tracker.clear(turn: 1)
        XCTAssertTrue(tracker.items.isEmpty)
    }
}

final class NativeStreamDraftCacheTests: XCTestCase {
    private func temporaryDocuments() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-draft-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testTranscriptSnapshotWriterExcludesDisplayOnlyDraftRows() throws {
        let directory = try temporaryDocuments()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json")
        var draft = ChatItem(id: "draft-row", kind: .assistant, title: "Assistant",
                             text: "display only")
        draft.isInterruptedDraft = true
        let settled = ChatItem(id: "settled-row", kind: .assistant, title: "Assistant",
                               text: "durable answer")
        let writer = TranscriptSnapshotWriter(isCurrentSession: { _, _ in true })
        writer.submit(items: [settled, draft], backend: .phone, sessionID: "session",
                      lastSeq: nil, url: url, capturedAt: Date())
        writer.waitForIdle()
        let decoded = try XCTUnwrap(CachedTranscriptCodec.decode(
            try Data(contentsOf: url), backend: .phone, sessionID: "session"))
        XCTAssertEqual(decoded.items.map(\.id), ["settled-row"])
    }

    func testPolicyPaintedDraftIsExcludedFromTranscriptSnapshot() throws {
        let directory = try temporaryDocuments()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.json")
        var question = ChatItem(id: "session:1", kind: .user, title: "You",
                                text: "question")
        question.turn = 1
        var settled = ChatItem(id: "session:9", kind: .assistant, title: "Assistant",
                               text: "durable answer")
        settled.turn = 1
        let draft = NativeStreamDraftItem(itemID: "session:10:part-0",
                                          kind: .assistant, turn: 1, step: nil,
                                          text: "display only")
        let resolution = NativeStreamDraftPolicy.resolve(
            drafts: [draft],
            history: [question, settled],
            turnEndReasons: [1: "interrupted"],
            engineReportsRunningTurn: false,
            sessionID: "session")
        let painted = try XCTUnwrap(resolution.items.first(where: { $0.isInterruptedDraft }))
        XCTAssertEqual(painted.id, "session:draft-1-assistant")

        let writer = TranscriptSnapshotWriter(isCurrentSession: { _, _ in true })
        writer.submit(items: resolution.items, backend: .phone, sessionID: "session",
                      lastSeq: nil, url: url, capturedAt: Date())
        writer.waitForIdle()
        let decoded = try XCTUnwrap(CachedTranscriptCodec.decode(
            try Data(contentsOf: url), backend: .phone, sessionID: "session"))
        XCTAssertEqual(decoded.items.map(\.id), ["session:1", "session:9"])
        XCTAssertFalse(decoded.items.contains(where: { $0.id == painted.id }))
    }

    func testRemoveLocalDataRemovesTheDraftFile() throws {
        let documents = try temporaryDocuments()
        defer { try? FileManager.default.removeItem(at: documents) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pdsh-draft-\(UUID().uuidString)"))
        let session = "session-unpair"
        let url = try XCTUnwrap(WorkspaceStorage.streamDraftURL(
            for: .phone, sessionID: session, documentsDirectory: documents))
        try Data("{}".utf8).write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        WorkspaceStorage.removeLocalData(for: .phone, defaults: defaults,
                                         documentsDirectory: documents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSnapshotEvictionRemovesTheCompanionDraft() throws {
        let documents = try temporaryDocuments()
        defer { try? FileManager.default.removeItem(at: documents) }
        let directory = WorkspaceStorage.transcriptsDirectory(for: .pc(machineId: "pc-one"),
                                                              documentsDirectory: documents)
        let fileManager = FileManager.default
        for index in 0..<5 {
            let snapshot = directory.appendingPathComponent("s-\(index).json")
            let draft = directory.appendingPathComponent("s-\(index).draft.json")
            try Data("{}".utf8).write(to: snapshot)
            try Data("{}".utf8).write(to: draft)
            let date = Date(timeIntervalSince1970: Double(index))
            try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: snapshot.path)
            try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: draft.path)
        }
        WorkspaceStorage.evictTranscriptSnapshots(for: .pc(machineId: "pc-one"),
                                                  documentsDirectory: documents,
                                                  keeping: "s-0", limit: 2)
        let left = try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(left, ["s-0.draft.json", "s-0.json",
                              "s-4.draft.json", "s-4.json"],
                       "evicted snapshots take their draft with them; the current "
                       + "session keeps both")
    }

    func testRemoveTranscriptArtifactsDeletesSnapshotAndDraft() throws {
        let documents = try temporaryDocuments()
        defer { try? FileManager.default.removeItem(at: documents) }
        let session = "session-erase"
        let snapshot = try XCTUnwrap(WorkspaceStorage.transcriptSnapshotURL(
            for: .phone, sessionID: session, documentsDirectory: documents))
        let draft = try XCTUnwrap(WorkspaceStorage.streamDraftURL(
            for: .phone, sessionID: session, documentsDirectory: documents))
        try Data("{}".utf8).write(to: snapshot)
        try Data("{}".utf8).write(to: draft)
        WorkspaceStorage.removeTranscriptArtifacts(for: .phone, sessionID: session,
                                                   documentsDirectory: documents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.path))
    }
}
