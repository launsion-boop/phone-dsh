// SPDX-License-Identifier: MIT
package com.phonedsh.bot.ledger

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeFormatterBuilder
import java.time.format.DateTimeParseException
import kotlin.math.abs
import kotlin.math.roundToLong

/**
 * A frozen LLM ledger value could not be decoded or validated
 * (`spec/bot/v1/llm-ledger.schema.json`). The [field] is the member path that
 * failed; it is the Kotlin equivalent of Swift `BotLLMLedgerError.field`.
 */
public class BotLLMLedgerException(
    public val field: String,
    message: String,
    cause: Throwable? = null,
) : Exception("$field: $message", cause)

/**
 * One model step's usage (`llm-ledger.schema.json`, Swift
 * `Ledger/BotLLMLedgerRecord.swift`).
 *
 * The 14 schema-required members are always encoded, including explicit
 * `null` for the nullable ones. `ttftMs` is the one optional member and is
 * omitted when unavailable. [cacheHitRatio] defaults to the upstream formula
 * `cacheReadTokens / (inputTokens + cacheReadTokens + cacheWriteTokens)`.
 */
public data class BotLLMLedgerRecord(
    public val ts: String,
    public val botId: String?,
    public val sessionId: String?,
    public val purpose: BotModelPurpose,
    public val model: String?,
    public val provider: String?,
    public val inputTokens: Long,
    public val outputTokens: Long,
    public val cacheReadTokens: Long,
    public val cacheWriteTokens: Long,
    public val cacheHitRatio: Double = computeCacheHitRatio(
        inputTokens,
        cacheReadTokens,
        cacheWriteTokens,
    ),
    public val ttftMs: Long? = null,
    public val durationMs: Long?,
    public val status: String = "ok",
    public val errorKind: String? = null,
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["ts"] = JsonString(ts)
        members["botId"] = botId?.let(::JsonString) ?: JsonNull
        members["sessionId"] = sessionId?.let(::JsonString) ?: JsonNull
        members["purpose"] = JsonString(purpose.wire)
        members["model"] = model?.let(::JsonString) ?: JsonNull
        members["provider"] = provider?.let(::JsonString) ?: JsonNull
        members["inputTokens"] = JsonNumber(inputTokens.toString())
        members["outputTokens"] = JsonNumber(outputTokens.toString())
        members["cacheReadTokens"] = JsonNumber(cacheReadTokens.toString())
        members["cacheWriteTokens"] = JsonNumber(cacheWriteTokens.toString())
        members["cacheHitRatio"] = BotLedgerJson.number(cacheHitRatio)
        ttftMs?.let { members["ttftMs"] = JsonNumber(it.toString()) }
        members["durationMs"] = durationMs?.let { JsonNumber(it.toString()) } ?: JsonNull
        members["status"] = JsonString(status)
        members["errorKind"] = errorKind?.let(::JsonString) ?: JsonNull
        return JsonObject(members)
    }

    public fun encodeCanonical(): ByteArray =
        BotJson.canonical(toJson()).toByteArray(Charsets.UTF_8)

    /**
     * Checks the schema minimums plus the code-only cache formula
     * (`BotLLMLedgerRecord.swift:72-96`). Timestamp *format* is checked by
     * [BotLLMLedger.append] where the event `time` is derived.
     */
    public fun validate() {
        if (ts.length < 20) {
            throw BotLLMLedgerException("ts", "timestamp is too short")
        }
        for ((field, value) in listOf(
            "inputTokens" to inputTokens,
            "outputTokens" to outputTokens,
            "cacheReadTokens" to cacheReadTokens,
            "cacheWriteTokens" to cacheWriteTokens,
        )) {
            if (value < 0) {
                throw BotLLMLedgerException(field, "token counts must be non-negative")
            }
        }
        ttftMs?.let {
            if (it < 0) throw BotLLMLedgerException("ttftMs", "TTFT must be non-negative")
        }
        durationMs?.let {
            if (it < 0) throw BotLLMLedgerException("durationMs", "duration must be non-negative")
        }
        if (status.isEmpty()) {
            throw BotLLMLedgerException("status", "status must not be empty")
        }
        val expected = computeCacheHitRatio(inputTokens, cacheReadTokens, cacheWriteTokens)
        if (!cacheHitRatio.isFinite() || cacheHitRatio < 0.0 || cacheHitRatio > 1.0 ||
            abs(cacheHitRatio - expected) > RATIO_TOLERANCE
        ) {
            throw BotLLMLedgerException(
                "cacheHitRatio",
                "cacheHitRatio must equal cacheRead/(input+cacheRead+cacheWrite)",
            )
        }
    }

    public companion object {
        /** Same tolerance as Swift `BotLLMLedgerRecord.validate`. */
        public const val RATIO_TOLERANCE: Double = 1e-12

        private val REQUIRED_FIELDS: Set<String> = linkedSetOf(
            "ts", "botId", "sessionId", "purpose", "model", "provider",
            "inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens",
            "cacheHitRatio", "durationMs", "status", "errorKind",
        )

        private val ALL_FIELDS: Set<String> = REQUIRED_FIELDS + "ttftMs"

        private val TIMESTAMP_FORMATTER: DateTimeFormatter =
            DateTimeFormatterBuilder().appendInstant(3).toFormatter()

        /** `cacheRead / (input + cacheRead + cacheWrite)`, or 0 for an empty prompt. */
        public fun cacheHitRatio(
            inputTokens: Long,
            cacheReadTokens: Long,
            cacheWriteTokens: Long,
        ): Double = computeCacheHitRatio(inputTokens, cacheReadTokens, cacheWriteTokens)

        /** ISO-8601 UTC with exactly millisecond precision (`BotLLMLedgerRecord.timestamp`). */
        public fun timestamp(epochMillis: Long): String =
            TIMESTAMP_FORMATTER.format(Instant.ofEpochMilli(epochMillis))

        /** Parses the frozen `ts` forms: `...Z` and, as a fallback, an explicit offset. */
        public fun parseTimestamp(timestamp: String): Instant? {
            return try {
                Instant.parse(timestamp)
            } catch (_: DateTimeParseException) {
                try {
                    OffsetDateTime.parse(timestamp, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant()
                } catch (_: DateTimeParseException) {
                    null
                }
            }
        }

        /** The event `time`: the same instant in epoch milliseconds, rounded like Swift. */
        public fun eventTimeMillis(timestamp: String): Long? {
            val instant = parseTimestamp(timestamp) ?: return null
            return instant.epochSecond * 1_000L +
                (instant.nano / 1_000_000.0).roundToLong()
        }

        public fun fromJson(value: JsonValue): BotLLMLedgerRecord {
            val members = (value as? JsonObject)?.members
                ?: throw BotLLMLedgerException("record", "record must be an object")
            val unknown = members.keys.firstOrNull { it !in ALL_FIELDS }
            if (unknown != null) {
                throw BotLLMLedgerException(unknown, "unknown LLM ledger member")
            }

            val record = BotLLMLedgerRecord(
                ts = requiredString(members, "ts"),
                botId = requiredNullableString(members, "botId"),
                sessionId = requiredNullableString(members, "sessionId"),
                purpose = requiredPurpose(members),
                model = requiredNullableString(members, "model"),
                provider = requiredNullableString(members, "provider"),
                inputTokens = requiredInteger(members, "inputTokens"),
                outputTokens = requiredInteger(members, "outputTokens"),
                cacheReadTokens = requiredInteger(members, "cacheReadTokens"),
                cacheWriteTokens = requiredInteger(members, "cacheWriteTokens"),
                cacheHitRatio = requiredNumber(members, "cacheHitRatio"),
                ttftMs = optionalInteger(members, "ttftMs"),
                durationMs = requiredNullableInteger(members, "durationMs"),
                status = requiredString(members, "status"),
                errorKind = requiredNullableString(members, "errorKind"),
            )
            record.validate()
            return record
        }

        public fun decode(json: String): BotLLMLedgerRecord {
            val parsed = try {
                JsonValue.parse(json)
            } catch (error: Exception) {
                throw BotLLMLedgerException("record", "record is not valid JSON", error)
            }
            return fromJson(parsed)
        }

        private fun computeCacheHitRatio(
            inputTokens: Long,
            cacheReadTokens: Long,
            cacheWriteTokens: Long,
        ): Double {
            val input = maxOf(0L, inputTokens).toDouble()
            val read = maxOf(0L, cacheReadTokens).toDouble()
            val write = maxOf(0L, cacheWriteTokens).toDouble()
            val prompt = input + read + write
            return if (prompt > 0.0) read / prompt else 0.0
        }

        private fun requiredValue(members: Map<String, JsonValue>, key: String): JsonValue =
            members[key] ?: throw BotLLMLedgerException(key, "missing required member")

        private fun requiredString(members: Map<String, JsonValue>, key: String): String =
            when (val value = requiredValue(members, key)) {
                is JsonString -> value.value
                else -> throw BotLLMLedgerException(key, "must be a string")
            }

        private fun requiredNullableString(
            members: Map<String, JsonValue>,
            key: String,
        ): String? = when (val value = requiredValue(members, key)) {
            is JsonNull -> null
            is JsonString -> value.value
            else -> throw BotLLMLedgerException(key, "must be a string or null")
        }

        private fun requiredPurpose(members: Map<String, JsonValue>): BotModelPurpose {
            val text = requiredString(members, "purpose")
            return BotModelPurpose.parse(text)
                ?: throw BotLLMLedgerException("purpose", "unknown purpose: $text")
        }

        private fun requiredInteger(members: Map<String, JsonValue>, key: String): Long =
            (requiredValue(members, key) as? JsonNumber)?.asLongOrNull()
                ?: throw BotLLMLedgerException(key, "must be an integer")

        private fun requiredNullableInteger(
            members: Map<String, JsonValue>,
            key: String,
        ): Long? = when (val value = requiredValue(members, key)) {
            is JsonNull -> null
            is JsonNumber -> value.asLongOrNull()
                ?: throw BotLLMLedgerException(key, "must be an integer or null")
            else -> throw BotLLMLedgerException(key, "must be an integer or null")
        }

        /**
         * `ttftMs` is optional. An explicit `null` is *not* the same as
         * omission: the schema type is integer, and the frozen rule is
         * `omit_when_unavailable`.
         */
        private fun optionalInteger(members: Map<String, JsonValue>, key: String): Long? =
            when (val value = members[key]) {
                null -> null
                is JsonNumber -> value.asLongOrNull()
                    ?: throw BotLLMLedgerException(key, "must be an integer when present")
                else -> throw BotLLMLedgerException(key, "must be an integer when present")
            }

        private fun requiredNumber(members: Map<String, JsonValue>, key: String): Double {
            val number = requiredValue(members, key) as? JsonNumber
                ?: throw BotLLMLedgerException(key, "must be a number")
            val parsed = number.raw.toDoubleOrNull()
                ?: throw BotLLMLedgerException(key, "must be a number")
            if (!parsed.isFinite()) {
                throw BotLLMLedgerException(key, "must be a finite number")
            }
            return parsed
        }
    }
}

