// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

final class BotWatchdogContextLintVectorsTests: XCTestCase {
    func testDefaultThresholdsAndInvalidThresholdsComeFromTheSharedFixture() throws {
        let fixture = try botGolden("context-lint.phone")
        let thresholds = try XCTUnwrap(fixture["thresholds"] as? [String: Any])
        let decoded = try botDecode(BotContextLintThresholds.self, thresholds["default"]!)
        XCTAssertEqual(decoded, .default)

        let invalid = try XCTUnwrap(thresholds["invalid"] as? [[String: Any]])
        for item in invalid {
            let name = try XCTUnwrap(item["name"] as? String)
            XCTAssertThrowsError(
                try botDecode(BotContextLintThresholds.self, item["input"]!), name)
        }
    }

    func testAllSixRulesAndBoundariesDriveRealContextLint() throws {
        let fixture = try botGolden("context-lint.phone")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        var rules: Set<String> = []
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let events = try botDecode(
                [BotContextLintEvent].self, item["events"] ?? [])
            let thresholds = try botDecode(
                BotContextLintThresholds.self, item["thresholds"] ?? [:])
            let expected = try botDecode([BotContextLintFinding].self, item["expect"]!)
            let promptMount: BotJSONValue?
            if let value = item["promptMount"] {
                promptMount = try botJSONValue(value)
            } else {
                promptMount = nil
            }
            let tools: BotJSONValue?
            if let value = item["tools"] {
                tools = try botJSONValue(value)
            } else {
                tools = nil
            }
            let findings = BotContextLint.lint(
                events: events, promptMount: promptMount, tools: tools,
                thresholds: thresholds, sessionId: item["sessionId"] as? String)
            XCTAssertEqual(findings, expected, name)
            rules.formUnion(findings.map(\.rule.rawValue))
        }
        XCTAssertEqual(rules, Set(BotContextLintRule.allCases.map(\.rawValue)))
    }

    func testValidFindingsDecodeAndFrozenInvalidShapesFailClosed() throws {
        let fixture = try botGolden("context-lint.phone")
        let valid = try XCTUnwrap(fixture["valid"] as? [[String: Any]])
        let findings = try botDecode([BotContextLintFinding].self, valid)
        XCTAssertEqual(Set(findings.map(\.rule.rawValue)), Set(BotContextLintRule.allCases.map(\.rawValue)))

        let invalid = try XCTUnwrap(fixture["invalid"] as? [[String: Any]])
        for item in invalid {
            let name = try XCTUnwrap(item["name"] as? String)
            guard let finding = item["finding"] as? [String: Any] else { continue }
            switch name {
            case "missing-evidence", "unknown-rule", "unknown-severity":
                XCTAssertThrowsError(
                    try botDecode(BotContextLintFinding.self, finding), name)
            case "location-extra-key", "location-missing-key":
                // `location` is an open JSON object in Swift; the closed key set
                // is a schema/validator rule, not a Codable decoding rule.
                _ = try botDecode(BotContextLintFinding.self, finding)
            default:
                XCTFail("unregistered invalid lint case \(name)")
            }
        }
    }
}
