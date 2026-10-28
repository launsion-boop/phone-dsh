// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: report diagnostic channels.
//
// Root cause this pins (G2-A01/A02): `no_console_error` evaluated the runtime
// `recorder.consoleErrors`, then `buildReport` appended the runner's own
// terminal diagnostics (the wall-budget timeout) to the same `console_errors`
// field. Every timed-out report said `no_console_error: ok` while the same
// field listed the runner timeout, so a judge could not trust either signal.
//
// The fix gives the report one source of truth per channel: `console_errors`
// is exactly the Worker/session array the assertion evaluates, and runner
// lifecycle diagnostics live in the separate `runner_errors` field. These are
// the component-level tests; the end-to-end timeout report is checked by
// `PhoneDSHScenarioAbortJournalTests`.
//
// The `PhoneDSH` prefix keeps these tests inside the CI gate filter
// `swift test --filter 'PhoneDSH|PhoneDSHShell'`; the
// `PhoneDSHScenario` segment keeps them inside the scenario gate filter.

import Foundation
import XCTest
@testable import PhoneDSHScenario

final class PhoneDSHScenarioReportDiagnosticsTests: XCTestCase {
    // MARK: - Fixtures

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-report-diagnostics-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func evaluator(consoleErrors: [String]) throws -> ScenarioAssertionEvaluator {
        let root = try temporaryDirectory()
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let results = root.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        return ScenarioAssertionEvaluator(
            workspace: workspace,
            resultsDirectory: results,
            turnStartedCount: 1,
            modelRequests: 1,
            consoleErrors: consoleErrors,
            restartRecovered: nil,
            redactor: ScenarioRedactor())
    }

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        while directory.pathComponents.count > 1 {
            if fileManager.fileExists(atPath: directory.appendingPathComponent("spec").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw XCTSkip("the scenario repository root (spec/) was not found above the test file")
    }

    private func timeoutDiagnostics(consoleErrors: [String] = []) -> ScenarioReportDiagnostics {
        ScenarioReportDiagnostics(
            consoleErrors: consoleErrors,
            runnerDiagnostics: ScenarioReportDiagnostics.runnerDiagnostics(
                deferred: nil,
                runnerInfra: nil,
                terminalError: "timeout(\"budget.max_minutes=10 elapsed\")",
                otherError: nil))
    }

    // MARK: - The channel split

    /// The exact defect: a runner timeout must not appear in the console-error
    /// stream, and the assertion's verdict must follow the same stream.
    func testRunnerTimeoutStaysOutOfTheConsoleErrorChannel() throws {
        let diagnostics = timeoutDiagnostics()
        XCTAssertEqual(diagnostics.consoleErrors, [],
                       "runner diagnostics are not Worker console errors")
        XCTAssertEqual(diagnostics.runnerErrors.count, 1)
        XCTAssertTrue(diagnostics.runnerErrors[0].contains("budget.max_minutes=10 elapsed"),
                      "the runner timeout must be preserved verbatim in runner_errors")
        XCTAssertEqual(diagnostics.assertionConsoleErrors, diagnostics.consoleErrors,
                       "the assertion source and the report field must be one array")
    }

    /// Every runner lifecycle category stays on the runner channel; a real
    /// Worker console error stays on the console channel.
    func testEveryRunnerLifecycleDiagnosticGoesToTheRunnerChannel() {
        let workerError = "console.error: worker exploded"
        let diagnostics = ScenarioReportDiagnostics(
            consoleErrors: [workerError],
            runnerDiagnostics: ScenarioReportDiagnostics.runnerDiagnostics(
                deferred: "the Mac console session is locked",
                runnerInfra: "no perturbation executor for kind \"webcontent_kill\"",
                terminalError: "timeout(\"budget.max_minutes=1 elapsed\")",
                otherError: "disk full"))
        XCTAssertEqual(diagnostics.consoleErrors, [workerError])
        XCTAssertEqual(diagnostics.runnerErrors.count, 4)
        XCTAssertEqual(diagnostics.runnerErrors.map { $0.hasPrefix("runner: ") },
                       [true, true, true, true])
        XCTAssertFalse(diagnostics.runnerErrors.contains(workerError))
        XCTAssertTrue(diagnostics.runnerErrors[0].contains("deferred"))
        XCTAssertTrue(diagnostics.runnerErrors[1].contains("no perturbation executor"))
        XCTAssertTrue(diagnostics.runnerErrors[2].contains("budget.max_minutes=1 elapsed"))
        XCTAssertTrue(diagnostics.runnerErrors[3].contains("disk full"))
    }

    /// Redaction applies per channel, and a credential never appears on
    /// either side.
    func testChannelsAreRedactedIndependently() {
        let diagnostics = ScenarioReportDiagnostics(
            consoleErrors: ["console.error: Authorization: Bearer abcdefghijkl"],
            runnerDiagnostics: ["runner: timeout: sk-abcdefgh"],
            redactor: ScenarioRedactor())
        XCTAssertEqual(diagnostics.consoleErrors,
                       ["console.error: authorization: <redacted>"])
        XCTAssertEqual(diagnostics.runnerErrors, ["runner: timeout: sk-<redacted>"])
        XCTAssertFalse(diagnostics.consoleErrors.contains { $0.contains("abcdefghijkl") })
        XCTAssertFalse(diagnostics.runnerErrors.contains { $0.contains("sk-abcdefgh") })
    }

    /// A real Worker console error still fails `no_console_error`, and the
    /// failure detail references the array the assertion evaluated.
    func testWorkerConsoleErrorStillFailsNoConsoleError() throws {
        let error = "console.error: worker exploded"
        let evaluator = try evaluator(consoleErrors: [error])
        let reports = evaluator.reports(
            for: [Scenario.Assertion(type: "no_console_error")],
            completion: .completed)
        let report = try XCTUnwrap(reports.first)
        XCTAssertFalse(report.ok, "a Worker console error is a real no_console_error failure")
        XCTAssertTrue(report.detail.contains("console_errors"),
                      "the detail must reference the field it evaluated: \(report.detail)")
        XCTAssertTrue(report.detail.contains(error), report.detail)

        let diagnostics = timeoutDiagnostics(consoleErrors: [error])
        XCTAssertEqual(diagnostics.consoleErrors, [error])
        XCTAssertEqual(report.ok, diagnostics.consoleErrors.isEmpty,
                       "the verdict and console_errors must never disagree")
        XCTAssertFalse(diagnostics.runnerErrors.contains { $0.contains(error) },
                       "Worker errors must not leak into runner_errors")
    }

    /// The clean mirror: an empty Worker/session stream passes and encodes as
    /// an empty `console_errors` array beside the runner diagnostics.
    func testCleanConsolePassesAndTheReportEncodesBothChannels() throws {
        let evaluator = try evaluator(consoleErrors: [])
        let reports = evaluator.reports(
            for: [Scenario.Assertion(type: "no_console_error")],
            completion: .completed)
        let assertion = try XCTUnwrap(reports.first)
        XCTAssertTrue(assertion.ok)
        XCTAssertEqual(assertion.detail, "no console errors")

        let diagnostics = timeoutDiagnostics()
        let report = ScenarioReport(
            id: "G2-SCHEMA-UNIT",
            status: "TIMEOUT",
            assertions: [assertion],
            turns: [],
            perturbations: [],
            usage: ScenarioUsageReport(modelRequests: 0, upstreamBytesIn: 0,
                                       upstreamBytesOut: 0, wallS: 0),
            pageVisibility: nil,
            deferred: nil,
            runnerInfra: nil,
            webContentTerminations: 0,
            hostEvaluated: nil,
            consoleErrors: diagnostics.consoleErrors,
            runnerErrors: diagnostics.runnerErrors,
            hostStates: [],
            runCompleted: false,
            runIncompleteReason: "the run ended with status TIMEOUT")
        let data = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["console_errors"] as? [String], [],
                       "report.json console_errors must hold only Worker/session errors")
        XCTAssertEqual(object["runner_errors"] as? [String], diagnostics.runnerErrors,
                       "runner diagnostics have their own report field")
        XCTAssertTrue(object["runner_errors"] is [String])
        let encodedAssertions = object["assertions"] as? [[String: Any]] ?? []
        XCTAssertEqual(encodedAssertions.first?["ok"] as? Bool, true)
    }

