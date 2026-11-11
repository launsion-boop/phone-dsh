// SPDX-License-Identifier: MIT

import Foundation

/// The retained hard limits for proactive delivery: the frequency fuse.
///
/// Daily budget, per-category quotas, cooldowns, TTLs and the dedupe window
/// were removed by PC-20261111-bot-v2-unwired. DND and quiet hours are read
/// from `ProactiveSettings` directly by `ProactivityPolicy`.
public struct ProactivePolicyConfiguration: Sendable, Equatable {
    public var fuseWindowMs: Int64
    public var fuseMaxWakeups: Int

    public init(fuseWindowMs: Int64 = 900_000, fuseMaxWakeups: Int = 4) {
        self.fuseWindowMs = fuseWindowMs
        self.fuseMaxWakeups = fuseMaxWakeups
    }
}

struct AcceptedConsideration: Sendable {
    var at: Int64
    var kind: ProactiveKind
    var botId: String
    var fuseRecorded: Bool
}

struct ProactivePolicyCheck {
    var allowed: Bool
    var reason: String
}

struct ProactivityPolicy {
    var configuration: ProactivePolicyConfiguration
    private(set) var accepted: [AcceptedConsideration] = []

    init(configuration: ProactivePolicyConfiguration = ProactivePolicyConfiguration()) {
        self.configuration = configuration
    }

    func check(_ candidate: ProactiveCandidate, now: Int64,
               settings: ProactiveSettings) -> ProactivePolicyCheck {
        let botId = candidate.botId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !botId.isEmpty else { return .init(allowed: false, reason: "missing-bot") }
        let explicitReminderException = candidate.kind == .reminder && candidate.allowDuringDnd
            && !(candidate.reminderId ?? "").isEmpty
        if settings.dnd && !explicitReminderException {
            return .init(allowed: false, reason: "dnd")
        }
        if !explicitReminderException,
           RoutineQuietHours.isWithinQuietHours(now, start: settings.quietStart,
                                                end: settings.quietEnd,
                                                timeZone: settings.timeZone) {
            return .init(allowed: false, reason: "quiet-hours")
        }
        return .init(allowed: true, reason: "allowed")
    }

    func fuseTripped(botId: String, now: Int64) -> Bool {
        accepted.filter {
            $0.fuseRecorded && $0.botId == botId && now - $0.at < configuration.fuseWindowMs
        }.count >= configuration.fuseMaxWakeups
    }

    mutating func commit(_ candidate: ProactiveCandidate, now: Int64, fuseRecorded: Bool) {
        accepted.append(AcceptedConsideration(at: now, kind: candidate.kind,
                                              botId: candidate.botId,
                                              fuseRecorded: fuseRecorded))
    }

    mutating func restore(_ consideration: AcceptedConsideration) {
        accepted.append(consideration)
    }
}
