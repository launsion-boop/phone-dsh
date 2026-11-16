// SPDX-License-Identifier: MIT

import Foundation

/// The model-facing entry point for user feedback utterances.
///
/// This is a host tool, not a generic MCP registration: it is executed through
/// the same `BotTeamToolHandling` seam the runtime already uses for host tools,
/// and the runtime only routes a call here after identity attribution and the
/// per-caller catalog check. The handler refuses every principal that is not a
/// real user chat turn, so a routine/task/agent/maintainer turn can never claim
/// the user's preference.
public struct BotFeedbackTools: BotTeamToolHandling {
    public static let toolName = "RecordFeedback"

    private let center: BotFeedbackCenter

    public init(center: BotFeedbackCenter) {
        self.center = center
    }

    public func handles(_ toolName: String) -> Bool {
        Self.bare(toolName) == Self.toolName
    }

    public func execute(name: String, arguments: BotJSONValue,
                        principal: BotGatewayPrincipal,
                        context: BotMCPRequestContext) async -> BotMCPCallResult {
        guard principal.kind == .chat else {
            return .failure("permission_denied",
                            "只有真实用户回合可以记录反馈；后台/例行/代理会话不能替用户表态。")
        }
        guard case .object(let args) = arguments else {
            return .failure("invalid_arguments", "RecordFeedback 的参数必须是对象。")
        }
        guard let actionText = Self.string(args["action"]),
              let action = BotFeedbackAction(rawValue: actionText) else {
            return .failure("invalid_arguments",
                            "action 必须是 adopt、undo、correct 或 suppress。")
        }
        guard case .object(let targetObject)? = args["target"] else {
            return .failure("invalid_arguments", "target 必须是对象。")
        }
        guard let kindText = Self.string(targetObject["kind"]),
              let kind = BotFeedbackArtifactKind(rawValue: kindText),
              let rawID = Self.string(targetObject["id"]),
              !Self.trim(rawID).isEmpty else {
            return .failure("invalid_arguments", "target 需要 kind 与 id。")
        }
        let scope: BotFeedbackScopeKind
        if let scopeText = Self.string(args["scope"]) {
            guard let parsed = BotFeedbackScopeKind(rawValue: scopeText) else {
                return .failure("invalid_arguments",
                                "scope 必须是 artifact、routine、class 或 user。")
            }
            scope = parsed
        } else {
            scope = .artifact
        }
        var version: Int?
        if let rawVersion = targetObject["version"] {
            guard case .number(let number) = rawVersion, number >= 0,
                  number == number.rounded() else {
                return .failure("invalid_arguments", "target.version 必须是非负整数。")
            }
            version = Int(number)
        }
        var disputedRefs: [String] = []
        if case .array(let refs)? = args["disputed_refs"] {
            for value in refs {
                guard case .string(let ref) = value else {
                    return .failure("invalid_arguments", "disputed_refs 必须是字符串数组。")
                }
                disputedRefs.append(ref)
            }
        }
        var expiresAtMS: Int64?
        if let raw = args["expires_at_ms"] {
            guard case .number(let number) = raw, number >= 0,
                  number == number.rounded() else {
                return .failure("invalid_arguments", "expires_at_ms 必须是非负整数。")
            }
            expiresAtMS = Int64(number)
        }
        var feedback = BotFeedback(
            botID: principal.botId, action: action,
            target: BotFeedbackArtifactRef(
                kind: kind, id: Self.trim(rawID), version: version,
                deliveryKey: Self.string(targetObject["delivery_key"])),
            scope: scope,
            origin: BotFeedbackOrigin(kind: .userChatTurn,
                                      sessionID: principal.sessionId,
                                      nonce: context.callId),
            disputedRefs: disputedRefs,
            expiresAtMS: expiresAtMS)
        // G-2 r11: a model cannot prove an applied write. When it supplies the
        // real refs it is disputing an existing version, so record the
        // disputed-only shape (omit `applied`); a direct host caller can still
        // record the applied shape explicitly.
        if action == .correct, !disputedRefs.isEmpty {
            feedback.disputedOnly = true
        }
        do {
            let outcome = try await center.record(feedback)
            return .success(Self.encode(outcome))
        } catch {
            return .failure("execution_failed", "反馈没有记录成功。")
        }
    }

