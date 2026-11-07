// SPDX-License-Identifier: MIT

import Foundation

public enum RoutineError: Error, LocalizedError, Equatable {
    case invalidSchedule(String)
    case invalidRoutine(String)
    case routineNotFound(String)
    case urgentReasonRequired
    case interruptReasonRequired
    case invalidQuietTarget
    case invalidHeldItem(String)
    case heldInboxFull(Int)
    case deliveryNotFound(String)
    case unsupportedDecision(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSchedule(let message), .invalidRoutine(let message), .invalidHeldItem(let message):
            return message
        case .routineNotFound(let id):
            return "routine not found: \(id)"
        case .urgentReasonRequired:
            return "urgent_reason is required when urgent is true (say which incident or deadline cannot wait)"
        case .interruptReasonRequired:
            return "interrupt_reason is required when delivery is \"interrupt\" (say who is waiting or what must be handled immediately)"
        case .invalidQuietTarget:
            return "quiet-hours deferral requires a future instant"
        case .heldInboxFull(let limit):
            return "held inbox is full (\(limit) items); the message was not delivered."
        case .deliveryNotFound(let key):
            return "routine delivery not found: \(key)"
        case .unsupportedDecision(let decision):
            return "decision must be \"retry\" or \"acknowledge\", got \(decision)"
        }
    }
}

public enum RoutineDeliveryMode: String, Codable, Sendable, Equatable {
    case held
    case interrupt
}

public enum RoutineRunStatus: String, Codable, Sendable, Equatable {
    case scheduled
    case started
    case succeeded
    case failed
    case timedOut = "timed-out"
    case cancelled
    case needsReconciliation = "needs-reconciliation"

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .timedOut, .cancelled, .needsReconciliation:
            return true
        case .scheduled, .started:
            return false
        }
    }
}

public struct RoutineSchedule: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case interval
        case daily
        case weekly
        case cron
    }

    public var kind: Kind
    public var everyMinutes: Int?
    public var phaseMinutes: Int?
    public var time: String?
    public var weekdays: [Int]?
    public var expr: String?
    public var timezone: String

    public init(kind: Kind, everyMinutes: Int? = nil, phaseMinutes: Int? = nil,
                time: String? = nil, weekdays: [Int]? = nil, expr: String? = nil,
                timezone: String = TimeZone.current.identifier) {
        self.kind = kind
        self.everyMinutes = everyMinutes
        self.phaseMinutes = phaseMinutes
        self.time = time
        self.weekdays = weekdays
        self.expr = expr
        self.timezone = timezone
    }

    public static func interval(everyMinutes: Int, phaseMinutes: Int? = nil,
                                timezone: String = TimeZone.current.identifier) -> RoutineSchedule {
        RoutineSchedule(kind: .interval, everyMinutes: everyMinutes, phaseMinutes: phaseMinutes, timezone: timezone)
    }

    public static func daily(time: String, timezone: String = TimeZone.current.identifier) -> RoutineSchedule {
        RoutineSchedule(kind: .daily, time: time, timezone: timezone)
    }

    public static func weekly(time: String, weekdays: [Int],
                              timezone: String = TimeZone.current.identifier) -> RoutineSchedule {
        RoutineSchedule(kind: .weekly, time: time, weekdays: weekdays, timezone: timezone)
    }

    public static func cron(_ expr: String, timezone: String = TimeZone.current.identifier) -> RoutineSchedule {
        RoutineSchedule(kind: .cron, expr: expr, timezone: timezone)
    }

    public func validated() throws -> RoutineSchedule {
        let zone = timezone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !zone.isEmpty else { throw RoutineError.invalidSchedule("schedule.timezone must be a non-empty IANA time zone") }
        guard TimeZone(identifier: zone) != nil else { throw RoutineError.invalidSchedule("unsupported time zone: \(zone)") }
        var copy = self
        copy.timezone = zone
        switch kind {
        case .interval:
            guard let everyMinutes, everyMinutes >= 1, everyMinutes <= 525_600 else {
                throw RoutineError.invalidSchedule("schedule.everyMinutes must be an integer 1–525600")
            }
            if let phaseMinutes, phaseMinutes < 0 || phaseMinutes >= everyMinutes {
                throw RoutineError.invalidSchedule("schedule.phaseMinutes must be an integer offset shorter than everyMinutes")
            }
            copy.everyMinutes = everyMinutes
            copy.time = nil
            copy.weekdays = nil
            copy.expr = nil
        case .daily:
            let parsed = try RoutineClock.parseTime(time)
            copy.time = parsed.text
            copy.everyMinutes = nil
            copy.phaseMinutes = nil
            copy.weekdays = nil
            copy.expr = nil
        case .weekly:
            let parsed = try RoutineClock.parseTime(time)
            guard let weekdays, !weekdays.isEmpty, weekdays.allSatisfy({ (1...7).contains($0) }) else {
                throw RoutineError.invalidSchedule("schedule.weekdays must be a non-empty array of ISO weekdays 1=Mon … 7=Sun")
            }
            copy.time = parsed.text
            copy.weekdays = Array(Set(weekdays)).sorted()
            copy.everyMinutes = nil
            copy.phaseMinutes = nil
            copy.expr = nil
        case .cron:
            let expression = (expr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try CronExpression.parse(expression)
            copy.expr = expression.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            copy.everyMinutes = nil
            copy.phaseMinutes = nil
            copy.time = nil
            copy.weekdays = nil
        }
        return copy
    }
}