/** Strict JSON accessors shared by the ledger codecs. */
internal object BotLedgerJson {
    fun objectMembers(value: JsonValue?, path: String): Map<String, JsonValue> =
        when (value) {
            null -> throw BotLLMLedgerException(path, "missing required member")
            is JsonObject -> value.members
            else -> throw BotLLMLedgerException(path, "must be an object")
        }

    fun rejectUnknown(
        members: Map<String, JsonValue>,
        path: String,
        allowed: Set<String>,
    ) {
        val unknown = members.keys.firstOrNull { it !in allowed } ?: return
        throw BotLLMLedgerException("$path.$unknown", "unknown member")
    }

    fun string(value: JsonValue?, path: String): String = when (value) {
        null -> throw BotLLMLedgerException(path, "missing required member")
        is JsonString -> value.value
        else -> throw BotLLMLedgerException(path, "must be a string")
    }

    fun boolean(value: JsonValue?, path: String): Boolean = when (value) {
        null -> throw BotLLMLedgerException(path, "missing required member")
        is JsonBool -> value.value
        else -> throw BotLLMLedgerException(path, "must be a boolean")
    }

    fun integer(value: JsonValue?, path: String): Int {
        val number = (value as? JsonNumber)?.asLongOrNull()
            ?: throw BotLLMLedgerException(path, "must be an integer")
        if (number < Int.MIN_VALUE || number > Int.MAX_VALUE) {
            throw BotLLMLedgerException(path, "is out of range")
        }
        return number.toInt()
    }

