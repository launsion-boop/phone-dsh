// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

/// S2 added the read-only `ReadMemory` primitive after the Worker's structural
/// approval table was written. The Worker then proposed an unknown effect for
/// it (alwaysScope=session) while the host classified it as a known read
/// (alwaysScope=until) and rejected the call with `stale:always_scope`. Both
/// readers are frozen as `read + auto` and must never produce an approval card.
final class BotReadMemoryApprovalTests: XCTestCase {
    private let cases: [(name: String, args: BotJSONValue)] = [
        ("ReadMemory", .object(["path": .string("user/profile.md")])),
        ("ReadMemory", .object(["path": .string("agent/notes"), "version": .number(2)])),
        ("RecallMemory", .object(["query": .string("tone"), "limit": .number(5)])),
    ]

    func testMemoryReadToolsAreReadAutoInBothSpellings() {
        for (name, args) in cases {
            for spelling in [name, "mcp__phone__\(name)"] {
                let effect = BotToolEffectClassifier.effect(for: spelling, arguments: args)
                XCTAssertEqual(effect.tool, name, spelling)
                XCTAssertEqual(effect.mutability, .read, spelling)
                XCTAssertEqual(effect.policy, .auto, spelling)
                XCTAssertTrue(effect.known, spelling)
                XCTAssertEqual(effect.isMcp, spelling.hasPrefix("mcp__"), spelling)
                XCTAssertEqual(BotToolEffectClassifier.policy(for: spelling, arguments: args),
                               .auto, spelling)
            }
        }
    }

    func testMemoryReadGoldenIsReadAutoForBothPrimitives() throws {
        let phone = try RowTestSupport.golden("tool-effects.phone")
        let readMemory = try goldenEntry(named: "ReadMemory", in: phone, where: "tool-effects.phone.valid")
        let upstream = try RowTestSupport.golden("tool-effects")
        let recallMemory = try goldenEntry(named: "RecallMemory", in: upstream, where: "tool-effects.valid")

        for entry in [readMemory, recallMemory] {
            XCTAssertEqual(entry["policy"] as? String, "auto")
            let expected = try RowTestSupport.decode(
                BotToolEffect.self, entry["effect"] as Any)
            XCTAssertEqual(expected.mutability, .read)
            XCTAssertEqual(expected.policy, .auto)
            XCTAssertTrue(expected.known)
            let actual = BotToolEffectClassifier.effect(
                for: try XCTUnwrap(entry["name"] as? String),
                arguments: try RowTestSupport.decode(BotJSONValue.self, entry["args"] as Any))
            XCTAssertEqual(actual, expected)
        }
    }

    func testHostAutoAllowsMemoryReadWithoutACard() async throws {
        let fixture = try makeBotMCPFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.runtime.issueSession(botId: "main", sessionId: "gb-main", kind: .chat)

        for (index, item) in cases.enumerated() {
            let callId = "memory-read-approval-\(index)"
            let digest = try BotArgumentsDigest.string(for: item.args)
            _ = try await fixture.runtime.registerIdentity(
                runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
                callId: callId, name: "mcp__phone__\(item.name)", arguments: item.args)
            let outcome = await fixture.runtime.approve(
                runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: "gb-main",
                callId: callId, name: "mcp__phone__\(item.name)",
                action: "Read memory", detail: "probe", command: "",
                argsDigest: digest, alwaysScope: "until", askAction: "tool-call")
            XCTAssertTrue(outcome.ok, "\(item.name): \(String(describing: outcome.message))")
            XCTAssertTrue(outcome.allowed, "\(item.name) must be auto-allowed")
            XCTAssertEqual(outcome.message, "auto-policy", item.name)
            XCTAssertNil(outcome.approvalId, "\(item.name) must not create a card")
        }
        let pending = await fixture.runtime.approvals.pendingIDs
        XCTAssertTrue(pending.isEmpty, "read-only memory tools left pending approvals: \(pending)")
    }

    private func goldenEntry(named name: String, in fixture: [String: Any],
                             where location: String) throws -> [String: Any] {
        let valid = try RowTestSupport.array(fixture["valid"], in: location)
        return try XCTUnwrap(valid.first { $0["name"] as? String == name },
                             "\(name) missing from \(location)")
    }
}
