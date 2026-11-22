// SPDX-License-Identifier: MIT
// Value types and the closed codec of the durable send outbox
// (spec/host/v1/README.md section 10, schema/outbox-entry.schema.json).
//
// Kotlin end of `examples/probe-app/ProbeKit/Outbox/SendOutbox.swift`. The
// decoder is the schema made executable: an unknown member, a wrong type, a
// value outside a bound and the two cross-field attachment laws all reject the
// whole entry. Nothing is repaired and nothing is defaulted.
package com.phonedsh.probe.outbox

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import java.security.MessageDigest

internal enum class SendOutboxState(val wire: String) {
    QUEUED("queued"),
    SUBMITTING("submitting"),
    ACCEPTED("accepted"),
    DURABLE("durable"),
    OUTCOME_UNKNOWN("outcomeUnknown"),

    /** The engine proved the target session gone. Resting: only a user discard or resend removes it. */
    TARGET_LOST("targetLost"),
    ;

    companion object {
        fun fromWire(value: String): SendOutboxState? = entries.firstOrNull { it.wire == value }
    }
}

internal enum class SendOutboxBackend(val wire: String) {
    LOCAL("local"),
    PC("pc"),
    ;

    companion object {
        fun fromWire(value: String): SendOutboxBackend? = entries.firstOrNull { it.wire == value }
    }
}

/** The closed attachment kinds of the schema. An unknown value rejects the entry. */
internal enum class SendOutboxAttachmentKind(val wire: String) {
    IMAGE("image"),
    FILE("file"),
    AUDIO("audio"),
    VIDEO("video"),
    DOCUMENT("document"),
    ;

    companion object {
        fun fromWire(value: String): SendOutboxAttachmentKind? = entries.firstOrNull { it.wire == value }

        /** Same mapping as the Swift end, so one payload gets one kind on both platforms. */
        fun fromMimeType(mimeType: String): SendOutboxAttachmentKind {
            val lower = mimeType.lowercase()
            return when {
                lower.startsWith("image/") -> IMAGE
                lower.startsWith("audio/") -> AUDIO
                lower.startsWith("video/") -> VIDEO
                lower.startsWith("text/") || lower == "application/pdf" || lower == "application/zip" ||
                    lower == "application/msword" || lower.startsWith("application/vnd.") -> DOCUMENT
                else -> FILE
            }
        }
    }
}

/**
 * One attachment reference. [storePath] is relative to the outbox directory and
 * is exactly `attachments/<rpcId>/<id>`; the bytes are never in the entry.
 */
internal data class SendOutboxAttachment(
    val id: String,
    val kind: SendOutboxAttachmentKind,
    val byteSize: Long,
    val sha256: String,
    val contentType: String,
    val filename: String,
    val storePath: String,
)

/** Caller input for a new attachment; the store derives id, size, digest and path. */
internal class SendOutboxAttachmentInput(
    val id: String? = null,
    val kind: SendOutboxAttachmentKind,
    val contentType: String,
    val filename: String,
    val data: ByteArray,
)

/** A digest-verified attachment read back for dispatch. */
internal class SendOutboxLoadedAttachment(
    val attachment: SendOutboxAttachment,
    val data: ByteArray,
)

/** The only two values written to `lastError` for a blocked attachment entry. Never user text. */
internal enum class SendOutboxAttachmentFailure(val wire: String) {
    MISSING("attachment_missing"),
    DIGEST_MISMATCH("attachment_digest_mismatch"),
}

internal data class SendOutboxEntry(
    val v: Int = 1,
    val rpcId: String,
    val sessionId: String,
    val text: String,
    val createdAtMs: Long,
    val state: SendOutboxState,
    val attempts: Int,
    val lastError: String? = null,
    val acceptedAtMs: Long? = null,
    val durableAtMs: Long? = null,
    val outcomeUnknownAtMs: Long? = null,
    val backend: SendOutboxBackend? = null,
    /** Absent for a text-only entry; an entry written before attachments existed decodes unchanged. */
    val attachments: List<SendOutboxAttachment>? = null,
)

