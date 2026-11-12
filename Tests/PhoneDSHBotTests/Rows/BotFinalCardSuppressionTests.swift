// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// P26 §2.9: a successful `final:true` content card makes the card the last
/// visible item of the turn. The host already suppresses
/// `conversation.assistant_message`; this projection is the App's second
/// durable read of the same session log and must use the same rule, otherwise
/// the suppressed sentence comes back from the raw JSONL after the turn ends.
final class BotFinalCardSuppressionTests: XCTestCase {
    private let projector = BotSessionLogProjector()

    private func project(_ events: [BotDSHSessionEvent]) -> [BotRow] {
        projector.project(botID: "main", sessionID: "gb-main",
                          sessionEvents: events, uiEvents: []).rows
    }

    private func textRows(_ rows: [BotRow]) -> [String] {
        rows.compactMap { row in
            guard row.body.type == .text, case .string(let text)? = row.body["text"] else { return nil }
            return text
        }
    }

    private func turnStart(seq: Int = 1, turn: Int = 1) -> BotDSHSessionEvent {
        BotDSHSessionEvent(type: "turn/start", seq: seq, time: 1_000,
                           data: ["turn": .number(Double(turn))])
    }

    private func assistant(seq: Int, text: String, turn: Int = 1) -> BotDSHSessionEvent {
        RowTestSupport.dshText(seq: seq, time: 1_000 + Int64(seq), role: "assistant",
                               text: text, turn: turn)
    }

    private func toolCall(seq: Int, name: String, arguments: String,
                          callID: String = "call-1", turn: Int = 1) -> BotDSHSessionEvent {
        BotDSHSessionEvent(type: "tool/call", seq: seq, time: 1_000 + Int64(seq), data: [
            "turn": .number(Double(turn)),
            "callId": .string(callID),
            "name": .string(name),
            "arguments": .string(arguments),
        ])
    }

    private func toolResult(seq: Int, callID: String = "call-1", failed: Bool = false,
                            text: String = "card sent", turn: Int = 1) -> BotDSHSessionEvent {
        var message: [String: BotJSONValue] = [
            "toolCallId": .string(callID),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ]
        if failed { message["isError"] = .bool(true) }
        return BotDSHSessionEvent(type: "tool/result", seq: seq, time: 1_000 + Int64(seq), data: [
            "turn": .number(Double(turn)),
            "message": .object(message),
        ])
    }

    private func turnEnd(seq: Int, turn: Int = 1) -> BotDSHSessionEvent {
        BotDSHSessionEvent(type: "turn/end", seq: seq, time: 1_000 + Int64(seq), data: [
            "turn": .number(Double(turn)),
            "reason": .object(["kind": .string("completed")]),
        ])
    }

    func testSuccessfulFinalCardSuppressesLaterAssistantText() {
        let rows = project([
            turnStart(seq: 1),
            assistant(seq: 2, text: "结论在卡片之前"),
            toolCall(seq: 3, name: "mcp__phone__show_progress",
                     arguments: #"{"title":"完成","final":true}"#),
            toolResult(seq: 4),
            assistant(seq: 5, text: "卡片之后不应显示"),
            turnEnd(seq: 6),
        ])
        XCTAssertEqual(textRows(rows), ["结论在卡片之前"])
    }

    func testFailedFinalCardKeepsLaterAssistantText() {
        let rows = project([
            turnStart(seq: 1),
            assistant(seq: 2, text: "结论"),
            toolCall(seq: 3, name: "mcp__phone__show_progress",
                     arguments: #"{"title":"失败","final":true}"#),
            toolResult(seq: 4, failed: true),
            assistant(seq: 5, text: "失败原因仍然要说"),
            turnEnd(seq: 6),
        ])
        XCTAssertEqual(textRows(rows), ["结论", "失败原因仍然要说"])
    }

    func testCardWithoutFinalKeepsLaterAssistantText() {
        let rows = project([
            turnStart(seq: 1),
            assistant(seq: 2, text: "进行中"),
            toolCall(seq: 3, name: "mcp__phone__show_progress",
                     arguments: #"{"title":"进度"}"#),
            toolResult(seq: 4),
            assistant(seq: 5, text: "卡后继续工作"),
            turnEnd(seq: 6),
        ])
        XCTAssertEqual(textRows(rows), ["进行中", "卡后继续工作"])
    }

    func testFinalFalseCardKeepsLaterAssistantText() {
        let rows = project([
            turnStart(seq: 1),
            assistant(seq: 2, text: "进行中"),
            toolCall(seq: 3, name: "mcp__phone__show_progress",
                     arguments: #"{"title":"进度","final":false}"#),
            toolResult(seq: 4),
            assistant(seq: 5, text: "卡后继续工作"),
            turnEnd(seq: 6),
        ])
        XCTAssertEqual(textRows(rows), ["进行中", "卡后继续工作"])
    }

    func testFinalCardSuppressionDoesNotCrossTheTurnBoundary() {
        let rows = project([
            turnStart(seq: 1),
            assistant(seq: 2, text: "第一轮结论"),
            toolCall(seq: 3, name: "mcp__phone__show_progress",
                     arguments: #"{"title":"完成","final":true}"#),
            toolResult(seq: 4),
            assistant(seq: 5, text: "第一轮收尾被压掉"),
            turnEnd(seq: 6),
            turnStart(seq: 7, turn: 2),
            assistant(seq: 8, text: "第二轮正文可见", turn: 2),
            turnEnd(seq: 9, turn: 2),
        ])
        XCTAssertEqual(textRows(rows), ["第一轮结论", "第二轮正文可见"])
    }

    func testAskUserStillSuppressesTrailingAssistantText() {
        let rows = project([
            turnStart(seq: 1),
            assistant(seq: 2, text: "先确认一下"),
            toolCall(seq: 3, name: "mcp__phone__ask_user",
                     arguments: #"{"question":"选哪个？","options":[{"id":"a","label":"A"},{"id":"b","label":"B"}]}"#),
            toolResult(seq: 4, text: "已显示提问卡；回合应在此结束，等待用户选择。"),
            assistant(seq: 5, text: "提问卡之后的正文"),
            turnEnd(seq: 6),
        ])
        XCTAssertEqual(textRows(rows), ["先确认一下"])
    }

    func testShowNextStepsStillSuppressesTrailingAssistantText() {
        let rows = project([
            turnStart(seq: 1),
            assistant(seq: 2, text: "建议如下"),
            toolCall(seq: 3, name: "mcp__phone__show_next_steps",
                     arguments: #"{"steps":[{"id":"a","label":"A"},{"id":"b","label":"B"}]}"#),
            toolResult(seq: 4, text: "已显示建议下一步卡片；回合应在此结束，等待用户选择。"),
            assistant(seq: 5, text: "建议卡之后的正文"),
            turnEnd(seq: 6),
        ])
        XCTAssertEqual(textRows(rows), ["建议如下"])
    }
}
