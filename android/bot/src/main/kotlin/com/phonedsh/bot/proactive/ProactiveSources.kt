// SPDX-License-Identifier: MIT
package com.phonedsh.bot.proactive

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.routines.RoutineDelivery
import com.phonedsh.bot.routines.RoutineDeliveryMode
import com.phonedsh.bot.routines.RoutineInterruptCandidate
import com.phonedsh.bot.routines.RoutineInterruptConsiderer
import com.phonedsh.bot.routines.RoutineInterruptDecision
import com.phonedsh.bot.routines.RoutineScheduleMath
import com.phonedsh.bot.store.BotEvent

/** One host reminder that becomes a proactive candidate when it is due. */
public data class ProactiveReminder(
    public val reminderId: String,
    public val botId: String,
    public val text: String,
    public val dueAt: Long,
    public val allowDuringDnd: Boolean = false,
    /** The host row/deep link. Absent means the delivery layer must refuse it (CCR-5). */
    public val rowId: String? = null,
    public val dedupeKey: String? = "reminder:$reminderId",
)

/**
 * Event-to-candidate adapters (`ProactiveSources.swift`).
 *
 * `routine.run_finished` only produces a candidate for a successful routine.
 * Failed/timed-out/cancelled terminal states go through
 * `RoutineScheduler.considerInterrupt` and [ProactiveRoutineInterruptAdapter],
 * per CCR-4; this adapter must not claim those failures are covered.
 */
public class ProactiveSources(
    private val nowProvider: () -> Long = { System.currentTimeMillis() },
) {
    private val reminders: LinkedHashMap<String, ProactiveReminder> = LinkedHashMap()

    public fun candidates(event: BotEvent): List<ProactiveCandidate> = when (event.type) {
        "task.settled" -> taskCandidate(event)?.let(::listOf) ?: emptyList()
        "routine.run_finished" -> routineCandidate(event)?.let(::listOf) ?: emptyList()
        else -> emptyList()
    }

    @Synchronized
    public fun addReminder(reminder: ProactiveReminder): Boolean {
        if (reminders.containsKey(reminder.reminderId)) return false
        reminders[reminder.reminderId] = reminder
        return true
    }

    @Synchronized
    public fun cancelReminder(reminderId: String): Boolean =
        reminders.remove(reminderId) != null

    @Synchronized
    public fun pendingReminders(): List<ProactiveReminder> =
        reminders.values.sortedWith(compareBy({ it.dueAt }, { it.reminderId }))

    /** Remove every due reminder and return its candidate, oldest first. */
    @Synchronized
    public fun tick(now: Long? = null): List<ProactiveCandidate> {
        val at = now ?: nowProvider()
        val due = reminders.values
            .filter { it.dueAt <= at }
            .sortedWith(compareBy({ it.dueAt }, { it.reminderId }))
        val result = ArrayList<ProactiveCandidate>(due.size)
        for (entry in due) {
            reminders.remove(entry.reminderId)
            result += ProactiveCandidate(
                kind = ProactiveKind.REMINDER,
                botId = entry.botId,
                createdAt = entry.dueAt,
                id = "reminder:${entry.reminderId}",
                dedupeKey = entry.dedupeKey,
                trigger = "reminder.due",
                body = entry.text,
                reminderId = entry.reminderId,
                allowDuringDnd = entry.allowDuringDnd,
                rowId = entry.rowId,
            )
        }
        return result
    }

    private fun taskCandidate(event: BotEvent): ProactiveCandidate? {
        val botId = botId(event) ?: return null
        val data = eventData(event)
        val taskId = string(data["taskId"])
            ?: string(data["task_id"])
            ?: string(data["id"])
            ?: return null
        if (taskId.isEmpty()) return null
        val attempt = maxOf(1, integer(data["attempt"]) ?: 1)
        val status = string(data["status"]) ?: "unknown"
        val key = "task-done:$taskId:$attempt:$status"
        return ProactiveCandidate(
            kind = ProactiveKind.TASK_DONE,
            botId = botId,
            createdAt = nowProvider(),
            id = key,
            dedupeKey = key,
            trigger = "task.settled",
            sourceEventId = event.eventId,
            taskId = taskId,
            taskTitle = string(data["title"]) ?: string(data["taskTitle"]),
            summary = string(data["summary"]) ?: string(data["resultExcerpt"]),
            status = status,
        )
    }

    private fun routineCandidate(event: BotEvent): ProactiveCandidate? {
        val botId = botId(event) ?: return null
        val data = eventData(event)
        if (bool(data["proactiveHandled"]) == true) return null
        if (string(data["delivery"]) != "interrupt") return null
        if (bool(data["quiet"]) == true) return null
        if ((string(data["status"]) ?: "succeeded") != "succeeded") return null
        val excerpt = string(data["resultExcerpt"])?.trim()
        if (excerpt.isNullOrEmpty()) return null
        val routineId = string(data["routineId"])
            ?: string(data["automationId"])
            ?: return null
        if (routineId.isEmpty()) return null
        val runId = string(data["runId"]) ?: ""
        val attempt = maxOf(1, integer(data["attempt"]) ?: 1)
        val key = "routine-result:$routineId:$runId:$attempt"
        val title = string(data["routineTitle"]) ?: routineId
        return ProactiveCandidate(
            kind = ProactiveKind.ROUTINE_RESULT,
            botId = botId,
            createdAt = nowProvider(),
            id = key,
            dedupeKey = key,
            trigger = "routine.run_finished",
            sourceEventId = event.eventId,
            title = title,
            body = RoutineScheduleMath.summarize(excerpt),
            taskTitle = null,
            summary = null,
            status = "succeeded",
            routineId = routineId,
            runId = runId,
            attempt = attempt,
            delivery = ProactiveDeliveryMode.INTERRUPT,
            quiet = false,
            resultExcerpt = clipCodePoints(excerpt, 300),
            deliveryKey = string(data["deliveryKey"]),
            rowId = string(data["rowId"]) ?: RoutineDelivery.rowId(routineId, attempt),
        )
    }

    private fun botId(event: BotEvent): String? {
        val value = string(eventData(event)["botId"]) ?: event.principal.botId
        return if (value == null || value.trim().isEmpty()) null else value
    }

    private fun eventData(event: BotEvent): Map<String, JsonValue> =
        (event.data as? JsonObject)?.members ?: emptyMap()

    private fun string(value: JsonValue?): String? = (value as? JsonString)?.value

    private fun bool(value: JsonValue?): Boolean? = (value as? JsonBool)?.value

    private fun integer(value: JsonValue?): Int? =
        (value as? JsonNumber)?.asLongOrNull()?.let { number ->
            if (number < Int.MIN_VALUE || number > Int.MAX_VALUE) null else number.toInt()
        }
}

