// The chat transcript cache: what a cold start reopens.
// SPDX-License-Identifier: MIT
//
// ---- why this exists, and why it is not the journal -------------------------
// The authoritative record of a session is still the host WAL / journal, owned by
// `:dsh`. The journal names a session but does not expose its event text to this
// module (`JournalStore.records` is `internal`), and the app-level `SessionArchive`
// keeps only the settled tail's *kinds*, not the words. A cold start therefore had
// nothing to paint for the conversation the user just had: the turn state came back
// but the transcript did not.
//
// This store is the Android half of the iOS baseline's
// `transcript-snapshots/<sessionID>.json` (`ChatModel.swift:2512-2599`): the
// rendered node sequence of one conversation plus its title, so the screen can be
// painted before the Worker is up. It stores **the nodes the screen already drew**
// (`ui-state/1` via `:lib`'s canonical codec), not a second copy of the events, so
// restoring cannot disagree with what was on screen.
//
// The rows live in the same `session` domain as `SessionArchive`, under a `chat/`
// key prefix, so the one `DomainStore` remains the one product store and the
// existing quota applies unchanged. The `turn/` and `current` rows of
// `SessionArchive` are never touched: the two writers own disjoint key ranges.
//
// ---- failure model ---------------------------------------------------------
// A row that cannot be decoded is reported as absent, never as a half transcript;
// it is not deleted either (silent loss is what `budgets.md` §5 forbids).
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.domain.DomainNames
import com.phonedsh.domain.DomainStore
import com.phonedsh.domain.DomainTransaction
import com.phonedsh.ui.projection.UiStateNode
import com.phonedsh.ui.projection.decodeCanonicalUiState
import com.phonedsh.ui.projection.encodeCanonical
import com.phonedsh.ui.state.StateRequestId
import com.phonedsh.ui.state.StateRevision

/**
 * One conversation as this App knows it.
 *
 * @param id the App's stable chat id (`chat-<millis>-<n>`). It survives every
 *   process restart; the Worker's session id does not, which is why they are
 *   different values.
 * @param title the user's name for it; empty means 新会话 (the page's untitled word).
 * @param updatedAtMs the wall-clock instant of its last change, clamped
 *   monotonically for the list order (never the write-acceptance test).
 * @param workerSessionIds every Worker `session/create` id this conversation has
 *   used, oldest first. Each one is a journal row; keeping the list lets the
 *   session list claim them all so one conversation never lists twice. The last
 *   one is the id the next turn resumes (the Worker persists its session log in
 *   `/dsh/home/sessions`, so a cold start continues the same model history).
 * @param nodes the rendered `ui-state/1` sequence, in order.
 */
internal data class ChatRecord(
    val id: String,
    val title: String,
    val updatedAtMs: Long,
    val workerSessionIds: List<String>,
    val nodes: List<UiStateNode>,
    /** The real DSH working directory for this App-owned chat. */
    val workspaceID: String? = ChatSessionStore.DEFAULT_WORKSPACE_ID,
    /** Whether this chat is hidden in the recoverable archive section. */
    val archived: Boolean = false,
    /** Whether the user pinned this chat to the top of its group. */
    val pinned: Boolean = false,
    /** Monotonic store revision; zero denotes a caller-created value. */
    val revision: Long = 0L,
    /** A visible but non-actionable copy of outstanding remote requests. */
    /** Null means a legacy row did not report this state; empty is known-empty. */
    val pendingNodes: List<UiStateNode>? = null,
    /** Messages accepted by the UI but not yet sent to the Worker. */
    /** Null means the durable queue was not readable/reported. */
    val queuedPrompts: List<String>? = null,
    /** Stable workspace group id; null is explicitly unassigned/unknown. */
    val workspaceGroupId: String? = ChatSessionStore.DEFAULT_WORKSPACE_GROUP_ID,
    /** Forward-compatible envelope members preserved across metadata edits. */
    val unknownFields: Map<String, JsonValue> = emptyMap(),
) {
    /** The Worker session the next turn should try first, or `null` before the first. */
    val workerSessionId: String? get() = workerSessionIds.lastOrNull()
}

