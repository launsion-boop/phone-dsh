// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: workspace_command host
// evaluation regression tests.
//
// Root cause these pin: `--run-on sim` evaluated `workspace_command`
// assertions inside the simulator test process, which cannot spawn `/bin/bash`;
// every such assertion was written as `exit -1: host process execution is not
// available ...` and the scenario was judged FAIL regardless of the model's
// work. The fix is one host evaluator (`ScenarioWorkspaceCommand`) shared by
// the macOS runner and the simulator host phase, with a provisional
// `pending_host` assertion / `PENDING_HOST` report status in between.
//
// The class name starts with `PhoneDSH` so the CI gate
// `swift test --filter 'PhoneDSH|PhoneDSHShell'` executes it.

import Foundation
import XCTest
@testable import PhoneDSHScenario

final class PhoneDSHScenarioWorkspaceCommandTests: XCTestCase {
    private static let hostMarkerPrefix =
        "[environment: host-bash; worker VFS: not used; path: /dsh/workspace -> "

    private static var repositoryRoot: URL {
        guard let root = scenarioRepositoryRoot(startingAt: URL(fileURLWithPath: #filePath)) else {
            preconditionFailure("cannot locate the repository root from #filePath")
        }
        return root
    }

    // MARK: Fixtures

    @discardableResult
    private func makeWorkspace(in root: URL,
                               files: [String: String]) throws -> URL {
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        for (path, content) in files {
            let url = workspace.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        return workspace
    }

    private func withTemporaryRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-scenario-workspace-command-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScenarioError.artifact("not a JSON object: \(url.path)")
        }
        return object
    }

    // MARK: Deferral (the simulator path)

