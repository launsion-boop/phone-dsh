// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.routines.RoutineJson.collapseWhitespace
import com.phonedsh.bot.routines.RoutineJson.codePointLength
import com.phonedsh.bot.routines.RoutineJson.objectOf
import com.phonedsh.bot.routines.RoutineJson.optionalArray
import com.phonedsh.bot.routines.RoutineJson.optionalBool
import com.phonedsh.bot.routines.RoutineJson.optionalInt
import com.phonedsh.bot.routines.RoutineJson.optionalLong
import com.phonedsh.bot.routines.RoutineJson.optionalObject
import com.phonedsh.bot.routines.RoutineJson.optionalString
import com.phonedsh.bot.routines.RoutineJson.prefixCodePoints
import com.phonedsh.bot.routines.RoutineJson.requiredArray
import com.phonedsh.bot.routines.RoutineJson.requiredBool
import com.phonedsh.bot.routines.RoutineJson.requiredInt
import com.phonedsh.bot.routines.RoutineJson.requiredLong
import com.phonedsh.bot.routines.RoutineJson.requiredObject
import com.phonedsh.bot.routines.RoutineJson.requiredString
import com.phonedsh.agentcore.JsonString

/**
 * A model-visible routine failure. The codes are the frozen
 * `RoutineError` cases (`Sources/PhoneDSHBot/Routines/RoutineModels.swift:5-37`;
 * D9 §13); the messages are the exact strings the model sees.
 */
sealed class RoutineError(message: String) : Exception(message) {
    abstract val code: String

    class InvalidSchedule(message: String) : RoutineError(message) {
        override val code: String get() = "invalidSchedule"
    }

    class InvalidRoutine(message: String) : RoutineError(message) {
        override val code: String get() = "invalidRoutine"
    }

    class RoutineNotFound(val routineId: String) : RoutineError("routine not found: $routineId") {
        override val code: String get() = "routineNotFound"
    }

    class UrgentReasonRequired : RoutineError(
        "urgent_reason is required when urgent is true (say which incident or deadline cannot wait)",
    ) {
        override val code: String get() = "urgentReasonRequired"
    }

    class InterruptReasonRequired : RoutineError(
        "interrupt_reason is required when delivery is \"interrupt\" " +
            "(say who is waiting or what must be handled immediately)",
    ) {
        override val code: String get() = "interruptReasonRequired"
    }

    class InvalidQuietTarget : RoutineError("quiet-hours deferral requires a future instant") {
        override val code: String get() = "invalidQuietTarget"
    }

    class InvalidHeldItem(message: String) : RoutineError(message) {
        override val code: String get() = "invalidHeldItem"
    }

    class HeldInboxFull(val limit: Int) : RoutineError(
        "held inbox is full ($limit items); the message was not delivered.",
    ) {
        override val code: String get() = "heldInboxFull"
    }

    class DeliveryNotFound(val key: String) : RoutineError("routine delivery not found: $key") {
        override val code: String get() = "deliveryNotFound"
    }

    class UnsupportedDecision(val decision: String) : RoutineError(
        "decision must be \"retry\" or \"acknowledge\", got $decision",
    ) {
        override val code: String get() = "unsupportedDecision"
    }
}

/** `routine.schema.json.delivery` and `RoutineDeliveryMode`. */
enum class RoutineDeliveryMode(val rawValue: String) {
    HELD("held"),
    INTERRUPT("interrupt"),
    ;

    companion object {
        fun from(value: String?): RoutineDeliveryMode = when (value) {
            "interrupt" -> INTERRUPT
            "held", null -> HELD
            else -> throw RoutineDecodeException("unknown routine delivery mode: $value")
        }
    }
}

/** `routine.schema.json.run_state.status` plus the in-flight statuses. */
enum class RoutineRunStatus(val rawValue: String) {
    SCHEDULED("scheduled"),
    STARTED("started"),
    SUCCEEDED("succeeded"),
    FAILED("failed"),
    TIMED_OUT("timed-out"),
    CANCELLED("cancelled"),
    NEEDS_RECONCILIATION("needs-reconciliation"),
    WAITING_APPROVAL("waiting-approval"),
    ;

    val isTerminal: Boolean
        get() = when (this) {
            SUCCEEDED, FAILED, TIMED_OUT, CANCELLED, NEEDS_RECONCILIATION -> true
            SCHEDULED, STARTED, WAITING_APPROVAL -> false
        }

    companion object {
        fun from(value: String?): RoutineRunStatus = when (value) {
            "scheduled" -> SCHEDULED
            "started" -> STARTED
            "succeeded" -> SUCCEEDED
            "failed" -> FAILED
            "timed-out" -> TIMED_OUT
            "cancelled" -> CANCELLED
            "needs-reconciliation" -> NEEDS_RECONCILIATION
            "waiting-approval" -> WAITING_APPROVAL
            else -> throw RoutineDecodeException("unknown routine run status: $value")
        }
    }
}

