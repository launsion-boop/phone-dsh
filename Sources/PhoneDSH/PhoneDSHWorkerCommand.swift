// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2-FIX-35: Worker-side command acceptance receipts.
//
// `workspace_command` is host acceptance: the Mac runs `/bin/bash` against a
// materialized copy of the workspace. This file is the independent Worker
// entry. The scenario runner asks the live Worker, over the same authenticated
// ordered channel the harness uses, to execute one assertion command against
// an immutable fork of its VFS and return a receipt bound to the scenario,
// session, turn and completion watermark.
//
// The phone-only route is served by `@phone-dsh/dsh-surface-phone` (the same
// connection carrier as the recovery write-open). It makes no model request
// and never opens the session journal. The host does not fall back to a local
// process when the receipt is absent or malformed: that is a failed assertion,
// not a Worker observation.

import Foundation
import PhoneDSHAgentCore
import PhoneDSHWire

/// Wire facts of the phone-only Worker command acceptance route.
public enum PhoneDSHWorkerCommandProtocol {
    /// Exact shared-API path served by `@phone-dsh/dsh-surface-phone`.
    public static let path = "/api/pdsh-worker-command/execute"
    /// Request and response media type.
    public static let contentType = "application/json"
    /// Receipt protocol recorded by the route.
    public static let receiptProtocol = "pdsh-worker-command/1"
    /// Default command budget, matching the route's default.
    public static let defaultBudgetMilliseconds = 30_000
    /// Upper bound the route enforces.
    public static let maximumBudgetMilliseconds = 120_000
}

/// One Worker command assertion request.
///
/// The binding is not optional: a receipt that cannot say which scenario,
/// session, turn and assertion it belongs to is not acceptance evidence.
public struct PhoneDSHWorkerCommandRequest: Equatable, Sendable {
    public var command: String
    /// `bash` (default), `sh` or `python3`.
    public var program: String
    public var cwd: String
    public var timeoutMilliseconds: Int
    public var scenarioID: String
    public var sessionID: String
    public var turn: Int
    public var assertionIndex: Int
    public var completionWatermark: Int?

    public init(command: String,
                program: String = "bash",
                cwd: String = "/dsh/workspace",
                timeoutMilliseconds: Int = PhoneDSHWorkerCommandProtocol.defaultBudgetMilliseconds,
                scenarioID: String,
                sessionID: String,
                turn: Int,
                assertionIndex: Int,
                completionWatermark: Int? = nil) {
        self.command = command
        self.program = program
        self.cwd = cwd
        self.timeoutMilliseconds = min(
            max(1, timeoutMilliseconds),
            PhoneDSHWorkerCommandProtocol.maximumBudgetMilliseconds)
        self.scenarioID = scenarioID
        self.sessionID = sessionID
        self.turn = turn
        self.assertionIndex = assertionIndex
        self.completionWatermark = completionWatermark
    }

    /// The exact JSON object the route validates.
    public var json: JSONValue {
        var value: [String: JSONValue] = [
            "command": .string(command),
            "program": .string(program),
            "cwd": .string(cwd),
            "timeout_ms": .number(Double(timeoutMilliseconds)),
            "scenario_id": .string(scenarioID),
            "session_id": .string(sessionID),
            "turn": .number(Double(turn)),
            "assertion_index": .number(Double(assertionIndex)),
        ]
        if let completionWatermark {
            value["completion_watermark"] = .number(Double(completionWatermark))
        }
        return .object(value)
    }
}

/// Typed view of one `pdsh-worker-command/1` receipt.
///
/// `raw` is retained verbatim for `report.json`; the accessors are the stable
/// facts the assertion evaluator checks. A malformed receipt fails loud.
public struct PhoneDSHWorkerCommandReceipt: Equatable, Sendable {
    public var raw: JSONValue