    /// The simulator's decision must be "pending host", not a failed process
    /// spawn: no `check-workspace` copy and no command side effect may appear
    /// in the iOS bundle. `hostAvailable: false` is the same branch the iOS
    /// compile takes (`ScenarioWorkspaceCommand.hostProcessesAvailable`).
    func testSimulatorDeferralRecordsPendingHostWithoutSpawningOrCopying() throws {
        try withTemporaryRoot { root in
            let workspace = try makeWorkspace(in: root, files: ["a.txt": "scenario\n"])
            let results = root.appendingPathComponent("results", isDirectory: true)
            try FileManager.default.createDirectory(at: results,
                                                    withIntermediateDirectories: true)
            let disposition = try ScenarioWorkspaceCommand.evaluateOrDefer(
                command: "touch should-not-run.txt",
                workspace: workspace,
                resultsDirectory: results,
                hostAvailable: false)
            guard case .pendingHost(let command) = disposition else {
                XCTFail("the simulator path must defer the command, got \(disposition)")
                return
            }
            XCTAssertEqual(command, "touch should-not-run.txt")
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: results.appendingPathComponent("check-workspace").path),
                "the deferred path must not create the host check-workspace copy")
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: workspace.appendingPathComponent("should-not-run.txt").path),
                "the deferred path must not execute the command")
            XCTAssertTrue(ScenarioWorkspaceCommand.hostProcessesAvailable,
                          "this regression suite runs on macOS, where the host can spawn")
        }
    }

    // MARK: One evaluator

    /// The command runs against a throwaway copy, `/dsh/workspace` is rewritten
    /// to that copy, and exit 0 is the verdict — the macOS semantics both
    /// callers now share.
    func testEvaluationCopiesWorkspaceRewritesDshWorkspaceAndPasses() throws {
        try withTemporaryRoot { root in
            let workspace = try makeWorkspace(in: root, files: [
                "a.txt": "scenario\n",
                "sub/b.txt": "beta\n",
            ])
            let results = root.appendingPathComponent("results", isDirectory: true)
            try FileManager.default.createDirectory(at: results,
                                                    withIntermediateDirectories: true)
            let outcome = try ScenarioWorkspaceCommand.evaluate(
                command: "test -f /dsh/workspace/a.txt "
                    + "&& grep -qx scenario /dsh/workspace/a.txt "
                    + "&& test -s sub/b.txt",
                workspace: workspace,
                resultsDirectory: results)
            XCTAssertTrue(outcome.ok, outcome.detail)
            XCTAssertEqual(outcome.status, 0)
            XCTAssertEqual(outcome.semantics.id, "host-bash")
            XCTAssertFalse(outcome.semantics.workerVFS,
                           "the Mac host must never claim Worker VFS execution")
            XCTAssertEqual(outcome.semantics.shell, "/bin/bash")
            XCTAssertEqual(outcome.semantics.timeoutSeconds,
                           ScenarioHostCommandSemantics.defaultTimeoutSeconds)
            XCTAssertEqual(outcome.detail,
                           "exit 0\n" + outcome.semantics.detailMarker)
            XCTAssertTrue(outcome.detail.contains("host-bash"), outcome.detail)
            XCTAssertTrue(outcome.detail.contains("worker VFS: not used"), outcome.detail)
            XCTAssertGreaterThanOrEqual(outcome.durationMs, 0)
            let copy = results.appendingPathComponent("check-workspace", isDirectory: true)
            XCTAssertEqual(outcome.semantics.pathRewrite.to, copy.path)
            XCTAssertTrue(outcome.detail.contains("path: /dsh/workspace -> \(copy.path)"),
                          outcome.detail)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: copy.appendingPathComponent("a.txt").path))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: copy.appendingPathComponent("sub/b.txt").path))
            // The command runs against the copy, so the materialized workspace
            // is not modified by a passing assertion.
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent("check-workspace").path))
        }
    }

    func testEvaluationStillFailsWhenTheCommandFails() throws {
        try withTemporaryRoot { root in
            let workspace = try makeWorkspace(in: root, files: ["a.txt": "scenario\n"])
            let results = root.appendingPathComponent("results", isDirectory: true)
            try FileManager.default.createDirectory(at: results,
                                                    withIntermediateDirectories: true)
            let outcome = try ScenarioWorkspaceCommand.evaluate(
                command: "test -f /dsh/workspace/missing.txt",
                workspace: workspace,
                resultsDirectory: results)
            XCTAssertFalse(outcome.ok)
            XCTAssertNotEqual(outcome.status, 0)
            XCTAssertTrue(outcome.detail.hasPrefix("exit "), outcome.detail)
        }
    }

    /// A missing materialized workspace is a typed failure, not a crash: the
    /// host phase turns it into a failed assertion with that detail.
    func testEvaluationThrowsWhenTheMaterializedWorkspaceIsMissing() throws {
        try withTemporaryRoot { root in
            let results = root.appendingPathComponent("results", isDirectory: true)
            try FileManager.default.createDirectory(at: results,
                                                    withIntermediateDirectories: true)
            XCTAssertThrowsError(try ScenarioWorkspaceCommand.evaluate(
                command: "true",
                workspace: root.appendingPathComponent("missing", isDirectory: true),
                resultsDirectory: results)) { error in
                    XCTAssertTrue(String(describing: error).contains("materialized workspace"),
                                  String(describing: error))
                }
        }
    }

    // MARK: Host phase (pulled simulator report)

    private struct PulledReport {
        var resultsRoot: URL
        var reportURL: URL
        var scenarioRoot: URL
    }

    private func makePulledReport(resultsRoot: URL,
                                  id: String,
                                  status: String,
                                  assertions: [[String: Any]],
                                  workspaceFiles: [String: String]) throws -> PulledReport {
        let scenarioRoot = resultsRoot.appendingPathComponent(id, isDirectory: true)
        let workspace = scenarioRoot
            .appendingPathComponent("host/materialized/workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)
        for (path, content) in workspaceFiles {
            let url = workspace.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        let report: [String: Any] = [
            "id": id,
            "status": status,
            "assertions": assertions,
            "turns": [[
                "prompt_len": 12,
                "started": "2026-10-25T00:00:00Z",
                "ended": "2026-10-25T00:00:05Z",
                "model_requests": 1,
            ]],
            "perturbations": [],
            "usage": ["wall_s": 1.5],
            "console_errors": [],
            "host_states": ["running"],
        ]
        let reportURL = scenarioRoot.appendingPathComponent("report.json")
        let data = try JSONSerialization.data(withJSONObject: report,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: reportURL)
        return PulledReport(resultsRoot: resultsRoot, reportURL: reportURL,
                            scenarioRoot: scenarioRoot)
    }

    private func pendingAssertion(_ command: String) -> [String: Any] {
        [
            "type": "workspace_command",
            "ok": false,
            "detail": "pending_host: evaluated after the results are pulled",
            "status": "pending_host",
            "command": command,
        ]
    }

    func testHostPhaseFinalizesAPendingAssertionToPass() throws {
        try withTemporaryRoot { root in
            let results = root.appendingPathComponent("results", isDirectory: true)
            try FileManager.default.createDirectory(at: results,
                                                    withIntermediateDirectories: true)
            let command = "test -f /dsh/workspace/a.txt "
                + "&& grep -qx scenario /dsh/workspace/a.txt"
            let pulled = try makePulledReport(
                resultsRoot: results,
                id: "G2-REGRESSION-PASS",
                status: "PENDING_HOST",
                assertions: [
                    ["type": "file_exists", "ok": true, "detail": "exists: a.txt"],
                    pendingAssertion(command),
                ],
                workspaceFiles: ["a.txt": "scenario\n"])
            let summary = try ScenarioHostEvaluation.finalizeReports(
                in: results, ids: ["G2-REGRESSION-PASS"])
            XCTAssertEqual(summary.reports, 1)
            XCTAssertEqual(summary.assertionsEvaluated, 1)
            XCTAssertEqual(summary.remainingPending, 0)

            let report = try readJSON(pulled.reportURL)
            XCTAssertEqual(report["status"] as? String, "PASS")
            XCTAssertEqual(report["host_evaluated"] as? Bool, true)
            // Existing fields are preserved, only the deferred assertion changes.
            XCTAssertNotNil(report["turns"])
            XCTAssertEqual((report["usage"] as? [String: Any])?["wall_s"] as? Double, 1.5)
            let assertions = try XCTUnwrap(report["assertions"] as? [[String: Any]])
            XCTAssertEqual(assertions.count, 2)
            XCTAssertNil(assertions[0]["host_evaluated"])
            let evaluated = assertions[1]
            XCTAssertEqual(evaluated["type"] as? String, "workspace_command")
            XCTAssertEqual(evaluated["ok"] as? Bool, true)
            XCTAssertEqual(evaluated["status"] as? String, "host_evaluated")
            XCTAssertEqual(evaluated["host_evaluated"] as? Bool, true)
            XCTAssertNotNil(evaluated["duration_ms"])
            XCTAssertEqual(evaluated["command"] as? String, command)
            let evaluatedDetail = try XCTUnwrap(evaluated["detail"] as? String)
            XCTAssertTrue(evaluatedDetail.hasPrefix("exit 0"),
                          evaluatedDetail)
            XCTAssertTrue(evaluatedDetail.contains(Self.hostMarkerPrefix),
                          evaluatedDetail)
            XCTAssertTrue(evaluatedDetail.contains("check-workspace"), evaluatedDetail)
            // The host phase runs against the pulled materialized workspace
            // and leaves the throwaway copy for diagnosis.
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: pulled.scenarioRoot
                    .appendingPathComponent("check-workspace/a.txt").path))
        }
    }

    func testHostPhaseFinalizesAPendingAssertionToFail() throws {
        try withTemporaryRoot { root in
            let results = root.appendingPathComponent("results", isDirectory: true)
            try FileManager.default.createDirectory(at: results,
                                                    withIntermediateDirectories: true)
            let pulled = try makePulledReport(
                resultsRoot: results,
                id: "G2-REGRESSION-FAIL",
                status: "PENDING_HOST",
                assertions: [pendingAssertion("test -f /dsh/workspace/missing.txt")],
                workspaceFiles: ["a.txt": "scenario\n"])
            let summary = try ScenarioHostEvaluation.finalizeReports(
                in: results, ids: ["G2-REGRESSION-FAIL"])
            XCTAssertEqual(summary.assertionsEvaluated, 1)
            let report = try readJSON(pulled.reportURL)
            XCTAssertEqual(report["status"] as? String, "FAIL")
            XCTAssertEqual(report["host_evaluated"] as? Bool, true)
            let assertions = try XCTUnwrap(report["assertions"] as? [[String: Any]])
            XCTAssertEqual(assertions[0]["ok"] as? Bool, false)
            XCTAssertEqual(assertions[0]["status"] as? String, "host_evaluated")
            let failedDetail = try XCTUnwrap(assertions[0]["detail"] as? String)
            XCTAssertTrue(failedDetail.hasPrefix("exit "), failedDetail)
            XCTAssertTrue(failedDetail.contains(Self.hostMarkerPrefix), failedDetail)
        }
    }

    /// A run-level terminal status is preserved, and a deferred command from
    /// that incomplete run is finalized as NOT_EXECUTED rather than evaluated
    /// against the fixture-or-partial workspace (G2-FIX-15). The assertion is
    /// still filled in (no `pending_host` survives), but no host command ran,
    /// so the report carries no host-evaluated marker.
    func testHostPhaseKeepsATerminalStatusButStillFillsTheAssertion() throws {
        try withTemporaryRoot { root in
            let results = root.appendingPathComponent("results", isDirectory: true)
            try FileManager.default.createDirectory(at: results,
                                                    withIntermediateDirectories: true)
            let pulled = try makePulledReport(
                resultsRoot: results,
                id: "G2-REGRESSION-TIMEOUT",
                status: "TIMEOUT",
                assertions: [pendingAssertion("test -f /dsh/workspace/a.txt")],
                workspaceFiles: ["a.txt": "scenario\n"])
            let summary = try ScenarioHostEvaluation.finalizeReports(
                in: results, ids: ["G2-REGRESSION-TIMEOUT"])
            XCTAssertEqual(summary.assertionsEvaluated, 1)
            XCTAssertEqual(summary.remainingPending, 0)
            let report = try readJSON(pulled.reportURL)
            XCTAssertEqual(report["status"] as? String, "TIMEOUT")
            XCTAssertNil(report["host_evaluated"])
            let assertions = try XCTUnwrap(report["assertions"] as? [[String: Any]])
            XCTAssertEqual(assertions[0]["ok"] as? Bool, false)
            XCTAssertEqual(assertions[0]["status"] as? String, "NOT_EXECUTED")
            XCTAssertNil(assertions[0]["host_evaluated"])
            XCTAssertTrue((assertions[0]["detail"] as? String)?.contains("not executed") ?? false,
                          String(describing: assertions[0]["detail"]))
        }
    }

    /// A report outside this run's selection is left untouched, so concurrent
    /// lanes sharing a `--results` directory cannot rewrite each other's tree.
    func testHostPhaseOnlyTouchesTheRequestedScenarioIds() throws {
        try withTemporaryRoot { root in
            let results = root.appendingPathComponent("results", isDirectory: true)
            try FileManager.default.createDirectory(at: results,
                                                    withIntermediateDirectories: true)
            let mine = try makePulledReport(
                resultsRoot: results,
                id: "G2-MINE",
                status: "PENDING_HOST",
                assertions: [pendingAssertion("test -f a.txt")],
                workspaceFiles: ["a.txt": "scenario\n"])
            let other = try makePulledReport(
                resultsRoot: results,
                id: "G2-OTHER",
                status: "PENDING_HOST",
                assertions: [pendingAssertion("test -f a.txt")],
                workspaceFiles: ["a.txt": "scenario\n"])
            let summary = try ScenarioHostEvaluation.finalizeReports(
                in: results, ids: ["G2-MINE"])
            XCTAssertEqual(summary.reports, 1)
            XCTAssertEqual(summary.assertionsEvaluated, 1)
            XCTAssertEqual(try readJSON(mine.reportURL)["status"] as? String, "PASS")
            let otherReport = try readJSON(other.reportURL)
            XCTAssertEqual(otherReport["status"] as? String, "PENDING_HOST")
            let otherAssertions = try XCTUnwrap(
                otherReport["assertions"] as? [[String: Any]])
            XCTAssertEqual(otherAssertions[0]["status"] as? String, "pending_host")
        }
    }

    // MARK: One implementation, no simulator process

    /// The macOS runner and the host phase both reach the one evaluator, and
    /// the simulator test bundle has no process-spawning code at all. This is a
    /// source-level pin because the wrong state cannot be compiled here for
    /// iOS; the deferral branch itself is covered above.
    func testOneSharedEvaluationAndNoSimulatorProcessSpawn() throws {
        let root = Self.repositoryRoot
        let runner = try String(contentsOf: root.appendingPathComponent(
            "Sources/PhoneDSHScenario/ScenarioRun.swift"), encoding: .utf8)
        XCTAssertTrue(runner.contains("ScenarioAssertionEvaluator("),
                      "the scenario runner must use the shared assertion evaluator")
        XCTAssertTrue(runner.contains("completion: completion"),
                      "the runner must pass the run-completion gate to the evaluator")
        XCTAssertFalse(runner.contains("ScenarioProcess.bash"),
                       "the runner must not keep a second bash evaluation path")

        // The report-path evaluator (and its one workspace_command call) lives
        // in the G2-FIX-15 gate file; it is the same implementation for the
        // macOS runner and the simulator host phase.
        let evaluator = try String(contentsOf: root.appendingPathComponent(
            "Sources/PhoneDSHScenario/ScenarioAssertionGate.swift"),
            encoding: .utf8)
        XCTAssertTrue(evaluator.contains("ScenarioWorkspaceCommand.evaluateOrDefer"),
                      "the scenario report path must call the shared evaluator")
        XCTAssertTrue(evaluator.contains("ScenarioAssertionStatus.pendingHost"),
                      "the iOS path must record the assertion as pending_host")

        let shared = try String(contentsOf: root.appendingPathComponent(
            "Sources/PhoneDSHScenario/ScenarioWorkspaceCommand.swift"),
            encoding: .utf8)
        XCTAssertTrue(shared.contains("static func evaluateOrDefer"),
                      "the shared evaluator entry point is missing")

        let simulatorTarget = root.appendingPathComponent(
            "examples/probe-app/PhoneDSHScenarioSimTests", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: simulatorTarget, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "the simulator test target has no Swift sources")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("Process("),
                           "\(file.lastPathComponent) must not spawn a host process")
        }
    }
}
