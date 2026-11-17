// SPDX-License-Identifier: MIT
// Value types and the closed codec of the external admission journal
// (spec/host/v1/external-admission.md, revision external-admission-v1;
// schema/admission-record.schema.json).
//
// The decoder is the schema made executable plus the identity law: a record
// whose `admissionId` is not the digest of its own principal, source and
// request id is not a record. A value this build cannot read (a newer `v`, an
// unknown stage, source kind or target kind, an unknown member) rejects the
// whole record; the journal then treats the file as undecodable.
package com.phonedsh.probe.admission

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import java.security.MessageDigest

internal enum class AdmissionStage(val wire: String) {
    ADMITTED("admitted"),
    DISPATCHING("dispatching"),
    LINKED("linked"),
    COMPLETED("completed"),
    FAILED("failed"),
    EXPIRED("expired"),
    CANCELLED("cancelled"),
    UNKNOWN("unknown"),
    ;

    /** `admitted` or `dispatching`: the record still carries `text` and counts toward the pending bound. */
    val isPending: Boolean get() = this == ADMITTED || this == DISPATCHING

    /** No edge leaves a terminal stage; the record is the dedupe tombstone until sweep deletes it. */
    val isTerminal: Boolean get() = !isPending && this != LINKED

    companion object {
        fun fromWire(value: String): AdmissionStage? = entries.firstOrNull { it.wire == value }
    }
}

internal enum class AdmissionSourceKind(val wire: String) {
    TONOLINK_VOICE("tonolink-voice"),
    CLOUD_TASK("cloud-task"),
    ;

    companion object {
        fun fromWire(value: String): AdmissionSourceKind? = entries.firstOrNull { it.wire == value }
    }
}

/** The adapter that received the request and that adapter's own stable id. */
internal data class AdmissionSource(val kind: AdmissionSourceKind, val id: String)

/** Fixed at admission. Delivery never re-reads "the currently selected chat". */
internal sealed interface AdmissionTarget {
    data class DshSession(val sessionId: String) : AdmissionTarget

    data class Bot(val botId: String) : AdmissionTarget
}

internal data class AdmissionRecord(
    val v: Int = 1,
    val admissionId: String,
    val principal: String,
    val source: AdmissionSource,
    val sourceRequestId: String,
    val target: AdmissionTarget,
    val contentSha256: String,
    /** Present exactly while the record is pending. */
    val text: String? = null,
    /** The send-outbox `rpcId` (dsh-session) or the user-action nonce (bot). Immutable. */
    val downstreamId: String,
    val admittedAtMs: Long,
    val expiresAtMs: Long,
    val stage: AdmissionStage,
    val attempts: Int,
    val lastError: String? = null,
    val nextAttemptAtMs: Long? = null,
    val linkedAtMs: Long? = null,
    val settledAtMs: Long? = null,
    val reason: String? = null,
)

/** What a source hands to the journal. A null [downstreamId] is minted by the journal. */
internal data class AdmissionRequest(
    val principal: String,
    val source: AdmissionSource,
    val sourceRequestId: String,
    val target: AdmissionTarget,
    val text: String,
    val expiresAtMs: Long,
    val downstreamId: String? = null,
)

internal enum class AdmissionInvalidReason {
    /** The closed schema: member set per stage, types, patterns, bounds. */
    SCHEMA,

    /** `admissionId` is not the digest of this record's principal, source and request id. */
    IDENTITY,
}

internal class AdmissionInvalidRecordException(
    val reason: AdmissionInvalidReason,
    detail: String,
) : Exception("invalid admission record (${reason.name.lowercase()}): $detail")

internal object AdmissionCodec {
    private const val MAX_SAFE_INTEGER: Long = 9_007_199_254_740_991L
    private const val MAX_TEXT_CHARACTERS: Int = 16_384

    private val HEX64 = Regex("[0-9a-f]{64}")
    private val PRINCIPAL = Regex("(local|account:[A-Za-z0-9._-]{1,128})")
    private val PRINTABLE_128 = Regex("[\\x21-\\x7e]{1,128}")
    private val PRINTABLE_256 = Regex("[\\x21-\\x7e]{1,256}")
    private val UUID_V4 = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
    private val CODE = Regex("[a-z_]{1,64}")

