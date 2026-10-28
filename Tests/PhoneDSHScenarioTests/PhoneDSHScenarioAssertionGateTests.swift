// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: run-completion gate regression
// tests (G2-FIX-15).
//
// Root cause these pin: `ScenarioRun.evaluateAssertions()` ran on every exit
// path and every assertion type reported only a boolean `ok`. A run that ended
// TIMEOUT/BUDGET/ERROR (or whose turns never reached a terminal `ended`)
// evaluated its workspace/file assertions against the untouched fixture or a
// partial workspace. Those checks can trivially match there, so
// the report showed e.g. `status: "TIMEOUT"` with 8/8 assertions `ok: true`
// although the model wrote zero bytes.
//
// The tests feed the production assertion evaluator a recorded run fixture
// (status + turn reports + counters) without a model or a WKWebView. On the
// pre-fix path the fixture satisfies every completion-dependent assertion
// (`ok: true`); the gate must yield the explicit `NOT_EXECUTED` state, and the
// summary must not be able to call the report all-green. Observed counters such
// as `turn_count_lte` remain evaluable even when a turn fails; their bounds are
// independent of workspace completion. The mirror case pins that a completed
// run still evaluates ok/fail and detail exactly as before.
//
// The `PhoneDSH` prefix keeps these tests inside the CI gate filter
// `swift test --filter 'PhoneDSH|PhoneDSHShell'`.

import Foundation
import XCTest
import PhoneDSHAgentCore
@testable import PhoneDSHScenario

final class PhoneDSHScenarioAssertionGateTests: XCTestCase {
    // MARK: - Fixtures

    private static let progressDependentTypes = [
        "file_exists",
        "no_file",
        "file_contains",
        "file_regex",
        "file_json_path",
        "workspace_command",
        "worker_command",
    ]

    /// A completed-run Worker receipt stand-in for the gate fixture. The
    /// production evaluator only produces this while the live Worker is up;
    /// these tests exercise the report merge, not the transport.
    private func workerCommandReport() -> ScenarioAssertionReport {
        ScenarioAssertionReport(
            type: "worker_command",
            ok: true,
            detail: "worker exit 0\n[environment: worker-command; worker VFS: used "
                + "(immutable fork); host process: not used]",
            durationMs: 1,
            workerEvaluated: true,
            workerReceipt: .object(["protocol": .string("pdsh-worker-command/1")]))
    }