public struct RoutineQuietDefer: Codable, Sendable, Equatable {
    public var until: Int64
    public var scheduledFor: Int64
    public var at: Int64

    public init(until: Int64, scheduledFor: Int64, at: Int64) {
        self.until = until
        self.scheduledFor = scheduledFor
        self.at = at
    }
}

public struct RoutineRunState: Codable, Sendable, Equatable {
    public var runId: String
    public var attempt: Int
    public var status: RoutineRunStatus
    public var scheduledFor: Int64?
    public var startedAt: Int64
    public var finishedAt: Int64?
    public var leaseOwner: String?
    public var leaseExpiresAt: Int64?
    public var error: String?
    public var reconciliationRequired: Bool
    public var recovered: Bool
    public var quietDeferred: RoutineQuietDefer?

    public init(runId: String, attempt: Int, status: RoutineRunStatus, scheduledFor: Int64? = nil,
                startedAt: Int64, finishedAt: Int64? = nil, leaseOwner: String? = nil,
                leaseExpiresAt: Int64? = nil, error: String? = nil,
                reconciliationRequired: Bool = false, recovered: Bool = false,
                quietDeferred: RoutineQuietDefer? = nil) {
        self.runId = runId
        self.attempt = attempt
        self.status = status
        self.scheduledFor = scheduledFor
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.leaseOwner = leaseOwner
        self.leaseExpiresAt = leaseExpiresAt
        self.error = error
        self.reconciliationRequired = reconciliationRequired
        self.recovered = recovered
        self.quietDeferred = quietDeferred
    }
}

public struct RoutineResult: Codable, Sendable, Equatable {
    public var status: RoutineRunStatus
    public var text: String
    public var error: String?
    public var startedAt: Int64
    public var finishedAt: Int64?
    public var durationMs: Int64?
    public var scheduledFor: Int64?
    public var lateByMs: Int64?
    public var quiet: Bool
    public var quietDeferredFrom: Int64?
    public var quietDeferredUntil: Int64?
    public var attempt: Int
    public var runId: String

    enum CodingKeys: String, CodingKey {
        case status, text, error, quiet, attempt
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case durationMs = "duration_ms"
        case scheduledFor = "scheduled_for"
        case lateByMs = "late_by_ms"
        case quietDeferredFrom = "quiet_deferred_from"
        case quietDeferredUntil = "quiet_deferred_until"
        case runId = "run_id"
    }

    public init(status: RoutineRunStatus, text: String = "", error: String? = nil,
                startedAt: Int64, finishedAt: Int64? = nil, durationMs: Int64? = nil,
                scheduledFor: Int64? = nil, lateByMs: Int64? = nil, quiet: Bool = false,
                quietDeferredFrom: Int64? = nil, quietDeferredUntil: Int64? = nil,
                attempt: Int, runId: String) {
        self.status = status
        self.text = text
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationMs = durationMs
        self.scheduledFor = scheduledFor
        self.lateByMs = lateByMs
        self.quiet = quiet
        self.quietDeferredFrom = quietDeferredFrom
        self.quietDeferredUntil = quietDeferredUntil
        self.attempt = attempt
        self.runId = runId
    }
}

