// SPDX-License-Identifier: MIT

import Foundation

public struct ProactivePolicyConfiguration: Sendable, Equatable {
    public var dailyBudget: Int
    public var quotas: [ProactiveKind: Int]
    public var cooldownsMs: [ProactiveKind: Int64]
    public var ttlsMs: [ProactiveKind: Int64]
    public var dedupeTTLMs: Int64
    public var fuseWindowMs: Int64
    public var fuseMaxWakeups: Int

    public init(dailyBudget: Int = 12,
                quotas: [ProactiveKind: Int] = [.taskDone: 6, .routineResult: 6, .idleCheckin: 2, .reminder: 20],
                cooldownsMs: [ProactiveKind: Int64] = [.taskDone: 600_000, .routineResult: 900_000,
                                                        .idleCheckin: 5_400_000, .reminder: 60_000],
                ttlsMs: [ProactiveKind: Int64] = [.taskDone: 86_400_000, .routineResult: 21_600_000,
                                                   .idleCheckin: 1_800_000, .reminder: 86_400_000],
                dedupeTTLMs: Int64 = 86_400_000, fuseWindowMs: Int64 = 900_000,
                fuseMaxWakeups: Int = 4) {
        self.dailyBudget = dailyBudget
        self.quotas = quotas
        self.cooldownsMs = cooldownsMs
        self.ttlsMs = ttlsMs
        self.dedupeTTLMs = dedupeTTLMs
        self.fuseWindowMs = fuseWindowMs
        self.fuseMaxWakeups = fuseMaxWakeups
    }
}

struct AcceptedConsideration: Sendable {
    var at: Int64
    var kind: ProactiveKind
    var botId: String
    var dedupeKey: String
    var cost: Int
    var channel: String
    var spendBudget: Bool
    var fuseRecorded: Bool
}

struct ProactivePolicyCheck {
    var allowed: Bool
    var reason: String
    var dedupeKey: String
    var cost: Int
    var channel: String
}

struct ProactivityPolicy {
    var configuration: ProactivePolicyConfiguration
    private(set) var accepted: [AcceptedConsideration] = []

    init(configuration: ProactivePolicyConfiguration = ProactivePolicyConfiguration()) {
        self.configuration = configuration
    }

    func check(_ candidate: ProactiveCandidate, now: Int64, settings: ProactiveSettings,
               checkBudget: Bool) -> ProactivePolicyCheck {
        let botId = candidate.botId.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = dedupeKey(candidate, now: now)
        let cost = max(1, candidate.cost)
        guard !botId.isEmpty else { return .init(allowed: false, reason: "missing-bot", dedupeKey: key, cost: cost, channel: candidate.channel) }
        let explicitReminderException = candidate.kind == .reminder && candidate.allowDuringDnd && !(candidate.reminderId ?? "").isEmpty
        if settings.dnd && !explicitReminderException {
            return .init(allowed: false, reason: "dnd", dedupeKey: key, cost: cost, channel: candidate.channel)
        }
        if !explicitReminderException,
           RoutineQuietHours.isWithinQuietHours(now, start: settings.quietStart, end: settings.quietEnd,
                                                timeZone: settings.timeZone) {
            return .init(allowed: false, reason: "quiet-hours", dedupeKey: key, cost: cost, channel: candidate.channel)
        }
        if accepted.contains(where: { $0.dedupeKey == key && now - $0.at < configuration.dedupeTTLMs }) {
            return .init(allowed: false, reason: "duplicate", dedupeKey: key, cost: cost, channel: candidate.channel)
        }
        let ttl = candidate.ttlMs ?? configuration.ttlsMs[candidate.kind] ?? 0
        if ttl > 0, now - candidate.createdAt > ttl {
            return .init(allowed: false, reason: "ttl-expired", dedupeKey: key, cost: cost, channel: candidate.channel)
        }
        let day = RoutineQuietHours.dayKey(now, timeZone: settings.timeZone)
        let quotaUsed = accepted.filter {
            $0.botId == botId && $0.kind == candidate.kind &&
            RoutineQuietHours.dayKey($0.at, timeZone: settings.timeZone) == day
        }.count
        let quotaLimit = configuration.quotas[candidate.kind] ?? 0
        if quotaUsed >= quotaLimit {
            return .init(allowed: false, reason: "quota", dedupeKey: key, cost: cost, channel: candidate.channel)
        }
        if let last = accepted.filter({ $0.botId == botId && $0.kind == candidate.kind }).map(\.at).max(),
           let cooldown = configuration.cooldownsMs[candidate.kind], cooldown > 0, now - last < cooldown {
            return .init(allowed: false, reason: "cooldown", dedupeKey: key, cost: cost, channel: candidate.channel)
        }
        if checkBudget, configuration.dailyBudget > 0 {
            let spent = accepted.filter {
                $0.spendBudget && RoutineQuietHours.dayKey($0.at, timeZone: settings.timeZone) == day
            }.reduce(0) { $0 + $1.cost }
            if spent + cost > configuration.dailyBudget {
                return .init(allowed: false, reason: "global-budget", dedupeKey: key, cost: cost, channel: candidate.channel)
            }
        }
        return .init(allowed: true, reason: "allowed", dedupeKey: key, cost: cost, channel: candidate.channel)
    }

    func fuseTripped(botId: String, now: Int64) -> Bool {
        accepted.filter {
            $0.fuseRecorded && $0.botId == botId && now - $0.at < configuration.fuseWindowMs
        }.count >= configuration.fuseMaxWakeups
    }

    mutating func commit(_ candidate: ProactiveCandidate, check: ProactivePolicyCheck,
                         now: Int64, spendBudget: Bool, fuseRecorded: Bool) {
        accepted.append(AcceptedConsideration(at: now, kind: candidate.kind, botId: candidate.botId,
                                              dedupeKey: check.dedupeKey, cost: check.cost,
                                              channel: check.channel, spendBudget: spendBudget,
                                              fuseRecorded: fuseRecorded))
    }

    mutating func restore(_ consideration: AcceptedConsideration) {
        accepted.append(consideration)
    }

    func budgetSpent(now: Int64, timeZone: String) -> Int {
        let day = RoutineQuietHours.dayKey(now, timeZone: timeZone)
        return accepted.filter {
            $0.spendBudget && RoutineQuietHours.dayKey($0.at, timeZone: timeZone) == day
        }.reduce(0) { $0 + $1.cost }
    }

    private func dedupeKey(_ candidate: ProactiveCandidate, now: Int64) -> String {
        if let explicit = candidate.dedupeKey?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        let payload = candidate.taskId ?? candidate.runId ?? candidate.reminderId ?? candidate.id ?? ""
        return "\(candidate.kind.rawValue):\(candidate.botId):\(payload.isEmpty ? String(now) : payload)"
    }
}
