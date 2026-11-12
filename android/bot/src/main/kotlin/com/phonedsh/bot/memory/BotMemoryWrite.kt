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

public enum class BotMemoryAction(public val wire: String) {
    WRITE("write"),
    APPEND("append"),
    REPLACE("replace"),
    MOVE("move"),
    DELETE("delete"),
    RESTORE("restore"),
    ;

    public companion object {
        public fun parse(value: String?): BotMemoryAction? =
            entries.firstOrNull { it.wire == value }
    }
}

/** Arguments of `UpdateMemory` (`memory-write-request.schema.json`). */
public data class BotMemoryWriteRequest(
    public val action: BotMemoryAction,
    public val path: String,
    public val content: String? = null,
    public val find: String? = null,
    public val replace: String? = null,
    public val to: String? = null,
    public val expectedVersion: Int,
    public val restoreVersion: Int? = null,
    public val evidence: List<String> = emptyList(),
    public val markedContradiction: Boolean = false,
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["action"] = JsonString(action.wire)
        members["path"] = JsonString(path)
        content?.let { members["content"] = JsonString(it) }
        find?.let { members["find"] = JsonString(it) }
        replace?.let { members["replace"] = JsonString(it) }
        to?.let { members["to"] = JsonString(it) }
        members["expected_version"] = JsonNumber(expectedVersion.toString())
        restoreVersion?.let { members["restore_version"] = JsonNumber(it.toString()) }
        if (evidence.isNotEmpty()) members["evidence"] = JsonArray(evidence.map(::JsonString))
        if (markedContradiction) members["marked_contradiction"] = JsonBool(true)
        return JsonObject(members)
    }

    public companion object {
        private val allowedKeys = setOf(
            "action", "path", "content", "find", "replace", "to", "expected_version",
            "restore_version", "evidence", "marked_contradiction",
        )

        public fun fromJson(value: JsonValue?): BotMemoryWriteRequest {
            val members = BotMemoryJson.objectMembers(value, "writeRequest")
            BotMemoryJson.rejectUnknown(members, "writeRequest", allowedKeys)
            val action = BotMemoryAction.parse(BotMemoryJson.string(members["action"], "action"))
                ?: throw BotJsonException("action is not a known memory action")
            val path = BotMemoryJson.string(members["path"], "path")
            if (BotMemoryText.scalarCount(path) < 3 || BotMemoryText.scalarCount(path) > 200) {
                throw BotJsonException("path has an invalid length")
            }
            val expected = BotMemoryJson.integer(members["expected_version"], "expected_version")
            if (expected < 0) throw BotJsonException("expected_version must not be negative")
            val find = BotMemoryJson.optionalString(members["find"], "find")
            if (find != null && find.isEmpty()) throw BotJsonException("find must not be empty")
            BotMemoryJson.optionalString(members["to"], "to")?.let {
                if (BotMemoryText.scalarCount(it) < 3 || BotMemoryText.scalarCount(it) > 200) {
                    throw BotJsonException("to has an invalid length")
                }
            }
            val restore = BotMemoryJson.optionalInteger(members["restore_version"], "restore_version")
            if (restore != null && restore < 1) throw BotJsonException("restore_version must be at least 1")
            val evidence = BotMemoryJson.optionalArray(members["evidence"], "evidence")
                ?.mapIndexed { index, item -> BotMemoryJson.string(item, "evidence[$index]") }
                ?: emptyList()
            if (evidence.size > BotMemoryEvidence.MAXIMUM_REFERENCES) {
                throw BotJsonException("evidence may have at most 8 items")
            }
            for (raw in evidence) {
                if (raw == BotMemoryEvidence.CURRENT_USER_TURN) continue
                if (raw.length > BotMemoryEvidence.MAXIMUM_REFERENCE_LENGTH ||
                    !BotMemoryEvidence.isCanonicalStoredReference(raw)
                ) {
                    throw BotJsonException("evidence is not a canonical record:// reference")
                }
            }
            return BotMemoryWriteRequest(
                action = action,
                path = path,
                content = BotMemoryJson.optionalString(members["content"], "content"),
                find = find,
                replace = BotMemoryJson.optionalString(members["replace"], "replace"),
                to = BotMemoryJson.optionalString(members["to"], "to"),
                expectedVersion = expected,
                restoreVersion = restore,
                evidence = evidence,
                markedContradiction = BotMemoryJson.optionalBoolean(
                    members["marked_contradiction"], "marked_contradiction",
                ) ?: false,
            )
        }
    }
}

