// SPDX-License-Identifier: MIT

import Foundation

public struct ProactiveReminder: Sendable, Equatable {
    public var reminderId: String
    public var botId: String
    public var text: String
    public var dueAt: Int64
    public var ttlMs: Int64
    public var allowDuringDnd: Bool
    public var dedupeKey: String

    public init(reminderId: String, botId: String, text: String, dueAt: Int64,
                ttlMs: Int64 = 86_400_000, allowDuringDnd: Bool = false,
                dedupeKey: String? = nil) {
        self.reminderId = reminderId
        self.botId = botId
        self.text = text
        self.dueAt = dueAt
        self.ttlMs = ttlMs
        self.allowDuringDnd = allowDuringDnd
        self.dedupeKey = dedupeKey ?? "reminder:\(reminderId)"
    }
}

public actor ProactiveSources {
    private let nowProvider: @Sendable () -> Int64
    private let idleAfterMs: Int64
    private var lastActivity: [String: Int64] = [:]
    private var idleEmitted: [String: Int64] = [:]
    private var reminders: [String: ProactiveReminder] = [:]

    public init(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                idleAfterMs: Int64 = 2_700_000) {
        self.nowProvider = now
        self.idleAfterMs = max(0, idleAfterMs)
    }

    public func candidates(for event: BotEvent) -> [ProactiveCandidate] {
        switch event.type {
        case "conversation.turn_ended":
            guard let botId = botId(event) else { return [] }
            lastActivity[botId] = event.time
            idleEmitted.removeValue(forKey: botId)
            return []
        case "task.settled":
            return taskCandidate(event).map { [$0] } ?? []
        case "routine.run_finished":
            return routineCandidate(event).map { [$0] } ?? []
        default:
            return []
        }
    }

    @discardableResult
    public func addReminder(_ reminder: ProactiveReminder) -> Bool {
        guard reminders[reminder.reminderId] == nil else { return false }
        reminders[reminder.reminderId] = reminder
        return true
    }

    @discardableResult
    public func cancelReminder(_ reminderId: String) -> Bool {
        reminders.removeValue(forKey: reminderId) != nil
    }

    public func pendingReminders() -> [ProactiveReminder] {
        reminders.values.sorted { ($0.dueAt, $0.reminderId) < ($1.dueAt, $1.reminderId) }
    }

    public func tick(now: Int64? = nil) -> [ProactiveCandidate] {
        let at = now ?? nowProvider()
        var result: [ProactiveCandidate] = []
        for entry in reminders.values.sorted(by: { ($0.dueAt, $0.reminderId) < ($1.dueAt, $1.reminderId) }) where entry.dueAt <= at {
            reminders.removeValue(forKey: entry.reminderId)
            result.append(ProactiveCandidate(
                id: "reminder:\(entry.reminderId)", kind: .reminder, botId: entry.botId,
                dedupeKey: entry.dedupeKey, trigger: "reminder.due", createdAt: entry.dueAt,
                ttlMs: entry.ttlMs, body: entry.text, reminderId: entry.reminderId,
                allowDuringDnd: entry.allowDuringDnd
            ))
        }
        for (botId, last) in lastActivity.sorted(by: { $0.key < $1.key }) {
            guard at - last >= idleAfterMs, idleEmitted[botId] != last else { continue }
            idleEmitted[botId] = last
            let key = "idle-checkin:\(botId):\(last)"
            result.append(ProactiveCandidate(
                id: key, kind: .idleCheckin, botId: botId, dedupeKey: key,
                trigger: "idle.tick", createdAt: at, ttlMs: 1_800_000,
                silentForMs: at - last
            ))
        }
        return result
    }

    private func taskCandidate(_ event: BotEvent) -> ProactiveCandidate? {
        guard let botId = botId(event),
              let taskId = Self.string(event.data, "taskId") ?? Self.string(event.data, "task_id") ?? Self.string(event.data, "id"),
              !taskId.isEmpty else { return nil }
        let attempt = max(1, Self.int(event.data, "attempt") ?? 1)
        let status = Self.string(event.data, "status") ?? "unknown"
        let key = "task-done:\(taskId):\(attempt):\(status)"
        return ProactiveCandidate(
            id: key, kind: .taskDone, botId: botId, dedupeKey: key,
            trigger: "task.settled", sourceEventId: event.eventId, createdAt: nowProvider(),
            taskId: taskId, taskTitle: Self.string(event.data, "title") ?? Self.string(event.data, "taskTitle"),
            summary: Self.string(event.data, "summary") ?? Self.string(event.data, "resultExcerpt"),
            status: status
        )
    }

    private func routineCandidate(_ event: BotEvent) -> ProactiveCandidate? {
        guard let botId = botId(event),
              Self.bool(event.data, "proactiveHandled") != true,
              Self.string(event.data, "delivery") == "interrupt",
              Self.bool(event.data, "quiet") != true,
              (Self.string(event.data, "status") ?? "succeeded") == "succeeded",
              let excerpt = Self.string(event.data, "resultExcerpt")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !excerpt.isEmpty,
              let routineId = Self.string(event.data, "routineId") ?? Self.string(event.data, "automationId"),
              !routineId.isEmpty else { return nil }
        let runId = Self.string(event.data, "runId") ?? ""
        let attempt = max(1, Self.int(event.data, "attempt") ?? 1)
        let key = "routine-result:\(routineId):\(runId):\(attempt)"
        let title = Self.string(event.data, "routineTitle") ?? routineId
        return ProactiveCandidate(
            id: key, kind: .routineResult, botId: botId, dedupeKey: key,
            trigger: "routine.run_finished", sourceEventId: event.eventId,
            createdAt: nowProvider(), ttlMs: 21_600_000, title: title,
            body: RoutineScheduleMath.summarize(excerpt), status: "succeeded",
            routineId: routineId, runId: runId, attempt: attempt, delivery: .interrupt,
            resultExcerpt: String(excerpt.prefix(300)), deliveryKey: Self.string(event.data, "deliveryKey"),
            rowId: Self.string(event.data, "rowId") ?? RoutineDelivery.rowId(routineId: routineId, attempt: attempt)
        )
    }

    private func botId(_ event: BotEvent) -> String? {
        let value = Self.string(event.data, "botId") ?? event.principal.botId
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil
    }

    private static func string(_ data: BotJSONValue, _ key: String) -> String? {
        guard case .object(let object) = data, case .string(let value)? = object[key] else { return nil }
        return value
    }

    private static func bool(_ data: BotJSONValue, _ key: String) -> Bool? {
        guard case .object(let object) = data, case .bool(let value)? = object[key] else { return nil }
        return value
    }

    private static func int(_ data: BotJSONValue, _ key: String) -> Int? {
        guard case .object(let object) = data, case .number(let value)? = object[key] else { return nil }
        return Int(value)
    }
}
