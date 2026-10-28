// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: the run-completion gate for
// assertion evaluation, and the one assertion evaluator both report paths use.
//
// Root cause (G2-FIX-15): `ScenarioRun.evaluateAssertions()` ran on every exit
// path. A run that ended TIMEOUT/BUDGET/ERROR, or whose scenario turns never
// reached a terminal `ended`, evaluated its progress-dependent assertions
// against the untouched fixture (or a partial workspace). Such checks can
// trivially match there, so the report carried `ok: true` for work the model
// never did — indistinguishable from a genuine pass.
//
// The gate below turns the run-completion fact into an explicit third state,
// `NOT_EXECUTED`, for the assertion types that need the turns to have run.
// `no_console_error`, `session_error`, `model_requests_lte` and the
// `restart_recovered` coverage verdict keep their own evaluation (the last one
// is owned by G2-FIX-6); nothing here looks at a scenario id, a prompt or a
// fixture.

import Foundation

/// Whether a run delivered and finished every scenario turn without exiting
/// through timeout/budget/error.
///
/// Deliberately pure: the scenario runner computes the fact from its own turn
/// reports and terminal state, and the iOS Simulator host phase reconstructs it
/// from the pulled report.json. Both paths then read the same gate.
enum ScenarioRunCompletion: Equatable {
    case completed
    case incomplete(reason: String)

    var isComplete: Bool {
        if case .completed = self { return true }
        return false
    }

    /// The human-readable facts that made the run incomplete; `nil` when it
    /// completed.
    var reason: String? {
        if case .incomplete(let reason) = self { return reason }
        return nil
    }

    /// The terminal run statuses that are not a completed scenario run. `FAIL`
    /// is not here: it is an assertion verdict computed after this fact.
    /// `INFRA` (G2-FIX-65) aborts before the run starts, so it is never a
    /// completed run; reading a pulled report must keep that classification.
    static let failedStatuses: Set<String> = ["TIMEOUT", "BUDGET", "ERROR", "INFRA"]

    /// The runner-side fact: every scenario turn was delivered, every delivered
    /// turn has a terminal end, and the run did not exit through
    /// timeout/budget/error.
    static func evaluate(plannedTurns: Int,
                         turnReports: [ScenarioTurnReport],
                         terminalStatus: String?) -> ScenarioRunCompletion {
        var problems: [String] = []
        if let terminalStatus, failedStatuses.contains(terminalStatus) {
            problems.append("the run ended with status \(terminalStatus)")
        }
        if turnReports.count != plannedTurns {
            problems.append("\(turnReports.count) of \(plannedTurns) scenario turn(s) were delivered")
        }
        // G2-FIX-13/G2-FIX-125: the report has one row per planned turn; only
        // `delivered: true` rows are scenario turns. A row the runner never
        // delivered is explicit evidence, never a missing entry.
        if turnReports.count == plannedTurns {
            let undelivered = turnReports.filter { !$0.delivered }.count
            if undelivered > 0 {
                problems.append("\(undelivered) of \(plannedTurns) scenario turn(s) "
                    + "were not delivered")
            }
        }
        let deliveredTurns = turnReports.filter { $0.delivered }
        let openTurns = deliveredTurns.filter { $0.ended == nil }.count
        if openTurns > 0 {
            // A delivered turn with no `turnEnded` is a hang, not a
            // completion; it is distinct from a turn that never ran.
            problems.append("\(openTurns) delivered turn(s) have no terminal turn/end "
                + "(ended is null)")
        }
        // Any non-completed terminal event (cancelled/aborted/interrupted/
        // failed/budget) makes the run incomplete and is named on the report.
        let terminalReasons = deliveredTurns.compactMap(\.terminalReason)
            .filter { $0 != "completed" }
        if !terminalReasons.isEmpty {
            let unique = Array(Set(terminalReasons)).sorted()
            problems.append("\(terminalReasons.count) delivered turn(s) ended with "
                + "terminal reason(s): \(unique.joined(separator: ", "))")
        }
        guard !problems.isEmpty else { return .completed }
        return .incomplete(reason: problems.joined(separator: "; "))
    }