/** Outcome of a host-side durable chat mutation. */
internal sealed interface ChatWriteOutcome {
    data object Persisted : ChatWriteOutcome
    data object Stale : ChatWriteOutcome
    data class Failed(val code: String) : ChatWriteOutcome
}

/** Receipt is emitted only after the durable row can be read back. */
internal data class ChatWriteReceipt(
    val requestId: StateRequestId,
    val sessionId: String,
    val revision: StateRevision,
    val outcome: ChatWriteOutcome,
)

/** A user-named workspace group; deleting a group never deletes chat rows. */
internal data class ChatWorkspaceGroup(val id: String, val name: String, val revision: Long = 0L)

/** Unknown and deleted group references stay explicit in every caller. */
internal fun workspaceGroupTitle(record: ChatRecord, groups: Collection<ChatWorkspaceGroup>): String =
    record.workspaceGroupId?.let { id -> groups.firstOrNull { it.id == id }?.name } ?: "未分配"

/** Uses the persisted selection when it is active; otherwise falls back to newest active. */
internal fun selectRestoredChatSession(records: List<ChatRecord>, preferredId: String?): ChatRecord? =
    records.firstOrNull { it.id == preferredId && !it.archived }
        ?: records.firstOrNull { !it.archived }

/**
 * The two-way store over [DomainStore]'s `session` domain.
 *
 * Every method is synchronous and touches disk: callers must not run them on the
 * Android main thread (`DomainStore`'s threading rule).
 */
internal class ChatSessionStore(private val store: DomainStore) {
    /** The last selected non-device session, equivalent to iOS currentSessionDefaultsKey. */
    fun currentSessionId(): String? = store.get(DOMAIN, CURRENT_SESSION_ID_KEY)
        ?.toString(Charsets.UTF_8)
        ?.takeIf(String::isNotBlank)

    /**
     * Updates transcript content without replacing the latest row's metadata envelope.
     *
     * The row revision is the concurrency authority; the wall clock is only the
     * list-order hint, so an older [updatedAtMs] is clamped instead of refusing
     * content written before a clock rollback.
     */
    fun updateContent(
        id: String,
        title: String,
        updatedAtMs: Long,
        workerSessionIds: List<String>,
        nodes: List<UiStateNode>,
        requestId: StateRequestId,
        expectedRevision: StateRevision? = null,
    ): ChatWriteReceipt = mutate(requestId, id, expectedRevision) { current ->
        current.copy(
            title = title,
            updatedAtMs = maxOf(updatedAtMs, current.updatedAtMs),
            workerSessionIds = workerSessionIds.distinct(),
            nodes = nodes,
        )
    }

    /** Persists selection only for an existing active row and reads the key back. */
    fun selectCurrentSession(
        id: String,
        requestId: StateRequestId,
        expectedCurrentId: String? = currentSessionId(),
    ): ChatWriteReceipt {
        val revision = try {
            store.transaction {
                val currentId = get(DOMAIN, CURRENT_SESSION_ID_KEY)?.toString(Charsets.UTF_8)
                if (currentId != expectedCurrentId) return@transaction -1L
                val record = get(DOMAIN, key(id))?.toString(Charsets.UTF_8)?.let(::decodeOrNull)
                    ?: return@transaction null
                if (record.archived) return@transaction null
                put(DOMAIN, CURRENT_SESSION_ID_KEY, id.toByteArray(Charsets.UTF_8))
                check(get(DOMAIN, CURRENT_SESSION_ID_KEY)?.toString(Charsets.UTF_8) == id) {
                    "current chat selection readback mismatch"
                }
                record.revision
            }
        } catch (failure: Exception) {
            return ChatWriteReceipt(requestId, id, StateRevision(0), ChatWriteOutcome.Failed(failure.javaClass.simpleName))
        }
        return if (revision == -1L) {
            ChatWriteReceipt(requestId, id, StateRevision(0), ChatWriteOutcome.Stale)
        } else if (revision == null) {
            ChatWriteReceipt(requestId, id, StateRevision(0), ChatWriteOutcome.Failed("session_unavailable"))
        } else {
            ChatWriteReceipt(requestId, id, StateRevision(revision), ChatWriteOutcome.Persisted)
        }
    }

