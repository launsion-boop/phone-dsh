// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: the one host evaluation for
// `workspace_command` assertions.
//
// A `workspace_command` assertion needs a host process, so the iOS Simulator
// test bundle cannot run it. The evaluator below is the single implementation
// of the semantics (throwaway copy of the materialized workspace, `/dsh/
// workspace` rewriting, `/bin/bash -c`, PATH, 180 s watchdog, exit-0 verdict):
//
//   * the macOS XCTest runner calls ``evaluateOrDefer`` while the scenario
//     runs; the process is available, so the assertion is final;
//   * the iOS Simulator runner calls the same function and gets
//     ``ScenarioWorkspaceCommandDisposition/pendingHost(command:)`` — no
//     process is spawned, and the assertion is written as
//     `status: "pending_host"`, report status `PENDING_HOST`;
//   * after `scripts/ci/scenarios.sh --run-on sim` pulls the results, its
//     host phase invokes ``ScenarioHostEvaluation`` (through the
//     `ScenarioHostEvaluationTests` shim) against the pulled
//     `host/materialized/workspace`, fills the deferred assertions in, and
//     computes the final status by the same rule as the macOS report writer.
//
// Report schema compatibility: only optional fields are added — `status`,
// `command`, `host_evaluated` and `duration_ms` on an assertion, and
// `host_evaluated` on the report. The G2-FIX-15 completion gate adds the final
// assertion status `NOT_EXECUTED` (with `ok: false`) and the report-level
// `run_completed` / `run_incomplete_reason` fields.

import Foundation

/// Assertion status strings written to report.json. A final report carries the
/// usual `ok`/`detail` plus `host_evaluated`; `pending_host` only exists
/// between the simulator run and the host phase.
enum ScenarioAssertionStatus {
    static let pendingHost = "pending_host"
    static let hostEvaluated = "host_evaluated"
    /// The assertion was never executed because the scenario run itself did
    /// not complete (G2-FIX-15): a turn was not delivered, a turn has no
    /// terminal `ended`, or the run exited through timeout/budget/error. This
    /// is a third state, distinct from a pass and from a failed evaluation, and
    /// it never counts as passing.
    static let notExecuted = "NOT_EXECUTED"
    /// Provisional report status while at least one assertion is pending; it
    /// must not be mistaken for a final verdict.
    static let pendingHostReport = "PENDING_HOST"
}

/// The explicit execution semantics of a host-evaluated `workspace_command`.
///
/// This is deliberately not named "Worker VFS": the Mac host runs `/bin/bash`
/// against a materialized copy. A report must be readable as host acceptance
/// evidence and must not imply that the command ran in the Worker's
/// in-memory VFS. The fields are the stable facts a reviewer needs when the
/// model's command surface and the host's differ.
public struct ScenarioHostCommandSemantics: Equatable, Sendable {
    /// The only path the host rewrites, from the Worker VFS path to the
    /// throwaway materialized copy.
    public struct PathRewrite: Equatable, Sendable {
        public var from: String
        public var to: String

        public init(from: String = ScenarioHostCommandSemantics.workspacePath,
                    to: String) {
            self.from = from
            self.to = to
        }
    }

    /// Stable identifier recorded in every outcome detail.
    public static let identifier = "host-bash"
    /// The Worker VFS path the catalog commands address.
    public static let workspacePath = "/dsh/workspace"
    /// The PATH `ScenarioProcess.run` uses for host commands.
    public static let hostPath =
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    /// The documented host watchdog (G2-FIX-35 keeps the 180 s bound).
    public static let defaultTimeoutSeconds: TimeInterval = 180

    public var id: String
    /// `false`: this is the Mac host shell, never the Worker's in-memory VFS.
    public var workerVFS: Bool
    public var shell: String
    public var path: String
    public var pathRewrite: PathRewrite
    public var timeoutSeconds: TimeInterval

    public init(id: String = ScenarioHostCommandSemantics.identifier,
                workerVFS: Bool = false,
                shell: String = "/bin/bash",
                path: String = ScenarioHostCommandSemantics.hostPath,
                pathRewrite: PathRewrite,
                timeoutSeconds: TimeInterval = ScenarioHostCommandSemantics.defaultTimeoutSeconds) {
        self.id = id
        self.workerVFS = workerVFS
        self.shell = shell
        self.path = path
        self.pathRewrite = pathRewrite
        self.timeoutSeconds = timeoutSeconds
    }

