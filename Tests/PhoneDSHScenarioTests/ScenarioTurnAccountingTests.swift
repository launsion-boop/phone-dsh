// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: turn accounting regressions.
//
// G2-FIX-13/G2-FIX-125: `turn_count_lte` read `recorder.turnStartedCount`,
// which includes the runner's own `-retry-1` DSH turn, and `turns[]` only had
// a row for a delivered turn. G2-FIX-91/G2-FIX-92: `ended` was the runner's
// clock and a cancelled/aborted `turnEnded` was treated as a normal finish.
// These tests pin the corrected accounting without a WKWebView boot.

import Foundation
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHScenario

final class ScenarioTurnAccountingTests: XCTestCase {
    private func assertion(_ json: String) throws -> Scenario.Assertion {
        try JSONDecoder().decode(Scenario.Assertion.self, from: Data(json.utf8))
    }

    private func scratchWorkspace() throws -> (root: URL, workspace: URL, results: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-turn-accounting-\(UUID().uuidString)",
                                    isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let results = root.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: results,
                                                withIntermediateDirectories: true)
        try Data("alpha\n".utf8).write(to: workspace.appendingPathComponent("a.txt"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, workspace, results)
    }

    // MARK: - G2-FIX-13 / G2-FIX-125

    func testTurnCountLteCountsDeliveredScenarioTurnsNotDSHRetryTurns() throws {
        let paths = try scratchWorkspace()
        // Two delivered scenario turns, but three DSH turn/start events because
        // the runner retried the first prompt after a perturbation. The old
        // implementation counted 3 and failed a max of 2.
        let evaluator = ScenarioAssertionEvaluator(
            workspace: paths.workspace,
            resultsDirectory: paths.results,
            turnStartedCount: 3,
            deliveredTurnCount: 2,
            modelRequests: 0,
            consoleErrors: [],
            restartRecovered: nil,
            redactor: ScenarioRedactor())
        let bound = try assertion(#"{"type":"turn_count_lte","max":2}"#)
        let report = try XCTUnwrap(evaluator.reports(for: [bound],
                                                     completion: .completed).first)
        XCTAssertTrue(report.ok,
                      "delivered scenario turns (2) must be compared, not the 3 "
                        + "DSH turn/start events that include the retry")
        XCTAssertTrue(report.detail.contains("2 delivered scenario turn(s)"),
                      report.detail)
        XCTAssertTrue(report.detail.contains("3 DSH turn/start event(s)"),
                      report.detail)
        XCTAssertNil(report.failure)

        // The old over-count is still visible as the explicit retry count.
        let over = try assertion(#"{"type":"turn_count_lte","max":1}"#)
        let failing = try XCTUnwrap(evaluator.reports(for: [over],
                                                      completion: .completed).first)
        XCTAssertFalse(failing.ok)
        XCTAssertEqual(failing.failure?.kind, .countExceeded)
    }

    func testEveryPlannedTurnHasOneRowAndUndeliveredIsExplicit() throws {
        let undelivered = ScenarioTurnReport(
            promptLen: 5,
            started: "2026-10-25T00:00:00.000Z",
            ended: nil,
            modelRequests: 0,
            toolCalls: 0,
            events: 0,
            index: 1,
            delivered: false,
            requestID: "g2-test-turn-2",
            attempts: 0,
            terminalReason: nil)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(undelivered))
                as? [String: Any])
        XCTAssertEqual(object["index"] as? Int, 1)
        XCTAssertEqual(object["delivered"] as? Bool, false)
        XCTAssertEqual(object["request_id"] as? String, "g2-test-turn-2")
        XCTAssertEqual(object["attempts"] as? Int, 0)
        XCTAssertNil(object["ended"], "an undelivered turn must not invent an end")
        XCTAssertNil(object["terminal_reason"])

        let completion = ScenarioRunCompletion.evaluate(
            plannedTurns: 2,
            turnReports: [
                ScenarioTurnReport(promptLen: 5, started: "s", ended: "e",
                                   modelRequests: 1, toolCalls: 0, events: 2,
                                   index: 0, delivered: true,
                                   requestID: "g2-test-turn-1", attempts: 1,
                                   terminalReason: "completed"),
                undelivered,
            ],
            terminalStatus: nil)
        XCTAssertFalse(completion.isComplete)
        XCTAssertTrue(try XCTUnwrap(completion.reason).contains("not delivered"),
                      String(describing: completion.reason))
    }

    // MARK: - G2-FIX-91 / G2-FIX-92

    func testRecorderKeepsTheTurnEndEventTimeAndReason() throws {
        let recorder = ScenarioRecorder()
        let eventTime = Date(timeIntervalSince1970: 1_790_000_000.125)
        recorder.record(harness: HarnessEvent(
            seq: 9,
            time: eventTime,
            kind: .turnEnded(turnID: "7", reason: .cancelled)))
        let end = try XCTUnwrap(recorder.turnEnd(after: 0),
                                "the terminal event was not recorded")
        XCTAssertEqual(end.turnID, "7")
        XCTAssertEqual(end.terminalReason, "cancelled")
        XCTAssertEqual(scenarioTimestamp(end.time), scenarioTimestamp(eventTime),
                       "the report must use the turnEnded event time")
    }

