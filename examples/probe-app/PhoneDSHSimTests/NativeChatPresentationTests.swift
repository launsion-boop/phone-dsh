// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHAgentCore
import XCTest

final class NativeChatPresentationTests: XCTestCase {
    func testHistoryKeepsReasoningAndPairsToolResultByCallID() {
        let records = [
            event(1, "assistant/message", data: [
                "turn": .number(4), "step": .number(1),
                "message": .object([
                    "id": .string("message-4"),
                    "content": .array([
                        .object(["type": .string("reasoning"), "text": .string("先检查入口")]),
                        .object(["type": .string("text"), "text": .string("已经找到入口。")]),
                    ]),
                ]),
                "usage": .object([
                    "inputTokens": .number(100), "outputTokens": .number(20),
                    "cacheReadTokens": .number(60), "cacheWriteTokens": .number(10),
                ]),
            ]),
            event(2, "tool/call", data: [
                "turn": .number(4), "step": .number(1), "callId": .string("call-1"),
                "name": .string("bash"), "arguments": .string(#"{"command":"swift test","description":"运行测试"}"#),
            ]),
            event(3, "tool/result", data: [
                "turn": .number(4), "step": .number(1),
                "message": .object([
                    "source": .object(["callId": .string("call-1")]),
                    "content": .array([.object(["type": .string("text"), "text": .string("3 tests passed")])]),
                ]),
                "meta": .object(["exitCode": .number(0)]),
            ]),
        ]

        let items = NativeTranscriptProjector.items(from: records, sessionID: "session")

        XCTAssertEqual(items.map(\.kind), [.reasoning, .assistant, .toolCall])
        XCTAssertEqual(items[0].text, "先检查入口")
        XCTAssertEqual(items[1].messageID, "message-4")
        XCTAssertEqual(items[2].toolOutput, "3 tests passed")
        XCTAssertEqual(items[2].toolState, .ok)
        XCTAssertEqual(items[2].toolMetadata?["exitCode"]?.intValue, 0)
        let usage = NativeTranscriptProjector.usage(forTurn: 4, in: items)
        XCTAssertEqual(usage?.totalTokens, 190)
        XCTAssertEqual(usage?.cacheReadTokens, 60)
    }

    func testChangedFilesUseSuccessfulMutationsAndDeduplicatePaths() {
        let records = [
            event(1, "tool/call", data: [
                "turn": .number(2), "callId": .string("write"), "name": .string("write"),
                "arguments": .string(#"{"file_path":"notes/a.md","content":"one\ntwo"}"#),
            ]),
            event(2, "tool/result", data: [
                "turn": .number(2), "message": .object([
                    "source": .object(["callId": .string("write")]), "content": .array([]),
                ]),
            ]),
            event(3, "tool/call", data: [
                "turn": .number(2), "callId": .string("edit"), "name": .string("edit"),
                "arguments": .string(#"{"file_path":"notes/a.md","old_string":"one","new_string":"three"}"#),
            ]),
            event(4, "tool/result", data: [
                "turn": .number(2), "message": .object([
                    "source": .object(["callId": .string("edit")]), "content": .array([]),
                ]),
            ]),
        ]
        let items = NativeTranscriptProjector.items(from: records, sessionID: "session")

        let changes = NativeTranscriptProjector.changes(forTurn: 2, in: items)

        XCTAssertEqual(changes?.files.count, 1)
        XCTAssertEqual(changes?.files[0].path, "notes/a.md")
        XCTAssertEqual(changes?.files[0].oldText, "one")
        XCTAssertEqual(changes?.files[0].newText, "three")
    }

    func testToolSummaryAndFailureFollowOfficialArgumentsAndResult() {
        var item = ChatItem(id: "call", kind: .toolCall, title: "Tool call: bash", text: "")
        item.toolName = "bash"
        item.argumentsRaw = #"{"command":"swift test","description":"验证原生界面"}"#
        item.arguments = .object(["command": .string("swift test"), "description": .string("验证原生界面")])
        item.toolOutput = "编译失败\n详细错误"
        item.toolState = .error

        let model = NativeToolCallModel(item: item)

        XCTAssertEqual(model.title, "运行命令")
        XCTAssertEqual(model.summary, "编译失败")
        XCTAssertEqual(model.icon, .terminal)
        XCTAssertEqual(model.state, .error)
    }

    func testProjectionMetricsUseProviderBucketsWithoutDoubleCounting() throws {
        let usage = try XCTUnwrap(NativeTokenUsage(value: .object([
            "uncachedInputTokens": .number(100), "outputTokens": .number(40),
            "cacheReadTokens": .number(50), "cacheWriteTokens": .number(10),
        ])))
        XCTAssertEqual(usage.totalTokens, 200)
        XCTAssertEqual(usage.cacheHitPercent, 31.25)
        XCTAssertEqual(nativePercent(usage.cacheHitPercent), "31")
        XCTAssertEqual(nativeCompactTokens(198_000), "198K")
    }

    private func event(_ seq: Int, _ type: String, data: [String: JSONValue]) -> JSONValue {
        .object([
            "seq": .number(Double(seq)), "type": .string(type), "time": .number(1_700_000_000_000),
            "data": .object(data),
        ])
    }
}
