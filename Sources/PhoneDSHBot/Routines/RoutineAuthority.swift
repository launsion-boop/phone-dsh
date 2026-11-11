// SPDX-License-Identifier: MIT

import Foundation

/// The user-message authority of the turn that is currently executing a tool.
///
/// `isUserTurn` is the only input that decides whether a routine change or a
/// `CreateTeammate` call may proceed without an approval card. It is derived
/// from the host-minted turn origin (README §4.1), never from message text or
/// the session kind. A held turn is deliberately not a user turn for authority:
/// the held block may contain another Bot's text, so it cannot widen goals.
public struct BotTurnAuthority: Codable, Sendable, Equatable {
    public var rpcId: String?
    public var turnId: String?
    public var sessionId: String
    public var origin: BotTurnOriginKind
    public var isUserTurn: Bool
    /// The approval-card id when a non-user turn was confirmed by the user.
    public var approvalID: String?

    public init(rpcId: String?, turnId: String?, sessionId: String,
                origin: BotTurnOriginKind, isUserTurn: Bool, approvalID: String? = nil) {
        self.rpcId = rpcId
        self.turnId = turnId
        self.sessionId = sessionId
        self.origin = origin
        self.isUserTurn = isUserTurn
        self.approvalID = approvalID
    }

    /// Human-readable trigger for an approval card. The `agent:` case names
    /// the sender's call id rather than a display name because the host does
    /// not trust model-supplied names; the message itself is not quoted.
    public var approvalSourceDescription: String {
        switch origin {
        case .agent:
            return "由其他 Bot 的消息（\(rpcId ?? "未知 callId")）触发"
        case .routine:
            return "由例行任务回合触发"
        case .task, .taskWake:
            return "由 Task 子会话触发"
        case .held:
            return "由带 held 块的回合触发"
        case .user:
            return "由用户回合触发"
        case .unknown:
            return "回合来源未知（没有用户消息引用）"
        }
    }
}

/// Who created a routine, expressed with the current turn-source fields.
/// S1 replaces `rpcId` with a `record://` reference; no second field is added
/// in the meantime.
public struct RoutineCreator: Codable, Sendable, Equatable {
    public enum Authorization: String, Codable, Sendable {
        case userTurn = "user-turn"
        case userConfirmed = "user-confirmed"
    }

    public var rpcId: String?
    public var turnId: String?
    public var sessionId: String?
    public var origin: BotTurnOriginKind
    public var authorization: Authorization
    public var approvalID: String?

    public init(rpcId: String? = nil, turnId: String? = nil, sessionId: String? = nil,
                origin: BotTurnOriginKind, authorization: Authorization,
                approvalID: String? = nil) {
        self.rpcId = rpcId
        self.turnId = turnId
        self.sessionId = sessionId
        self.origin = origin
        self.authorization = authorization
        self.approvalID = approvalID
    }

    public init(authority: BotTurnAuthority, approvalID: String? = nil) {
        self.init(
            rpcId: authority.rpcId, turnId: authority.turnId, sessionId: authority.sessionId,
            origin: authority.origin,
            authorization: authority.isUserTurn ? .userTurn : .userConfirmed,
            approvalID: authority.isUserTurn ? nil : approvalID)
    }
}

/// One routine create/update decision before it reaches the store. The host
/// asks for confirmation only for `requiresConfirmation`; the pure rule lives
/// here so the approval card and the store see the same assessment.
public struct RoutineChangeAssessment: Sendable, Equatable {
    public enum Action: String, Sendable {
        case create
        case update
        case resume
        case other
    }

    public var action: Action
    public var routineID: String?
    public var requiresConfirmation: Bool
    public var resource: String
    public var detail: String

    public init(action: Action, routineID: String?, requiresConfirmation: Bool,
                resource: String, detail: String) {
        self.action = action
        self.routineID = routineID
        self.requiresConfirmation = requiresConfirmation
        self.resource = resource
        self.detail = detail
    }
}

public enum RoutineAuthority {
    /// The fields whose change widens what the routine may do on its own.
    public static let approvalAction = "更新例行任务授权"

