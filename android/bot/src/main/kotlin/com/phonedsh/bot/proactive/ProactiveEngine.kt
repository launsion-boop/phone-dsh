// SPDX-License-Identifier: MIT
package com.phonedsh.bot.proactive

import com.phonedsh.bot.routines.RoutineScheduleMath

/**
 * Host seam for the durable `proactive.considered` event (P25/P18). The
 * callback runs after the decision is built; a failed append does not change
 * the decision, mirroring Swift `ProactiveEngine.finish`.
 */
public fun interface ProactiveConsiderationSink {
    public fun record(
        candidate: ProactiveCandidate,
        decision: ProactiveDecision,
        fuseRecorded: Boolean,
    )
}

/**
 * The P26 proactive admission chain (README §3.0).
 *
 * `consider` returns a decision even when nothing is delivered. Delivery goes
 * through [ProactiveDelivering]; this class has no Android/notification-center
 * dependency. The clock is injected so tests use a fake and hosts use the
 * durable event time.
 *
 * Order: routine pre-filter -> mode -> delivery kind -> hard limits -> fuse ->
 * delivery -> commit. The first hit short-circuits.
 */
public class ProactiveEngine(
    private val settingsProvider: () -> ProactiveSettings = { ProactiveSettings() },
    private val nowProvider: () -> Long = { System.currentTimeMillis() },
    private val deliverer: ProactiveDelivering? = null,
    private val considerationSink: ProactiveConsiderationSink? = null,
) {
    private val policy = ProactivePolicy()
    private val history = ArrayList<ProactiveDecision>()
    private var sequence: Long = 0
    private var restored = false
    private var restoredCount = 0

    @Synchronized
    public fun consider(candidate: ProactiveCandidate): ProactiveDecision {
        val at = nowProvider()
        val settings = settingsProvider().normalized()

        if (candidate.kind == ProactiveKind.ROUTINE_RESULT) {
            if (candidate.delivery != ProactiveDeliveryMode.INTERRUPT) {
                return finish(
                    candidate, at, settings, ProactiveDecisionKind.SKIP,
                    ProactiveReason.ROUTINE_HELD,
                )
            }
            if (candidate.quiet) {
                return finish(
                    candidate, at, settings, ProactiveDecisionKind.SKIP,
                    ProactiveReason.ROUTINE_QUIET,
                )
            }
        }

        if (settings.mode == ProactiveMode.OFF) {
            return finish(
                candidate, at, settings, ProactiveDecisionKind.SKIP,
                ProactiveReason.MODE_OFF,
            )
        }

        val deliverable = settings.mode == ProactiveMode.ON &&
            settings.deliveryKinds.contains(candidate.kind)
        val check = policy.check(candidate, at, settings)
        if (!check.allowed) {
            return finish(
                candidate, at, settings, ProactiveDecisionKind.SKIP,
                check.reason ?: ProactiveReason.MISSING_BOT,
            )
        }

        val fuseApplies = settings.mode == ProactiveMode.WOULD || deliverable
        if (fuseApplies && policy.fuseTripped(candidate.botId, at, settings)) {
            return finish(
                candidate, at, settings, ProactiveDecisionKind.SKIP,
                ProactiveReason.FUSE,
            )
        }

        val dedupeKey = deliveryKey(candidate, at)
        val notification = notification(candidate, dedupeKey)
        var decision = ProactiveDecisionKind.WOULD
        var delivery: ProactiveDeliveryResult? = null

        if (deliverable) {
            val delivering = deliverer
                ?: return finish(
                    candidate, at, settings, ProactiveDecisionKind.SKIP,
                    ProactiveReason.DELIVERY_UNAVAILABLE, notification,
                )
            try {
                val result = delivering.deliver(notification)
                delivery = result
                if (!result.delivered) {
                    return finish(
                        candidate, at, settings, ProactiveDecisionKind.SKIP,
                        ProactiveReason.DELIVERY_FAILED, notification, result,
                    )
                }
                decision = ProactiveDecisionKind.DID
            } catch (error: Exception) {
                val result = ProactiveDeliveryResult(
                    delivered = false,
                    error = error.message ?: error.toString(),
                )
                return finish(
                    candidate, at, settings, ProactiveDecisionKind.SKIP,
                    ProactiveReason.DELIVERY_FAILED, notification, result,
                )
            }
        }

        policy.record(
            candidate,
            at,
            fuseRecorded = decision == ProactiveDecisionKind.DID ||
                settings.mode == ProactiveMode.WOULD,
        )
        val reason = when {
            decision == ProactiveDecisionKind.DID -> ProactiveReason.DELIVERED
            settings.mode == ProactiveMode.WOULD -> ProactiveReason.WOULD_MODE
            else -> ProactiveReason.WOULD_ONLY_KIND
        }
        return finish(candidate, at, settings, decision, reason, notification, delivery)
    }

    /** Most recent decisions, newest first, matching Swift `recent(limit:)`. */
    @Synchronized
    public fun recent(limit: Int = 50): List<ProactiveDecision> =
        history.takeLast(maxOf(0, limit)).reversed()

    /**
     * Rebuild fuse accounting from durable events before the first
     * consideration. Only records inside the current window are restored, as
     * in Swift `restoreAccounting`; a second call is a no-op.
     */
    @Synchronized
    public fun restoreAccounting(considerations: List<ProactiveConsideration>): Int {
        if (restored) return restoredCount
        val settings = settingsProvider().normalized()
        val windowStart = nowProvider() - settings.fuseWindowMs
        var count = 0
        for (consideration in considerations) {
            if (consideration.at >= windowStart) {
                policy.restore(consideration)
                count += 1
            }
        }
        restored = true
        restoredCount = count
        return count
    }

    private fun finish(
        candidate: ProactiveCandidate,
        at: Long,
        settings: ProactiveSettings,
        decision: ProactiveDecisionKind,
        reason: ProactiveReason,
        notification: ProactiveNotification? = null,
        delivery: ProactiveDeliveryResult? = null,
    ): ProactiveDecision {
        sequence += 1
        val dedupeKey = deliveryKey(candidate, at)
        val resolvedNotification = notification ?: notification(candidate, dedupeKey)
        val record = ProactiveDecision(
            id = "proactive:$at:$sequence",
            at = at,
            decision = decision,
            reason = reason,
            kind = candidate.kind,
            botId = candidate.botId,
            dedupeKey = dedupeKey,
            mode = settings.mode,
            channel = candidate.channel,
            notification = resolvedNotification,
            delivery = delivery,
        )
        history += record
        if (history.size > 200) history.subList(0, history.size - 200).clear()
        runCatching { considerationSink?.record(candidate, record, record.fuseRecorded) }
        return record
    }

    /**
     * Stable notification identifier. An explicit key is trimmed and used when
     * non-empty; otherwise the payload is the first present of
     * taskId/runId/reminderId/id, or the clock value when all are empty. It is
     * not a suppression window.
     */
    private fun deliveryKey(candidate: ProactiveCandidate, at: Long): String {
        val explicit = candidate.dedupeKey?.trim()
        if (!explicit.isNullOrEmpty()) return explicit
        val payload = candidate.taskId
            ?: candidate.runId
            ?: candidate.reminderId
            ?: candidate.id
            ?: ""
        return "${candidate.kind.wire}:${candidate.botId}:${payload.ifEmpty { at.toString() }}"
    }

    private fun notification(
        candidate: ProactiveCandidate,
        dedupeKey: String,
    ): ProactiveNotification {
        val explicitTitle = candidate.title?.trim().orEmpty()
        val explicitBody = candidate.body?.trim().orEmpty()
        val title: String
        val body: String
        when (candidate.kind) {
            ProactiveKind.TASK_DONE -> {
                title = explicitTitle.ifEmpty { "DSH Bot · 后台任务" }
                body = explicitBody.ifEmpty {
                    candidate.summary
                        ?: candidate.taskTitle
                        ?: "任务 ${candidate.taskId ?: ""} ${proactiveStatusLabel(candidate.status)}"
                }
            }
            ProactiveKind.ROUTINE_RESULT -> {
                title = explicitTitle.ifEmpty { "DSH Bot · 定时执行" }
                body = explicitBody.ifEmpty {
                    candidate.resultExcerpt?.let { RoutineScheduleMath.summarize(it) }
                        ?: "例行任务 ${candidate.routineId ?: ""} " +
                        proactiveStatusLabel(candidate.status)
                }
            }
            ProactiveKind.REMINDER -> {
                title = explicitTitle.ifEmpty { "DSH Bot · 提醒" }
                body = explicitBody.ifEmpty { "提醒时间到了" }
            }
        }
        return ProactiveNotification(
            title = title,
            body = body,
            kind = candidate.kind,
            botId = candidate.botId,
            dedupeKey = dedupeKey,
            channel = candidate.channel,
            rowId = candidate.rowId,
        )
    }
}
