// SPDX-License-Identifier: MIT
package com.phonedsh.bot.proactive

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import java.util.Locale
import java.util.Objects

/**
 * P26 proactive value types frozen by
 * `spec/bot/v2/proactive-decision.schema.json` and README §3.0.
 *
 * The schema is the authority for the wire names. Kotlin enums keep the same
 * closed sets so an unknown value fails closed instead of silently widening
 * the contract.
 */
public enum class ProactiveMode(public val wire: String) {
    OFF("off"),
    WOULD("would"),
    ON("on"),
    ;

    public companion object {
        public fun parse(value: String?): ProactiveMode? = entries.firstOrNull { it.wire == value }
    }
}

public enum class ProactiveKind(public val wire: String) {
    TASK_DONE("task-done"),
    ROUTINE_RESULT("routine-result"),
    REMINDER("reminder"),
    ;

    public companion object {
        public val wireValues: List<String> = entries.map { it.wire }

        public fun parse(value: String?): ProactiveKind? = entries.firstOrNull { it.wire == value }
    }
}

public enum class ProactiveDecisionKind(public val wire: String) {
    DID("did"),
    WOULD("would"),
    SKIP("skip"),
    ;

    public companion object {
        public val wireValues: List<String> = entries.map { it.wire }

        public fun parse(value: String?): ProactiveDecisionKind? =
            entries.firstOrNull { it.wire == value }
    }
}

/** The complete `reason` set from README §3.0. */
public enum class ProactiveReason(public val wire: String) {
    DELIVERED("delivered"),
    WOULD_MODE("would-mode"),
    WOULD_ONLY_KIND("would-only-kind"),
    MODE_OFF("mode-off"),
    FUSE("fuse"),
    DND("dnd"),
    QUIET_HOURS("quiet-hours"),
    MISSING_BOT("missing-bot"),
    DELIVERY_FAILED("delivery-failed"),
    DELIVERY_UNAVAILABLE("delivery-unavailable"),
    ROUTINE_HELD("routine-held"),
    ROUTINE_QUIET("routine-quiet"),
    ;

    public companion object {
        public val wireValues: List<String> = entries.map { it.wire }

        public fun parse(value: String?): ProactiveReason? =
            entries.firstOrNull { it.wire == value }
    }
}

/** `$defs.proactiveCandidate.delivery`; only routine results carry one. */
public enum class ProactiveDeliveryMode(public val wire: String) {
    HELD("held"),
    INTERRUPT("interrupt"),
    ;

    public companion object {
        public fun parse(value: String?): ProactiveDeliveryMode? =
            entries.firstOrNull { it.wire == value }
    }
}

/** A shared candidate document violates the frozen schema. */
public class ProactiveCandidateException(
    public val code: String,
    public val path: String,
    message: String = "$code at $path",
) : Exception(message)

/**
 * One proactive candidate (`proactive-decision.schema.json`
 * `$defs.proactiveCandidate`).
 *
 * `kind`, `botId` and `createdAt` are required; every other member is optional
 * and is omitted again by [toJson] when absent. `botId` is deliberately not
 * trimmed here: a whitespace-only id is a valid document that the engine later
 * refuses with `missing-bot`.
 */
