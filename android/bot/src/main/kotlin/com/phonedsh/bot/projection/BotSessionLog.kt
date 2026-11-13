// SPDX-License-Identifier: MIT
package com.phonedsh.bot.projection

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import java.math.BigDecimal

/**
 * A DSH surface placement marker (`projection.md` §2.4). Only the canonical
 * v3/v4 shapes exist here: `"append"` and the three-member replace object.
 */
public sealed interface BotSurfaceOp {
    public data object Append : BotSurfaceOp

    public data class Replace(
        public val startSeq: Long,
        public val endSeq: Long,
    ) : BotSurfaceOp

    public companion object {
        /** `null` when [value] is not one of the two canonical shapes. */
        public fun decode(value: JsonValue?): BotSurfaceOp? {
            if (value == null) return null
            when (value) {
                is JsonString -> return if (value.value == "append") Append else null
                is JsonObject -> {
                    val members = value.members
                    if (members.size != 3) return null
                    if ((members["op"] as? JsonString)?.value != "replace") return null
                    val start = integer(members["startSeq"]) ?: return null
                    val end = integer(members["endSeq"]) ?: return null
                    if (start < 0 || end < start) return null
                    return Replace(start, end)
                }
                else -> return null
            }
        }

        private fun integer(value: JsonValue?): Long? {
            val number = value as? JsonNumber ?: return null
            return integerValue(number)
        }
    }
}

/** One decoded DSH session-log record (`projection.md` §2.3). */
public data class BotSessionLogRecord(
    public val type: String,
    public val seq: Long,
    public val time: Long,
    public val data: Map<String, JsonValue>,
    public val surfaceOp: BotSurfaceOp? = null,
    public val eventId: String? = null,
)

/** One skipped JSONL line (`projection.md` §2.5). [seq] is best effort. */
public data class BotSessionLogSkippedRecord(
    public val lineNumber: Int,
    public val seq: Long?,
)

/** The parse result; damaged lines never fail the whole log. */
public data class BotSessionLogParseResult(
    public val records: List<BotSessionLogRecord>,
    public val skipped: List<BotSessionLogSkippedRecord> = emptyList(),
)

/**
 * The normative DSH session JSONL decoder (`projection.md` §2).
 *
 * The first non-empty record may be the v4 header and is skipped only when
 * every listed member is present with its type. Every other non-empty line
 * must decode as an event; failures are reported with their 1-based physical
 * line number and continue.
 */
public object BotSessionLogParser {
    public fun parseJsonl(text: String): BotSessionLogParseResult {
        val records = ArrayList<BotSessionLogRecord>()
        val skipped = ArrayList<BotSessionLogSkippedRecord>()
        var firstRecord = true
        var lineNumber = 0
        var start = 0
        while (start <= text.length) {
            lineNumber += 1
            val end = text.indexOf('\n', start)
            val raw = if (end < 0) text.substring(start) else text.substring(start, end)
            // §2.1 drops leading 0x20/0x09/0x0D only; JsonValue.parse
            // tolerates trailing JSON whitespace exactly as JSONDecoder does.
            val line = raw.dropWhile { it == ' ' || it == '\t' || it == '\r' }
            if (line.isNotEmpty()) {
                val value = try {
                    JsonValue.parse(line)
                } catch (_: Exception) {
                    null
                }
                if (firstRecord) {
                    firstRecord = false
                    if (value != null && isV4Header(value)) {
                        if (end < 0) break
                        start = end + 1
                        continue
                    }
                }
                val record = try {
                    value?.let { decodeRecord(it) }
                } catch (_: Exception) {
                    null
                }
                if (record != null) {
                    records.add(record)
                } else {
                    skipped.add(BotSessionLogSkippedRecord(lineNumber, diagnosticSeq(value)))
                }
            }
            if (end < 0) break
            start = end + 1
        }
        return BotSessionLogParseResult(records = records, skipped = skipped)
    }

    private fun isV4Header(value: JsonValue): Boolean {
        val members = (value as? JsonObject)?.members ?: return false
        if ((members["type"] as? JsonString)?.value != "session") return false
        if (integer(members["version"]) != 4L) return false
        if (members["id"] !is JsonString) return false
        if (integer(members["createdAt"]) == null) return false
        if (members["isSeeded"] !is JsonBool) return false
        if (integer(members["delegationDepth"]) == null) return false
        return true
    }

