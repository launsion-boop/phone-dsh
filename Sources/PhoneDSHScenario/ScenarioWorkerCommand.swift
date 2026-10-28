// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2-FIX-35: the independent Worker command assertion.
//
// `workspace_command` is evaluated after `host.stop()` against a materialized
// copy. `worker_command` is different: it runs while the live Worker is still
// up, through the ordered-channel transport, on an immutable fork of the
// Worker VFS. Its receipt is the evidence that the command did not run in the
// Mac's `/bin/bash` and did not touch the Agent's live workspace or journal.
//
// The evaluator stays a pure consumer of the receipt. It never substitutes a
// host run and never fabricates an exit status: a missing or mismatched
// receipt is a failed assertion.

import Foundation
import PhoneDSH
import PhoneDSHAgentCore

/// One evaluated `worker_command` assertion plus the receipt that produced it.
enum ScenarioWorkerCommand {
    /// Request one command receipt from the live Worker and turn it into an
    /// assertion report.
    ///
    /// - Parameters:
    ///   - assertion: the catalog assertion (`command`, optional program/cwd/budget).
    ///   - index: 0-based catalog index, bound into the receipt.
    ///   - scenarioID/sessionID/turn: the scenario binding.
    ///   - completionWatermark: delivered turn-end count at evaluation time.
    ///   - transport: the host's captured Worker transport.
    ///   - redactor: the run redactor for every string on the report.
    static func evaluate(assertion: Scenario.Assertion,
                         index: Int,
                         scenarioID: String,
                         sessionID: String,
                         turn: Int,
                         completionWatermark: Int,
                         transport: any DSHRemoteTransport,
                         redactor: ScenarioRedactor) async -> ScenarioAssertionReport {
        guard let command = assertion.command, !command.isEmpty else {
            return report(assertion, ok: false, detail: "worker_command has no command",
                          failure: ScenarioAssertionFailure(
                            kind: .error, expected: "a command", actual: "missing"),
                          redactor: redactor)
        }
        guard let calling = transport as? any PhoneDSHWorkerCommandCalling else {
            return report(assertion, ok: false,
                          detail: "worker_command has no Worker command channel; "
                            + "the transport cannot deliver a pdsh-worker-command/1 request",
                          failure: ScenarioAssertionFailure(
                            kind: .missingReceipt,
                            expected: "the ordered-channel Worker command route",
                            actual: "the transport does not implement PhoneDSHWorkerCommandCalling"),
                          redactor: redactor)
        }
        let request = PhoneDSHWorkerCommandRequest(
            command: command,
            program: assertion.program ?? "bash",
            cwd: assertion.cwd ?? "/dsh/workspace",
            timeoutMilliseconds: assertion.timeoutMilliseconds
                ?? PhoneDSHWorkerCommandProtocol.defaultBudgetMilliseconds,
            scenarioID: scenarioID,
            sessionID: sessionID,
            turn: turn,
            assertionIndex: index,
            completionWatermark: completionWatermark)
        let receipt: PhoneDSHWorkerCommandReceipt
        do {
            receipt = try await calling.executeWorkerCommand(request)
        } catch {
            return report(assertion, ok: false,
                          detail: "worker_command has no captured Worker receipt: "
                            + String(describing: error),
                          failure: ScenarioAssertionFailure(
                            kind: .missingReceipt,
                            expected: "a pdsh-worker-command/1 receipt from the live Worker",
                            actual: String(describing: error)),
                          redactor: redactor)
        }
        return inspect(assertion, request: request, receipt: receipt, redactor: redactor)
    }

