// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.routines.RoutineJson.objectOf
import com.phonedsh.bot.routines.RoutineJson.optionalString
import com.phonedsh.bot.wake.BotTurnOriginKind

/**
 * Who created a routine, expressed with the current turn-source fields
 * (`spec/bot/v2/README.md` §2.2). S1 replaces `rpcId` with a `record://`
 * reference; no second field is added in the meantime.
 */
data class RoutineCreator(
    val rpcId: String? = null,
    val turnId: String? = null,
    val sessionId: String? = null,
    val origin: BotTurnOriginKind,
    val authorization: Authorization,
    val approvalId: String? = null,
) {
    enum class Authorization(val rawValue: String) {
        USER_TURN("user-turn"),
        USER_CONFIRMED("user-confirmed"),
        ;

        companion object {
            fun from(value: String?): Authorization = when (value) {
                "user-turn" -> USER_TURN
                "user-confirmed" -> USER_CONFIRMED
                else -> throw RoutineDecodeException("unknown routine creator authorization: $value")
            }
        }
    }

    fun toJson(): JsonObject = objectOf(
        listOf(
            "rpcId" to rpcId?.let(RoutineJson::string),
            "turnId" to turnId?.let(RoutineJson::string),
            "sessionId" to sessionId?.let(RoutineJson::string),
            "origin" to JsonString(origin.rawValue),
            "authorization" to JsonString(authorization.rawValue),
            "approvalID" to approvalId?.let(RoutineJson::string),
        ),
    )

    companion object {
        fun fromJson(value: JsonValue?): RoutineCreator {
            val members = (value as? JsonObject)?.members
                ?: throw RoutineDecodeException("creator must be an object")
            return RoutineCreator(
                rpcId = members.optionalString("rpcId"),
                turnId = members.optionalString("turnId"),
                sessionId = members.optionalString("sessionId"),
                origin = BotTurnOriginKind.from(members["origin"]?.let { (it as? JsonString)?.value }),
                authorization = Authorization.from(members.optionalString("authorization")),
                approvalId = members.optionalString("approvalID"),
            )
        }

        /** `BotTurnAuthority` → creator: a real user turn needs no approval id. */
        fun fromTurnAuthority(
            rpcId: String?,
            turnId: String?,
            sessionId: String,
            origin: BotTurnOriginKind,
            isUserTurn: Boolean,
            approvalId: String? = null,
        ): RoutineCreator = RoutineCreator(
            rpcId = rpcId,
            turnId = turnId,
            sessionId = sessionId,
            origin = origin,
            authorization = if (isUserTurn) Authorization.USER_TURN else Authorization.USER_CONFIRMED,
            approvalId = if (isUserTurn) null else approvalId,
        )
    }
}

/**
 * One routine create/update decision before it reaches the store. The authority
 * rule is pure so the approval card and the store see the same assessment.
 */
data class RoutineChangeAssessment(
    val action: Action,
    val routineId: String?,
    val requiresConfirmation: Boolean,
    val resource: String,
    val detail: String,
) {
    enum class Action(val rawValue: String) {
        CREATE("create"),
        UPDATE("update"),
        RESUME("resume"),
        OTHER("other"),
    }
}

/**
 * `RoutineAuthority` (`Sources/PhoneDSHBot/Routines/RoutineAuthority.swift`).
 *
 * "Loosening" is: schedule more frequent than now, `held` → `interrupt`,
 * `urgent` false → true, or resuming a paused routine (v2 §2.2). A real user
 * turn needs no approval card; every other turn must confirm before the store
 * is touched. The full `UpdateRoutine` tool surface is B5; this file owns only
 * the arguments the authority decision reads.
 */
object RoutineAuthority {
    /** The fields whose change widens what the routine may do on its own. */
    const val APPROVAL_ACTION: String = "更新例行任务授权"

