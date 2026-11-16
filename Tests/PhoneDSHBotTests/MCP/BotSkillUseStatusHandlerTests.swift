// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// Focused coverage for the Bot-only gate lookup: the principal selects the
/// Bot, nil stays null (untracked), and a missing provenance install fails
/// closed. No skill bytes are read.
final class BotSkillUseStatusHandlerTests: XCTestCase {
    private func arguments(_ name: String) -> BotJSONValue {
        .object([
            "schema": .string("bot-skill-use-status/v1"),
            "name": .string(name),
        ])
    }

    func testCurrentAndUntrackedStatusByPrincipal() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(
            botId: "bot-a", sessionId: "gb-bot-a", kind: .chat)
        await beginUserTurn(fixture.runtime, sessionId: "gb-bot-a")
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
        let current = try await registerAndExecute(
            fixture.runtime, name: "BotSkillUseStatus",
            arguments: arguments("weekly-report"),
            sessionId: "gb-bot-a", callId: "skill-current")
        XCTAssertEqual(current.structuredContent?["status"], .string("current"),
                       "\(current)")

        let untracked = try await registerAndExecute(
            fixture.runtime, name: "BotSkillUseStatus",
            arguments: arguments("missing"),
            sessionId: "gb-bot-a", callId: "skill-untracked")
        XCTAssertEqual(untracked.structuredContent?["status"], .null,
                       "\(untracked)")
    }

    func testMissingProvenanceFailsClosed() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(
            botId: "bot-a", sessionId: "gb-bot-a", kind: .chat)
        await beginUserTurn(fixture.runtime, sessionId: "gb-bot-a")
        let result = try await registerAndExecute(
            fixture.runtime, name: "BotSkillUseStatus",
            arguments: arguments("weekly-report"),
            sessionId: "gb-bot-a", callId: "skill-no-service")
        XCTAssertEqual(result.structuredContent?["error"]?["code"],
                       .string("skill-provenance-unavailable"), "\(result)")
    }
}
