// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 scenario runner: one catalog scenario end to end.
//
// Boots PhoneDSHHost with the real WKWebView engine, seeds the workspace from
// the catalog, drives the prompts over the harness, applies the perturbation
// points, evaluates the assertions against the materialized copy, and writes
// report.json / transcript.jsonl / workspace.tar under <results>/<id>/.

import Foundation
import WebKit
import PhoneDSHHarness
import PhoneDSHAgentCore
import PhoneDSHController
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHGateway
import PhoneDSHLog
import PhoneDSHWire

// MARK: - File content assertions

/// The two file-content assertion primitives, kept here so the regression
/// tests compile assertions exactly the way `evaluate` does.
enum ScenarioFileContent {
    /// `file_contains` is a literal substring check: no pattern syntax, no
    /// line anchoring, no trimming.
    static func contains(_ value: String, in text: String) -> Bool {
        text.contains(value)
    }

    /// `file_regex` is an ICU pattern evaluated grep-style: `.anchorsMatchLines`
    /// makes `^` and `$` anchor at every line boundary, so a heading assertion
    /// such as `^## ` matches a multi-line Markdown artifact instead of only a
    /// `## ` at the very start of the whole file. A pattern that does not occur
    /// at a line start still does not match.
    static func matches(_ pattern: String, in text: String) throws -> Bool {
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

// MARK: - Bounded-count assertions

/// The `*_lte` verdict shared by `turn_count_lte` and `model_requests_lte`.
///
/// The catalog-load schema rejects an assertion without `max`; evaluation
/// still fails loud when one reaches this point, instead of substituting
/// `Int.max` (which made a misspelled bound an always-true check).
enum ScenarioCountBound {
    static func verdict(count: Int,
                        assertion: Scenario.Assertion) throws -> (maximum: Int, ok: Bool) {
        guard let maximum = assertion.max else {
            throw ScenarioError.assertion("\(assertion.type) has no max")
        }
        return (maximum, count <= maximum)
    }
}

// MARK: - Report documents

/// The typed failure behind an assertion verdict (G2-FIX-77).
///
/// `detail` stays the human-readable sentence; `failure.kind` is a stable
/// machine value every assertion type fills on failure, so a judge can
/// distinguish "the file is missing" from "the content is wrong" without
/// parsing English.
public struct ScenarioAssertionFailure: Encodable, Equatable {
    /// Stable failure kinds. `not_executed` is a gate verdict, not a product
    /// failure; `error` is the catch-all for an artifact/evaluation error.
    public enum Kind: String, Encodable, Equatable, CaseIterable {
        case missing
        case unexpectedFile = "unexpected_file"
        case notContains = "not_contains"
        case notMatch = "not_match"
        case jsonPathAbsent = "json_path_absent"
        case commandFailed = "command_failed"
        case commandUnsupported = "command_unsupported"
        case missingReceipt = "missing_receipt"
        case workerReceiptMismatch = "worker_receipt_mismatch"
        case countExceeded = "count_exceeded"
        case notExecuted = "not_executed"
        case error

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public var kind: Kind
    public var path: String?
    public var expected: String?
    public var actual: String?

    public init(kind: Kind, path: String? = nil,
                expected: String? = nil, actual: String? = nil) {
        self.kind = kind
        self.path = path
        self.expected = expected
        self.actual = actual
    }
}

public struct ScenarioAssertionReport: Encodable {
    public var type: String
    public var ok: Bool
    public var detail: String
    /// `pending_host` while a simulator run has deferred a
    /// `workspace_command`; `host_evaluated` once a host has run it;
    /// `NOT_EXECUTED` when the run did not complete and this assertion needs
    /// the turns to have run (G2-FIX-15). Absent for assertions that never need
    /// a host process and were evaluated normally.
    public var status: String?
    /// The deferred command text, kept on the assertion for the host phase and
    /// for the judge. Absent for other assertion types.
    public var command: String?
    /// `true` when this assertion's command ran on the Mac host (the macOS
    /// runner, or the simulator host phase after the results were pulled).
    public var hostEvaluated: Bool?
    /// Wall time of the host or Worker command in milliseconds.
    public var durationMs: Int?
    /// `true` when this assertion's command ran through the live Worker's
    /// command-acceptance route (not the Mac host).
    public var workerEvaluated: Bool? = nil
    /// The full `pdsh-worker-command/1` receipt for an inspected assertion.
    /// Written only when `workerEvaluated` is true; the typed fields above and
    /// this raw object always come from the same response.
    public var workerReceipt: JSONValue? = nil
    /// The effective `worker_command` request facts. The evidence gate compares
    /// them with `worker_receipt.execution`; absent for other assertion types.
    public var program: String? = nil
    public var cwd: String? = nil
    public var timeoutMilliseconds: Int? = nil
    /// Typed failure evidence; nil for a passing or provisional assertion.
    public var failure: ScenarioAssertionFailure? = nil

    /// A `NOT_EXECUTED` assertion is never a pass even if `ok` were set; every
    /// summary and verdict computation goes through this one predicate.
    public var isPassing: Bool {
        ScenarioAssertionGate.passes(status: status, ok: ok)
    }

    private enum CodingKeys: String, CodingKey {
        case type, ok, detail, status, command, program, cwd
        case hostEvaluated = "host_evaluated"
        case durationMs = "duration_ms"
        case workerEvaluated = "worker_evaluated"
        case workerReceipt = "worker_receipt"
        case timeoutMilliseconds = "timeout_ms"
        case failure
    }
}

public struct ScenarioTurnReport: Encodable {
    public var promptLen: Int
    public var started: String
    public var ended: String?
    public var modelRequests: Int
    public var toolCalls: Int
    public var events: Int
    /// 0-based index of the planned scenario turn (G2-FIX-13/G2-FIX-125).
    public var index: Int = 0
    /// False for a planned turn the runner never delivered (a timeout before
    /// its prompt). Such a turn is still written to `turns[]` exactly once.
    public var delivered: Bool = true
    /// The prompt request id, including the runner's retry suffixes.
    public var requestID: String? = nil
    /// Prompts sent for this logical scenario turn, including the one retry.
    public var attempts: Int = 0
    /// The `turnEnded` reason kind: `completed`, `cancelled`, `aborted`,
    /// `interrupted`, `failed` or `budget`. Nil while no terminal event has
    /// arrived.
    public var terminalReason: String? = nil

    private enum CodingKeys: String, CodingKey {
        case promptLen = "prompt_len"
        case started, ended
        case modelRequests = "model_requests"
        case toolCalls = "tool_calls"
        case events
        case index, delivered
        case requestID = "request_id"
        case attempts
        case terminalReason = "terminal_reason"
    }
}

/// Static evidence from the materialized workspace of an incomplete run
/// (G2-FIX-94). This is audit material only: it is never summarized into the
/// assertion verdict and can never turn the run into PASS.
public struct ScenarioPartialEvidenceReport: Encodable {
    /// 0-based index of the catalog assertion this evidence belongs to.
    public var assertionIndex: Int
    public var type: String
    public var ok: Bool
    public var detail: String
    /// `materialized_workspace`: the evidence is a static read of the tree the
    /// delivered turns left behind, not a completed-run verdict.
    public var basis: String
    /// Delivered scenario turns that had a terminal `turnEnded` event.
    public var completedTurns: Int
    /// Attribution against the seeded fixture: `created_since_fixture`,
    /// `modified_since_fixture`, `unchanged_from_fixture`,
    /// `absent_in_fixture_and_workspace` or `fixture_baseline_unavailable`.
    public var fixtureDiff: String?

    private enum CodingKeys: String, CodingKey {
        case assertionIndex = "assertion"
        case type, ok, detail, basis
        case completedTurns = "completed_turns"
        case fixtureDiff = "fixture_diff"
    }
}

public struct ScenarioPerturbationReport: Encodable {
    public var at: String
    public var kind: String
    public var recoveredMs: Int?
    public var ok: Bool?
    /// `applied` for a perturbation this run executed; `runner_infra` for a
    /// declaration the execution target cannot execute (G2-FIX-65). The
    /// scenario was then aborted as INFRA and no assertion was evaluated.
    public var status: String?
    /// The capability mechanism that executed the perturbation: `host-call`,
    /// `page-worker-terminate`, `host-webcontent-sigkill` or
    /// `simulator-webcontent-watcher`.
    public var mechanism: String?
    /// The WebContent pid(s) a `webcontent_kill` actually signalled.
    public var killedPids: [Int]?
    /// The WAL mutations that account for the observed workspace state after
    /// recovery, in mseq order. Present for every applied perturbation: the
    /// recovery check replays these mutations on the frozen pre-perturbation
    /// workspace and requires byte equality with the materialized copy.
    public var accountedChanges: [ScenarioRecoveryChange]? = nil
    public var detail: String?

    private enum CodingKeys: String, CodingKey {
        case at, kind, ok, detail, status, mechanism
        case recoveredMs = "recovered_ms"
        case killedPids = "killed_pids"
        case accountedChanges = "accounted_changes"
    }
}

public struct ScenarioUsageReport: Encodable {
    public var modelRequests: Int
    public var upstreamBytesIn: Int
    public var upstreamBytesOut: Int
    /// Where the byte counters came from: `gateway_metrics`, `mock` or
    /// `response_log_fallback` (G2-FIX-7/G2-FIX-126).
    public var bytesSource: String?
    /// Backward-compatible alias for `run_wall_s`.
    public var wallS: Double
    /// Runner lifetime from ScenarioRun creation through artifact evaluation
    /// and teardown, matching the historical `wall_s` measurement.
    public var runWallS: Double
    /// Session lifetime from successful harness session open until host stop.
    /// Omitted when this run never opened a session.
    public var sessionWallS: Double?

    public init(modelRequests: Int, upstreamBytesIn: Int, upstreamBytesOut: Int,
                wallS: Double, runWallS: Double? = nil, sessionWallS: Double? = nil,
                bytesSource: String? = nil) {
        self.modelRequests = modelRequests
        self.upstreamBytesIn = upstreamBytesIn
        self.upstreamBytesOut = upstreamBytesOut
        self.bytesSource = bytesSource
        let runnerWall = runWallS ?? wallS
        self.wallS = runnerWall
        self.runWallS = runnerWall
        self.sessionWallS = sessionWallS
    }

    private enum CodingKeys: String, CodingKey {
        case modelRequests = "model_requests"
        case upstreamBytesIn = "upstream_bytes_in"
        case upstreamBytesOut = "upstream_bytes_out"
        case wallS = "wall_s"
        case runWallS = "run_wall_s"
        case sessionWallS = "session_wall_s"
        case bytesSource = "bytes_source"
    }
}

/// The pre-turn page-visibility sample (G2-FIX-21): both halves of the
/// WebKit precondition, recorded so a failed real-model run shows whether the
/// page was throttled.
public struct ScenarioPageVisibilityReport: Encodable {
    public var attachedWithVisibleArea: Bool
    public var windowOcclusionVisible: Bool?
    public var documentVisibilityState: String?
    public var isVisible: Bool

    private enum CodingKeys: String, CodingKey {
        case attachedWithVisibleArea = "attached_with_visible_area"
        case windowOcclusionVisible = "window_occlusion_visible"
        case documentVisibilityState = "document_visibility_state"
        case isVisible = "is_visible"
    }
}

/// The two diagnostic channels `report.json` writes, kept apart on purpose.
///
/// `console_errors` is the Worker/session console error stream and nothing
/// else: it is exactly the array `no_console_error` and `session_error`
/// evaluate. Runner lifecycle diagnostics (a deferred run, a runner-INFRA
/// abort, the terminal timeout/budget/error that ended the run) are facts about
/// the runner, not Worker console output, so they belong to the separate
/// `runner_errors` field. Mixing the two made `report.json` contradict itself:
/// `no_console_error` was evaluated on the Worker/session array and could be
/// `ok: true` while the same `console_errors` field listed the runner's own
/// timeout.
struct ScenarioReportDiagnostics: Equatable {
    /// The bound on each diagnostic channel before the paired arrays are
    /// written (the historical report cap kept the same tail).
    static let limit = 2000

    /// Worker/session console errors, redacted and bounded, in arrival order.
    var consoleErrors: [String]
    /// Runner lifecycle diagnostics, redacted and bounded, in runner order.
    var runnerErrors: [String]

    init(consoleErrors: [String],
         runnerDiagnostics: [String],
         redactor: ScenarioRedactor = ScenarioRedactor()) {
        self.consoleErrors = Self.channel(consoleErrors, redactor: redactor)
        self.runnerErrors = Self.channel(runnerDiagnostics, redactor: redactor)
    }

    /// The exact array `no_console_error` evaluates; the report writes this
    /// same array, so the verdict and the field can never disagree.
    var assertionConsoleErrors: [String] { consoleErrors }

    /// The runner diagnostics of a run, in the order the report has always
    /// listed them: deferral, runner-INFRA abort, terminal error, other error.
    static func runnerDiagnostics(deferred: String?,
                                  runnerInfra: String?,
                                  terminalError: String?,
                                  otherError: String?) -> [String] {
        var diagnostics: [String] = []
        if let deferred { diagnostics.append("runner: deferred: \(deferred)") }
        if let runnerInfra { diagnostics.append("runner: \(runnerInfra)") }
        if let terminalError { diagnostics.append("runner: \(terminalError)") }
        if let otherError { diagnostics.append("runner: \(otherError)") }
        return diagnostics
    }

    /// Redacts one channel and applies the report cap to it.
    static func channel(_ diagnostics: [String],
                        redactor: ScenarioRedactor = ScenarioRedactor()) -> [String] {
        let redacted = diagnostics.map { redactor.redact($0) }
        return redacted.count > limit ? Array(redacted.suffix(limit)) : redacted
    }
}

/// How a failed `host.stop()` enters the scenario run's terminal state.
///
/// `stop()` seals the WAL after it finishes the event bus, so a seal failure
/// is only visible in the thrown error. The runner must not swallow it: the
/// error is appended to the runner diagnostics (through `otherError`) and the
/// report can never be PASS. An earlier terminal error is preserved verbatim
/// and the stop detail is appended beside it, never overwriting the cause that
/// ended the run first.
struct ScenarioStopFailure {
    var terminalError: ScenarioError?
    var otherError: String?
    var detail: String

    static func merge(error: Error,
                      terminalError: ScenarioError?,
                      otherError: String?) -> ScenarioStopFailure {
        let detail = "host.stop() failed: \(String(describing: error))"
        let combined = [otherError, detail]
            .compactMap { $0 }
            .joined(separator: "; ")
        return ScenarioStopFailure(terminalError: terminalError,
                                   otherError: combined,
                                   detail: detail)
    }
}

public struct ScenarioReport: Encodable {
    public var id: String
    public var status: String
    public var assertions: [ScenarioAssertionReport]
    public var turns: [ScenarioTurnReport]
    public var perturbations: [ScenarioPerturbationReport]
    public var usage: ScenarioUsageReport
    public var pageVisibility: ScenarioPageVisibilityReport?
    /// Present when an environment precondition deferred the run (a locked Mac
    /// console); `status` is then `SKIP` and no scenario code ran.
    public var deferred: String?
    /// Present when the runner aborted the scenario before the product ran (an
    /// unexecutable perturbation declaration on this execution target,
    /// G2-FIX-65). `status` is then `INFRA`; no assertion — in particular no
    /// `restart_recovered` — is evaluated, so a capability gap can never be
    /// reported as a product recovery failure.
    public var runnerInfra: String?
    /// WebContent terminations the host observed during the run (the evidence
    /// that a `webcontent_kill` reached the engine's D14 path).
    public var webContentTerminations: UInt64
    /// `true` when at least one assertion's `workspace_command` ran on the Mac
    /// host for this report: the macOS runner evaluates it inline, and the
    /// simulator host phase adds this marker when it finalizes the pulled
    /// report. Absent when no host command ran (or a simulator run is still
    /// `PENDING_HOST`).
    public var hostEvaluated: Bool?
    /// `true` when at least one assertion's `worker_command` ran on the live
    /// Worker's immutable VFS fork. Kept separate from `hostEvaluated`: the two
    /// acceptance locations are never merged into one label.
    public var workerEvaluated: Bool? = nil
    /// Worker/session console errors only, redacted: the same array
    /// `no_console_error` and `session_error` evaluate. Runner lifecycle
    /// diagnostics are in `runner_errors`, never in this field.
    public var consoleErrors: [String]
    /// Runner lifecycle diagnostics (deferred run, runner-INFRA abort,
    /// timeout/budget/other terminal exit), redacted. These are facts about the
    /// runner, not Worker console output, and are never evaluated by
    /// `no_console_error`.
    public var runnerErrors: [String]
    public var hostStates: [String]
    /// The run-completion fact the assertion gate used (G2-FIX-15): every
    /// scenario turn delivered, every delivered turn has a terminal `ended`,
    /// and the run did not exit through timeout/budget/error. `false` means
    /// progress-dependent assertions are `NOT_EXECUTED`, never a pass.
    public var runCompleted: Bool
    /// The facts that made `runCompleted` false; absent for a completed run.
    public var runIncompleteReason: String?
    /// Declared-versus-effective resource budget provenance (G2-FIX-115).
    /// Present for a scenario that declares a `budgets` block, on every exit
    /// path: `declared_single_file_bytes` is the scenario premise and
    /// `effective_single_file_bytes` is the Worker-reported manifest value.
    /// `matches` is true only when both the host configuration and the Worker
    /// agree with the declaration; a drift makes the run fail loud.
    public var budgets: ScenarioBudgetProvenance? = nil
    /// Static, incomplete-run evidence from the materialized workspace
    /// (G2-FIX-94). Present only when the run did not complete; never counted
    /// in `assertions` or in the status.
    public var partialEvidence: [ScenarioPartialEvidenceReport]? = nil

    private enum CodingKeys: String, CodingKey {
        case id, status, assertions, turns, perturbations, usage, deferred
        case pageVisibility = "page_visibility"
        case runnerInfra = "runner_infra"
        case webContentTerminations = "webcontent_terminations"
        case consoleErrors = "console_errors"
        case runnerErrors = "runner_errors"
        case hostStates = "host_states"
        case hostEvaluated = "host_evaluated"
        case workerEvaluated = "worker_evaluated"
        case runCompleted = "run_completed"
        case runIncompleteReason = "run_incomplete_reason"
        case budgets
        case partialEvidence = "partial_evidence"
    }
}

// MARK: - Engine holder

/// The engine the host factory created. The test keeps the object to inject the
/// page-side Worker hook (before boot) and to terminate the Worker later.
final class ScenarioEngineBox: @unchecked Sendable {
    var engine: WebEngine?
    var container: WebEngineHostView?
}

// MARK: - Pending perturbation

private struct PendingPerturbation {
    typealias Point = ScenarioPerturbationPoint

    var spec: Scenario.Perturbation
    var point: Point
    var applied = false
}

// MARK: - Perturbation coverage

/// The declared perturbation points and the reports the run produced, mapped
/// to the report entries and the `restart_recovered` verdict.
///
/// Two terminal categories keep a missing recovery loud and distinguishable:
/// unexercised (the run never reached the point) and unrecovered (the
/// perturbation was applied with `ok: false`). Every category fails the
/// verdict; only an exact applied-and-recovered match passes.
///
/// A third, legacy category (`ok: null`, "unavailable") is still mapped
/// separately for a report written before G2-FIX-65. The current runner never
/// produces it: the capability matrix validates every declaration before the
/// run and aborts an unexecutable scenario as a runner-INFRA result, so an
/// unsupported kind can no longer appear in this mapping or fail
/// `restart_recovered`.
///
/// Deliberately pure: no host, WebKit or filesystem state is involved, so the
/// recovery-coverage rule is unit-testable without a model or a WKWebView boot.
struct ScenarioPerturbationCoverage {
    struct Declared: Equatable {
        var at: String
        var kind: String
    }

    struct Verdict: Equatable {
        var ok: Bool
        var detail: String
    }

    struct Result {
        var entries: [ScenarioPerturbationReport]
        var restartRecovered: Verdict
    }

    static func resolve(declared: [Declared],
                        appliedReports: [ScenarioPerturbationReport],
                        runStatus: String) -> Result {
        var entries: [ScenarioPerturbationReport] = []
        var consumed = Array(repeating: false, count: appliedReports.count)
        var unexercised: [String] = []
        var unavailable: [String] = []
        var unrecovered: [String] = []

        func label(_ item: Declared) -> String {
            "\(item.at) (\(item.kind))"
        }

        for item in declared {
            let match = appliedReports.indices.first {
                !consumed[$0]
                    && appliedReports[$0].at == item.at
                    && appliedReports[$0].kind == item.kind
            }
            if let match {
                consumed[match] = true
                let report = appliedReports[match]
                entries.append(report)
                if report.ok == nil {
                    // Legacy defensive category: the current runner never
                    // writes `ok: null` (an unsupported declaration aborts as
                    // runner-INFRA before the run, G2-FIX-65), but a report
                    // from an older tree can still be mapped here. The point
                    // was reached, so it is neither unexercised nor
                    // applied-and-unrecovered; recovery is still unproven.
                    unavailable.append(label(item))
                } else if report.ok != true {
                    unrecovered.append(label(item))
                }
                continue
            }
            // The point was never reached (or its result was never recorded):
            // keep a skipped entry so the report lists every declaration.
            entries.append(ScenarioPerturbationReport(
                at: item.at,
                kind: item.kind,
                recoveredMs: nil,
                ok: nil,
                detail: "skipped: perturbation point \(label(item)) was not reached "
                    + "before the run ended with status \(runStatus)"))
            unexercised.append(label(item))
        }
        // No current caller produces a report outside the declaration list;
        // preserve one rather than hiding run evidence.
        for index in appliedReports.indices where !consumed[index] {
            entries.append(appliedReports[index])
        }

        if declared.isEmpty {
            return Result(entries: entries, restartRecovered: Verdict(
                ok: true, detail: "the scenario declares no perturbations"))
        }
        var problems: [String] = []
        if !unexercised.isEmpty {
            problems.append("unexercised perturbation point(s): "
                + unexercised.joined(separator: ", "))
        }
        if !unavailable.isEmpty {
            problems.append("unavailable perturbation point(s): "
                + unavailable.joined(separator: ", "))
        }
        if !unrecovered.isEmpty {
            problems.append("unrecovered perturbation point(s): "
                + unrecovered.joined(separator: ", "))
        }
        if problems.isEmpty {
            return Result(entries: entries, restartRecovered: Verdict(
                ok: true,
                detail: "\(declared.count) perturbation(s) applied and recovered"))
        }
        return Result(entries: entries, restartRecovered: Verdict(
            ok: false,
            detail: problems.joined(separator: "; ") + "; run status \(runStatus)"))
    }
}

// MARK: - The run

/// Executes one scenario. Create on the main actor and call ``execute()``.
@MainActor
public final class ScenarioRun {
    private let scenario: Scenario
    private let environment: ScenarioEnvironment
    private let resultsDirectory: URL
    private let hostRoot: URL
    private let scratchDirectory: URL
    private let recorder = ScenarioRecorder()
    private let startedAt = Date()
    private let redactor: ScenarioRedactor

    private var mock: ScenarioMockUpstream?
    private var credentialProvider: ScenarioCredentialProvider?
    private var visibleWindow: ScenarioVisibleWindow?
    private var container: WebEngineHostView?
    private let engineBox = ScenarioEngineBox()
    private var host: PhoneDSHHost?
    private var harness: (any AgentHarness)?
    private var harnessPump: Task<Void, Never>?
    private var sessionID: String?
    private var sessionStartedAt: Date?
    private var sessionEndedAt: Date?
    private var webContentPid: pid_t?

    private var pending: [PendingPerturbation] = []
    /// Number of perturbations actually applied so far; a turn that a
    /// perturbation interrupted is retried once the host is Running again.
    private var perturbationApplications = 0
    private var perturbationReports: [ScenarioPerturbationReport] = []
    /// The final `restart_recovered` verdict, computed once the run reaches
    /// any terminal path (success, ScenarioError or any other error).
    private var restartRecoveredVerdict: ScenarioPerturbationCoverage.Verdict?
    private var turnReports: [ScenarioTurnReport] = []
    private var assertionReports: [ScenarioAssertionReport] = []
    /// `worker_command` reports produced while the live Worker was still up,
    /// keyed by catalog assertion index. They are merged into the final report
    /// after `host.stop()` so old host and new Worker acceptance keep their
    /// catalog positions and their distinct `host_evaluated`/`worker_evaluated`
    /// markers.
    private var workerCommandReports: [Int: ScenarioAssertionReport] = [:]
    /// The redacted Worker/session console errors the assertion gate evaluated.
    /// `buildReport` writes exactly this array to `console_errors`; runner
    /// diagnostics go to the separate `runner_errors` channel.
    private var evaluatedConsoleErrors: [String]?
    private var terminalError: ScenarioError?
    private var otherError: String?
    /// The capability matrix of this execution target (G2-FIX-65).
    private let capabilities: ScenarioPerturbationCapabilities
    /// The load-time rejection of this scenario, when its declarations cannot
    /// execute on this target. Executing the run then writes an INFRA report
    /// without booting the host; no assertion is evaluated.
    private let preflightRejection: ScenarioInfraRejection?
    /// Set when the run aborted as runner-infra (preflight or a failed
    /// mechanism). `runnerInfra` in the report is set from this.
    private var runnerInfra: ScenarioInfraRejection?
    /// Set when the environment cannot run a WKWebView scenario at all (a
    /// locked Mac console); the report is `SKIP` and the XCTest case skips.
    private var deferredReason: String?
    /// Declared-versus-effective resource budget provenance (G2-FIX-115).
    /// Written to `report.json` on every exit path once the host configuration
    /// has been built.
    private var budgetProvenance: ScenarioBudgetProvenance?
    /// The materialized workspace as it was seeded, used only to attribute
    /// partial evidence to the fixture (G2-FIX-94).
    private var fixtureBaseline: MaterializedSnapshot?
    /// Static workspace evidence written for an incomplete run (G2-FIX-94).
    private var partialEvidence: [ScenarioPartialEvidenceReport] = []
    /// The host gateway counters captured after `host.stop()` (G2-FIX-7).
    private var gatewayMetrics: ModelGatewayMetrics?
    private let wallDeadline: Date

    public init(scenario: Scenario, environment: ScenarioEnvironment,
                preflight: ScenarioInfraRejection? = nil,
                capabilities: ScenarioPerturbationCapabilities = .current) {
        self.scenario = scenario
        self.environment = environment
        self.capabilities = capabilities
        self.preflightRejection = preflight
            ?? ScenarioPerturbationPreflight.rejection(for: scenario,
                                                        capabilities: capabilities)
        let directory = environment.resultsRoot.appendingPathComponent(scenario.id, isDirectory: true)
        self.resultsDirectory = directory
        self.hostRoot = directory.appendingPathComponent("host", isDirectory: true)
        self.scratchDirectory = directory.appendingPathComponent("scratch", isDirectory: true)
        self.wallDeadline = Date().addingTimeInterval(
            TimeInterval(max(1, scenario.budget.maxMinutes) * 60))
        self.redactor = ScenarioRedactor(secrets: [environment.modelAPIKey ?? ""])
        self.pending = scenario.perturbations?.map { spec in
            PendingPerturbation(spec: spec,
                                point: ScenarioPerturbationPoint(rawValue: spec.at))
        } ?? []
    }

    /// The catalog spelling the coverage mapping uses for a declared point.
    /// Exposed to the tests so the "unknown points are preserved, never
    /// dropped" rule is testable without a WKWebView boot.
    nonisolated static func pointLabel(for point: String) -> String {
        ScenarioPerturbationPoint(rawValue: point).raw
    }

    /// Builds the host configuration for one scenario with the scenario's
    /// declared resource budgets injected through the public
    /// `PhoneDSHConfiguration.singleFileLimitBytes` field.
    ///
    /// Kept separate from ``startHost()`` so the injection path is testable
    /// without a WKWebView: the regression test builds the same configuration
    /// the runner boots and drives a scripted Worker through the real
    /// `PhoneDSHHost` (G2-FIX-115). A `nil` declaration passes `nil`, which is
    /// exactly the landed host default behaviour.
    nonisolated static func hostConfiguration(
        workspaceRoot: URL,
        bundle: PhoneDSHBundleLocation,
        allowedModelHosts: Set<String>,
        replaySafeModelEndpoints: Set<String> = [],
        credentialProvider: any CredentialProvider,
        budgets: ScenarioBudgets?,
        drainDeadline: TimeInterval,
        helloTimeout: TimeInterval
    ) -> PhoneDSHConfiguration {
        PhoneDSHConfiguration(
            workspaceRoot: workspaceRoot,
            token: "scenario-launch-token",
            origin: URL(string: "http://127.0.0.1:1")!,
            bundle: bundle,
            allowedModelHosts: allowedModelHosts,
            replaySafeModelEndpoints: replaySafeModelEndpoints,
            credentialProvider: credentialProvider,
            drainDeadline: drainDeadline,
            helloTimeout: helloTimeout,
            singleFileLimitBytes: budgets?.singleFileBytes)
    }

    // MARK: Execute

    public func execute() async -> ScenarioReport {
        do {
            // G2-FIX-Q3: a batch/tooling cleanup that decides to stop the
            // test process must not kill it silently mid-suite. The guard
            // records SIGTERM/SIGINT/SIGHUP; the waits below turn the request
            // into a reportable runner-INFRA failure, and the process lives on
            // to write the report and the XCTest summary.
            ScenarioProcessSignals.install()
            try ScenarioProcessSignals.throwIfTerminationRequested()
            try prepareDirectories()
            // G2-FIX-65: a declaration this execution target cannot execute
            // aborts the scenario before any product code runs. The report is
            // an explicit INFRA result; no assertion is evaluated, so the gap
            // cannot be confused with a recovery failure.
            if let rejection = preflightRejection {
                return finishInfra(rejection)
            }
            // A locked console makes every window occlusion-hidden, so the page
            // is throttled and no scenario can run; record the environment
            // state and let the XCTest case skip. The fail-loud visibility
            // assertion below still applies to an unlocked session.
            if let deferred = ScenarioConsoleSession.lockedReason {
                deferredReason = deferred
                do {
                    try writeTranscript()
                } catch {
                    otherError = String(describing: error)
                }
                let report = buildReport()
                do {
                    try writeReport(report)
                } catch {
                    print("scenario \(scenario.id): cannot write report.json: \(error)")
                }
                return report
            }
            let seeds = try ScenarioFixtures.seeds(
                for: scenario,
                fixturesRoot: environment.fixturesRoot,
                scratch: scratchDirectory)
            _ = try await ScenarioWorkspace.seed(roots: seeds, workspaceRoot: hostRoot)
            fixtureBaseline = MaterializedSnapshot.read(workspaceRoot: hostRoot)
            try setUpWindow()
            try startMockUpstreamIfNeeded()
            try await startHost()
            try await requireVisiblePageBeforeFirstTurn()
            try await runTurns()
            // A minute perturbation can come due while the last turn ends;
            // apply it before the success path closes the run.
            try await applyDueMinutePerturbations()
            // G2-FIX-35: Worker assertions need the live Worker, so they run
            // here, after the turns and before `host.stop()` below. The old
            // host `workspace_command` assertions still run after the stop
            // against the materialized copy; the two are never merged.
            try await evaluateWorkerCommands()
        } catch let error as ScenarioError {
            if case .infra(let detail) = error {
                runnerInfra = runtimeInfraRejection(reason: detail)
            } else {
                terminalError = error
            }
        } catch {
            otherError = String(describing: error)
        }

        // Every exit path (success, ScenarioError, any other error) records a
        // terminal state for every declared perturbation before assertions and
        // the report are built. An unreached point is a coverage miss, never a
        // silently absent report entry. A runner-INFRA abort has no verdict:
        // the declarations are listed in the report and no assertion runs.
        if runnerInfra == nil {
            finalizePerturbations(runStatus: runStatusForFinalization)
        }

        if let host {
            do {
                try await host.stop()
            } catch {
                // `stop()` reports a failed terminal WAL seal only through this
                // error, after it has already finished the event bus. Record it
                // instead of turning the run into a PASS.
                recordStopFailure(error)
            }
            if sessionStartedAt != nil { sessionEndedAt = Date() }
            // G2-FIX-7/G2-FIX-126: one snapshot after the host stopped. The
            // gateway counters are complete by then and `stop()` keeps them in
            // the host's last diagnostics.
            gatewayMetrics = await host.diagnostics().gatewayMetrics
        }
        recorder.stop()

        // The materialized copy stops changing once the host is parked/stopped.
        do {
            try writeTranscript()
            if runnerInfra == nil {
                try writeWorkspaceArchive()
                try evaluateAssertions()
                try writeModelBodies()
            }
        } catch let error as ScenarioError {
            if terminalError == nil { terminalError = error }
        } catch {
            if otherError == nil { otherError = String(describing: error) }
        }

        await teardown()
        let report = buildReport()
        do {
            try writeReport(report)
        } catch {
            // The test failure below still carries the details.
            print("scenario \(scenario.id): cannot write report.json: \(error)")
        }
        return report
    }

    /// Writes the runner-INFRA report for a scenario rejected at load and
    /// returns it. The host is never started; the declared perturbations are
    /// visible with the `runner_infra` terminal status and no assertion (in
    /// particular no `restart_recovered`) is evaluated.
    private func finishInfra(_ rejection: ScenarioInfraRejection) -> ScenarioReport {
        runnerInfra = rejection
        try? writeTranscript()
        let report = buildReport()
        do {
            try writeReport(report)
        } catch {
            print("scenario \(scenario.id): cannot write report.json: \(error)")
        }
        return report
    }

    /// Turns a runtime mechanism failure (a supported kind the runner still
    /// could not execute) into the same explicit runner-INFRA classification.
    private func runtimeInfraRejection(reason: String) -> ScenarioInfraRejection {
        let detail = "scenario \(scenario.id) aborted as runner-infra on "
            + "\(capabilities.target.rawValue): \(reason)"
        return ScenarioInfraRejection(
            scenarioID: scenario.id,
            target: capabilities.target,
            perturbations: (scenario.perturbations ?? []).map {
                ScenarioInfraPerturbation(at: $0.at, kind: $0.kind, reason: reason)
            },
            reason: detail)
    }

    // MARK: Setup

    private func prepareDirectories() throws {
        let safeID = scenario.id.range(
            of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil
        guard safeID, scenario.id != ".", scenario.id != ".." else {
            throw ScenarioError.environment("scenario id is not path-safe: \(scenario.id)")
        }
        let manager = FileManager.default
        try manager.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
        // The batch orchestrator writes its own files into this directory
        // (scenario.json, history/, judge outputs); this run only replaces its
        // own artifacts.
        let owned = ["report.json", "transcript.jsonl", "workspace.tar",
                     "host", "scratch", "check-workspace", "bodies"]
        for name in owned {
            let url = resultsDirectory.appendingPathComponent(name)
            if manager.fileExists(atPath: url.path) {
                try manager.removeItem(at: url)
            }
        }
        try ScenarioDefinitionArtifact.write(
            scenario, to: resultsDirectory.appendingPathComponent("scenario.json"),
            redactor: redactor)
        try manager.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
    }

    private func setUpWindow() throws {
        let window = try ScenarioVisibleWindow(
            title: "phone-dsh scenario \(scenario.id)")
        self.visibleWindow = window
        self.container = window.container
        self.engineBox.container = window.container
    }

    private func startMockUpstreamIfNeeded() throws {
        guard !environment.isRealUpstream else { return }
        let mock = ScenarioMockUpstream()
        if let spec = scenario.mock { mock.script = spec.script }
        _ = try mock.start()
        self.mock = mock
    }

    private var modelBaseURL: URL {
        if let url = environment.modelBaseURL { return url }
        guard let mock else { return URL(string: "http://127.0.0.1:1")! }
        return mock.baseURL
    }

    private var modelHost: String {
        modelBaseURL.host?.lowercased() ?? "127.0.0.1"
    }

    private var workerModelName: String {
        environment.modelName ?? "deepseek-flash"
    }

    private func startHost() async throws {
        guard let container else {
            throw ScenarioError.environment("the WKWebView container was not created")
        }
        let provider = ScenarioCredentialProvider(
            modelHost: modelHost,
            modelKey: environment.isRealUpstream ? environment.modelAPIKey : "scenario-mock-key",
            anonymousHosts: Set(scenario.network?.allowedHosts ?? []))
        self.credentialProvider = provider

        let mockHostRule: String
        if environment.isRealUpstream {
            mockHostRule = modelHost
        } else {
            mockHostRule = "http://127.0.0.1:\(mock?.port ?? 0)"
        }
        let modelHosts: Set<String> = [mockHostRule]
        let gatewayHosts = modelHosts.union(scenario.network?.allowedHosts ?? [])

        let bundle = PhoneDSHBundleLocation(
            staticDirectory: environment.staticDirectory,
            imageArchive: environment.imageArchive)
        var configuration = Self.hostConfiguration(
            workspaceRoot: hostRoot,
            bundle: bundle,
            allowedModelHosts: modelHosts,
            // Model POSTs keep the gateway's 429/5xx backoff; egress POSTs do not.
            replaySafeModelEndpoints: ModelGatewayConfiguration.standardModelEndpoints(baseURL: modelBaseURL),
            credentialProvider: provider,
            budgets: scenario.budgets,
            drainDeadline: 20,
            helloTimeout: 240)
        configuration.gateway.allowedUpstreamHosts = gatewayHosts
        configuration.engine.bootTimeout = 240
        // G2-FIX-115: record the declaration against the value the host
        // configuration actually resolved to before any Worker boots. A tier
        // gate that clamped the declared limit is a premise failure now, not a
        // silent default later.
        if let declared = scenario.budgets?.singleFileBytes {
            let provenance = ScenarioBudgetCheck.inspect(
                declaredSingleFileBytes: declared,
                hostConfigurationSingleFileBytes: configuration.singleFileLimitBytes,
                effectiveSingleFileBytes: nil,
                source: "host configuration")
            budgetProvenance = provenance
            try ScenarioBudgetCheck.validateHostConfiguration(provenance)
        }
        var workerEnvironment = [
            "DEEPSEEK_BASE_URL": modelBaseURL.absoluteString,
            "DEEPSEEK_API_KEY": environment.isRealUpstream
                ? "scenario-host-injects-key" : "scenario-mock-key",
            "DSH_TELEMETRY_DISABLED": "1",
            // Informational only: the Worker's packed profile fixes the DSH
            // default model row (deepseek-flash in the pinned base bundle).
            "PDSH_MODEL_NAME": workerModelName,
            "PDSH_SCENARIO_ID": scenario.id,
        ]
        if !environment.isRealUpstream {
            workerEnvironment["PDSH_SCENARIO_UPSTREAM"] = "mock"
            // Stall self-tests shorten the Worker's delivery inactivity
            // interval through harness config; every other mock run keeps the
            // production default. A value longer than the scenario budget is
            // how the pre-fix evidence run neutralizes the deadline.
            if let deliveryIdle = scenario.mock?.deliveryIdleTimeoutMs {
                workerEnvironment["PDSH_LLM_DELIVERY_IDLE_TIMEOUT_MS"] =
                    "\(max(1, deliveryIdle))"
            }
        }
        configuration.engine.environment = workerEnvironment

        let box = engineBox
        let scenarioContainer = container
        let factory: PhoneDSHEngineFactory = { engineConfiguration in
            try await MainActor.run {
                let engine = WebEngine(configuration: engineConfiguration)
                engine.attach(to: scenarioContainer)
                // Page-side hook for the `worker_kill` perturbation: wrap the
                // Worker constructor before boot.js evaluates so the runner can
                // terminate the real Worker execution context. The page and
                // the worker-entry bundle are unchanged; this is a document-start
                // user script owned by the test harness.
                let script = WKUserScript(
                    source: ScenarioRun.workerWrapperScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true)
                engine.view.configuration.userContentController.addUserScript(script)
                box.engine = engine
                return engine as any WebEngineControlling
            }
        }

        let scenarioHost = PhoneDSHHost(configuration: configuration, engineFactory: factory)
        self.host = scenarioHost
        recorder.attach(host: scenarioHost)

        // Only a lane holding this lock boots a WKWebView, so every macOS
        // WebContent process that appears in the window belongs to this run.
        let bootLock = try? ScenarioBootLock(path: ScenarioBootLock.sharedPath)
        defer { bootLock?.release() }
        let baseline = ScenarioWebContent.allPids()
        try await withBudget(timeout: 240, label: "host start") {
            try await scenarioHost.start()
        }
        try await scenarioWait(timeout: 240, label: "host Running") {
            await scenarioHost.state == .running
        }
        let diagnostics = await scenarioHost.diagnostics()
        guard diagnostics.state == .running, diagnostics.admission == .open else {
            throw ScenarioError.environment(
                "the host did not reach Running with admission open "
                + "(state \(diagnostics.state.rawValue), admission \(diagnostics.admission.rawValue))")
        }
        // G2-FIX-115: the declaration is only a premise once the Worker reports
        // the same effective budget. Verify before the first turn, so a drifted
        // scenario can never spend a model request on a false premise.
        try await verifyDeclaredResourceBudgets()
        let appeared = ScenarioWebContent.allPids().subtracting(baseline)
        webContentPid = ScenarioWebContent.newestPid(among: appeared)
            ?? appeared.first
            ?? ScenarioWebContent.current()?.pid
        // The WebContent identity is settled; harness/session setup does not
        // create a WebKit process, so other lanes may boot again.
        bootLock?.release()

        let harness = try await scenarioHost.harness()
        self.harness = harness
        let session = try await harness.openSession(
            HarnessSessionRequest(workspace: "/dsh/workspace"))
        sessionStartedAt = Date()
        sessionID = session.id
        harnessPump = recorder.attach(harness: harness, sessionID: session.id, after: nil)
    }

    /// G2-FIX-115: verifies the effective single-file budget the Worker
    /// actually booted with against the scenario declaration.
    ///
    /// The Worker publishes its machine-readable environment to
    /// `/dsh/home/capabilities.json`; that write travels the real VFS sink and
    /// is materialized by the host, so reading the materialized copy is a fact
    /// about the running machine, not about what the runner configured. Host
    /// HELLO caps are capability names only (channel.md §2.2) and carry no
    /// limits, so the manifest is the effective-limit report.
    ///
    /// A mismatch fails the run loud and leaves both values in
    /// ``budgetProvenance``/`report.json`; the run status then names the premise
    /// failure instead of the scenario silently measuring the default host.
    private func verifyDeclaredResourceBudgets() async throws {
        guard let declared = scenario.budgets?.singleFileBytes else { return }
        let manifest = hostRoot.appendingPathComponent(
            ScenarioBudgetCheck.capabilitiesRelativePath)
        let source = "host/" + ScenarioBudgetCheck.capabilitiesRelativePath
        do {
            try await scenarioWait(
                timeout: 60, label: "the Worker capability manifest",
                deadline: wallDeadline
            ) {
                FileManager.default.fileExists(atPath: manifest.path)
            }
        } catch let error as ScenarioError {
            guard case .timeout = error else { throw error }
            budgetProvenance = ScenarioBudgetCheck.inspect(
                declaredSingleFileBytes: declared,
                hostConfigurationSingleFileBytes:
                    budgetProvenance?.hostConfigurationSingleFileBytes,
                effectiveSingleFileBytes: nil,
                source: source,
                detail: "the Worker did not materialize the capability manifest in time")
            throw ScenarioError.environment(
                "scenario resource budget cannot be verified: declared "
                    + "singleFileBytes=\(declared) but the Worker never materialized "
                    + source)
        }
        let effective: Int
        do {
            effective = try ScenarioBudgetCheck.effectiveSingleFileBytes(
                inCapabilityManifest: Data(contentsOf: manifest))
        } catch {
            budgetProvenance = ScenarioBudgetCheck.inspect(
                declaredSingleFileBytes: declared,
                hostConfigurationSingleFileBytes:
                    budgetProvenance?.hostConfigurationSingleFileBytes,
                effectiveSingleFileBytes: nil,
                source: source,
                detail: String(describing: error))
            throw ScenarioError.artifact(
                "cannot verify the scenario resource budget from \(source): \(error)")
        }
        let provenance = ScenarioBudgetCheck.inspect(
            declaredSingleFileBytes: declared,
            hostConfigurationSingleFileBytes:
                budgetProvenance?.hostConfigurationSingleFileBytes,
            effectiveSingleFileBytes: effective,
            source: source)
        budgetProvenance = provenance
        try ScenarioBudgetCheck.validateEffective(provenance)
    }

    // MARK: Turns

    /// G2-FIX-21: fail loud before the first turn when WebKit cannot see the
    /// page.
    ///
    /// A hidden page is throttled: the Worker's fetch body, timers and channel
    /// frames stop while the WebContent process stays alive, so the run would
    /// otherwise burn its whole wall budget in silence. The shared pump runs
    /// inside `harnessAssertPageVisible`, so this assertion also catches a
    /// harness that forgot to dispatch AppKit events.
    private func requireVisiblePageBeforeFirstTurn() async throws {
        guard let engine = engineBox.engine else {
            throw ScenarioError.environment(
                "the WKWebView engine is not available before the first turn")
        }
        do {
            let visibility = try await harnessAssertPageVisible(
                engine, label: "before the first scenario turn")
            // Keep the sample in the transcript as evidence for the report.
            recorder.recordPageVisibility(visibility)
        } catch let error as SmokeError {
            throw ScenarioError.environment(String(describing: error))
        }
    }

    private func runTurns() async throws {
        guard let sessionID else {
            throw ScenarioError.environment("the harness session was not opened")
        }
        // G2-FIX-13/G2-FIX-125: `turns[]` has exactly one entry per planned
        // turn, including a turn the run never delivered. A placeholder is
        // created before the first send so an early timeout/budget exit still
        // leaves a machine-readable `delivered: false` row instead of an
        // absent turn.
        turnReports = scenario.turns.enumerated().map { index, turn in
            let turnNumber = index + 1
            return ScenarioTurnReport(
                promptLen: turn.prompt.count,
                started: scenarioTimestamp(),
                ended: nil,
                modelRequests: 0,
                toolCalls: 0,
                events: 0,
                index: index,
                delivered: false,
                requestID: "\(scenario.id.lowercased())-turn-\(turnNumber)",
                attempts: 0,
                terminalReason: nil)
        }
        for (index, turn) in scenario.turns.enumerated() {
            try checkBudget()
            guard let harness else {
                throw ScenarioError.environment("the harness was released")
            }
            let turnNumber = index + 1
            let requestsBefore = credentialProvider?.modelRequests ?? 0
            let toolCallsBefore = recorder.toolCallCount
            let eventsBefore = recorder.harnessEventCount
            let endedBefore = recorder.turnEndedCount
            // A timeout/budget error while this turn runs must still leave the
            // in-flight turn in the report; the error path records it with
            // `ended: nil` and a non-completed `terminal_reason`.
            var reportRecorded = false
            defer {
                if !reportRecorded {
                    turnReports[index].modelRequests =
                        max(0, (credentialProvider?.modelRequests ?? 0) - requestsBefore)
                    turnReports[index].toolCalls =
                        max(0, recorder.toolCallCount - toolCallsBefore)
                    turnReports[index].events =
                        max(0, recorder.harnessEventCount - eventsBefore)
                }
            }
            let startedBefore = recorder.turnStartedCount
            let applicationsBefore = perturbationApplications
            turnReports[index].started = scenarioTimestamp()
            turnReports[index].attempts = 1
            try await harness.send(
                .prompt(text: turn.prompt, attachments: [],
                        requestID: "\(scenario.id.lowercased())-turn-\(turnNumber)"),
                to: sessionID)
            turnReports[index].delivered = true
            var ended = endedBefore
            var started = startedBefore
            var retries = 0
            while true {
                let end = try await waitForTurnEnd(
                    startedBefore: started, endedBefore: ended)
                if let end {
                    // G2-FIX-91/G2-FIX-92: the report's `ended` is the
                    // `turnEnded` event's own time, and the terminal reason is
                    // the event's reason, never a runner timestamp or an
                    // assumed completion.
                    turnReports[index].ended = scenarioTimestamp(end.time)
                    turnReports[index].terminalReason = end.terminalReason
                } else {
                    turnReports[index].ended = nil
                    turnReports[index].terminalReason = nil
                }
                let terminalFailure = end.map { $0.terminalReason != "completed" } ?? false
                let perturbationInterruptedTurn =
                    perturbationApplications > applicationsBefore
                if end != nil && !(terminalFailure && perturbationInterruptedTurn) {
                    break
                }
                // A restart or kill during a turn destroys the Worker-side
                // agent; DSH may persist a cancelled turn or no terminal event
                // at all. A real user retries the request once the phone is
                // back; the runner retries once, so the scenario measures
                // recovery rather than the cancellation itself. The catalog's
                // model_requests_lte budgets bound the extra model attempt;
                // turn_count_lte counts this delivered scenario turn once,
                // while the report separately exposes DSH start events.
                guard retries < 1 else { break }
                retries += 1
                ended = recorder.turnEndedCount
                started = recorder.turnStartedCount
                turnReports[index].attempts += 1
                turnReports[index].requestID =
                    "\(scenario.id.lowercased())-turn-\(turnNumber)-retry-\(retries)"
                turnReports[index].ended = nil
                turnReports[index].terminalReason = nil
                guard let harness = self.harness else { break }
                try await harness.send(
                    .prompt(text: turn.prompt, attachments: [],
                            requestID:
                                "\(scenario.id.lowercased())-turn-\(turnNumber)-retry-\(retries)"),
                    to: sessionID)
            }
            turnReports[index].modelRequests =
                max(0, (credentialProvider?.modelRequests ?? 0) - requestsBefore)
            turnReports[index].toolCalls =
                max(0, recorder.toolCallCount - toolCallsBefore)
            turnReports[index].events =
                max(0, recorder.harnessEventCount - eventsBefore)
            reportRecorded = true
            try await applyAfterTurnPerturbations(turnNumber)
        }
    }

    /// Waits for a turn that starts after `startedBefore` to end and returns
    /// the terminal event itself (G2-FIX-91). Returns nil when no terminal
    /// event arrives within the interrupt grace after a perturbation applied
    /// during the turn (the caller then retries the request); returns nil only
    /// for that case, never for a real terminal event.
    private func waitForTurnEnd(startedBefore: Int, endedBefore: Int) async throws
        -> ScenarioTurnEndRecord? {
        var interruptedAt: Date?
        var lastEventCount = recorder.harnessEventCount
        var lastEventAt = Date()
        while true {
            try checkBudget()
            // G2-FIX-Q3: an external stop request during the turn wait ends
            // the run fail-loud instead of letting the process vanish.
            try ScenarioProcessSignals.throwIfTerminationRequested()
            if recorder.turnEndedCount > endedBefore,
               recorder.turnStartedCount > startedBefore {
                return recorder.turnEnd(after: endedBefore)
            }
            let before = perturbationApplications
            try await applyDuringFirstToolPerturbations()
            try await applyDueMinutePerturbations()
            if perturbationApplications > before {
                interruptedAt = Date()
            }
            if let interruptedAt,
               Date().timeIntervalSince(interruptedAt) >= 10 {
                return nil
            }
            // Delivery stall watchdog (G2-FIX-1, retained as the runtime
            // safety net behind the pre-turn visibility assertion). A hidden
            // WKWebView page is frozen by WebKit after a few seconds: the
            // Worker's fetch body, its channel frames and its DOM timers all
            // stop while no process exits, so the run would otherwise sit
            // silently until the wall-clock budget. The runner samples the
            // window occlusion state and the page's visibility through the
            // engine; when the page has been event-silent past the grace
            // interval and is not visible, fail with an actionable environment
            // error instead of burning the budget.
            let events = recorder.harnessEventCount
            if events != lastEventCount {
                lastEventCount = events
                lastEventAt = Date()
            }
            let idleGap = Date().timeIntervalSince(lastEventAt)
            if idleGap >= ScenarioRun.stallGraceInterval {
                let visibility: WebEnginePageVisibility?
                if let engine = engineBox.engine {
                    visibility = await engine.pageVisibility(timeout: 2)
                } else {
                    visibility = nil
                }
                guard let visibility, visibility.isVisible else {
                    let detail = visibility?.actionableFailure
                        ?? "the WKWebView page did not answer the visibility probe"
                    throw ScenarioError.environment(
                        "\(detail) No harness event arrived for \(Int(idleGap)) s. "
                        + "If the display or the user session is locked, unlock it "
                        + "before running the batch; the harness pumps AppKit events "
                        + "while it waits, so an unlocked screen stays visible.")
                }
                // A visible page may legitimately pause on the model; treat the
                // observation as a fresh grace window instead of failing.
                lastEventAt = Date()
            }
            try await harnessWait(0.05)
        }
    }

    /// How long a turn may go without a harness event before the runner checks
    /// whether the page is visible. Model pauses on a visible page are normal.
    private static let stallGraceInterval: TimeInterval = 12

    /// Applies the `during_first_tool` perturbations once, as soon as the first
    /// tool call of the run has been observed.
    private func applyDuringFirstToolPerturbations() async throws {
        guard recorder.toolCallCount > 0 else { return }
        for index in pending.indices {
            guard !pending[index].applied else { continue }
            guard case .duringFirstTool = pending[index].point else { continue }
            pending[index].applied = true
            try await applyPending(at: index)
        }
    }

    private func applyAfterTurnPerturbations(_ turn: Int) async throws {
        for index in pending.indices {
            guard !pending[index].applied else { continue }
            guard case .afterTurn(let number) = pending[index].point, number == turn else { continue }
            pending[index].applied = true
            try await applyPending(at: index)
        }
    }

    private func applyDueMinutePerturbations() async throws {
        let elapsed = Date().timeIntervalSince(startedAt)
        for index in pending.indices {
            guard !pending[index].applied else { continue }
            guard case .minute(let minute) = pending[index].point else { continue }
            guard elapsed >= TimeInterval(minute * 60) else { continue }
            pending[index].applied = true
            try await applyPending(at: index)
        }
    }

    /// The run status at finalization time. It names the failure that ended the
    /// run, if any, in the skipped-coverage details; assertion failures are
    /// decided later, so a normal end is reported as `completed`.
    private var runStatusForFinalization: String {
        if let terminalError {
            switch terminalError {
            case .timeout: return "TIMEOUT"
            case .budget: return "BUDGET"
            default: return "ERROR"
            }
        }
        if otherError != nil { return "ERROR" }
        return "completed"
    }

    /// Records the terminal state of every declared perturbation exactly once,
    /// on every exit path. Applied reports keep their result (including the
    /// `ok: null` unavailable terminal state); a declaration the run never
    /// reached becomes a skipped coverage miss. The same pure mapping decides
    /// the `restart_recovered` verdict.
    private func finalizePerturbations(runStatus: String) {
        let coverage = ScenarioPerturbationCoverage.resolve(
            declared: pending.map {
                ScenarioPerturbationCoverage.Declared(at: $0.point.raw,
                                                      kind: $0.spec.kind)
            },
            appliedReports: perturbationReports,
            runStatus: runStatus)
        perturbationReports = coverage.entries
        restartRecoveredVerdict = coverage.restartRecovered
    }

    // MARK: Perturbations

    /// Executes one pending declaration. The capability matrix already accepted
    /// the kind at load; a mechanism that still cannot run (or an impossible
    /// declaration passed directly to this object) is a runner-INFRA abort,
    /// never a product failure. A mechanism that runs but whose recovered state
    /// is wrong stays an applied `ok: false` perturbation and fails
    /// `restart_recovered`.
    private func applyPending(at index: Int) async throws {
        let item = pending[index]
        guard let capability = capabilities.capability(for: item.spec.kind) else {
            throw ScenarioError.infra(
                "no effective capability for perturbation kind \"\(item.spec.kind)\" "
                + "on \(capabilities.target.rawValue)")
        }
        perturbationApplications += 1
        do {
            let report = try await apply(perturbation: item, capability: capability)
            perturbationReports.append(report)
        } catch let error as ScenarioError {
            if case .infra = error { throw error }
            perturbationReports.append(ScenarioPerturbationReport(
                at: item.point.raw, kind: item.spec.kind,
                recoveredMs: nil, ok: false, status: "applied",
                mechanism: capability.mechanism.rawValue,
                detail: String(describing: error)))
        } catch {
            perturbationReports.append(ScenarioPerturbationReport(
                at: item.point.raw, kind: item.spec.kind,
                recoveredMs: nil, ok: false, status: "applied",
                mechanism: capability.mechanism.rawValue,
                detail: String(describing: error)))
        }
    }

    private func apply(perturbation: PendingPerturbation,
                       capability: ScenarioPerturbationCapability) async throws
        -> ScenarioPerturbationReport {
        guard let host else {
            throw ScenarioError.infra("the host is not running")
        }
        // Diagnostics materialize every acked mutation, so the materialized
        // watermark is a sound replay floor: everything at or below it is in
        // the frozen base below, and everything above it is replayed from the
        // WAL after recovery. The floor is the materialized watermark, not the
        // acked one, because a mutation acked just before the snapshot may
        // still have been in flight to the materialized copy.
        let beforeDiagnostics = await host.diagnostics()
        let beforeAcked = beforeDiagnostics.ackedMseq
        let beforeMaterialized = beforeDiagnostics.materializedUptoMseq
        let recoveryBase: ScenarioRecoveryBase
        do {
            recoveryBase = try ScenarioRecovery.captureBase(hostRoot: hostRoot)
        } catch {
            throw ScenarioError.infra(
                "cannot freeze the pre-perturbation materialized workspace: \(error)")
        }
        defer { recoveryBase.discard() }
        let before = MaterializedSnapshot.read(workspaceRoot: recoveryBase.root)
        let beforeHello = beforeDiagnostics.workerHelloCount
        let actionStart = Date()
        let actionLock = try? ScenarioBootLock(path: ScenarioBootLock.sharedPath)
        defer { actionLock?.release() }
        let webContentBaseline = ScenarioWebContent.allPids()
        var killedPids: [pid_t] = []

        switch perturbation.spec.kind {
        case "planned_restart":
            try await host.plannedRestart(reason: "scenario \(scenario.id) \(perturbation.point.raw)")
        case "park_resume":
            try await host.park()
            try await host.resume()
        case "worker_kill":
            try await terminatePageWorker()
            // The page's Worker execution context is gone; the page itself
            // cannot restart it, so the host's standard restart path rebuilds
            // the page and waits for the new HELLO.
            try await host.plannedRestart(reason: "scenario worker kill \(scenario.id)")
        case "webcontent_kill":
            #if os(macOS)
            killedPids = [try killWebContentProcess()]
            #else
            killedPids = try await ScenarioSimulatorWebContentWatcher.killAndWait(
                scenarioID: scenario.id,
                resultsRoot: resultsDirectory.deletingLastPathComponent())
            #endif
        default:
            throw ScenarioError.infra(
                "no perturbation executor for kind \"\(perturbation.spec.kind)\" "
                + "on \(capabilities.target.rawValue)")
        }

        try await scenarioWait(timeout: 240, label: "\(perturbation.spec.kind) recovery",
                               deadline: wallDeadline) {
            let diagnostics = await host.diagnostics()
            return diagnostics.state == .running
                && diagnostics.admission == .open
                && diagnostics.workerHelloCount > beforeHello
        }

        // Track the WebContent process that now serves this view: a killed
        // process is replaced, and a park/resume builds a new engine.
        let appeared = ScenarioWebContent.allPids().subtracting(webContentBaseline)
        if let refreshed = ScenarioWebContent.newestPid(among: appeared) ?? appeared.first {
            webContentPid = refreshed
        } else if let remembered = webContentPid,
                  !ScenarioWebContent.isAliveWebContent(remembered) {
            webContentPid = ScenarioWebContent.current()?.pid
        }
        actionLock?.release()

        // A restart replaces the page and its Worker; the harness/transport that
        // observed the old process may stay silent even though `send` works.
        // Rebind to the recovered host (a fresh DSHRemoteHarness) and resume the
        // event stream after everything already recorded.
        try await rebindHarness()

        let verdict = await checkRecovery(base: recoveryBase,
                                          before: before,
                                          beforeAcked: beforeAcked,
                                          beforeMaterialized: beforeMaterialized)
        let recoveredMs = Int((Date().timeIntervalSince(actionStart) * 1000).rounded())
        return ScenarioPerturbationReport(
            at: perturbation.point.raw,
            kind: perturbation.spec.kind,
            recoveredMs: recoveredMs,
            ok: verdict.ok,
            status: "applied",
            mechanism: capability.mechanism.rawValue,
            killedPids: killedPids.isEmpty ? nil : killedPids.map { Int($0) },
            accountedChanges: verdict.accounted,
            detail: verdict.detail)
    }

    /// Reads the recovered workspace and verifies it by WAL replay. A healthy
    /// host settles on the first attempt; the retries absorb a mutation that
    /// materializes between the watermark read and the snapshot read, and the
    /// materializer's atomic-write scratch file.
    private func checkRecovery(base: ScenarioRecoveryBase,
                               before: MaterializedSnapshot,
                               beforeAcked: UInt64,
                               beforeMaterialized: UInt64) async -> ScenarioRecoveryVerdict {
        var last = ScenarioRecoveryVerdict.failure("the recovery check did not run")
        for attempt in 0..<ScenarioRecovery.maximumCheckAttempts {
            guard let host else {
                return .failure("the host was released during the recovery check")
            }
            // Diagnostics first: it materializes the acked tail, so the
            // snapshot read immediately after is a consistent cut at the
            // reported watermarks unless a new mutation lands in between (the
            // retry below re-reads both).
            let diagnostics = await host.diagnostics()
            let snapshot = MaterializedSnapshot.read(workspaceRoot: hostRoot)
            let verdict = ScenarioRecovery.verify(
                hostRoot: hostRoot,
                base: base,
                before: before,
                beforeAcked: beforeAcked,
                beforeMaterialized: beforeMaterialized,
                afterAcked: diagnostics.ackedMseq,
                afterMaterialized: diagnostics.materializedUptoMseq,
                after: snapshot)
            last = verdict
            if verdict.ok { break }
            if attempt + 1 < ScenarioRecovery.maximumCheckAttempts {
                try? await Task.sleep(
                    nanoseconds: UInt64(ScenarioRecovery.checkRetryInterval * 1_000_000_000))
            }
        }
        return last
    }

    /// Recreates the harness object and its event pump after a recovery.
    private func rebindHarness() async throws {
        guard let host, let sessionID else {
            throw ScenarioError.perturbation("the harness session was not opened")
        }
        let fresh = try await host.harness()
        self.harness = fresh
        harnessPump?.cancel()
        harnessPump = recorder.attach(harness: fresh, sessionID: sessionID,
                                      after: recorder.lastDurableSeq)
    }

    private static let workerWrapperScript = """
    (function () {
      if (globalThis.__xlScenarioWorkers) return;
      var NativeWorker = globalThis.Worker;
      var workers = [];
      globalThis.__xlScenarioWorkers = workers;
      function ScenarioWorker(url, options) {
        var worker = new NativeWorker(url, options);
        workers.push(worker);
        return worker;
      }
      ScenarioWorker.prototype = NativeWorker.prototype;
      globalThis.Worker = ScenarioWorker;
    })();
    """

    private static let terminateWorkersScript = """
    (function () {
      var workers = globalThis.__xlScenarioWorkers || [];
      var count = workers.length;
      for (var i = 0; i < workers.length; i += 1) {
        try { workers[i].terminate(); } catch (error) {}
      }
      globalThis.__xlScenarioWorkers = [];
      return count;
    })();
    """

    /// Terminates the page's real Worker execution context. The page's
    /// `Worker` handles were captured by the document-start user script.
    private func terminatePageWorker() async throws {
        guard let engine = engineBox.engine else {
            throw ScenarioError.perturbation("the WKWebView engine is not available")
        }
        let value: Any?
        do {
            value = try await engine.view.evaluateJavaScript(
                Self.terminateWorkersScript)
        } catch {
            throw ScenarioError.perturbation("cannot evaluate the Worker kill script: \(error)")
        }
        let terminated = (value as? NSNumber)?.intValue ?? 0
        guard terminated > 0 else {
            throw ScenarioError.perturbation("no page Worker was captured for termination")
        }
    }

    /// SIGKILLs the WebContent process that currently serves this WKWebView and
    /// returns its pid as the report evidence.
    ///
    /// The process is selected by the evidence in ``ScenarioWebContent``: only a
    /// macOS WebContent process holding a TCP connection to this test
    /// process's own loopback listener is eligible. A process from another
    /// simulator or another lane is never matched.
    private func killWebContentProcess() throws -> pid_t {
        let pid: pid_t
        if let current = ScenarioWebContent.current() {
            pid = current.pid
        } else if let remembered = webContentPid,
                  ScenarioWebContent.isAliveWebContent(remembered) {
            pid = remembered
        } else {
            throw ScenarioError.infra(
                "no WebContent process is connected to this run's loopback origin")
        }
        try ScenarioWebContent.terminate(pid)
        webContentPid = pid
        return pid
    }

    // MARK: Budget

    private func checkBudget() throws {
        if Date() >= wallDeadline {
            // G2-FIX-76: a wall-budget cancel is a timeout cause, not an
            // anonymous user cancel; DSH journals it as such.
            let detail = "budget.max_minutes=\(scenario.budget.maxMinutes) elapsed"
            Task { [harness, sessionID] in
                if let harness, let sessionID {
                    try? await harness.send(.cancelWithCause(.timeout(detail)),
                                            to: sessionID)
                }
            }
            throw ScenarioError.timeout(detail)
        }
        let requests = credentialProvider?.modelRequests ?? 0
        if requests > scenario.budget.maxModelRequests {
            let detail =
                "budget.max_model_requests=\(scenario.budget.maxModelRequests) exceeded"
            Task { [harness, sessionID] in
                if let harness, let sessionID {
                    try? await harness.send(.cancelWithCause(.budget(detail)),
                                            to: sessionID)
                }
            }
            throw ScenarioError.budget(detail)
        }
    }

    /// Runs a host operation with the scenario's wall budget applied.
    private func withBudget<T>(timeout: TimeInterval, label: String,
                               _ operation: () async throws -> T) async throws -> T {
        try checkBudget()
        let result = try await operation()
        try checkBudget()
        return result
    }

    // MARK: Assertions

    private func evaluateAssertions() throws {
        // The run-completion fact is computed once, before any assertion is
        // evaluated, and gates the progress-dependent assertion class. An
        // incomplete run reports those assertions `NOT_EXECUTED` instead of
        // evaluating them against fixture-or-partial state (G2-FIX-15).
        let completion = runCompletion
        // One redaction of the Worker/session console-error stream, used both
        // by `no_console_error` and by the report's `console_errors` field. The
        // assertion can never evaluate one array while the report prints
        // another.
        let consoleErrors = ScenarioReportDiagnostics.channel(recorder.consoleErrors,
                                                              redactor: redactor)
        evaluatedConsoleErrors = consoleErrors
        let deliveredTurns = turnReports.filter { $0.delivered }
        let completedTurns = deliveredTurns.filter { $0.ended != nil }.count
        let evaluator = ScenarioAssertionEvaluator(
            workspace: hostRoot.appendingPathComponent("materialized/workspace",
                                                       isDirectory: true),
            resultsDirectory: resultsDirectory,
            turnStartedCount: recorder.turnStartedCount,
            deliveredTurnCount: deliveredTurns.count,
            modelRequests: credentialProvider?.modelRequests ?? 0,
            consoleErrors: consoleErrors,
            restartRecovered: restartRecoveredVerdict,
            redactor: redactor)
        assertionReports.append(contentsOf: evaluator.reports(
            for: scenario.assertions,
            completion: completion,
            overrides: workerCommandReports))
        // G2-FIX-94: an incomplete run keeps static workspace evidence without
        // promoting it to an assertion verdict. The gate above already wrote
        // the progress-dependent assertions as NOT_EXECUTED.
        if !completion.isComplete, !deliveredTurns.isEmpty {
            partialEvidence = evaluator.partialEvidence(
                for: scenario.assertions,
                completion: completion,
                completedTurns: completedTurns,
                fixtureBaseline: fixtureBaseline,
                currentWorkspace: MaterializedSnapshot.read(workspaceRoot: hostRoot))
        }
        // Mock runs have an exact expected delivery count: every distinct
        // scripted 200 response must be consumed by the Worker's model client.
        // A response that stalls on the gateway → loopback → WebKit →
        // model-client path reaches the response log but never produces an
        // assistant message or a usage event, so the counts diverge. A
        // transport retry (the host gateway re-sends the identical request
        // after a cancelled connection, or the Worker re-issues it after a
        // reconnect) is the *same* logical request: its superseded response is
        // not a second delivery, so the count is by request body, not by
        // socket attempt. This is a run-level invariant for every
        // `--upstream mock` scenario, not a per-scenario branch.
        if let mock, !environment.isRealUpstream {
            let streamed = mock.distinctCompleteResponseCount
            let attempts = mock.responseBodies.count
            let stalled = mock.stalledBodies.count
            let consumed = recorder.usageEventCount
            let stalledNote = stalled == 0 ? ""
                : ", \(stalled) scripted stall(s), \(mock.stalledBytes) byte(s) delivered before the stall"
            let retryNote = attempts == streamed ? ""
                : " (\(attempts) transport attempt(s), \(attempts - streamed) retried)"
            let deliveryOK = streamed > 0 && consumed >= streamed
            assertionReports.append(ScenarioAssertionReport(
                type: "mock_delivery",
                ok: deliveryOK,
                detail: "\(consumed) usage event(s) for \(streamed) complete streamed response(s)"
                    + retryNote + stalledNote,
                failure: deliveryOK ? nil : ScenarioAssertionFailure(
                    kind: .countExceeded,
                    expected: "one usage event per complete streamed response",
                    actual: "\(consumed) usage event(s) for \(streamed) response(s)")))
        }
    }

    /// Evaluates every `worker_command` against the live Worker.
    ///
    /// The check runs only for a completed run; an incomplete run is gated to
    /// `NOT_EXECUTED` by the shared assertion gate. One transport is captured
    /// for the whole phase, so every receipt belongs to the same Worker
    /// connection. A route/transport failure becomes a failed assertion with a
    /// `missing_receipt` kind, never a host fallback.
    private func evaluateWorkerCommands() async throws {
        let indices = scenario.assertions.indices.filter {
            scenario.assertions[$0].type == "worker_command"
        }
        guard !indices.isEmpty else { return }
        guard let host, let sessionID else {
            // No Worker was ever opened (a deferred/SKIP path does not reach
            // here); the evaluator will report the missing receipt.
            return
        }
        let completion = runCompletion
        guard completion.isComplete else { return }
        let transport: any DSHRemoteTransport
        do {
            transport = try await host.makeTransport()
        } catch {
            for index in indices {
                let assertion = scenario.assertions[index]
                workerCommandReports[index] = ScenarioAssertionReport(
                    type: assertion.type,
                    ok: false,
                    detail: redactor.redact("worker_command has no captured Worker receipt: "
                        + String(describing: error)),
                    command: assertion.command.map(redactor.redact),
                    failure: ScenarioAssertionFailure(
                        kind: .missingReceipt,
                        expected: "the live Worker command route",
                        actual: String(describing: error)))
            }
            return
        }
        let deliveredTurns = turnReports.filter { $0.delivered }.count
        let watermark = recorder.turnEndedCount
        for index in indices {
            workerCommandReports[index] = await ScenarioWorkerCommand.evaluate(
                assertion: scenario.assertions[index],
                index: index,
                scenarioID: scenario.id,
                sessionID: sessionID,
                turn: deliveredTurns,
                completionWatermark: watermark,
                transport: transport,
                redactor: redactor)
        }
    }

    /// The run-completion fact the report path records and the assertion gate
    /// reads: every scenario turn delivered, every delivered turn reported with
    /// a terminal `ended`, and no timeout/budget/error exit.
    private var runCompletion: ScenarioRunCompletion {
        if let runnerInfra {
            return .incomplete(reason: runnerInfra.detail)
        }
        let terminalStatus = runStatusForFinalization == "completed"
            ? nil : runStatusForFinalization
        return ScenarioRunCompletion.evaluate(
            plannedTurns: scenario.turns.count,
            turnReports: turnReports,
            terminalStatus: terminalStatus)
    }

    // MARK: Artifacts

    private func writeTranscript() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let body = try ScenarioTranscript.encode(records: recorder.records,
                                                 encoder: encoder,
                                                 redactor: redactor)
        try scenarioWrite(body, to: resultsDirectory.appendingPathComponent("transcript.jsonl"))
    }

    private func writeWorkspaceArchive() throws {
        let workspace = hostRoot.appendingPathComponent("materialized/workspace", isDirectory: true)
        guard FileManager.default.fileExists(atPath: workspace.path) else {
            throw ScenarioError.artifact("the materialized workspace does not exist; no workspace.tar")
        }
        let archive = resultsDirectory.appendingPathComponent("workspace.tar")
        if FileManager.default.fileExists(atPath: archive.path) {
            try FileManager.default.removeItem(at: archive)
        }
        // G2-FIX-5: one writer on every platform. The macOS external bsdtar
        // can emit AppleDouble `._` members depending on its environment; the
        // library's ustar writer has no such mode and keeps `.git` entries as
        // ordinary files.
        do {
            try ScenarioTar.archive(directory: workspace, to: archive)
        } catch {
            throw ScenarioError.artifact(
                "cannot archive the materialized workspace: \(error)")
        }
    }

    private func writeModelBodies() throws {
        guard environment.keepBodies else { return }
        let bodies = resultsDirectory.appendingPathComponent("bodies", isDirectory: true)
        try FileManager.default.createDirectory(at: bodies, withIntermediateDirectories: true)
        if let mock {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            for (index, request) in mock.requests.enumerated() {
                let payload: [String: Any] = [
                    "index": index + 1,
                    "method": request.method,
                    "path": request.path,
                    "headers": redactor.redact(headers: request.headers),
                    "body": redactor.redact(String(decoding: request.body, as: UTF8.self)),
                ]
                let data = try JSONSerialization.data(withJSONObject: payload,
                                                      options: [.sortedKeys, .prettyPrinted])
                try scenarioWrite(data, to: bodies.appendingPathComponent(
                    String(format: "request-%04d.json", index + 1)))
            }
            for (index, body) in mock.responseBodies.enumerated() {
                let text = redactor.redact(String(decoding: body, as: UTF8.self))
                try scenarioWrite(Data(text.utf8), to: bodies.appendingPathComponent(
                    String(format: "response-%04d.txt", index + 1)))
            }
            // Intentional stalls keep their intended bodies; the run report
            // carries the same complete-vs-stalled distinction.
            for (index, body) in mock.stalledBodies.enumerated() {
                let text = redactor.redact(String(decoding: body, as: UTF8.self))
                try scenarioWrite(Data(text.utf8), to: bodies.appendingPathComponent(
                    String(format: "response-stalled-%04d.txt", index + 1)))
            }
            return
        }
        // Real runs: request bodies are not observable at the host App layer;
        // the gateway's bounded response log is.
        let log = hostRoot.appendingPathComponent("response-log", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: log, includingPropertiesForKeys: [.isRegularFileKey], options: []) else {
            return
        }
        var count = 0
        for case let url as URL in enumerator where url.lastPathComponent == "body" {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            count += 1
            let text = redactor.redact(String(decoding: (try? Data(contentsOf: url)) ?? Data(),
                                              as: UTF8.self))
            let key = url.deletingLastPathComponent().lastPathComponent
            try scenarioWrite(Data(text.utf8), to: bodies.appendingPathComponent(
                "response-log-\(key).txt"))
        }
        let note = "request bodies are not exposed by the host gateway; "
            + "\(count) response body file(s) come from the bounded response log\n"
        try scenarioWrite(Data(note.utf8), to: bodies.appendingPathComponent("README.txt"))
    }

    // MARK: Report

    private func buildReport() -> ScenarioReport {
        let diagnostics = ScenarioReportDiagnostics(
            consoleErrors: evaluatedConsoleErrors
                ?? ScenarioReportDiagnostics.channel(recorder.consoleErrors,
                                                     redactor: redactor),
            runnerDiagnostics: ScenarioReportDiagnostics.runnerDiagnostics(
                deferred: deferredReason,
                runnerInfra: runnerInfra?.detail,
                terminalError: terminalError.map { String(describing: $0) },
                otherError: otherError),
            redactor: redactor)
        var states = recorder.hostStates
        if states.count > 500 { states = Array(states.suffix(500)) }
        let bytes = upstreamBytes()
        // A deferred `workspace_command` is not a verdict. It is excluded from
        // the settled-failure test, and when it is the only open item the whole
        // report is provisional (`PENDING_HOST`) until the host phase fills it
        // in. A settled failure still wins immediately, so a known bad run is
        // never hidden behind the pending marker. `NOT_EXECUTED` assertions
        // (G2-FIX-15) are settled non-passes: they can never be counted green.
        let summary = ScenarioAssertionSummary.summarize(assertionReports)
        let hasPendingHost = summary.pendingHost > 0
        let hasSettledFailure = summary.failed > 0 || summary.notExecuted > 0
        let status: String
        if runnerInfra != nil {
            // G2-FIX-65: the scenario was aborted before the product ran. Its
            // own status keeps the capability gap out of the PASS/FAIL verdict.
            status = "INFRA"
        } else if deferredReason != nil {
            status = "SKIP"
        } else if let terminalError {
            switch terminalError {
            case .timeout: status = "TIMEOUT"
            case .budget: status = "BUDGET"
            default: status = "ERROR"
            }
        } else if otherError != nil {
            status = "ERROR"
        } else if hasSettledFailure {
            status = "FAIL"
        } else if hasPendingHost {
            status = ScenarioAssertionStatus.pendingHostReport
        } else {
            status = "PASS"
        }
        let completion = runCompletion
        return ScenarioReport(
            id: scenario.id,
            status: status,
            assertions: assertionReports,
            turns: turnReports,
            perturbations: perturbationReportsForReport(),
            usage: ScenarioUsageReport(
                modelRequests: credentialProvider?.modelRequests ?? 0,
                upstreamBytesIn: bytes.bytesIn,
                upstreamBytesOut: bytes.bytesOut,
                wallS: runWallSeconds,
                runWallS: runWallSeconds,
                sessionWallS: sessionStartedAt.map {
                    ((sessionEndedAt ?? Date()).timeIntervalSince($0) * 1000).rounded() / 1000
                },
                bytesSource: bytes.source.rawValue),
            pageVisibility: recorder.lastPageVisibility.map {
                ScenarioPageVisibilityReport(
                    attachedWithVisibleArea: $0.attachedWithVisibleArea,
                    windowOcclusionVisible: $0.windowOcclusionVisible,
                    documentVisibilityState: $0.documentVisibilityState,
                    isVisible: $0.isVisible)
            },
            deferred: deferredReason,
            runnerInfra: runnerInfra?.detail,
            webContentTerminations: recorder.webContentTerminations,
            hostEvaluated: assertionReports.contains { $0.hostEvaluated == true }
                ? true : nil,
            workerEvaluated: assertionReports.contains { $0.workerEvaluated == true }
                ? true : nil,
            consoleErrors: diagnostics.consoleErrors,
            runnerErrors: diagnostics.runnerErrors,
            hostStates: states,
            runCompleted: completion.isComplete,
            runIncompleteReason: completion.reason,
            budgets: budgetProvenance,
            partialEvidence: partialEvidence.isEmpty ? nil : partialEvidence)
    }

    /// Adds the declared perturbations that never ran to an INFRA report.
    ///
    /// An INFRA abort reaches `buildReport` either at load (nothing ran) or
    /// after a mechanism failed mid-run (previously applied entries are kept).
    /// Every declaration must still be visible, with the runner-infra status,
    /// so a reader sees the whole coverage gap instead of an empty list.
    private func perturbationReportsForReport() -> [ScenarioPerturbationReport] {
        guard let runnerInfra else { return perturbationReports }
        var reports = perturbationReports
        let reported = Set(perturbationReports.map {
            "\($0.at)\u{1F}\($0.kind)"
        })
        for spec in scenario.perturbations ?? [] {
            let key = "\(spec.at)\u{1F}\(spec.kind)"
            guard !reported.contains(key) else { continue }
            let reason = runnerInfra.perturbations.first {
                $0.at == spec.at && $0.kind == spec.kind
            }?.reason ?? runnerInfra.reason
            reports.append(ScenarioPerturbationReport(
                at: spec.at,
                kind: spec.kind,
                recoveredMs: nil,
                ok: nil,
                status: "runner_infra",
                detail: "runner-infra: \(reason); execution target "
                    + "\(runnerInfra.target.rawValue); scenario \(runnerInfra.scenarioID)"))
        }
        return reports
    }

    private func upstreamBytes() -> ScenarioUsageBytes {
        if let mock, !environment.isRealUpstream {
            // Both directions come from the mock that saw the bytes; the
            // request body is the Worker's outbound model request and the
            // response body is the upstream's reply.
            return ScenarioUsageMetrics.mock(requestBytes: mock.requestBytes,
                                             responseBytes: mock.responseBytes)
        }
        let log = hostRoot.appendingPathComponent("response-log", isDirectory: true)
        return ScenarioUsageMetrics.real(
            gatewayMetrics: gatewayMetrics,
            responseLogBytes: ScenarioUsageMetrics.responseLogBytes(in: log))
    }

    private func writeReport(_ report: ScenarioReport) throws {
        try ScenarioReportArtifact.write(
            report, to: resultsDirectory.appendingPathComponent("report.json"))
    }

    // MARK: Teardown

    /// Merges a failed `host.stop()` into the terminal state. An earlier
    /// terminal cause is kept; the stop detail is appended so the report is
    /// never PASS while still naming the first failure.
    private func recordStopFailure(_ error: Error) {
        let merged = ScenarioStopFailure.merge(error: error,
                                               terminalError: terminalError,
                                               otherError: otherError)
        terminalError = merged.terminalError
        otherError = merged.otherError
    }

    private func teardown() async {
        if let host {
            // `stop()` is normally already done; this only releases a host that
            // failed before the stop call. Its error is recorded like the
            // regular stop path: teardown must not hide a new seal failure.
            do {
                try await host.stop()
            } catch {
                recordStopFailure(error)
            }
        }
        engineBox.engine?.shutdown()
        visibleWindow?.close()
        visibleWindow = nil
        mock?.stop()
        // A WKWebView releases its WebContent lazily and WebKit may reuse the
        // process for the next scenario in this test process. Terminating the
        // run's own process (tracked at boot/restart) keeps every scenario's
        // baseline unambiguous. It never targets a process by name: only the
        // pid selected while this lane held the boot lock is killed.
        if let pid = webContentPid, ScenarioWebContent.isAliveWebContent(pid) {
            _ = kill(pid, SIGKILL)
        }
        webContentPid = nil
    }

    private var runWallSeconds: Double {
        (Date().timeIntervalSince(startedAt) * 1000).rounded() / 1000
    }
}

/// Produces valid JSONL rows without truncating serialized JSON. Tool-result
/// audit text is already bounded with an explicit durable-log pointer by the
/// harness event mapper; large tool-call arguments remain intact here.
enum ScenarioTranscript {
    static func encode(records: [ScenarioHarnessRecord],
                       encoder: JSONEncoder = JSONEncoder(),
                       redactor: ScenarioRedactor = ScenarioRedactor()) throws -> Data {
        var body = Data()
        for record in records {
            let data = try encoder.encode(record.event)
            let line = redactor.redact(String(decoding: data, as: UTF8.self))
            body.append(Data((line + "\n").utf8))
        }
        return body
    }
}

enum ScenarioReportArtifact {
    static func write(_ report: ScenarioReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try scenarioWrite(encoder.encode(report), to: url)
    }
}
