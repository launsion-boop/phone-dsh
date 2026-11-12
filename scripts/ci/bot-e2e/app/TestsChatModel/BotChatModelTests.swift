// SPDX-License-Identifier: MIT

import XCTest
import PhoneDSHAgentCore

@MainActor
final class BotChatModelTests: XCTestCase {
    func testSameTextFromSeparateSendsReconcilesByNonce() {
        let model = BotChatModel(context: BotRuntimeContext(botID: "main", botName: "大肥鱼"), fixtureActions: true)
        model.send(text: "same text")
        model.send(text: "same text")
        let pending = model.rows
        for (index, local) in pending.enumerated() {
            var durable = BotUIRow.text(id: "row-\(index)", seq: index + 1, role: "user", text: "same text")
            durable.chatActionNonce = String(local.id.dropFirst("local-".count))
            model.apply(BotUIRowBatch(rows: [durable], deletes: [], cursor: index + 1, reset: false))
            XCTAssertFalse(model.rows.contains { $0.id == local.id })
            XCTAssertEqual(model.rows.count, 2)
        }
        XCTAssertEqual(model.rows.map(\.id), ["row-0", "row-1"])
    }

    func testHistoryUsesRowAnchorAfterLiveUpdates() async {
        let rows = (0..<52).map { index in
            BotUIRow.text(id: "row-\(index)", seq: index, role: "user", text: "Message \(index)")
        }
        let driver = BotChatDriver(
            history: { anchor, limit in
                XCTAssertEqual(anchor, "row-2")
                XCTAssertEqual(limit, 50)
                return BotUIHistoryPage(rows: Array(rows.prefix(2)), nextCursor: "row-0", hasMore: false)
            },
            watch: { _ in BotUIRowBatch(rows: [], deletes: [], cursor: 0, reset: false) },
            perform: { _ in .rejected(reason: "unused") },
            stopCurrentTurn: { _ in })
        let model = BotChatModel(context: BotRuntimeContext(botID: "main", botName: "大肥鱼"), driver: driver)
        model.apply(BotUIRowBatch(rows: rows, deletes: [], cursor: 99, reset: true))
        XCTAssertEqual(model.rows.count, 50)
        XCTAssertTrue(model.hasMoreHistory)
        model.apply(BotUIRowBatch(rows: [], deletes: [], cursor: 100, reset: false))
        await model.loadHistory()
        XCTAssertEqual(model.rows, rows)
        XCTAssertFalse(model.hasMoreHistory)
        XCTAssertNil(model.runtimeNotice)
    }

    /// Regression for the removed production fallback: without a driver the
    /// model must report a failed action and never fabricate an accepted event.
    func testWithoutDriverFailsClosed() async throws {
        let model = BotChatModel(context: BotRuntimeContext(botID: "main", botName: "大肥鱼"))
        model.send(text: "没有 driver 不应被接受")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(model.actionStates.values.contains {
            if case .failed = $0 { return true }
            return false
        }, "missing driver must produce a failed action state")
        XCTAssertFalse(model.rows.contains { row in
            row.provenance.eventIDs.contains { $0.hasPrefix("evt-action-") }
        }, "missing driver must never fabricate an accepted event")
    }

    // MARK: - Activity line visibility across a turn