/**
 * The B6 seam to `RoutineScheduler`: map the scheduler's interrupt candidate
 * onto [ProactiveEngine] and return the mode/decision/reason strings the
 * scheduler writes back. This is the production path for failed/timed-out/
 * cancelled routine terminal states (CCR-4).
 */
public class ProactiveRoutineInterruptAdapter(
    private val engine: ProactiveEngine,
) : RoutineInterruptConsiderer {
    override fun consider(candidate: RoutineInterruptCandidate): RoutineInterruptDecision {
        val decision = engine.consider(candidate.toProactiveCandidate())
        return RoutineInterruptDecision(
            mode = decision.mode.wire,
            decision = decision.decision.wire,
            reason = decision.reason.wire,
        )
    }

    public companion object {
        public fun RoutineInterruptCandidate.toProactiveCandidate(): ProactiveCandidate =
            ProactiveCandidate(
                kind = ProactiveKind.parse(kind) ?: ProactiveKind.ROUTINE_RESULT,
                botId = botId,
                createdAt = createdAt,
                id = id,
                dedupeKey = dedupeKey,
                trigger = trigger,
                title = title,
                body = body,
                status = status,
                routineId = routineId,
                runId = runId,
                attempt = attempt,
                delivery = when (delivery) {
                    RoutineDeliveryMode.HELD -> ProactiveDeliveryMode.HELD
                    RoutineDeliveryMode.INTERRUPT -> ProactiveDeliveryMode.INTERRUPT
                },
                quiet = quiet,
                resultExcerpt = resultExcerpt,
                deliveryKey = deliveryKey,
                rowId = rowId,
            )
    }
}