    private fun decodeRecord(value: JsonValue): BotSessionLogRecord? {
        val members = (value as? JsonObject)?.members ?: return null
        val type = (members["type"] as? JsonString)?.value ?: return null
        val seq = integer(members["seq"]) ?: return null
        val time = integer(members["time"]) ?: return null
        val data = (members["data"] as? JsonObject)?.members ?: return null
        val eventId = when (val event = members["eventId"]) {
            null, is JsonNull -> null
            is JsonString -> event.value
            else -> return null
        }
        val surfaceOp = when (val surface = members["surfaceOp"]) {
            null, is JsonNull -> null
            else -> BotSurfaceOp.decode(surface) ?: return null
        }
        return BotSessionLogRecord(
            type = type,
            seq = seq,
            time = time,
            data = data,
            surfaceOp = surfaceOp,
            eventId = eventId,
        )
    }

    private fun diagnosticSeq(value: JsonValue?): Long? {
        val members = (value as? JsonObject)?.members ?: return null
        val number = members["seq"] as? JsonNumber ?: return null
        return integerValue(number)
    }

    private fun integer(value: JsonValue?): Long? =
        (value as? JsonNumber)?.let { integerValue(it) }

}

private fun integerValue(number: JsonNumber): Long? {
    val raw = number.raw
    if (raw.indexOf('.') < 0 && raw.indexOf('e') < 0 && raw.indexOf('E') < 0) {
        return raw.toLongOrNull()
    }
    val decimal = try {
        BigDecimal(raw)
    } catch (_: NumberFormatException) {
        return null
    }
    if (decimal.stripTrailingZeros().scale() > 0) return null
    return try {
        decimal.longValueExact()
    } catch (_: ArithmeticException) {
        null
    }
}

/** Durable event origin (`BotEventOrigin`). */
public sealed interface BotProjectionOrigin {
    public data class Local(public val source: String) : BotProjectionOrigin

    public data class Dsh(public val sessionId: String, public val seq: Long) : BotProjectionOrigin

    public val isDirectUser: Boolean
        get() = this is Local && source == "user"
}

/**
 * The projection's durable BotEvent input (`projection.md` §6). Only the
 * members the projector reads are retained; the store's full `BotEvent` type
 * is owned by P25 and is wired in by the integrator.
 */
public data class BotProjectionEvent(
    public val type: String,
    public val eventId: String,
    public val time: Long,
    public val commitSeq: Long?,
    public val origin: BotProjectionOrigin,
    public val principalBotId: String?,
    public val principalSessionId: String?,
    public val turnId: String?,
    public val runId: String?,
    public val data: JsonValue,
) {
    public val isErasedPayload: Boolean
        get() = ((data as? JsonObject)?.members?.get("\$erased") as? JsonBool)?.value == true

    public companion object {
        public fun fromJson(value: JsonValue): BotProjectionEvent {
            val members = (value as? JsonObject)?.members
                ?: throw IllegalArgumentException("event must be an object")
            val type = (members["type"] as? JsonString)?.value
                ?: throw IllegalArgumentException("event.type must be a string")
            val eventId = (members["eventId"] as? JsonString)?.value
                ?: throw IllegalArgumentException("event.eventId must be a string")
            val time = long(members["time"])
                ?: throw IllegalArgumentException("event.time must be an integer")
            val origin = origin(members["origin"])
            val principal = (members["principal"] as? JsonObject)?.members
            return BotProjectionEvent(
                type = type,
                eventId = eventId,
                time = time,
                commitSeq = long(members["commitSeq"]),
                origin = origin,
                principalBotId = (principal?.get("botId") as? JsonString)?.value,
                principalSessionId = (principal?.get("sessionId") as? JsonString)?.value,
                turnId = string(members["turnId"]),
                runId = string(members["runId"]),
                data = members["data"] ?: JsonNull,
            )
        }

        private fun origin(value: JsonValue?): BotProjectionOrigin {
            val members = (value as? JsonObject)?.members
                ?: return BotProjectionOrigin.Local("")
            return when ((members["kind"] as? JsonString)?.value) {
                "dsh" -> BotProjectionOrigin.Dsh(
                    sessionId = (members["sessionId"] as? JsonString)?.value ?: "",
                    seq = long(members["seq"]) ?: 0L,
                )
                "local" -> BotProjectionOrigin.Local(
                    (members["source"] as? JsonString)?.value ?: "")
                else -> BotProjectionOrigin.Local("")
            }
        }

        private fun string(value: JsonValue?): String? = (value as? JsonString)?.value

        private fun long(value: JsonValue?): Long? =
            (value as? JsonNumber)?.asLongOrNull()
    }
}

/** Convenience for the test/decoder: `JsonArray` members as a list. */
internal fun jsonArray(value: JsonValue?): List<JsonValue> =
    (value as? JsonArray)?.values ?: emptyList()