/** `routine.schema.json.schedule`; validated by [RoutineSchedule.validated]. */
data class RoutineSchedule(
    val kind: Kind,
    val everyMinutes: Int? = null,
    val phaseMinutes: Int? = null,
    val time: String? = null,
    val weekdays: List<Int>? = null,
    val expr: String? = null,
    val timezone: String = defaultTimeZone(),
) {
    enum class Kind(val rawValue: String) {
        INTERVAL("interval"),
        DAILY("daily"),
        WEEKLY("weekly"),
        CRON("cron"),
        ;

        companion object {
            fun from(value: String?): Kind = when (value) {
                "interval" -> INTERVAL
                "daily" -> DAILY
                "weekly" -> WEEKLY
                "cron" -> CRON
                else -> throw RoutineDecodeException("unknown routine schedule kind: $value")
            }
        }
    }

    fun toJson(): JsonObject = objectOf(
        listOf(
            "kind" to JsonString(kind.rawValue),
            "everyMinutes" to everyMinutes?.let { RoutineJson.number(it.toLong()) },
            "phaseMinutes" to phaseMinutes?.let { RoutineJson.number(it.toLong()) },
            "time" to time?.let(RoutineJson::string),
            "weekdays" to weekdays?.let { days ->
                com.phonedsh.agentcore.JsonArray(days.map { RoutineJson.number(it.toLong()) })
            },
            "expr" to expr?.let(RoutineJson::string),
            "timezone" to JsonString(timezone),
        ),
    )

    /**
     * Fills in the defaults and clears the members that do not apply to the
     * kind, exactly like `RoutineSchedule.validated()`.
     */
    fun validated(): RoutineSchedule {
        val zone = timezone.trim()
        if (zone.isEmpty()) {
            throw RoutineError.InvalidSchedule("schedule.timezone must be a non-empty IANA time zone")
        }
        if (!RoutineTime.isKnownZone(zone)) {
            throw RoutineError.InvalidSchedule("unsupported time zone: $zone")
        }
        val copy = copy(timezone = zone)
        return when (kind) {
            Kind.INTERVAL -> {
                val every = everyMinutes
                if (every == null || every < 1 || every > 525_600) {
                    throw RoutineError.InvalidSchedule("schedule.everyMinutes must be an integer 1–525600")
                }
                val phase = phaseMinutes
                if (phase != null && (phase < 0 || phase >= every)) {
                    throw RoutineError.InvalidSchedule(
                        "schedule.phaseMinutes must be an integer offset shorter than everyMinutes",
                    )
                }
                copy.copy(everyMinutes = every, time = null, weekdays = null, expr = null)
            }
            Kind.DAILY -> {
                val parsed = RoutineTime.parseTime(time)
                copy.copy(
                    time = parsed.text, everyMinutes = null, phaseMinutes = null,
                    weekdays = null, expr = null,
                )
            }
            Kind.WEEKLY -> {
                val parsed = RoutineTime.parseTime(time)
                val days = weekdays
                if (days == null || days.isEmpty() || days.any { it < 1 || it > 7 }) {
                    throw RoutineError.InvalidSchedule(
                        "schedule.weekdays must be a non-empty array of ISO weekdays 1=Mon … 7=Sun",
                    )
                }
                copy.copy(
                    time = parsed.text, weekdays = days.distinct().sorted(),
                    everyMinutes = null, phaseMinutes = null, expr = null,
                )
            }
            Kind.CRON -> {
                val expression = collapseWhitespace(expr ?: "")
                CronExpression.parse(expression)
                copy.copy(
                    expr = expression, everyMinutes = null, phaseMinutes = null,
                    time = null, weekdays = null,
                )
            }
        }
    }

    companion object {
        fun interval(everyMinutes: Int, phaseMinutes: Int? = null, timezone: String = defaultTimeZone()): RoutineSchedule =
            RoutineSchedule(Kind.INTERVAL, everyMinutes = everyMinutes, phaseMinutes = phaseMinutes, timezone = timezone)

        fun daily(time: String, timezone: String = defaultTimeZone()): RoutineSchedule =
            RoutineSchedule(Kind.DAILY, time = time, timezone = timezone)

        fun weekly(time: String, weekdays: List<Int>, timezone: String = defaultTimeZone()): RoutineSchedule =
            RoutineSchedule(Kind.WEEKLY, time = time, weekdays = weekdays, timezone = timezone)

        fun cron(expr: String, timezone: String = defaultTimeZone()): RoutineSchedule =
            RoutineSchedule(Kind.CRON, expr = expr, timezone = timezone)

        fun fromJson(value: JsonValue?): RoutineSchedule {
            val members = value as? JsonObject
                ?: throw RoutineDecodeException("schedule must be an object")
            return RoutineSchedule(
                kind = Kind.from(members.members.requiredString("kind", "schedule.kind")),
                everyMinutes = members.members.optionalInt("everyMinutes"),
                phaseMinutes = members.members.optionalInt("phaseMinutes"),
                time = members.members.optionalString("time"),
                weekdays = members.members.optionalArray("weekdays")?.map {
                    (it as? com.phonedsh.agentcore.JsonNumber)?.asLongOrNull()?.toInt()
                        ?: throw RoutineDecodeException("schedule.weekdays must contain integers")
                },
                expr = members.members.optionalString("expr"),
                timezone = members.members.requiredString("timezone", "schedule.timezone"),
            )
        }

        private fun defaultTimeZone(): String = RoutineTime.defaultZoneId()
    }
}

