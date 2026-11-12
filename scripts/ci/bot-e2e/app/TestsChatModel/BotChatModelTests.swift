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

    // MARK: - Interactive card settlement

    /// A send is the user's implicit deny for every approval still pending:
    /// the existing approval action must reach the driver before the chat.
    func testSendAutoDeclinesApprovalsBeforeChat() async throws {
        var performed: [String] = []
        let model = BotChatModel(
            rows: [approvalRow(id: "approval-auto")],
            context: context,
            driver: driver { action in
                switch action {
                case .approval(_, _, _, let decision, _):
                    performed.append("approval:\(decision.rawValue)")
                case .chat:
                    performed.append("chat")
                case .cardAnswer:
                    performed.append("cardAnswer")
                case .cardDismiss:
                    performed.append("cardDismiss")
                case .stopTask:
                    performed.append("stopTask")
                }
                return .accepted(eventID: "evt-\(performed.count)")
            })

        XCTAssertEqual(model.pendingApprovalCount, 1)
        model.send(text: "先继续，这个审批不用了。")
        XCTAssertEqual(model.pendingApprovalCount, 0,
                       "a send must clear pendingApprovalCount before the async deny finishes")

        try await waitFor { performed.count == 2 }
        XCTAssertEqual(performed, ["approval:deny", "chat"])
        XCTAssertEqual(model.actionLog, ["approval:deny", "chat"])
        XCTAssertTrue(model.autoDeclinedApprovalIDs.contains("approval-auto"))

        let row = try XCTUnwrap(model.rows.first(where: { $0.id == "approval-auto" }))
        let settlement = try XCTUnwrap(model.settlement(for: row))
        XCTAssertEqual(settlement.title, "已略过，视为拒绝")
        XCTAssertEqual(settlement.detail, "rm -f /tmp/phone-dsh-old-report.pdf")
        XCTAssertEqual(model.needsAttentionCount, 0)
    }

    func testSendClearsPendingApprovalCountImmediately() {
        let model = BotChatModel(rows: [approvalRow(id: "approval-immediate")],
                                 context: context,
                                 driver: driver())
        XCTAssertEqual(model.pendingApprovalCount, 1)
        model.send(text: "下一条消息")
        XCTAssertEqual(model.pendingApprovalCount, 0)
    }

    func testAnswerSettlesIntoSelectedOptionLine() async throws {
        let model = BotChatModel(rows: [questionRow()], context: context,
                                 driver: driver())
        let row = try XCTUnwrap(model.rows.first(where: { $0.id == "question-settle" }))
        model.answer(row: row, optionID: "library")

        // Pending keeps the full card (existing loading).
        XCTAssertNil(model.settlement(for: row))
        try await waitFor { model.actionStates["card:question-settle"] == .accepted }

        let settlement = try XCTUnwrap(model.settlement(for: row))
        XCTAssertEqual(settlement.title, "已选择：保存到文档库")
        XCTAssertEqual(settlement.detail, "要把这份整理好的内容保存到哪里？")
        XCTAssertEqual(model.needsAttentionCount, 0)
    }

    func testDurableAnsweredAndSkippedRules() throws {
        let answered = BotChatModel(rows: [questionRow(status: "answered",
                                                       answeredOptionID: "library")],
                                    context: context)
        let answeredRow = try XCTUnwrap(answered.rows.first)
        XCTAssertEqual(answered.settlement(for: answeredRow)?.title, "已选择：保存到文档库")

        let skipped = BotChatModel(rows: [
            checklistRow(),
            BotUIRow.text(id: "next-user", seq: 2, role: "user", text: "继续"),
        ], context: context)
        let checklist = try XCTUnwrap(skipped.rows.first(where: { $0.id == "checklist-settle" }))
        let settlement = try XCTUnwrap(skipped.settlement(for: checklist))
        XCTAssertEqual(settlement.title, "已略过")
        XCTAssertEqual(settlement.detail, "发布前检查 · 已完成 2/4")
        XCTAssertEqual(skipped.needsAttentionCount, 0)
    }

    func testStepsWithoutPromptUsesSuggestedNextStepDetail() throws {
        let model = BotChatModel(rows: [stepsRow()], context: context)
        let row = try XCTUnwrap(model.rows.first)
        let settlement = try XCTUnwrap(model.settlement(for: row))
        XCTAssertEqual(settlement.title, "已选择：查看验收结果")
        XCTAssertEqual(settlement.detail, "建议下一步")
    }

    func testFailedAnswerKeepsFullCardForRetry() async throws {
        let model = BotChatModel(
            rows: [questionRow()], context: context,
            driver: driver { _ in .rejected(reason: "离线") })
        let row = try XCTUnwrap(model.rows.first)
        model.answer(row: row, optionID: "library")
        XCTAssertNil(model.settlement(for: row))

        try await waitFor {
            guard let state = model.actionStates["card:question-settle"] else { return false }
            if case .failed = state { return true }
            return false
        }
        XCTAssertNil(model.settlement(for: row), "a failed action must stay a full retryable card")
        XCTAssertEqual(model.needsAttentionCount, 1)
    }

    func testDismissedQuestionSettlesClosed() async throws {
        let model = BotChatModel(rows: [questionRow()], context: context,
                                 driver: driver())
        let row = try XCTUnwrap(model.rows.first)
        model.dismiss(row: row)
        try await waitFor { model.dismissedCardIDs.contains("question-settle") }

        let settlement = try XCTUnwrap(model.settlement(for: row))
        XCTAssertEqual(settlement.title, "已关闭")
        XCTAssertEqual(model.needsAttentionCount, 0)
    }

    func testChecklistSendSettlesOnlyAfterAcceptance() async throws {
        let model = BotChatModel(rows: [checklistRow()], context: context,
                                 driver: driver())
        let row = try XCTUnwrap(model.rows.first(where: { $0.id == "checklist-settle" }))
        model.sendChecklist(row: row, done: 2, total: 4,
                            message: "发布前检查：已完成 2/4。")
        XCTAssertNil(model.settlement(for: row), "the full checklist stays while the action is in flight")

        try await waitFor { model.checklistProgress["checklist-settle"]?.sent == true }
        let settled = try XCTUnwrap(model.rows.first(where: { $0.id == "checklist-settle" }))
        let settlement = try XCTUnwrap(model.settlement(for: settled))
        XCTAssertEqual(settlement.title, "已发送勾选结果")
        XCTAssertEqual(settlement.detail, "发布前检查 · 已完成 2/4")
        XCTAssertEqual(model.needsAttentionCount, 0)
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

    private func waitFor(timeout: TimeInterval = 2,
                         _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("condition was not met within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
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

    private func approvalRow(id: String = "approval-activity",
                             status: String = "pending") -> BotUIRow {
        BotUIRow.fixture(id: id, seq: 2, body: BotUIBody(type: "approval", values: [
            "approvalID": .string(id),
            "digest": "sha256:activity",
            "status": .string(status),
            "action": "删除旧的临时报告",
            "command": "rm -f /tmp/phone-dsh-old-report.pdf",
        ]))
    }

    private func questionRow(id: String = "question-settle",
                             status: String? = nil,
                             answeredOptionID: String? = nil) -> BotUIRow {
        var values: [String: BotJSONValue] = [
            "cardType": "question",
            "question": "要把这份整理好的内容保存到哪里？",
            "options": [
                ["id": "library", "label": "保存到文档库"],
                ["id": "pdf", "label": "导出 PDF"],
            ],
        ]
        if let status { values["status"] = .string(status) }
        if let answeredOptionID { values["answeredOptionID"] = .string(answeredOptionID) }
        return BotUIRow.fixture(id: id, seq: 1,
                                body: BotUIBody(type: "widget", values: values))
    }

    private func stepsRow() -> BotUIRow {
        BotUIRow.fixture(id: "steps-settle", seq: 1, body: BotUIBody(type: "widget", values: [
            "cardType": "steps",
            "status": "answered",
            "answeredOptionID": "review",
            "steps": [
                ["id": "review", "label": "查看验收结果"],
                ["id": "pr", "label": "创建 Pull Request"],
            ],
        ]))
    }

    private func checklistRow(id: String = "checklist-settle") -> BotUIRow {
        BotUIRow.fixture(id: id, seq: 1, body: BotUIBody(type: "widget", values: [
            "cardType": "checklist",
            "title": "发布前检查",
            "items": [
                ["id": "c0", "text": "运行指定 CI 门禁", "done": true],
                ["id": "c1", "text": "检查浅色与深色截图", "done": true],
                ["id": "c2", "text": "验证重复点击和迟到结果"],
                ["id": "c3", "text": "记录未验证项目"],
            ],
        ]))
    }

    func testNoticeRowsStayOutOfTranscriptAndFreshErrorGoesToHeader() {
        let model = BotChatModel(context: BotRuntimeContext(botID: "main", botName: "大肥鱼"), fixtureActions: true)
        let history = BotUIRow.fixture(id: "old-error", seq: 1,
                                       body: BotUIBody(type: "notice", values: ["tone": "error", "text": "旧的失败"]))
        model.apply(BotUIRowBatch(rows: [history], deletes: [], cursor: 1, reset: true))
        XCTAssertNil(model.runtimeNotice, "history must not replay an error")
        XCTAssertTrue(model.visibleRows.isEmpty)

        let denied = BotUIRow.fixture(id: "denied", seq: 2,
                                      body: BotUIBody(type: "notice", values: ["tone": "denied", "text": "已拒绝"]))
        model.apply(BotUIRowBatch(rows: [denied], deletes: [], cursor: 2, reset: false))
        XCTAssertNil(model.runtimeNotice, "a denial is the approval's settled line")

        let fresh = BotUIRow.fixture(id: "fresh-error", seq: 3,
                                     body: BotUIBody(type: "notice", values: ["tone": "error", "text": "生成报告失败"]))
        model.apply(BotUIRowBatch(rows: [fresh], deletes: [], cursor: 3, reset: false))
        XCTAssertEqual(model.runtimeNotice, "生成报告失败")
        XCTAssertTrue(model.visibleRows.isEmpty)

        model.apply(BotUIRowBatch(rows: [fresh], deletes: [], cursor: 4, reset: false))
        model.runtimeNotice = nil
        model.apply(BotUIRowBatch(rows: [fresh], deletes: [], cursor: 5, reset: false))
        XCTAssertNil(model.runtimeNotice, "an already-known notice is not reported again")
    }

    func testSendClearsRuntimeNotice() {
        let model = BotChatModel(context: BotRuntimeContext(botID: "main", botName: "大肥鱼"), fixtureActions: true)
        model.runtimeNotice = "Bot 实时更新失败：offline"
        model.send(text: "再试一次")
        XCTAssertNil(model.runtimeNotice)
    }

    func testRuntimeNoticeExpiresByItself() async throws {
        XCTAssertEqual(BotChatModel.runtimeNoticeLifetime, 6_000_000_000)
        let model = BotChatModel(context: BotRuntimeContext(botID: "main", botName: "大肥鱼"), fixtureActions: true)
        model.runtimeNotice = "历史加载失败：offline"
        try await Task.sleep(nanoseconds: BotChatModel.runtimeNoticeLifetime + 400_000_000)
        XCTAssertNil(model.runtimeNotice)
    }
}