    private val COMMON_MEMBERS = setOf(
        "v", "admissionId", "principal", "source", "sourceRequestId", "target", "contentSha256",
        "downstreamId", "admittedAtMs", "expiresAtMs", "stage", "attempts",
    )
    private val PENDING_MEMBERS = COMMON_MEMBERS + setOf("text", "lastError", "nextAttemptAtMs")
    private val LINKED_MEMBERS = COMMON_MEMBERS + setOf("linkedAtMs")
    private val TERMINAL_MEMBERS = COMMON_MEMBERS + setOf("linkedAtMs", "settledAtMs", "reason")

    fun isValidAdmissionId(value: String): Boolean = HEX64.matches(value)

    /** `^[a-z_]{1,64}$`: the shape of `lastError` and `reason`. */
    fun isValidCode(value: String): Boolean = CODE.matches(value)

    fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    // ------------------------------------------------------------------ encode

    @Throws(AdmissionInvalidRecordException::class)
    fun encode(record: AdmissionRecord): String {
        validate(record)
        return toJson(record).toJsonString()
    }

    private fun toJson(record: AdmissionRecord): JsonObject {
        val members = sortedMapOf<String, JsonValue>(
            "v" to number(record.v.toLong()),
            "admissionId" to JsonString(record.admissionId),
            "principal" to JsonString(record.principal),
            "source" to JsonObject(
                sortedMapOf<String, JsonValue>(
                    "kind" to JsonString(record.source.kind.wire),
                    "id" to JsonString(record.source.id),
                ),
            ),
            "sourceRequestId" to JsonString(record.sourceRequestId),
            "target" to targetJson(record.target),
            "contentSha256" to JsonString(record.contentSha256),
            "downstreamId" to JsonString(record.downstreamId),
            "admittedAtMs" to number(record.admittedAtMs),
            "expiresAtMs" to number(record.expiresAtMs),
            "stage" to JsonString(record.stage.wire),
            "attempts" to number(record.attempts.toLong()),
        )
        record.text?.let { members["text"] = JsonString(it) }
        record.lastError?.let { members["lastError"] = JsonString(it) }
        record.nextAttemptAtMs?.let { members["nextAttemptAtMs"] = number(it) }
        record.linkedAtMs?.let { members["linkedAtMs"] = number(it) }
        record.settledAtMs?.let { members["settledAtMs"] = number(it) }
        record.reason?.let { members["reason"] = JsonString(it) }
        return JsonObject(members)
    }

    private fun targetJson(target: AdmissionTarget): JsonObject = when (target) {
        is AdmissionTarget.DshSession -> JsonObject(
            sortedMapOf<String, JsonValue>(
                "kind" to JsonString("dsh-session"),
                "sessionId" to JsonString(target.sessionId),
            ),
        )
        is AdmissionTarget.Bot -> JsonObject(
            sortedMapOf<String, JsonValue>(
                "kind" to JsonString("bot"),
                "botId" to JsonString(target.botId),
            ),
        )
    }

    private fun number(value: Long): JsonNumber = JsonNumber(value.toString())

    // ------------------------------------------------------------------ decode

    @Throws(AdmissionInvalidRecordException::class)
    fun decode(text: String): AdmissionRecord {
        val value = try {
            JsonValue.parse(text)
        } catch (failure: Exception) {
            // The parser reports malformed text with a checked harness exception.
            throw schema("not a JSON document: ${failure.message}")
        }
        return decode(value)
    }

