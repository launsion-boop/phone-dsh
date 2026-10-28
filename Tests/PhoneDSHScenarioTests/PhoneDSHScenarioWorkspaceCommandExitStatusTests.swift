// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: the real process termination
// status must become the `workspace_command` assertion verdict.
//
// The G2 real-model batch exposed `workspace_command` reports whose detail was
// `exit 0` while the command should have failed silently (no stdout/stderr).
// The root-cause investigation for this fix found that on the committed head
// the evaluator already propagates `Process.terminationStatus` unconditionally;
// the batch evidence came from a stale `scenario.json` snapshot that disagreed
// with the repaired catalog entry the runner actually read (the evaluated
// commands really did exit 0). These tests pin the propagation mechanism so
// that class of failure can never silently come back:
//
//   * a command that exits non-zero without output is a failure;
//   * the G2-A04 shapes (integer compare, python `exit(0 if cond else 1)`) and
//     the G2-A01 shape (line-count compare) all fail with their real status;
//   * the same verdict comes out of the simulator host phase that finalizes a
//     pulled `pending_host` report;
//   * a loud failure (exit 2 + stderr) stays `ok: false` with the output
//     visible, exactly as the earlier history attempts recorded it;
//   * display-only tail truncation (G2-FIX-14) never changes the verdict.

import Foundation
import XCTest
@testable import PhoneDSHScenario

final class PhoneDSHScenarioWorkspaceCommandExitStatusTests: XCTestCase {
    // MARK: Fixtures

    /// 15 newline-terminated lines: the shape of the G2-A04 `clean.csv` that
    /// the defective assertion compared with 16.
    private static let fifteenLineFixture: String = {
        var lines = ["date,merchant,amount,currency"]
        for index in 1...14 {
            lines.append(String(format: "2026-01-%02d,merchant-%02d,1.00,CNY", index, index))
        }
        return lines.joined(separator: "\n") + "\n"
    }()

    /// 16 newline-terminated lines: the shape of the G2-A01 `INDEX.md` that the
    /// defective assertion compared with 10.
    private static let sixteenLineFixture: String = {
        var lines = ["# index"]
        for index in 1...15 {
            lines.append(String(format: "entry-%02d", index))
        }
        return lines.joined(separator: "\n") + "\n"
    }()

    private func withWorkspace(
        files: [String: String],
        _ body: (URL, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-scenario-exit-status-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)
        for (path, content) in files {
            let url = workspace.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        let results = root.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: results,
                                                withIntermediateDirectories: true)
        try body(workspace, results)
    }

    /// The evaluator call the macOS runner makes for one `workspace_command`
    /// assertion. `evaluate` is the single implementation both the macOS runner
    /// and the simulator host phase call; the assertion's `ok`/`detail` are
    /// derived from this outcome's `status`, which is the process termination
    /// status.
    private func evaluate(_ command: String,
                          workspace: URL,
                          results: URL) throws -> ScenarioWorkspaceCommandOutcome {
        try ScenarioWorkspaceCommand.evaluate(command: command,
                                              workspace: workspace,
                                              resultsDirectory: results,
                                              timeout: 30)
    }

    /// G2-FIX-35: the verdict is followed by exactly one host-environment
    /// line. For a real evaluation the marker names the actual throwaway copy.
    private func assertDetail(_ detail: String,
                              verdict: String,
                              outcome: ScenarioWorkspaceCommandOutcome,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertEqual(detail, verdict + "\n" + outcome.semantics.detailMarker,
                       file: file, line: line)
        XCTAssertTrue(outcome.semantics.detailMarker.hasPrefix(
            "[environment: host-bash; worker VFS: not used; path: /dsh/workspace -> "),
                      outcome.semantics.detailMarker, file: file, line: line)
    }

    /// The host phase has no outcome value, only the rewritten detail string.
    /// A failing command may append `: <output>` after the verdict, so the
    /// environment line must be checked as its own line rather than directly
    /// after the verdict (the loud-failure case is `exit 2: boom\n[...]`).
    private func assertHostPhaseDetail(_ detail: String,
                                       verdict: String,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        XCTAssertTrue(detail.hasPrefix(verdict), detail, file: file, line: line)
        XCTAssertTrue(detail.contains(
            "\n[environment: host-bash; worker VFS: not used; path: /dsh/workspace -> "),
                      detail, file: file, line: line)
        XCTAssertTrue(detail.hasSuffix("]"), detail, file: file, line: line)
        XCTAssertTrue(detail.contains("check-workspace"),
                      "\(detail)\nthe marker must name the materialized copy: \(detail)",
                      file: file, line: line)
    }