    /// The per-caller tool definition. G-2 freezes this shape; the runtime
    /// catalog provider appends it for identified callers until K releases L3.
    /// The per-caller tool definition frozen by G-2
    /// (`spec/bot/v2/record-feedback-tool.json`, contract revision
    /// `b4c6ef7d99ea7cbec53697c045e25855d1e2aa79`). Effect is `write+confirm`:
    /// the runtime classifier must use `write`/`ask`, never `auto`.
    public static let definition = BotMCPToolDefinition(
        name: toolName,
        description: "Record explicit feedback the user just gave about one Bot output, routine, or memory. "
            + "Use this when the user accepts, rejects, corrects, or asks you to stop a kind of proactive "
            + "message. Bind the exact object you are referring to; never guess an id. scope=user only when "
            + "the user wants the same class of message suppressed in every Bot.",
        inputSchema: .object([
            "type": .string("object"),
            "required": .array([.string("action"), .string("target")]),
            "properties": .object([
                "action": .object(["enum": .array(BotFeedbackAction.allCases.map {
                    BotJSONValue.string($0.rawValue)
                })]),
                "target": .object([
                    "type": .string("object"),
                    "required": .array([.string("kind"), .string("id")]),
                    "properties": .object([
                        "kind": .object(["enum": .array(BotFeedbackArtifactKind.allCases.map {
                            BotJSONValue.string($0.rawValue)
                        })]),
                        "id": .object(["type": .string("string"), "minLength": .number(1),
                                       "maxLength": .number(200)]),
                        "version": .object(["type": .string("integer"), "minimum": .number(0)]),
                        "delivery_key": .object(["type": .string("string"),
                                                 "minLength": .number(1),
                                                 "maxLength": .number(200)]),
                    ]),
                    "additionalProperties": .bool(false),
                ]),
                "scope": .object(["enum": .array(BotFeedbackScopeKind.allCases.map {
                    BotJSONValue.string($0.rawValue)
                }), "default": .string("artifact")]),
                "disputed_refs": .object([
                    "type": .string("array"), "maxItems": .number(8),
                    "items": .object([
                        "type": .string("string"),
                        "pattern": .string("^record://(session|event)/"),
                    ]),
                ]),
                "expires_at_ms": .object(["type": .string("integer"), "minimum": .number(0)]),
            ]),
            "additionalProperties": .bool(false),
        ]))

    private static func encode(_ outcome: BotFeedbackOutcome) -> BotJSONValue {
        let effectiveAccept = outcome.accepted || outcome.status == .duplicated
        var fields: [String: BotJSONValue] = [
            "ok": .bool(effectiveAccept),
            "accepted": .bool(effectiveAccept),
            "status": .string(outcome.status.rawValue),
            "action": .string(outcome.action.rawValue),
        ]
        if !effectiveAccept, let reason = outcome.reason {
            fields["reason"] = .string(reason)
            // A generic, contract-level hint lets the model correct a wrong
            // kind/scope without guessing and without any test-specific id.
            fields["hint"] = .string(Self.rejectionHint(for: outcome.action))
            fields["accepted_target_kinds"] = .array(
                BotFeedbackArtifactKind.allCases.map { BotJSONValue.string($0.rawValue) })
        }
        if let value = outcome.feedbackID { fields["feedback_id"] = .string(value) }
        if let value = outcome.classKey { fields["class_key"] = .string(value) }
        if let value = outcome.code { fields["code"] = .string(value) }
        if let value = outcome.message { fields["message"] = .string(value) }
        if outcome.reversed { fields["reversed"] = .bool(true) }
        if outcome.auditPending { fields["audit_pending"] = .bool(true) }
        if let applied = outcome.appliedMemory {
            fields["applied_memory"] = .object([
                "path": .string(applied.path),
                "version": .number(Double(applied.version)),
                "previous_version": .number(Double(applied.previousVersion)),
            ])
        }
        return .object(fields)
    }

    static func rejectionHint(for action: BotFeedbackAction) -> String {
        switch action {
        case .adopt:
            return "adopt needs a delivery row ref from the row/context, or a delivered proactive artifact; a plain message row is adopted by the UI only."
        case .suppress:
            return "suppress needs a delivered proactive/delivery artifact (scope artifact/class) or a routine id from automation_status (scope routine/class); a routine target with scope artifact is invalid, and an ordinary message row does not define a class."
        case .correct:
            return "correct needs target.kind=memory with the current version; UpdateMemory is not required. Include real record:// disputed_refs to dispute the existing version without rewriting it (disputed-only), or bind a version actually written in this turn (applied correction)."
        case .undo:
            return "undo needs target.kind=feedback with the feedback_id returned by an earlier accepted RecordFeedback call."
        }
    }

    private static func bare(_ name: String) -> String {
        (name.components(separatedBy: "__").last ?? name)
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func string(_ value: BotJSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }
}