    /** Clears only the selected row the caller observed, then confirms the key is absent. */
    fun clearCurrentSession(expectedId: String, requestId: StateRequestId): ChatWriteReceipt {
        val revision = try {
            store.transaction {
                val current = get(DOMAIN, CURRENT_SESSION_ID_KEY)?.toString(Charsets.UTF_8)
                if (current != expectedId) return@transaction null
                delete(DOMAIN, CURRENT_SESSION_ID_KEY)
                check(get(DOMAIN, CURRENT_SESSION_ID_KEY) == null) { "current chat selection clear mismatch" }
                get(DOMAIN, key(expectedId))?.toString(Charsets.UTF_8)?.let(::decodeOrNull)?.revision ?: 0L
            }
        } catch (failure: Exception) {
            return ChatWriteReceipt(requestId, expectedId, StateRevision(0), ChatWriteOutcome.Failed(failure.javaClass.simpleName))
        }
        return if (revision == null) {
            ChatWriteReceipt(requestId, expectedId, StateRevision(0), ChatWriteOutcome.Stale)
        } else {
            ChatWriteReceipt(requestId, expectedId, StateRevision(revision), ChatWriteOutcome.Persisted)
        }
    }

    /**
     * Writes [record], replacing the row of the same id.
     *
     * A replacement is ordered by [ChatRecord.revision], not by the wall clock;
     * [ChatRecord.updatedAtMs] is clamped so display order cannot regress.
     */
    fun save(record: ChatRecord) {
        store.transaction {
            val latest = get(DOMAIN, key(record.id))?.toString(Charsets.UTF_8)?.let(::decodeOrNull)
            val changed = record.copy(
                updatedAtMs = maxOf(record.updatedAtMs, latest?.updatedAtMs ?: record.updatedAtMs),
                revision = (latest?.revision ?: 0L) + 1L,
            )
            put(DOMAIN, key(record.id), encode(changed).toByteArray(Charsets.UTF_8))
            check(get(DOMAIN, key(record.id))?.toString(Charsets.UTF_8)?.let(::decodeOrNull) == changed) {
                "chat row readback differed after write"
            }
            changed
        }
    }

    /**
     * Applies a metadata command against the current stored row in one store
     * transaction. The returned receipt names the committed revision; a missing
     * row, conflict or storage exception cannot be reported as success.
     */
    fun mutate(
        requestId: StateRequestId,
        sessionId: String,
        expectedRevision: StateRevision? = null,
        transform: (ChatRecord) -> ChatRecord,
    ): ChatWriteReceipt {
        require(requestId.value.isNotBlank())
        require(sessionId.isNotBlank())
        return try {
            val revision = store.transaction {
                val raw = get(DOMAIN, key(sessionId)) ?: return@transaction null
                val before = decodeOrNull(raw.toString(Charsets.UTF_8)) ?: return@transaction null
                if (expectedRevision != null && before.revision != expectedRevision.value) return@transaction -1L
                val changed = transform(before).copy(revision = before.revision + 1L)
                put(DOMAIN, key(sessionId), encode(changed).toByteArray(Charsets.UTF_8))
                val readBack = get(DOMAIN, key(sessionId))?.toString(Charsets.UTF_8)?.let(::decodeOrNull)
                if (readBack != changed) throw IllegalStateException("chat mutation readback mismatch")
                changed.revision
            }
            if (revision == null) ChatWriteReceipt(requestId, sessionId, StateRevision(0), ChatWriteOutcome.Failed("session_not_found"))
            else if (revision == -1L) ChatWriteReceipt(requestId, sessionId, expectedRevision ?: StateRevision(0), ChatWriteOutcome.Stale)
            else ChatWriteReceipt(requestId, sessionId, StateRevision(revision), ChatWriteOutcome.Persisted)
        } catch (failure: Exception) {
            ChatWriteReceipt(requestId, sessionId, StateRevision(0), ChatWriteOutcome.Failed(failure.javaClass.simpleName))
        }
    }

    /** Loads one record, or `null` when it is absent or does not decode. */
    fun load(id: String): ChatRecord? = decodeOrNull(
        store.get(DOMAIN, key(id))?.toString(Charsets.UTF_8),
    )

