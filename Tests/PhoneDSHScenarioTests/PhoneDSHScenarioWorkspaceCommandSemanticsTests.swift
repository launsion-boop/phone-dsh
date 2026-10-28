// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2-FIX-35: the host `workspace_command` semantics are
// explicit, and a command that needs the Worker VFS is rejected instead of
// producing a host-only fake success.
//
// The old evaluator rewrote only `/dsh/workspace` and ran everything else
// unchanged under the Mac's `/bin/bash`. A command such as
// `test -d /dsh/home || true` therefore exited 0 on the host because
// `/dsh/home` simply does not exist there, while the model's Worker VFS may
// have had it. These tests pin the typed, pre-execution rejection and the
// stable environment line that tells a reviewer the verdict is host
// acceptance, not Worker VFS evidence.
//
// The class name starts with `PhoneDSH` so the CI gate
// `swift test --filter 'PhoneDSH|PhoneDSHShell'` executes it.

import Foundation
import XCTest
@testable import PhoneDSHScenario

final class PhoneDSHScenarioWorkspaceCommandSemanticsTests: XCTestCase {
    private func withTemporaryWorkspace(files: [String: String] = ["a.txt": "scenario\n"],
                                        _ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-host-semantics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
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

    // MARK: Semantics value

    func testHostBashSemanticsAreStableAndExplicit() {
        let semantics = ScenarioHostCommandSemantics.hostBash
        XCTAssertEqual(semantics.id, "host-bash")
        XCTAssertFalse(semantics.workerVFS)
        XCTAssertEqual(semantics.shell, "/bin/bash")
        XCTAssertEqual(semantics.path,
                       "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(semantics.pathRewrite.from, "/dsh/workspace")
        XCTAssertEqual(semantics.pathRewrite.to, "<copy>")
        XCTAssertEqual(semantics.timeoutSeconds,
                       ScenarioHostCommandSemantics.defaultTimeoutSeconds)
        XCTAssertEqual(semantics.detailMarker,
                       "[environment: host-bash; worker VFS: not used; "
                        + "path: /dsh/workspace -> <copy>]")
    }

    /// The environment line is part of every outcome, including a synthetic
    /// value used by a display test; it is not conditional on a process run.
    func testEveryOutcomeDetailCarriesTheEnvironmentLine() {
        let outcome = ScenarioWorkspaceCommandOutcome(status: 0,
                                                      timedOut: false,
                                                      durationMs: 0,
                                                      stdout: "",
                                                      stderr: "")
        XCTAssertEqual(outcome.detail,
                       "exit 0\n" + ScenarioHostCommandSemantics.hostBash.detailMarker)
    }

    // MARK: Path classification

    func testOnlyTheWorkspaceTreeIsRewritableOnTheHost() {
        for command in [
            "test -f /dsh/workspace/a.txt",
            "test -f /dsh/workspace/sub/a.txt",
            "cd /dsh/workspace && test -f a.txt",
            "test -d /dsh/workspace",
            "test -d /dsh/workspace/",
            "test -d '/dsh/workspace'",
            "echo /dsh/workspace",
            "echo no virtual paths here",
        ] {
            XCTAssertNil(ScenarioWorkspaceCommand.workerVFSOnlyPath(in: command),
                         "the workspace rewrite must accept: \(command)")
        }

        XCTAssertEqual(
            ScenarioWorkspaceCommand.workerVFSOnlyPath(
                in: "test -d /dsh/home || true"),
            "/dsh/home")
        XCTAssertEqual(
            ScenarioWorkspaceCommand.workerVFSOnlyPath(
                in: "test -d /dsh/tmp/scratch"),
            "/dsh/tmp/scratch")
        // A sibling of the workspace is not the workspace tree.
        XCTAssertEqual(
            ScenarioWorkspaceCommand.workerVFSOnlyPath(
                in: "test -d /dsh/workspace-archive"),
            "/dsh/workspace-archive")
    }

    /// The first fix only matched the literal `/dsh/` marker, so the VFS root
    /// and a traversal out of the rewritten tree still ran on the host and
    /// exited 0 (`|| true`) because those host paths are absent.
    func testDshRootAndParentTraversalAreWorkerVFSOnly() {
        for (command, expected) in [
            ("test -d /dsh || true", "/dsh"),
            ("test -d /dsh", "/dsh"),
            ("test -d /dsh/workspace/..", "/dsh/workspace/.."),
            ("test -d /dsh/workspace/../home", "/dsh/workspace/../home"),
            ("test -f /dsh/workspace/sub/../../home", "/dsh/workspace/sub/../../home"),
            ("test -d //dsh/home", "/dsh/home"),
            ("test -d /dsh/workspace/a.txt; test -d /dsh", "/dsh"),
        ] {
            XCTAssertEqual(ScenarioWorkspaceCommand.workerVFSOnlyPath(in: command),
                           expected,
                           "this reference must be rejected on the host: \(command)")
        }
        // `/dsh` inside an unrelated path component is not the VFS root.
        XCTAssertNil(ScenarioWorkspaceCommand.workerVFSOnlyPath(
            in: "test -d /tmp/foo/dsh/home"))
    }

    // MARK: Typed rejection before execution

    /// The baseline shape: `test -d /dsh/home || true` exits 0 on the host
    /// because `/dsh/home` is not there. The fixed evaluator rejects it before
    /// the shell starts, so the `|| true` never manufactures a pass and the
    /// command's other side effects never happen.
    func testWorkerVFSOnlyCommandIsRejectedBeforeAnyProcessStarts() throws {
        try withTemporaryWorkspace { workspace, results in
            let command = "touch should-not-run.txt; test -d /dsh/home || true"
            XCTAssertThrowsError(try ScenarioWorkspaceCommand.evaluate(
                command: command,
                workspace: workspace,
                resultsDirectory: results)) { error in
                    guard let failure = error as? ScenarioWorkspaceCommandFailure else {
                        return XCTFail("expected a typed worker_vfs_only failure, got \(error)")
                    }
                    XCTAssertEqual(failure.kind, .workerVFSOnly)
                    XCTAssertTrue(failure.description.contains("worker_vfs_only"),
                                  failure.description)
                    XCTAssertTrue(failure.description.contains("/dsh/home"),
                                  failure.description)
                    XCTAssertTrue(failure.description.contains("cannot reproduce"),
                                  "the detail must say the host cannot reproduce the path: "
                                    + failure.description)
                }
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: results.appendingPathComponent("check-workspace").path),
                "a rejected command must not materialize a throwaway copy")
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent("should-not-run.txt").path),
                "a rejected command must not execute its side effects")
        }
    }

    func testDshTmpIsRejectedAsWorkerVFSOnly() throws {
        try withTemporaryWorkspace { workspace, results in
            XCTAssertThrowsError(try ScenarioWorkspaceCommand.evaluate(
                command: "test -d /dsh/tmp || true",
                workspace: workspace,
                resultsDirectory: results)) { error in
                    XCTAssertEqual((error as? ScenarioWorkspaceCommandFailure)?.kind,
                                   Optional(ScenarioWorkspaceCommandFailure.Kind.workerVFSOnly),
                                   String(describing: error))
                }
        }
    }

    /// Both the VFS root and a `..` escape from the rewritten workspace must
    /// fail before the host process and before the throwaway copy exists.
    func testDshRootAndTraversalAreRejectedBeforeAnyProcessStarts() throws {
        for command in [
            "touch should-not-run.txt; test -d /dsh || true",
            "touch should-not-run.txt; test -d /dsh/workspace/.. || true",
            "touch should-not-run.txt; test -d /dsh/workspace/../home || true",
        ] {
            try withTemporaryWorkspace { workspace, results in
                XCTAssertThrowsError(try ScenarioWorkspaceCommand.evaluate(
                    command: command,
                    workspace: workspace,
                    resultsDirectory: results)) { error in
                        XCTAssertEqual(
                            (error as? ScenarioWorkspaceCommandFailure)?.kind,
                            Optional(ScenarioWorkspaceCommandFailure.Kind.workerVFSOnly),
                            String(describing: error))
                    }
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: results.appendingPathComponent("check-workspace").path),
                    "a rejected command must not materialize a throwaway copy")
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: workspace.appendingPathComponent("should-not-run.txt").path),
                    "a rejected command must not execute its side effects")
            }
        }
    }

    /// The simulator cannot evaluate the command, so it still only records
    /// `pending_host`; the host phase is where the typed rejection happens.
    func testSimulatorDeferralStillRecordsPendingHostForAWorkerOnlyPath() throws {
        try withTemporaryWorkspace { workspace, results in
            let disposition = try ScenarioWorkspaceCommand.evaluateOrDefer(
                command: "test -d /dsh/home || true",
                workspace: workspace,
                resultsDirectory: results,
                hostAvailable: false)
            guard case .pendingHost(let command) = disposition else {
                return XCTFail("the simulator must defer the command, got \(disposition)")
            }
            XCTAssertEqual(command, "test -d /dsh/home || true")
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: results.appendingPathComponent("check-workspace").path))
        }
    }

    // MARK: Host phase (pulled simulator report)

    func testHostPhaseRejectsWorkerOnlyPathInsteadOfRunningIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-host-semantics-report-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "G2-HOST-SEMANTICS"
        let scenarioRoot = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: scenarioRoot,
                                                withIntermediateDirectories: true)
        let report: [String: Any] = [
            "id": id,
            "status": "PENDING_HOST",
            "assertions": [[
                "type": "workspace_command",
                "ok": false,
                "detail": "pending_host: evaluated after the results are pulled",
                "status": "pending_host",
                "command": "test -d /dsh/home || true",
            ]],
            "turns": [[
                "prompt_len": 12,
                "started": "2026-10-25T00:00:00Z",
                "ended": "2026-10-25T00:00:05Z",
                "model_requests": 1,
            ]],
        ]
        let reportURL = scenarioRoot.appendingPathComponent("report.json")
        try JSONSerialization.data(withJSONObject: report,
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: reportURL)

        let summary = try ScenarioHostEvaluation.finalizeReports(in: root, ids: [id])
        XCTAssertEqual(summary.assertionsEvaluated, 1)
        XCTAssertEqual(summary.remainingPending, 0)

        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: reportURL)) as? [String: Any]
        XCTAssertEqual(object?["status"] as? String, "FAIL")
        let assertions = try XCTUnwrap(object?["assertions"] as? [[String: Any]])
        let assertion = try XCTUnwrap(assertions.first)
        XCTAssertEqual(assertion["ok"] as? Bool, false)
        XCTAssertEqual(assertion["status"] as? String,
                       ScenarioAssertionStatus.hostEvaluated)
        let detail = try XCTUnwrap(assertion["detail"] as? String)
        XCTAssertTrue(detail.contains("worker_vfs_only"), detail)
        XCTAssertTrue(detail.contains("/dsh/home"), detail)
        XCTAssertTrue(detail.contains("cannot reproduce"), detail)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: scenarioRoot.appendingPathComponent("check-workspace").path),
            "the host phase must reject before copying or executing")
    }
}