    // MARK: 1. A silent non-zero exit

    /// `bash -c 'exit 1'` writes nothing and must still fail with status 1.
    func testSilentExitOneWithoutOutputIsAFailure() throws {
        try withWorkspace(files: ["a.txt": "scenario\n"]) { workspace, results in
            let outcome = try evaluate("bash -c 'exit 1'",
                                       workspace: workspace, results: results)
            XCTAssertEqual(outcome.stdout, "", "the command must stay silent")
            XCTAssertEqual(outcome.stderr, "", "the command must stay silent")
            XCTAssertFalse(outcome.timedOut)
            XCTAssertEqual(outcome.status, 1,
                           "the real termination status must be recorded")
            XCTAssertFalse(outcome.ok, "a silent exit 1 must not be upgraded to a pass")
            assertDetail(outcome.detail, verdict: "exit 1", outcome: outcome)
        }
    }

    /// Whitespace-only output is still "no failure output": trimming it must
    /// not turn a non-zero exit into a pass or hide the exit code.
    func testWhitespaceOnlyOutputDoesNotHideANonZeroExit() throws {
        try withWorkspace(files: ["a.txt": "scenario\n"]) { workspace, results in
            let outcome = try evaluate("printf '   \\n'; exit 1",
                                       workspace: workspace, results: results)
            XCTAssertEqual(outcome.status, 1)
            XCTAssertFalse(outcome.ok)
            assertDetail(outcome.detail, verdict: "exit 1", outcome: outcome)
        }
    }

    // MARK: 2. The G2-A04 assertion-3 shape (integer compare)

    /// `test "$(wc -l < clean.csv)" -eq 16` on a 15-line file exits 1 with no
    /// output.
    func testIntegerCompareMismatchOnAQuietFailureIsAFailure() throws {
        try withWorkspace(files: ["clean.csv": Self.fifteenLineFixture]) {
            workspace, results in
            let command = "test \"$(wc -l < clean.csv)\" -eq 16"
            let outcome = try evaluate(command, workspace: workspace, results: results)
            XCTAssertEqual(outcome.status, 1,
                           "`test` must report 1 when 15 != 16, got \(outcome.status)")
            XCTAssertFalse(outcome.ok)
            assertDetail(outcome.detail, verdict: "exit 1", outcome: outcome)
        }
    }

    // MARK: 3. The G2-A04 assertion-4 shape (python conditional)

    /// The python one-liner from the batch with a false condition:
    /// `exit(0 if <cond> else 1)` writes no output, so only the process status
    /// can distinguish pass from failure.
    func testPythonConditionalFalseWithoutOutputIsAFailure() throws {
        try withWorkspace(files: ["clean.csv": Self.fifteenLineFixture]) {
            workspace, results in
            let command = "python3 -c \"import csv;rows=list(csv.reader(open('clean.csv')));"
                + "h=rows[0];b=[tuple(f.strip() for f in r) for r in rows[1:]];"
                + "exit(0 if h==['date','merchant','amount','currency'] "
                + "and len(set(b))==15 and all(f==f.strip() for r in b for f in r) else 1)\""
            let outcome = try evaluate(command, workspace: workspace, results: results)
            XCTAssertEqual(outcome.status, 1,
                           "the false python condition must terminate with 1")
            XCTAssertFalse(outcome.ok)
            assertDetail(outcome.detail, verdict: "exit 1", outcome: outcome)
        }
    }

    // MARK: 4. The G2-A01 assertion-6 shape (line-count compare)

    /// `test "$(wc -l < INDEX.md)" -eq 10` on a 16-line file: a different file
    /// and threshold, the same "quiet integer compare" mechanism.
    func testLineCountCompareMismatchOnAQuietFailureIsAFailure() throws {
        try withWorkspace(files: ["INDEX.md": Self.sixteenLineFixture]) {
            workspace, results in
            let command = "test \"$(wc -l < INDEX.md)\" -eq 10"
            let outcome = try evaluate(command, workspace: workspace, results: results)
            XCTAssertEqual(outcome.status, 1)
            XCTAssertFalse(outcome.ok)
            assertDetail(outcome.detail, verdict: "exit 1", outcome: outcome)
        }
    }

