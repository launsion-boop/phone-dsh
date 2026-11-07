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
        let hostExtensions: [Call]?
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

    func testToolEffectsSharedGolden() throws {
        let vector = try JSONDecoder().decode(ToolVector.self, from: golden("tool-effects"))
        XCTAssertEqual(vector.schemaVersion, 1)
        XCTAssertEqual(vector.vector, "tool-effects")
        XCTAssertEqual(vector.source.checkout, "bf4075b0a2e8092b04b726c59a7b085d5a37e6f6")
        XCTAssertEqual(vector.valid.count + vector.invalid.count, 23)
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

    /// R2: ReplyToDevice is a known host extension in the pure argument
    /// classifier; the concrete device id is resolved before execution.
    func testReplyToDeviceHostExtensionMatchesSharedGolden() throws {
        let vector = try JSONDecoder().decode(ToolVector.self, from: golden("tool-effects"))
        let extensions = try XCTUnwrap(vector.hostExtensions)
        XCTAssertEqual(extensions.map(\.name), [BotToolCatalog.deviceReplyName])
        for call in extensions {
            let actual = BotToolEffectClassifier.effect(
                for: call.name, arguments: call.args, language: .zh)
            XCTAssertEqual(actual, call.effect, "host extension mismatch for \(call.name)")
            XCTAssertTrue(actual.known)
            XCTAssertEqual(actual.resource, "device:*")
            XCTAssertEqual(actual.execution, "device-reply")
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
        for call in vector.valid + vector.invalid {
            let actual = BotApprovalPatternAnalyzer.analyze(tool: call.tool, arguments: call.args,
                                                            workspace: "/tmp/phonedsh-bot-work",
                                                            language: .en)
            XCTAssertEqual(actual, call.matches, "approval pattern mismatch for \(call.args)")
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