    func testNonCompletedTerminalReasonEntersRunIncompleteReason() throws {
        let eventTime = "2026-10-25T00:00:04.123Z"
        for reason in ["cancelled", "aborted", "interrupted", "failed", "budget"] {
            let report = ScenarioTurnReport(
                promptLen: 5,
                started: "2026-10-25T00:00:00.000Z",
                ended: eventTime,
                modelRequests: 1,
                toolCalls: 0,
                events: 4,
                index: 0,
                delivered: true,
                requestID: "g2-test-turn-1",
                attempts: 1,
                terminalReason: reason)
            let completion = ScenarioRunCompletion.evaluate(
                plannedTurns: 1, turnReports: [report], terminalStatus: nil)
            XCTAssertFalse(completion.isComplete, "\(reason) must not be complete")
            let recorded = try XCTUnwrap(completion.reason)
            XCTAssertTrue(recorded.contains(reason),
                          "run_incomplete_reason must name \(reason): \(recorded)")
            XCTAssertEqual(report.ended, eventTime,
                           "the event time must survive unchanged")
        }
    }

    func testDeliveredTurnWithoutTurnEndIsNoTerminalTurnEnd() throws {
        let completion = ScenarioRunCompletion.evaluate(
            plannedTurns: 1,
            turnReports: [
                ScenarioTurnReport(promptLen: 5, started: "s", ended: nil,
                                   modelRequests: 1, toolCalls: 0, events: 2,
                                   index: 0, delivered: true,
                                   requestID: "g2-test-turn-1", attempts: 1,
                                   terminalReason: nil),
            ],
            terminalStatus: nil)
        XCTAssertFalse(completion.isComplete)
        XCTAssertTrue(try XCTUnwrap(completion.reason).contains("no terminal turn/end"),
                      String(describing: completion.reason))
    }

    // MARK: - G2-FIX-94 partial evidence

    func testIncompleteRunKeepsPartialEvidenceWithoutChangingTheVerdict() throws {
        let paths = try scratchWorkspace()
        let hostRoot = paths.root.appendingPathComponent("host", isDirectory: true)
        let materialized = hostRoot
            .appendingPathComponent("materialized/workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: materialized,
                                                withIntermediateDirectories: true)
        try Data("model output\n".utf8)
            .write(to: materialized.appendingPathComponent("out.txt"))
        let current = MaterializedSnapshot.read(workspaceRoot: hostRoot)
        let baseline = MaterializedSnapshot(entries: [:])

        let evaluator = ScenarioAssertionEvaluator(
            workspace: materialized,
            resultsDirectory: paths.results,
            turnStartedCount: 2,
            deliveredTurnCount: 1,
            modelRequests: 1,
            consoleErrors: [],
            restartRecovered: nil,
            redactor: ScenarioRedactor())
        let completion = ScenarioRunCompletion.incomplete(
            reason: "the run ended with status TIMEOUT")
        let missing = try assertion(#"{"type":"file_exists","path":"out.txt"}"#)
        let reports = evaluator.reports(for: [missing], completion: completion)
        XCTAssertEqual(reports.first?.status, ScenarioAssertionStatus.notExecuted)
        XCTAssertFalse(reports.first?.isPassing ?? true)
        XCTAssertEqual(ScenarioAssertionSummary.summarize(reports).notExecuted, 1)
        XCTAssertFalse(ScenarioAssertionSummary.summarize(reports).allPassed)

        let evidence = evaluator.partialEvidence(
            for: [missing],
            completion: completion,
            completedTurns: 1,
            fixtureBaseline: baseline,
            currentWorkspace: current)
        let item = try XCTUnwrap(evidence.first)
        XCTAssertEqual(item.assertionIndex, 0)
        XCTAssertEqual(item.type, "file_exists")
        XCTAssertTrue(item.ok, "the static workspace read can see the artifact")
        XCTAssertEqual(item.basis, "materialized_workspace")
        XCTAssertEqual(item.completedTurns, 1)
        XCTAssertEqual(item.fixtureDiff, "created_since_fixture")
        XCTAssertTrue(item.detail.contains("exists"), item.detail)

        // A completed run has no partial-evidence array at all.
        XCTAssertTrue(evaluator.partialEvidence(
            for: [missing],
            completion: .completed,
            completedTurns: 1,
            fixtureBaseline: baseline,
            currentWorkspace: current).isEmpty)
    }

    // MARK: - Report-object reconstruction (simulator host phase)

    func testReportObjectKeepsUndeliveredAndTerminalReasons() throws {
        let json = """
        {"status":"TIMEOUT","run_completed":true,
         "turns":[
           {"index":0,"delivered":true,"started":"s","ended":"2026-10-25T00:00:04.000Z",
            "terminal_reason":"aborted"},
           {"index":1,"delivered":false,"started":"s"}
         ]}
        """
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let completion = ScenarioRunCompletion.from(report: object)
        XCTAssertFalse(completion.isComplete)
        let reason = try XCTUnwrap(completion.reason)
        XCTAssertTrue(reason.contains("not delivered"), reason)
        XCTAssertTrue(reason.contains("aborted"), reason)
    }
}