    /// The canonical semantics before a copy path is known. `to` is the
    /// placeholder `<copy>`; ``resolvingWorkspaceCopy(_:)`` replaces it with the
    /// actual throwaway directory for a real evaluation.
    public static let hostBash = ScenarioHostCommandSemantics(
        pathRewrite: PathRewrite(to: "<copy>"))

    public func withTimeout(_ timeout: TimeInterval) -> ScenarioHostCommandSemantics {
        ScenarioHostCommandSemantics(id: id,
                                     workerVFS: workerVFS,
                                     shell: shell,
                                     path: path,
                                     pathRewrite: pathRewrite,
                                     timeoutSeconds: timeout)
    }

    public func resolvingWorkspaceCopy(_ copy: URL) -> ScenarioHostCommandSemantics {
        ScenarioHostCommandSemantics(id: id,
                                     workerVFS: workerVFS,
                                     shell: shell,
                                     path: path,
                                     pathRewrite: PathRewrite(from: pathRewrite.from,
                                                              to: copy.path),
                                     timeoutSeconds: timeoutSeconds)
    }

    /// The one stable environment line carried by every outcome detail.
    public var detailMarker: String {
        "[environment: \(id); worker VFS: \(workerVFS ? "used" : "not used"); "
            + "path: \(pathRewrite.from) -> \(pathRewrite.to)]"
    }
}

/// One completed host run of a `workspace_command` assertion.
struct ScenarioWorkspaceCommandOutcome: Equatable, Sendable {
    var status: Int32
    var timedOut: Bool
    var durationMs: Int
    var stdout: String
    var stderr: String
    /// The environment this run actually used. Defaults to the canonical host
    /// semantics so a synthetic outcome still carries the same explicit marker.
    var semantics: ScenarioHostCommandSemantics = .hostBash

    var ok: Bool { status == 0 && !timedOut }

    var combinedTail: String {
        ScenarioProcessOutput.combinedTail(stdout: stdout, stderr: stderr)
    }

    var detail: String {
        var detail = "exit \(status)"
        if timedOut { detail += " (timed out)" }
        if status != 0, !combinedTail.isEmpty {
            // `combinedTail` already applies the single marked bound; a second
            // suffix here would silently drop the truncation marker too.
            detail += ": \(combinedTail)"
        }
        return detail + "\n" + semantics.detailMarker
    }
}

/// A typed failure recorded before the host process starts.
struct ScenarioWorkspaceCommandFailure: Error, Equatable, CustomStringConvertible {
    enum Kind: String, Equatable, Sendable {
        /// The command names a `/dsh/` path other than `/dsh/workspace`; that
        /// path exists only in the Worker VFS, so the Mac host cannot reproduce
        /// the command (and must not report a fake exit 0 for it).
        case workerVFSOnly = "worker_vfs_only"
    }

    var kind: Kind
    var detail: String

    var description: String { "\(kind.rawValue): \(detail)" }
}

/// The result of asking for a `workspace_command` evaluation.
enum ScenarioWorkspaceCommandDisposition: Equatable {
    case evaluated(ScenarioWorkspaceCommandOutcome)
    case pendingHost(command: String)
}

enum ScenarioWorkspaceCommand {
    /// The macOS test process can spawn `/bin/bash`; the iOS Simulator bundle
    /// cannot. The branch is compile-time so the iOS product links no
    /// `Process`-based path.
    static var hostProcessesAvailable: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// The shared entry point: evaluate now when the host can spawn, otherwise
    /// report the command for the host phase. `hostAvailable` is injectable so
    /// the simulator deferral path is testable on macOS.
    static func evaluateOrDefer(command: String,
                                workspace: URL,
                                resultsDirectory: URL,
                                timeout: TimeInterval = ScenarioHostCommandSemantics.defaultTimeoutSeconds,
                                hostAvailable: Bool = hostProcessesAvailable,
                                fileManager: FileManager = .default) throws
        -> ScenarioWorkspaceCommandDisposition {
        guard hostAvailable else { return .pendingHost(command: command) }
        return .evaluated(try evaluate(command: command,
                                       workspace: workspace,
                                       resultsDirectory: resultsDirectory,
                                       timeout: timeout,
                                       fileManager: fileManager))
    }

