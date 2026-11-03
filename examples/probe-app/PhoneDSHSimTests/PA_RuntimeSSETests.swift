// SPDX-License-Identifier: MIT

import XCTest
import ProbeKit

final class PA_RuntimeSSETests: XCTestCase {
    func testByteByByteFragmentationCRLFCommentsAndToolJSON() throws {
        func sse(_ event: String, _ payload: [String: Any]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return "event: \(event)\r\ndata: \(String(decoding: data, as: UTF8.self))\r\n\r\n"
        }
        let sse = try [
            ": keepalive\r\n",
            sse("message_start", ["type": "message_start"]),
            sse("content_block_start", ["type": "content_block_start", "index": 0,
                                        "content_block": ["type": "text", "text": ""]]),
            sse("content_block_delta", ["type": "content_block_delta", "index": 0,
                                        "delta": ["type": "text_delta", "text": "你好"]]),
            sse("content_block_stop", ["type": "content_block_stop", "index": 0]),
            sse("content_block_start", ["type": "content_block_start", "index": 1,
                                        "content_block": ["type": "tool_use", "id": "toolu_1",
                                                          "name": "github_pull_get", "input": [:]]]),
            sse("content_block_delta", ["type": "content_block_delta", "index": 1,
                                        "delta": ["type": "input_json_delta", "partial_json": "{\"number\":"]]),
            sse("content_block_delta", ["type": "content_block_delta", "index": 1,
                                        "delta": ["type": "input_json_delta", "partial_json": "42}"]]),
            sse("content_block_stop", ["type": "content_block_stop", "index": 1]),
            sse("future_extension", ["type": "future_extension"]),
            sse("ping", ["type": "ping"]),
            sse("message_delta", ["type": "message_delta", "delta": ["stop_reason": "tool_use"]]),
            sse("message_stop", ["type": "message_stop"]),
        ].joined()
        var parser = AnthropicSSEParser()
        var accumulator = AnthropicResponseAccumulator()
        for byte in Data(sse.utf8) {
            for event in try parser.consume(Data([byte])) { try accumulator.apply(event) }
        }
        for event in try parser.finish() { try accumulator.apply(event) }
        try accumulator.validated()
        XCTAssertEqual(accumulator.text, "你好")
        XCTAssertEqual(accumulator.stopReason, "tool_use")
        XCTAssertEqual(accumulator.toolUses.map(\.inputJSON), ["{\"number\":42}"])
        XCTAssertEqual(parser.unknownEventCount, 1)
        XCTAssertEqual(accumulator.unknownEventCount, 1)
    }

    func testProviderErrorEventMapsToMainFailure() throws {
        var parser = AnthropicSSEParser()
        let data = Data("event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\"}}\n\n".utf8)
        let events = try parser.consume(data)
        var accumulator = AnthropicResponseAccumulator()
        XCTAssertThrowsError(try accumulator.apply(events[0])) { error in
            XCTAssertEqual(error as? MainFailure, .provider("busy"))
        }
    }

    func testUnexpectedEOFInEventAndBeforeMessageStop() throws {
        var parser = AnthropicSSEParser()
        _ = try parser.consume(Data("event: message_stop\ndata: {\"type\":\"message_stop\"}".utf8))
        XCTAssertThrowsError(try parser.finish())

        var completeParser = AnthropicSSEParser()
        _ = try completeParser.consume(Data("event: message_start\ndata: {\"type\":\"message_start\"}\n\n".utf8))
        _ = try completeParser.finish()
        var accumulator = AnthropicResponseAccumulator()
        try accumulator.apply(.messageStart)
        XCTAssertThrowsError(try accumulator.validated()) { error in
            guard case .provider(let message) = error as? MainFailure else {
                return XCTFail("expected recoverable provider failure, got \(error)")
            }
            XCTAssertTrue(message.contains("unexpected EOF"))
        }
    }

    func testMessagesRequestConstruction() throws {
        let context = MainAssembledContext(systemPrompt: "system rules",
                                           messages: [.text("hello")], estimatedTokens: 4,
                                           tokenEstimationMethod: "test", recentMessages: [],
                                           rollingSummary: nil)
        let request = AnthropicMessagesAdapter().makeRequest(
            model: "deepseek-flash", context: context,
            tools: [AnthropicTool(name: "github_pull_get", description: "Read PR",
                                  inputSchemaJSON: "{\"type\":\"object\"}")],
            toolChoice: .auto, maxTokens: 1_234)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.bodyData()) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "deepseek-flash")
        XCTAssertEqual(object["system"] as? String, "system rules")
        XCTAssertEqual(object["max_tokens"] as? Int, 1_234)
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual((object["tool_choice"] as? [String: Any])?["type"] as? String, "auto")
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "github_pull_get")
        XCTAssertNotNil(tools.first?["input_schema"])
    }
}