/** `quiet_defer`; Swift `RoutineQuietDefer`. */
data class RoutineQuietDefer(val until: Long, val scheduledFor: Long, val at: Long) {
    fun toJson(): JsonObject = objectOf(
        listOf(
            "until" to RoutineJson.number(until),
            "scheduledFor" to RoutineJson.number(scheduledFor),
            "at" to RoutineJson.number(at),
        ),
    )

    companion object {
        fun fromJson(value: JsonValue?): RoutineQuietDefer {
            val members = value as? JsonObject
                ?: throw RoutineDecodeException("quiet_defer must be an object")
            return RoutineQuietDefer(
                until = members.members.requiredLong("until", "quiet_defer.until"),
                scheduledFor = members.members.requiredLong("scheduledFor", "quiet_defer.scheduledFor"),
                at = members.members.requiredLong("at", "quiet_defer.at"),
            )
        }
    }
}

/** `run_state`; Swift `RoutineRunState`. Unknown members are ignored. */
data class RoutineRunState(
    val runId: String,
    val attempt: Int,
    val status: RoutineRunStatus,
    val scheduledFor: Long? = null,
    val startedAt: Long,
    val finishedAt: Long? = null,
    val leaseOwner: String? = null,
    val leaseExpiresAt: Long? = null,
    val error: String? = null,
    val reconciliationRequired: Boolean = false,
    val recovered: Boolean = false,
    val quietDeferred: RoutineQuietDefer? = null,
    val waitingApprovalId: String? = null,
    val waitingSessionId: String? = null,
) {
    fun toJson(): JsonObject = objectOf(
        listOf(
            "runId" to JsonString(runId),
            "attempt" to RoutineJson.number(attempt.toLong()),
            "status" to JsonString(status.rawValue),
            "scheduledFor" to scheduledFor?.let(RoutineJson::number),
            "startedAt" to RoutineJson.number(startedAt),
            "finishedAt" to finishedAt?.let(RoutineJson::number),
            "leaseOwner" to leaseOwner?.let(RoutineJson::string),
            "leaseExpiresAt" to leaseExpiresAt?.let(RoutineJson::number),
            "error" to error?.let(RoutineJson::string),
            "reconciliationRequired" to RoutineJson.bool(reconciliationRequired),
            "recovered" to RoutineJson.bool(recovered),
            "quietDeferred" to quietDeferred?.toJson(),
            "waitingApprovalID" to waitingApprovalId?.let(RoutineJson::string),
            "waitingSessionID" to waitingSessionId?.let(RoutineJson::string),
        ),
    )

    companion object {
        fun fromJson(value: JsonValue?): RoutineRunState {
            val members = value as? JsonObject
                ?: throw RoutineDecodeException("run_state must be an object")
            return RoutineRunState(
                runId = members.members.requiredString("runId", "run_state.runId"),
                attempt = members.members.requiredInt("attempt", "run_state.attempt"),
                status = RoutineRunStatus.from(members.members.requiredString("status", "run_state.status")),
                scheduledFor = members.members.optionalLong("scheduledFor"),
                startedAt = members.members.requiredLong("startedAt", "run_state.startedAt"),
                finishedAt = members.members.optionalLong("finishedAt"),
                leaseOwner = members.members.optionalString("leaseOwner"),
                leaseExpiresAt = members.members.optionalLong("leaseExpiresAt"),
                error = members.members.optionalString("error"),
                reconciliationRequired = members.members.optionalBool("reconciliationRequired") ?: false,
                recovered = members.members.optionalBool("recovered") ?: false,
                quietDeferred = members.members.optionalObject("quietDeferred")?.let {
                    RoutineQuietDefer.fromJson(JsonObject(it))
                },
                waitingApprovalId = members.members.optionalString("waitingApprovalID"),
                waitingSessionId = members.members.optionalString("waitingSessionID"),
            )
        }
    }
}