public data class ProactiveCandidate(
    public val kind: ProactiveKind,
    public val botId: String,
    public val createdAt: Long,
    public val id: String? = null,
    public val dedupeKey: String? = null,
    public val trigger: String? = null,
    public val sourceEventId: String? = null,
    public val channel: String = "system-notification",
    public val title: String? = null,
    public val body: String? = null,
    public val taskId: String? = null,
    public val taskTitle: String? = null,
    public val summary: String? = null,
    public val status: String? = null,
    public val routineId: String? = null,
    public val runId: String? = null,
    public val attempt: Int? = null,
    public val delivery: ProactiveDeliveryMode? = null,
    public val quiet: Boolean = false,
    public val resultExcerpt: String? = null,
    public val deliveryKey: String? = null,
    public val rowId: String? = null,
    public val reminderId: String? = null,
    public val allowDuringDnd: Boolean = false,
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        id?.let { members["id"] = JsonString(it) }
        members["kind"] = JsonString(kind.wire)
        members["botId"] = JsonString(botId)
        dedupeKey?.let { members["dedupeKey"] = JsonString(it) }
        trigger?.let { members["trigger"] = JsonString(it) }
        sourceEventId?.let { members["sourceEventId"] = JsonString(it) }
        members["createdAt"] = BotJson.number(createdAt)
        members["channel"] = JsonString(channel)
        title?.let { members["title"] = JsonString(it) }
        body?.let { members["body"] = JsonString(it) }
        taskId?.let { members["taskId"] = JsonString(it) }
        taskTitle?.let { members["taskTitle"] = JsonString(it) }
        summary?.let { members["summary"] = JsonString(it) }
        status?.let { members["status"] = JsonString(it) }
        routineId?.let { members["routineId"] = JsonString(it) }
        runId?.let { members["runId"] = JsonString(it) }
        attempt?.let { members["attempt"] = BotJson.number(it.toLong()) }
        delivery?.let { members["delivery"] = JsonString(it.wire) }
        members["quiet"] = JsonBool(quiet)
        resultExcerpt?.let { members["resultExcerpt"] = JsonString(it) }
        deliveryKey?.let { members["deliveryKey"] = JsonString(it) }
        rowId?.let { members["rowId"] = JsonString(it) }
        reminderId?.let { members["reminderId"] = JsonString(it) }
        members["allowDuringDnd"] = JsonBool(allowDuringDnd)
        return JsonObject(members)
    }

    public companion object {
        public val FIELDS: List<String> = listOf(
            "id", "kind", "botId", "dedupeKey", "trigger", "sourceEventId", "createdAt",
            "channel", "title", "body", "taskId", "taskTitle", "summary", "status",
            "routineId", "runId", "attempt", "delivery", "quiet", "resultExcerpt",
            "deliveryKey", "rowId", "reminderId", "allowDuringDnd",
        )
        public val REQUIRED_FIELDS: List<String> = listOf("kind", "botId", "createdAt")
        private val OPTIONAL_STRING_FIELDS: List<String> = listOf(
            "id", "dedupeKey", "trigger", "sourceEventId", "channel", "title", "body",
            "taskId", "taskTitle", "summary", "status", "routineId", "runId",
            "resultExcerpt", "deliveryKey", "rowId", "reminderId",
        )

        /** Strict shared-document decoder; the first violation is the golden code/path. */
        public fun fromJson(value: JsonValue?): ProactiveCandidate {
            val members = (value as? JsonObject)?.members
                ?: throw ProactiveCandidateException("proactive-candidate-type", "$")
            val unknown = members.keys.filterNot(FIELDS::contains).sorted().firstOrNull()
            if (unknown != null) {
                throw ProactiveCandidateException(
                    "proactive-candidate-unknown-field", "$.$unknown",
                )
            }
            for (field in REQUIRED_FIELDS) {
                if (!members.containsKey(field)) {
                    throw ProactiveCandidateException(
                        "proactive-candidate-missing-field", "$.$field",
                    )
                }
            }

            val kindText = members["kind"] as? JsonString
                ?: throw ProactiveCandidateException("proactive-candidate-type", "$.kind")
            val kind = ProactiveKind.parse(kindText.value)
                ?: throw ProactiveCandidateException(
                    "proactive-candidate-unknown-enum", "$.kind",
                )

            val botId = members["botId"] as? JsonString
                ?: throw ProactiveCandidateException("proactive-candidate-type", "$.botId")
            if (botId.value.isEmpty()) {
                throw ProactiveCandidateException(
                    "proactive-candidate-min-length", "$.botId",
                )
            }

            val createdAtValue = members["createdAt"] as? JsonNumber
                ?: throw ProactiveCandidateException(
                    "proactive-candidate-type", "$.createdAt",
                )
            val createdAt = createdAtValue.asLongOrNull()
                ?: throw ProactiveCandidateException(
                    "proactive-candidate-type", "$.createdAt",
                )
            if (createdAt < 0) {
                throw ProactiveCandidateException(
                    "proactive-candidate-range", "$.createdAt",
                )
            }

            val strings = LinkedHashMap<String, String>()
            for (field in OPTIONAL_STRING_FIELDS) {
                val raw = members[field] ?: continue
                val text = raw as? JsonString
                    ?: throw ProactiveCandidateException(
                        "proactive-candidate-type", "$.$field",
                    )
                strings[field] = text.value
            }
            val channel = strings["channel"]
            if (channel != null && channel.isEmpty()) {
                throw ProactiveCandidateException(
                    "proactive-candidate-min-length", "$.channel",
                )
            }

            val delivery = when (val raw = members["delivery"]) {
                null -> null
                is JsonString -> ProactiveDeliveryMode.parse(raw.value)
                    ?: throw ProactiveCandidateException(
                        "proactive-candidate-unknown-enum", "$.delivery",
                    )
                else -> throw ProactiveCandidateException(
                    "proactive-candidate-type", "$.delivery",
                )
            }

            val attempt = when (val raw = members["attempt"]) {
                null -> null
                is JsonNumber -> {
                    val number = raw.asLongOrNull()
                        ?: throw ProactiveCandidateException(
                            "proactive-candidate-type", "$.attempt",
                        )
                    if (number < 0) {
                        throw ProactiveCandidateException(
                            "proactive-candidate-range", "$.attempt",
                        )
                    }
                    number.toInt()
                }
                else -> throw ProactiveCandidateException(
                    "proactive-candidate-type", "$.attempt",
                )
            }

            fun optionalBool(field: String): Boolean? = when (val raw = members[field]) {
                null -> null
                is JsonBool -> raw.value
                else -> throw ProactiveCandidateException(
                    "proactive-candidate-type", "$.$field",
                )
            }
            val quiet = optionalBool("quiet") ?: false
            val allowDuringDnd = optionalBool("allowDuringDnd") ?: false

            val rowId = strings["rowId"]
            if (rowId != null && rowId.isEmpty()) {
                throw ProactiveCandidateException(
                    "proactive-candidate-min-length", "$.rowId",
                )
            }

            return ProactiveCandidate(
                kind = kind,
                botId = botId.value,
                createdAt = createdAt,
                id = strings["id"],
                dedupeKey = strings["dedupeKey"],
                trigger = strings["trigger"],
                sourceEventId = strings["sourceEventId"],
                channel = channel ?: "system-notification",
                title = strings["title"],
                body = strings["body"],
                taskId = strings["taskId"],
                taskTitle = strings["taskTitle"],
                summary = strings["summary"],
                status = strings["status"],
                routineId = strings["routineId"],
                runId = strings["runId"],
                attempt = attempt,
                delivery = delivery,
                quiet = quiet,
                resultExcerpt = strings["resultExcerpt"],
                deliveryKey = strings["deliveryKey"],
                rowId = rowId,
                reminderId = strings["reminderId"],
                allowDuringDnd = allowDuringDnd,
            )
        }
    }
}