    /// Validate the receipt against the request and build the report.
    private static func inspect(_ assertion: Scenario.Assertion,
                                request: PhoneDSHWorkerCommandRequest,
                                receipt: PhoneDSHWorkerCommandReceipt,
                                redactor: ScenarioRedactor) -> ScenarioAssertionReport {
        func mismatch(_ fact: String) -> ScenarioAssertionReport {
            return report(assertion, ok: false,
                          detail: "worker_command receipt mismatch: \(fact)\n\(receiptDetail(receipt))",
                          workerEvaluated: true,
                          workerReceipt: receipt.raw,
                          durationMs: receipt.durationMilliseconds,
                          request: request,
                          failure: ScenarioAssertionFailure(
                            kind: .workerReceiptMismatch,
                            expected: "a receipt bound to this scenario/session/turn/assertion",
                            actual: fact),
                          redactor: redactor)
        }
        guard receipt.isWorkerVFS else {
            return mismatch("location is not a Worker VFS fork "
                + "(kind=\(receipt.locationKind ?? "missing"), "
                + "host_process=\(receipt.locationHostProcess.map { String(describing: $0) } ?? "missing"))")
        }
        guard receipt.carrier == "ordered-channel" else {
            return mismatch("carrier is \(receipt.carrier ?? "missing"), not the ordered channel")
        }
        guard receipt.bindingScenarioID == request.scenarioID else {
            return mismatch("scenario_id \(receipt.bindingScenarioID ?? "missing") != \(request.scenarioID)")
        }
        guard receipt.bindingSessionID == request.sessionID else {
            return mismatch("session_id \(receipt.bindingSessionID ?? "missing") != \(request.sessionID)")
        }
        guard receipt.bindingTurn == request.turn else {
            return mismatch("turn \(receipt.bindingTurn.map(String.init) ?? "missing") != \(request.turn)")
        }
        guard receipt.bindingAssertionIndex == request.assertionIndex else {
            return mismatch("assertion_index \(receipt.bindingAssertionIndex.map(String.init) ?? "missing") "
                + "!= \(request.assertionIndex)")
        }
        if let expected = request.completionWatermark,
           receipt.bindingCompletionWatermark != expected {
            return mismatch("completion_watermark "
                + "\(receipt.bindingCompletionWatermark.map(String.init) ?? "missing") != \(expected)")
        }
        guard receipt.modelRequests == 0 else {
            return mismatch("model_requests \(receipt.modelRequests.map(String.init) ?? "missing") != 0")
        }
        guard receipt.liveWorkspaceUnchanged == true else {
            return mismatch("live_workspace_unchanged=\(receipt.liveWorkspaceUnchanged.map { String(describing: $0) } ?? "missing")")
        }
        guard receipt.sourceFrozen == true else {
            return mismatch("source is not frozen at one Worker VFS watermark "
                + "(source_frozen=\(receipt.sourceFrozen.map { String(describing: $0) } ?? "missing"))")
        }
        guard let missingRoots = receipt.sourceMissingRoots else {
            return mismatch("source.missing_roots is missing or not a string array")
        }
        guard missingRoots.isEmpty else {
            return mismatch("source.missing_roots is not empty "
                + "(\(missingRoots.joined(separator: ", ")))")
        }
        guard receipt.isImmutableFork else {
            return mismatch("source is not an immutable Worker VFS fork")
        }
        guard let sourceStart = receipt.sourceMseqStart,
              let sourceEnd = receipt.sourceMseqEnd,
              sourceStart >= 0,
              sourceEnd == sourceStart else {
            return mismatch("source mseq is not one frozen watermark "
                + "(start=\(receipt.sourceMseqStart.map(String.init) ?? "missing"), "
                + "end=\(receipt.sourceMseqEnd.map(String.init) ?? "missing"))")
        }
        guard receipt.sideEffectsIsolated == true else {
            return mismatch("side_effects.isolated is not true")
        }
        guard receipt.sideEffectsLiveWorkspace == false else {
            return mismatch("side_effects.live_workspace is not false "
                + "(\(receipt.sideEffectsLiveWorkspace.map { String(describing: $0) } ?? "missing"))")
        }
        guard receipt.sideEffectsJournal == false else {
            return mismatch("side_effects.journal is not false "
                + "(\(receipt.sideEffectsJournal.map { String(describing: $0) } ?? "missing"))")
        }
        let ok = receipt.succeeded
        let failure: ScenarioAssertionFailure? = ok ? nil : ScenarioAssertionFailure(
            kind: .commandFailed,
            path: assertion.path,
            expected: "the Worker command exits 0",
            actual: "exit \(receipt.exitCode.map(String.init) ?? "missing")"
                + (receipt.timedOut ? " (timed out at \(receipt.budgetMilliseconds.map(String.init) ?? "?") ms)" : "")
                + (receipt.cancelled ? " (cancelled)" : ""))
        return report(assertion, ok: ok,
                      detail: receiptDetail(receipt),
                      workerEvaluated: true,
                      workerReceipt: receipt.raw,
                      durationMs: receipt.durationMilliseconds,
                      request: request,
                      failure: failure,
                      redactor: redactor)
    }