/** The seven edges of section 10 (PC-20261122-outbox-lost-target added `queued → targetLost`). There is no other edge. */
internal object SendOutboxTransition {
    fun allows(from: SendOutboxState, to: SendOutboxState): Boolean = when (from) {
        SendOutboxState.QUEUED -> to == SendOutboxState.SUBMITTING || to == SendOutboxState.TARGET_LOST
        SendOutboxState.SUBMITTING -> to == SendOutboxState.ACCEPTED || to == SendOutboxState.OUTCOME_UNKNOWN
        SendOutboxState.ACCEPTED -> to == SendOutboxState.DURABLE
        SendOutboxState.OUTCOME_UNKNOWN -> to == SendOutboxState.ACCEPTED || to == SendOutboxState.QUEUED
        SendOutboxState.DURABLE -> false
        SendOutboxState.TARGET_LOST -> false
    }
}

/** Why a stored or produced entry is not a valid outbox entry. */
internal enum class SendOutboxInvalidReason {
    /** The closed schema: member set, types, patterns, bounds, the text/attachments `oneOf`. */
    SCHEMA,

    /** Two attachments of one entry share an `id`. */
    DUPLICATE_ATTACHMENT_ID,

    /** A `storePath` is not `attachments/<this rpcId>/<this attachment id>`. */
    ATTACHMENT_STORE_PATH_MISMATCH,
}

internal class SendOutboxInvalidEntryException(
    val reason: SendOutboxInvalidReason,
    detail: String,
) : Exception("invalid outbox entry (${reason.name.lowercase()}): $detail")

internal object SendOutboxCodec {
    const val MAX_TEXT_CHARACTERS: Int = 1_000_000
    const val MAX_ATTACHMENTS: Int = 20
    const val MAX_ATTEMPTS: Int = 1_024
    const val MAX_LAST_ERROR_CHARACTERS: Int = 1_024

    private val RPC_ID = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
    private val NAME = Regex("[A-Za-z0-9._-]{1,64}")
    private val SHA256 = Regex("[0-9a-f]{64}")
    private val STORE_PATH = Regex("attachments/[0-9a-f-]{36}/[A-Za-z0-9._-]{1,64}")

    private val ENTRY_MEMBERS = setOf(
        "v", "rpcId", "sessionId", "text", "createdAtMs", "state", "attempts", "lastError",
        "acceptedAtMs", "durableAtMs", "outcomeUnknownAtMs", "backend", "attachments",
    )
    private val ATTACHMENT_MEMBERS = setOf(
        "id", "kind", "byteSize", "sha256", "contentType", "filename", "storePath",
    )

    /** `^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$` */
    fun isValidRpcId(value: String): Boolean = RPC_ID.matches(value)

    /** `^[A-Za-z0-9._-]{1,64}$` */
    fun isValidSessionId(value: String): Boolean = NAME.matches(value)

    /** The schema pattern, minus the two names that are directory links rather than files. */
    fun isValidAttachmentId(value: String): Boolean = NAME.matches(value) && value != "." && value != ".."

    fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /** Schema lengths count Unicode code points, not UTF-16 units. */
    fun characters(value: String): Int = value.codePointCount(0, value.length)

    // ------------------------------------------------------------------ encode

    /** Validates [entry] against the schema and its laws, then encodes it with sorted members. */
    @Throws(SendOutboxInvalidEntryException::class)
    fun encode(entry: SendOutboxEntry): String {
        validate(entry)
        return toJson(entry).toJsonString()
    }

