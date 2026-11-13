// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.BotJsonException

/** A canonical `record://` reference (v1 §4.2). */
public data class BotMemoryRecordReference(
    public val kind: Kind,
    public val canonical: String,
    public val sessionId: String? = null,
    public val seq: Long? = null,
    public val commitSeq: Long? = null,
) {
    public enum class Kind { SESSION, EVENT }
}

public class BotMemoryEvidenceException(
    public val code: String,
    message: String,
) : Exception(message)

/**
 * Evidence parsing and trust derivation (v2 §1.5). The reserved
 * `current-user-turn` value is host-owned: the caller passes the reference it
 * observed on the current turn; this code never reads it from the model.
 */
public object BotMemoryEvidence {
    public const val CURRENT_USER_TURN: String = "current-user-turn"
    public const val MAXIMUM_REFERENCES: Int = 8
    public const val MAXIMUM_REFERENCE_LENGTH: Int = 128
    public const val SAFE_INTEGER: Long = (1L shl 53) - 1

    private val sessionIdPattern = Regex("^[A-Za-z0-9._-]{1,64}$")

    /** The exact stored form from `memory-document.schema.json`. */
    private val storedReferencePattern = Regex(
        "^record://(session/(?!\\.{1,2}#)[A-Za-z0-9._-]{1,64}#(0|[1-9][0-9]*)|event/[1-9][0-9]*)$",
    )

    private val nonUserRpcPrefixes = listOf(
        "held:", "agent:", "routine:", "task-turn:", "task-settled:", "task-interrupted:",
    )

    private val userRpcPrefixes = listOf("bot-", "user-action:", "card-answer:")

    private val observationTools = setOf(
        "web_fetch", "web_search", "Task", "AwaitTask", "StopSubagent",
    )

    public fun parse(raw: String?): BotMemoryRecordReference? {
        if (raw == null) return null
        val value = raw.trim(' ', '\t', '\r', '\n')
        if (value.length < 9) return null
        if (!value.substring(0, 9).equals("record://", ignoreCase = true)) return null
        val rest = value.substring(9)
        val slash = rest.indexOf('/')
        if (slash < 0) return null
        val kind = rest.substring(0, slash)
        val tail = rest.substring(slash + 1)
        if (rest.indexOf('/', slash + 1) >= 0) return null
        return when {
            kind.equals("event", ignoreCase = true) -> {
                if (tail.isEmpty() || !tail.all { it in '0'..'9' }) return null
                val number = tail.toLongOrNull() ?: return null
                if (number < 1 || number > SAFE_INTEGER) return null
                BotMemoryRecordReference(
                    kind = BotMemoryRecordReference.Kind.EVENT,
                    canonical = "record://event/$number",
                    commitSeq = number,
                )
            }
            kind.equals("session", ignoreCase = true) -> {
                if (tail.count { it == '#' } != 1) return null
                val hash = tail.indexOf('#')
                val identifier = tail.substring(0, hash)
                val fragment = tail.substring(hash + 1)
                if (!sessionIdPattern.matches(identifier)) return null
                if (identifier == "." || identifier == "..") return null
                if (fragment.isEmpty() || !fragment.all { it in '0'..'9' }) return null
                val number = fragment.toLongOrNull() ?: return null
                if (number > SAFE_INTEGER) return null
                BotMemoryRecordReference(
                    kind = BotMemoryRecordReference.Kind.SESSION,
                    canonical = "record://session/$identifier#$number",
                    sessionId = identifier,
                    seq = number,
                )
            }
            else -> null
        }
    }

    /** Validates one reference that is about to be stored (`evidence` in a document). */
    public fun validateStoredReference(raw: String) {
        if (raw.length > MAXIMUM_REFERENCE_LENGTH || !storedReferencePattern.matches(raw)) {
            throw BotJsonException("evidence reference is not canonical: $raw")
        }
    }

    public fun isCanonicalStoredReference(raw: String): Boolean =
        raw.length <= MAXIMUM_REFERENCE_LENGTH && storedReferencePattern.matches(raw)

    /**
     * Resolves the reserved `current-user-turn` item and canonicalizes every
     * reference. Throws `memory-evidence-invalid` for any malformed item or an
     * unavailable reserved value.
     */
    public fun resolveForWrite(
        references: List<String>,
        sourceKind: BotMemorySourceKind,
        currentUserTurnReference: String?,
    ): List<String> {
        if (references.size > MAXIMUM_REFERENCES) {
            throw BotMemoryEvidenceException(
                "memory-evidence-invalid",
                "evidence may have at most $MAXIMUM_REFERENCES references",
            )
        }
        val resolved = ArrayList<String>(references.size)
        for (raw in references) {
            if (raw == CURRENT_USER_TURN) {
                if (sourceKind != BotMemorySourceKind.USER_TURN || currentUserTurnReference == null) {
                    throw BotMemoryEvidenceException(
                        "memory-evidence-invalid",
                        "current-user-turn is unavailable in this turn",
                    )
                }
                val parsed = parse(currentUserTurnReference)
                    ?: throw BotMemoryEvidenceException(
                        "memory-evidence-invalid",
                        "the host current-turn reference is malformed",
                    )
                resolved += parsed.canonical
                continue
            }
            if (raw.length > MAXIMUM_REFERENCE_LENGTH) {
                throw BotMemoryEvidenceException(
                    "memory-evidence-invalid",
                    "evidence reference is longer than $MAXIMUM_REFERENCE_LENGTH characters",
                )
            }
            val parsed = parse(raw)
                ?: throw BotMemoryEvidenceException(
                    "memory-evidence-invalid",
                    "malformed evidence reference: $raw",
                )
            resolved += parsed.canonical
        }
        return resolved
    }