    /** Every decodable record, newest first. */
    fun loadAll(): List<ChatRecord> {
        if (store.usageBytes(DOMAIN) == 0L) return emptyList()
        return store.list(DOMAIN, PREFIX, MAXIMUM_RECORDS)
            .mapNotNull { entry -> decodeOrNull(entry.value.toString(Charsets.UTF_8)) }
            .sortedByDescending { it.updatedAtMs }
    }

    /** Updates a stored chat's archive bit without replacing transcript content. */
    fun setArchived(id: String, archived: Boolean): Boolean =
        mutate(StateRequestId("archive:$id:${if (archived) 1 else 0}"), id) { record -> record.copy(archived = archived) }
            .outcome.let { it is ChatWriteOutcome.Persisted }

    /** Updates a stored chat's pin bit without replacing transcript content. */
    fun setPinned(id: String, pinned: Boolean): Boolean =
        mutate(StateRequestId("pin:$id:${if (pinned) 1 else 0}"), id) { record -> record.copy(pinned = pinned) }
            .outcome.let { it is ChatWriteOutcome.Persisted }

    /** Removes one record; `true` when a row existed. */
    fun delete(id: String): Boolean = store.delete(DOMAIN, key(id))

    fun rename(id: String, title: String, requestId: StateRequestId, expectedRevision: StateRevision? = null): ChatWriteReceipt =
        mutate(requestId, id, expectedRevision) { it.copy(title = title.trim()) }

    fun setArchived(id: String, archived: Boolean, requestId: StateRequestId): ChatWriteReceipt =
        mutate(requestId, id) { it.copy(archived = archived) }

    fun setPinned(id: String, pinned: Boolean, requestId: StateRequestId): ChatWriteReceipt =
        mutate(requestId, id) { it.copy(pinned = pinned) }

    fun putWorkspaceGroup(
        group: ChatWorkspaceGroup,
        requestId: StateRequestId,
        expectedRevision: StateRevision? = null,
    ): ChatWriteReceipt {
        require(group.id.isNotBlank() && group.name.isNotBlank())
        val revision = try {
            store.transaction {
                val key = groupKey(group.id)
                if (expectedRevision != null && workspaceGroupRevision(this) != expectedRevision.value) return@transaction -1L
                val next = group.copy(revision = nextWorkspaceGroupRevision(this))
                put(DOMAIN, key, encodeGroup(next).toByteArray(Charsets.UTF_8))
                check(get(DOMAIN, key)?.toString(Charsets.UTF_8)?.let(::decodeGroup) == next)
                workspaceGroupRevision(this)
            }
        } catch (failure: Exception) {
            return ChatWriteReceipt(requestId, group.id, StateRevision(0), ChatWriteOutcome.Failed(failure.javaClass.simpleName))
        }
        if (revision == -1L) return ChatWriteReceipt(requestId, group.id, expectedRevision ?: StateRevision(0), ChatWriteOutcome.Stale)
        return ChatWriteReceipt(requestId, group.id, StateRevision(revision), ChatWriteOutcome.Persisted)
    }

    fun deleteWorkspaceGroup(
        id: String,
        requestId: StateRequestId,
        expectedRevision: StateRevision? = null,
    ): ChatWriteReceipt {
        val revision = try {
            store.transaction {
                val key = groupKey(id)
                val currentRevision = workspaceGroupRevision(this)
                if (expectedRevision != null && currentRevision != expectedRevision.value) return@transaction -1L
                if (get(DOMAIN, key) == null) return@transaction null
                check(delete(DOMAIN, key)) { "workspace group disappeared during delete" }
                val nextRevision = nextWorkspaceGroupRevision(this)
                check(get(DOMAIN, key) == null) { "workspace group delete readback mismatch" }
                nextRevision
            }
        } catch (failure: Exception) {
            return ChatWriteReceipt(requestId, id, StateRevision(0), ChatWriteOutcome.Failed(failure.javaClass.simpleName))
        }
        if (revision == -1L) return ChatWriteReceipt(requestId, id, expectedRevision ?: StateRevision(0), ChatWriteOutcome.Stale)
        return if (revision == null) {
            ChatWriteReceipt(requestId, id, workspaceGroupsRevision(), ChatWriteOutcome.Failed("group_not_found"))
        } else {
            ChatWriteReceipt(requestId, id, StateRevision(revision), ChatWriteOutcome.Persisted)
        }
    }

