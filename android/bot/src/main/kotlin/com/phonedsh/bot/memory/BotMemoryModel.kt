// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJsonException

/**
 * P26 v2 memory value types (`spec/bot/v2/memory-document.schema.json` and the
 * sibling schemas). There is no tier, importance, sensitivity, archived or
 * expires_at field: memory is a Markdown document tree rooted at `user/` and
 * `agent/`.
 */
public enum class BotMemoryScope(public val wire: String) {
    AGENT("agent"),
    USER("user"),
    ;

    public companion object {
        public fun parse(value: String?): BotMemoryScope? =
            entries.firstOrNull { it.wire == value }

        public val roots: List<BotMemoryScope> = listOf(USER, AGENT)
    }
}

public enum class BotMemoryAuthorKind(public val wire: String) {
    CHAT("chat"),
    TASK("task"),
    ROUTINE("routine"),
    TEAM("team"),
    PROACTIVE("proactive"),
    WATCHDOG("watchdog"),
    MAINTAINER("maintainer"),
    UI("ui"),
    MIGRATION("migration"),
    SYSTEM("system"),
    ;

    /** P25 only accepts the existing principal kinds; these three map to `ipc`. */
    public val principalKind: String
        get() = when (this) {
            UI, MIGRATION, SYSTEM -> "ipc"
            else -> wire
        }

    /** Task/routine/team/proactive/watchdog sessions may only submit to their own inbox. */
    public val isInboxOnly: Boolean
        get() = when (this) {
            TASK, ROUTINE, TEAM, PROACTIVE, WATCHDOG -> true
            CHAT, MAINTAINER, UI, MIGRATION, SYSTEM -> false
        }

    public companion object {
        public fun parse(value: String?): BotMemoryAuthorKind? =
            entries.firstOrNull { it.wire == value }
    }
}

public enum class BotMemorySourceKind(public val wire: String) {
    USER_TURN("user-turn"),
    HIDDEN_WAKE("hidden-wake"),
    AGENT_MESSAGE("agent-message"),
    ROUTINE("routine"),
    TASK("task"),
    MAINTENANCE("maintenance"),
    ;

    public companion object {
        public fun parse(value: String?): BotMemorySourceKind? =
            entries.firstOrNull { it.wire == value }
    }
}

/** `trust` is derived from the `evidence` references (v2 §1.5). */
public enum class BotMemoryTrust(public val wire: String) {
    USER("user"),
    OBSERVATION("observation"),
    ASSISTANT("assistant"),
    IMPORT("import"),
    SYSTEM("system"),
    ;

    public companion object {
        public fun parse(value: String?): BotMemoryTrust? =
            entries.firstOrNull { it.wire == value }
    }
}

public data class BotMemoryAuthor(
    public val botId: String? = null,
    public val sessionId: String? = null,
    public val kind: BotMemoryAuthorKind,
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        botId?.let { members["bot_id"] = JsonString(it) }
        sessionId?.let { members["session_id"] = JsonString(it) }
        members["kind"] = JsonString(kind.wire)
        return JsonObject(members)
    }

    public companion object {
        public fun fromJson(value: JsonValue?): BotMemoryAuthor {
            val members = BotMemoryJson.objectMembers(value, "author")
            BotMemoryJson.rejectUnknown(members, "author", setOf("bot_id", "session_id", "kind"))
            val kind = BotMemoryAuthorKind.parse(BotMemoryJson.string(members["kind"], "author.kind"))
                ?: throw BotJsonException("author.kind is not a known author kind")
            val botId = BotMemoryJson.optionalString(members["bot_id"], "author.bot_id")
            if (botId != null && botId.isEmpty()) {
                throw BotJsonException("author.bot_id must not be empty")
            }
            val sessionId = BotMemoryJson.optionalString(members["session_id"], "author.session_id")
            if (sessionId != null && sessionId.isEmpty()) {
                throw BotJsonException("author.session_id must not be empty")
            }
            return BotMemoryAuthor(botId = botId, sessionId = sessionId, kind = kind)
        }
    }
}