    /**
     * Derives the strongest trust over [references], matching the v2 §1.5
     * table. [records] is the host-owned resolved record set keyed by the
     * canonical reference; a foreign or missing record is invalid, never
     * downgraded.
     */
    public fun deriveTrust(
        records: Map<String, BotMemoryEvidenceRecord>,
        references: List<String>,
        callerBotId: String,
        currentUserTurnReference: String? = null,
        sourceKind: BotMemorySourceKind = BotMemorySourceKind.USER_TURN,
    ): BotMemoryTrust {
        var trust = BotMemoryTrust.ASSISTANT
        for (canonical in resolveForWrite(references, sourceKind, currentUserTurnReference)) {
            val record = records[canonical]
                ?: throw BotMemoryEvidenceException(
                    "memory-evidence-invalid",
                    "evidence reference does not resolve: $canonical",
                )
            if (record.botId != callerBotId) {
                throw BotMemoryEvidenceException(
                    "memory-evidence-invalid",
                    "evidence reference belongs to another Bot: $canonical",
                )
            }
            val userRecord =
                (record.kind == BotMemoryEvidenceRecord.Kind.SESSION && record.type == "user/message") ||
                    (record.kind == BotMemoryEvidenceRecord.Kind.EVENT &&
                        record.type == "conversation.user_message")
            if (userRecord && isUserStatementRpc(record.rpcId)) {
                trust = BotMemoryTrust.USER
            } else if (externalSource(record) && trust != BotMemoryTrust.USER) {
                trust = BotMemoryTrust.OBSERVATION
            }
        }
        return trust
    }

    public fun isUserStatementRpc(rpcId: String?): Boolean {
        if (rpcId == null) return true
        if (rpcId.isEmpty()) return false
        if (nonUserRpcPrefixes.any { rpcId.startsWith(it) }) return false
        return userRpcPrefixes.any { rpcId.startsWith(it) }
    }

    public fun externalSource(record: BotMemoryEvidenceRecord): Boolean = when (record.kind) {
        BotMemoryEvidenceRecord.Kind.EVENT -> {
            if (record.type == "comm.inbound" && record.hasDeviceTaskResult) {
                true
            } else {
                (record.type == "conversation.tool_call" || record.type == "conversation.tool_result") &&
                    isExternalTool(record.tool)
            }
        }
        BotMemoryEvidenceRecord.Kind.SESSION -> record.type == "tool/call" && isExternalTool(record.tool)
    }

    public fun isExternalTool(tool: String?): Boolean {
        if (tool == null) return false
        if (tool in observationTools) return true
        if (tool.startsWith("mcp__phone__android_") || tool.startsWith("mcp__phone__ble_")) return true
        if (tool.startsWith("mcp__phone__")) return false
        return tool.startsWith("mcp__")
    }
}

/** One host-owned record reached through a `record://` reference. */
public data class BotMemoryEvidenceRecord(
    public val kind: Kind,
    public val type: String? = null,
    public val rpcId: String? = null,
    public val tool: String? = null,
    public val botId: String,
    public val hasDeviceTaskResult: Boolean = false,
) {
    public enum class Kind(public val wire: String) {
        SESSION("session"),
        EVENT("event"),
    }

    public companion object {
        public fun fromJson(value: String?, botId: String, path: String = "record"): BotMemoryEvidenceRecord {
            val members = (value?.let { com.phonedsh.agentcore.JsonValue.parse(it) } as? JsonObject)?.members
                ?: throw BotJsonException("$path must be an object")
            val kind = when (val raw = BotMemoryJson.optionalString(members["kind"], "$path.kind")) {
                "session" -> Kind.SESSION
                "event" -> Kind.EVENT
                else -> throw BotJsonException("$path.kind must be session or event")
            }
            val device = members["deviceTaskResult"] as? JsonObject
            return BotMemoryEvidenceRecord(
                kind = kind,
                type = BotMemoryJson.optionalString(members["type"], "$path.type"),
                rpcId = BotMemoryJson.optionalString(members["rpcId"], "$path.rpcId"),
                tool = BotMemoryJson.optionalString(members["tool"], "$path.tool"),
                botId = botId,
                hasDeviceTaskResult = device != null,
            )
        }
    }
}