    fun loadWorkspaceGroups(): List<ChatWorkspaceGroup> =
        store.list(DOMAIN, GROUP_PREFIX, MAXIMUM_RECORDS).mapNotNull { decodeGroup(it.value.toString(Charsets.UTF_8)) }

    /** Monotonic revision for the full workspace-group catalog, including deletes. */
    fun workspaceGroupsRevision(): StateRevision = StateRevision(
        store.get(DOMAIN, GROUP_REVISION_KEY)?.toString(Charsets.UTF_8)?.toLongOrNull() ?: 0L,
    )

    /** Seed the visible 日常 group only on an actually empty group store. */
    fun ensureDefaultWorkspaceGroup(requestId: StateRequestId): ChatWriteReceipt {
        return try {
            val revision = store.transaction {
                val key = groupKey(DEFAULT_WORKSPACE_GROUP_ID)
                val existing = get(DOMAIN, key)?.toString(Charsets.UTF_8)?.let(::decodeGroup)
                if (existing != null) return@transaction workspaceGroupRevision(this)
                val created = ChatWorkspaceGroup(DEFAULT_WORKSPACE_GROUP_ID, DEFAULT_WORKSPACE_GROUP_NAME,
                    nextWorkspaceGroupRevision(this))
                put(DOMAIN, key, encodeGroup(created).toByteArray(Charsets.UTF_8))
                check(get(DOMAIN, key)?.toString(Charsets.UTF_8)?.let(::decodeGroup) == created)
                workspaceGroupRevision(this)
            }
            ChatWriteReceipt(requestId, DEFAULT_WORKSPACE_GROUP_ID, StateRevision(revision), ChatWriteOutcome.Persisted)
        } catch (failure: Exception) {
            ChatWriteReceipt(requestId, DEFAULT_WORKSPACE_GROUP_ID, StateRevision(0), ChatWriteOutcome.Failed(failure.javaClass.simpleName))
        }
    }

    private fun nextWorkspaceGroupRevision(tx: DomainTransaction): Long {
        val next = workspaceGroupRevision(tx) + 1L
        tx.put(DOMAIN, GROUP_REVISION_KEY, next.toString().toByteArray(Charsets.UTF_8))
        check(workspaceGroupRevision(tx) == next) { "workspace group revision readback mismatch" }
        return next
    }

    private fun workspaceGroupRevision(tx: DomainTransaction): Long =
        tx.get(DOMAIN, GROUP_REVISION_KEY)?.toString(Charsets.UTF_8)?.toLongOrNull() ?: 0L

    private fun key(id: String): String = PREFIX + id

    private fun encode(record: ChatRecord): String = JsonObject(
        linkedMapOf(
            "schema" to JsonString(SCHEMA),
            "id" to JsonString(record.id),
            "title" to JsonString(record.title),
            "updatedAtMs" to JsonNumber(record.updatedAtMs.toString()),
            "workerSessionIds" to JsonArray(
                record.workerSessionIds.map { JsonString(it) },
            ),
            "workspaceID" to (record.workspaceID?.let(::JsonString) ?: JsonNull),
            "archived" to JsonBool(record.archived),
            "pinned" to JsonBool(record.pinned),
            "revision" to JsonNumber(record.revision.toString()),
            "workspaceGroupId" to (record.workspaceGroupId?.let(::JsonString) ?: JsonNull),
            // The node sequence is the `ui-state/1` canonical JSONL `:lib` writes,
            // carried as one string member so this envelope never re-implements the
            // node schema.
            "nodes" to JsonString(record.nodes.encodeCanonical()),
        ).apply {
            record.pendingNodes?.let { put("pendingNodes", JsonString(it.encodeCanonical())) }
            record.queuedPrompts?.let { put("queuedPrompts", JsonArray(it.map(::JsonString))) }
            record.unknownFields.forEach { (name, value) -> if (name !in this) put(name, value) }
        },
    ).toJsonString()

