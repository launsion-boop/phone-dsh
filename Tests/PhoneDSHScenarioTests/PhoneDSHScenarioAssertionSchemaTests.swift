// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: strict assertion schema tests.
//
// Root cause (G2-FIX-51): `Scenario.Assertion` used the default `Decodable`,
// so a misspelled bound key such as `"3": 0` decoded to `max == nil` and the
// evaluators substituted `Int.max`, turning the check into a silent no-op that
// reported `ok: true`. These tests pin the load-time schema: unknown keys,
// missing required keys and unknown assertion types fail the catalog load with
// an error naming the scenario id, assertion index, type and key.

import Foundation
import XCTest
@testable import PhoneDSHScenario

final class PhoneDSHScenarioAssertionSchemaTests: XCTestCase {
    // MARK: - Fixtures

    private func scenarioDocument(id: String,
                                  assertions: [[String: Any]]) -> [String: Any] {
        [
            "id": id,
            "category": "files",
            "title": "schema fixture",
            "user_story": "schema fixture",
            "workspace": ["files": [String: String]()],
            "turns": [["prompt": "hello"]],
            "assertions": assertions,
            "budget": ["max_minutes": 1, "max_model_requests": 2],
            "tags": ["files"],
            "target": "macos",
        ]
    }

    private func writeCatalog(_ scenarios: [[String: Any]]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-scenario-schema-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog.json")
        let document: [String: Any] = ["version": 1, "scenarios": scenarios]
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        return url
    }