public data class BotMemorySource(
    public val kind: BotMemorySourceKind,
    public val sessionId: String? = null,
    public val turnId: String? = null,
    public val role: String? = null,
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["kind"] = JsonString(kind.wire)
        sessionId?.let { members["sessionId"] = JsonString(it) }
        turnId?.let { members["turnId"] = JsonString(it) }
        role?.let { members["role"] = JsonString(it) }
        return JsonObject(members)
    }

    public companion object {
        public fun fromJson(value: JsonValue?): BotMemorySource {
            val members = BotMemoryJson.objectMembers(value, "source")
            val kind = BotMemorySourceKind.parse(BotMemoryJson.string(members["kind"], "source.kind"))
                ?: throw BotJsonException("source.kind is not a known source kind")
            val turnId = when (val raw = members["turnId"]) {
                null, is JsonNull -> null
                is JsonString -> raw.value
                is JsonNumber -> raw.raw
                else -> throw BotJsonException("source.turnId must be a string or integer")
            }
            return BotMemorySource(
                kind = kind,
                sessionId = BotMemoryJson.optionalString(members["sessionId"], "source.sessionId"),
                turnId = turnId,
                role = BotMemoryJson.optionalString(members["role"], "source.role"),
            )
        }
    }
}

/** One live Markdown document version (`memory-document.schema.json`). */
public data class BotMemoryDocument(
    public val path: String,
    public val scope: BotMemoryScope,
    public val content: String,
    public val version: Int,
    public val updatedAtMs: Long,
    public val author: BotMemoryAuthor,
    public val evidence: List<String> = emptyList(),
    public val trust: BotMemoryTrust? = null,
    public val source: BotMemorySource? = null,
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["path"] = JsonString(path)
        members["scope"] = JsonString(scope.wire)
        members["content"] = JsonString(content)
        members["version"] = JsonNumber(version.toString())
        members["updated_at_ms"] = JsonNumber(updatedAtMs.toString())
        members["author"] = author.toJson()
        members["evidence"] = JsonArray(evidence.map(::JsonString))
        trust?.let { members["trust"] = JsonString(it.wire) }
        source?.let { members["source"] = it.toJson() }
        return JsonObject(members)
    }

    public companion object {
        private val allowedKeys = setOf(
            "path", "scope", "content", "version", "updated_at_ms", "author", "evidence", "trust", "source",
        )

        public fun fromJson(value: JsonValue?): BotMemoryDocument {
            val members = BotMemoryJson.objectMembers(value, "document")
            BotMemoryJson.rejectUnknown(members, "document", allowedKeys)
            val path = BotMemoryJson.string(members["path"], "document.path")
            if (BotMemoryText.scalarCount(path) !in 3..200) {
                throw BotJsonException("document.path has an invalid length")
            }
            val scope = BotMemoryScope.parse(BotMemoryJson.string(members["scope"], "document.scope"))
                ?: throw BotJsonException("document.scope must be agent or user")
            val version = BotMemoryJson.integer(members["version"], "document.version")
            if (version < 1) throw BotJsonException("document.version must be at least 1")
            val updatedAt = BotMemoryJson.integer64(members["updated_at_ms"], "document.updated_at_ms")
            if (updatedAt < 0) throw BotJsonException("document.updated_at_ms must not be negative")
            val evidence = BotMemoryJson.evidenceArray(members["evidence"], "document.evidence")
            if (evidence.size > 8) throw BotJsonException("document.evidence may have at most 8 items")
            evidence.forEach { BotMemoryEvidence.validateStoredReference(it) }
            if (BotMemoryPath.parse(path) == null) {
                throw BotJsonException("document.path is not a rooted memory path")
            }
            if (BotMemoryPath.scopeOf(path) != scope) {
                throw BotJsonException("document.path does not belong to document.scope")
            }
            val trustText = BotMemoryJson.optionalString(members["trust"], "document.trust")
            val trust = if (trustText == null) {
                null
            } else {
                BotMemoryTrust.parse(trustText)
                    ?: throw BotJsonException("document.trust is not a known trust value")
            }
            return BotMemoryDocument(
                path = path,
                scope = scope,
                content = BotMemoryJson.string(members["content"], "document.content"),
                version = version,
                updatedAtMs = updatedAt,
                author = BotMemoryAuthor.fromJson(members["author"]),
                evidence = evidence,
                trust = trust,
                source = members["source"]?.let { BotMemorySource.fromJson(it) },
            )
        }
    }
}