    private func withTemporaryRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-scenario-assertion-gate-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    /// A workspace the fixture's assertions trivially satisfy.
    @discardableResult
    private func makeWorkspace(in root: URL) throws -> URL {
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("alpha\n## heading\n".utf8)
            .write(to: workspace.appendingPathComponent("a.txt"))
        try Data(#"{"ok":true,"items":[{"name":"first"}]}"#.utf8)
            .write(to: workspace.appendingPathComponent("data.json"))
        return workspace
    }

    private func makeResults(in root: URL) throws -> URL {
        let results = root.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        return results
    }

    private func assertion(_ type: String,
                           path: String? = nil,
                           value: String? = nil,
                           command: String? = nil,
                           max: Int? = nil) -> Scenario.Assertion {
        Scenario.Assertion(type: type, path: path, value: value, command: command, max: max)
    }

    /// The completion-dependent assertion types. `turn_count_lte` is
    /// intentionally absent: its runner counter remains observable on a
    /// failed or incomplete turn; `worker_command` needs the live Worker, so
    /// an incomplete run gates it too.
    private func progressAssertions(command: String = "touch gate-control.txt") -> [Scenario.Assertion] {
        [
            assertion("file_exists", path: "a.txt"),
            assertion("no_file", path: "absent.txt"),
            assertion("file_contains", path: "a.txt", value: "alpha"),
            assertion("file_regex", path: "a.txt", value: "^## "),
            assertion("file_json_path", path: "data.json", value: "ok"),
            assertion("workspace_command", command: command),
            assertion("worker_command", command: "printf worker"),
        ]
    }

    private func evaluator(workspace: URL,
                           results: URL,
                           turnStartedCount: Int = 0,
                           deliveredTurnCount: Int = 0,
                           modelRequests: Int = 0,
                           consoleErrors: [String] = [],
                           restartRecovered: ScenarioPerturbationCoverage.Verdict? =
                               ScenarioPerturbationCoverage.Verdict(
                                   ok: true, detail: "1 perturbation(s) applied and recovered"))
        -> ScenarioAssertionEvaluator {
        ScenarioAssertionEvaluator(
            workspace: workspace,
            resultsDirectory: results,
            turnStartedCount: turnStartedCount,
            deliveredTurnCount: deliveredTurnCount,
            modelRequests: modelRequests,
            consoleErrors: consoleErrors,
            restartRecovered: restartRecovered,
            redactor: ScenarioRedactor())
    }

    /// The recorded G2-B07-shaped run: status TIMEOUT, one delivered turn whose
    /// report has no terminal `ended`, and a model that wrote nothing.
    private func timeoutCompletion() -> ScenarioRunCompletion {
        ScenarioRunCompletion.evaluate(
            plannedTurns: 1,
            turnReports: [
                ScenarioTurnReport(promptLen: 12,
                                   started: "2026-10-25T00:00:00Z",
                                   ended: nil,
                                   modelRequests: 1,
                                   toolCalls: 0,
                                   events: 3),
            ],
            terminalStatus: "TIMEOUT")
    }

    private func completedCompletion() -> ScenarioRunCompletion {
        ScenarioRunCompletion.evaluate(
            plannedTurns: 1,
            turnReports: [
                ScenarioTurnReport(promptLen: 12,
                                   started: "2026-10-25T00:00:00Z",
                                   ended: "2026-10-25T00:00:05Z",
                                   modelRequests: 1,
                                   toolCalls: 1,
                                   events: 9),
            ],
            terminalStatus: nil)
    }

    // MARK: - The gate (the regression)

    /// The same fixture and workspace, evaluated through an incomplete run,
    /// keeps workspace-dependent assertions NOT_EXECUTED. Observable counters
    /// are tested separately and remain evaluable.
    func testTimeoutRunMarksEveryProgressDependentAssertionNotExecuted() throws {
        try withTemporaryRoot { root in
            let workspace = try makeWorkspace(in: root)
            let results = try makeResults(in: root)
            let completion = timeoutCompletion()
            XCTAssertFalse(completion.isComplete,
                           "a TIMEOUT run with an open turn must not be complete")

            // Control: the fixture trivially satisfies every assertion, which
            // is why evaluating them on an incomplete run used to report green.
            let controlEvaluator = evaluator(workspace: workspace,
                                             results: root.appendingPathComponent(
                                                "control-results", isDirectory: true))
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("control-results", isDirectory: true),
                withIntermediateDirectories: true)
            let control = controlEvaluator.reports(
                for: progressAssertions(),
                completion: .completed,
                overrides: [6: workerCommandReport()])
            XCTAssertEqual(control.count, 7)
            XCTAssertTrue(control.allSatisfy { $0.ok },
                          "fixture assertions must trivially pass when evaluated; "
                            + "got \(control.map { "\($0.type)=\($0.ok)" })")

            // The report path under test: incomplete run, same assertions and
            // workspace. No assertion of the progress-dependent class may pass.
            let gated = evaluator(workspace: workspace, results: results)
                .reports(for: progressAssertions(), completion: completion)
            XCTAssertEqual(gated.map(\.type), Self.progressDependentTypes)
            for report in gated {
                XCTAssertEqual(report.status, ScenarioAssertionStatus.notExecuted,
                               "\(report.type) must be NOT_EXECUTED, got \(report)")
                XCTAssertFalse(report.ok, "\(report.type) must not claim ok")
                XCTAssertFalse(report.isPassing, "\(report.type) must never pass")
                XCTAssertTrue(report.detail.contains("not executed"),
                              "\(report.type): \(report.detail)")
                XCTAssertTrue(report.detail.contains("TIMEOUT"),
                              "\(report.type): the reason must name the terminal exit")
            }
            XCTAssertEqual(ScenarioAssertionStatus.notExecuted, "NOT_EXECUTED",
                           "report.json carries the explicit NOT_EXECUTED state")
            // The command was gated, not deferred or executed: no throwaway
            // check-workspace copy exists.
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: results.appendingPathComponent("check-workspace").path),
                "a gated workspace_command must not run")