    /// Returns the first `/dsh` reference that is not a path *inside* the
    /// rewritten `/dsh/workspace` tree. The host has no Worker VFS, so such a
    /// command is impossible to reproduce: it must fail before any process
    /// starts instead of silently passing (for example `test -d /dsh/home ||
    /// true` exits 0 on the host because `/dsh/home` simply does not exist
    /// there).
    ///
    /// The root itself (`/dsh`) and any parent traversal that leaves the
    /// rewritten tree (`/dsh/workspace/..`, `/dsh/workspace/../home`) are also
    /// rejected. Rejecting the traversal instead of normalising it is
    /// deliberate: after the rewrite the host would resolve it against a real
    /// temporary directory, so a normalised path could address host files that
    /// the Worker VFS never exposed.
    static func workerVFSOnlyPath(in command: String) -> String? {
        let root = "/dsh"
        let workspace = ScenarioHostCommandSemantics.workspacePath
        var search = command.startIndex
        while let range = command.range(of: root, range: search..<command.endIndex) {
            // `/dsh` must start a path component, not be part of a longer
            // filename (for example `/tmp/foo/dsh`). A preceding slash is a
            // component boundary too, so `//dsh/home` is still classified.
            if range.lowerBound != command.startIndex {
                let previous = command[command.index(before: range.lowerBound)]
                if isPathContinuation(previous) {
                    search = range.upperBound
                    continue
                }
            }
            var end = range.upperBound
            while end < command.endIndex {
                let character = command[end]
                if character.isWhitespace || "\"'`;|&()<>\\".contains(character) {
                    break
                }
                end = command.index(after: end)
            }
            let token = String(command[range.lowerBound..<end])
            guard isInsideWorkspace(token, workspace: workspace) else {
                return token
            }
            // Continue after the token so a second `/dsh` reference in the
            // same command is classified too.
            search = end
        }
        return nil
    }

    /// Characters that make a preceding `/dsh` part of a longer filename.
    /// `/` is intentionally absent: it is a path-component boundary.
    private static func isPathContinuation(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
            || character == "_" || character == "-" || character == "."
            || character == "~"
    }

    /// `true` only for the exact rewritten root or a descendant of it with no
    /// `..` component. `/dsh` itself, `/dsh/workspace-archive` and
    /// `/dsh/workspace/../home` are not inside the rewritten tree.
    private static func isInsideWorkspace(_ token: String, workspace: String) -> Bool {
        guard token == workspace || token.hasPrefix(workspace + "/") else {
            return false
        }
        let remainder = token.dropFirst(workspace.count)
        return !remainder
            .split(separator: "/", omittingEmptySubsequences: true)
            .contains(where: { String($0) == ".." })
    }

    /// Runs `/bin/bash -c <command>` in a throwaway copy of the materialized
    /// workspace. `/dsh/workspace` in the command is rewritten to that copy;
    /// the same copy is kept as `<results>/check-workspace/` evidence.
    ///
    /// This is the only implementation of those semantics. The macOS runner
    /// and the simulator host phase both reach it. Every outcome detail names
    /// the host environment explicitly (G2-FIX-35); a command that needs any
    /// other Worker VFS path fails with `worker_vfs_only` before it starts.
    static func evaluate(command: String,
                         workspace: URL,
                         resultsDirectory: URL,
                         timeout: TimeInterval = ScenarioHostCommandSemantics.defaultTimeoutSeconds,
                         fileManager: FileManager = .default) throws
        -> ScenarioWorkspaceCommandOutcome {
        if let unsupported = workerVFSOnlyPath(in: command) {
            throw ScenarioWorkspaceCommandFailure(
                kind: .workerVFSOnly,
                detail: "the command references \(unsupported), which exists only in the "
                    + "Worker VFS; the Mac host (/bin/bash acceptance) cannot reproduce it. "
                    + "Only \(ScenarioHostCommandSemantics.workspacePath) is rewritten to the "
                    + "materialized copy.")
        }
        guard fileManager.fileExists(atPath: workspace.path) else {
            throw ScenarioError.artifact("the materialized workspace does not exist")
        }
        let copy = resultsDirectory.appendingPathComponent("check-workspace", isDirectory: true)
        try scenarioCopyTree(from: workspace, to: copy, fileManager: fileManager)
        let semantics = ScenarioHostCommandSemantics.hostBash
            .withTimeout(timeout)
            .resolvingWorkspaceCopy(copy)
        // The catalog addresses the virtual workspace by its VFS path; host
        // bash must run against the materialized copy.
        let rewritten = command.replacingOccurrences(of: semantics.pathRewrite.from,
                                                     with: semantics.pathRewrite.to)
        let started = Date()
        let result = ScenarioProcess.run(semantics.shell, ["-c", rewritten],
                                         in: copy,
                                         timeout: semantics.timeoutSeconds,
                                         environment: ["PATH": semantics.path])
        let elapsed = max(0, Int((Date().timeIntervalSince(started) * 1000).rounded()))
        return ScenarioWorkspaceCommandOutcome(
            status: result.status,
            timedOut: result.timedOut,
            durationMs: elapsed,
            stdout: result.stdout,
            stderr: result.stderr,
            semantics: semantics)
    }
}