/** One historical version, including a deletion tombstone. */
public data class BotMemoryDocumentVersion(
    public val path: String,
    public val scope: BotMemoryScope,
    public val version: Int,
    public val content: String,
    public val deleted: Boolean = false,
    public val deletionReason: String? = null,
    public val updatedAtMs: Long,
    public val author: BotMemoryAuthor,
    public val evidence: List<String> = emptyList(),
    public val trust: BotMemoryTrust? = null,
) {
    public fun toDocument(): BotMemoryDocument = BotMemoryDocument(
        path = path,
        scope = scope,
        content = content,
        version = version,
        updatedAtMs = updatedAtMs,
        author = author,
        evidence = evidence,
        trust = trust,
    )
}

public data class BotMemoryDirectoryEntry(
    public val path: String,
    public val name: String,
    public val kind: Kind,
    public val version: Int? = null,
    public val updatedAtMs: Long? = null,
) {
    public enum class Kind(public val wire: String) {
        DOCUMENT("document"),
        DIRECTORY("directory"),
    }

    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["path"] = JsonString(path)
        members["name"] = JsonString(name)
        members["kind"] = JsonString(kind.wire)
        version?.let { members["version"] = JsonNumber(it.toString()) }
        updatedAtMs?.let { members["updated_at_ms"] = JsonNumber(it.toString()) }
        return JsonObject(members)
    }
}

/** `memory-read-result.schema.json`. */
public sealed interface BotMemoryReadResult {
    public val isFailure: Boolean

    public data class Document(public val version: BotMemoryDocumentVersion) : BotMemoryReadResult {
        override val isFailure: Boolean get() = false

        public fun toJson(): JsonObject {
            val members = LinkedHashMap<String, JsonValue>()
            members["ok"] = JsonBool(true)
            members["kind"] = JsonString("document")
            members["path"] = JsonString(version.path)
            members["scope"] = JsonString(version.scope.wire)
            members["version"] = JsonNumber(version.version.toString())
            members["content"] = JsonString(version.content)
            members["updated_at_ms"] = JsonNumber(version.updatedAtMs.toString())
            members["author"] = version.author.toJson()
            members["evidence"] = JsonArray(version.evidence.map(::JsonString))
            version.trust?.let { members["trust"] = JsonString(it.wire) }
            if (version.deleted) {
                members["deleted"] = JsonBool(true)
                // memory-read-result.schema.json only allows forget|erase.
                // A `move` tombstone is logically a forget for the source; the
                // stored event keeps the more specific reason for audit.
                members["deletion_reason"] = JsonString(
                    if (version.deletionReason == "erase") "erase" else "forget",
                )
            }
            return JsonObject(members)
        }
    }

    public data class Directory(
        public val path: String,
        public val scope: BotMemoryScope,
        public val entries: List<BotMemoryDirectoryEntry>,
    ) : BotMemoryReadResult {
        override val isFailure: Boolean get() = false

        public fun toJson(): JsonObject {
            val members = LinkedHashMap<String, JsonValue>()
            members["ok"] = JsonBool(true)
            members["kind"] = JsonString("directory")
            members["path"] = JsonString(path)
            members["scope"] = JsonString(scope.wire)
            members["entries"] = JsonArray(entries.map { it.toJson() })
            return JsonObject(members)
        }
    }

    public data class Failure(
        public val code: String,
        public val error: String,
        public val path: String? = null,
    ) : BotMemoryReadResult {
        override val isFailure: Boolean get() = true

        public fun toJson(): JsonObject {
            val members = LinkedHashMap<String, JsonValue>()
            members["ok"] = JsonBool(false)
            members["code"] = JsonString(code)
            members["error"] = JsonString(error)
            path?.let { members["path"] = JsonString(it) }
            return JsonObject(members)
        }
    }
}

public data class BotMemoryLimits(
    public val index: Int = BotMemoryLimits.INDEX,
    public val total: Int = BotMemoryLimits.TOTAL,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "index" to JsonNumber(index.toString()),
            "total" to JsonNumber(total.toString()),
        ),
    )

    public companion object {
        public const val INDEX: Int = 1_500
        public const val TOTAL: Int = 4_000
        public val standard: BotMemoryLimits = BotMemoryLimits()

        public fun fromJson(value: JsonValue?): BotMemoryLimits {
            val members = BotMemoryJson.objectMembers(value, "limits")
            BotMemoryJson.rejectUnknown(members, "limits", setOf("index", "total"))
            val index = BotMemoryJson.integer(members["index"], "limits.index")
            val total = BotMemoryJson.integer(members["total"], "limits.total")
            if (index != INDEX) throw BotJsonException("limits.index must be $INDEX")
            if (total != TOTAL) throw BotJsonException("limits.total must be $TOTAL")
            return BotMemoryLimits(index, total)
        }
    }
}

