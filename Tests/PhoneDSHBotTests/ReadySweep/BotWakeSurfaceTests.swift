// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Bot-side wake surfaces (PLAN §2.8): the channel hand-off and the local
/// listener hook. A signal is emitted only after the channel's durable write;
/// the hook fires only for an authorized `tools/call`.
final class BotWakeSurfaceTests: XCTestCase {
    func testWakeSourceDeliversSignalsInOrderAndStops() async {
        let source = BotChannelWakeSource()
        let log = WakeSignalLog()
        await source.start { signal in log.append(signal) }
        XCTAssertTrue(source.isInstalled)

        source.signal(botId: "bot-a", reason: BotChannelWakeSource.bleRequestReason, at: 10)
        source.signal(botId: "bot-a", reason: BotChannelWakeSource.lanRequestReason, at: 20)
        XCTAssertEqual(log.all, [
            WakeSignal(botId: "bot-a", reason: "bleRequest", at: 10),
            WakeSignal(botId: "bot-a", reason: "lanRequest", at: 20),
        ])

        await source.stop()
        source.signal(botId: "bot-a", reason: BotChannelWakeSource.bleRequestReason, at: 30)
        XCTAssertEqual(log.all.count, 2)
        XCTAssertFalse(source.isInstalled)
    }

    func testWakeSourceIgnoresIncompleteSignals() async {
        let source = BotChannelWakeSource()
        let log = WakeSignalLog()
        await source.start { signal in log.append(signal) }
        source.signal(botId: "", reason: BotChannelWakeSource.bleRequestReason, at: 10)
        source.signal(botId: "bot-a", reason: "", at: 20)
        XCTAssertTrue(log.all.isEmpty)
    }

    func testMCPHookFiresOncePerAuthorizedToolCallRequestOnly() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        let handler = BotMCPHandler(runtime: fixture.runtime)
        let server = BotMCPHTTPServer(handler: handler, token: "wake-token")
        let flag = WakeHookFlag()
        server.onToolCall = { flag.increment() }
        let mcp = try await server.start()
        defer { server.stop() }

        let toolCallStatus = try await post(mcp, token: "wake-token", body: Self.toolCall)
        XCTAssertEqual(toolCallStatus, 200)
        XCTAssertEqual(flag.count, 1)

        // initialize / ping / list never ask for a wake.
        let initializeStatus = try await post(mcp, token: "wake-token", body: Self.initialize)
        XCTAssertEqual(initializeStatus, 200)
        let pingStatus = try await post(mcp, token: "wake-token", body: Self.ping)
        XCTAssertEqual(pingStatus, 200)
        XCTAssertEqual(flag.count, 1)

        // An unauthenticated request never reaches the handler or the hook.
        let unauthorizedStatus = try await post(mcp, token: "wrong", body: Self.toolCall)
        XCTAssertEqual(unauthorizedStatus, 401)
        XCTAssertEqual(flag.count, 1)

        // A batch containing a tools/call still produces exactly one signal.
        let batchStatus = try await post(mcp, token: "wake-token", body: Self.batchToolCall)
        XCTAssertEqual(batchStatus, 200)
        XCTAssertEqual(flag.count, 2)
    }

    private func post(_ url: URL, token: String, body: String) async throws -> Int {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private static let toolCall = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}
        """
    private static let batchToolCall = """
        [{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}]
        """
    private static let initialize = """
        {"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}
        """
    private static let ping = """
        {"jsonrpc":"2.0","id":4,"method":"ping","params":{}}
        """
}

private final class WakeSignalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var signals: [WakeSignal] = []

    var all: [WakeSignal] { lock.withLock { signals } }
    func append(_ signal: WakeSignal) { lock.withLock { signals.append(signal) } }
}

private final class WakeHookFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