// MARK: - Host phase for pulled simulator reports

struct ScenarioHostEvaluationSummary: Equatable, Sendable {
    /// Reports visited (existing report.json files among the requested ids).
    var reports: Int
    /// Deferred assertions filled in by this host phase.
    var assertionsEvaluated: Int
    /// Reports that still carry a `pending_host` assertion afterwards.
    var remainingPending: Int
}

/// Fills the deferred simulator assertions in a pulled report.json and applies
/// the macOS report rule to the final status.
enum ScenarioHostEvaluation {
    private static let idPattern = #"^[A-Za-z0-9._-]{1,64}$"#

    /// Finalizes one report. Returns the number of assertions evaluated; `0`
    /// means the report had no deferred assertion and was left byte-identical.
    static func finalizeReport(at reportURL: URL,
                               timeout: TimeInterval = ScenarioHostCommandSemantics.defaultTimeoutSeconds,
                               fileManager: FileManager = .default) throws -> Int {
        let data = try Data(contentsOf: reportURL)
        guard var report = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScenarioError.artifact("report.json is not a JSON object: \(reportURL.path)")
        }
        guard var assertions = report["assertions"] as? [[String: Any]] else { return 0 }
        let resultsDirectory = reportURL.deletingLastPathComponent()
        // The pulled simulator evidence keeps the host's materialized copy.
        // `workspace.tar` is the same tree archived before assertion evaluation;
        // the materialized directory is authoritative for this phase.
        let workspace = resultsDirectory
            .appendingPathComponent("host/materialized/workspace", isDirectory: true)
        let secret = ProcessInfo.processInfo.environment["PDSH_MODEL_API_KEY"] ?? ""
        let redactor = ScenarioRedactor(secrets: [secret])
        // The same run-completion gate the runner applies before it writes the
        // report: a deferred command from an incomplete run is NOT_EXECUTED,
        // never evaluated against the fixture-or-partial workspace, and never a
        // pass (G2-FIX-15).
        let completion = ScenarioRunCompletion.from(report: report)
        var evaluated = 0
        var ranOnHost = 0
        for index in assertions.indices {
            guard assertions[index]["status"] as? String == ScenarioAssertionStatus.pendingHost else {
                continue
            }
            let type = assertions[index]["type"] as? String ?? ""
            if ScenarioAssertionGate.suppresses(type, completion: completion) {
                assertions[index]["ok"] = false
                assertions[index]["detail"] = redactor.redact(
                    ScenarioAssertionGate.notExecutedDetail(completion: completion))
                assertions[index]["status"] = ScenarioAssertionStatus.notExecuted
                evaluated += 1
                continue
            }
            let command = (assertions[index]["command"] as? String) ?? ""
            do {
                let disposition = try ScenarioWorkspaceCommand.evaluateOrDefer(
                    command: command,
                    workspace: workspace,
                    resultsDirectory: resultsDirectory,
                    timeout: timeout,
                    hostAvailable: ScenarioWorkspaceCommand.hostProcessesAvailable,
                    fileManager: fileManager)
                switch disposition {
                case .pendingHost:
                    // The host cannot spawn either; leave the assertion for a
                    // real host and let the caller report the pending state.
                    continue
                case .evaluated(let outcome):
                    assertions[index]["ok"] = outcome.ok
                    assertions[index]["detail"] = redactor.redact(outcome.detail)
                    assertions[index]["status"] = ScenarioAssertionStatus.hostEvaluated
                    assertions[index]["host_evaluated"] = true
                    assertions[index]["duration_ms"] = outcome.durationMs
                    evaluated += 1
                    ranOnHost += 1
                }
            } catch {
                // A missing materialized workspace or another artifact failure
                // is an assertion failure (the macOS runner's catch path has
                // the same shape), not a crash of the host phase.
                assertions[index]["ok"] = false
                assertions[index]["detail"] = redactor.redact(String(describing: error))
                assertions[index]["status"] = ScenarioAssertionStatus.hostEvaluated
                assertions[index]["host_evaluated"] = true
                assertions[index]["duration_ms"] = 0
                evaluated += 1
                ranOnHost += 1
            }
        }
        guard evaluated > 0 else { return 0 }
        report["assertions"] = assertions
        // The status precedence is the one `ScenarioRun.buildReport` applies on
        // macOS: a run-level terminal status wins, otherwise any failed or
        // NOT_EXECUTED assertion is FAIL and a clean report is PASS. A
        // simulator report in PENDING_HOST/FAIL/PASS is exactly the set that
        // can change here.
        var status = report["status"] as? String ?? "UNKNOWN"
        let allOK = assertions.allSatisfy { assertion in
            ScenarioAssertionGate.passes(status: assertion["status"] as? String,
                                         ok: (assertion["ok"] as? Bool) ?? false)
        }
        if status == ScenarioAssertionStatus.pendingHostReport || status == "FAIL" || status == "PASS" {
            status = allOK ? "PASS" : "FAIL"
        }
        report["status"] = status
        // The report-level marker means "a workspace_command ran on the Mac
        // host"; a NOT_EXECUTED finalization did not run anything.
        if ranOnHost > 0 {
            report["host_evaluated"] = true
        }
        let output = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try scenarioWrite(output, to: reportURL, fileManager: fileManager)
        return evaluated
    }

    /// Finalizes the requested report ids under `resultsRoot`. Empty `ids`
    /// scans every `<id>/report.json` (manual use); the runner always passes
    /// its own selection so concurrent lanes do not touch each other's trees.
    static func finalizeReports(in resultsRoot: URL,
                                ids: [String],
                                timeout: TimeInterval = ScenarioHostCommandSemantics.defaultTimeoutSeconds,
                                fileManager: FileManager = .default) throws
        -> ScenarioHostEvaluationSummary {
        let targets: [String]
        if ids.isEmpty {
            let entries = (try? fileManager.contentsOfDirectory(
                at: resultsRoot, includingPropertiesForKeys: nil)) ?? []
            targets = entries.filter { entry in
                fileManager.fileExists(
                    atPath: entry.appendingPathComponent("report.json").path)
            }.map(\.lastPathComponent).sorted()
        } else {
            targets = ids
        }
        var summary = ScenarioHostEvaluationSummary(reports: 0,
                                                    assertionsEvaluated: 0,
                                                    remainingPending: 0)
        for id in targets {
            guard id.range(of: idPattern, options: .regularExpression) != nil,
                  id != ".", id != ".." else {
                throw ScenarioError.environment("scenario id is not path-safe: \(id)")
            }
            let reportURL = resultsRoot
                .appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent("report.json")
            guard fileManager.fileExists(atPath: reportURL.path) else { continue }
            summary.reports += 1
            summary.assertionsEvaluated += try finalizeReport(
                at: reportURL, timeout: timeout, fileManager: fileManager)
            let data = try Data(contentsOf: reportURL)
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let assertions = object["assertions"] as? [[String: Any]],
               assertions.contains(where: {
                   $0["status"] as? String == ScenarioAssertionStatus.pendingHost
               }) {
                summary.remainingPending += 1
            }
        }
        return summary
    }
}