/** `last_result`; Swift `RoutineResult` (snake_case coding keys). */
data class RoutineResult(
    val status: RoutineRunStatus,
    val text: String = "",
    val error: String? = null,
    val startedAt: Long,
    val finishedAt: Long? = null,
    val durationMs: Long? = null,
    val scheduledFor: Long? = null,
    val lateByMs: Long? = null,
    val quiet: Boolean = false,
    val quietDeferredFrom: Long? = null,
    val quietDeferredUntil: Long? = null,
    val attempt: Int,
    val runId: String,
) {
    fun toJson(): JsonObject = objectOf(
        listOf(
            "status" to JsonString(status.rawValue),
            "text" to JsonString(text),
            "error" to error?.let(RoutineJson::string),
            "started_at" to RoutineJson.number(startedAt),
            "finished_at" to finishedAt?.let(RoutineJson::number),
            "duration_ms" to durationMs?.let(RoutineJson::number),
            "scheduled_for" to scheduledFor?.let(RoutineJson::number),
            "late_by_ms" to lateByMs?.let(RoutineJson::number),
            "quiet" to RoutineJson.bool(quiet),
            "quiet_deferred_from" to quietDeferredFrom?.let(RoutineJson::number),
            "quiet_deferred_until" to quietDeferredUntil?.let(RoutineJson::number),
            "attempt" to RoutineJson.number(attempt.toLong()),
            "run_id" to JsonString(runId),
        ),
    )

    companion object {
        fun fromJson(value: JsonValue?): RoutineResult {
            val members = value as? JsonObject
                ?: throw RoutineDecodeException("last_result must be an object")
            return RoutineResult(
                status = RoutineRunStatus.from(members.members.requiredString("status", "last_result.status")),
                text = members.members.optionalString("text") ?: "",
                error = members.members.optionalString("error"),
                startedAt = members.members.requiredLong("started_at", "last_result.started_at"),
                finishedAt = members.members.optionalLong("finished_at"),
                durationMs = members.members.optionalLong("duration_ms"),
                scheduledFor = members.members.optionalLong("scheduled_for"),
                lateByMs = members.members.optionalLong("late_by_ms"),
                quiet = members.members.optionalBool("quiet") ?: false,
                quietDeferredFrom = members.members.optionalLong("quiet_deferred_from"),
                quietDeferredUntil = members.members.optionalLong("quiet_deferred_until"),
                attempt = members.members.optionalInt("attempt") ?: 0,
                runId = members.members.optionalString("run_id") ?: "",
            )
        }
    }
}

/** `last_skip`; Swift `RoutineSkip`. */
data class RoutineSkip(
    val reason: String,
    val at: Long,
    val triggerAt: Long? = null,
    val runningAttempt: Int? = null,
    val runningRunId: String? = null,
) {
    fun toJson(): JsonObject = objectOf(
        listOf(
            "reason" to JsonString(reason),
            "at" to RoutineJson.number(at),
            "trigger_at" to triggerAt?.let(RoutineJson::number),
            "running_attempt" to runningAttempt?.let { RoutineJson.number(it.toLong()) },
            "running_run_id" to runningRunId?.let(RoutineJson::string),
        ),
    )

    companion object {
        fun fromJson(value: JsonValue?): RoutineSkip {
            val members = value as? JsonObject
                ?: throw RoutineDecodeException("last_skip must be an object")
            return RoutineSkip(
                reason = members.members.requiredString("reason", "last_skip.reason"),
                at = members.members.requiredLong("at", "last_skip.at"),
                triggerAt = members.members.optionalLong("trigger_at"),
                runningAttempt = members.members.optionalInt("running_attempt"),
                runningRunId = members.members.optionalString("running_run_id"),
            )
        }
    }
}