    /// The host-phase fact: reconstruct completion from a report.json object.
    ///
    /// A new report carries the runner-computed `run_completed` fact. Older or
    /// partially written reports are read from their own evidence: a terminal
    /// status or a turn without a terminal `ended` makes the run incomplete.
    static func from(report: [String: Any]) -> ScenarioRunCompletion {
        if let completed = report["run_completed"] as? Bool, !completed {
            let recorded = report["run_incomplete_reason"] as? String
            return .incomplete(reason: recorded ?? "the recorded run did not complete")
        }
        var problems: [String] = []
        if let status = report["status"] as? String, failedStatuses.contains(status) {
            problems.append("the run ended with status \(status)")
        }
        if let turns = report["turns"] as? [[String: Any]] {
            let undelivered = turns.filter { $0["delivered"] as? Bool == false }.count
            if undelivered > 0 {
                problems.append("\(undelivered) scenario turn(s) were not delivered")
            }
            let delivered = turns.filter { ($0["delivered"] as? Bool) ?? true }
            let openTurns = delivered.filter { !turnHasEnded($0) }.count
            if openTurns > 0 {
                problems.append("\(openTurns) delivered turn(s) have no terminal turn/end "
                    + "(ended is null)")
            }
            let terminal = delivered.compactMap { $0["terminal_reason"] as? String }
                .filter { !$0.isEmpty && $0 != "completed" }
            if !terminal.isEmpty {
                let unique = Array(Set(terminal)).sorted()
                problems.append("\(terminal.count) delivered turn(s) ended with "
                    + "terminal reason(s): \(unique.joined(separator: ", "))")
            }
        }
        guard !problems.isEmpty else { return .completed }
        return .incomplete(reason: problems.joined(separator: "; "))
    }

    private static func turnHasEnded(_ turn: [String: Any]) -> Bool {
        guard let value = turn["ended"], let text = value as? String else { return false }
        return !text.isEmpty
    }
}

/// The one rule for which assertions depend on the turns having run to
/// completion, and the shared NOT_EXECUTED verdict helpers.
enum ScenarioAssertionGate {
    /// Assertion types whose verdict needs the scenario's turns to have run.
    /// The catalog schema test refuses unknown types, so this set is exhaustive
    /// for the progress-dependent class and never names a scenario.
    static let progressDependentTypes: Set<String> = [
        "file_exists",
        "no_file",
        "file_contains",
        "file_regex",
        "file_json_path",
        "workspace_command",
        "worker_command",
    ]

    /// Assertion types whose evidence is a static read of the materialized
    /// workspace. `workspace_command` and `turn_count_lte` are excluded: the
    /// former needs a host process, the latter is a runner counter.
    static let materializedEvidenceTypes: Set<String> = [
        "file_exists",
        "no_file",
        "file_contains",
        "file_regex",
        "file_json_path",
    ]

    static func isProgressDependent(_ type: String) -> Bool {
        progressDependentTypes.contains(type)
    }

    /// `true` exactly when an incomplete run must not evaluate the assertion.
    static func suppresses(_ type: String,
                           completion: ScenarioRunCompletion) -> Bool {
        !completion.isComplete && isProgressDependent(type)
    }

    /// The one NOT_EXECUTED detail sentence, shared by the runner and the
    /// simulator host phase.
    static func notExecutedDetail(completion: ScenarioRunCompletion) -> String {
        guard let reason = completion.reason else {
            return "not executed: the scenario run did not complete"
        }
        return "not executed: the scenario run did not complete (\(reason))"
    }

    /// NOT_EXECUTED is never a pass, whatever the boolean beside it says.
    static func passes(status: String?, ok: Bool) -> Bool {
        status != ScenarioAssertionStatus.notExecuted && ok
    }
}

/// Aggregate verdict over a report's assertions. NOT_EXECUTED is counted
/// separately from a failed evaluation and can never make `allPassed` true.
struct ScenarioAssertionSummary: Equatable {
    var passed = 0
    var failed = 0
    var notExecuted = 0
    var pendingHost = 0

    var total: Int { passed + failed + notExecuted + pendingHost }

    /// A run may only be called all-green when every assertion really passed.
    var allPassed: Bool {
        failed == 0 && notExecuted == 0 && pendingHost == 0
    }