    /// The page's scroll target: the newest pending approval / question card
    /// wins over trailing live text. #126 mounts the turn's streamed text after
    /// the durable rows, so a tail scroll covered the card that was waiting for
    /// the person (final-2: DB had approval.requested, UI showed no card).
    func testNewestActionableCardWinsOverTrailingLiveText() {
        let questionBody = BotUIBody(type: "widget", values: [
            "cardType": .string("question"),
            "question": .string("要选 A 还是 B？"),
            "options": .array([.object(["id": .string("o0"), "label": .string("A")])]),
        ])
        let question = BotUIRow.fixture(id: "q", seq: 2, body: questionBody)
        let model = BotChatModel(
            rows: [question],
            context: BotRuntimeContext(botID: "main", botName: "大肥鱼"),
            fixtureActions: true)
        XCTAssertEqual(model.newestActionableCard?.id, "q")
        model.receive(.textDelta("这段旁白在卡片下方，不能把卡片滚出键盘上沿。"))
        XCTAssertEqual(model.newestActionableCard?.id, "q",
                       "live text after the card must not steal the scroll target")

        let approval = BotUIRow.fixture(id: "a", seq: 3, body: BotUIBody(type: "approval", values: [
            "approvalID": .string("approval-1"),
            "digest": .string("digest-1"),
            "status": .string("pending"),
            "action": .string("删除旧文件"),
        ]))
        model.apply(BotUIRowBatch(rows: [approval], deletes: [], cursor: 1, reset: false))
        XCTAssertEqual(model.newestActionableCard?.id, "a")

        var decided = approval
        decided.body.values["status"] = .string("allowed")
        decided.updatedSeq = 2
        model.apply(BotUIRowBatch(rows: [decided], deletes: [], cursor: 2, reset: false))
        XCTAssertNil(model.newestActionableCard,
                     "a decided approval is no longer an actionable scroll target")
    }

    /// The line starts on the local echo: after `send` the host has not opened
    /// the turn yet, so there is no factory activity and it shows thinking.
    func testSendShowsActivityLineBeforeTurnStarts() {
        let model = BotChatModel(context: context, driver: driver())
        model.send(text: "看看构建结果")
        XCTAssertTrue(model.awaitingTurn)
        XCTAssertTrue(model.showsActivityLine)
        XCTAssertEqual(model.lineActivity?.category, .thinking)
    }

    func testStreamingTextKeepsReplyingActivityLine() async throws {
        let model = BotChatModel(context: context)
        model.receive(liveEvent("turn/start", turn: 1, seq: 1))
        model.receive(.textDelta("我先看一下构建日志"))
        XCTAssertTrue(model.showsActivityLine)
        XCTAssertEqual(model.lineActivity?.category, .replying)
        XCTAssertEqual(model.lineActivity?.detail, "")

        // After the coalescer flushes, the uncommitted live buffer is the
        // signal, and it is still "replying".
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(model.isStreamingNow)
        XCTAssertTrue(model.showsActivityLine)
        XCTAssertEqual(model.lineActivity?.category, .replying)
    }

    func testPendingApprovalShowsWaitingCategoryEvenWhileStreaming() {
        let model = BotChatModel(rows: [approvalRow()], context: context)
        model.receive(liveEvent("turn/start", turn: 1, seq: 1))
        model.receive(.textDelta("我先把这一段写完"))
        XCTAssertTrue(model.showsActivityLine)
        XCTAssertEqual(model.pendingApprovalCount, 1)
        XCTAssertEqual(model.lineActivity?.category, .waiting)
    }