    fun number(value: JsonValue?, path: String): Double {
        val number = value as? JsonNumber
            ?: throw BotLLMLedgerException(path, "must be a number")
        val parsed = number.raw.toDoubleOrNull()
            ?: throw BotLLMLedgerException(path, "must be a number")
        if (!parsed.isFinite()) {
            throw BotLLMLedgerException(path, "must be a finite number")
        }
        return parsed
    }

    fun array(value: JsonValue?, path: String): List<JsonValue> = when (value) {
        null -> throw BotLLMLedgerException(path, "missing required member")
        is JsonArray -> value.values
        else -> throw BotLLMLedgerException(path, "must be an array")
    }

    fun number(value: Long): JsonNumber = JsonNumber(value.toString())

    /**
     * Encodes a JSON number the way Swift's `JSONEncoder` does for `Double`:
     * integral values lose the `.0` (for example `1.0` becomes `1`).
     */
    fun number(value: Double): JsonNumber {
        require(value.isFinite()) { "JSON cannot encode a non-finite number" }
        if (value == 0.0) return JsonNumber("0")
        if (value % 1.0 == 0.0 && value >= Long.MIN_VALUE.toDouble() &&
            value <= Long.MAX_VALUE.toDouble()
        ) {
            return JsonNumber(value.toLong().toString())
        }
        return JsonNumber(value.toString())
    }
}
