// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// A corrupt memory log must turn into a normal tool error the model can see.
/// It must never leave the turn waiting for a tool result, and the message is
/// user-facing: no error type, no raw `.corrupted` text and no internal code.
final class BotMCPMemoryFailureTests: XCTestCase {
    func testRecallMemoryReturnsHumanErrorWhenReplayFails() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(
            botId: "main", sessionId: "gb-main", kind: .chat)
        // Prime the memory authority and the grant snapshot before appending
        // the conflicting durable events.
        _ = try await registerAndExecute(
            fixture.runtime, name: "RecallMemory", arguments: .object([:]))

        let author = BotMemoryAuthor(botID: "main", sessionID: "gb-main", kind: .chat)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for (index, content) in ["first", "second"].enumerated() {
            var data: [String: BotJSONValue] = [
                "path": .string("agent/notes/conflict.md"),
                "scope": .string("agent"),
                "content": .string(content),
                "version": .number(1),
                "expected_version": .number(0),
                "updated_at_ms": .number(1_000),
                "evidence": .array([]),
                "trust": .string("assistant"),
            ]
            data["author"] = try BotJSONValue.parse(encoder.encode(author))
            let event = BotEvent(
                type: "memory.document_written",
                eventId: "memory-conflict-\(index)",
                time: 1_000,
                origin: .local(source: "memory-service"),
                traceId: "trace-memory-conflict-\(index)",
                principal: BotPrincipal(botId: "main", sessionId: nil, kind: "ipc"),
                causationId: nil,
                correlationId: nil,
                data: .object(data))
            _ = try await fixture.store.append(event)
        }

        let result = try await registerAndExecute(
            fixture.runtime, name: "RecallMemory",
            arguments: .object(["query": .string("anything")]))
        XCTAssertEqual(result.isError, true,
                       "a failed memory read must be a tool error, not a hang: \(result)")
        let error = result.structuredContent?["error"]
        XCTAssertEqual(error?["code"]?.stringValue, "memory_unavailable")
        let message = error?["message"]?.stringValue ?? ""
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains("corrupted"), message)
        XCTAssertFalse(message.contains("PhoneDSHBot."), message)
        XCTAssertFalse(message.contains("error 4"), message)
    }
}