/** `memory-injection.schema.json`: the two root indexes plus the fixed explanation. */
public data class BotMemoryInjection(
    public val text: String,
    public val limits: BotMemoryLimits = BotMemoryLimits.standard,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "text" to JsonString(text),
            "limits" to limits.toJson(),
        ),
    )

    public companion object {
        public fun fromJson(value: JsonValue?): BotMemoryInjection {
            val members = BotMemoryJson.objectMembers(value, "injection")
            BotMemoryJson.rejectUnknown(members, "injection", setOf("text", "limits"))
            val text = BotMemoryJson.string(members["text"], "injection.text")
            if (BotMemoryText.scalarCount(text) > BotMemoryLimits.TOTAL) {
                throw BotJsonException("injection.text exceeds ${BotMemoryLimits.TOTAL} scalars")
            }
            return BotMemoryInjection(text = text, limits = BotMemoryLimits.fromJson(members["limits"]))
        }
    }
}

/** Internal accessors shared by the memory codecs; unknown members are rejected explicitly. */
internal object BotMemoryJson {
    fun objectMembers(value: JsonValue?, path: String): Map<String, JsonValue> =
        (value as? JsonObject)?.members ?: throw BotJsonException("$path must be an object")

    fun rejectUnknown(members: Map<String, JsonValue>, path: String, allowed: Set<String>) {
        val unknown = members.keys - allowed
        if (unknown.isNotEmpty()) {
            throw BotJsonException("$path has unknown member ${unknown.sorted().first()}")
        }
    }

    fun string(value: JsonValue?, path: String): String =
        (value as? JsonString)?.value ?: throw BotJsonException("$path must be a string")

    fun optionalString(value: JsonValue?, path: String): String? = when (value) {
        null, is JsonNull -> null
        is JsonString -> value.value
        else -> throw BotJsonException("$path must be a string")
    }

    fun boolean(value: JsonValue?, path: String): Boolean =
        (value as? JsonBool)?.value ?: throw BotJsonException("$path must be a boolean")

    fun optionalBoolean(value: JsonValue?, path: String): Boolean? = when (value) {
        null, is JsonNull -> null
        is JsonBool -> value.value
        else -> throw BotJsonException("$path must be a boolean")
    }

    fun integer(value: JsonValue?, path: String): Int =
        integer64(value, path).let {
            if (it < Int.MIN_VALUE || it > Int.MAX_VALUE) {
                throw BotJsonException("$path is out of range")
            }
            it.toInt()
        }

    fun integer64(value: JsonValue?, path: String): Long =
        (value as? JsonNumber)?.asLongOrNull() ?: throw BotJsonException("$path must be an integer")

    fun optionalInteger(value: JsonValue?, path: String): Int? = when (value) {
        null, is JsonNull -> null
        is JsonNumber -> {
            val number = value.asLongOrNull() ?: throw BotJsonException("$path must be an integer")
            if (number < Int.MIN_VALUE || number > Int.MAX_VALUE) {
                throw BotJsonException("$path is out of range")
            }
            number.toInt()
        }
        else -> throw BotJsonException("$path must be an integer")
    }

    fun array(value: JsonValue?, path: String): List<JsonValue> =
        (value as? JsonArray)?.values ?: throw BotJsonException("$path must be an array")

    fun optionalArray(value: JsonValue?, path: String): List<JsonValue>? = when (value) {
        null, is JsonNull -> null
        is JsonArray -> value.values
        else -> throw BotJsonException("$path must be an array")
    }

    fun stringArray(value: JsonValue?, path: String): List<String> =
        array(value, path).mapIndexed { index, item -> string(item, "$path[$index]") }

    fun evidenceArray(value: JsonValue?, path: String): List<String> =
        optionalArray(value, path)?.mapIndexed { index, item -> string(item, "$path[$index]") }
            ?: emptyList()

    fun number(value: Long): JsonNumber = JsonNumber(value.toString())
}