    // MARK: 5. Exit 0 is still a pass

    /// The unconditional status propagation must not invert: a silent command
    /// that really exits 0 stays a pass.
    func testSilentExitZeroStillPasses() throws {
        try withWorkspace(files: ["a.txt": "scenario\n"]) { workspace, results in
            let outcome = try evaluate("bash -c 'exit 0'",
                                       workspace: workspace, results: results)
            XCTAssertEqual(outcome.status, 0)
            XCTAssertTrue(outcome.ok)
            assertDetail(outcome.detail, verdict: "exit 0", outcome: outcome)
        }
    }

    // MARK: 6. The loud-failure path stays loud

    /// The earlier attempts captured `exit 2` together with the stderr text; a
    /// loud failure must keep both the status and the output.
    func testLoudFailureKeepsStatusAndStderr() throws {
        try withWorkspace(files: ["a.txt": "scenario\n"]) { workspace, results in
            let outcome = try evaluate("printf 'boom\\n' >&2; exit 2",
                                       workspace: workspace, results: results)
            XCTAssertEqual(outcome.status, 2)
            XCTAssertFalse(outcome.ok)
            XCTAssertTrue(outcome.detail.hasPrefix("exit 2"), outcome.detail)
            XCTAssertTrue(outcome.detail.contains("boom"),
                          "the failure output must stay visible: \(outcome.detail)")
            XCTAssertTrue(outcome.detail.contains(outcome.semantics.detailMarker),
                          "the host environment line must stay visible: \(outcome.detail)")
        }
    }

    // MARK: 7. Display truncation is not part of the verdict

    /// G2-FIX-14 truncates the displayed tail only. A failure whose output
    /// exceeds the tail bound must keep the real status and stay a failure.
    func testTruncatedFailureOutputDoesNotAffectTheVerdict() throws {
        try withWorkspace(files: ["a.txt": "scenario\n"]) { workspace, results in
            let command = "i=0; while [ \"$i\" -lt 5000 ]; do printf 'x'; "
                + "i=$((i + 1)); done; printf 'tail-marker\\n' >&2; exit 1"
            let outcome = try evaluate(command, workspace: workspace, results: results)
            XCTAssertEqual(outcome.status, 1)
            XCTAssertFalse(outcome.ok)
            XCTAssertTrue(outcome.detail.hasPrefix("exit 1"), outcome.detail)
            XCTAssertTrue(outcome.detail.contains("tail-marker"),
                          "the displayed tail must include the end of stderr")
            XCTAssertLessThanOrEqual(outcome.combinedTail.count, 1_300,
                                     "the displayed tail stays bounded")
            XCTAssertTrue(outcome.detail.contains(outcome.semantics.detailMarker),
                          "the host environment line is additive, not truncated output")
        }
    }

    // MARK: 8. The simulator host phase shares the verdict

    /// Writes a pulled simulator report with one deferred `workspace_command`
    /// assertion plus a materialized workspace, runs the real host-phase
    /// finalizer, and returns the rewritten report.
    private func finalizePulledReport(
        command: String,
        workspaceFiles: [String: String]
    ) throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-scenario-host-phase-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = "G2-EXIT-STATUS"
        let scenarioRoot = root.appendingPathComponent(id, isDirectory: true)
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
            "status": ScenarioAssertionStatus.pendingHostReport,
            "assertions": [[
                "type": "workspace_command",
                "ok": false,
                "detail": "pending_host: evaluated after the results are pulled",
                "status": ScenarioAssertionStatus.pendingHost,
                "command": command,
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: report,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: scenarioRoot.appendingPathComponent("report.json"))
        let summary = try ScenarioHostEvaluation.finalizeReports(in: root, ids: [id])
        XCTAssertEqual(summary.assertionsEvaluated, 1)
        XCTAssertEqual(summary.remainingPending, 0)
        let rewritten = try Data(contentsOf: scenarioRoot.appendingPathComponent("report.json"))
        guard let object = try JSONSerialization.jsonObject(with: rewritten) as? [String: Any] else {
            throw ScenarioError.artifact("rewritten report is not a JSON object")
        }
        return object
    }