/** `routine.schema.json`; Swift `Routine`. Nil optionals are omitted (CCR-7). */
data class Routine(
    val id: String,
    val agentId: String,
    val title: String,
    val prompt: String,
    val schedule: RoutineSchedule,
    val enabled: Boolean = true,
    val idempotent: Boolean = false,
    val urgent: Boolean = false,
    val urgentReason: String = "",
    val delivery: RoutineDeliveryMode = RoutineDeliveryMode.HELD,
    val interruptReason: String = "",
    val createdAt: Long,
    val creator: RoutineCreator? = null,
    val completionCriteria: String = "",
    val constraints: String = "",
    val attempt: Int = 0,
    val runState: RoutineRunState? = null,
    val quietDefer: RoutineQuietDefer? = null,
    val lastSkip: RoutineSkip? = null,
    val skipCount: Int = 0,
    val crashRetry: Boolean = false,
    val lastRunAt: Long? = null,
    val nextRunAt: Long? = null,
    val lastResult: RoutineResult? = null,
) {
    fun toJson(): JsonObject = objectOf(
        listOf(
            "id" to JsonString(id),
            "agentId" to JsonString(agentId),
            "title" to JsonString(title),
            "prompt" to JsonString(prompt),
            "schedule" to schedule.toJson(),
            "enabled" to RoutineJson.bool(enabled),
            "idempotent" to RoutineJson.bool(idempotent),
            "urgent" to RoutineJson.bool(urgent),
            "urgent_reason" to JsonString(urgentReason),
            "delivery" to JsonString(delivery.rawValue),
            "interrupt_reason" to JsonString(interruptReason),
            "created_at" to RoutineJson.number(createdAt),
            "creator" to creator?.toJson(),
            "completion_criteria" to JsonString(completionCriteria),
            "constraints" to JsonString(constraints),
            "attempt" to RoutineJson.number(attempt.toLong()),
            "run_state" to runState?.toJson(),
            "quiet_defer" to quietDefer?.toJson(),
            "last_skip" to lastSkip?.toJson(),
            "skip_count" to RoutineJson.number(skipCount.toLong()),
            "crash_retry" to RoutineJson.bool(crashRetry),
            "last_run_at" to lastRunAt?.let(RoutineJson::number),
            "next_run_at" to nextRunAt?.let(RoutineJson::number),
            "last_result" to lastResult?.toJson(),
        ),
    )

    /**
     * The exact `Routine.validated()` rules (D9 §1). Returns a normalized copy;
     * the receiver is never mutated.
     */
    fun validated(): Routine {
        var copy = copy(
            id = id.trim(),
            agentId = agentId.trim(),
            title = collapseWhitespace(title),
            prompt = prompt.trim(),
            completionCriteria = completionCriteria.trim(),
            constraints = constraints.trim(),
        )
        if (codePointLength(copy.completionCriteria) > 2_000) {
            throw RoutineError.InvalidRoutine("routine completion_criteria is too long (max 2000 characters)")
        }
        if (codePointLength(copy.constraints) > 2_000) {
            throw RoutineError.InvalidRoutine("routine constraints is too long (max 2000 characters)")
        }
        copy.creator?.let { creator ->
            creator.rpcId?.let {
                if (it.trim().isEmpty()) {
                    throw RoutineError.InvalidRoutine("routine creator.rpcId must be non-empty when present")
                }
            }
            if (creator.authorization == RoutineCreator.Authorization.USER_CONFIRMED &&
                creator.approvalId == null
            ) {
                throw RoutineError.InvalidRoutine("routine creator.approvalID is required after user confirmation")
            }
            if (creator.authorization == RoutineCreator.Authorization.USER_TURN &&
                creator.approvalId != null
            ) {
                throw RoutineError.InvalidRoutine("routine creator.approvalID is only valid after user confirmation")
            }
        }
        if (copy.id.isEmpty() || copy.agentId.isEmpty()) {
            throw RoutineError.InvalidRoutine("routine id and agentId are required")
        }
        if (copy.title.isEmpty() || codePointLength(copy.title) > 200) {
            throw RoutineError.InvalidRoutine(
                if (copy.title.isEmpty()) {
                    "routine title must be a non-empty string"
                } else {
                    "routine title is too long (max 200 characters)"
                },
            )
        }
        if (copy.prompt.isEmpty() || codePointLength(copy.prompt) > 20_000) {
            throw RoutineError.InvalidRoutine(
                if (copy.prompt.isEmpty()) {
                    "routine prompt must be a non-empty string"
                } else {
                    "routine prompt is too long (max 20000 characters)"
                },
            )
        }
        copy = copy.copy(schedule = schedule.validated())
        val flags = RoutineDeliveryFlags.of(
            urgent = urgent,
            urgentReason = urgentReason,
            delivery = delivery,
            interruptReason = interruptReason,
        )
        return copy.copy(
            urgent = flags.urgent,
            urgentReason = flags.urgentReason,
            delivery = flags.delivery,
            interruptReason = flags.interruptReason,
        )
    }

    companion object {
        fun fromJson(value: JsonValue?): Routine {
            val members = (value as? JsonObject)?.members
                ?: throw RoutineDecodeException("routine must be an object")
            return Routine(
                id = members.requiredString("id"),
                agentId = members.requiredString("agentId"),
                title = members.requiredString("title"),
                prompt = members.requiredString("prompt"),
                schedule = RoutineSchedule.fromJson(members["schedule"]),
                enabled = members.optionalBool("enabled") ?: true,
                idempotent = members.optionalBool("idempotent") ?: false,
                urgent = members.optionalBool("urgent") ?: false,
                urgentReason = members.optionalString("urgent_reason") ?: "",
                delivery = RoutineDeliveryMode.from(members.optionalString("delivery")),
                interruptReason = members.optionalString("interrupt_reason") ?: "",
                createdAt = members.optionalLong("created_at") ?: 0,
                creator = members.optionalObject("creator")?.let { RoutineCreator.fromJson(JsonObject(it)) },
                completionCriteria = members.optionalString("completion_criteria") ?: "",
                constraints = members.optionalString("constraints") ?: "",
                attempt = members.optionalInt("attempt") ?: 0,
                runState = members.optionalObject("run_state")?.let { RoutineRunState.fromJson(JsonObject(it)) },
                quietDefer = members.optionalObject("quiet_defer")?.let { RoutineQuietDefer.fromJson(JsonObject(it)) },
                lastSkip = members.optionalObject("last_skip")?.let { RoutineSkip.fromJson(JsonObject(it)) },
                skipCount = members.optionalInt("skip_count") ?: 0,
                crashRetry = members.optionalBool("crash_retry") ?: false,
                lastRunAt = members.optionalLong("last_run_at"),
                nextRunAt = members.optionalLong("next_run_at"),
                lastResult = members.optionalObject("last_result")?.let { RoutineResult.fromJson(JsonObject(it)) },
            )
        }
    }
}

