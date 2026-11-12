// SPDX-License-Identifier: MIT
package com.phonedsh.bot.proactive

/** One contribution to the per-Bot frequency fuse. */
public data class ProactiveConsideration(
    public val at: Long,
    public val kind: ProactiveKind,
    public val botId: String,
    public val fuseRecorded: Boolean,
)

/** Result of the DND/quiet/missing-bot hard-limit check. */
public data class ProactivePolicyCheck(
    public val allowed: Boolean,
    public val reason: ProactiveReason? = null,
)

/**
 * The retained proactive policy: missing-bot, DND, quiet hours and the
 * frequency fuse. Daily budgets, quotas, cooldowns, TTLs and dedupe windows
 * were removed by PC-20261111-bot-v2-unwired and are deliberately absent.
 */
public class ProactivePolicy {
    private val accepted: MutableList<ProactiveConsideration> = ArrayList()

    public fun check(
        candidate: ProactiveCandidate,
        now: Long,
        settings: ProactiveSettings,
    ): ProactivePolicyCheck {
        if (candidate.botId.trim().isEmpty()) {
            return ProactivePolicyCheck(false, ProactiveReason.MISSING_BOT)
        }
        val explicitReminder = candidate.kind == ProactiveKind.REMINDER &&
            candidate.allowDuringDnd &&
            !candidate.reminderId.isNullOrEmpty()
        if (settings.dnd && !explicitReminder) {
            return ProactivePolicyCheck(false, ProactiveReason.DND)
        }
        if (!explicitReminder && ProactiveQuietHours.isWithinQuietHours(
                now,
                start = settings.quietStart,
                end = settings.quietEnd,
                timeZone = settings.timeZone,
            )
        ) {
            return ProactivePolicyCheck(false, ProactiveReason.QUIET_HOURS)
        }
        return ProactivePolicyCheck(true)
    }

    /** Strict window comparison: `now - acceptedAt < fuseWindowMs`. */
    public fun fuseTripped(
        botId: String,
        now: Long,
        settings: ProactiveSettings,
    ): Boolean {
        val count = accepted.count {
            it.fuseRecorded &&
                it.botId == botId &&
                now - it.at < settings.fuseWindowMs
        }
        return count >= settings.fuseMaxWakeups
    }

    public fun record(candidate: ProactiveCandidate, now: Long, fuseRecorded: Boolean) {
        accepted += ProactiveConsideration(
            at = now,
            kind = candidate.kind,
            botId = candidate.botId,
            fuseRecorded = fuseRecorded,
        )
    }

    /** Restore accounting from durable events; host P18 owns event decoding. */
    public fun restore(consideration: ProactiveConsideration) {
        accepted += consideration
    }

    public fun considerations(): List<ProactiveConsideration> = accepted.toList()
}