    /// One stable, human-readable evidence line plus the raw bounded streams.
    ///
    /// Every environment/live claim is derived from the receipt's machine
    /// fields, never assumed. A capture failure or an unfrozen snapshot must
    /// not read as `immutable fork`, and `live workspace unchanged` is printed
    /// only when the receipt's live-workspace proof actually passed.
    private static func receiptDetail(_ receipt: PhoneDSHWorkerCommandReceipt) -> String {
        var lines: [String] = []
        var verdict = "\(receipt.program ?? "worker") exit \(receipt.exitCode.map(String.init) ?? "?")"
        if receipt.timedOut { verdict += " (timed out)" }
        if receipt.cancelled { verdict += " (cancelled)" }
        lines.append(verdict)

        let missingRootsValue = receipt.sourceMissingRoots
        let missingRoots = missingRootsValue ?? []
        let immutableFork = receipt.isImmutableFork
            && receipt.sourceFrozen == true
            && missingRootsValue != nil
            && missingRoots.isEmpty
        let forkUsed = receipt.locationKind == "worker"
            && receipt.locationWorkerVFS == true
            && receipt.locationFork == "memory-vfs"
            && receipt.sourceFork == true
        let environment: String
        if immutableFork {
            environment = "worker VFS: used (immutable fork)"
        } else if !forkUsed || !missingRoots.isEmpty {
            environment = "worker VFS: snapshot failed (not used)"
        } else if receipt.sourceFrozen != true {
            environment = "worker VFS: used (source not frozen; not immutable)"
        } else {
            environment = "worker VFS: used (incomplete evidence; not immutable)"
        }
        lines.append("[environment: worker-command; \(environment); host process: "
            + (receipt.locationHostProcess == true ? "used" : "not used") + "]")
        lines.append("receipt \(receipt.receiptID ?? "missing")"
            + "; scenario \(receipt.bindingScenarioID ?? "?")"
            + "; session \(receipt.bindingSessionID ?? "?")"
            + "; turn \(receipt.bindingTurn.map(String.init) ?? "?")"
            + "; assertion \(receipt.bindingAssertionIndex.map(String.init) ?? "?")"
            + "; watermark \(receipt.bindingCompletionWatermark.map(String.init) ?? "none")")
        lines.append("source mseq \(receipt.sourceMseqStart.map(String.init) ?? "?")"
            + "..\(receipt.sourceMseqEnd.map(String.init) ?? "?")"
            + " frozen \(receipt.sourceFrozen.map { String(describing: $0) } ?? "?")"
            + "; fork \(receipt.sourceEntries.map(String.init) ?? "?") entr"
            + (receipt.sourceEntries == 1 ? "y" : "ies") + ", "
            + "\(receipt.sourceBytes.map(String.init) ?? "?") B"
            + "; digest \(receipt.sourceDigest ?? "missing")")
        if let failure = receipt.sourceFailure {
            lines.append("source failure: \(failure)"
                + Self.failureDetail(receipt.sourceFailureDetail))
        }
        if receipt.sourceTimedOut == true {
            lines.append("source timed out at the snapshot deadline")
        }
        if let failure = receipt.executionFailure {
            lines.append("execution failure: \(failure)"
                + Self.failureDetail(receipt.executionFailureDetail))
        }
        if let failure = receipt.verificationFailure {
            lines.append("verification failure: \(failure)"
                + Self.failureDetail(receipt.verificationFailureDetail))
        }
        lines.append("budget \(receipt.budgetMilliseconds.map(String.init) ?? "?") ms"
            + "; duration \(receipt.durationMilliseconds.map(String.init) ?? "?") ms"
            + "; stdout \(receipt.stdoutBytes.map(String.init) ?? "?") B"
            + (receipt.stdoutTruncated ? " (truncated)" : "")
            + "; stderr \(receipt.stderrBytes.map(String.init) ?? "?") B"
            + (receipt.stderrTruncated ? " (truncated)" : ""))
        if !receipt.stdout.isEmpty {
            lines.append("stdout:\n\(ScenarioProcessOutput.detailTail(receipt.stdout))")
        }
        if !receipt.stderr.isEmpty {
            lines.append("stderr:\n\(ScenarioProcessOutput.detailTail(receipt.stderr))")
        }
        if immutableFork {
            let changes = receipt.sideEffectChanges ?? 0
            let live: String
            if receipt.liveWorkspaceUnchanged == true {
                live = "live workspace unchanged"
            } else if receipt.liveWorkspaceUnchanged == false {
                live = "live workspace NOT verified unchanged"
            } else {
                live = "live workspace unchanged: not recorded"
            }
            lines.append("fork side effects: \(changes) path(s); \(live)")
        } else {
            lines.append("fork side effects: not recorded (no immutable fork)")
        }
        return lines.joined(separator: "\n")
    }