/**
 * `ProactiveNotification` (`proactive-decision.schema.json`). Title and body
 * are clipped by Unicode scalar count on construction; `deepLink` is present
 * exactly when `rowId` is present.
 */
public class ProactiveNotification(
    title: String,
    body: String,
    public val kind: ProactiveKind,
    public val botId: String,
    public val dedupeKey: String,
    public val channel: String = "system-notification",
    public val rowId: String? = null,
) {
    public val title: String = clipCodePoints(title, 120)
    public val body: String = clipCodePoints(body, 500)
    public val deepLink: String? = rowId?.let { ProactiveDeepLink.make(botId, it) }

    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["title"] = JsonString(title)
        members["body"] = JsonString(body)
        members["kind"] = JsonString(kind.wire)
        members["botId"] = JsonString(botId)
        members["dedupeKey"] = JsonString(dedupeKey)
        members["channel"] = JsonString(channel)
        rowId?.let { members["rowId"] = JsonString(it) }
        deepLink?.let { members["deepLink"] = JsonString(it) }
        return JsonObject(members)
    }

    override fun equals(other: Any?): Boolean =
        other is ProactiveNotification &&
            title == other.title &&
            body == other.body &&
            kind == other.kind &&
            botId == other.botId &&
            dedupeKey == other.dedupeKey &&
            channel == other.channel &&
            rowId == other.rowId

    override fun hashCode(): Int = Objects.hash(title, body, kind, botId, dedupeKey, channel, rowId)

    override fun toString(): String =
        "ProactiveNotification(title=$title, body=$body, kind=${kind.wire}, botId=$botId, " +
            "dedupeKey=$dedupeKey, channel=$channel, rowId=$rowId)"
}

/** `ProactiveDeliveryResult`; `error` is present only for a failed delivery. */
public data class ProactiveDeliveryResult(
    public val delivered: Boolean,
    public val channel: String = "system-notification",
    public val error: String? = null,
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["delivered"] = JsonBool(delivered)
        members["channel"] = JsonString(channel)
        error?.let { members["error"] = JsonString(it) }
        return JsonObject(members)
    }
}

