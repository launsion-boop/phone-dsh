// SPDX-License-Identifier: MIT

import Foundation

public struct RoutineRunRequest: Sendable, Equatable {
    public var botId: String
    public var routine: Routine
    public var runId: String
    public var attempt: Int
    public var startedAt: Int64
    public var timeoutMs: Int64
    public var wake: RoutineWake
    /// Set when a `waiting-approval` run is resumed. The request id and the
    /// prompt must differ from the first attempt so DSH opens a new turn
    /// instead of deduplicating the original prompt.
    public var resumeApprovalID: String?
    /// The routine session recorded with the parked run. After a process
    /// restart the in-memory routine→session map is gone; reusing this id keeps
    /// the same conversation when the Worker can still resume it.
    public var resumeSessionID: String?

    public init(botId: String, routine: Routine, runId: String, attempt: Int,
                startedAt: Int64, timeoutMs: Int64,
                wake: RoutineWake, resumeApprovalID: String? = nil,
                resumeSessionID: String? = nil) {
        self.botId = botId
        self.routine = routine
        self.runId = runId
        self.attempt = attempt
        self.startedAt = startedAt
        self.timeoutMs = timeoutMs
        self.wake = wake
        self.resumeApprovalID = resumeApprovalID
        self.resumeSessionID = resumeSessionID
    }
}

public enum RoutineExecutionStatus: String, Sendable {
    case succeeded
    case failed
    case cancelled
    /// The run stopped at a durable approval. It produced no delivery and the
    /// scheduler persists `waiting-approval` until the user decides.
    case waitingApproval
}

public struct RoutineExecutionResult: Sendable, Equatable {
    public var status: RoutineExecutionStatus
    public var text: String
    public var error: String?
    public var quiet: Bool
    public var cancelledBy: String?
    public var approvalID: String?
    public var sessionID: String?

    public init(status: RoutineExecutionStatus, text: String = "", error: String? = nil,
                quiet: Bool = false, cancelledBy: String? = nil,
                approvalID: String? = nil, sessionID: String? = nil) {
        self.status = status
        self.text = text
        self.error = error
        self.quiet = quiet
        self.cancelledBy = cancelledBy
        self.approvalID = approvalID
        self.sessionID = sessionID
    }

    public static func success(_ text: String, quiet: Bool = false) -> RoutineExecutionResult {
        RoutineExecutionResult(status: .succeeded, text: text, quiet: quiet)
    }

    public static func failure(_ error: String) -> RoutineExecutionResult {
        RoutineExecutionResult(status: .failed, error: error)
    }

    public static func waiting(approvalID: String, sessionID: String,
                               error: String? = nil) -> RoutineExecutionResult {
        RoutineExecutionResult(status: .waitingApproval, error: error,
                               approvalID: approvalID, sessionID: sessionID)
    }
}

public struct RoutineCancellation: Sendable, Equatable {
    public var botId: String
    public var routineId: String
    public var runId: String
    public var timeoutMs: Int64
    public var reason: String

    public init(botId: String, routineId: String, runId: String, timeoutMs: Int64, reason: String = "timeout") {
        self.botId = botId
        self.routineId = routineId
        self.runId = runId
        self.timeoutMs = timeoutMs
        self.reason = reason
    }
}

public struct RoutineCancellationResult: Sendable, Equatable {
    public var cancelled: Bool
    public var reconciliationRequired: Bool
    public var reason: String?

    public init(cancelled: Bool, reconciliationRequired: Bool = false, reason: String? = nil) {
        self.cancelled = cancelled
        self.reconciliationRequired = reconciliationRequired
        self.reason = reason
    }
}

public struct RoutineAutomation: Sendable, Equatable, Identifiable {
    public var id: String
    public var botId: String
    public var kind: String
    public var status: String
    public var result: String
    public var error: String?
    public var routineId: String
    public var routineTitle: String
    public var deliveryKey: String
    public var attempt: Int
    public var runId: String
    public var delivery: RoutineDeliveryMode
    public var quiet: Bool
    public var urgent: Bool
    public var urgentReason: String
    public var context: String
    public var scheduledFor: Int64?
    public var lateByMs: Int64
    public var startedAt: Int64
    public var finishedAt: Int64
    public var nextRunAt: Int64?
    public var notified: String?
    public var notifyReason: String?
    public var proactiveMode: String?
    public var heldInbox: String?
    public var heldInboxError: String?

    public init(delivery: RoutineDelivery) {
        id = RoutineDelivery.rowId(routineId: delivery.routineId, attempt: delivery.attempt)
        botId = delivery.agentId
        kind = "routine-run"
        switch delivery.resultStatus {
        case .succeeded:
            status = "sent"
            result = delivery.text
        case .cancelled:
            status = "idle"
            result = "执行已取消"
        case .timedOut:
            status = "failed"
            result = "执行超时，已取消"
        case .needsReconciliation:
            status = "failed"
            result = "执行结果未知，需要确认：\(String((delivery.error ?? "未知原因").prefix(300)))"
        default:
            status = "failed"
            result = "执行失败：\(String((delivery.error ?? "未知错误").prefix(300)))"
        }
        if delivery.resultStatus == .succeeded && delivery.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = "已完成（没有新结果）"
        }
        error = delivery.error
        routineId = delivery.routineId
        routineTitle = delivery.routineTitle
        deliveryKey = delivery.deliveryKey
        attempt = delivery.attempt
        runId = delivery.runId
        self.delivery = delivery.delivery
        quiet = delivery.quiet
        urgent = delivery.urgent
        urgentReason = delivery.urgentReason
        var context = delivery.context
        func append(_ value: String) { context = context.isEmpty ? value : "\(context) · \(value)" }
        if let deferredFrom = delivery.quietDeferredFrom {
            let clock = RoutineScheduleMath.formatMinute(deferredFrom, timezone: TimeZone.current.identifier) ?? "—"
            append("（因安静时段延后，原定 \(String(clock.suffix(5)))）")
        } else if delivery.lateByMs > 60_000 {
            append("（延迟 \(max(1, (delivery.lateByMs + 30_000) / 60_000)) 分钟触发）")
        }
        if delivery.urgent { append("（紧急：\(delivery.urgentReason.isEmpty ? "—" : delivery.urgentReason)）") }
        if delivery.heldInbox == "failed" { append("结果未能交给主对话") }
        if delivery.delivery == .interrupt {
            if delivery.notified == "sent" { append("已通知") }
            if delivery.notified == "skipped" { append("未通知：\(delivery.notifyReason ?? "unknown")") }
        }
        self.context = context
        scheduledFor = delivery.scheduledFor
        lateByMs = delivery.lateByMs
        startedAt = delivery.startedAt
        finishedAt = delivery.finishedAt
        nextRunAt = delivery.nextRunAt
        notified = delivery.notified
        notifyReason = delivery.notifyReason
        proactiveMode = delivery.proactiveMode
        heldInbox = delivery.heldInbox
        heldInboxError = delivery.heldInboxError
    }
}

public protocol RoutineResultSink: Actor {
    @discardableResult
    func deliver(_ automation: RoutineAutomation) async throws -> Bool
}
