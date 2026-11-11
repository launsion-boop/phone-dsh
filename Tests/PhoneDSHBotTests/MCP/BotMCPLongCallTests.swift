// SPDX-License-Identifier: MIT
// spec/bot/v1/mcp-endpoint.md §2 "Long tool calls": the shared cases judge the real
// decision, and real HTTP against the real listener checks the framing: a slow native
// tool is answered as SSE (head, keepalives, one message event), a fast one stays JSON.

import Foundation
import XCTest
@testable import PhoneDSHBot

private struct DelayedNativeMCP: BotNativeMCPForwarding, Sendable {
    let delay: Duration

    func handle(_ request: BotJSONValue, headers: [String: String]) async -> BotJSONValue? {
        let id = request["id"] ?? .null
        switch request["method"]?.stringValue {
        case "tools/list":
            return .object([
                "jsonrpc": .string("2.0"), "id": id,
                "result": .object(["tools": .array([
                    .object(["name": .string("iphone_agent_run"), "description": .string("ui task"),
                             "inputSchema": .object(["type": .string("object")])]),
                ])]),
            ])
        case "tools/call":
            try? await Task.sleep(for: delay)
            return .object([
                "jsonrpc": .string("2.0"), "id": id,
                "result": .object([
                    "content": .array([.object(["type": .string("text"), "text": .string("opened settings")])]),
                    "isError": .bool(false),
                ]),
            ])
        default:
            return nil
        }
    }
}

final class BotMCPLongCallTests: XCTestCase {
    private func cases() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("spec/v1/golden/mcp-long-call/cases.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testConstantsMatchTheServer() throws {
        let c = try XCTUnwrap(try cases()["constants"] as? [String: Any])
        XCTAssertEqual(c["stream_after_ms"] as? Int, 5000)
        XCTAssertEqual(BotMCPHTTPServer.LongCallTiming.standard.streamAfter, .milliseconds(c["stream_after_ms"] as! Int))
        XCTAssertEqual(BotMCPHTTPServer.LongCallTiming.standard.keepaliveInterval, .milliseconds(c["keepalive_interval_ms"] as! Int))
        XCTAssertEqual(String(decoding: BotMCPHTTPServer.keepaliveBytes, as: UTF8.self), c["keepalive_bytes"] as? String)
    }

    func testDecisionTable() throws {
        let decisions = try XCTUnwrap(try cases()["decisions"] as? [[String: Any]])
        for item in decisions {
            let streams = BotMCPHTTPServer.streamsLongCall(method: item["method"] as! String,
                                                           batch: item["batch"] as! Bool,
                                                           accept: item["accept"] as? String)
            // A fast call never reaches the stream branch's deadline, so it stays JSON either way.
            let expected = (item["slow"] as! Bool) && streams ? "stream" : "json"
            XCTAssertEqual(expected, item["expect"] as? String, item["name"] as? String ?? "")
        }
    }

    // MARK: - Real HTTP

    private func server(delay: Duration) async throws -> (BotMCPHTTPServer, URL, BotMCPTestFixture) {
        let fixture = try makeBotMCPFixture()
        let handler = BotMCPHandler(runtime: fixture.runtime)
        await handler.attachNativeMCP(DelayedNativeMCP(delay: delay))
        let server = BotMCPHTTPServer(handler: handler, token: "test-token-1234567890",
                                      longCallTiming: .init(streamAfter: .milliseconds(200),
                                                            keepaliveInterval: .milliseconds(150)))
        return (server, try await server.start(), fixture)
    }

    private func call(_ url: URL, token: String, accept: String?) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        request.httpBody = try BotJSONValue.object([
            "jsonrpc": .string("2.0"), "id": .string("long-1"), "method": .string("tools/call"),
            "params": .object(["name": .string("iphone_agent_run"), "arguments": .object(["task": .string("open settings")])]),
        ]).encoded()
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse), data)
    }

    func testSlowCallIsStreamedWithKeepalivesThenOneMessage() async throws {
        let (server, url, fixture) = try await server(delay: .milliseconds(700))
        defer { server.stop(); fixture.cleanup() }
        let (response, data) = try await call(url, token: server.token, accept: "application/json, text/event-stream")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        XCTAssertNotNil(response.value(forHTTPHeaderField: "Mcp-Session-Id"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertGreaterThanOrEqual(text.components(separatedBy: ": keepalive\n\n").count - 1, 1, text)
        let parts = text.components(separatedBy: "event: message\ndata: ")
        XCTAssertEqual(parts.count, 2, "exactly one message event: \(text)")
        XCTAssertTrue(parts[0].replacingOccurrences(of: ": keepalive\n\n", with: "").isEmpty, "only keepalives before it")
        XCTAssertTrue(parts[1].hasSuffix("\n\n"))
        let message = try BotJSONValue.parse(Data(parts[1].dropLast(2).utf8))
        XCTAssertEqual(message["id"], .string("long-1"))
        XCTAssertEqual(message["result"]?["content"]?.arrayValue?.first?["text"], .string("opened settings"))
        XCTAssertFalse(parts[1].dropLast(2).contains("\n"), "the JSON-RPC response is one data line")
    }

    func testFastCallStaysJSON() async throws {
        let (server, url, fixture) = try await server(delay: .zero)
        defer { server.stop(); fixture.cleanup() }
        let (response, data) = try await call(url, token: server.token, accept: "application/json, text/event-stream")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(try BotJSONValue.parse(data)["id"], .string("long-1"))
    }

    func testClientWithoutSSEWaitsForJSON() async throws {
        let (server, url, fixture) = try await server(delay: .milliseconds(500))
        defer { server.stop(); fixture.cleanup() }
        let (response, data) = try await call(url, token: server.token, accept: "application/json")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(try BotJSONValue.parse(data)["result"]?["content"]?.arrayValue?.first?["text"], .string("opened settings"))
    }
}
