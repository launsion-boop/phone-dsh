// SPDX-License-Identifier: MIT

import Foundation

public enum ProactiveKind: String, Codable, Sendable, CaseIterable {
    case taskDone = "task-done"
    case routineResult = "routine-result"
    case idleCheckin = "idle-checkin"
    case reminder
}

public struct ProactiveCandidate: Sendable, Equatable {
    public var id: String?
    public var kind: ProactiveKind
    public var botId: String
    public var dedupeKey: String?
    public var trigger: String?
    public var sourceEventId: String?
    public var createdAt: Int64
    public var ttlMs: Int64?
    public var cost: Int
    public var channel: String
    public var title: String?
    public var body: String?
    public var taskId: String?
    public var taskTitle: String?
    public var summary: String?
    public var status: String?
    public var routineId: String?
    public var runId: String?
    public var attempt: Int?
    public var delivery: RoutineDeliveryMode?
    public var quiet: Bool
    public var resultExcerpt: String?
    public var deliveryKey: String?
    public var rowId: String?
    public var reminderId: String?
    public var allowDuringDnd: Bool
    public var silentForMs: Int64?

    public init(id: String? = nil, kind: ProactiveKind, botId: String, dedupeKey: String? = nil,
                trigger: String? = nil, sourceEventId: String? = nil, createdAt: Int64,
                ttlMs: Int64? = nil, cost: Int = 1, channel: String = "system-notification",
                title: String? = nil, body: String? = nil, taskId: String? = nil,
                taskTitle: String? = nil, summary: String? = nil, status: String? = nil,
                routineId: String? = nil, runId: String? = nil, attempt: Int? = nil,
                delivery: RoutineDeliveryMode? = nil, quiet: Bool = false,
                resultExcerpt: String? = nil, deliveryKey: String? = nil, rowId: String? = nil,
                reminderId: String? = nil, allowDuringDnd: Bool = false, silentForMs: Int64? = nil) {
        self.id = id
        self.kind = kind
        self.botId = botId
        self.dedupeKey = dedupeKey
        self.trigger = trigger
        self.sourceEventId = sourceEventId
        self.createdAt = createdAt
        self.ttlMs = ttlMs
        self.cost = cost
        self.channel = channel
        self.title = title
        self.body = body
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.summary = summary
        self.status = status
        self.routineId = routineId
        self.runId = runId
        self.attempt = attempt
        self.delivery = delivery
        self.quiet = quiet
        self.resultExcerpt = resultExcerpt
        self.deliveryKey = deliveryKey
        self.rowId = rowId
        self.reminderId = reminderId
        self.allowDuringDnd = allowDuringDnd
        self.silentForMs = silentForMs
    }
}

public struct ProactiveNotification: Sendable, Equatable {
    public var title: String
    public var body: String
    public var kind: ProactiveKind
    public var botId: String
    public var dedupeKey: String
    public var channel: String
    public var rowId: String?
    public var deepLink: String?

    public init(title: String, body: String, kind: ProactiveKind, botId: String,
                dedupeKey: String, channel: String = "system-notification", rowId: String? = nil) {
        self.title = String(title.prefix(120))
        self.body = String(body.prefix(500))
        self.kind = kind
        self.botId = botId
        self.dedupeKey = dedupeKey
        self.channel = channel
        self.rowId = rowId
        if let rowId {
            self.deepLink = BotNotificationDeepLink.make(botId: botId, rowId: rowId)
        } else {
            self.deepLink = nil
        }
    }
}

public enum BotNotificationDeepLink {
    public static func make(botId: String, rowId: String) -> String {
        "phonedsh://bot/\(escape(botId))/row/\(escape(rowId))"
    }

    public static func parse(_ value: String) -> (botId: String, rowId: String)? {
        let prefix = "phonedsh://bot/"
        guard value.hasPrefix(prefix) else { return nil }
        let parts = value.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[1] == "row",
              let botId = parts[0].removingPercentEncoding,
              let rowId = parts[2].removingPercentEncoding,
              !botId.isEmpty, !rowId.isEmpty else { return nil }
        return (botId, rowId)
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

public struct ProactiveDeliveryResult: Sendable, Equatable {
    public var delivered: Bool
    public var channel: String
    public var error: String?

    public init(delivered: Bool, channel: String = "system-notification", error: String? = nil) {
        self.delivered = delivered
        self.channel = channel
        self.error = error
    }
}

public protocol ProactiveDelivering: Sendable {
    func deliver(_ notification: ProactiveNotification) async throws -> ProactiveDeliveryResult
}

public struct ProactiveTriageResult: Sendable, Equatable {
    public var allow: Bool
    public var reason: String
    public var source: String

    public init(allow: Bool, reason: String, source: String) {
        self.allow = allow
        self.reason = reason
        self.source = source
    }
}

public protocol ProactiveTriaging: Sendable {
    func evaluate(_ candidate: ProactiveCandidate) async -> ProactiveTriageResult
}

public struct DisabledProactiveTriage: ProactiveTriaging {
    public init() {}
    public func evaluate(_ candidate: ProactiveCandidate) async -> ProactiveTriageResult {
        if candidate.kind == .reminder {
            return ProactiveTriageResult(allow: true, reason: "reminder-skips-triage", source: "policy")
        }
        return ProactiveTriageResult(allow: true, reason: "triage-disabled", source: "config")
    }
}

public enum ProactiveDecisionKind: String, Codable, Sendable {
    case did
    case would
    case skip
}

public struct ProactiveDecision: Sendable, Equatable {
    public var id: String
    public var at: Int64
    public var decision: ProactiveDecisionKind
    public var reason: String
    public var kind: ProactiveKind?
    public var botId: String?
    public var dedupeKey: String?
    public var mode: ProactiveMode
    public var channel: String
    public var cost: Int
    public var notification: ProactiveNotification?
    public var delivery: ProactiveDeliveryResult?
    public var commitSeq: Int?

    public init(id: String, at: Int64, decision: ProactiveDecisionKind, reason: String,
                kind: ProactiveKind?, botId: String?, dedupeKey: String?, mode: ProactiveMode,
                channel: String = "system-notification", cost: Int = 1,
                notification: ProactiveNotification? = nil,
                delivery: ProactiveDeliveryResult? = nil, commitSeq: Int? = nil) {
        self.id = id
        self.at = at
        self.decision = decision
        self.reason = reason
        self.kind = kind
        self.botId = botId
        self.dedupeKey = dedupeKey
        self.mode = mode
        self.channel = channel
        self.cost = cost
        self.notification = notification
        self.delivery = delivery
        self.commitSeq = commitSeq
    }
}

public protocol ProactiveConsidering: Actor {
    func consider(_ candidate: ProactiveCandidate) async -> ProactiveDecision
    @discardableResult
    func restoreAccounting() async -> Int
}