/** `urgent`/`interrupt` reason normalization and validation (D9 §1). */
data class RoutineDeliveryFlags(
    val urgent: Boolean,
    val urgentReason: String,
    val delivery: RoutineDeliveryMode,
    val interruptReason: String,
) {
    fun toJson(): JsonObject = objectOf(
        listOf(
            "urgent" to RoutineJson.bool(urgent),
            "urgent_reason" to JsonString(urgentReason),
            "delivery" to JsonString(delivery.rawValue),
            "interrupt_reason" to JsonString(interruptReason),
        ),
    )

    companion object {
        const val MAX_REASON_LENGTH: Int = 500

        fun of(
            urgent: Boolean = false,
            urgentReason: String = "",
            delivery: RoutineDeliveryMode = RoutineDeliveryMode.HELD,
            interruptReason: String = "",
        ): RoutineDeliveryFlags {
            val cleanUrgent = clean(urgentReason)
            val cleanInterrupt = clean(interruptReason)
            if (urgent && cleanUrgent.isEmpty()) throw RoutineError.UrgentReasonRequired()
            if (delivery == RoutineDeliveryMode.INTERRUPT && cleanInterrupt.isEmpty()) {
                throw RoutineError.InterruptReasonRequired()
            }
            return RoutineDeliveryFlags(urgent, cleanUrgent, delivery, cleanInterrupt)
        }

        fun clean(value: String): String = prefixCodePoints(collapseWhitespace(value), MAX_REASON_LENGTH)
    }
}

/** `routine-delivery.schema.json.status`. */
enum class RoutineDeliveryStatus(val rawValue: String) {
    PENDING("pending"),
    DELIVERING("delivering"),
    DELIVERED("delivered"),
    FAILED("failed"),
    ;

    companion object {
        fun from(value: String?): RoutineDeliveryStatus = when (value) {
            "pending" -> PENDING
            "delivering" -> DELIVERING
            "delivered" -> DELIVERED
            "failed" -> FAILED
            else -> throw RoutineDecodeException("unknown routine delivery status: $value")
        }
    }
}

/**
 * `routine-delivery.schema.json`; Swift `RoutineDelivery`.
 *
 * `deliveryKey` is `routineId:attempt`; the row id and the held-inbox item id
 * are derived from it so a replay of one attempt never creates a second row.
 */