    /// Format a bounded failure detail without letting it dominate the line.
    private static func failureDetail(_ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return "" }
        return " (\(ScenarioProcessOutput.detailTail(detail)))"
    }

    /// Build one report through the run's redactor.
    private static func report(_ assertion: Scenario.Assertion,
                               ok: Bool,
                               detail: String,
                               workerEvaluated: Bool? = nil,
                               workerReceipt: JSONValue? = nil,
                               durationMs: Int? = nil,
                               request: PhoneDSHWorkerCommandRequest? = nil,
                               failure: ScenarioAssertionFailure?,
                               redactor: ScenarioRedactor) -> ScenarioAssertionReport {
        let redactedFailure = failure.map {
            ScenarioAssertionFailure(
                kind: $0.kind,
                path: $0.path.map(redactor.redact),
                expected: $0.expected.map(redactor.redact),
                actual: $0.actual.map(redactor.redact))
        }
        return ScenarioAssertionReport(
            type: assertion.type,
            ok: ok,
            detail: redactor.redact(detail),
            command: assertion.command.map(redactor.redact),
            hostEvaluated: nil,
            durationMs: durationMs,
            workerEvaluated: workerEvaluated,
            workerReceipt: workerReceipt?.redacted(using: redactor),
            // Map the optional request, not `request?.program`: the latter
            // resolves to `String.map` (a `Character` closure) and does not
            // type-check against `redactor.redact(String)`.
            program: request.map { redactor.redact($0.program) },
            cwd: request.map { redactor.redact($0.cwd) },
            timeoutMilliseconds: request?.timeoutMilliseconds,
            failure: redactedFailure)
    }
}

/// Recursively redact every string in a raw receipt while preserving its JSON
/// shape. `ScenarioReportArtifact` encodes the report directly, so a secret in
/// `execution.stdout`, a changed path or any additive receipt field must not
/// survive in `report.json`.
private extension JSONValue {
    func redacted(using redactor: ScenarioRedactor) -> JSONValue {
        switch self {
        case .string(let value):
            return .string(redactor.redact(value))
        case .array(let values):
            return .array(values.map { $0.redacted(using: redactor) })
        case .object(let object):
            var safe: [String: JSONValue] = [:]
            for (key, value) in object {
                safe[redactor.redact(key)] = value.redacted(using: redactor)
            }
            return .object(safe)
        case .null, .bool, .number:
            return self
        }
    }
}