    fun assess(
        arguments: JsonValue?,
        machine: RoutineMachine,
        botId: String,
        now: Long,
    ): RoutineChangeAssessment {
        val args = (arguments as? JsonObject)?.members
            ?: throw RoutineError.InvalidRoutine("UpdateRoutine requires action")
        val action = (args["action"] as? JsonString)?.value
            ?: throw RoutineError.InvalidRoutine("UpdateRoutine requires action")
        return when (action) {
            "create" -> {
                val title = RoutineChangeArguments.title(args)
                RoutineChangeAssessment(
                    action = RoutineChangeAssessment.Action.CREATE,
                    routineId = null,
                    requiresConfirmation = true,
                    resource = "routine:create:${safeResource(title)}",
                    detail = "在新的例行任务「$title」创建前确认；" +
                        "它会在没有用户消息的回合里保存可自行触发的目标。",
                )
            }
            "update" -> {
                val id = RoutineChangeArguments.requiredString(args, "routine_id")
                machine.get(botId, id) ?: throw RoutineError.RoutineNotFound(id)
                val current = machine.get(botId, id)!!
                val patch = RoutineChangeArguments.patch(args, now)
                val widens = isLoosening(current, patch, now)
                RoutineChangeAssessment(
                    action = RoutineChangeAssessment.Action.UPDATE,
                    routineId = id,
                    requiresConfirmation = widens,
                    resource = "routine:widen:${safeResource(id)}:${safeResource(describe(patch))}",
                    detail = "例行任务「${current.title}」会被放宽：" +
                        "${describeWidening(current, patch, now)}。",
                )
            }
            "resume" -> {
                val id = RoutineChangeArguments.requiredString(args, "routine_id")
                val current = machine.get(botId, id) ?: throw RoutineError.RoutineNotFound(id)
                RoutineChangeAssessment(
                    action = RoutineChangeAssessment.Action.RESUME,
                    routineId = id,
                    requiresConfirmation = !current.enabled,
                    resource = "routine:resume:${safeResource(id)}",
                    detail = "重新启用暂停的例行任务「${current.title}」会恢复它的自动触发。",
                )
            }
            else -> RoutineChangeAssessment(
                action = RoutineChangeAssessment.Action.OTHER,
                routineId = (args["routine_id"] as? JsonString)?.value,
                requiresConfirmation = false,
                resource = "routine:other",
                detail = "读、列、暂停或删除不改变自行触发的授权。",
            )
        }
    }

    fun isLoosening(current: Routine, patch: RoutinePatch, now: Long): Boolean {
        if (patch.enabled == true && !current.enabled) return true
        if (patch.delivery == RoutineDeliveryMode.INTERRUPT && current.delivery != RoutineDeliveryMode.INTERRUPT) {
            return true
        }
        if (patch.urgent == true && !current.urgent) return true
        val schedule = patch.schedule
        if (schedule != null && RoutineScheduleMath.isMoreFrequent(schedule, current = current.schedule, now = now)) {
            return true
        }
        return false
    }

    private fun describeWidening(current: Routine, patch: RoutinePatch, now: Long): String {
        val parts = ArrayList<String>()
        if (patch.enabled == true && !current.enabled) parts += "恢复自动触发"
        if (patch.delivery == RoutineDeliveryMode.INTERRUPT && current.delivery != RoutineDeliveryMode.INTERRUPT) {
            parts += "改为立即打断"
        }
        if (patch.urgent == true && !current.urgent) parts += "改为紧急"
        val schedule = patch.schedule
        if (schedule != null && RoutineScheduleMath.isMoreFrequent(schedule, current = current.schedule, now = now)) {
            parts += "触发更频繁"
        }
        return if (parts.isEmpty()) "无" else parts.joinToString("、")
    }

    private fun describe(patch: RoutinePatch): String {
        val parts = ArrayList<String>()
        patch.schedule?.let { parts += RoutineScheduleMath.expression(it) ?: it.kind.rawValue }
        patch.delivery?.let { parts += "delivery=${it.rawValue}" }
        patch.urgent?.let { parts += "urgent=$it" }
        patch.enabled?.let { parts += "enabled=$it" }
        return parts.joinToString(",")
    }

    private fun safeResource(value: String): String {
        val mapped = buildString {
            var index = 0
            while (index < value.length) {
                val scalar = value.codePointAt(index)
                index += Character.charCount(scalar)
                val character = String(Character.toChars(scalar))
                val allowed = character[0].isLetterOrDigit() || character[0] == '.' ||
                    character[0] == '_' || character[0] == '-'
                append(if (allowed) character else "_")
            }
        }
        return RoutineJson.prefixCodePoints(mapped, 120)
    }
}