data class RoutineDelivery(
    val deliveryKey: String,
    val routineId: String,
    val agentId: String,
    val attempt: Int,
    val runId: String,
    val status: RoutineDeliveryStatus = RoutineDeliveryStatus.PENDING,
    val resultStatus: RoutineRunStatus,
    val text: String = "",
    val error: String? = null,
    val routineTitle: String,
    val context: String = "",
    val delivery: RoutineDeliveryMode,
    val quiet: Boolean = false,
    val urgent: Boolean = false,
    val urgentReason: String = "",
    val notified: String? = null,
    val notifyReason: String? = null,
    val notifiedAt: Long? = null,
    val proactiveHandled: Boolean = false,
    val proactiveMode: String? = null,
    val cancelOrigin: String? = null,
    val heldInbox: String? = null,
    val heldInboxError: String? = null,
    val quietDeferredFrom: Long? = null,
    val quietDeferredUntil: Long? = null,
    val scheduledFor: Long? = null,
    val lateByMs: Long = 0,
    val startedAt: Long,
    val finishedAt: Long,
    val durationMs: Long = 0,
    val nextRunAt: Long? = null,
    val createdAt: Long,
    val updatedAt: Long,
    val deliveredAt: Long? = null,
    val failedAt: Long? = null,
    val lastError: String? = null,
    val attempts: Int = 0,
    val leaseOwner: String? = null,
    val leaseExpiresAt: Long? = null,
) {
    fun toJson(): JsonObject = objectOf(
        listOf(
            "deliveryKey" to JsonString(deliveryKey),
            "routineId" to JsonString(routineId),
            "agentId" to JsonString(agentId),
            "attempt" to RoutineJson.number(attempt.toLong()),
            "runId" to JsonString(runId),
            "status" to JsonString(status.rawValue),
            "resultStatus" to JsonString(resultStatus.rawValue),
            "text" to JsonString(text),
            "error" to error?.let(RoutineJson::string),
            "routineTitle" to JsonString(routineTitle),
            "context" to JsonString(context),
            "delivery" to JsonString(delivery.rawValue),
            "quiet" to RoutineJson.bool(quiet),
            "urgent" to RoutineJson.bool(urgent),
            "urgentReason" to JsonString(urgentReason),
            "notified" to notified?.let(RoutineJson::string),
            "notifyReason" to notifyReason?.let(RoutineJson::string),
            "notifiedAt" to notifiedAt?.let(RoutineJson::number),
            "proactiveHandled" to RoutineJson.bool(proactiveHandled),
            "proactiveMode" to proactiveMode?.let(RoutineJson::string),
            "cancelOrigin" to cancelOrigin?.let(RoutineJson::string),
            "heldInbox" to heldInbox?.let(RoutineJson::string),
            "heldInboxError" to heldInboxError?.let(RoutineJson::string),
            "quietDeferredFrom" to quietDeferredFrom?.let(RoutineJson::number),
            "quietDeferredUntil" to quietDeferredUntil?.let(RoutineJson::number),
            "scheduledFor" to scheduledFor?.let(RoutineJson::number),
            "lateByMs" to RoutineJson.number(lateByMs),
            "startedAt" to RoutineJson.number(startedAt),
            "finishedAt" to RoutineJson.number(finishedAt),
            "durationMs" to RoutineJson.number(durationMs),
            "nextRunAt" to nextRunAt?.let(RoutineJson::number),
            "createdAt" to RoutineJson.number(createdAt),
            "updatedAt" to RoutineJson.number(updatedAt),
            "deliveredAt" to deliveredAt?.let(RoutineJson::number),
            "failedAt" to failedAt?.let(RoutineJson::number),
            "lastError" to lastError?.let(RoutineJson::string),
            "attempts" to RoutineJson.number(attempts.toLong()),
            "leaseOwner" to leaseOwner?.let(RoutineJson::string),
            "leaseExpiresAt" to leaseExpiresAt?.let(RoutineJson::number),
        ),
    )

    companion object {
        fun key(routineId: String, attempt: Int): String = "$routineId:${maxOf(0, attempt)}"

        /** Model id → `[A-Za-z0-9._-]`, capped at 80 scalars (Swift `RoutineDelivery.rowId`). */
        fun safeRoutineId(routineId: String): String {
            val mapped = buildString {
                var index = 0
                while (index < routineId.length) {
                    val scalar = routineId.codePointAt(index)
                    index += Character.charCount(scalar)
                    val character = String(Character.toChars(scalar))
                    val allowed = character[0].isLetterOrDigit() || character[0] == '.' ||
                        character[0] == '_' || character[0] == '-'
                    append(if (allowed) character else "_")
                }
            }
            return prefixCodePoints(mapped, 80)
        }

        fun rowId(routineId: String, attempt: Int): String {
            val safe = safeRoutineId(routineId)
            return "routine-run-${if (safe.isEmpty()) "routine" else safe}-${maxOf(0, attempt)}"
        }

        fun fromJson(value: JsonValue?): RoutineDelivery {
            val members = (value as? JsonObject)?.members
                ?: throw RoutineDecodeException("routine delivery must be an object")
            return RoutineDelivery(
                deliveryKey = members.requiredString("deliveryKey"),
                routineId = members.requiredString("routineId"),
                agentId = members.requiredString("agentId"),
                attempt = members.requiredInt("attempt"),
                runId = members.requiredString("runId"),
                status = RoutineDeliveryStatus.from(members.requiredString("status")),
                resultStatus = RoutineRunStatus.from(members.requiredString("resultStatus")),
                text = members.requiredString("text"),
                error = members.optionalString("error"),
                routineTitle = members.requiredString("routineTitle"),
                context = members.requiredString("context"),
                delivery = RoutineDeliveryMode.from(members.optionalString("delivery")),
                quiet = members.optionalBool("quiet") ?: false,
                urgent = members.optionalBool("urgent") ?: false,
                urgentReason = members.optionalString("urgentReason") ?: "",
                notified = members.optionalString("notified"),
                notifyReason = members.optionalString("notifyReason"),
                notifiedAt = members.optionalLong("notifiedAt"),
                proactiveHandled = members.optionalBool("proactiveHandled") ?: false,
                proactiveMode = members.optionalString("proactiveMode"),
                cancelOrigin = members.optionalString("cancelOrigin"),
                heldInbox = members.optionalString("heldInbox"),
                heldInboxError = members.optionalString("heldInboxError"),
                quietDeferredFrom = members.optionalLong("quietDeferredFrom"),
                quietDeferredUntil = members.optionalLong("quietDeferredUntil"),
                scheduledFor = members.optionalLong("scheduledFor"),
                lateByMs = members.optionalLong("lateByMs") ?: 0,
                startedAt = members.requiredLong("startedAt"),
                finishedAt = members.requiredLong("finishedAt"),
                durationMs = members.optionalLong("durationMs") ?: 0,
                nextRunAt = members.optionalLong("nextRunAt"),
                createdAt = members.requiredLong("createdAt"),
                updatedAt = members.requiredLong("updatedAt"),
                deliveredAt = members.optionalLong("deliveredAt"),
                failedAt = members.optionalLong("failedAt"),
                lastError = members.optionalString("lastError"),
                attempts = members.optionalInt("attempts") ?: 0,
                leaseOwner = members.optionalString("leaseOwner"),
                leaseExpiresAt = members.optionalLong("leaseExpiresAt"),
            )
        }
    }
}