    private fun decodeOrNull(text: String?): ChatRecord? {
        if (text.isNullOrBlank()) return null
        return try {
            val root = JsonValue.parse(text) as? JsonObject ?: return null
            if ((root["schema"] as? JsonString)?.value != SCHEMA) return null
            val id = (root["id"] as? JsonString)?.value ?: return null
            if (id.isBlank()) return null
            val nodes = decodeCanonicalUiState((root["nodes"] as? JsonString)?.value.orEmpty())
            ChatRecord(
                id = id,
                title = (root["title"] as? JsonString)?.value.orEmpty(),
                updatedAtMs = (root["updatedAtMs"] as? JsonNumber)?.asLongOrNull() ?: 0L,
                workerSessionIds = (root["workerSessionIds"] as? JsonArray)
                    ?.values
                    ?.mapNotNull { (it as? JsonString)?.value }
                    .orEmpty(),
                nodes = nodes,
                // Older chat snapshots predate these optional fields. Every
                // chat/ row was created by this host in /dsh/workspace, so the
                // persisted cwd is a safe backward-compatible default.
                workspaceID = (root["workspaceID"] as? JsonString)?.value
                    ?: DEFAULT_WORKSPACE_ID,
                archived = (root["archived"] as? JsonBool)?.value ?: false,
                pinned = (root["pinned"] as? JsonBool)?.value ?: false,
                revision = (root["revision"] as? JsonNumber)?.asLongOrNull() ?: 0L,
                pendingNodes = (root["pendingNodes"] as? JsonString)?.value?.let(::decodeCanonicalUiState),
                queuedPrompts = (root["queuedPrompts"] as? JsonArray)?.values?.mapNotNull { (it as? JsonString)?.value },
                workspaceGroupId = (root["workspaceGroupId"] as? JsonString)?.value,
                unknownFields = root.members.filterKeys { it !in KNOWN_CHAT_FIELDS },
            )
        } catch (_: Exception) {
            // A damaged row is reported as absent; the next save for that chat
            // replaces it. Nothing is deleted on this path.
            null
        }
    }

    private fun groupKey(id: String): String = GROUP_PREFIX + id

    private fun encodeGroup(group: ChatWorkspaceGroup): String = JsonObject(mapOf(
        "schema" to JsonString(GROUP_SCHEMA), "id" to JsonString(group.id),
        "name" to JsonString(group.name), "revision" to JsonNumber(group.revision.toString()),
    )).toJsonString()

    private fun decodeGroup(text: String): ChatWorkspaceGroup? = runCatching {
        val root = JsonValue.parse(text) as? JsonObject ?: return null
        if ((root["schema"] as? JsonString)?.value != GROUP_SCHEMA) return null
        val id = (root["id"] as? JsonString)?.value ?: return null
        val name = (root["name"] as? JsonString)?.value ?: return null
        ChatWorkspaceGroup(id, name, (root["revision"] as? JsonNumber)?.asLongOrNull() ?: 0L)
    }.getOrNull()

    companion object {
        /** The domain `SessionArchive` also uses; this store owns the `chat/` range. */
        const val DOMAIN: String = DomainNames.SESSION

        /** Key prefix of one chat row. */
        const val PREFIX: String = "chat/"
        const val GROUP_PREFIX: String = "workspace-group/"
        const val GROUP_SCHEMA: String = "pdsh-workspace-group/1"
        const val GROUP_REVISION_KEY: String = "workspace-group-meta/revision"
        /** Mirrors iOS `ChatModel.currentSessionDefaultsKey`. */
        const val CURRENT_SESSION_ID_KEY: String = "chat.dsh.currentSessionID"

        /** The envelope version this reader accepts. */
        const val SCHEMA: String = "pdsh-chat-session/1"

        /** A read bound, not a retention policy (the domain quota is the bound). */
        const val MAXIMUM_RECORDS: Int = 1000

        /** The cwd all App-created chats pass to the DSH worker. */
        const val DEFAULT_WORKSPACE_ID: String = "/dsh/workspace"
        const val DEFAULT_WORKSPACE_GROUP_ID: String = "daily"
        const val DEFAULT_WORKSPACE_GROUP_NAME: String = "日常"
        val KNOWN_CHAT_FIELDS: Set<String> = setOf(
            "schema", "id", "title", "updatedAtMs", "workerSessionIds", "workspaceID",
            "archived", "pinned", "nodes", "revision", "pendingNodes", "queuedPrompts", "workspaceGroupId",
        )
    }
}