/** `memory-write-result.schema.json`. Only members the schema allows are emitted. */
public sealed interface BotMemoryWriteResult {
    public val ok: Boolean
    public val action: BotMemoryAction
    public val path: String
    public val scope: BotMemoryScope?
    public val version: Int?
    public val code: String?

    public fun toJson(): JsonObject

    public data class Success(
        override val action: BotMemoryAction,
        override val path: String,
        override val scope: BotMemoryScope,
        override val version: Int,
        public val previousVersion: Int? = null,
        public val replaced: Int? = null,
    ) : BotMemoryWriteResult {
        override val ok: Boolean get() = true
        override val code: String? get() = null

        override fun toJson(): JsonObject {
            val members = LinkedHashMap<String, JsonValue>()
            members["ok"] = JsonBool(true)
            members["action"] = JsonString(action.wire)
            members["path"] = JsonString(path)
            members["scope"] = JsonString(scope.wire)
            members["version"] = JsonNumber(version.toString())
            previousVersion?.let { members["previous_version"] = JsonNumber(it.toString()) }
            replaced?.let { members["replaced"] = JsonNumber(it.toString()) }
            return JsonObject(members)
        }
    }

    public data class Failure(
        override val code: String,
        public val error: String,
        override val action: BotMemoryAction,
        override val path: String,
        override val scope: BotMemoryScope? = null,
        public val currentVersion: Int? = null,
        public val limit: Int? = null,
        public val actual: Int? = null,
    ) : BotMemoryWriteResult {
        override val ok: Boolean get() = false
        override val version: Int? get() = null

        override fun toJson(): JsonObject {
            val members = LinkedHashMap<String, JsonValue>()
            members["ok"] = JsonBool(false)
            members["code"] = JsonString(code)
            members["error"] = JsonString(error)
            members["path"] = JsonString(path)
            // The failure branch of memory-write-result.schema.json has no
            // `scope` member; the Swift MCP output currently emits one.
            currentVersion?.let { members["current_version"] = JsonNumber(it.toString()) }
            limit?.let { members["limit"] = JsonNumber(it.toString()) }
            actual?.let { members["actual"] = JsonNumber(it.toString()) }
            return JsonObject(members)
        }
    }

    public companion object {
        public val failureCodes: Set<String> = setOf(
            "memory-path-invalid", "memory-scope-denied", "memory-source-boundary",
            "memory-evidence-required", "memory-evidence-invalid", "memory-version-conflict",
            "memory-index-too-long", "memory-not-found", "memory-path-exists",
            "memory-replace-not-found", "memory-version-not-found",
        )

        public fun fromJson(value: JsonValue?): BotMemoryWriteResult {
            val members = BotMemoryJson.objectMembers(value, "writeResult")
            val ok = BotMemoryJson.boolean(members["ok"], "writeResult.ok")
            if (ok) {
                BotMemoryJson.rejectUnknown(
                    members, "writeResult",
                    setOf("ok", "action", "path", "scope", "version", "previous_version", "replaced", "count"),
                )
                val action = BotMemoryAction.parse(BotMemoryJson.string(members["action"], "writeResult.action"))
                    ?: throw BotJsonException("writeResult.action is not a known action")
                val scope = BotMemoryScope.parse(BotMemoryJson.string(members["scope"], "writeResult.scope"))
                    ?: throw BotJsonException("writeResult.scope must be agent or user")
                val version = BotMemoryJson.integer(members["version"], "writeResult.version")
                if (version < 1) throw BotJsonException("writeResult.version must be at least 1")
                BotMemoryJson.optionalInteger(members["count"], "writeResult.count")?.let {
                    if (it < 0) throw BotJsonException("writeResult.count must not be negative")
                }
                return Success(
                    action = action,
                    path = BotMemoryJson.string(members["path"], "writeResult.path"),
                    scope = scope,
                    version = version,
                    previousVersion = BotMemoryJson.optionalInteger(
                        members["previous_version"], "writeResult.previous_version",
                    ),
                    replaced = BotMemoryJson.optionalInteger(members["replaced"], "writeResult.replaced"),
                )
            }
            BotMemoryJson.rejectUnknown(
                members, "writeResult",
                setOf("ok", "code", "error", "path", "current_version", "limit", "actual"),
            )
            val code = BotMemoryJson.string(members["code"], "writeResult.code")
            if (code !in failureCodes) throw BotJsonException("writeResult.code is not a known memory error")
            val limit = BotMemoryJson.optionalInteger(members["limit"], "writeResult.limit")
            if (limit != null && limit != BotMemoryLimits.INDEX) {
                throw BotJsonException("writeResult.limit must be ${BotMemoryLimits.INDEX}")
            }
            return Failure(
                code = code,
                error = BotMemoryJson.string(members["error"], "writeResult.error"),
                action = BotMemoryAction.WRITE,
                path = BotMemoryJson.optionalString(members["path"], "writeResult.path").orEmpty(),
                currentVersion = BotMemoryJson.optionalInteger(
                    members["current_version"], "writeResult.current_version",
                ),
                limit = limit,
                actual = BotMemoryJson.optionalInteger(members["actual"], "writeResult.actual"),
            )
        }
    }
}