/**
 * The subset of `UpdateRoutine` arguments the authority assessment reads.
 * The tool's request validation and response stay with the B5 MCP surface.
 */
internal object RoutineChangeArguments {
    fun title(args: Map<String, JsonValue>): String = requiredString(args, "title")

    fun requiredString(args: Map<String, JsonValue>, key: String): String {
        val value = (args[key] as? JsonString)?.value
        if (value == null || value.trim().isEmpty()) {
            throw RoutineError.InvalidRoutine("UpdateRoutine requires a non-empty $key")
        }
        return value
    }

    fun optionalString(value: JsonValue?): String? = when (value) {
        null -> null
        is JsonString -> value.value
        else -> throw RoutineError.InvalidRoutine("routine argument string is invalid")
    }

    fun patch(args: Map<String, JsonValue>, now: Long): RoutinePatch {
        var patch = RoutinePatch()
        args["title"]?.let { patch = patch.copy(title = requiredString(args, "title")) }
        args["prompt"]?.let { patch = patch.copy(prompt = requiredString(args, "prompt")) }
        args["schedule"]?.let { patch = patch.copy(schedule = schedule(it, now)) }
        (args["enabled"] as? com.phonedsh.agentcore.JsonBool)?.let { patch = patch.copy(enabled = it.value) }
        (args["urgent"] as? com.phonedsh.agentcore.JsonBool)?.let { patch = patch.copy(urgent = it.value) }
        args["urgent_reason"]?.let { patch = patch.copy(urgentReason = optionalString(it)) }
        args["delivery"]?.let {
            val mode = (it as? JsonString)?.value
                ?: throw RoutineError.InvalidRoutine("routine delivery must be a string")
            patch = patch.copy(delivery = RoutineDeliveryMode.from(mode))
        }
        args["interrupt_reason"]?.let { patch = patch.copy(interruptReason = optionalString(it)) }
        args["completion_criteria"]?.let { patch = patch.copy(completionCriteria = optionalString(it)) }
        args["constraints"]?.let { patch = patch.copy(constraints = optionalString(it)) }
        return patch
    }

    fun schedule(value: JsonValue, now: Long): RoutineSchedule {
        if (value is JsonString) return RoutineScheduleParser.parse(value.value, now = now)
        val members = (value as? JsonObject)?.members
            ?: throw RoutineError.InvalidSchedule("invalid routine schedule")
        val kindName = (members["kind"] as? JsonString)?.value
            ?: throw RoutineError.InvalidSchedule("invalid routine schedule")
        val timezone = (members["timezone"] as? JsonString)?.value ?: RoutineTime.defaultZoneId()
        return when (RoutineSchedule.Kind.from(kindName)) {
            RoutineSchedule.Kind.INTERVAL -> {
                val minutes = (members["everyMinutes"] as? JsonNumber)?.asLongOrNull()?.toInt()
                    ?: throw RoutineError.InvalidSchedule("everyMinutes must be at least 1")
                if (minutes < 1) throw RoutineError.InvalidSchedule("everyMinutes must be at least 1")
                RoutineSchedule.interval(minutes, timezone = timezone).validated()
            }
            RoutineSchedule.Kind.DAILY -> RoutineSchedule.daily(
                time = requiredString(members, "time"), timezone = timezone,
            ).validated()
            RoutineSchedule.Kind.WEEKLY -> {
                val days = (members["weekdays"] as? JsonArray)?.values?.map {
                    (it as? JsonNumber)?.asLongOrNull()?.toInt()
                        ?: throw RoutineError.InvalidSchedule("weekly schedule requires weekdays")
                } ?: throw RoutineError.InvalidSchedule("weekly schedule requires weekdays")
                RoutineSchedule.weekly(
                    time = requiredString(members, "time"), weekdays = days, timezone = timezone,
                ).validated()
            }
            RoutineSchedule.Kind.CRON -> RoutineSchedule.cron(
                expr = requiredString(members, "expr"), timezone = timezone,
            ).validated()
        }
    }
}
