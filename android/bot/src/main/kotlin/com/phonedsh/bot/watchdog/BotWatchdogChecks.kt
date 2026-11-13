// SPDX-License-Identifier: MIT
package com.phonedsh.bot.watchdog

import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue

/**
 * The five unit-state checks (`spec/bot/v1/watchdog.md` §6). They are pure: a
 * finding never changes the unit and never stops a turn.
 */
public object BotWatchdogChecks {
    public fun run(
        unit: BotWatchdogUnit,
        now: Long,
        config: BotWatchdogConfig = BotWatchdogConfig.DEFAULT,
    ): List<BotWatchdogFinding> = buildList {
        deadline(unit, now)?.let(::add)
        heartbeat(unit, now, config)?.let(::add)
        repeatedToolSignature(unit, config)?.let(::add)
        repeatedToolError(unit, config)?.let(::add)
        quota(unit, config)?.let(::add)
    }

    public fun deadline(unit: BotWatchdogUnit, now: Long): BotWatchdogFinding? {
        val deadlineAt = unit.deadlineAt ?: return null
        if (deadlineAt <= 0 || now <= deadlineAt) return null
        return BotWatchdogFinding(
            BotWatchdogCheck.DEADLINE,
            linkedMapOf(
                "deadlineAt" to number(deadlineAt),
                "now" to number(now),
                "elapsedMs" to number(maxOf(0, now - unit.startedAt)),
            ),
        )
    }

    public fun heartbeat(
        unit: BotWatchdogUnit,
        now: Long,
        config: BotWatchdogConfig = BotWatchdogConfig.DEFAULT,
    ): BotWatchdogFinding? {
        if (unit.pendingApproval > 0 || config.heartbeatTimeoutMs <= 0) return null
        val lastEventAt = unit.lastEventAt ?: unit.startedAt
        val silentMs = now - lastEventAt
        if (silentMs <= config.heartbeatTimeoutMs) return null
        return BotWatchdogFinding(
            BotWatchdogCheck.HEARTBEAT,
            linkedMapOf(
                "lastEventAt" to number(lastEventAt),
                "now" to number(now),
                "silentMs" to number(silentMs),
                "thresholdMs" to number(config.heartbeatTimeoutMs),
            ),
        )
    }

    public fun repeatedToolSignature(
        unit: BotWatchdogUnit,
        config: BotWatchdogConfig = BotWatchdogConfig.DEFAULT,
    ): BotWatchdogFinding? {
        if (config.repeatedToolCalls <= 0 || unit.repeatedToolSignatureCount < config.repeatedToolCalls) {
            return null
        }
        return BotWatchdogFinding(
            BotWatchdogCheck.REPEATED_TOOL_SIGNATURE,
            linkedMapOf(
                "signature" to nullableString(unit.lastToolSignature),
                "count" to number(unit.repeatedToolSignatureCount),
                "threshold" to number(config.repeatedToolCalls),
            ),
        )
    }

    public fun repeatedToolError(
        unit: BotWatchdogUnit,
        config: BotWatchdogConfig = BotWatchdogConfig.DEFAULT,
    ): BotWatchdogFinding? {
        if (config.repeatedToolErrors <= 0 || unit.repeatedToolErrorCount < config.repeatedToolErrors) {
            return null
        }
        return BotWatchdogFinding(
            BotWatchdogCheck.REPEATED_TOOL_ERROR,
            linkedMapOf(
                "errorSignature" to nullableString(unit.lastToolErrorSignature),
                "count" to number(unit.repeatedToolErrorCount),
                "threshold" to number(config.repeatedToolErrors),
            ),
        )
    }

    public fun quota(
        unit: BotWatchdogUnit,
        config: BotWatchdogConfig = BotWatchdogConfig.DEFAULT,
    ): BotWatchdogFinding? {
        val tokens = maxOf(0, unit.tokens)
        val cost = if (unit.costUsd.isFinite()) maxOf(0.0, unit.costUsd) else 0.0
        val overTokens = config.maxUnitTokens > 0 && tokens > config.maxUnitTokens
        val overCost = config.maxUnitCostUsd > 0 && cost > config.maxUnitCostUsd
        if (!overTokens && !overCost) return null
        val reason = when {
            overTokens && overCost -> "tokens_and_cost"
            overTokens -> "tokens"
            else -> "cost"
        }
        return BotWatchdogFinding(
            BotWatchdogCheck.QUOTA,
            linkedMapOf(
                "tokens" to number(tokens),
                "maxTokens" to number(config.maxUnitTokens),
                "costUsd" to number(cost),
                "maxCostUsd" to number(config.maxUnitCostUsd),
                "reason" to JsonString(reason),
            ),
        )
    }

    /** The evidence object a host reading must carry; empty evidence is never fabricated. */
    internal fun mobileFinding(
        event: BotMobileWatchdogEvent,
        evidence: Map<String, JsonValue>,
    ): BotWatchdogFinding? {
        if (event != BotMobileWatchdogEvent.WEBCONTENT_TERMINATED && evidence.isEmpty()) return null
        return BotWatchdogFinding(event.check, LinkedHashMap(evidence))
    }
}