    @Throws(AdmissionInvalidRecordException::class)
    fun decode(value: JsonValue): AdmissionRecord {
        val root = value as? JsonObject ?: throw schema("record is not an object")
        val version = requiredLong(root, "v")
        if (version != 1L) throw schema("v is $version, not 1")
        val stage = AdmissionStage.fromWire(requiredString(root, "stage")) ?: throw schema("unknown stage")
        val allowed = when {
            stage.isPending -> PENDING_MEMBERS
            stage == AdmissionStage.LINKED -> LINKED_MEMBERS
            else -> TERMINAL_MEMBERS
        }
        root.members.keys.firstOrNull { it !in allowed }?.let {
            throw schema("member '$it' is not part of a ${stage.wire} record")
        }
        val attempts = requiredLong(root, "attempts")
        if (attempts < 0 || attempts > AdmissionPolicy.MAX_ATTEMPTS) throw schema("attempts out of range")
        val record = AdmissionRecord(
            v = 1,
            admissionId = requiredString(root, "admissionId"),
            principal = requiredString(root, "principal"),
            source = decodeSource(root["source"] ?: throw schema("missing member 'source'")),
            sourceRequestId = requiredString(root, "sourceRequestId"),
            target = decodeTarget(root["target"] ?: throw schema("missing member 'target'")),
            contentSha256 = requiredString(root, "contentSha256"),
            text = optionalString(root, "text"),
            downstreamId = requiredString(root, "downstreamId"),
            admittedAtMs = requiredLong(root, "admittedAtMs"),
            expiresAtMs = requiredLong(root, "expiresAtMs"),
            stage = stage,
            attempts = attempts.toInt(),
            lastError = optionalString(root, "lastError"),
            nextAttemptAtMs = optionalLong(root, "nextAttemptAtMs"),
            linkedAtMs = optionalLong(root, "linkedAtMs"),
            settledAtMs = optionalLong(root, "settledAtMs"),
            reason = optionalString(root, "reason"),
        )
        validate(record)
        return record
    }

    /**
     * Reads a request written in the record's own member names (`principal`,
     * `source`, `sourceRequestId`, `target`, `text`, `expiresAtMs`, optional
     * `downstreamId`), the shape the shared vectors use. Null when a member is
     * missing, mistyped or names a kind this build does not know: such a request
     * is `invalid` before it reaches the journal. Value bounds are judged by
     * [AdmissionPolicy.candidate], not here.
     */
    fun decodeRequest(value: JsonValue): AdmissionRequest? = try {
        val root = value as? JsonObject ?: throw schema("request is not an object")
        AdmissionRequest(
            principal = requiredString(root, "principal"),
            source = decodeSource(root["source"] ?: throw schema("missing member 'source'")),
            sourceRequestId = requiredString(root, "sourceRequestId"),
            target = decodeTarget(root["target"] ?: throw schema("missing member 'target'")),
            text = requiredString(root, "text"),
            expiresAtMs = requiredLong(root, "expiresAtMs"),
            downstreamId = optionalString(root, "downstreamId"),
        )
    } catch (_: AdmissionInvalidRecordException) {
        null
    }

    private fun decodeSource(value: JsonValue): AdmissionSource {
        val source = value as? JsonObject ?: throw schema("source is not an object")
        source.members.keys.firstOrNull { it != "kind" && it != "id" }?.let {
            throw schema("unknown source member '$it'")
        }
        return AdmissionSource(
            kind = AdmissionSourceKind.fromWire(requiredString(source, "kind")) ?: throw schema("unknown source kind"),
            id = requiredString(source, "id"),
        )
    }

    private fun decodeTarget(value: JsonValue): AdmissionTarget {
        val target = value as? JsonObject ?: throw schema("target is not an object")
        return when (requiredString(target, "kind")) {
            "dsh-session" -> {
                target.members.keys.firstOrNull { it != "kind" && it != "sessionId" }?.let {
                    throw schema("unknown dsh-session target member '$it'")
                }
                AdmissionTarget.DshSession(requiredString(target, "sessionId"))
            }
            "bot" -> {
                target.members.keys.firstOrNull { it != "kind" && it != "botId" }?.let {
                    throw schema("unknown bot target member '$it'")
                }
                AdmissionTarget.Bot(requiredString(target, "botId"))
            }
            else -> throw schema("unknown target kind")
        }
    }

    // ---------------------------------------------------------------- validate