    static func summarize(_ reports: [ScenarioAssertionReport]) -> ScenarioAssertionSummary {
        var summary = ScenarioAssertionSummary()
        for report in reports {
            if report.status == ScenarioAssertionStatus.pendingHost {
                summary.pendingHost += 1
            } else if report.status == ScenarioAssertionStatus.notExecuted {
                summary.notExecuted += 1
            } else if ScenarioAssertionGate.passes(status: report.status, ok: report.ok) {
                summary.passed += 1
            } else {
                summary.failed += 1
            }
        }
        return summary
    }
}

/// Evaluates catalog assertions against the materialized workspace, applying
/// the run-completion gate first. The macOS runner builds this after the host
/// has stopped; the unit tests feed it recorded run fixtures (status, turns and
/// counters) without a model, a WKWebView or a host.
struct ScenarioAssertionEvaluator {
    var workspace: URL
    var resultsDirectory: URL
    var turnStartedCount: Int
    /// Scenario turns the runner actually delivered, independent of the DSH
    /// `turn/start` count (which includes a driver retry, G2-FIX-13/125).
    var deliveredTurnCount: Int = 0
    var modelRequests: Int
    /// The Worker/session console error stream, redacted once by the runner and
    /// written unchanged to the report's `console_errors` field. Every
    /// `no_console_error`/`session_error` verdict is derived from this same
    /// array, so the assertion and the report cannot disagree.
    var consoleErrors: [String]
    /// The finalized perturbation-coverage verdict (G2-FIX-6 owns it).
    var restartRecovered: ScenarioPerturbationCoverage.Verdict?
    var redactor: ScenarioRedactor

    /// Reports every assertion, in catalog order. On an incomplete run the
    /// progress-dependent types become NOT_EXECUTED; every other type keeps the
    /// evaluation it had before this gate existed.
    func reports(for assertions: [Scenario.Assertion],
                 completion: ScenarioRunCompletion,
                 overrides: [Int: ScenarioAssertionReport] = [:])
        -> [ScenarioAssertionReport] {
        assertions.enumerated().map { index, assertion in
            // Run completion is checked before any cached evaluation. A
            // `worker_command` runs while the live Worker is still up, before
            // `host.stop()`; a later stop/seal failure makes the run
            // incomplete. The cached receipt is a real observation, but its
            // PASS is not a completed-run verdict, so it must become
            // NOT_EXECUTED instead of surviving the gate.
            if ScenarioAssertionGate.suppresses(assertion.type,
                                                completion: completion) {
                return ScenarioAssertionReport(
                    type: assertion.type,
                    ok: false,
                    detail: redactor.redact(
                        ScenarioAssertionGate.notExecutedDetail(completion: completion)),
                    status: ScenarioAssertionStatus.notExecuted,
                    failure: ScenarioAssertionFailure(
                        kind: .notExecuted,
                        path: assertion.path,
                        expected: "the scenario run completes",
                        actual: completion.reason))
            }
            // A completed run keeps the pre-evaluated receipt at its catalog
            // index so the report keeps the catalog's order without running
            // the assertion twice.
            if let override = overrides[index] { return override }
            return evaluate(assertion)
        }
    }

    /// Evidence from an incomplete run's materialized workspace (G2-FIX-94).
    ///
    /// These are static reads of files the delivered turns left behind. They
    /// are deliberately returned separately from ``reports(for:completion:)``:
    /// the assertion verdict stays NOT_EXECUTED, the summary ignores this
    /// array, and the run status can never become PASS from it.
    func partialEvidence(for assertions: [Scenario.Assertion],
                         completion: ScenarioRunCompletion,
                         completedTurns: Int,
                         fixtureBaseline: MaterializedSnapshot?,
                         currentWorkspace: MaterializedSnapshot)
        -> [ScenarioPartialEvidenceReport] {
        guard !completion.isComplete else { return [] }
        return assertions.enumerated().compactMap { index, assertion in
            guard ScenarioAssertionGate.suppresses(assertion.type,
                                                   completion: completion),
                  ScenarioAssertionGate.materializedEvidenceTypes.contains(assertion.type)
            else { return nil }
            let report = evaluate(assertion)
            return ScenarioPartialEvidenceReport(
                assertionIndex: index,
                type: assertion.type,
                ok: report.ok,
                detail: report.detail,
                basis: "materialized_workspace",
                completedTurns: completedTurns,
                fixtureDiff: Self.fixtureDiff(path: assertion.path,
                                              baseline: fixtureBaseline,
                                              current: currentWorkspace))
        }
    }