    private func assertions(in report: [String: Any]) throws -> [[String: Any]] {
        guard let assertions = report["assertions"] as? [[String: Any]] else {
            throw ScenarioError.artifact("report has no assertions array")
        }
        return assertions
    }

    /// The simulator writes `pending_host`; the host phase must finalize the
    /// same silent failure to `ok: false` with the real exit code, not to the
    /// provisional `ok: false` that the report happened to carry.
    func testHostPhaseFinalizesASilentFailureWithTheRealExitCode() throws {
        let report = try finalizePulledReport(
            command: "test \"$(wc -l < clean.csv)\" -eq 16",
            workspaceFiles: ["clean.csv": Self.fifteenLineFixture])
        XCTAssertEqual(report["status"] as? String, "FAIL")
        XCTAssertEqual(report["host_evaluated"] as? Bool, true)
        let assertion = try XCTUnwrap(assertions(in: report).first)
        XCTAssertEqual(assertion["type"] as? String, "workspace_command")
        XCTAssertEqual(assertion["ok"] as? Bool, false)
        let detail = try XCTUnwrap(assertion["detail"] as? String)
        assertHostPhaseDetail(detail, verdict: "exit 1")
        XCTAssertEqual(assertion["status"] as? String,
                       ScenarioAssertionStatus.hostEvaluated)
        XCTAssertEqual(assertion["host_evaluated"] as? Bool, true)
        XCTAssertEqual(assertion["command"] as? String,
                       "test \"$(wc -l < clean.csv)\" -eq 16",
                       "the executed command stays on the assertion for the judge")
        XCTAssertNotNil(assertion["duration_ms"])
    }

    /// The host phase must keep a loud failure's status and stderr visible.
    func testHostPhaseKeepsALoudFailureLoud() throws {
        let report = try finalizePulledReport(
            command: "printf 'boom\\n' >&2; exit 2",
            workspaceFiles: ["a.txt": "scenario\n"])
        XCTAssertEqual(report["status"] as? String, "FAIL")
        let assertion = try XCTUnwrap(assertions(in: report).first)
        XCTAssertEqual(assertion["ok"] as? Bool, false)
        let detail = try XCTUnwrap(assertion["detail"] as? String)
        assertHostPhaseDetail(detail, verdict: "exit 2")
        XCTAssertTrue(detail.contains("boom"), detail)
    }

    /// A host-phase failure with both streams must keep the verdict/output
    /// block and still put the environment line on its own line. This is the
    /// shape that exposed the earlier `verdict + "\n[environment..."` helper:
    /// the real failure detail is `exit 3: stdout...stderr\n[environment...]`.
    func testHostPhaseKeepsOutputOnItsOwnLineBeforeTheEnvironmentLine() throws {
        let report = try finalizePulledReport(
            command: "printf 'stdout-line\\n'; printf 'stderr-line\\n' >&2; exit 3",
            workspaceFiles: ["a.txt": "scenario\n"])
        XCTAssertEqual(report["status"] as? String, "FAIL")
        let assertion = try XCTUnwrap(assertions(in: report).first)
        XCTAssertEqual(assertion["ok"] as? Bool, false)
        let detail = try XCTUnwrap(assertion["detail"] as? String)
        assertHostPhaseDetail(detail, verdict: "exit 3")
        XCTAssertTrue(detail.hasPrefix("exit 3: "),
                      "the output follows the verdict: \(detail)")
        XCTAssertTrue(detail.contains("stdout-line"), detail)
        XCTAssertTrue(detail.contains("stderr-line"), detail)
    }

    /// The host phase confirms a genuinely passing command as PASS.
    func testHostPhaseFinalizesAGenuinePass() throws {
        let report = try finalizePulledReport(
            command: "test \"$(wc -l < clean.csv)\" -eq 15",
            workspaceFiles: ["clean.csv": Self.fifteenLineFixture])
        XCTAssertEqual(report["status"] as? String, "PASS")
        let assertion = try XCTUnwrap(assertions(in: report).first)
        XCTAssertEqual(assertion["ok"] as? Bool, true)
        let detail = try XCTUnwrap(assertion["detail"] as? String)
        assertHostPhaseDetail(detail, verdict: "exit 0")
    }
}