public struct RoutineSkip: Codable, Sendable, Equatable {
    public var reason: String
    public var at: Int64
    public var triggerAt: Int64?
    public var runningAttempt: Int?
    public var runningRunId: String?

    enum CodingKeys: String, CodingKey {
        case reason, at
        case triggerAt = "trigger_at"
        case runningAttempt = "running_attempt"
        case runningRunId = "running_run_id"
    }

    public init(reason: String, at: Int64, triggerAt: Int64? = nil,
                runningAttempt: Int? = nil, runningRunId: String? = nil) {
        self.reason = reason
        self.at = at
        self.triggerAt = triggerAt
        self.runningAttempt = runningAttempt
        self.runningRunId = runningRunId
    }
}

public struct Routine: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var agentId: String
    public var title: String
    public var prompt: String
    public var schedule: RoutineSchedule
    public var enabled: Bool
    public var idempotent: Bool
    public var urgent: Bool
    public var urgentReason: String
    public var delivery: RoutineDeliveryMode
    public var interruptReason: String
    public var createdAt: Int64
    public var attempt: Int
    public var runState: RoutineRunState?
    public var quietDefer: RoutineQuietDefer?
    public var lastSkip: RoutineSkip?
    public var skipCount: Int
    public var crashRetry: Bool
    public var lastRunAt: Int64?
    public var nextRunAt: Int64?
    public var lastResult: RoutineResult?

    enum CodingKeys: String, CodingKey {
        case id, agentId, title, prompt, schedule, enabled, idempotent, urgent, delivery, attempt
        case urgentReason = "urgent_reason"
        case interruptReason = "interrupt_reason"
        case createdAt = "created_at"
        case runState = "run_state"
        case quietDefer = "quiet_defer"
        case lastSkip = "last_skip"
        case skipCount = "skip_count"
        case crashRetry = "crash_retry"
        case lastRunAt = "last_run_at"
        case nextRunAt = "next_run_at"
        case lastResult = "last_result"
    }

    public init(id: String, agentId: String, title: String, prompt: String, schedule: RoutineSchedule,
                enabled: Bool = true, idempotent: Bool = false, urgent: Bool = false,
                urgentReason: String = "", delivery: RoutineDeliveryMode = .held,
                interruptReason: String = "", createdAt: Int64, attempt: Int = 0,
                runState: RoutineRunState? = nil, quietDefer: RoutineQuietDefer? = nil,
                lastSkip: RoutineSkip? = nil, skipCount: Int = 0, crashRetry: Bool = false,
                lastRunAt: Int64? = nil, nextRunAt: Int64? = nil, lastResult: RoutineResult? = nil) {
        self.id = id
        self.agentId = agentId
        self.title = title
        self.prompt = prompt
        self.schedule = schedule
        self.enabled = enabled
        self.idempotent = idempotent
        self.urgent = urgent
        self.urgentReason = urgentReason
        self.delivery = delivery
        self.interruptReason = interruptReason
        self.createdAt = createdAt
        self.attempt = attempt
        self.runState = runState
        self.quietDefer = quietDefer
        self.lastSkip = lastSkip
        self.skipCount = skipCount
        self.crashRetry = crashRetry
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.lastResult = lastResult
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        agentId = try container.decode(String.self, forKey: .agentId)
        title = try container.decode(String.self, forKey: .title)
        prompt = try container.decode(String.self, forKey: .prompt)
        schedule = try container.decode(RoutineSchedule.self, forKey: .schedule)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        idempotent = try container.decodeIfPresent(Bool.self, forKey: .idempotent) ?? false
        urgent = try container.decodeIfPresent(Bool.self, forKey: .urgent) ?? false
        urgentReason = try container.decodeIfPresent(String.self, forKey: .urgentReason) ?? ""
        delivery = try container.decodeIfPresent(RoutineDeliveryMode.self, forKey: .delivery) ?? .held
        interruptReason = try container.decodeIfPresent(String.self, forKey: .interruptReason) ?? ""
        createdAt = try container.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        attempt = try container.decodeIfPresent(Int.self, forKey: .attempt) ?? 0
        runState = try container.decodeIfPresent(RoutineRunState.self, forKey: .runState)
        quietDefer = try container.decodeIfPresent(RoutineQuietDefer.self, forKey: .quietDefer)
        lastSkip = try container.decodeIfPresent(RoutineSkip.self, forKey: .lastSkip)
        skipCount = try container.decodeIfPresent(Int.self, forKey: .skipCount) ?? 0
        crashRetry = try container.decodeIfPresent(Bool.self, forKey: .crashRetry) ?? false
        lastRunAt = try container.decodeIfPresent(Int64.self, forKey: .lastRunAt)
        nextRunAt = try container.decodeIfPresent(Int64.self, forKey: .nextRunAt)
        lastResult = try container.decodeIfPresent(RoutineResult.self, forKey: .lastResult)
    }

    public func validated() throws -> Routine {
        var copy = self
        copy.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.agentId = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.title = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        copy.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.id.isEmpty, !copy.agentId.isEmpty else { throw RoutineError.invalidRoutine("routine id and agentId are required") }
        guard !copy.title.isEmpty, copy.title.count <= 200 else {
            throw RoutineError.invalidRoutine(copy.title.isEmpty ? "routine title must be a non-empty string" : "routine title is too long (max 200 characters)")
        }
        guard !copy.prompt.isEmpty, copy.prompt.count <= 20_000 else {
            throw RoutineError.invalidRoutine(copy.prompt.isEmpty ? "routine prompt must be a non-empty string" : "routine prompt is too long (max 20000 characters)")
        }
        copy.schedule = try schedule.validated()
        let flags = try RoutineDeliveryFlags(urgent: urgent, urgentReason: urgentReason,
                                             delivery: delivery, interruptReason: interruptReason)
        copy.urgent = flags.urgent
        copy.urgentReason = flags.urgentReason
        copy.delivery = flags.delivery
        copy.interruptReason = flags.interruptReason
        return copy
    }
}

