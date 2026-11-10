// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotFishActionEffectTests: XCTestCase {
    func testFishActionIsCosmeticAndAutoPolicy() {
        let effect = BotToolEffectClassifier.effect(
            for: "FishAction", arguments: .object(["action": .string("happy")]))
        XCTAssertEqual(effect.tool, "FishAction")
        XCTAssertEqual(effect.operation, "ui.FishAction")
        XCTAssertEqual(effect.mutability, .read)
        XCTAssertEqual(effect.policy, .auto)
        XCTAssertTrue(effect.ui)
        XCTAssertTrue(effect.known)
        XCTAssertFalse(effect.isMcp)
        XCTAssertNil(effect.execution)
        XCTAssertTrue(effect.detail.contains("action=happy"))

        XCTAssertEqual(BotToolEffectClassifier.policy(
            for: "mcp__phone__FishAction",
            arguments: .object(["action": .string("waving")])), .auto)
    }

    func testFishActionEffectGoldenMatchesTheRealClassifier() throws {
        let fixture = try RowTestSupport.golden("tool-effects.phone")
        let valid = try RowTestSupport.array(fixture["valid"], in: "tool-effects.phone.valid")
        let entry = try XCTUnwrap(valid.first { $0["name"] as? String == "FishAction" })
        XCTAssertEqual(entry["policy"] as? String, "auto")
        let expected = try RowTestSupport.decode(BotToolEffect.self, entry["effect"] as Any)
        let actual = BotToolEffectClassifier.effect(
            for: "FishAction",
            arguments: try RowTestSupport.decode(BotJSONValue.self, entry["args"] as Any))
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.mutability, .read)
        XCTAssertEqual(actual.policy, .auto)
    }

    func testFishActionToolCatalogGoldenMatchesTheRealDefinition() throws {
        let fixture = try RowTestSupport.golden("tool-catalog.phone")
        let fish = try RowTestSupport.object(fixture["fish"], in: "tool-catalog.phone.fish")
        XCTAssertEqual(fish["tools"] as? [String], [BotToolCatalog.fishActionName])
        XCTAssertEqual(fish["actions"] as? [String], BotToolCatalog.fishActions)
        XCTAssertEqual(fish["expressions"] as? [String], BotToolCatalog.fishExpressions)
        XCTAssertEqual(fish["required"] as? [String], ["action"])
        XCTAssertEqual(fish["properties"] as? [String], ["action"])

        let definition = try XCTUnwrap(BotToolCatalog.allDefinitions.first {
            $0.name == BotToolCatalog.fishActionName
        })
        for needle in fish["descriptionContains"] as? [String] ?? [] {
            XCTAssertTrue(definition.description.contains(needle), "missing description: \(needle)")
        }
        let result = BotFishActionTool()
        XCTAssertTrue(result.handles("mcp__phone__FishAction"))
    }
}
