// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Focused coverage for the Bot-only gate lookup: the principal selects the
/// Bot, nil stays null (untracked), and a missing provenance install fails
/// closed. No skill bytes are read.
final class BotSkillUseStatusHandlerTests: XCTestCase {
    private func call(_ handler: BotMCPHandler, session: String, callID: String,
                      name: String) async -> BotJSONValue {
        let arguments = BotJSONValue.object([
            "schema": .string("bot-skill-use-status/v1"),
            "name": .string(name),
        ])
        return await handler.rpc(
            method: "tools/call",
            params: .object(["name": .string("BotSkillUseStatus"),
                             "arguments": arguments]),
            id: .string(callID))
    }

    func testCurrentAndUntrackedStatusByPrincipal() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(
            botId: "bot-a", sessionId: "gb-bot-a", kind: .chat)
        await beginUserTurn(fixture.runtime)
        let token = try await fixture.runtime.issueSessionToken(
            botId: "bot-a", sessionId: "gb-bot-a", kind: .chat)
        let service = BotProvenanceService(eventLog: fixture.store)
        await fixture.runtime.installProvenance(service)
        _ = try await service.recordSkillWrite(BotSkillWriteRequest(
            name: "weekly-report", file: "weekly-report.md", revision: 1,
            action: .write,
            contentSHA256: "sha256:" + String(repeating: "a", count: 64),
            bytes: 18, previousSHA256: nil,
            author: BotSkillChangeAuthor(kind: "bot", botID: "bot-a",
                                         sessionID: "gb-bot-a"),
            atMS: 2_000, sources: [], source: .projectDsh,
            ownerBotID: "bot-a"))
        let handler = BotMCPHandler(runtime: fixture.runtime)
        let arguments = BotJSONValue.object([
            "schema": .string("bot-skill-use-status/v1"),
            "name": .string("weekly-report"),
        ])
        let registration = await handler.registerIdentity(.object([
            "runtimeId": .string(BotMCPRuntime.defaultRuntimeID),
            "sessionId": .string("gb-bot-a"), "callId": .string("skill-current"),
            "name": .string("BotSkillUseStatus"),
            "argsDigest": .string(try BotArgumentsDigest.string(for: arguments)),
            "sessionToken": .string(token.token),
        ]))
        XCTAssertEqual(registration["ok"], .bool(true))
        let current = await call(handler, session: "gb-bot-a",
                                 callID: "skill-current", name: "weekly-report")
        XCTAssertEqual(current["result"]?["structuredContent"]?["status"],
                       .string("current"), "\(current)")

        let untracked = await call(handler, session: "gb-bot-a",
                                   callID: "skill-untracked", name: "missing")
        XCTAssertEqual(untracked["result"]?["structuredContent"]?["status"], .null,
                       "\(untracked)")
    }

    func testMissingProvenanceFailsClosed() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(
            botId: "bot-a", sessionId: "gb-bot-a", kind: .chat)
        await beginUserTurn(fixture.runtime)
        let handler = BotMCPHandler(runtime: fixture.runtime)
        let result = await call(handler, session: "gb-bot-a",
                                callID: "skill-no-service", name: "weekly-report")
        let text = result["error"]?["message"]?.stringValue ?? ""
        XCTAssertTrue(result["result"]?["structuredContent"]?["error"]?["code"]
            == .string("skill-provenance-unavailable"), "\(result)")
    }
}
