// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// F1: a `tools/call` that arrives while the App is reattaching a replacement
/// Worker must wait only for the bounded readiness budget, then return a
/// human message. It must not hold the Worker's MCP client until the 130 s
/// client deadline (the observed `Request timed out`).
final class BotRuntimeReadinessTests: XCTestCase {
    func testRejectedReadinessReturnsHumanErrorQuickly() async throws {
        let fixture = try makeBotMCPFixture(taskExecutor: StubBotTaskExecutor())
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        await fixture.runtime.setRuntimeReadinessProbe(timeoutMilliseconds: 50) { _ in false }

        let started = Date()
        let result = try await registerAndExecute(fixture.runtime, name: "Task", arguments: .object([
            "task_title": .string("x"),
            "prompt": .string("y"),
        ]))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.structuredContent?["error"]?["code"], .string("unavailable"))
        XCTAssertTrue(result.structuredContent?["error"]?["message"]?.stringValue?
            .contains("与 App 的连接正在恢复，请稍后重试。") == true)
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testReadyRuntimeExecutesNormally() async throws {
        let fixture = try makeBotMCPFixture(taskExecutor: StubBotTaskExecutor())
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        await fixture.runtime.setRuntimeReadinessProbe(timeoutMilliseconds: 50) { _ in true }

        let result = try await registerAndExecute(fixture.runtime, name: "Task", arguments: .object([
            "task_title": .string("x"),
            "prompt": .string("y"),
        ]))
        XCTAssertNil(result.isError)
        XCTAssertNotNil(result.structuredContent?["task_id"]?.stringValue)
    }
}