/** One `proactive.considered` decision record. */
public data class ProactiveDecision(
    public val id: String,
    public val at: Long,
    public val decision: ProactiveDecisionKind,
    public val reason: ProactiveReason,
    public val kind: ProactiveKind,
    public val botId: String,
    public val dedupeKey: String,
    public val mode: ProactiveMode,
    public val channel: String,
    public val notification: ProactiveNotification,
    public val delivery: ProactiveDeliveryResult? = null,
    public val commitSeq: Long? = null,
) {
    /**
     * Whether this consideration contributes to the frequency fuse. It is not
     * part of the decision JSON (the schema closes the object); the host writes
     * the same value into `proactive.considered.data.fuseRecorded`.
     */
    public val fuseRecorded: Boolean
        get() = decision == ProactiveDecisionKind.DID ||
            (decision == ProactiveDecisionKind.WOULD && reason == ProactiveReason.WOULD_MODE)

    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["id"] = JsonString(id)
        members["at"] = BotJson.number(at)
        members["decision"] = JsonString(decision.wire)
        members["reason"] = JsonString(reason.wire)
        members["kind"] = JsonString(kind.wire)
        members["botId"] = JsonString(botId)
        members["dedupeKey"] = JsonString(dedupeKey)
        members["mode"] = JsonString(mode.wire)
        members["channel"] = JsonString(channel)
        members["notification"] = notification.toJson()
        delivery?.let { members["delivery"] = it.toJson() }
        commitSeq?.let { members["commitSeq"] = BotJson.number(it) }
        return JsonObject(members)
    }
}

/** `phonedsh://bot/<botId>/row/<rowId>`, with percent-encoded path segments. */
public object ProactiveDeepLink {
    public const val SCHEME: String = "phonedsh://bot/"

    private const val PATH_SAFE = "-._~!$&'()*+,;=:@"

    public fun make(botId: String, rowId: String): String =
        "$SCHEME${escape(botId)}/row/${escape(rowId)}"

    public fun parse(value: String): Pair<String, String>? {
        if (!value.startsWith(SCHEME)) return null
        val parts = value.substring(SCHEME.length).split('/')
        if (parts.size != 3 || parts[1] != "row") return null
        val botId = percentDecode(parts[0]) ?: return null
        val rowId = percentDecode(parts[2]) ?: return null
        if (botId.isEmpty() || rowId.isEmpty()) return null
        return botId to rowId
    }

    private fun escape(value: String): String {
        val out = StringBuilder()
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            val unsigned = byte.toInt() and 0xFF
            val character = unsigned.toChar()
            val allowed = (character in 'a'..'z') ||
                (character in 'A'..'Z') ||
                (character in '0'..'9') ||
                character in PATH_SAFE
            if (allowed) {
                out.append(character)
            } else {
                out.append('%')
                out.append(unsigned.toString(16).uppercase(Locale.ROOT).padStart(2, '0'))
            }
        }
        return out.toString()
    }

    private fun percentDecode(value: String): String? {
        val bytes = ArrayList<Byte>()
        var index = 0
        while (index < value.length) {
            val character = value[index]
            if (character == '%') {
                if (index + 2 >= value.length) return null
                val hex = value.substring(index + 1, index + 3).toIntOrNull(16) ?: return null
                bytes += hex.toByte()
                index += 3
            } else {
                for (byte in character.toString().toByteArray(Charsets.UTF_8)) bytes += byte
                index++
            }
        }
        return String(bytes.toByteArray(), Charsets.UTF_8)
    }
}

/** `status` labels shared by the default notification copy (README §3.0). */
internal fun proactiveStatusLabel(status: String?): String {
    if (status == null) return "已结束"
    return when (status.lowercase(Locale.ROOT)) {
        "completed", "succeeded", "ok", "sent" -> "已完成"
        "stopped", "canceled", "cancelled" -> "已停止"
        "timed_out", "timeout", "timed-out" -> "超时"
        "error", "failed", "failure" -> "失败"
        else -> status
    }
}

/** `String.prefix(n)` over Unicode scalars; never split a surrogate pair. */
internal fun clipCodePoints(value: String, limit: Int): String {
    if (limit <= 0) return ""
    if (value.codePointCount(0, value.length) <= limit) return value
    return value.substring(0, value.offsetByCodePoints(0, limit))
}

/** JSON array of enum wire names, used by the settings writer. */
internal fun proactiveKindArray(kinds: List<ProactiveKind>): JsonArray =
    JsonArray(kinds.map { JsonString(it.wire) })