    private fun toJson(entry: SendOutboxEntry): JsonObject {
        val members = sortedMapOf<String, JsonValue>(
            "v" to number(entry.v.toLong()),
            "rpcId" to JsonString(entry.rpcId),
            "sessionId" to JsonString(entry.sessionId),
            "text" to JsonString(entry.text),
            "createdAtMs" to number(entry.createdAtMs),
            "state" to JsonString(entry.state.wire),
            "attempts" to number(entry.attempts.toLong()),
        )
        entry.lastError?.let { members["lastError"] = JsonString(it) }
        entry.acceptedAtMs?.let { members["acceptedAtMs"] = number(it) }
        entry.durableAtMs?.let { members["durableAtMs"] = number(it) }
        entry.outcomeUnknownAtMs?.let { members["outcomeUnknownAtMs"] = number(it) }
        entry.backend?.let { members["backend"] = JsonString(it.wire) }
        entry.attachments?.let { attachments ->
            members["attachments"] = JsonArray(
                attachments.map { attachment ->
                    JsonObject(
                        sortedMapOf<String, JsonValue>(
                            "id" to JsonString(attachment.id),
                            "kind" to JsonString(attachment.kind.wire),
                            "byteSize" to number(attachment.byteSize),
                            "sha256" to JsonString(attachment.sha256),
                            "contentType" to JsonString(attachment.contentType),
                            "filename" to JsonString(attachment.filename),
                            "storePath" to JsonString(attachment.storePath),
                        ),
                    )
                },
            )
        }
        return JsonObject(members)
    }

    private fun number(value: Long): JsonNumber = JsonNumber(value.toString())

    // ------------------------------------------------------------------ decode

    @Throws(SendOutboxInvalidEntryException::class)
    fun decode(text: String): SendOutboxEntry {
        val value = try {
            JsonValue.parse(text)
        } catch (failure: Exception) {
            // The parser reports malformed text with a checked harness exception.
            throw schema("not a JSON document: ${failure.message}")
        }
        return decode(value)
    }

    @Throws(SendOutboxInvalidEntryException::class)
    fun decode(value: JsonValue): SendOutboxEntry {
        val root = value as? JsonObject ?: throw schema("entry is not an object")
        root.members.keys.firstOrNull { it !in ENTRY_MEMBERS }?.let { throw schema("unknown member '$it'") }
        val version = requiredLong(root, "v")
        if (version != 1L) throw schema("v is $version, not 1")
        val stateWire = requiredString(root, "state")
        val attempts = requiredLong(root, "attempts")
        if (attempts < 0 || attempts > MAX_ATTEMPTS) throw schema("attempts out of range")
        val backend = optionalString(root, "backend")?.let {
            SendOutboxBackend.fromWire(it) ?: throw schema("unknown backend")
        }
        val attachments = root["attachments"]?.let { raw ->
            val array = raw as? JsonArray ?: throw schema("attachments is not an array")
            array.values.map(::decodeAttachment)
        }
        val entry = SendOutboxEntry(
            v = 1,
            rpcId = requiredString(root, "rpcId"),
            sessionId = requiredString(root, "sessionId"),
            text = requiredString(root, "text"),
            createdAtMs = requiredLong(root, "createdAtMs"),
            state = SendOutboxState.fromWire(stateWire) ?: throw schema("unknown state"),
            attempts = attempts.toInt(),
            lastError = optionalString(root, "lastError"),
            acceptedAtMs = optionalLong(root, "acceptedAtMs"),
            durableAtMs = optionalLong(root, "durableAtMs"),
            outcomeUnknownAtMs = optionalLong(root, "outcomeUnknownAtMs"),
            backend = backend,
            attachments = attachments,
        )
        validate(entry)
        return entry
    }

    private fun decodeAttachment(value: JsonValue): SendOutboxAttachment {
        val item = value as? JsonObject ?: throw schema("attachment is not an object")
        item.members.keys.firstOrNull { it !in ATTACHMENT_MEMBERS }?.let {
            throw schema("unknown attachment member '$it'")
        }
        return SendOutboxAttachment(
            id = requiredString(item, "id"),
            kind = SendOutboxAttachmentKind.fromWire(requiredString(item, "kind"))
                ?: throw schema("unknown attachment kind"),
            byteSize = requiredLong(item, "byteSize"),
            sha256 = requiredString(item, "sha256"),
            contentType = requiredString(item, "contentType"),
            filename = requiredString(item, "filename"),
            storePath = requiredString(item, "storePath"),
        )
    }

