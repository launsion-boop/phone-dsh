// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJsonException
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventBatch
import com.phonedsh.bot.store.BotEventErasureTarget
import com.phonedsh.bot.store.BotEventOrigin
import com.phonedsh.bot.store.BotPrincipal
import com.phonedsh.bot.store.sha256
import java.util.UUID

/** Physical-erasure callback owned by the session-epoch coordinator (S6). */
public data class BotMemorySessionErasureRequest(
    public val botId: String,
    public val callerSessionId: String?,
    public val needles: List<String>,
    public val records: List<String>,
    public val atMs: Long,
    public val scope: BotMemoryScope,
)

public data class BotMemoryUncoveredRecord(
    public val record: String,
    public val reason: String,
)

public data class BotMemorySessionErasureReport(
    public val erasedSessionRecords: List<JsonObject> = emptyList(),
    public val sessionEpochs: List<JsonObject> = emptyList(),
    public val uncoveredRecords: List<BotMemoryUncoveredRecord> = emptyList(),
)

public fun interface BotMemorySessionEraser {
    public fun erase(request: BotMemorySessionErasureRequest): BotMemorySessionErasureReport
}

public data class BotMemoryPhysicalEraseOutcome(
    public val ok: Boolean,
    public val error: String? = null,
    public val scope: BotMemoryScope,
    public val paths: List<String> = emptyList(),
    public val removedDocuments: Int = 0,
    public val removedVersions: Int = 0,
    public val erasedEvents: Int = 0,
    public val erasedEventSequences: List<Long> = emptyList(),
    public val erasedBytes: Long = 0,
    public val erasureRecord: String? = null,
    public val uncoveredRecords: List<String> = emptyList(),
    public val survivingPaths: List<String> = emptyList(),
    public val legacyFactIds: List<String> = emptyList(),
    public val erasedSessionRecords: List<JsonObject> = emptyList(),
    public val sessionEpochs: List<JsonObject> = emptyList(),
)

/** The live document-tree authority (`SQLiteBotMemoryDocumentStore` in Swift). */
/** Optional durable `memory.review_requested` writer used by `marked_contradiction`. */
public interface BotMemoryReviewWriter {
    public fun recordReviewRequested(
        botId: String,
        action: BotMemoryAuthor,
        path: String,
        scope: BotMemoryScope,
        version: Int,
        evidence: List<String>,
        atMs: Long,
        correlationId: String?,
    )
}

public interface BotMemoryDocumentStore {
    public fun documents(scope: BotMemoryScope? = null): List<BotMemoryDocument>

    public fun document(path: String): BotMemoryDocument?

    public fun versions(path: String): List<BotMemoryDocumentVersion>

    public fun write(request: BotMemoryStoreWriteRequest): BotMemoryStoreWriteOutcome

    /** Logical delete of one root, used by "forget all". */
    public fun eraseAll(scope: BotMemoryScope, author: BotMemoryAuthor, atMs: Long): Int

    public fun erase(
        path: String,
        author: BotMemoryAuthor,
        atMs: Long,
        sessionEraser: BotMemorySessionEraser? = null,
    ): BotMemoryPhysicalEraseOutcome

    public fun erase(
        scope: BotMemoryScope,
        author: BotMemoryAuthor,
        atMs: Long,
        sessionEraser: BotMemorySessionEraser? = null,
    ): BotMemoryPhysicalEraseOutcome

    /** Legacy facts visible to this Bot (own agent facts + shared user facts). */
    public fun legacyFacts(scope: BotMemoryScope? = null): List<BotMemoryLegacyFact>

    public fun replayDiagnostics(): BotMemoryReplayDiagnostics
}

/**
 * SQLite-backed document tree over the P25 event log. Every version
 * (including deletion) is one durable event; replay is incremental and
 * filters `agent/` paths to this Bot while `user/` stays shared.
 */
