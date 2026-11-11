// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// P26 RecallMemory scope contract: an explicit scope searches only that
/// document root with the full limit; an unspecified scope searches both.
final class BotMCPMemoryRecallScopeTests: XCTestCase {
    func testExplicitAgentScopeUsesFullLimitInsteadOfFilteringMergedTopN() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        // Prime the grant snapshot before seeding durable memory events directly;
        // grant recovery requires a snapshot whenever the log is non-empty.
        _ = try await registerAndExecute(
            fixture.runtime, name: "RecallMemory", arguments: .object([:]))
        for index in 0..<6 {
            _ = try await seedDocument(
                makeDocument(
                    "agent/notes/coffee-\(index).md", "咖啡 agent \(index)",
                    updatedAtMS: 1_000 + Int64(index) * 2 + 1),
                store: fixture.store, botID: "main")
        }
        for index in 0..<6 {
            _ = try await seedDocument(
                makeDocument(
                    "user/notes/coffee-\(index).md", "咖啡 user \(index)",
                    updatedAtMS: 2_000 + Int64(index) * 2),
                store: fixture.store, botID: "main")
        }

        let agentResult = try await registerAndExecute(
            fixture.runtime, name: "RecallMemory",
            arguments: .object([
                "query": .string("咖啡"), "scope": .string("agent"), "limit": .number(4),
            ]))
        let agentHits = try XCTUnwrap(agentResult.structuredContent?["hits"]?.arrayValue)
        XCTAssertEqual(agentResult.structuredContent?["count"], .number(4))
        XCTAssertEqual(agentHits.count, 4)
        XCTAssertTrue(agentHits.allSatisfy { $0["scope"] == .string("agent") })

        let userResult = try await registerAndExecute(
            fixture.runtime, name: "RecallMemory",
            arguments: .object([
                "query": .string("咖啡"), "scope": .string("user"), "limit": .number(4),
            ]))
        let userHits = try XCTUnwrap(userResult.structuredContent?["hits"]?.arrayValue)
        XCTAssertEqual(userResult.structuredContent?["count"], .number(4))
        XCTAssertTrue(userHits.allSatisfy { $0["scope"] == .string("user") })

        let merged = try await registerAndExecute(
            fixture.runtime, name: "RecallMemory",
            arguments: .object(["query": .string("咖啡"), "limit": .number(7)]))
        let mergedHits = try XCTUnwrap(merged.structuredContent?["hits"]?.arrayValue)
        XCTAssertEqual(merged.structuredContent?["count"], .number(7))
        XCTAssertEqual(Set(mergedHits.compactMap { $0["scope"]?.stringValue }),
                       Set(["agent", "user"]))
        XCTAssertEqual(merged.structuredContent?["total"], .number(12))
        XCTAssertTrue(mergedHits.allSatisfy { $0["path"]?.stringValue?.hasSuffix("INDEX.md") == false })
    }
}