    // ---------------------------------------------------------------- validate

    /** The field laws of the schema followed by the two attachment-reference laws. */
    @Throws(SendOutboxInvalidEntryException::class)
    fun validate(entry: SendOutboxEntry) {
        if (entry.v != 1) throw schema("v is ${entry.v}, not 1")
        if (!isValidRpcId(entry.rpcId)) throw schema("rpcId is not a lowercase UUIDv4")
        if (!isValidSessionId(entry.sessionId)) throw schema("sessionId is invalid")
        val attachments = entry.attachments
        if (entry.text.isEmpty() && attachments.isNullOrEmpty()) {
            throw schema("text is empty and there is no attachment")
        }
        if (characters(entry.text) > MAX_TEXT_CHARACTERS) throw schema("text is too long")
        if (entry.createdAtMs < 0) throw schema("createdAtMs is negative")
        if (entry.attempts < 0 || entry.attempts > MAX_ATTEMPTS) throw schema("attempts out of range")
        entry.lastError?.let {
            if (characters(it) > MAX_LAST_ERROR_CHARACTERS) throw schema("lastError is too long")
        }
        for (time in listOf(entry.acceptedAtMs, entry.durableAtMs, entry.outcomeUnknownAtMs)) {
            if (time != null && time < 0) throw schema("a timestamp is negative")
        }
        if (attachments == null) return
        if (attachments.size > MAX_ATTACHMENTS) throw schema("${attachments.size} attachments (maximum 20)")
        for (attachment in attachments) {
            if (!isValidAttachmentId(attachment.id)) throw schema("attachment id is invalid")
            if (attachment.byteSize < 0) throw schema("attachment byteSize is negative")
            if (!SHA256.matches(attachment.sha256)) throw schema("attachment sha256 is invalid")
            if (attachment.contentType.isEmpty() || characters(attachment.contentType) > 200) {
                throw schema("attachment contentType is invalid")
            }
            if (attachment.filename.isEmpty() || characters(attachment.filename) > 255) {
                throw schema("attachment filename is invalid")
            }
            if (!STORE_PATH.matches(attachment.storePath)) throw schema("attachment storePath is invalid")
        }
        val seen = HashSet<String>()
        for (attachment in attachments) {
            if (!seen.add(attachment.id)) {
                throw SendOutboxInvalidEntryException(
                    SendOutboxInvalidReason.DUPLICATE_ATTACHMENT_ID,
                    "attachment id '${attachment.id}' is used twice",
                )
            }
        }
        for (attachment in attachments) {
            if (attachment.storePath != storePath(entry.rpcId, attachment.id)) {
                throw SendOutboxInvalidEntryException(
                    SendOutboxInvalidReason.ATTACHMENT_STORE_PATH_MISMATCH,
                    "storePath of '${attachment.id}' does not name this entry's store",
                )
            }
        }
    }

    fun storePath(rpcId: String, attachmentId: String): String = "attachments/$rpcId/$attachmentId"

    // ----------------------------------------------------------------- members

    private fun schema(detail: String) =
        SendOutboxInvalidEntryException(SendOutboxInvalidReason.SCHEMA, detail)

    private fun requiredString(source: JsonObject, name: String): String =
        (source[name] ?: throw schema("missing member '$name'")).let {
            (it as? JsonString)?.value ?: throw schema("member '$name' is not a string")
        }

    private fun optionalString(source: JsonObject, name: String): String? =
        source[name]?.let { (it as? JsonString)?.value ?: throw schema("member '$name' is not a string") }

    private fun requiredLong(source: JsonObject, name: String): Long =
        optionalLong(source, name) ?: throw schema("missing member '$name'")

    private fun optionalLong(source: JsonObject, name: String): Long? =
        source[name]?.let {
            (it as? JsonNumber)?.asLongOrNull() ?: throw schema("member '$name' is not an integer")
        }
}