    /// Returns the load error text, or `nil` when the catalog loaded. The
    /// pre-fix tree returns `nil` for every call below, which is the defect.
    private func loadError(_ url: URL) -> String? {
        do {
            _ = try ScenarioCatalog.load(from: url)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    // MARK: - Load-time fail loud

    func testUnknownAssertionKeyFailsCatalogLoad() throws {
        let url = try writeCatalog([
            scenarioDocument(id: "G2-SCHEMA-UNKNOWN", assertions: [
                ["type": "file_exists", "path": "a.txt"],
                ["type": "turn_count_lte", "3": 0],
            ]),
        ])
        let error = try XCTUnwrap(loadError(url),
                                  "a misspelled assertion key decoded silently")
        XCTAssertTrue(error.contains("G2-SCHEMA-UNKNOWN"), error)
        XCTAssertTrue(error.contains("assertion[1]"), error)
        XCTAssertTrue(error.contains("turn_count_lte"), error)
        XCTAssertTrue(error.contains("\"3\""), error)
    }

    func testMissingTurnCountBoundFailsCatalogLoad() throws {
        let url = try writeCatalog([
            scenarioDocument(id: "G2-SCHEMA-TURN", assertions: [
                ["type": "turn_count_lte"],
            ]),
        ])
        let error = try XCTUnwrap(loadError(url),
                                  "turn_count_lte without max decoded silently")
        XCTAssertTrue(error.contains("G2-SCHEMA-TURN"), error)
        XCTAssertTrue(error.contains("assertion[0]"), error)
        XCTAssertTrue(error.contains("turn_count_lte"), error)
        XCTAssertTrue(error.contains("max"), error)
    }

    func testMissingModelRequestBoundFailsCatalogLoad() throws {
        let url = try writeCatalog([
            scenarioDocument(id: "G2-SCHEMA-MODEL", assertions: [
                ["type": "model_requests_lte"],
            ]),
        ])
        let error = try XCTUnwrap(loadError(url),
                                  "model_requests_lte without max decoded silently")
        XCTAssertTrue(error.contains("G2-SCHEMA-MODEL"), error)
        XCTAssertTrue(error.contains("assertion[0]"), error)
        XCTAssertTrue(error.contains("model_requests_lte"), error)
        XCTAssertTrue(error.contains("max"), error)
    }

    func testMissingRequiredKeyForFileAssertionFailsCatalogLoad() throws {
        // A missing `value` makes `file_contains`/`file_regex` match
        // everything, so it is the same silent-pass class as a missing `max`.
        let url = try writeCatalog([
            scenarioDocument(id: "G2-SCHEMA-VALUE", assertions: [
                ["type": "file_contains", "path": "a.txt"],
            ]),
        ])
        let error = try XCTUnwrap(loadError(url),
                                  "file_contains without value decoded silently")
        XCTAssertTrue(error.contains("G2-SCHEMA-VALUE"), error)
        XCTAssertTrue(error.contains("assertion[0]"), error)
        XCTAssertTrue(error.contains("file_contains"), error)
        XCTAssertTrue(error.contains("value"), error)
    }

    func testUnknownAssertionTypeFailsCatalogLoad() throws {
        let url = try writeCatalog([
            scenarioDocument(id: "G2-SCHEMA-TYPE", assertions: [
                ["type": "turn_count_lt", "max": 3],
            ]),
        ])
        let error = try XCTUnwrap(loadError(url),
                                  "an unknown assertion type decoded silently")
        XCTAssertTrue(error.contains("G2-SCHEMA-TYPE"), error)
        XCTAssertTrue(error.contains("assertion[0]"), error)
        XCTAssertTrue(error.contains("turn_count_lt"), error)
    }

    // MARK: - No widening

    func testShippedCatalogAndSelftestStillLoad() throws {
        let root = try XCTUnwrap(scenarioRepositoryRoot(
            startingAt: URL(fileURLWithPath: #filePath)))
        let catalog = try ScenarioCatalog.load(
            from: root.appendingPathComponent("scripts/ci/scenarios/catalog.json"))
        XCTAssertFalse(catalog.scenarios.isEmpty)
        XCTAssertLessThanOrEqual(catalog.scenarios.count, ScenarioSlotPlan.slotCount)
        let selftest = try ScenarioCatalog.load(
            from: root.appendingPathComponent("scripts/ci/scenarios/selftest.json"))
        XCTAssertFalse(selftest.scenarios.isEmpty)

        // The only data change for G2-FIX-51: the mistyped `"3": 0` bound is
        // now the real `max: 3`, and the strict schema accepts it.
        let e09 = try XCTUnwrap(catalog.scenarios.first { $0.id == "G2-E09" })
        let bound = try XCTUnwrap(e09.assertions.first { $0.type == "turn_count_lte" })
        XCTAssertEqual(bound.max, 3,
                       "G2-E09's turn_count_lte bound must be present and 3")
    }

    // MARK: - Evaluation unchanged for a valid bound

    func testValidBoundEvaluatesExactlyAsBefore() throws {
        let valid = try decodeAssertion(#"{"type":"turn_count_lte","max":3}"#)
        let atLimit = try ScenarioCountBound.verdict(count: 3, assertion: valid)
        XCTAssertEqual(atLimit.maximum, 3)
        XCTAssertTrue(atLimit.ok)
        let overLimit = try ScenarioCountBound.verdict(count: 4, assertion: valid)
        XCTAssertEqual(overLimit.maximum, 3)
        XCTAssertFalse(overLimit.ok)

        // A missing bound cannot reach evaluation as `Int.max`; it throws.
        for type in ["turn_count_lte", "model_requests_lte"] {
            let missing = try decodeAssertion(#"{"type":"\#(type)"}"#)
            XCTAssertThrowsError(
                try ScenarioCountBound.verdict(count: 0, assertion: missing),
                "\(type) without max must not evaluate against Int.max")
        }
    }

    // MARK: - Typed failure evidence (G2-FIX-77)

    private func scratchWorkspace() throws -> (workspace: URL, results: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-assertion-failure-\(UUID().uuidString)",
                                    isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let results = root.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: results,
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (workspace, results)
    }

    func testFailedFileExistsCarriesStructuredFailureAndReadableDetail() throws {
        let paths = try scratchWorkspace()
        let evaluator = ScenarioAssertionEvaluator(
            workspace: paths.workspace,
            resultsDirectory: paths.results,
            turnStartedCount: 0,
            deliveredTurnCount: 0,
            modelRequests: 0,
            consoleErrors: [],
            restartRecovered: nil,
            redactor: ScenarioRedactor())
        let assertion = try decodeAssertion(#"{"type":"file_exists","path":"missing.txt"}"#)
        let report = try XCTUnwrap(
            evaluator.reports(for: [assertion], completion: .completed).first)
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.detail, "missing: missing.txt",
                       "the human-readable detail stays")
        XCTAssertEqual(report.failure?.kind, .missing)
        XCTAssertEqual(report.failure?.path, "missing.txt")
        XCTAssertEqual(report.failure?.expected, "the file exists")
        XCTAssertEqual(report.failure?.actual, "missing")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(report))
                as? [String: Any])
        let failure = try XCTUnwrap(object["failure"] as? [String: Any])
        XCTAssertEqual(failure["kind"] as? String, "missing")
        XCTAssertEqual(failure["path"] as? String, "missing.txt")
    }

    func testNotExecutedAssertionCarriesTheGateFailureKind() throws {
        let paths = try scratchWorkspace()
        let evaluator = ScenarioAssertionEvaluator(
            workspace: paths.workspace,
            resultsDirectory: paths.results,
            turnStartedCount: 1,
            deliveredTurnCount: 1,
            modelRequests: 0,
            consoleErrors: [],
            restartRecovered: nil,
            redactor: ScenarioRedactor())
        let assertion = try decodeAssertion(#"{"type":"file_exists","path":"a.txt"}"#)
        let completion = ScenarioRunCompletion.incomplete(
            reason: "the run ended with status TIMEOUT")
        let report = try XCTUnwrap(
            evaluator.reports(for: [assertion], completion: completion).first)
        XCTAssertEqual(report.status, ScenarioAssertionStatus.notExecuted)
        XCTAssertEqual(report.failure?.kind, .notExecuted)
        XCTAssertTrue(report.detail.contains("TIMEOUT"), report.detail)
    }

    private func decodeAssertion(_ json: String) throws -> Scenario.Assertion {
        try JSONDecoder().decode(Scenario.Assertion.self, from: Data(json.utf8))
    }
}