public class BotSqlMemoryDocumentStore(
    private val eventLog: BotMemoryEventLog,
    private val botId: String? = null,
    private val now: () -> Long = { System.currentTimeMillis() },
    private val replayFeed: BotMemoryReplayFeed = BotMemoryReplayFeed(),
) : BotMemoryDocumentStore, BotMemoryReviewWriter {
    private class ReplayState {
        val order = ArrayList<String>()
        val live = LinkedHashMap<String, BotMemoryDocument>()
        val versions = LinkedHashMap<String, LinkedHashMap<Int, BotMemoryDocumentVersion>>()
        val latestVersion = HashMap<String, Int>()
        val legacyFacts = LinkedHashMap<String, BotMemoryLegacyFact>()
        val legacyOrder = ArrayList<String>()
        val appliedEventIds = HashSet<String>()

        fun documents(scope: BotMemoryScope?): List<BotMemoryDocument> =
            order.mapNotNull { path ->
                val document = live[path] ?: return@mapNotNull null
                if (scope != null && document.scope != scope) null else document
            }.sortedBy { it.path }

        fun versionsOf(path: String): List<BotMemoryDocumentVersion> =
            versions[path]?.values?.sortedBy { it.version } ?: emptyList()
    }

    private data class WrittenPayload(
        val path: String,
        val scope: BotMemoryScope,
        val content: String,
        val version: Int,
        val expectedVersion: Int,
        val updatedAtMs: Long,
        val author: BotMemoryAuthor,
        val evidence: List<String>,
        val trust: BotMemoryTrust?,
        val source: BotMemorySource?,
    ) {
        fun toJson(): JsonObject {
            val members = LinkedHashMap<String, JsonValue>()
            members["path"] = JsonString(path)
            members["scope"] = JsonString(scope.wire)
            members["content"] = JsonString(content)
            members["version"] = JsonNumber(version.toString())
            members["expected_version"] = JsonNumber(expectedVersion.toString())
            members["updated_at_ms"] = JsonNumber(updatedAtMs.toString())
            members["author"] = author.toJson()
            members["evidence"] = JsonArray(evidence.map(::JsonString))
            trust?.let { members["trust"] = JsonString(it.wire) }
            source?.let { members["source"] = it.toJson() }
            return JsonObject(members)
        }

        fun document(): BotMemoryDocument = BotMemoryDocument(
            path = path,
            scope = scope,
            content = content,
            version = version,
            updatedAtMs = updatedAtMs,
            author = author,
            evidence = evidence,
            trust = trust,
            source = source,
        )
    }

    private data class DeletedPayload(
        val path: String,
        val scope: BotMemoryScope,
        val version: Int,
        val expectedVersion: Int,
        val at: Long,
        val reason: String,
        val author: BotMemoryAuthor,
        val evidence: List<String>,
        val trust: BotMemoryTrust?,
    ) {
        fun toJson(): JsonObject {
            val members = LinkedHashMap<String, JsonValue>()
            members["path"] = JsonString(path)
            members["scope"] = JsonString(scope.wire)
            members["version"] = JsonNumber(version.toString())
            members["expected_version"] = JsonNumber(expectedVersion.toString())
            members["at"] = JsonNumber(at.toString())
            members["reason"] = JsonString(reason)
            members["author"] = author.toJson()
            members["evidence"] = JsonArray(evidence.map(::JsonString))
            trust?.let { members["trust"] = JsonString(it.wire) }
            return JsonObject(members)
        }
    }

    private data class ForgottenPayload(
        val factId: String,
        val scope: BotMemoryScope,
        val at: Long,
        val reason: String,
    )

    private val state = ReplayState()
    private var processedEventIndex = 0
    private var processedMemoryEventCount = 0
    private var inWriteTransaction = false
    private var lastProcessedCommitSeq = 0L
    private val skippedEventIds = ArrayList<String>()

    private val effectiveBotId: String = normalizeBotId(botId)

    @Synchronized
    override fun documents(scope: BotMemoryScope?): List<BotMemoryDocument> {
        replay()
        return state.documents(scope)
    }

    @Synchronized
    override fun document(path: String): BotMemoryDocument? {
        replay()
        return state.live[path]
    }

    @Synchronized
    override fun versions(path: String): List<BotMemoryDocumentVersion> {
        replay()
        return state.versionsOf(path)
    }

    @Synchronized
    override fun legacyFacts(scope: BotMemoryScope?): List<BotMemoryLegacyFact> {
        replay()
        return state.legacyOrder.mapNotNull { id ->
            val fact = state.legacyFacts[id] ?: return@mapNotNull null
            if (scope != null && fact.scope != scope) null else fact
        }
    }

    @Synchronized
    override fun replayDiagnostics(): BotMemoryReplayDiagnostics {
        val feed = replayFeed.diagnostics()
        return BotMemoryReplayDiagnostics(
            fullReplayCount = feed.fullReplayCount,
            incrementalReplayCount = feed.incrementalReplayCount,
            scannedEventCount = feed.scannedEventCount,
            processedMemoryEventCount = processedMemoryEventCount,
            skippedEventIds = skippedEventIds.toList(),
            lastProcessedCommitSeq = lastProcessedCommitSeq,
        )
    }

    @Synchronized
    override fun write(request: BotMemoryStoreWriteRequest): BotMemoryStoreWriteOutcome {
        var outcome: BotMemoryStoreWriteOutcome? = null
        eventLog.writeTransaction {
            inWriteTransaction = true
            try {
                outcome = writeLocked(request)
            } finally {
                inWriteTransaction = false
            }
        }
        val result = outcome
            ?: throw BotMemoryStoreException("corrupted", "memory write produced no outcome")
        if (result is BotMemoryStoreWriteOutcome.Written) {
            replay()
            val live = state.live[result.document.path]
            return if (live != null) result.copy(document = live) else result
        }
        if (result is BotMemoryStoreWriteOutcome.Deleted) replay()
        return result
    }

    private fun writeLocked(request: BotMemoryStoreWriteRequest): BotMemoryStoreWriteOutcome {
        replay()
        val currentVersion = state.live[request.path]?.version ?: 0
        if (request.expectedVersion != currentVersion) {
            return BotMemoryStoreWriteOutcome.Conflict(currentVersion)
        }
        val current = state.live[request.path]

        var writtenContent: String?
        var replacedCount: Int? = null
        var targetPath = request.path
        when (request.action) {
            BotMemoryAction.WRITE -> writtenContent = request.content ?: ""
            BotMemoryAction.APPEND -> {
                current ?: return BotMemoryStoreWriteOutcome.NotFound(request.path)
                writtenContent = current.content + (request.content ?: "")
            }
            BotMemoryAction.REPLACE -> {
                current ?: return BotMemoryStoreWriteOutcome.NotFound(request.path)
                val find = request.find ?: ""
                if (find.isEmpty()) return BotMemoryStoreWriteOutcome.ReplaceNotFound
                val count = occurrences(current.content, find)
                if (count == 0) return BotMemoryStoreWriteOutcome.ReplaceNotFound
                writtenContent = current.content.replace(find, request.replace ?: "")
                replacedCount = count
            }
            BotMemoryAction.RESTORE -> {
                val version = request.restoreVersion ?: 0
                val restored = state.versions[request.path]?.get(version)
                if (restored == null || restored.deleted) {
                    return BotMemoryStoreWriteOutcome.VersionNotFound(version)
                }
                writtenContent = restored.content
            }
            BotMemoryAction.MOVE -> {
                current ?: return BotMemoryStoreWriteOutcome.NotFound(request.path)
                val destination = request.to ?: return BotMemoryStoreWriteOutcome.NotFound(request.path)
                if (state.live[destination] != null) {
                    return BotMemoryStoreWriteOutcome.PathExists(destination)
                }
                targetPath = destination
                writtenContent = current.content
            }
            BotMemoryAction.DELETE -> {
                current ?: return BotMemoryStoreWriteOutcome.NotFound(request.path)
                val version = (state.latestVersion[request.path] ?: current.version) + 1
                val deletion = BotMemoryDocumentVersion(
                    path = request.path,
                    scope = current.scope,
                    version = version,
                    content = "",
                    deleted = true,
                    deletionReason = "forget",
                    updatedAtMs = request.atMs,
                    author = request.author,
                    evidence = request.evidence,
                    trust = request.trust,
                )
                val event = deletionEvent(deletion, request.expectedVersion, request.correlationId)
                commit(listOf(event))
                return BotMemoryStoreWriteOutcome.Deleted(deletion)
            }
        }

        val content = writtenContent ?: return BotMemoryStoreWriteOutcome.NotFound(request.path)
        val scope = BotMemoryPath.scopeOf(targetPath) ?: current?.scope ?: BotMemoryScope.AGENT
        BotMemoryPath.indexOverflow(targetPath, content)?.let { actual ->
            return BotMemoryStoreWriteOutcome.IndexTooLong(
                path = targetPath,
                limit = BotMemoryLimits.INDEX,
                actual = actual,
            )
        }
        val latest = state.latestVersion[targetPath] ?: 0
        val version = latest + 1
        val document = BotMemoryDocument(
            path = targetPath,
            scope = scope,
            content = content,
            version = version,
            updatedAtMs = request.atMs,
            author = request.author,
            evidence = request.evidence,
            trust = request.trust ?: if (scope == BotMemoryScope.USER) {
                BotMemoryTrust.USER
            } else {
                BotMemoryTrust.ASSISTANT
            },
            source = request.source,
        )
        val targetExpected = state.live[targetPath]?.version ?: 0
        val writeEvent = writtenEvent(document, targetExpected, request.correlationId)

        if (request.action == BotMemoryAction.MOVE) {
            val source = current ?: return BotMemoryStoreWriteOutcome.NotFound(request.path)
            val sourceVersion = source.version
            val deletion = BotMemoryDocumentVersion(
                path = source.path,
                scope = source.scope,
                version = sourceVersion + 1,
                content = "",
                deleted = true,
                deletionReason = "move",
                updatedAtMs = request.atMs,
                author = request.author,
                evidence = request.evidence,
                trust = request.trust,
            )
            val deleteEvent = deletionEvent(deletion, sourceVersion, request.correlationId)
            commit(listOf(writeEvent, deleteEvent))
        } else {
            commit(listOf(writeEvent))
        }
        replay()
        return BotMemoryStoreWriteOutcome.Written(
            document = state.live[targetPath] ?: document,
            replaced = replacedCount,
        )
    }

    override fun recordReviewRequested(
        botId: String,
        action: BotMemoryAuthor,
        path: String,
        scope: BotMemoryScope,
        version: Int,
        evidence: List<String>,
        atMs: Long,
        correlationId: String?,
    ) {
        val data = JsonObject(
            linkedMapOf(
                "path" to JsonString(path),
                "scope" to JsonString(scope.wire),
                "version" to JsonNumber(version.toString()),
                "evidence" to JsonArray(evidence.map(::JsonString)),
            ),
        )
        val eventId = "memory.review_requested:$botId:$path:$version"
        val event = makeEvent(
            type = "memory.review_requested",
            eventId = eventId,
            data = data,
            at = atMs,
            author = action,
            source = null,
            correlationId = correlationId,
        )
        eventLog.append(event)
    }

    @Synchronized
    override fun eraseAll(scope: BotMemoryScope, author: BotMemoryAuthor, atMs: Long): Int {
        replay()
        val targets = state.documents(scope)
        if (targets.isEmpty()) return 0
        val events = targets.map { document ->
            val version = (state.latestVersion[document.path] ?: document.version) + 1
            val deletion = BotMemoryDocumentVersion(
                path = document.path,
                scope = document.scope,
                version = version,
                content = "",
                deleted = true,
                deletionReason = "erase",
                updatedAtMs = atMs,
                author = author,
                evidence = emptyList(),
                trust = null,
            )
            deletionEvent(deletion, document.version, correlationId = null)
        }
        commit(events)
        replay()
        return targets.size
    }

    @Synchronized
    override fun erase(
        path: String,
        author: BotMemoryAuthor,
        atMs: Long,
        sessionEraser: BotMemorySessionEraser?,
    ): BotMemoryPhysicalEraseOutcome {
        replay()
        val scope = BotMemoryPath.scopeOf(path)
            ?: return BotMemoryPhysicalEraseOutcome(
                ok = false, error = "memory-path-invalid", scope = BotMemoryScope.AGENT,
            )
        val hasHistory = state.versions[path] != null
        if (!hasHistory && state.live[path] == null) {
            return BotMemoryPhysicalEraseOutcome(
                ok = false, error = "memory-not-found", scope = scope,
            )
        }
        return erasePhysical(
            paths = listOf(path),
            scope = scope,
            target = BotMemoryErasureTarget(scope = scope, path = path),
            scopeErase = false,
            author = author,
            atMs = atMs,
            sessionEraser = sessionEraser,
        )
    }

    @Synchronized
    override fun erase(
        scope: BotMemoryScope,
        author: BotMemoryAuthor,
        atMs: Long,
        sessionEraser: BotMemorySessionEraser?,
    ): BotMemoryPhysicalEraseOutcome {
        replay()
        val paths = pathsIn(scope)
        return erasePhysical(
            paths = paths,
            scope = scope,
            target = BotMemoryErasureTarget(scope = scope),
            scopeErase = true,
            author = author,
            atMs = atMs,
            sessionEraser = sessionEraser,
        )
    }

    private fun pathsIn(scope: BotMemoryScope): List<String> {
        val paths = sortedSetOf<String>()
        for ((path, versions) in state.versions) {
            if (versions.values.any { it.scope == scope }) paths += path
        }
        for (document in state.live.values) {
            if (document.scope == scope) paths += document.path
        }
        return paths.toList()
    }

    private fun erasePhysical(
        paths: List<String>,
        scope: BotMemoryScope,
        target: BotMemoryErasureTarget,
        scopeErase: Boolean,
        author: BotMemoryAuthor,
        atMs: Long,
        sessionEraser: BotMemorySessionEraser?,
    ): BotMemoryPhysicalEraseOutcome {
        val targetPaths = paths.toSet()
        // Feed the planner every document this store can see, so
        // survivingPaths is correct; target selection still filters by
        // scope/path and the agent principal.
        val allPaths = LinkedHashSet<String>()
        allPaths += state.order
        allPaths += state.versions.keys
        val stateDocuments = allPaths.map { path ->
            val versions = state.versionsOf(path).ifEmpty {
                state.live[path]?.let { live ->
                    listOf(
                        BotMemoryDocumentVersion(
                            path = live.path, scope = live.scope, version = live.version,
                            content = live.content, updatedAtMs = live.updatedAtMs,
                            author = live.author, evidence = live.evidence, trust = live.trust,
                        ),
                    )
                } ?: emptyList()
            }
            BotMemoryErasureStateDocument(
                path = path,
                scope = versions.firstOrNull()?.scope
                    ?: state.live[path]?.scope
                    ?: scope,
                botId = effectiveBotId,
                live = state.live[path] != null,
                versions = versions.map {
                    BotMemoryErasureVersion(it.version, it.content, it.deleted)
                },
                evidence = versions.flatMap { it.evidence }.distinct().sorted(),
            )
        }

        val allEvents = allDurableEvents()
        val stateEvents = allEvents.mapNotNull { event ->
            val sequence = event.commitSeq ?: return@mapNotNull null
            val data = event.data as? JsonObject
            val type = event.type
            val erasedPayload = (data?.members?.get("\$erased") as? JsonBool)?.value == true
            val memoryType = type.startsWith("memory.") || type == "erasure"
            BotMemoryErasureStateEvent(
                seq = sequence,
                type = type,
                botId = normalizeBotId(event.principal.botId),
                path = (data?.members?.get("path") as? JsonString)?.value,
                text = when {
                    erasedPayload -> null
                    type == "memory.written" ->
                        (data?.members?.get("text") as? JsonString)?.value
                    memoryType -> null
                    else -> readableText(event.data)
                },
                refs = collectRecordReferences(event.data),
                factId = when (type) {
                    "memory.written" -> (data?.members?.get("fact_id") as? JsonString)?.value
                    "memory.forgotten" -> (data?.members?.get("factId") as? JsonString)?.value
                    else -> null
                },
                factScope = when (type) {
                    "memory.written" -> (data?.members?.get("scope") as? JsonString)?.value
                    "memory.forgotten" -> (data?.members?.get("scope") as? JsonString)?.value
                    else -> null
                },
                erasedPayload = erasedPayload,
            )
        }

        val planned = BotMemoryErasurePlanner.plan(target, effectiveBotId, stateDocuments, stateEvents)
        planned.plan ?: return BotMemoryPhysicalEraseOutcome(
            ok = false,
            error = planned.error ?: "memory-path-invalid",
            scope = scope,
        )
        val plan = planned.plan
        val metadata = if (plan.erasedEvents.isEmpty()) {
            emptyList()
        } else {
            eventLog.erasureTargets(plan.erasedEvents.map {
                require(it <= Int.MAX_VALUE) { "commit sequence does not fit the P25 API" }
                it.toInt()
            })
        }
        val payloadTargets = metadata.filter { it.payloadBytes > 0 }

        val sessionReport = if (sessionEraser != null) {
            sessionEraser.erase(
                BotMemorySessionErasureRequest(
                    botId = normalizeBotId(author.botId ?: botId),
                    callerSessionId = author.sessionId,
                    needles = plan.needles,
                    records = plan.uncoveredRecords,
                    atMs = atMs,
                    scope = scope,
                ),
            )
        } else {
            BotMemorySessionErasureReport()
        }
        val uncovered = if (sessionEraser == null) {
            plan.uncoveredRecords.map {
                BotMemoryUncoveredRecord(it, "session-log-erasure-not-implemented")
            }
        } else {
            sessionReport.uncoveredRecords
        }

        var erasureRecord: String? = null
        var erasedBytes = 0L
        if (payloadTargets.isNotEmpty() ||
            sessionReport.erasedSessionRecords.isNotEmpty() ||
            sessionReport.sessionEpochs.isNotEmpty()
        ) {
            val erasureId = "erasure-" + UUID.randomUUID().toString().lowercase()
            val data = erasureEventData(
                erasureId = erasureId,
                scope = scope,
                path = target.path,
                scopeErase = scopeErase,
                atMs = atMs,
                plan = plan,
                payloadTargets = payloadTargets,
                uncovered = uncovered,
                sessionReport = sessionReport,
            )
            val event = BotEvent(
                schemaVersion = 1,
                type = "erasure",
                eventId = "erasure-$erasureId",
                commitSeq = null,
                time = maxOf(0, atMs),
                origin = BotEventOrigin.Local("user"),
                traceId = "trace-$erasureId",
                principal = BotPrincipal(author.botId, null, "ipc", emptyList()),
                causationId = null,
                correlationId = null,
                data = data,
            )
            if (payloadTargets.isEmpty()) {
                val sequence = eventLog.append(event)
                erasureRecord = "record://event/$sequence"
            } else {
                val commit = eventLog.erasePayloads(
                    payloadTargets.map { it.commitSeq.toInt() },
                    event,
                    atMs,
                )
                erasureRecord = "record://event/${commit.erasureCommitSeq}"
                erasedBytes = payloadTargets.sumOf { it.payloadBytes }
            }
        }

        removeFromState(targetPaths, plan, scope, scopeErase)
        val surviving = state.documents(scope).map { it.path }.filter {
            it !in targetPaths
        }.sorted()
        return BotMemoryPhysicalEraseOutcome(
            ok = true,
            scope = scope,
            paths = plan.paths,
            removedDocuments = plan.removedDocuments,
            removedVersions = plan.removedVersions,
            erasedEvents = payloadTargets.size,
            erasedEventSequences = payloadTargets.map { it.commitSeq },
            erasedBytes = erasedBytes,
            erasureRecord = erasureRecord,
            uncoveredRecords = uncovered.map { it.record }.sorted(),
            survivingPaths = surviving,
            legacyFactIds = plan.legacyFactIds,
            erasedSessionRecords = sessionReport.erasedSessionRecords,
            sessionEpochs = sessionReport.sessionEpochs,
        )
    }

    private fun removeFromState(
        paths: Set<String>,
        plan: BotMemoryErasurePlan,
        scope: BotMemoryScope,
        scopeErase: Boolean,
    ) {
        for (path in paths) {
            state.live.remove(path)
            state.versions.remove(path)
            state.latestVersion.remove(path)
        }
        state.order.removeAll { it in paths }
        val factIds = plan.legacyFactIds.toSet()
        state.legacyFacts.entries.removeAll { (id, fact) ->
            id in factIds || (scopeErase && fact.scope == scope)
        }
        state.legacyOrder.removeAll { state.legacyFacts[it] == null }
    }

    private fun erasureEventData(
        erasureId: String,
        scope: BotMemoryScope,
        path: String?,
        scopeErase: Boolean,
        atMs: Long,
        plan: BotMemoryErasurePlan,
        payloadTargets: List<BotEventErasureTarget>,
        uncovered: List<BotMemoryUncoveredRecord>,
        sessionReport: BotMemorySessionErasureReport,
    ): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["schemaVersion"] = JsonNumber("1")
        members["erasureId"] = JsonString(erasureId)
        members["reason"] = JsonString(
            if (scopeErase) "memory-scope-erase" else "memory-document-erase",
        )
        members["requestedBy"] = JsonString("user")
        members["at_ms"] = JsonNumber(maxOf(0, atMs).toString())
        val targetMembers = LinkedHashMap<String, JsonValue>()
        targetMembers["kind"] = JsonString("memory")
        targetMembers["scope"] = JsonString(scope.wire)
        path?.let { targetMembers["path"] = JsonString(it) }
        members["targets"] = JsonArray(listOf(JsonObject(targetMembers)))
        members["memoryVersions"] = JsonArray(
            plan.memoryVersions.map { range ->
                JsonObject(
                    linkedMapOf(
                        "path" to JsonString(range.path),
                        "scope" to JsonString(range.scope.wire),
                        "versions" to JsonArray(range.versions.map { JsonNumber(it.toString()) }),
                    ),
                )
            },
        )
        members["erasedEvents"] = JsonArray(
            payloadTargets.map { erased ->
                JsonObject(
                    linkedMapOf(
                        "record" to JsonString("record://event/${erased.commitSeq}"),
                        "type" to JsonString(erased.type),
                        "digest" to JsonString(erased.digest),
                        "payloadBytes" to JsonNumber(erased.payloadBytes.toString()),
                    ),
                )
            },
        )
        members["erasedBytes"] = JsonNumber(payloadTargets.sumOf { it.payloadBytes }.toString())
        members["uncoveredRecords"] = JsonArray(
            uncovered.map { record ->
                JsonObject(
                    linkedMapOf(
                        "record" to JsonString(record.record),
                        "reason" to JsonString(record.reason),
                    ),
                )
            },
        )
        members["legacyFactIDs"] = JsonArray(plan.legacyFactIds.map(::JsonString))
        members["erasedSessionRecords"] = JsonArray(sessionReport.erasedSessionRecords)
        members["sessionEpochs"] = JsonArray(sessionReport.sessionEpochs)
        return JsonObject(members)
    }

    // ------------------------------------------------------------------
    // replay
    // ------------------------------------------------------------------

    private fun replay(): ReplayState {
        val events = replayFeed.memoryEvents(processedEventIndex, eventLog)
        if (events.isEmpty()) return state
        var index = processedEventIndex
        for (event in events) {
            val commitSeq = event.commitSeq
            if (commitSeq == null) {
                processedEventIndex = index
                throw BotMemoryStoreException("corrupted", "durable memory event has no commitSeq")
            }
            try {
                apply(event)
            } catch (error: BotMemoryStoreException) {
                processedEventIndex = index
                throw error
            } catch (error: BotJsonException) {
                recordSkipped(event)
            }
            index += 1
            processedMemoryEventCount += 1
            lastProcessedCommitSeq = commitSeq
        }
        processedEventIndex = index
        return state
    }

    private fun apply(event: BotEvent) {
        if (event.eventId in state.appliedEventIds) return
        val data = event.data as? JsonObject
            ?: throw BotJsonException("memory event data is not an object")
        if ((data.members["\$erased"] as? JsonBool)?.value == true) return
        when (event.type) {
            "memory.document_written" -> {
                val written = decodeWritten(data)
                if (!belongsToThisBot(event, written.scope)) return
                applyWritten(written.document())
            }
            "memory.document_deleted" -> {
                val deleted = decodeDeleted(data)
                if (!belongsToThisBot(event, deleted.scope)) return
                applyDeleted(deleted)
            }
            "memory.written" -> {
                val fact = BotMemoryLegacyFact.fromJson(data)
                if (!belongsToThisBot(event, fact.scope)) return
                if (state.legacyFacts[fact.factId] == null) state.legacyOrder += fact.factId
                state.legacyFacts[fact.factId] = fact
            }
            "memory.forgotten" -> {
                val forgotten = decodeForgotten(data)
                if (!belongsToThisBot(event, forgotten.scope)) return
                state.legacyFacts.remove(forgotten.factId)
                state.legacyOrder.removeAll { it == forgotten.factId }
            }
            "erasure" -> applyErasure(event, data)
            else -> return
        }
        state.appliedEventIds += event.eventId
    }

    private fun applyWritten(document: BotMemoryDocument) {
        val latest = state.latestVersion[document.path] ?: 0
        val existing = state.versions[document.path]?.get(document.version)
        if (existing != null) {
            if (existing.content == document.content && !existing.deleted) return
            throw BotMemoryStoreException(
                "corrupted",
                "conflicting document.written payloads for ${document.path}#${document.version}",
            )
        }
        if (document.version <= latest) {
            // A forward jump is a tombstone: the erased version's payload is
            // gone, so skipping it is correct. A non-forward duplicate is not.
            throw BotMemoryStoreException(
                "corrupted",
                "non-contiguous document version ${document.path}#${document.version}",
            )
        }
        if (state.live[document.path] == null) state.order += document.path
        state.live[document.path] = document
        state.versions.getOrPut(document.path) { LinkedHashMap() }[document.version] =
            BotMemoryDocumentVersion(
                path = document.path,
                scope = document.scope,
                version = document.version,
                content = document.content,
                updatedAtMs = document.updatedAtMs,
                author = document.author,
                evidence = document.evidence,
                trust = document.trust,
            )
        state.latestVersion[document.path] = document.version
    }

    private fun applyDeleted(data: DeletedPayload) {
        val latest = state.latestVersion[data.path] ?: 0
        val existing = state.versions[data.path]?.get(data.version)
        if (existing != null) {
            if (existing.deleted) return
            throw BotMemoryStoreException(
                "corrupted",
                "conflicting document.deleted payloads for ${data.path}#${data.version}",
            )
        }
        if (data.version <= latest) {
            throw BotMemoryStoreException(
                "corrupted",
                "non-contiguous document version ${data.path}#${data.version}",
            )
        }
        val version = BotMemoryDocumentVersion(
            path = data.path,
            scope = data.scope,
            version = data.version,
            content = "",
            deleted = true,
            deletionReason = data.reason,
            updatedAtMs = data.at,
            author = data.author,
            evidence = data.evidence,
            trust = data.trust,
        )
        state.versions.getOrPut(data.path) { LinkedHashMap() }[data.version] = version
        state.live.remove(data.path)
        state.latestVersion[data.path] = data.version
    }

    private fun applyErasure(event: BotEvent, data: JsonObject) {
        val erasingBot = normalizeBotId(event.principal.botId)
        val members = data.members
        val targets = (members["targets"] as? JsonArray)?.values ?: emptyList()
        val removedPaths = HashSet<String>()
        val scopeErases = ArrayList<BotMemoryScope>()
        for (target in targets) {
            val targetMembers = (target as? JsonObject)?.members ?: continue
            if ((targetMembers["kind"] as? JsonString)?.value != "memory") continue
            val targetScope = BotMemoryScope.parse((targetMembers["scope"] as? JsonString)?.value)
                ?: continue
            if (targetScope != BotMemoryScope.USER && erasingBot != effectiveBotId) continue
            val path = (targetMembers["path"] as? JsonString)?.value
            if (path != null) {
                removedPaths += path
            } else {
                scopeErases += targetScope
            }
        }
        for (path in removedPaths) {
            state.live.remove(path)
            state.versions.remove(path)
            state.latestVersion.remove(path)
        }
        for (targetScope in scopeErases) {
            val scoped = state.versions.filterValues { versions ->
                versions.values.any { it.scope == targetScope }
            }.keys.toList()
            for (path in scoped) {
                state.live.remove(path)
                state.versions.remove(path)
                state.latestVersion.remove(path)
            }
            state.legacyFacts.entries.removeAll { it.value.scope == targetScope }
        }
        val factIds = (members["legacyFactIDs"] as? JsonArray)?.values
            ?.mapNotNull { (it as? JsonString)?.value } ?: emptyList()
        for (factId in factIds) state.legacyFacts.remove(factId)
        val visible = state.live.keys.toSet()
        state.order.removeAll { it !in visible }
        state.legacyOrder.removeAll { state.legacyFacts[it] == null }
    }

    private fun recordSkipped(event: BotEvent) {
        if (event.eventId in skippedEventIds) return
        skippedEventIds += event.eventId
        while (skippedEventIds.size > MAXIMUM_SKIPPED_EVENT_IDS) {
            skippedEventIds.removeAt(0)
        }
    }

    // ------------------------------------------------------------------
    // event construction and commit
    // ------------------------------------------------------------------

    private fun writtenEvent(
        document: BotMemoryDocument,
        expectedVersion: Int,
        correlationId: String?,
    ): BotEvent {
        val payload = WrittenPayload(
            path = document.path,
            scope = document.scope,
            content = document.content,
            version = document.version,
            expectedVersion = expectedVersion,
            updatedAtMs = document.updatedAtMs,
            author = document.author,
            evidence = document.evidence,
            trust = document.trust,
            source = document.source,
        )
        val eventId = stableEventId(
            WRITTEN_EVENT_PREFIX,
            listOf(
                document.path, scopedBotId(botId) ?: "-", document.version.toString(),
                digest(document.content), expectedVersion.toString(),
                document.updatedAtMs.toString(),
            ),
        )
        return makeEvent(
            type = "memory.document_written",
            eventId = eventId,
            data = payload.toJson(),
            at = document.updatedAtMs,
            author = document.author,
            source = document.source,
            correlationId = correlationId,
        )
    }

    private fun deletionEvent(
        version: BotMemoryDocumentVersion,
        expectedVersion: Int,
        correlationId: String?,
    ): BotEvent {
        val payload = DeletedPayload(
            path = version.path,
            scope = version.scope,
            version = version.version,
            expectedVersion = expectedVersion,
            at = version.updatedAtMs,
            reason = version.deletionReason ?: "forget",
            author = version.author,
            evidence = version.evidence,
            trust = version.trust,
        )
        val eventId = stableEventId(
            DELETED_EVENT_PREFIX,
            listOf(
                version.path, scopedBotId(botId) ?: "-", version.version.toString(),
                expectedVersion.toString(), version.updatedAtMs.toString(),
                version.deletionReason ?: "",
            ),
        )
        return makeEvent(
            type = "memory.document_deleted",
            eventId = eventId,
            data = payload.toJson(),
            at = version.updatedAtMs,
            author = version.author,
            source = null,
            correlationId = correlationId,
        )
    }

    private fun makeEvent(
        type: String,
        eventId: String,
        data: JsonValue,
        at: Long,
        author: BotMemoryAuthor,
        source: BotMemorySource?,
        correlationId: String?,
    ): BotEvent = BotEvent(
        schemaVersion = 1,
        type = type,
        eventId = eventId,
        commitSeq = null,
        time = maxOf(0, at),
        origin = BotEventOrigin.Local("memory-service"),
        traceId = "trace-$eventId",
        principal = BotPrincipal(
            botId = author.botId,
            sessionId = author.sessionId,
            kind = author.kind.principalKind,
            capabilities = emptyList(),
        ),
        causationId = null,
        correlationId = correlationId,
        turnId = source?.turnId?.takeIf { it.isNotEmpty() },
        data = data,
    )

    private fun commit(events: List<BotEvent>) {
        if (events.isEmpty()) return
        if (inWriteTransaction) {
            val prepared = if (events.size == 1) {
                events
            } else {
                val batchId = "batch:" + UUID.randomUUID().toString().lowercase()
                events.mapIndexed { index, event ->
                    event.withBatch(BotEventBatch(batchId, index, events.size))
                }
            }
            for (event in prepared) eventLog.appendWithinTransaction(event)
            verifyCommitted(prepared)
            return
        }
        try {
            if (events.size == 1) {
                eventLog.append(events[0])
            } else {
                eventLog.appendBatch(events)
            }
        } catch (error: Throwable) {
            if (committedEventsMatch(events)) return
            throw error
        }
        verifyCommitted(events)
    }

    private fun verifyCommitted(events: List<BotEvent>) {
        for (event in events) {
            val persisted = eventLog.event(event.eventId)
                ?: throw BotMemoryStoreException(
                    "corrupted", "committed memory event is missing: ${event.eventId}",
                )
            if (persisted.type != event.type || persisted.data != event.data) {
                throw BotMemoryStoreException(
                    "corrupted", "committed memory event payload mismatch: ${event.eventId}",
                )
            }
        }
    }

    private fun committedEventsMatch(events: List<BotEvent>): Boolean {
        for (event in events) {
            val persisted = eventLog.event(event.eventId) ?: return false
            if (persisted.type != event.type || persisted.data != event.data) return false
        }
        return true
    }

    // ------------------------------------------------------------------
    // payload decoding
    // ------------------------------------------------------------------

    private fun decodeWritten(data: JsonObject): WrittenPayload {
        val members = data.members
        val path = requiredString(members, "path")
        if (BotMemoryPath.parse(path) == null) {
            throw BotJsonException("document.written path is invalid")
        }
        return WrittenPayload(
            path = path,
            scope = BotMemoryScope.parse((members["scope"] as? JsonString)?.value)
                ?: throw BotJsonException("document.written scope is invalid"),
            content = (members["content"] as? JsonString)?.value
                ?: throw BotJsonException("document.written content is missing"),
            version = requiredInt(members, "version"),
            expectedVersion = (members["expected_version"] as? JsonNumber)?.asLongOrNull()?.toInt() ?: 0,
            updatedAtMs = (members["updated_at_ms"] as? JsonNumber)?.asLongOrNull()
                ?: throw BotJsonException("document.written updated_at_ms is missing"),
            author = BotMemoryAuthor.fromJson(members["author"]),
            evidence = (members["evidence"] as? JsonArray)?.values
                ?.mapNotNull { (it as? JsonString)?.value } ?: emptyList(),
            trust = BotMemoryTrust.parse((members["trust"] as? JsonString)?.value),
            source = members["source"]?.let { BotMemorySource.fromJson(it) },
        )
    }

    private fun decodeDeleted(data: JsonObject): DeletedPayload {
        val members = data.members
        val path = requiredString(members, "path")
        if (BotMemoryPath.parse(path) == null) {
            throw BotJsonException("document.deleted path is invalid")
        }
        return DeletedPayload(
            path = path,
            scope = BotMemoryScope.parse((members["scope"] as? JsonString)?.value)
                ?: throw BotJsonException("document.deleted scope is invalid"),
            version = requiredInt(members, "version"),
            expectedVersion = (members["expected_version"] as? JsonNumber)?.asLongOrNull()?.toInt() ?: 0,
            at = (members["at"] as? JsonNumber)?.asLongOrNull() ?: 0,
            reason = (members["reason"] as? JsonString)?.value ?: "forget",
            author = BotMemoryAuthor.fromJson(members["author"]),
            evidence = (members["evidence"] as? JsonArray)?.values
                ?.mapNotNull { (it as? JsonString)?.value } ?: emptyList(),
            trust = BotMemoryTrust.parse((members["trust"] as? JsonString)?.value),
        )
    }

    private fun decodeForgotten(data: JsonObject): ForgottenPayload {
        val members = data.members
        val factId = (members["factId"] as? JsonString)?.value
            ?: (members["fact_id"] as? JsonString)?.value
            ?: throw BotJsonException("memory.forgotten factId is missing")
        val scope = BotMemoryScope.parse((members["scope"] as? JsonString)?.value)
            ?: throw BotJsonException("memory.forgotten scope is invalid")
        return ForgottenPayload(
            factId = factId,
            scope = scope,
            at = (members["at"] as? JsonNumber)?.asLongOrNull() ?: 0,
            reason = (members["reason"] as? JsonString)?.value ?: "forget",
        )
    }

    private fun allDurableEvents(): List<BotEvent> {
        val result = ArrayList<BotEvent>()
        var cursor = 0
        while (true) {
            val page = eventLog.events(cursor, 500)
            if (page.isEmpty()) return result
            result += page
            val last = page.last().commitSeq ?: return result
            cursor = last.toInt()
            if (page.size < 500) return result
        }
    }

    private fun belongsToThisBot(event: BotEvent, scope: BotMemoryScope): Boolean {
        if (scope == BotMemoryScope.USER) return true
        return normalizeBotId(event.principal.botId) == effectiveBotId
    }

    private fun readableText(value: JsonValue): String {
        val strings = ArrayList<String>()
        fun walk(current: JsonValue) {
            when (current) {
                is JsonString -> strings += current.value
                is JsonArray -> current.values.forEach(::walk)
                is JsonObject -> current.members.values.forEach(::walk)
                else -> Unit
            }
        }
        walk(value)
        // A NUL separator cannot be part of a memory needle, so a match can
        // never span two separate payload strings.
        return strings.joinToString("\u0000")
    }

    private fun collectRecordReferences(value: JsonValue): List<String> {
        val refs = ArrayList<String>()
        fun walk(current: JsonValue) {
            when (current) {
                is JsonString -> if (current.value.contains("record://")) refs += current.value
                is JsonArray -> current.values.forEach(::walk)
                is JsonObject -> current.members.values.forEach(::walk)
                else -> Unit
            }
        }
        walk(value)
        return refs
    }

    private fun requiredString(members: Map<String, JsonValue>, key: String): String =
        (members[key] as? JsonString)?.value
            ?: throw BotJsonException("memory event $key is missing")

    private fun requiredInt(members: Map<String, JsonValue>, key: String): Int {
        val value = (members[key] as? JsonNumber)?.asLongOrNull()
            ?: throw BotJsonException("memory event $key is missing")
        return value.toInt()
    }

    private fun occurrences(text: String, find: String): Int {
        var count = 0
        var index = 0
        while (true) {
            val at = text.indexOf(find, index)
            if (at < 0) return count
            count += 1
            index = at + find.length
        }
    }

    public companion object {
        /**
         * The usual `:app` wiring: one shared replay feed per P25 log, keyed
         * by the store's identity so a process scans the durable log once.
         */
        public fun forDomainStore(
            store: BotDomainStore,
            botId: String? = null,
            now: () -> Long = { System.currentTimeMillis() },
        ): BotSqlMemoryDocumentStore = BotSqlMemoryDocumentStore(
            eventLog = BotDomainMemoryEventLog(store),
            botId = botId,
            now = now,
            replayFeed = BotMemoryReplayFeedRegistry.feedFor(store),
        )

        private const val WRITTEN_EVENT_PREFIX = "evt-memory-document-written-"
        private const val DELETED_EVENT_PREFIX = "evt-memory-document-deleted-"
        private const val MAXIMUM_SKIPPED_EVENT_IDS = 256

        private fun normalizeBotId(value: String?): String =
            if (value.isNullOrEmpty()) "main" else value

        private fun scopedBotId(value: String?): String? =
            if (value.isNullOrEmpty() || value == "main") null else value

        private fun digest(text: String): String = sha256(text.toByteArray(Charsets.UTF_8))

        private fun stableEventId(prefix: String, components: List<String>): String =
            prefix + digest(components.joinToString("\u0000"))
    }
}