public struct RoutineDeliveryFlags: Codable, Sendable, Equatable {
    public var urgent: Bool
    public var urgentReason: String
    public var delivery: RoutineDeliveryMode
    public var interruptReason: String

    enum CodingKeys: String, CodingKey {
        case urgent, delivery
        case urgentReason = "urgent_reason"
        case interruptReason = "interrupt_reason"
    }

    public init(urgent: Bool = false, urgentReason: String = "", delivery: RoutineDeliveryMode = .held,
                interruptReason: String = "") throws {
        let cleanUrgent = Self.clean(urgentReason)
        let cleanInterrupt = Self.clean(interruptReason)
        if urgent && cleanUrgent.isEmpty { throw RoutineError.urgentReasonRequired }
        if delivery == .interrupt && cleanInterrupt.isEmpty { throw RoutineError.interruptReasonRequired }
        self.urgent = urgent
        self.urgentReason = cleanUrgent
        self.delivery = delivery
        self.interruptReason = cleanInterrupt
    }

    public static func clean(_ value: String) -> String {
        let collapsed = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(500))
    }
}

public enum RoutineDeliveryStatus: String, Codable, Sendable {
    case pending
    case delivering
    case delivered
    case failed
}

public struct RoutineDelivery: Codable, Sendable, Equatable {
    public var deliveryKey: String
    public var routineId: String
    public var agentId: String
    public var attempt: Int
    public var runId: String
    public var status: RoutineDeliveryStatus
    public var resultStatus: RoutineRunStatus
    public var text: String
    public var error: String?
    public var routineTitle: String
    public var context: String
    public var delivery: RoutineDeliveryMode
    public var quiet: Bool
    public var urgent: Bool
    public var urgentReason: String
    public var notified: String?
    public var notifyReason: String?
    public var notifiedAt: Int64?
    public var proactiveHandled: Bool
    public var proactiveMode: String?
    public var cancelOrigin: String?
    public var heldInbox: String?
    public var heldInboxError: String?
    public var quietDeferredFrom: Int64?
    public var quietDeferredUntil: Int64?
    public var scheduledFor: Int64?
    public var lateByMs: Int64
    public var startedAt: Int64
    public var finishedAt: Int64
    public var durationMs: Int64
    public var nextRunAt: Int64?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deliveredAt: Int64?
    public var failedAt: Int64?
    public var lastError: String?
    public var attempts: Int
    public var leaseOwner: String?
    public var leaseExpiresAt: Int64?