    public init(raw: JSONValue) throws {
        guard case .object(let object) = raw,
              object["protocol"]?.stringValue == PhoneDSHWorkerCommandProtocol.receiptProtocol else {
            throw PhoneDSHError.invalidResponse(
                "the Worker returned no pdsh-worker-command/1 receipt")
        }
        self.raw = raw
    }

    private var object: [String: JSONValue] {
        if case .object(let object) = raw { return object }
        return [:]
    }

    public var receiptID: String? { object["receipt_id"]?.stringValue }

    public var location: [String: JSONValue] {
        object["location"]?.objectValue ?? [:]
    }

    public var locationKind: String? { location["kind"]?.stringValue }
    public var locationHostProcess: Bool? { location["host_process"]?.boolValue }
    public var locationWorkerVFS: Bool? { location["worker_vfs"]?.boolValue }
    public var locationFork: String? { location["fork"]?.stringValue }

    public var isWorkerVFS: Bool {
        locationKind == "worker"
            && locationWorkerVFS == true
            && locationHostProcess == false
            && locationFork == "memory-vfs"
    }

    public var carrier: String? { location["carrier"]?.stringValue }

    public var binding: [String: JSONValue] {
        object["binding"]?.objectValue ?? [:]
    }

    public var bindingScenarioID: String? { binding["scenario_id"]?.stringValue }
    public var bindingSessionID: String? { binding["session_id"]?.stringValue }
    public var bindingTurn: Int? { binding["turn"]?.intValue }
    public var bindingAssertionIndex: Int? { binding["assertion_index"]?.intValue }
    public var bindingCompletionWatermark: Int? { binding["completion_watermark"]?.intValue }

    public var source: [String: JSONValue] {
        object["source"]?.objectValue ?? [:]
    }

    /// The fork's missing-root list. `nil` means the field is absent or not a
    /// string array, which is never a valid immutable-fork claim.
    public var sourceMissingRoots: [String]? {
        guard let value = source["missing_roots"], case .array(let roots) = value else {
            return nil
        }
        var values: [String] = []
        for root in roots {
            guard case .string(let text) = root else { return nil }
            values.append(text)
        }
        return values
    }

    /// A receipt is an immutable fork only when the source is frozen at one
    /// watermark, has a digest, and every declared root was captured. A failed
    /// capture publishes `source_frozen: false` and/or non-empty
    /// `missing_roots`, so it can never be accepted as the fork that ran the
    /// command.
    public var isImmutableFork: Bool {
        guard source["kind"]?.stringValue == "worker-vfs-fork",
              source["fork"]?.boolValue == true,
              source["digest"]?.stringValue?.isEmpty == false,
              sourceFrozen == true,
              let missingRoots = sourceMissingRoots,
              missingRoots.isEmpty else {
            return false
        }
        return true
    }

    public var sourceMseqStart: Int? { source["source_mseq_start"]?.intValue }
    public var sourceMseqEnd: Int? { source["source_mseq_end"]?.intValue }
    public var sourceFrozen: Bool? { source["source_frozen"]?.boolValue }
    public var sourceFork: Bool? { source["fork"]?.boolValue }
    public var sourceDigest: String? { source["digest"]?.stringValue }
    public var sourceEntries: Int? { source["entries"]?.intValue }
    public var sourceBytes: Int? { source["bytes"]?.intValue }
    public var sourceFailure: String? { source["failure"]?.stringValue }
    public var sourceFailureDetail: String? { source["failure_detail"]?.stringValue }
    public var sourceTimedOut: Bool? { source["timed_out"]?.boolValue }

    public var execution: [String: JSONValue] {
        object["execution"]?.objectValue ?? [:]
    }

