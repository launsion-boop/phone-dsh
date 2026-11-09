// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// P26 RecallMemory scope contract: an explicit scope searches only that store
/// with the full limit (upstream dshAgent.cjs), while an unspecified scope keeps
/// the merged result with a reserved slot for the missing scope.
final class BotMCPMemoryRecallScopeTests: XCTestCase {
    func testExplicitAgentScopeUsesFullLimitInsteadOfFilteringMergedTopN() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)
        // Prime the grant snapshot before seeding durable memory events directly;
        // grant recovery requires a snapshot whenever the log is non-empty.
        _ = try await registerAndExecute(
            fixture.runtime, name: "RecallMemory", arguments: .object([:]))
        let store = SQLiteBotMemoryFactStore(eventLog: fixture.store, botID: "main", now: { 1_000 })
        for index in 0..<6 {
            try await store.append(makeMemoryFact(
                "agent-\(index)", "咖啡 agent \(index)",
                learnedAtMS: 1_000 + Int64(index), importance: 0.1))
        }
        for index in 0..<6 {
            try await store.append(makeMemoryFact(
                "user-\(index)", "咖啡 user \(index)", scope: .user,
                learnedAtMS: 1_000 + Int64(index), importance: 1.0))
        }

        let agentResult = try await registerAndExecute(
            fixture.runtime, name: "RecallMemory",
            arguments: .object([
                "query": .string("咖啡"), "scope": .string("agent"), "limit": .number(4),
            ]))
        let agentFacts = try XCTUnwrap(agentResult.structuredContent?["facts"]?.arrayValue)
        XCTAssertEqual(agentResult.structuredContent?["count"], .number(4))
        XCTAssertEqual(agentFacts.count, 4)
        XCTAssertTrue(agentFacts.allSatisfy { $0["scope"] == .string("agent") })

        let userResult = try await registerAndExecute(
            fixture.runtime, name: "RecallMemory",
            arguments: .object([
                "query": .string("咖啡"), "scope": .string("user"), "limit": .number(4),
            ]))
        let userFacts = try XCTUnwrap(userResult.structuredContent?["facts"]?.arrayValue)
        XCTAssertEqual(userResult.structuredContent?["count"], .number(4))
        XCTAssertTrue(userFacts.allSatisfy { $0["scope"] == .string("user") })

        // Unspecified scope keeps the upstream merge: shared user facts
        // outrank here, but the last slot is reserved for the agent scope.
        let merged = try await registerAndExecute(
            fixture.runtime, name: "RecallMemory",
            arguments: .object(["query": .string("咖啡"), "limit": .number(4)]))
        let mergedFacts = try XCTUnwrap(merged.structuredContent?["facts"]?.arrayValue)
        XCTAssertEqual(merged.structuredContent?["count"], .number(4))
        XCTAssertEqual(Set(mergedFacts.compactMap { $0["scope"]?.stringValue }),
                       Set(["agent", "user"]))
    }
}