    public init(deliveryKey: String, routineId: String, agentId: String, attempt: Int, runId: String,
                status: RoutineDeliveryStatus = .pending, resultStatus: RoutineRunStatus,
                text: String = "", error: String? = nil, routineTitle: String, context: String = "",
                delivery: RoutineDeliveryMode, quiet: Bool = false, urgent: Bool = false,
                urgentReason: String = "", notified: String? = nil, notifyReason: String? = nil,
                notifiedAt: Int64? = nil, proactiveHandled: Bool = false, proactiveMode: String? = nil,
                cancelOrigin: String? = nil, heldInbox: String? = nil, heldInboxError: String? = nil,
                quietDeferredFrom: Int64? = nil, quietDeferredUntil: Int64? = nil,
                scheduledFor: Int64? = nil, lateByMs: Int64 = 0, startedAt: Int64,
                finishedAt: Int64, durationMs: Int64 = 0, nextRunAt: Int64? = nil,
                createdAt: Int64, updatedAt: Int64, deliveredAt: Int64? = nil,
                failedAt: Int64? = nil, lastError: String? = nil, attempts: Int = 0,
                leaseOwner: String? = nil, leaseExpiresAt: Int64? = nil) {
        self.deliveryKey = deliveryKey
        self.routineId = routineId
        self.agentId = agentId
        self.attempt = attempt
        self.runId = runId
        self.status = status
        self.resultStatus = resultStatus
        self.text = text
        self.error = error
        self.routineTitle = routineTitle
        self.context = context
        self.delivery = delivery
        self.quiet = quiet
        self.urgent = urgent
        self.urgentReason = urgentReason
        self.notified = notified
        self.notifyReason = notifyReason
        self.notifiedAt = notifiedAt
        self.proactiveHandled = proactiveHandled
        self.proactiveMode = proactiveMode
        self.cancelOrigin = cancelOrigin
        self.heldInbox = heldInbox
        self.heldInboxError = heldInboxError
        self.quietDeferredFrom = quietDeferredFrom
        self.quietDeferredUntil = quietDeferredUntil
        self.scheduledFor = scheduledFor
        self.lateByMs = lateByMs
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationMs = durationMs
        self.nextRunAt = nextRunAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deliveredAt = deliveredAt
        self.failedAt = failedAt
        self.lastError = lastError
        self.attempts = attempts
        self.leaseOwner = leaseOwner
        self.leaseExpiresAt = leaseExpiresAt
    }

    public static func key(routineId: String, attempt: Int) -> String {
        "\(routineId):\(max(0, attempt))"
    }

    public static func rowId(routineId: String, attempt: Int) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let mapped = String(routineId.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let safe = String(mapped.prefix(80))
        return "routine-run-\(safe.isEmpty ? "routine" : safe)-\(max(0, attempt))"
    }
}

public struct RoutineDocument: Codable, Sendable, Equatable {
    public var version: Int
    public var routines: [Routine]
    public var deliveries: [String: RoutineDelivery]

    public init(version: Int = 1, routines: [Routine] = [], deliveries: [String: RoutineDelivery] = [:]) {
        self.version = version
        self.routines = routines
        self.deliveries = deliveries
    }
}

public struct RoutinePatch: Sendable {
    public var title: String?
    public var prompt: String?
    public var schedule: RoutineSchedule?
    public var enabled: Bool?
    public var idempotent: Bool?
    public var urgent: Bool?
    public var urgentReason: String?
    public var delivery: RoutineDeliveryMode?
    public var interruptReason: String?

    public init(title: String? = nil, prompt: String? = nil, schedule: RoutineSchedule? = nil,
                enabled: Bool? = nil, idempotent: Bool? = nil, urgent: Bool? = nil,
                urgentReason: String? = nil, delivery: RoutineDeliveryMode? = nil,
                interruptReason: String? = nil) {
        self.title = title
        self.prompt = prompt
        self.schedule = schedule
        self.enabled = enabled
        self.idempotent = idempotent
        self.urgent = urgent
        self.urgentReason = urgentReason
        self.delivery = delivery
        self.interruptReason = interruptReason
    }
}