    /// Classify one `UpdateRoutine` request. Parsing errors are left to
    /// `BotRoutineTool.handle`; this function returns `nil` when the caller
    /// should not be asked (read/delete/pause or a non-widening update).
    public static func assess(arguments: BotJSONValue,
                              machine: RoutineMachine, botId: String,
                              now: Int64) async throws -> RoutineChangeAssessment {
        guard case .object(let args) = arguments,
              case .string(let action)? = args["action"] else {
            throw BotMCPError.invalidRequest("UpdateRoutine requires action")
        }
        switch action {
        case "create":
            let title = try BotRoutineTool.routineTitle(from: args)
            return RoutineChangeAssessment(
                action: .create, routineID: nil, requiresConfirmation: true,
                resource: "routine:create:\(safeResource(title))",
                detail: "在新的例行任务「\(title)」创建前确认；它会在没有用户消息的回合里保存可自行触发的目标。")
        case "update":
            let id = try BotRoutineTool.requiredString(args, "routine_id")
            guard let current = try await machine.get(botId: botId, routineId: id) else {
                throw RoutineError.routineNotFound(id)
            }
            let patch = try BotRoutineTool.makePatch(from: args)
            let widens = isLoosening(current: current, patch: patch, now: now)
            return RoutineChangeAssessment(
                action: .update, routineID: id, requiresConfirmation: widens,
                resource: "routine:widen:\(safeResource(id)):\(safeResource(RoutineAuthority.describe(patch)))",
                detail: "例行任务「\(current.title)」会被放宽：\(describeWidening(current: current, patch: patch, now: now))。")
        case "resume":
            let id = try BotRoutineTool.requiredString(args, "routine_id")
            guard let current = try await machine.get(botId: botId, routineId: id) else {
                throw RoutineError.routineNotFound(id)
            }
            return RoutineChangeAssessment(
                action: .resume, routineID: id, requiresConfirmation: !current.enabled,
                resource: "routine:resume:\(safeResource(id))",
                detail: "重新启用暂停的例行任务「\(current.title)」会恢复它的自动触发。")
        default:
            return RoutineChangeAssessment(
                action: .other, routineID: args["routine_id"]?.stringValue,
                requiresConfirmation: false, resource: "routine:other",
                detail: "读、列、暂停或删除不改变自行触发的授权。")
        }
    }

    /// True when applying `patch` to `current` would let the routine fire more
    /// often or reach the user more aggressively than the user has seen.
    public static func isLoosening(current: Routine, patch: RoutinePatch,
                                   now: Int64) -> Bool {
        if patch.enabled == true, !current.enabled { return true }
        if let delivery = patch.delivery, delivery == .interrupt, current.delivery != .interrupt {
            return true
        }
        if patch.urgent == true, !current.urgent { return true }
        if let schedule = patch.schedule,
           RoutineScheduleMath.isMoreFrequent(schedule, than: current.schedule, now: now) {
            return true
        }
        return false
    }

    private static func describeWidening(current: Routine, patch: RoutinePatch,
                                         now: Int64) -> String {
        var parts: [String] = []
        if patch.enabled == true, !current.enabled { parts.append("恢复自动触发") }
        if let delivery = patch.delivery, delivery == .interrupt, current.delivery != .interrupt {
            parts.append("改为立即打断")
        }
        if patch.urgent == true, !current.urgent { parts.append("改为紧急") }
        if let schedule = patch.schedule,
           RoutineScheduleMath.isMoreFrequent(schedule, than: current.schedule, now: now) {
            parts.append("触发更频繁")
        }
        return parts.isEmpty ? "无" : parts.joined(separator: "、")
    }

    private static func describe(_ patch: RoutinePatch) -> String {
        var parts: [String] = []
        if let schedule = patch.schedule {
            parts.append(RoutineScheduleMath.expression(schedule) ?? schedule.kind.rawValue)
        }
        if let delivery = patch.delivery { parts.append("delivery=\(delivery.rawValue)") }
        if let urgent = patch.urgent { parts.append("urgent=\(urgent)") }
        if let enabled = patch.enabled { parts.append("enabled=\(enabled)") }
        return parts.joined(separator: ",")
    }

    private static func safeResource(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let mapped = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return String(mapped.prefix(120))
    }
}