    /** The schema's field and per-stage member laws, then the identity law. */
    @Throws(AdmissionInvalidRecordException::class)
    fun validate(record: AdmissionRecord) {
        if (record.v != 1) throw schema("v is ${record.v}, not 1")
        if (!HEX64.matches(record.admissionId)) throw schema("admissionId is not lowercase hex SHA-256")
        if (!PRINCIPAL.matches(record.principal)) throw schema("principal is neither local nor account:<id>")
        if (!PRINTABLE_128.matches(record.source.id)) throw schema("source.id is invalid")
        if (!PRINTABLE_128.matches(record.sourceRequestId)) throw schema("sourceRequestId is invalid")
        val targetId = when (val target = record.target) {
            is AdmissionTarget.DshSession -> target.sessionId
            is AdmissionTarget.Bot -> target.botId
        }
        if (!PRINTABLE_256.matches(targetId)) throw schema("target id is invalid")
        if (!HEX64.matches(record.contentSha256)) throw schema("contentSha256 is invalid")
        if (!UUID_V4.matches(record.downstreamId)) throw schema("downstreamId is not a lowercase UUIDv4")
        if (!isTimestamp(record.admittedAtMs) || !isTimestamp(record.expiresAtMs)) {
            throw schema("a timestamp is out of range")
        }
        if (record.attempts < 0 || record.attempts > AdmissionPolicy.MAX_ATTEMPTS) {
            throw schema("attempts out of range")
        }
        for (time in listOf(record.nextAttemptAtMs, record.linkedAtMs, record.settledAtMs)) {
            if (time != null && !isTimestamp(time)) throw schema("a timestamp is out of range")
        }
        for (code in listOf(record.lastError, record.reason)) {
            if (code != null && !CODE.matches(code)) throw schema("lastError/reason is not a short code")
        }
        val stage = record.stage
        when {
            stage.isPending -> {
                val text = record.text ?: throw schema("a pending record has no text")
                val characters = text.codePointCount(0, text.length)
                if (characters < 1 || characters > MAX_TEXT_CHARACTERS) throw schema("text length out of range")
                if (record.linkedAtMs != null || record.settledAtMs != null || record.reason != null) {
                    throw schema("a pending record carries a later-stage member")
                }
            }
            stage == AdmissionStage.LINKED -> {
                if (record.text != null) throw schema("a linked record still carries text")
                if (record.lastError != null || record.nextAttemptAtMs != null ||
                    record.settledAtMs != null || record.reason != null
                ) {
                    throw schema("a linked record carries a member of another stage")
                }
            }
            else -> {
                if (record.text != null) throw schema("a terminal record still carries text")
                if (record.lastError != null || record.nextAttemptAtMs != null) {
                    throw schema("a terminal record carries a pending member")
                }
                if (record.settledAtMs == null) throw schema("a terminal record has no settledAtMs")
            }
        }
        val derived = AdmissionPolicy.admissionId(record.principal, record.source, record.sourceRequestId)
        if (derived != record.admissionId) {
            throw AdmissionInvalidRecordException(
                AdmissionInvalidReason.IDENTITY,
                "admissionId does not belong to this principal, source and request id",
            )
        }
    }

    private fun isTimestamp(value: Long): Boolean = value in 0..MAX_SAFE_INTEGER

    // ----------------------------------------------------------------- members

    private fun schema(detail: String) =
        AdmissionInvalidRecordException(AdmissionInvalidReason.SCHEMA, detail)

    private fun requiredString(source: JsonObject, name: String): String =
        optionalString(source, name) ?: throw schema("missing member '$name'")

    private fun optionalString(source: JsonObject, name: String): String? =
        source[name]?.let { (it as? JsonString)?.value ?: throw schema("member '$name' is not a string") }

    private fun requiredLong(source: JsonObject, name: String): Long =
        optionalLong(source, name) ?: throw schema("missing member '$name'")

    private fun optionalLong(source: JsonObject, name: String): Long? =
        source[name]?.let {
            (it as? JsonNumber)?.asLongOrNull() ?: throw schema("member '$name' is not an integer")
        }
}