    public var program: String? { execution["program"]?.stringValue }
    public var cwd: String? { execution["cwd"]?.stringValue }
    public var exitCode: Int? { execution["exit_code"]?.intValue }
    public var timedOut: Bool { execution["timed_out"]?.boolValue == true }
    public var cancelled: Bool { execution["cancelled"]?.boolValue == true }
    public var durationMilliseconds: Int? { execution["duration_ms"]?.intValue }
    public var budgetMilliseconds: Int? { execution["budget_ms"]?.intValue }
    public var stdout: String { execution["stdout"]?.stringValue ?? "" }
    public var stderr: String { execution["stderr"]?.stringValue ?? "" }
    public var stdoutBytes: Int? { execution["stdout_bytes"]?.intValue }
    public var stderrBytes: Int? { execution["stderr_bytes"]?.intValue }
    public var stdoutTruncated: Bool { execution["stdout_truncated"]?.boolValue == true }
    public var stderrTruncated: Bool { execution["stderr_truncated"]?.boolValue == true }
    public var executionFailure: String? { execution["failure"]?.stringValue }
    public var executionFailureDetail: String? { execution["failure_detail"]?.stringValue }

    public var modelRequests: Int? { object["model_requests"]?.intValue }
    public var liveWorkspaceUnchanged: Bool? { object["live_workspace_unchanged"]?.boolValue }
    public var sideEffects: [String: JSONValue] {
        object["side_effects"]?.objectValue ?? [:]
    }

    public var sideEffectsIsolated: Bool? { sideEffects["isolated"]?.boolValue }
    /// Explicit containment facts. A receipt that omits either key is not
    /// accepted: absence must never read as "no side effect".
    public var sideEffectsLiveWorkspace: Bool? { sideEffects["live_workspace"]?.boolValue }
    public var sideEffectsJournal: Bool? { sideEffects["journal"]?.boolValue }
    public var sideEffectChanges: Int? { sideEffects["changed"]?.intValue }

    public var verification: [String: JSONValue] {
        object["verification"]?.objectValue ?? [:]
    }

    public var verificationFailure: String? { verification["failure"]?.stringValue }
    public var verificationFailureDetail: String? { verification["failure_detail"]?.stringValue }

    /// The command succeeded only when it really exited 0 without a timeout or
    /// cancellation.
    public var succeeded: Bool {
        exitCode == 0 && !timedOut && !cancelled
    }
}

/// A transport that can ask the live Worker to execute one acceptance command.
///
/// Kept separate from `DSHRemoteTransport` so ordinary fake transports remain
/// unchanged and the Worker assertion can never fall back to a host shell.
public protocol PhoneDSHWorkerCommandCalling: Sendable {
    func executeWorkerCommand(_ request: PhoneDSHWorkerCommandRequest) async throws
        -> PhoneDSHWorkerCommandReceipt
}

extension ChannelDSHTransport: PhoneDSHWorkerCommandCalling {
    /// Post one command request to the phone-only route. A non-200 answer is a
    /// transport/route failure, never a synthesized observation.
    public func executeWorkerCommand(_ request: PhoneDSHWorkerCommandRequest) async throws
        -> PhoneDSHWorkerCommandReceipt {
        let body: Data
        do {
            body = try request.json.encoded()
        } catch {
            throw PhoneDSHError.invalidResponse("cannot encode the Worker command request")
        }
        let head = ApiRequestHead(method: "POST", path: PhoneDSHWorkerCommandProtocol.path,
                                  headers: [
                                    PhoneDSHMuxProtocol.contentTypeHeader:
                                        PhoneDSHWorkerCommandProtocol.contentType,
                                    "accept": PhoneDSHWorkerCommandProtocol.contentType,
                                  ])
        let result = try await sendWithReconnect(head: head, body: body)
        guard result.status == 200 else {
            let message = String(decoding: result.body.prefix(256), as: UTF8.self)
            throw DSHRemoteError(code: "worker-command/http-\(result.status)",
                                 message: message.isEmpty ? "HTTP \(result.status)" : message)
        }
        guard let envelope = try? JSONValue.parse(result.body),
              envelope["ok"]?.boolValue == true,
              let value = envelope["value"] else {
            throw PhoneDSHError.invalidResponse(
                "the Worker command route returned no successful receipt envelope")
        }
        return try PhoneDSHWorkerCommandReceipt(raw: value)
    }
}