    // MARK: - The checked-in selftest fixture

    /// The end-to-end regression in
    /// `PhoneDSHScenarioAbortJournalTests` runs this fixture; pin
    /// its shape here so a future catalog edit cannot silently turn the
    /// timeout regression into a completed run.
    func testSelftestCatalogCarriesTheTimeoutReportSchemaFixture() throws {
        let root = try repositoryRoot()
        let catalogURL = root.appendingPathComponent(
            "scripts/ci/scenarios/selftest.json")
        let catalog = try ScenarioCatalog.load(from: catalogURL)
        let scenario = try XCTUnwrap(
            catalog.scenarios.first { $0.id == "G2-SELFTEST-REPORT-SCHEMA" },
            "selftest.json must carry the report-schema timeout fixture")
        XCTAssertEqual(scenario.budget.maxMinutes, 1,
                       "the fixture must use the smallest wall budget")
        XCTAssertEqual(scenario.mock?.stallFromResponse, 1,
                       "the first mock reply must hang so the wall budget fires")
        XCTAssertTrue(scenario.assertions.contains { $0.type == "no_console_error" },
                      "the fixture must carry no_console_error")
        XCTAssertFalse(scenario.assertions.contains { $0.type == "file_exists" },
                       "the run never completes a turn, so no workspace assertion may pass")
        XCTAssertEqual(scenario.target, "macos")
    }
}