/**
 * The host-derived context of one write. `trust` is the value derived from
 * `evidence` before the store is called; `currentUserTurnReference` is the
 * host-observed reference behind the reserved `current-user-turn` item.
 */
public data class BotMemoryWriteContext(
    public val botId: String,
    public val sessionId: String?,
    public val authorKind: BotMemoryAuthorKind,
    public val source: BotMemorySource,
    public val trust: BotMemoryTrust?,
    public val isMainBot: Boolean = true,
    public val batchId: String? = null,
    public val isHostRollback: Boolean = false,
    public val currentUserTurnReference: String? = null,
)

public data class BotMemoryForgetResult(
    public val ok: Boolean,
    public val error: String? = null,
    public val removed: Int,
    public val path: String,
    public val version: Int? = null,
    public val count: Int,
    public val scope: BotMemoryScope,
)

public data class BotMemoryEraseScopeResult(
    public val ok: Boolean,
    public val error: String? = null,
    public val scope: BotMemoryScope,
    public val botId: String,
    public val removed: Int,
    public val count: Int,
)

/** Store-level write request; the authorizer has already run. */
public data class BotMemoryStoreWriteRequest(
    public val action: BotMemoryAction,
    public val path: String,
    public val content: String? = null,
    public val find: String? = null,
    public val replace: String? = null,
    public val to: String? = null,
    public val expectedVersion: Int,
    public val restoreVersion: Int? = null,
    public val author: BotMemoryAuthor,
    public val evidence: List<String> = emptyList(),
    public val trust: BotMemoryTrust? = null,
    public val source: BotMemorySource? = null,
    public val atMs: Long,
    public val correlationId: String? = null,
)

public sealed interface BotMemoryStoreWriteOutcome {
    public data class Written(
        public val document: BotMemoryDocument,
        public val replaced: Int? = null,
    ) : BotMemoryStoreWriteOutcome

    public data class Deleted(public val version: BotMemoryDocumentVersion) : BotMemoryStoreWriteOutcome

    public data class Conflict(public val currentVersion: Int) : BotMemoryStoreWriteOutcome

    public data class NotFound(public val path: String) : BotMemoryStoreWriteOutcome

    public data class PathExists(public val path: String) : BotMemoryStoreWriteOutcome

    public data object ReplaceNotFound : BotMemoryStoreWriteOutcome

    public data class VersionNotFound(public val version: Int) : BotMemoryStoreWriteOutcome

    public data class IndexTooLong(
        public val path: String,
        public val limit: Int,
        public val actual: Int,
    ) : BotMemoryStoreWriteOutcome
}

/** A `memory.document_written`/`memory.document_deleted` event could not be replayed. */
public class BotMemoryStoreException(
    public val code: String,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

public data class BotMemoryReplayDiagnostics(
    public val fullReplayCount: Int,
    public val incrementalReplayCount: Int,
    public val scannedEventCount: Int,
    public val processedMemoryEventCount: Int,
    public val skippedEventIds: List<String>,
    public val lastProcessedCommitSeq: Long,
)