    /// Committed text segments do not count as streaming: after the paragraph
    /// is committed and the turn calls a tool, the tool category returns.
    func testToolAfterCommittedTextReturnsToToolCategory() {
        let model = BotChatModel(context: context)
        model.receive(liveEvent("turn/start", turn: 1, seq: 1))
        model.receive(.textDelta("先看一下报告"))
        model.receive(liveEvent("assistant/message", turn: 1, seq: 3, data: [
            "message": .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string("先看一下报告")]),
                ]),
            ]),
        ]))
        XCTAssertFalse(model.isStreamingNow)
        XCTAssertEqual(model.lineActivity?.category, .thinking)

        model.receive(liveEvent("tool/call", turn: 1, seq: 4, data: [
            "callId": .string("call-read-1"),
            "name": .string("read"),
            "arguments": .string("{\"path\":\"/tmp/report.md\"}"),
        ]))
        XCTAssertTrue(model.showsActivityLine)
        XCTAssertEqual(model.lineActivity?.category, .reading)
        XCTAssertEqual(model.lineActivity?.detail, "在翻文件 · report.md")
    }

    func testFinalHidesActivityLine() {
        let model = BotChatModel(context: context)
        model.beginTurn(turnID: "1")
        model.receive(.textDelta("写完了"))
        XCTAssertTrue(model.showsActivityLine)
        model.receiveStream(turnID: "1", text: "写完了", final: true)
        XCTAssertFalse(model.showsActivityLine)
        XCTAssertNil(model.lineActivity)
    }

    func testTurnEndHidesActivityLine() {
        let model = BotChatModel(context: context)
        model.receive(liveEvent("turn/start", turn: 1, seq: 1))
        model.receive(liveEvent("tool/call", turn: 1, seq: 2, data: [
            "callId": .string("call-read-2"),
            "name": .string("read"),
            "arguments": .string("{}"),
        ]))
        XCTAssertTrue(model.showsActivityLine)
        model.receive(liveEvent("turn/end", turn: 1, seq: 3, data: [
            "reason": .object(["kind": .string("completed")]),
        ]))
        XCTAssertFalse(model.showsActivityLine)
        XCTAssertNil(model.lineActivity)
    }

    func testStopHidesActivityLineImmediately() {
        let model = BotChatModel(context: context)
        model.receive(liveEvent("turn/start", turn: 1, seq: 1))
        XCTAssertTrue(model.showsActivityLine)
        model.stop()
        XCTAssertFalse(model.showsActivityLine)
        XCTAssertNil(model.lineActivity)
    }

    /// Stopping hides only the status line: the partial reply already on
    /// screen must stay until the durable rows take it over.
    func testStopKeepsStreamedTextVisible() async throws {
        let model = BotChatModel(context: context)
        model.receive(liveEvent("turn/start", turn: 1, seq: 1))
        model.receive(.textDelta("已经流出的半段文字"))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(model.showsActivityLine)

        model.stop()
        XCTAssertFalse(model.showsActivityLine)
        XCTAssertNil(model.lineActivity)
        let live = try XCTUnwrap(model.live, "stop must keep the live turn")
        XCTAssertTrue(live.buffer.contains("已经流出的半段文字")
                      || live.segments.contains { segment in
                          if case .text(let text) = segment {
                              return text.contains("已经流出的半段文字")
                          }
                          return false
                      })
    }

    func testNextSendAfterStopShowsLineAgain() {
        let model = BotChatModel(context: context, driver: driver())
        model.receive(liveEvent("turn/start", turn: 1, seq: 1))
        model.stop()
        XCTAssertFalse(model.showsActivityLine)

        model.send(text: "继续")
        XCTAssertTrue(model.awaitingTurn)
        XCTAssertTrue(model.showsActivityLine)
        XCTAssertNotNil(model.lineActivity)
    }

    // MARK: - Helpers

    private var context: BotRuntimeContext {
        BotRuntimeContext(botID: "main", botName: "大肥鱼")
    }

    private func driver(
        perform: @escaping (BotUIUserAction) async -> BotUIActionResult = {
            _ in .accepted(eventID: "evt-check")
        }
    ) -> BotChatDriver {
        BotChatDriver(
            history: { _, _ in BotUIHistoryPage(rows: [], nextCursor: nil, hasMore: false) },
            watch: { _ in BotUIRowBatch(rows: [], deletes: [], cursor: 0, reset: false) },
            perform: perform,
            stopCurrentTurn: { _ in })
    }

    /// Live frames carry the DSH session-event shape (`type`/`seq`/`time`/
    /// `data`), exactly like the runtime forwards them.
    private func liveEvent(_ type: String, turn: Int, seq: Int,
                           data: [String: JSONValue] = [:]) -> BotLiveFrame {
        var values: [String: JSONValue] = ["turn": .number(Double(turn))]
        for (key, value) in data { values[key] = value }
        return .event(.object([
            "type": .string(type),
            "seq": .number(Double(seq)),
            "time": .number(Double(BotLiveFishProjection.now + Int64(seq))),
            "data": .object(values),
        ]))
    }

    private func approvalRow() -> BotUIRow {
        BotUIRow.fixture(id: "approval-activity", seq: 2, body: BotUIBody(type: "approval", values: [
            "approvalID": "approval-activity",
            "digest": "sha256:activity",
            "status": "pending",
            "action": "删除旧的临时报告",
        ]))
    }
}
