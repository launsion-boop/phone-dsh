// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotGoldenVectorTests: XCTestCase {
    private struct Source: Decodable {
        let checkout: String
    }

    private struct ToolVector: Decodable {
        let schemaVersion: Int
        let vector: String
        let source: Source
        let valid: [Call]
        let invalid: [Call]
        let nativeMcp: [Call]?
    }

    private struct Call: Decodable {
        let name: String
        let args: BotJSONValue
        let policy: BotToolPolicy
        let effect: BotToolEffect
    }

    private struct ApprovalVector: Decodable {
        let schemaVersion: Int
        let vector: String
        let source: Source
        let valid: [ApprovalCall]
        let invalid: [ApprovalCall]
    }

    private struct ApprovalCall: Decodable {
        let tool: String
        let args: BotJSONValue
        let matches: [BotApprovalPatternMatch]
    }

    private struct ApprovalDowngradeVector: Decodable {
        let downgraded: [ApprovalCall]
    }

    func testToolEffectsSharedGolden() throws {
        // The upstream export keeps its Traditional Chinese labels; the
        // `.phone.json` overlay replaces only the localized display strings.
        // The classifier is a phone consumer, so it must match the merged view.
        let vector = try JSONDecoder().decode(
            ToolVector.self, from: BotGoldenFixture.mergedData("tool-effects"))
        XCTAssertEqual(vector.schemaVersion, 1)
        XCTAssertEqual(vector.vector, "tool-effects")
        XCTAssertEqual(vector.source.checkout, "bf4075b0a2e8092b04b726c59a7b085d5a37e6f6")
        XCTAssertEqual(vector.valid.count + vector.invalid.count, 28)
        for call in vector.valid + vector.invalid {
            let actual = BotToolEffectClassifier.effect(for: call.name, arguments: call.args, language: .zh)
            XCTAssertEqual(BotToolEffectClassifier.policy(for: call.name, arguments: call.args),
                           call.policy, "policy mismatch for \(call.name)")
            XCTAssertEqual(actual, call.effect, "effect mismatch for \(call.name)")
        }
    }

    func testToolEffectHandlesInt64BoundaryWithoutTrapping() {
        let effect = BotToolEffectClassifier.effect(for: "RecallMemory", arguments: .object([
            "limit": .number(9_223_372_036_854_775_808.0),
        ]))
        XCTAssertTrue(effect.detail.contains("limit="))
    }

    /// PR59's native-MCP BLE tools are classified by the same shared table so
    /// they never fall into `tool.unclassified`. The real authorization gate is
    /// PR59's per-connection grant; the Bot ask is an additional layer.
    func testBleNativeMcpEffectsMatchSharedGolden() throws {
        let vector = try JSONDecoder().decode(ToolVector.self, from: BotGoldenFixture.mergedData("tool-effects"))
        let entries = try XCTUnwrap(vector.nativeMcp)
        XCTAssertEqual(entries.map(\.name).sorted(), [
            "mcp__phone__ble_alert", "mcp__phone__ble_devices", "mcp__phone__ble_link_call",
            "mcp__phone__ble_link_result", "mcp__phone__ble_link_tools", "mcp__phone__ble_read",
        ])
        for call in entries {
            XCTAssertEqual(call.policy, .ask)
            let actual = BotToolEffectClassifier.effect(
                for: call.name, arguments: call.args, language: .zh)
            XCTAssertEqual(actual, call.effect, "BLE effect mismatch for \(call.name)")
            XCTAssertTrue(actual.known)
            XCTAssertTrue(actual.isMcp)
            XCTAssertNotEqual(actual.operation, "tool.unclassified")
        }
        let unknown = BotToolEffectClassifier.effect(for: "GenerateImage", arguments: .object([:]))
        XCTAssertFalse(unknown.known)
        XCTAssertEqual(unknown.operation, "tool.unclassified")
        XCTAssertEqual(unknown.policy, .ask)
    }

    func testApprovalPatternsSharedGolden() throws {
        let vector = try JSONDecoder().decode(ApprovalVector.self, from: golden("approval-patterns"))
        XCTAssertEqual(vector.schemaVersion, 1)
        XCTAssertEqual(vector.vector, "approval-patterns")
        XCTAssertEqual(vector.source.checkout, "bf4075b0a2e8092b04b726c59a7b085d5a37e6f6")
        XCTAssertEqual(vector.valid.count + vector.invalid.count, 6)
        let overlay = try JSONDecoder().decode(
            ApprovalDowngradeVector.self, from: golden("approval-patterns.phone"))
        let downgraded = Set(overlay.downgraded.map { call -> String in
            call.args["command"]?.stringValue ?? ""
        })
        XCTAssertEqual(downgraded.count, overlay.downgraded.count)
        for call in overlay.downgraded {
            let actual = BotApprovalPatternAnalyzer.analyze(
                tool: call.tool, arguments: call.args,
                workspace: "/tmp/phonedsh-bot-work", language: .en)
            XCTAssertEqual(actual, [], "network command pattern must be downgraded: \(call.args)")
        }
        // Upstream network cases are exactly the phone-downgraded cases; every
        // other upstream case keeps its shared semantics.
        for call in vector.valid + vector.invalid {
            let command = call.args["command"]?.stringValue ?? ""
            let actual = BotApprovalPatternAnalyzer.analyze(tool: call.tool, arguments: call.args,
                                                            workspace: "/tmp/phonedsh-bot-work",
                                                            language: .en)
            if downgraded.contains(command) {
                XCTAssertEqual(actual, [], "approval pattern mismatch for \(call.args)")
            } else {
                XCTAssertEqual(actual, call.matches, "approval pattern mismatch for \(call.args)")
            }
        }
    }

    private func golden(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("spec/bot/v1/golden/\(name).json"))
    }
}