/**
 * `routine-document.schema.json.document`: version 1, routines sorted by the
 * caller, deliveries keyed by `routineId:attempt`. An unknown version fails
 * closed instead of being silently reset (D9 §11, v2 §2.3).
 */
data class RoutineDocument(
    val version: Int = 1,
    val routines: List<Routine> = emptyList(),
    val deliveries: Map<String, RoutineDelivery> = emptyMap(),
) {
    fun toJson(): JsonObject = objectOf(
        listOf(
            "version" to RoutineJson.number(version.toLong()),
            "routines" to com.phonedsh.agentcore.JsonArray(routines.map { it.toJson() }),
            "deliveries" to JsonObject(
                LinkedHashMap(deliveries.mapValues { it.value.toJson() }),
            ),
        ),
    )

    companion object {
        const val SUPPORTED_VERSION: Int = 1

        fun fromJson(value: JsonValue?): RoutineDocument {
            val members = (value as? JsonObject)?.members
                ?: throw RoutineDecodeException("routine document must be an object")
            val version = members.requiredLong("version", "document.version").toInt()
            if (version != SUPPORTED_VERSION) {
                throw RoutineError.InvalidRoutine(
                    "routine document version must be 1; an unknown version fails closed",
                )
            }
            val deliveries = LinkedHashMap<String, RoutineDelivery>()
            for ((key, delivery) in members.requiredObject("deliveries", "document.deliveries")) {
                deliveries[key] = RoutineDelivery.fromJson(delivery)
            }
            return RoutineDocument(
                version = version,
                routines = members.requiredArray("routines", "document.routines").map(Routine::fromJson),
                deliveries = deliveries,
            )
        }
    }
}

/** A partial update; `null` means "leave the field unchanged" (Swift `RoutinePatch`). */
data class RoutinePatch(
    val title: String? = null,
    val prompt: String? = null,
    val schedule: RoutineSchedule? = null,
    val enabled: Boolean? = null,
    val idempotent: Boolean? = null,
    val urgent: Boolean? = null,
    val urgentReason: String? = null,
    val delivery: RoutineDeliveryMode? = null,
    val interruptReason: String? = null,
    val completionCriteria: String? = null,
    val constraints: String? = null,
) {
    fun applyTo(current: Routine): Routine {
        var next = current
        title?.let { next = next.copy(title = it) }
        prompt?.let { next = next.copy(prompt = it) }
        schedule?.let { next = next.copy(schedule = it) }
        enabled?.let { next = next.copy(enabled = it) }
        idempotent?.let { next = next.copy(idempotent = it) }
        urgent?.let { next = next.copy(urgent = it) }
        urgentReason?.let { next = next.copy(urgentReason = it) }
        delivery?.let { next = next.copy(delivery = it) }
        interruptReason?.let { next = next.copy(interruptReason = it) }
        completionCriteria?.let { next = next.copy(completionCriteria = it) }
        constraints?.let { next = next.copy(constraints = it) }
        return next
    }
}
