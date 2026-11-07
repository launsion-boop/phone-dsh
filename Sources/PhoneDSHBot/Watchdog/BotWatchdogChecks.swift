// SPDX-License-Identifier: MIT

import Foundation

public enum BotWatchdogChecks {
    public static func run(
        unit: BotWatchdogUnit,
        now: Int64,
        config: BotWatchdogConfig = .default
    ) -> [BotWatchdogFinding] {
        var findings: [BotWatchdogFinding] = []
        if let finding = deadline(unit: unit, now: now) { findings.append(finding) }
        if let finding = heartbeat(unit: unit, now: now, config: config) { findings.append(finding) }
        if let finding = repeatedToolSignature(unit: unit, config: config) { findings.append(finding) }
        if let finding = repeatedToolError(unit: unit, config: config) { findings.append(finding) }
        if let finding = quota(unit: unit, config: config) { findings.append(finding) }
        return findings
    }

    public static func deadline(unit: BotWatchdogUnit, now: Int64) -> BotWatchdogFinding? {
        guard let deadlineAt = unit.deadlineAt, deadlineAt > 0, now > deadlineAt else { return nil }
        return BotWatchdogFinding(check: .deadline, evidence: [
            "deadlineAt": botWatchdogNumber(deadlineAt),
            "now": botWatchdogNumber(now),
            "elapsedMs": botWatchdogNumber(max(0, now - unit.startedAt)),
        ])
    }

    public static func heartbeat(
        unit: BotWatchdogUnit,
        now: Int64,
        config: BotWatchdogConfig = .default
    ) -> BotWatchdogFinding? {
        guard unit.pendingApproval <= 0, config.heartbeatTimeoutMs > 0 else { return nil }
        let lastEventAt = unit.lastEventAt ?? unit.startedAt
        let silentMs = now - lastEventAt
        guard silentMs > config.heartbeatTimeoutMs else { return nil }
        return BotWatchdogFinding(check: .heartbeat, evidence: [
            "lastEventAt": botWatchdogNumber(lastEventAt),
            "now": botWatchdogNumber(now),
            "silentMs": botWatchdogNumber(silentMs),
            "thresholdMs": botWatchdogNumber(config.heartbeatTimeoutMs),
        ])
    }

    public static func repeatedToolSignature(
        unit: BotWatchdogUnit,
        config: BotWatchdogConfig = .default
    ) -> BotWatchdogFinding? {
        guard config.repeatedToolCalls > 0,
              unit.repeatedToolSignatureCount >= config.repeatedToolCalls else { return nil }
        return BotWatchdogFinding(check: .repeatedToolSignature, evidence: [
            "signature": botWatchdogString(unit.lastToolSignature),
            "count": botWatchdogNumber(unit.repeatedToolSignatureCount),
            "threshold": botWatchdogNumber(config.repeatedToolCalls),
        ])
    }

    public static func repeatedToolError(
        unit: BotWatchdogUnit,
        config: BotWatchdogConfig = .default
    ) -> BotWatchdogFinding? {
        guard config.repeatedToolErrors > 0,
              unit.repeatedToolErrorCount >= config.repeatedToolErrors else { return nil }
        return BotWatchdogFinding(check: .repeatedToolError, evidence: [
            "errorSignature": botWatchdogString(unit.lastToolErrorSignature),
            "count": botWatchdogNumber(unit.repeatedToolErrorCount),
            "threshold": botWatchdogNumber(config.repeatedToolErrors),
        ])
    }

    public static func quota(
        unit: BotWatchdogUnit,
        config: BotWatchdogConfig = .default
    ) -> BotWatchdogFinding? {
        let tokens = max(0, unit.tokens)
        let cost = max(0, unit.costUsd)
        let overTokens = config.maxUnitTokens > 0 && tokens > config.maxUnitTokens
        let overCost = config.maxUnitCostUsd > 0 && cost > config.maxUnitCostUsd
        guard overTokens || overCost else { return nil }
        let reason = overTokens && overCost ? "tokens_and_cost" : (overTokens ? "tokens" : "cost")
        return BotWatchdogFinding(check: .quota, evidence: [
            "tokens": botWatchdogNumber(tokens),
            "maxTokens": botWatchdogNumber(config.maxUnitTokens),
            "costUsd": botWatchdogNumber(cost),
            "maxCostUsd": botWatchdogNumber(config.maxUnitCostUsd),
            "reason": .string(reason),
        ])
    }
}