    /// Attributes one materialized assertion path to the fixture baseline:
    /// an unchanged path is fixture evidence, a created/modified path is
    /// evidence the run produced it.
    private static func fixtureDiff(path: String?,
                                    baseline: MaterializedSnapshot?,
                                    current: MaterializedSnapshot) -> String? {
        guard let path else { return nil }
        guard let baseline else { return "fixture_baseline_unavailable" }
        let before = baseline.entries[path]
        let now = current.entries[path]
        switch (before, now) {
        case (nil, nil): return "absent_in_fixture_and_workspace"
        case (nil, .some(_)): return "created_since_fixture"
        case (.some(_), nil): return "removed_since_fixture"
        case let (.some(old), .some(new)) where old == new:
            return "unchanged_from_fixture"
        case (.some(_), .some(_)): return "modified_since_fixture"
        }
    }

    private func evaluate(_ assertion: Scenario.Assertion) -> ScenarioAssertionReport {
        func fileURL(_ path: String) throws -> URL {
            guard let value = assertion.path, !value.isEmpty else {
                throw ScenarioError.assertion("\(assertion.type) has no path")
            }
            try ScenarioFixtures.validate(relativePath: value)
            return workspace.appendingPathComponent(value)
        }
        do {
            switch assertion.type {
            case "file_exists":
                let url = try fileURL(assertion.path ?? "")
                let exists = FileManager.default.fileExists(atPath: url.path)
                return report(assertion, ok: exists,
                              detail: exists ? "exists: \(assertion.path!)"
                                             : "missing: \(assertion.path!)",
                              failure: exists ? nil : ScenarioAssertionFailure(
                                  kind: .missing, path: assertion.path,
                                  expected: "the file exists", actual: "missing"))
            case "no_file":
                let url = try fileURL(assertion.path ?? "")
                let exists = FileManager.default.fileExists(atPath: url.path)
                return report(assertion, ok: !exists,
                              detail: exists ? "unexpected file: \(assertion.path!)"
                                             : "absent: \(assertion.path!)",
                              failure: exists ? ScenarioAssertionFailure(
                                  kind: .unexpectedFile, path: assertion.path,
                                  expected: "the file is absent", actual: "present") : nil)
            case "file_contains":
                let url = try fileURL(assertion.path ?? "")
                let text = try readText(url)
                let value = assertion.value ?? ""
                let ok = ScenarioFileContent.contains(value, in: text)
                return report(assertion, ok: ok,
                              detail: ok ? "contains \(value.prefix(80))"
                                         : "does not contain \(value.prefix(80))",
                              failure: ok ? nil : ScenarioAssertionFailure(
                                  kind: .notContains, path: assertion.path,
                                  expected: value, actual: "substring not found"))
            case "file_regex":
                let url = try fileURL(assertion.path ?? "")
                let text = try readText(url)
                let value = assertion.value ?? ""
                let ok = try ScenarioFileContent.matches(value, in: text)
                return report(assertion, ok: ok,
                              detail: ok ? "matches \(value.prefix(80))"
                                         : "does not match \(value.prefix(80))",
                              failure: ok ? nil : ScenarioAssertionFailure(
                                  kind: .notMatch, path: assertion.path,
                                  expected: value, actual: "pattern did not match"))
            case "file_json_path":
                let url = try fileURL(assertion.path ?? "")
                let data = try Data(contentsOf: url)
                let object = try JSONSerialization.jsonObject(with: data)
                let path = assertion.value ?? ""
                let found = try jsonValue(at: path, in: object)
                return report(assertion, ok: found != nil,
                              detail: found != nil ? "json path \(path) resolves"
                                                   : "json path \(path) is absent",
                              failure: found != nil ? nil : ScenarioAssertionFailure(
                                  kind: .jsonPathAbsent, path: assertion.path,
                                  expected: path, actual: "path absent"))
            case "workspace_command":
                return try evaluateWorkspaceCommand(assertion)
            case "worker_command":
                // Worker assertions are evaluated against the live Worker
                // before `host.stop()`; a report that reaches this evaluator
                // without that receipt has no Worker observation and must not
                // be substituted with a host run.
                return report(assertion, ok: false,
                              detail: "worker_command has no captured Worker receipt; "
                                + "the Worker evaluation phase did not run",
                              failure: ScenarioAssertionFailure(
                                  kind: .missingReceipt,
                                  expected: "a pdsh-worker-command/1 receipt from the live Worker",
                                  actual: "no receipt"))
            case "turn_count_lte":
                let bound = try ScenarioCountBound.verdict(count: deliveredTurnCount,
                                                           assertion: assertion)
                let detail = "\(deliveredTurnCount) delivered scenario turn(s), "
                    + "\(turnStartedCount) DSH turn/start event(s) including retries, "
                    + "max \(bound.maximum)"
                return report(assertion, ok: bound.ok, detail: detail,
                              failure: bound.ok ? nil : ScenarioAssertionFailure(
                                  kind: .countExceeded, expected: "<= \(bound.maximum)",
                                  actual: "\(deliveredTurnCount) delivered scenario turn(s)"))
            case "no_console_error":
                let errors = consoleErrors
                return report(assertion, ok: errors.isEmpty,
                              detail: errors.isEmpty
                                ? "no console errors"
                                : "\(errors.count) console error(s) in console_errors: "
                                    + "\(errors[0].prefix(200))",
                              failure: errors.isEmpty ? nil : ScenarioAssertionFailure(
                                  kind: .error, expected: "no console errors",
                                  actual: "\(errors.count) console error(s)"))
            case "model_requests_lte":
                let bound = try ScenarioCountBound.verdict(count: modelRequests,
                                                           assertion: assertion)
                return report(assertion, ok: bound.ok,
                              detail: "\(modelRequests) model request(s), max \(bound.maximum)",
                              failure: bound.ok ? nil : ScenarioAssertionFailure(
                                  kind: .countExceeded, expected: "<= \(bound.maximum)",
                                  actual: "\(modelRequests) model request(s)"))
            case "session_error":
                // A delivery stall must surface as a session/host error event,
                // not silence until the wall budget. `value`, when present,
                // narrows the match (for example the typed timeout marker).
                let needle = assertion.value ?? ""
                let matching = needle.isEmpty
                    ? consoleErrors : consoleErrors.filter { $0.contains(needle) }
                let label = needle.isEmpty ? "session/host error"
                    : "session/host error containing \(needle.prefix(80))"
                return report(assertion, ok: !matching.isEmpty,
                              detail: matching.isEmpty ? "no \(label)"
                                : "\(matching.count) \(label): \(matching[0].prefix(200))",
                              failure: matching.isEmpty ? ScenarioAssertionFailure(
                                  kind: .missing, expected: label, actual: "none") : nil)
            case "restart_recovered":
                // The verdict is computed from the finalized coverage, not
                // from "some perturbation report exists": a scenario that
                // declares a point the run never reached must fail loud.
                guard let verdict = restartRecovered else {
                    return report(assertion, ok: false,
                                  detail: "perturbation coverage was not finalized "
                                    + "before the restart_recovered assertion",
                                  failure: ScenarioAssertionFailure(
                                      kind: .error,
                                      expected: "finalized perturbation coverage",
                                      actual: "coverage not finalized"))
                }
                return report(assertion, ok: verdict.ok, detail: verdict.detail,
                              failure: verdict.ok ? nil : ScenarioAssertionFailure(
                                  kind: .error, expected: "every perturbation recovered",
                                  actual: verdict.detail))
            default:
                return report(assertion, ok: false,
                              detail: "unknown assertion type: \(assertion.type)",
                              failure: ScenarioAssertionFailure(
                                  kind: .error, expected: "a known assertion type",
                                  actual: assertion.type))
            }
        } catch {
            return report(assertion, ok: false, detail: String(describing: error),
                          failure: ScenarioAssertionFailure(
                              kind: .error, actual: String(describing: error)))
        }
    }

