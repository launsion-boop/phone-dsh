// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: G2-C05 annual-total oracle.

// Root cause this pins: G2-C05's expected active-subscription total is 1665
// (the cancelled gym card is excluded), but the old oracle was
// `file_contains: "1665"`. That is a literal substring check, so the correct
// artifact `1,665 元/年` was reported as a false failure even though the model
// produced the right number in a normal thousands-separated form. The catalog
// now uses the existing `file_regex` assertion with numeric boundaries; this
// test loads that exact assertion from the shipped catalog and exercises the
// production NSRegularExpression matcher (and the file assertion evaluator),
// never a second number parser.
//
// The `PhoneDSH` prefix keeps this test inside the CI gate filter
// `swift test --filter 'PhoneDSH|PhoneDSHShell'`.

import Foundation
import XCTest
@testable import PhoneDSHScenario

final class PhoneDSHScenarioNumericOracleTests: XCTestCase {
    /// The shipped assertion, not a copied pattern: pattern drift or a
    /// regression back to `file_contains` fails this test.
    private func c05AnnualTotalAssertion() throws -> Scenario.Assertion {
        let root = try XCTUnwrap(scenarioRepositoryRoot(
            startingAt: URL(fileURLWithPath: #filePath)))
        let catalog = try ScenarioCatalog.load(
            from: root.appendingPathComponent("scripts/ci/scenarios/catalog.json"))
        let scenario = try XCTUnwrap(catalog.scenarios.first { $0.id == "G2-C05" })
        return try XCTUnwrap(scenario.assertions.first {
            $0.type == "file_regex"
                && $0.path == "subscriptions.md"
                && ($0.value ?? "").contains("1665")
        }, "G2-C05 must carry the annual-total regex oracle")
    }

    func testAnnualTotalAcceptsEquivalentAmountsWithoutFormatCoupling() throws {
        let pattern = try XCTUnwrap(try c05AnnualTotalAssertion().value)
        let accepted = [
            // The form the real source284 run produced.
            "一年总共 1,665 元/年\n",
            // The same value without a thousands separator.
            "一年总共 1665 元\n",
            // Zero decimal places are still the same amount.
            "年度总计：1665.00 元\n",
            "年度总计：1,665.0 元\n",
            // The user did not require any particular label, emphasis,
            // currency spacing or table shape, so none of these may be
            // necessary for the oracle to pass.
            "汇总：1,665\n",
            "| 总计 | **1,665 元/年** |\n",
            "1,665 元/年\n",
        ]
        for document in accepted {
            XCTAssertTrue(try ScenarioFileContent.matches(pattern, in: document),
                          "expected the annual total to match: \(document)")
        }
    }

    func testAnnualTotalRejectsWrongAmountsAndEmbeddedSubstrings() throws {
        let pattern = try XCTUnwrap(try c05AnnualTotalAssertion().value)
        let rejected = [
            "一年总共 16650 元\n",
            "一年总共 11665 元\n",
            "一年总共 1,664 元\n",
            "一年总共 1665.01 元\n",
            "一年总共 11,665 元\n",
            "一年总共 1,6650 元\n",
            "一年总共 1665,000 元\n",
            "一年总共 21665 元\n",
            // The remaining correct summary fields must not stand in for the
            // missing annual total.
            "还在生效的订阅 6 个，平均每月 138.75 元。\n",
        ]
        for document in rejected {
            XCTAssertFalse(try ScenarioFileContent.matches(pattern, in: document),
                           "wrong amount or embedded substring matched: \(document)")
        }
    }

    func testAnnualTotalAssertionEvaluatesThroughTheScenarioEvaluator() throws {
        let assertion = try c05AnnualTotalAssertion()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-c05-numeric-oracle-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let subscriptions = workspace.appendingPathComponent("subscriptions.md")
        let evaluator = ScenarioAssertionEvaluator(
            workspace: workspace,
            resultsDirectory: root,
            turnStartedCount: 3,
            deliveredTurnCount: 3,
            modelRequests: 16,
            consoleErrors: [],
            restartRecovered: nil,
            redactor: ScenarioRedactor())

        try Data("汇总\n\n- 年总花费：1,665 元/年\n".utf8)
            .write(to: subscriptions)
        let passed = try XCTUnwrap(
            evaluator.reports(for: [assertion], completion: .completed).first)
        XCTAssertTrue(passed.ok, passed.detail)
        XCTAssertNil(passed.failure)

        try Data("汇总\n\n- 年总花费：1,664 元/年\n".utf8)
            .write(to: subscriptions)
        let failed = try XCTUnwrap(
            evaluator.reports(for: [assertion], completion: .completed).first)
        XCTAssertFalse(failed.ok, failed.detail)
        XCTAssertEqual(failed.failure?.kind, ScenarioAssertionFailure.Kind.notMatch)
    }
}
