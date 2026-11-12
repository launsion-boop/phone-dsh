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
                deliverer: (any ProactiveDelivering)? = nil,
                eventLog: (any BotEventLog)? = nil,
                deliveryKinds: Set<ProactiveKind> = [.taskDone, .routineResult]) {
        self.settingsProvider = settings
        self.nowProvider = now
        self.policy = ProactivityPolicy(configuration: policy)
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

    /// Rebuild the retained frequency-fuse accounting from durable events.
    ///
    /// Only events inside the fuse window matter: budget, quota, cooldown,
    /// TTL and dedupe-window bookkeeping was removed by PC-20261111-bot-v2-unwired.
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
            let windowStart = now - policy.configuration.fuseWindowMs
            let accepted = events.filter { event in
                guard event.type == "proactive.considered",
                      event.time >= windowStart,
                      let decision = Self.string(event.data, "decision") else { return false }
                return decision == "did" || decision == "would"
            }.sorted {
                ($0.time, $0.commitSeq ?? 0) < ($1.time, $1.commitSeq ?? 0)
            }
            var considerations: [AcceptedConsideration] = []
            for event in accepted {
                guard let kindText = Self.string(event.data, "kind"),
                      let botId = Self.string(event.data, "botId") ?? event.principal.botId,
                      !botId.isEmpty else {
                    throw RestoreError.malformedConsideration(event.eventId)
                }
                // Removed/unknown kinds (for example the deleted idle-checkin
                // source) must not make the retained fuse accounting unreadable.
                guard let kind = ProactiveKind(rawValue: kindText) else { continue }
                let decision = Self.string(event.data, "decision") ?? "skip"
                let mode = Self.string(event.data, "mode") ?? ""
                let historicalFuse = mode == "would" || decision == "did"
                considerations.append(AcceptedConsideration(
                    at: event.time, kind: kind, botId: botId,
                    fuseRecorded: Self.bool(event.data, "fuseRecorded") ?? historicalFuse
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

    private func perform(_ candidate: ProactiveCandidate) async -> ProactiveDecision {
        let at = nowProvider()
        let settings = settingsProvider().normalized()
        if candidate.kind == .routineResult {
            if candidate.delivery != .interrupt {
                return await finish(candidate, at: at, settings: settings, decision: .skip,
                                    reason: "routine-held")
            }
            if candidate.quiet {
                return await finish(candidate, at: at, settings: settings, decision: .skip,
                                    reason: "routine-quiet")
            }
        }
        if settings.mode == .off {
            return await finish(candidate, at: at, settings: settings, decision: .skip,
                                reason: "mode-off")
        }
        let deliverable = settings.mode == .on && deliveryKinds.contains(candidate.kind)
        let check = policy.check(candidate, now: at, settings: settings)
        guard check.allowed else {
            return await finish(candidate, at: at, settings: settings, decision: .skip,
                                reason: check.reason)
        }
        let fuseApplies = settings.mode == .would || deliverable
        if fuseApplies && policy.fuseTripped(botId: candidate.botId, now: at) {
            return await finish(candidate, at: at, settings: settings, decision: .skip,
                                reason: "fuse")
        }

        let notification = Self.notification(candidate, dedupeKey: Self.deliveryKey(candidate, at: at))
        var decision: ProactiveDecisionKind = .would
        var delivery: ProactiveDeliveryResult?
        if deliverable {
            guard let deliverer else {
                return await finish(candidate, at: at, settings: settings, decision: .skip,
                                    reason: "delivery-unavailable", notification: notification)
            }
            do {
                let result = try await deliverer.deliver(notification)
                delivery = result
                guard result.delivered else {
                    return await finish(candidate, at: at, settings: settings, decision: .skip,
                                        reason: "delivery-failed", notification: notification, delivery: result)
                }
                decision = .did
            } catch {
                let result = ProactiveDeliveryResult(delivered: false, error: error.localizedDescription)
                return await finish(candidate, at: at, settings: settings, decision: .skip,
                                    reason: "delivery-failed", notification: notification, delivery: result)
            }
        }
        policy.commit(candidate, now: at, fuseRecorded: decision == .did || settings.mode == .would)
        let reason = decision == .did ? "delivered" : settings.mode == .would ? "would-mode" : "would-only-kind"
        return await finish(candidate, at: at, settings: settings, decision: decision,
                            reason: reason, notification: notification, delivery: delivery)
    }

    private func finish(_ candidate: ProactiveCandidate, at: Int64, settings: ProactiveSettings,
                        decision: ProactiveDecisionKind, reason: String,
                        notification: ProactiveNotification? = nil,
                        delivery: ProactiveDeliveryResult? = nil) async -> ProactiveDecision {
        sequence += 1
        let dedupeKey = Self.deliveryKey(candidate, at: at)
        let resolvedNotification = notification ?? Self.notification(candidate, dedupeKey: dedupeKey)
        var record = ProactiveDecision(
            id: "proactive:\(at):\(sequence)", at: at, decision: decision, reason: reason,
            kind: candidate.kind, botId: candidate.botId,
            dedupeKey: dedupeKey,
            mode: settings.mode, channel: candidate.channel,
            notification: resolvedNotification, delivery: delivery
        )
        history.append(record)
        if history.count > 200 { history.removeFirst(history.count - 200) }
        if let eventLog {
            let fuseRecorded = settings.mode == .would || decision == .did
            var data: [String: BotJSONValue] = [
                "decision": .string(decision.rawValue),
                "reason": .string(reason),
                "kind": .string(candidate.kind.rawValue),
                "category": .string(candidate.kind.rawValue),
                "botId": .string(candidate.botId),
                "mode": .string(settings.mode.rawValue),
                "channel": .string(record.channel),
                "fuseRecorded": .bool(fuseRecorded),
            ]
            if let trigger = candidate.trigger { data["trigger"] = .string(trigger) }
            data["dedupeKey"] = .string(dedupeKey)
            let event = BotEvent(type: "proactive.considered", eventId: record.id, time: at,
                                 origin: .local(source: "runtime"), traceId: "trace:\(record.id)",
                                 principal: BotPrincipal(botId: candidate.botId, sessionId: nil, kind: "proactive"),
                                 causationId: candidate.sourceEventId, correlationId: dedupeKey,
                                 data: .object(data))
            if let commitSeq = try? await eventLog.append(event) {
                record.commitSeq = commitSeq
                history[history.count - 1] = record
            }
        }
        return record
    }

    /// Stable notification identifier. It is not a suppression window: the
    /// candidate is still considered on every event.
    private static func deliveryKey(_ candidate: ProactiveCandidate, at: Int64) -> String {
        if let explicit = candidate.dedupeKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        let payload = candidate.taskId ?? candidate.runId ?? candidate.reminderId ?? candidate.id ?? ""
        return "\(candidate.kind.rawValue):\(candidate.botId):\(payload.isEmpty ? String(at) : payload)"
    }

    private static func notification(_ candidate: ProactiveCandidate,
                                     dedupeKey: String) -> ProactiveNotification {
        let explicitTitle = candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitBody = candidate.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        let body: String
        switch candidate.kind {
        case .taskDone:
            title = explicitTitle?.isEmpty == false ? explicitTitle! : "DSH Bot · 后台任务"
            body = explicitBody?.isEmpty == false ? explicitBody!
                : candidate.summary ?? candidate.taskTitle ?? "任务 \(candidate.taskId ?? "") \(statusLabel(candidate.status))"
        case .routineResult:
            title = explicitTitle?.isEmpty == false ? explicitTitle! : "DSH Bot · 定时执行"
            body = explicitBody?.isEmpty == false ? explicitBody!
                : candidate.resultExcerpt.map { RoutineScheduleMath.summarize($0) }
                    ?? "例行任务 \(candidate.routineId ?? "") \(statusLabel(candidate.status))"
        case .reminder:
            title = explicitTitle?.isEmpty == false ? explicitTitle! : "DSH Bot · 提醒"
            body = explicitBody?.isEmpty == false ? explicitBody! : "提醒时间到了"
        }
        return ProactiveNotification(title: title, body: body, kind: candidate.kind,
                                     botId: candidate.botId, dedupeKey: dedupeKey,
                                     channel: candidate.channel, rowId: candidate.rowId)
    }

    private static func statusLabel(_ status: String?) -> String {
        switch status?.lowercased() {
        case "completed", "succeeded", "ok", "sent": return "已完成"
        case "stopped", "canceled", "cancelled": return "已停止"
        case "timed_out", "timeout", "timed-out": return "超时"
        case "error", "failed", "failure": return "失败"
        default: return status ?? "已结束"
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
}