    private func report(_ assertion: Scenario.Assertion, ok: Bool,
                        detail: String,
                        status: String? = nil,
                        command: String? = nil,
                        hostEvaluated: Bool? = nil,
                        durationMs: Int? = nil,
                        failure: ScenarioAssertionFailure? = nil) -> ScenarioAssertionReport {
        let redactedFailure = failure.map {
            ScenarioAssertionFailure(
                kind: $0.kind,
                path: $0.path.map(redactor.redact),
                expected: $0.expected.map(redactor.redact),
                actual: $0.actual.map(redactor.redact))
        }
        return ScenarioAssertionReport(type: assertion.type, ok: ok,
                                       detail: redactor.redact(detail),
                                       status: status,
                                       command: command.map(redactor.redact),
                                       hostEvaluated: hostEvaluated,
                                       durationMs: durationMs,
                                       failure: redactedFailure)
    }

    private func readText(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ScenarioError.assertion("file does not exist: \(url.lastPathComponent)")
        }
        let data = try Data(contentsOf: url)
        return String(decoding: data, as: UTF8.self)
    }

    /// Dot/bracket JSON path (`totals.error`, `items[0].name`).
    private func jsonValue(at path: String, in root: Any) throws -> Any? {
        guard !path.isEmpty else { return root }
        var current: Any? = root
        var tokenStart = path.startIndex
        var index = path.startIndex
        while index < path.endIndex {
            let character = path[index]
            if character == "." || character == "[" {
                let token = String(path[tokenStart..<index])
                if !token.isEmpty { current = member(token, of: current) }
                if character == "[" {
                    guard let close = path[index...].firstIndex(of: "]") else { return nil }
                    let raw = String(path[path.index(after: index)..<close])
                    guard let offset = Int(raw), let array = current as? [Any],
                          array.indices.contains(offset) else { return nil }
                    current = array[offset]
                    index = path.index(after: close)
                    tokenStart = index
                    continue
                }
            }
            index = path.index(after: index)
        }
        let token = String(path[tokenStart...])
        if !token.isEmpty { current = member(token, of: current) }
        return current
    }

    private func member(_ name: String, of value: Any?) -> Any? {
        guard let dictionary = value as? [String: Any] else { return nil }
        return dictionary[name]
    }

    private func evaluateWorkspaceCommand(_ assertion: Scenario.Assertion)
        throws -> ScenarioAssertionReport {
        guard let command = assertion.command, !command.isEmpty else {
            throw ScenarioError.assertion("workspace_command has no command")
        }
        // One implementation for both runners: the macOS process evaluates the
        // command in a throwaway copy of the materialized workspace, while the
        // iOS Simulator (no `Process`) records the command as pending for the
        // host phase that `scenarios.sh --run-on sim` runs after pulling the
        // results. An unexpected host failure is an assertion failure, exactly
        // as before. An incomplete run never reaches this point: the gate above
        // reports the assertion NOT_EXECUTED instead of deferring a command
        // that nothing will ever run.
        let disposition = try ScenarioWorkspaceCommand.evaluateOrDefer(
            command: command,
            workspace: workspace,
            resultsDirectory: resultsDirectory)
        switch disposition {
        case .pendingHost(let command):
            return report(assertion, ok: false,
                          detail: "pending_host: the iOS Simulator test process cannot "
                            + "spawn /bin/bash; the host driver evaluates this command "
                            + "after pulling the results",
                          status: ScenarioAssertionStatus.pendingHost,
                          command: command)
        case .evaluated(let outcome):
            return report(assertion, ok: outcome.ok,
                          detail: outcome.detail,
                          hostEvaluated: true,
                          durationMs: outcome.durationMs,
                          failure: outcome.ok ? nil : ScenarioAssertionFailure(
                              kind: .commandFailed, path: assertion.path,
                              expected: "the command exits 0",
                              actual: "exit \(outcome.status)"
                                  + (outcome.timedOut ? " (timed out)" : "")))
        }
    }
}
