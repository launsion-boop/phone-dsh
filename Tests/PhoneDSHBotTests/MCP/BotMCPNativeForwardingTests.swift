// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

private struct StubNativeMCP: BotNativeMCPForwarding, Sendable {
    func handle(_ request: BotJSONValue, headers: [String: String]) async -> BotJSONValue? {
        let id = request["id"] ?? .null
        switch request["method"]?.stringValue {
        case "initialize":
            return .object([
                "jsonrpc": .string("2.0"), "id": id,
                "result": .object(["instructions": .string("native instructions")]),
            ])
        case "tools/list":
            return .object([
                "jsonrpc": .string("2.0"), "id": id,
                "result": .object(["tools": .array([
                    .object(["name": .string("android_connect"),
                             "description": .string("connect"),
                             "inputSchema": .object(["type": .string("object")])]),
                ])]),
            ])
        case "tools/call":
            return .object([
                "jsonrpc": .string("2.0"), "id": id,
                "result": .object([
                    "content": .array([.object(["type": .string("text"), "text": .string("native-ok")])]),
                    "isError": .bool(false),
                ]),
            ])
        default:
            return nil
        }
    }
}

final class BotMCPNativeForwardingTests: XCTestCase {
    func testBotAndNativeToolsShareOnePhoneEndpoint() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let handler = BotMCPHandler(runtime: fixture.runtime)
        await handler.attachNativeMCP(StubNativeMCP())

        let listed = await handler.rpc(method: "tools/list", params: .object([:]), id: .number(1))
        let tools = try XCTUnwrap(listed["result"]?["tools"]?.arrayValue)
        let names = tools.compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(names.contains("BotVolatileContext"))
        XCTAssertTrue(names.contains("android_connect"))
        XCTAssertEqual(Set(names).count, names.count)

        let initialized = await handler.rpc(
            method: "initialize", params: .object(["protocolVersion": .string("2025-06-18")]),
            id: .number(2))
        XCTAssertTrue(initialized["result"]?["instructions"]?.stringValue?.contains("native instructions") == true)
        XCTAssertEqual(initialized["result"]?["serverInfo"]?["name"], .string("phone"))

        // A native call needs no Bot identity registration; it is forwarded
        // unchanged to the native MCP handler.
        let native = await handler.rpc(
            method: "tools/call",
            params: .object(["name": .string("android_connect"),
                             "arguments": .object(["host": .string("192.0.2.1")])]),
            id: .string("native-call"))
        XCTAssertEqual(native["result"]?["content"]?.arrayValue?.first?["text"], .string("native-ok"))

        // A Bot tool still uses the registered claim path.
        let arguments = BotJSONValue.object([:])
        let registration = await handler.registerIdentity(.object([
            "runtimeId": .string(BotMCPRuntime.defaultRuntimeID), "sessionId": .string("gb-main"),
            "callId": .string("bot-call"), "name": .string("ListRoutines"),
            "argsDigest": .string(try BotArgumentsDigest.string(for: arguments)),
        ]))
        XCTAssertEqual(registration["ok"], .bool(true))
        let bot = await handler.rpc(
            method: "tools/call",
            params: .object(["name": .string("ListRoutines"), "arguments": arguments]),
            id: .string("bot-call"))
        XCTAssertNotNil(bot["result"]?["structuredContent"]?["count"])
    }

    func testHTTPEndpointListsAndCallsBothToolFamilies() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        let handler = BotMCPHandler(runtime: fixture.runtime)
        await handler.attachNativeMCP(StubNativeMCP())
        let server = BotMCPHTTPServer(handler: handler, token: "native-token")
        let url = try await server.start()
        defer { server.stop() }

        let listed = try await post(url, body: .object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/list"),
        ]), token: "native-token")
        let names = (listed["result"]?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(names.contains("android_connect"))
        XCTAssertTrue(names.contains("ask_user"))

        let native = try await post(url, body: .object([
            "jsonrpc": .string("2.0"), "id": .string("http-native"), "method": .string("tools/call"),
            "params": .object(["name": .string("android_connect"),
                               "arguments": .object(["host": .string("192.0.2.1")])]),
        ]), token: "native-token")
        XCTAssertEqual(native["result"]?["content"]?.arrayValue?.first?["text"], .string("native-ok"))

        let arguments = BotJSONValue.object([:])
        _ = await handler.registerIdentity(.object([
            "runtimeId": .string(BotMCPRuntime.defaultRuntimeID), "sessionId": .string("gb-main"),
            "callId": .string("http-bot"), "name": .string("ListRoutines"),
            "argsDigest": .string(try BotArgumentsDigest.string(for: arguments)),
        ]))
        let bot = try await post(url, body: .object([
            "jsonrpc": .string("2.0"), "id": .string("http-bot"), "method": .string("tools/call"),
            "params": .object(["name": .string("ListRoutines"), "arguments": arguments]),
        ]), token: "native-token")
        XCTAssertNotNil(bot["result"]?["structuredContent"]?["count"])
    }

    func testUnknownToolWithoutForwarderFailsClosed() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let handler = BotMCPHandler(runtime: fixture.runtime)
        let response = await handler.rpc(
            method: "tools/call",
            params: .object(["name": .string("android_connect"), "arguments": .object([:])]),
            id: .string("native"))
        XCTAssertEqual(response["error"]?["code"], .number(-32602))
    }

    private func post(_ url: URL, body: BotJSONValue, token: String) async throws -> BotJSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body.encoded()
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try BotJSONValue.parse(data)
    }
}
