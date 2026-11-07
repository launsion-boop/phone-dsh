// SPDX-License-Identifier: MIT

import Foundation

public actor ProactiveEngine: ProactiveConsidering {
    private struct Waiting {
        var candidate: ProactiveCandidate
        var continuation: CheckedContinuation<ProactiveDecision, Never>
    }

    private let settingsProvider: @Sendable () -> ProactiveSettings
    private let nowProvider: @Sendable () -> Int64
    private let deliverer: (any ProactiveDelivering)?
    private let triage: any ProactiveTriaging
    private let eventLog: (any BotEventLog)?
    private let deliveryKinds: Set<ProactiveKind>
    private var policy: ProactivityPolicy
    private var waiting: [Waiting] = []
    private var processing = false
    private var sequence = 0
    private var history: [ProactiveDecision] = []
    private var restored = false
    private var restoredCount = 0

    public init(settings: @escaping @Sendable () -> ProactiveSettings = { ProactiveSettings() },
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                policy: ProactivePolicyConfiguration = ProactivePolicyConfiguration(),
                triage: any ProactiveTriaging = DisabledProactiveTriage(),
                deliverer: (any ProactiveDelivering)? = nil,
                eventLog: (any BotEventLog)? = nil,
                deliveryKinds: Set<ProactiveKind> = [.taskDone, .routineResult]) {
        self.settingsProvider = settings
        self.nowProvider = now
        self.policy = ProactivityPolicy(configuration: policy)
        self.triage = triage
        self.deliverer = deliverer
        self.eventLog = eventLog
        self.deliveryKinds = deliveryKinds
    }

    public func consider(_ candidate: ProactiveCandidate) async -> ProactiveDecision {
        if processing {
            return await withCheckedContinuation { continuation in
                waiting.append(Waiting(candidate: candidate, continuation: continuation))
            }
        }
        processing = true
        let result = await perform(candidate)
        while !waiting.isEmpty {
            let next = waiting.removeFirst()
            let decision = await perform(next.candidate)
            next.continuation.resume(returning: decision)
        }
        processing = false
        return result
    }

    public func recent(limit: Int = 50) -> [ProactiveDecision] {
        history.suffix(max(0, limit)).reversed()
    }

    private enum RestoreError: Error {
        case cursorDidNotAdvance
        case malformedConsideration(String)
    }

    @discardableResult
    public func restoreAccounting() async -> Int {
        if restored { return restoredCount }
        guard let eventLog else {
            restored = true
            restoredCount = 0
            return 0
        }
        do {
            var events: [BotEvent] = []
            var cursor = 0
            while true {
                let page = try await eventLog.events(after: cursor, limit: 500)
                if page.isEmpty { break }
                events.append(contentsOf: page)
                guard let next = page.compactMap(\.commitSeq).max(), next > cursor else {
                    throw RestoreError.cursorDidNotAdvance
                }
                cursor = next
                if page.count < 500 { break }
            }
            let now = nowProvider()
            let settings = settingsProvider().normalized()
            let today = RoutineQuietHours.dayKey(now, timeZone: settings.timeZone)
            let accepted = events.filter { event in
                guard event.type == "proactive.considered",
                      RoutineQuietHours.dayKey(event.time, timeZone: settings.timeZone) == today,
                      let decision = Self.string(event.data, "decision") else { return false }
                return decision == "did" || decision == "would"
            }.sorted {
                ($0.time, $0.commitSeq ?? 0) < ($1.time, $1.commitSeq ?? 0)
            }
            var considerations: [AcceptedConsideration] = []
            for event in accepted {
                guard let kindText = Self.string(event.data, "kind"),
                      let kind = ProactiveKind(rawValue: kindText),
                      let botId = Self.string(event.data, "botId") ?? event.principal.botId,
                      !botId.isEmpty else {
                    throw RestoreError.malformedConsideration(event.eventId)
                }
                let dedupeKey = Self.string(event.data, "dedupeKey") ?? event.correlationId ?? event.eventId
                guard !dedupeKey.isEmpty else { throw RestoreError.malformedConsideration(event.eventId) }
                let decision = Self.string(event.data, "decision") ?? "skip"
                let mode = Self.string(event.data, "mode") ?? ""
                let historicalSpend = mode == "would" || decision == "did"
                considerations.append(AcceptedConsideration(
                    at: event.time, kind: kind, botId: botId, dedupeKey: dedupeKey,
                    cost: max(1, Self.int(event.data, "cost") ?? 1),
                    channel: Self.string(event.data, "channel") ?? "system-notification",
                    spendBudget: Self.bool(event.data, "spendBudget") ?? historicalSpend,
                    fuseRecorded: Self.bool(event.data, "fuseRecorded") ?? historicalSpend
                ))
            }
            for consideration in considerations { policy.restore(consideration) }
            restoredCount = considerations.count
            restored = true
            return restoredCount
        } catch {
            return 0
        }
    }

    public func budgetSpent() -> Int {
        policy.budgetSpent(now: nowProvider(), timeZone: settingsProvider().normalized().timeZone)
    }

    private func perform(_ candidate: ProactiveCandidate) async -> ProactiveDecision {
        let at = nowProvider()
        let settings = settingsProvider().normalized()
        if candidate.kind == .routineResult {
            if candidate.delivery != .interrupt {
                return await finish(candidate, at: at, settings: settings, decision: .skip,
                                    reason: "routine-held", check: nil)
            }
            if candidate.quiet {
                return await finish(candidate, at: at, settings: settings, decision: .skip,
                                    reason: "routine-quiet", check: nil)
            }
        }
        if settings.mode == .off {
            return await finish(candidate, at: at, settings: settings, decision: .skip,
                                reason: "mode-off", check: nil)
        }
        let deliverable = settings.mode == .on && deliveryKinds.contains(candidate.kind)
        let spendBudget = settings.mode == .would || deliverable
        let check = policy.check(candidate, now: at, settings: settings, checkBudget: spendBudget)
        guard check.allowed else {
            return await finish(candidate, at: at, settings: settings, decision: .skip,
                                reason: check.reason, check: check)
        }
        let triageResult = await triage.evaluate(candidate)
        if !triageResult.allow {
            return await finish(candidate, at: at, settings: settings, decision: .skip,
                                reason: "triage", check: check)
        }
        let fuseApplies = settings.mode == .would || deliverable
        if fuseApplies && policy.fuseTripped(botId: candidate.botId, now: at) {
            return await finish(candidate, at: at, settings: settings, decision: .skip,
                                reason: "fuse", check: check)
        }

        let notification = Self.notification(candidate, dedupeKey: check.dedupeKey)
        var decision: ProactiveDecisionKind = .would
        var delivery: ProactiveDeliveryResult?
        if deliverable {
            guard let deliverer else {
                return await finish(candidate, at: at, settings: settings, decision: .skip,
                                    reason: "delivery-unavailable", check: check, notification: notification)
            }
            do {
                let result = try await deliverer.deliver(notification)
                delivery = result
                guard result.delivered else {
                    return await finish(candidate, at: at, settings: settings, decision: .skip,
                                        reason: "delivery-failed", check: check,
                                        notification: notification, delivery: result)
                }
                decision = .did
            } catch {
                let result = ProactiveDeliveryResult(delivered: false, error: error.localizedDescription)
                return await finish(candidate, at: at, settings: settings, decision: .skip,
                                    reason: "delivery-failed", check: check,
                                    notification: notification, delivery: result)
            }
        }
        policy.commit(candidate, check: check, now: at, spendBudget: spendBudget,
                      fuseRecorded: decision == .did || settings.mode == .would)
        let reason = decision == .did ? "delivered" : settings.mode == .would ? "would-mode" : "would-only-kind"
        return await finish(candidate, at: at, settings: settings, decision: decision,
                            reason: reason, check: check, notification: notification, delivery: delivery)
    }

    private func finish(_ candidate: ProactiveCandidate, at: Int64, settings: ProactiveSettings,
                        decision: ProactiveDecisionKind, reason: String,
                        check: ProactivePolicyCheck?, notification: ProactiveNotification? = nil,
                        delivery: ProactiveDeliveryResult? = nil) async -> ProactiveDecision {
        sequence += 1
        let resolvedNotification = notification ?? (check.map {
            Self.notification(candidate, dedupeKey: $0.dedupeKey)
        } ?? Self.notification(candidate, dedupeKey: candidate.dedupeKey ?? candidate.id ?? "\(candidate.kind.rawValue):\(candidate.botId):\(at)"))
        var record = ProactiveDecision(
            id: "proactive:\(at):\(sequence)", at: at, decision: decision, reason: reason,
            kind: candidate.kind, botId: candidate.botId,
            dedupeKey: check?.dedupeKey ?? candidate.dedupeKey,
            mode: settings.mode, channel: check?.channel ?? candidate.channel,
            cost: max(1, check?.cost ?? candidate.cost), notification: resolvedNotification,
            delivery: delivery
        )
        history.append(record)
        if history.count > 200 { history.removeFirst(history.count - 200) }
        if let eventLog {
            let spendBudget = settings.mode == .would || decision == .did
            var data: [String: BotJSONValue] = [
                "decision": .string(decision.rawValue),
                "reason": .string(reason),
                "kind": .string(candidate.kind.rawValue),
                "category": .string(candidate.kind.rawValue),
                "botId": .string(candidate.botId),
                "mode": .string(settings.mode.rawValue),
                "channel": .string(record.channel),
                "cost": .number(Double(record.cost)),
                "spendBudget": .bool(spendBudget),
                "fuseRecorded": .bool(spendBudget),
            ]
            if let trigger = candidate.trigger { data["trigger"] = .string(trigger) }
            if let dedupeKey = record.dedupeKey { data["dedupeKey"] = .string(dedupeKey) }
            let event = BotEvent(type: "proactive.considered", eventId: record.id, time: at,
                                 origin: .local(source: "runtime"), traceId: "trace:\(record.id)",
                                 principal: BotPrincipal(botId: candidate.botId, sessionId: nil, kind: "proactive"),
                                 causationId: candidate.sourceEventId, correlationId: record.dedupeKey,
                                 data: .object(data))
            if let commitSeq = try? await eventLog.append(event) {
                record.commitSeq = commitSeq
                history[history.count - 1] = record
            }
        }
        return record
    }

    private static func notification(_ candidate: ProactiveCandidate,
                                     dedupeKey: String) -> ProactiveNotification {
        let explicitTitle = candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitBody = candidate.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        let body: String
        switch candidate.kind {
        case .taskDone:
            title = explicitTitle?.isEmpty == false ? explicitTitle! : "DSH Bot · 背景任務"
            body = explicitBody?.isEmpty == false ? explicitBody!
                : candidate.summary ?? candidate.taskTitle ?? "任務 \(candidate.taskId ?? "") \(statusLabel(candidate.status))"
        case .routineResult:
            title = explicitTitle?.isEmpty == false ? explicitTitle! : "DSH Bot · 排程執行"
            body = explicitBody?.isEmpty == false ? explicitBody!
                : candidate.resultExcerpt.map { RoutineScheduleMath.summarize($0) }
                    ?? "排程 \(candidate.routineId ?? "") \(statusLabel(candidate.status))"
        case .reminder:
            title = explicitTitle?.isEmpty == false ? explicitTitle! : "DSH Bot · 提醒"
            body = explicitBody?.isEmpty == false ? explicitBody! : "提醒時間到了"
        case .idleCheckin:
            title = explicitTitle?.isEmpty == false ? explicitTitle! : "DSH Bot · 好久不見"
            let minutes = max(1, Int((candidate.silentForMs ?? 0) / 60_000))
            body = explicitBody?.isEmpty == false ? explicitBody! : "已經安靜了 \(minutes) 分鐘，要不要聊兩句？"
        }
        return ProactiveNotification(title: title, body: body, kind: candidate.kind,
                                     botId: candidate.botId, dedupeKey: dedupeKey,
                                     channel: candidate.channel, rowId: candidate.rowId)
    }

    private static func statusLabel(_ status: String?) -> String {
        switch status?.lowercased() {
        case "completed", "succeeded", "ok", "sent": return "已完成"
        case "stopped", "canceled", "cancelled": return "已停止"
        case "timed_out", "timeout", "timed-out": return "逾時"
        case "error", "failed", "failure": return "失敗"
        default: return status ?? "已結束"
        }
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