            // The summary can no longer call the report all-green.
            let summary = ScenarioAssertionSummary.summarize(gated)
            XCTAssertEqual(summary.notExecuted, 7)
            XCTAssertEqual(summary.failed, 0)
            XCTAssertEqual(summary.passed, 0)
            XCTAssertFalse(summary.allPassed,
                           "NOT_EXECUTED must keep the summary from all-pass")
        }
    }

    /// A `worker_command` receipt is evaluated before `host.stop()`. A later
    /// stop/seal failure makes the run incomplete, so the cached PASS must not
    /// survive the gate: NOT_EXECUTED is never a pass.
    func testAFailedStopAfterAWorkerPassGatesTheCachedOverride() throws {
        try withTemporaryRoot { root in
            let workspace = try makeWorkspace(in: root)
            let results = try makeResults(in: root)
            let cached = workerCommandReport()
            XCTAssertTrue(cached.isPassing, "the cached receipt is a real Worker PASS")

            let completion = ScenarioRunCompletion.incomplete(
                reason: "host.stop() failed: injected terminal WAL seal failure")
            let reports = evaluator(workspace: workspace, results: results).reports(
                for: [assertion("worker_command", command: "printf worker")],
                completion: completion,
                overrides: [0: cached])
            let report = try XCTUnwrap(reports.first)
            XCTAssertEqual(report.status, ScenarioAssertionStatus.notExecuted)
            XCTAssertFalse(report.ok)
            XCTAssertFalse(report.isPassing)
            XCTAssertNil(report.workerReceipt,
                         "a gated override must not publish the old PASS receipt")
            XCTAssertTrue(report.detail.contains("host.stop() failed"), report.detail)

            let summary = ScenarioAssertionSummary.summarize(reports)
            XCTAssertEqual(summary.passed, 0)
            XCTAssertEqual(summary.notExecuted, 1)
            XCTAssertFalse(summary.allPassed)
        }
    }

    /// `turn_count_lte` observes delivered-turn accounting, so an expected
    /// failed terminal does not erase the count or turn it into NOT_EXECUTED.
    func testTurnCountIsEvaluatedWhenDeliveredTurnEndsWithFailure() throws {
        try withTemporaryRoot { root in
            let workspace = try makeWorkspace(in: root)
            let results = try makeResults(in: root)
            let completion = ScenarioRunCompletion.evaluate(
                plannedTurns: 1,
                turnReports: [ScenarioTurnReport(
                    promptLen: 67,
                    started: "2026-10-27T00:34:20.562Z",
                    ended: "2026-10-27T00:34:26.790Z",
                    modelRequests: 2,
                    toolCalls: 1,
                    events: 14,
                    index: 0,
                    delivered: true,
                    requestID: "g2-selftest-delivery-stall-turn-1",
                    attempts: 1,
                    terminalReason: "failed")],
                terminalStatus: nil)
            XCTAssertFalse(completion.isComplete,
                           "the delivered failed turn must remain an incomplete run")

            let withinBound = evaluator(workspace: workspace,
                                        results: results,
                                        turnStartedCount: 1,
                                        deliveredTurnCount: 1,
                                        modelRequests: 2)
                .reports(for: [assertion("turn_count_lte", max: 2)],
                         completion: completion)
            let passing = try XCTUnwrap(withinBound.first)
            XCTAssertTrue(passing.ok, passing.detail)
            XCTAssertNil(passing.status,
                         "an observed counter is evaluated, not marked NOT_EXECUTED")
            XCTAssertNil(passing.failure)
            XCTAssertEqual(passing.detail,
                           "1 delivered scenario turn(s), 1 DSH turn/start event(s) "
                            + "including retries, max 2")

            let overBound = evaluator(workspace: workspace,
                                      results: results,
                                      turnStartedCount: 1,
                                      deliveredTurnCount: 1,
                                      modelRequests: 2)
                .reports(for: [assertion("turn_count_lte", max: 0)],
                         completion: completion)
            let failing = try XCTUnwrap(overBound.first)
            XCTAssertFalse(failing.ok)
            XCTAssertNil(failing.status)
            XCTAssertEqual(failing.failure?.kind, .countExceeded,
                           "incomplete-run counts still enforce their declared bound")
        }
    }

    /// `no_console_error` and the other non-progress assertion types keep their
    /// current evaluation on an incomplete run; restart_recovered stays owned
    /// by the perturbation coverage (G2-FIX-6).
    func testGateLeavesNonProgressAssertionsEvaluated() throws {
        try withTemporaryRoot { root in
            let workspace = try makeWorkspace(in: root)
            let results = try makeResults(in: root)
            let evaluator = evaluator(workspace: workspace,
                                      results: results,
                                      modelRequests: 0,
                                      consoleErrors: [])
            let assertions = [
                assertion("no_console_error"),
                assertion("model_requests_lte", max: 2),
                assertion("session_error"),
                assertion("restart_recovered"),
            ]
            let reports = evaluator.reports(for: assertions, completion: timeoutCompletion())
            let byType = Dictionary(uniqueKeysWithValues: reports.map { ($0.type, $0) })
            XCTAssertEqual(byType["no_console_error"]?.ok, true)
            XCTAssertEqual(byType["no_console_error"]?.detail, "no console errors")
            XCTAssertEqual(byType["model_requests_lte"]?.ok, true)
            XCTAssertEqual(byType["model_requests_lte"]?.detail, "0 model request(s), max 2")
            XCTAssertEqual(byType["session_error"]?.ok, false,
                           "an absent session error is a real evaluation, not gated")
            XCTAssertEqual(byType["restart_recovered"]?.ok, true)
            for report in reports {
                XCTAssertNotEqual(report.status, ScenarioAssertionStatus.notExecuted,
                                  "\(report.type) is not progress-dependent")
            }
        }
    }

    /// Every progress-dependent type is gated for the whole class of incomplete
    /// runs, not just for a timeout: the gate reads only the completion fact.
    func testGateCoversTheWholeIncompleteRunClass() throws {
        for completion in [
            ScenarioRunCompletion.incomplete(reason: "the run ended with status BUDGET"),
            ScenarioRunCompletion.incomplete(reason: "the run ended with status ERROR"),
            ScenarioRunCompletion.incomplete(reason: "1 of 2 scenario turn(s) were delivered"),
            ScenarioRunCompletion.incomplete(reason: "1 delivered turn(s) have no terminal end"),
        ] {
            for type in Self.progressDependentTypes {
                XCTAssertTrue(ScenarioAssertionGate.suppresses(type, completion: completion),
                              "\(type) must be gated for \(completion)")
            }
            for type in ["no_console_error", "model_requests_lte", "session_error",
                         "restart_recovered", "turn_count_lte"] {
                XCTAssertFalse(ScenarioAssertionGate.suppresses(type, completion: completion),
                               "\(type) must keep its evaluation for \(completion)")
            }
        }
        XCTAssertTrue(ScenarioRunCompletion.completed.isComplete)
        for type in Self.progressDependentTypes {
            XCTAssertFalse(ScenarioAssertionGate.suppresses(type, completion: .completed),
                           "\(type) must be evaluated on a completed run")
        }
    }

    // MARK: - Mirror: a completed run is unchanged

    /// A completed run evaluates every assertion with the same verdicts as
    /// before the gate fix. `workspace_command` additionally carries
    /// G2-FIX-35's host-environment line.
    func testCompletedRunEvaluatesAssertionsExactlyAsBefore() throws {
        try withTemporaryRoot { root in
            let workspace = try makeWorkspace(in: root)
            let results = try makeResults(in: root)
            let reports = evaluator(workspace: workspace, results: results)
                .reports(for: progressAssertions(), completion: completedCompletion(),
                         overrides: [6: workerCommandReport()])
            XCTAssertEqual(reports.count, 7)
            let byType = Dictionary(uniqueKeysWithValues: reports.map { ($0.type, $0) })
            let expectedDetails = [
                "file_exists": "exists: a.txt",
                "no_file": "absent: absent.txt",
                "file_contains": "contains alpha",
                "file_regex": "matches ^## ",
                "file_json_path": "json path ok resolves",
            ]
            for (type, detail) in expectedDetails {
                XCTAssertEqual(byType[type]?.ok, true, "\(type) must stay ok:true")
                XCTAssertEqual(byType[type]?.detail, detail, "\(type) detail changed")
                XCTAssertNil(byType[type]?.status, "\(type) must not carry a gate status")
                XCTAssertEqual(byType[type]?.isPassing, true)
            }
            // G2-FIX-35 appends one host-environment line to every
            // workspace_command outcome; the verdict itself is unchanged.
            let workspaceDetail = try XCTUnwrap(byType["workspace_command"]?.detail)
            let hostMarker = "[environment: host-bash; worker VFS: not used; "
                + "path: /dsh/workspace -> "
            XCTAssertTrue(workspaceDetail.hasPrefix("exit 0\n" + hostMarker),
                          workspaceDetail)
            XCTAssertTrue(workspaceDetail.contains("check-workspace"), workspaceDetail)
            XCTAssertEqual(byType["workspace_command"]?.ok, true)
            XCTAssertEqual(byType["workspace_command"]?.isPassing, true)
            XCTAssertNil(byType["workspace_command"]?.status,
                         "workspace_command must not carry a gate status")
            XCTAssertEqual(byType["workspace_command"]?.hostEvaluated, true)
            XCTAssertNotNil(byType["workspace_command"]?.durationMs)

            // G2-FIX-35: the Worker assertion keeps its own marker and receipt;
            // it is never merged into the host row.
            XCTAssertEqual(byType["worker_command"]?.workerEvaluated, true)
            XCTAssertNil(byType["worker_command"]?.hostEvaluated)
            XCTAssertEqual(byType["worker_command"]?.isPassing, true)
            XCTAssertTrue(byType["worker_command"]?.detail.contains(
                "worker VFS: used (immutable fork)") == true,
                byType["worker_command"]?.detail ?? "")

            // A genuinely failing assertion is still an ordinary ok:false.
            let failing = evaluator(workspace: workspace, results: results).reports(
                for: [assertion("no_file", path: "a.txt")],
                completion: completedCompletion())
            XCTAssertEqual(failing.first?.ok, false)
            XCTAssertEqual(failing.first?.detail, "unexpected file: a.txt")
            XCTAssertEqual(failing.first?.status, nil)
            XCTAssertFalse(failing.first?.isPassing ?? true)
        }
    }

    // MARK: - The report schema

    /// The NOT_EXECUTED state is part of the assertion report schema; it is
    /// serialized with `ok: false` and never counted as a pass.
    func testNotExecutedStateIsSerializedIntoTheAssertionReport() throws {
        try withTemporaryRoot { root in
            let workspace = try makeWorkspace(in: root)
            let results = try makeResults(in: root)
            let report = try XCTUnwrap(
                evaluator(workspace: workspace, results: results)
                    .reports(for: [assertion("file_regex", path: "a.txt", value: "^## ")],
                             completion: timeoutCompletion()).first)
            let data = try JSONEncoder().encode(report)
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["status"] as? String, "NOT_EXECUTED")
            XCTAssertEqual(object["ok"] as? Bool, false)
            XCTAssertEqual(object["type"] as? String, "file_regex")
            XCTAssertNotNil(object["detail"] as? String)

            let summary = ScenarioAssertionSummary.summarize([report])
            XCTAssertEqual(summary.notExecuted, 1)
            XCTAssertFalse(summary.allPassed)
        }
    }

    /// A forged `ok: true` beside NOT_EXECUTED still cannot pass, in the typed
    /// summary or in the host-phase predicate.
    func testNotExecutedIsNeverAPassEvenWithAnOkBoolean() {
        let forged = ScenarioAssertionReport(type: "file_exists", ok: true,
                                             detail: "forged",
                                             status: ScenarioAssertionStatus.notExecuted)
        XCTAssertFalse(forged.isPassing)
        let summary = ScenarioAssertionSummary.summarize([forged])
        XCTAssertEqual(summary.passed, 0)
        XCTAssertEqual(summary.notExecuted, 1)
        XCTAssertFalse(summary.allPassed)
        XCTAssertFalse(ScenarioAssertionGate.passes(
            status: ScenarioAssertionStatus.notExecuted, ok: true))
    }

    // MARK: - The completion fact

    func testRunCompletionFactRequiresEveryFact() throws {
        let openTurn = ScenarioRunCompletion.evaluate(
            plannedTurns: 1,
            turnReports: [ScenarioTurnReport(promptLen: 1, started: "s", ended: nil,
                                             modelRequests: 0, toolCalls: 0, events: 0)],
            terminalStatus: nil)
        XCTAssertFalse(openTurn.isComplete)
        XCTAssertTrue(try XCTUnwrap(openTurn.reason).contains("ended is null"))

        let missingTurn = ScenarioRunCompletion.evaluate(
            plannedTurns: 2,
            turnReports: [ScenarioTurnReport(promptLen: 1, started: "s", ended: "e",
                                             modelRequests: 0, toolCalls: 0, events: 0)],
            terminalStatus: nil)
        XCTAssertFalse(missingTurn.isComplete)
        XCTAssertTrue(try XCTUnwrap(missingTurn.reason).contains("1 of 2"))

        for status in ["TIMEOUT", "BUDGET", "ERROR"] {
            let terminal = ScenarioRunCompletion.evaluate(
                plannedTurns: 1,
                turnReports: [ScenarioTurnReport(promptLen: 1, started: "s", ended: "e",
                                                 modelRequests: 0, toolCalls: 0, events: 0)],
                terminalStatus: status)
            XCTAssertFalse(terminal.isComplete, "\(status) is not a completed run")
            XCTAssertTrue(try XCTUnwrap(terminal.reason).contains(status))
        }

        // An assertion verdict (FAIL) is decided after this fact and does not
        // make the run incomplete.
        XCTAssertTrue(ScenarioRunCompletion.evaluate(
            plannedTurns: 1,
            turnReports: [ScenarioTurnReport(promptLen: 1, started: "s", ended: "e",
                                             modelRequests: 0, toolCalls: 0, events: 0)],
            terminalStatus: nil).isComplete)
    }

    func testRunCompletionFactIsReconstructedFromAReportObject() throws {
        let timeout = try jsonObject("""
        {"status":"TIMEOUT","run_completed":false,
         "run_incomplete_reason":"the run ended with status TIMEOUT; 1 delivered turn(s) have no terminal end (ended is null)",
         "turns":[{"prompt_len":12,"started":"2026-10-25T00:00:00Z","ended":null}]}
        """)
        XCTAssertFalse(ScenarioRunCompletion.from(report: timeout).isComplete)

        let completed = try jsonObject("""
        {"status":"PENDING_HOST","run_completed":true,
         "turns":[{"prompt_len":12,"started":"2026-10-25T00:00:00Z","ended":"2026-10-25T00:00:05Z"}]}
        """)
        XCTAssertTrue(ScenarioRunCompletion.from(report: completed).isComplete)

        // A legacy report without the explicit fact is read from its evidence.
        let legacyComplete = try jsonObject("""
        {"status":"PASS","turns":[{"prompt_len":12,"started":"s","ended":"e"}]}
        """)
        XCTAssertTrue(ScenarioRunCompletion.from(report: legacyComplete).isComplete)

        let legacyTerminal = try jsonObject(#"{"status":"TIMEOUT"}"#)
        XCTAssertFalse(ScenarioRunCompletion.from(report: legacyTerminal).isComplete)

        let legacyOpenTurn = try jsonObject("""
        {"status":"PASS","turns":[{"prompt_len":12,"started":"s"}]}
        """)
        XCTAssertFalse(ScenarioRunCompletion.from(report: legacyOpenTurn).isComplete)
    }

    // MARK: - The simulator host phase

    /// A deferred `workspace_command` from an incomplete run must be finalized
    /// as NOT_EXECUTED, not run against the untouched fixture, and the terminal
    /// status must stay terminal. (Mirror of the completed-run host phase is in
    /// `PhoneDSHScenarioWorkspaceCommandTests`.)
    func testHostPhaseDoesNotEvaluateADeferredCommandFromAnIncompleteRun() throws {
        try withTemporaryRoot { root in
            let results = try makeResults(in: root)
            let id = "G2-FIX15-TIMEOUT"
            let scenarioRoot = results.appendingPathComponent(id, isDirectory: true)
            let workspace = scenarioRoot
                .appendingPathComponent("host/materialized/workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace,
                                                    withIntermediateDirectories: true)
            try Data("alpha\n## heading\n".utf8)
                .write(to: workspace.appendingPathComponent("a.txt"))
            let report: [String: Any] = [
                "id": id,
                "status": "TIMEOUT",
                "run_completed": false,
                "run_incomplete_reason": "the run ended with status TIMEOUT; "
                    + "1 delivered turn(s) have no terminal end (ended is null)",
                "turns": [["prompt_len": 12, "started": "2026-10-25T00:00:00Z"]],
                "assertions": [
                    ["type": "file_regex", "ok": true, "detail": "matches ^## "],
                    ["type": "workspace_command", "ok": false,
                     "detail": "pending_host: evaluated after the results are pulled",
                     "status": ScenarioAssertionStatus.pendingHost,
                     "command": "touch not-executed.txt"],
                ],
                "perturbations": [],
                "usage": ["wall_s": 1.0],
                "console_errors": [],
                "host_states": ["running"],
            ]
            let reportURL = scenarioRoot.appendingPathComponent("report.json")
            try JSONSerialization.data(withJSONObject: report,
                                       options: [.prettyPrinted, .sortedKeys])
                .write(to: reportURL)

            let summary = try ScenarioHostEvaluation.finalizeReports(in: results, ids: [id])
            XCTAssertEqual(summary.reports, 1)
            XCTAssertEqual(summary.assertionsEvaluated, 1,
                           "the deferred assertion is finalized to a real state")
            XCTAssertEqual(summary.remainingPending, 0)

            let rewritten = try jsonObject(String(contentsOf: reportURL, encoding: .utf8))
            XCTAssertEqual(rewritten["status"] as? String, "TIMEOUT",
                           "a terminal run status must not become PASS/FAIL")
            XCTAssertNil(rewritten["host_evaluated"],
                         "no workspace_command ran, so the report has no host marker")
            let assertions = try XCTUnwrap(rewritten["assertions"] as? [[String: Any]])
            XCTAssertEqual(assertions[1]["status"] as? String, "NOT_EXECUTED")
            XCTAssertEqual(assertions[1]["ok"] as? Bool, false)
            XCTAssertEqual(assertions[1]["command"] as? String, "touch not-executed.txt")
            XCTAssertNil(assertions[1]["host_evaluated"])
            XCTAssertNil(assertions[1]["duration_ms"])
            XCTAssertTrue((assertions[1]["detail"] as? String)?.contains("TIMEOUT") ?? false,
                          String(describing: assertions[1]["detail"]))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: scenarioRoot.appendingPathComponent("check-workspace").path),
                "the gated command must not be executed in a throwaway copy")
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent("not-executed.txt").path))
        }
    }

    // MARK: - Helpers

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        guard let dictionary = object as? [String: Any] else {
            throw ScenarioError.artifact("fixture is not a JSON object")
        }
        return dictionary
    }
}
