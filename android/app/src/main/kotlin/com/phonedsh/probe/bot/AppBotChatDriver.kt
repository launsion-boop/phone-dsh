// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.attachments.BotAttachment
import com.phonedsh.bot.attachments.BotAttachmentPrompt
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.projection.BotProjectionEvent
import com.phonedsh.bot.projection.BotRowHistory
import com.phonedsh.bot.projection.BotRowPaging
import com.phonedsh.bot.projection.BotSessionEpochProjection
import com.phonedsh.bot.projection.BotSessionLogRecord
import com.phonedsh.bot.projection.BotSurfaceOp
import com.phonedsh.bot.rows.BotActionResult
import com.phonedsh.bot.rows.BotRowBatch
import com.phonedsh.bot.rows.BotUserAction
import com.phonedsh.bot.rows.BotUserActionKind
import com.phonedsh.bot.rows.BotUserActionValidation
import com.phonedsh.bot.session.BotSessionException
import com.phonedsh.bot.session.BotSessionKind
import com.phonedsh.bot.session.BotSessionLifecycleEvent
import com.phonedsh.bot.session.BotSessionLiveFrame
import com.phonedsh.bot.session.BotSessionPrincipal
import com.phonedsh.bot.session.BotSessionRemoteException
import com.phonedsh.bot.session.BotSessionRuntime
import com.phonedsh.bot.session.BotSessionStoredEvent
import com.phonedsh.bot.session.BotSessionTokenRegistry
import com.phonedsh.bot.session.BotSessionTransport
import com.phonedsh.bot.session.BotSessionWorkspace
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.BotEffectOutbox
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventCodec
import com.phonedsh.bot.store.BotEventOrigin
import com.phonedsh.bot.store.BotPrincipal
import com.phonedsh.bot.store.BotUserActionPlan
import com.phonedsh.bot.store.BotUserActionTransaction
import com.phonedsh.ui.bot.driver.BotChatDriver
import com.phonedsh.ui.bot.driver.BotLiveFrame
import com.phonedsh.ui.bot.driver.BotTurnProcess
import com.phonedsh.ui.bot.state.BotActivity
import com.phonedsh.ui.bot.state.BotActivityCategory
import com.phonedsh.ui.bot.state.BotActivityStatus
import com.phonedsh.ui.bot.state.BotRuntimePresentation
import com.phonedsh.ui.bot.state.BotUIHistoryPage
import java.nio.file.Path
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The App's rich [BotChatDriver] over the real P25 store and the P27
 * [BotSessionRuntime].
 *
 * Data flow (one direction only):
 *
 *   BotSessionTransport ──live frames──> records ──projector──> BotRowHistory
 *          │                               ▲                        │
 *          └── session/prompt/cancel ──────┘                        ├─ watch/history
 *   BotUserActionTransaction ──events──> BotDomainStore ────────────┘
 *
 * The runtime owns the DSH lifecycle; this class owns the row projection and
 * the P27 result vocabulary. It performs no network work on the caller's
 * thread: [perform] commits the local action and then starts the turn on the
 * driver scope, so the optimistic row and the durable event are visible even
 * while a Worker is still booting.
 *
 * History survives a force-stop because two independent durable sources are
 * read on reopen:
 *
 * 1. `runtime.started` / `runtime.exited` are written through to the P25 store
 *    ([onDurableLifecycle]); the epoch chain comes from those events
 *    (`session-lifecycle.md` §4/§7), not from process memory.
 * 2. Each epoch's DSH journal is read from the materialized session JSONL,
 *    with Worker history as a fallback ([BotSessionHistoryReader],
 *    `session-lifecycle.md` §7). The Swift host reads the same journal format.
 *
 * A pre-fix install has a Worker session (`gb-<botId>`) but no persisted
 * lifecycle. [discoverLegacySessions] reads `session/list` once and projects
 * those journals too, so old conversations are recovered without deleting or
 * rewriting Bot data. The projection deduplicates live records against the
 * journal by event id, DSH seq and user-action nonce, so a live turn never
 * appears twice after a rebuild.
 *
 * [storeLock] is the serialization seam for more than one Bot driver sharing
 * one [BotDomainStore] (one SQLite connection): every store read/write in this
 * class happens inside `synchronized(storeLock)`. A single-Bot composition may
 * omit it; a multi-Bot composition MUST pass the same lock object to every
 * driver that shares the store.
 *
 * [transport] is a real host adapter in the App and a fake/local adapter in
 * tests. This class never invents a successful assistant reply: if the
 * transport fails, a durable `ui.notice` row carries the failure.
 */
class AppBotChatDriver(
    private val store: BotDomainStore,
    private val transport: BotSessionTransport,
    private val botId: String = "main",
    private val scope: CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val tokens: BotSessionTokenRegistry = BotSessionTokenRegistry(now = clock),
    seedRecords: List<BotSessionLogRecord> = emptyList(),
    /**
     * Shared serialization object for every driver over the same store. The
     * default is private to this driver; pass the same instance to every
     * driver that shares [store].
     */
    private val storeLock: Any = Any(),
    private val resolveApproval: ((com.phonedsh.bot.rows.BotUserAction) -> BotActionResult)? = null,
    private val onTurnBoundary: (String, Boolean) -> Unit = { _, _ -> },
    materializedSessions: Path? = null,
) : BotChatDriver, AutoCloseable {
    private val lock = Any()
    private val history = BotRowHistory()

    /** Durable lifecycle seeded from the store before the runtime starts. */
    private val seedLifecycle: List<BotSessionStoredEvent> =
        seedLifecycleEvents(store, botId, storeLock)

    /** Ordered epoch chain (`session-lifecycle.md` §7); guarded by [lock]. */
    private val epochOrder = ArrayList<String>()
    private val recordsBySession = LinkedHashMap<String, MutableList<BotSessionLogRecord>>()
    private val loadedSessions = HashSet<String>()

    /** Records written before the runtime has chosen its main session. */
    private val pendingRecords = ArrayList<BotSessionLogRecord>(seedRecords)
    @Volatile
    private var legacyDiscoveryDone = false
    private val historyLoadRunning = AtomicBoolean(false)
    private val historyLoadRequested = AtomicBoolean(false)
    private val historyReader = BotSessionHistoryReader(transport, materializedSessions = materializedSessions)

    private val revision = MutableStateFlow(0L)
    private val presentationState = MutableStateFlow(BotRuntimePresentation())
    private val liveFrames = MutableSharedFlow<BotLiveFrame>(
        extraBufferCapacity = 512,
        onBufferOverflow = kotlinx.coroutines.channels.BufferOverflow.DROP_OLDEST,
    )
    private val closed = AtomicBoolean(false)
    private val outbox = BotEffectOutbox(store)
    private val actions = BotUserActionTransaction(store, outbox)
    private var activeTurnId: String? = null
    private var activity: BotActivity? = null
    // Local rows use a sequence domain far above DSH journal seqs: a live
    // optimistic row must never lose to an unrelated journal record merely
    // because their small integers happen to be equal before the journal has
    // committed the same message.
    private var localSeq: Long = maxOf(
        (seedRecords.maxOfOrNull { it.seq } ?: 0L) + 1L,
        LOCAL_SEQ_BASE,
    )
    private val started = AtomicBoolean(false)

    private val runtime: BotSessionRuntime = BotSessionRuntime(
        transport = transport,
        botId = botId,
        tokens = tokens,
        now = clock,
        onSessionRegistered = { sessionId ->
            synchronized(lock) {
                ensureSessionLocked(sessionId)
                bumpLocked()
            }
        },
        onLifecycleEvent = ::onDurableLifecycle,
        seedEvents = seedLifecycle,
    )

    private val liveToken: Long = runtime.subscribeLiveFrames(::onRuntimeFrame)

    init {
        synchronized(lock) {
            for (event in seedLifecycle) {
                lifecycleSessionId(event.data, event.principal.sessionId)?.let(::ensureSessionLocked)
            }
            rebuildLocked()
        }
    }

    override suspend fun history(before: String?, limit: Int): BotUIHistoryPage =
        withContext(Dispatchers.IO) {
            requestHistoryLoad()
            val snapshot = synchronized(lock) {
                rebuildLocked()
                BotRowPaging.page(history.history(), before = before, limit = limit)
            }
            BotUIHistoryPage(
                rows = snapshot.rows,
                nextCursor = snapshot.nextCursor,
                hasMore = snapshot.hasMore,
            )
        }

    override fun watch(cursor: Long): Flow<BotRowBatch> = flow {
        requestHistoryLoad()
        var current = cursor
        var seen = revision.value
        while (coroutineContext.isActive && !closed.get()) {
            val batch = synchronized(lock) {
                rebuildLocked()
                history.watch(current)
            }
            current = batch.cursor
            emit(batch)
            if (closed.get()) break
            revision.first { it != seen }
            seen = revision.value
        }
    }

    override suspend fun perform(action: BotUserAction): BotActionResult =
        withContext(Dispatchers.IO) {
            BotUserActionValidation.validate(action)?.let { return@withContext it }
            if (action.kind == BotUserActionKind.APPROVAL && resolveApproval != null) {
                return@withContext resolveApproval.invoke(action)
            }
            val plan = newPlanEvent(action)
            val result = try {
                synchronized(storeLock) {
                    actions.performAndRecord(action, BotUserActionPlan(event = plan))
                }
            } catch (error: Exception) {
                return@withContext BotActionResult.Rejected(
                    error.message ?: "action could not be recorded",
                )
            }
            if (result is BotActionResult.Accepted) {
                synchronized(lock) {
                    if (action.kind == BotUserActionKind.CHAT) {
                        addRecordLocked(userRecord(action, result.eventID, nextSeqLocked()))
                    }
                    bumpLocked()
                }
                if (action.kind == BotUserActionKind.CHAT) {
                    startChatTurn(action)
                }
            }
            result
        }

    internal fun domainChanged() {
        synchronized(lock) { bumpLocked() }
    }

    override suspend fun stopCurrentTurn(turnID: String?) {
        if (runtime.mainSessionIdentifier() == null && activeTurnId == null) return
        withContext(Dispatchers.IO) {
            try {
                // BotChatModel's presentation uses `turn-<n>` (the live event's
                // display id); the P27 runtime's DSH turn id is the bare value.
                runtime.stopMainTurn(turnID?.removePrefix("turn-"))
            } catch (error: BotSessionException) {
                // No live turn is already stopped by definition; a stale id is
                // the caller's race with turn/end, not a driver failure.
                if (!error.message.orEmpty().contains("stale_turn")) throw error
            } catch (error: BotSessionRemoteException) {
                throw error
            } catch (_: Exception) {
                // The connection may already be gone; turn/end (if any) still
                // arrives as a live frame and clears the presentation.
            }
        }
    }

    override suspend fun turnProcesses(): Map<Int, BotTurnProcess> =
        synchronized(lock) {
            rebuildLocked()
            buildProcesses(currentRecordsLocked())
        }

    override fun liveFrames(): Flow<BotLiveFrame> = liveFrames

    override fun presentation(): Flow<BotRuntimePresentation> = presentationState.asStateFlow()

    /** Test/diagnostic hook: waits until the first session exists. */
    suspend fun startMainSession(): String = withContext(Dispatchers.IO) {
        runtime.startMainSession()
    }

    /** The durable main-session id, or null before the first turn. */
    fun mainSessionId(): String? = runtime.mainSessionIdentifier()

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        runtime.unsubscribeLiveFrames(liveToken)
        scope.cancel()
    }

    // ------------------------------------------------------------ lifecycle

    /**
     * The one durable sink for `runtime.started` / `runtime.exited`
     * (`session-lifecycle.md` §4). The store append happens before the runtime
     * treats the event as committed; a failure propagates to the turn caller.
     */
    private fun onDurableLifecycle(event: BotSessionLifecycleEvent) {
        val stored = BotEvent(
            schemaVersion = BotEventCodec.CURRENT_SCHEMA_VERSION,
            type = event.type,
            eventId = event.eventId,
            commitSeq = null,
            time = event.time,
            origin = BotEventOrigin.Local("runtime"),
            traceId = "trace:${event.eventId}",
            principal = BotPrincipal(
                botId = event.principal.botId,
                sessionId = event.principal.sessionId,
                kind = event.principal.kind.wire,
                capabilities = event.principal.capabilities,
            ),
            causationId = null,
            correlationId = null,
            data = JsonObject(event.data),
        )
        synchronized(storeLock) { store.append(stored) }
        val sessionId = lifecycleSessionId(event.data, event.principal.sessionId)
        synchronized(lock) {
            if (sessionId != null) {
                ensureSessionLocked(sessionId)
                if (event.type == RUNTIME_STARTED) adoptPendingRecordsLocked(sessionId)
            }
            bumpLocked()
        }
        requestHistoryLoad()
    }

    private fun lifecycleSessionId(data: Map<String, JsonValue>, principalSessionId: String): String? {
        val dataSession = (data["sessionId"] as? JsonString)?.value
        if (!dataSession.isNullOrEmpty()) return dataSession
        return principalSessionId.takeIf { it.isNotEmpty() }
    }

    private fun ensureSessionLocked(sessionId: String) {
        if (sessionId.isEmpty()) return
        if (!epochOrder.contains(sessionId)) epochOrder.add(sessionId)
        recordsBySession.getOrPut(sessionId) { mutableListOf() }
    }

    private fun adoptPendingRecordsLocked(sessionId: String) {
        if (pendingRecords.isEmpty()) return
        ensureSessionLocked(sessionId)
        recordsBySession.getOrPut(sessionId) { mutableListOf() }.addAll(pendingRecords)
        pendingRecords.clear()
    }

    // ------------------------------------------------------------- history IO

    /**
     * Starts one background chain load if none is running. The page's watch
     * loop gets a revision bump when the journals land; [history] returns the
     * current snapshot immediately rather than blocking on a cold Worker.
     */
    private fun requestHistoryLoad() {
        if (closed.get()) return
        if (!historyLoadRunning.compareAndSet(false, true)) {
            // A new epoch may have landed while the previous pass was ending;
            // run another pass after it instead of dropping the request.
            historyLoadRequested.set(true)
            return
        }
        scope.launch {
            try {
                var attempt = 0
                while (!closed.get()) {
                    if (loadHistoryOnce()) break
                    if (attempt >= HISTORY_RETRY_DELAYS_MS.size) break
                    delay(HISTORY_RETRY_DELAYS_MS[attempt])
                    attempt += 1
                }
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                // History is best effort; the page keeps whatever it has.
            } finally {
                historyLoadRunning.set(false)
                if (!closed.get() && historyLoadRequested.compareAndSet(true, false)) {
                    requestHistoryLoad()
                }
            }
        }
    }

    /** One pass over every known epoch; false means a retry may help. */
    private fun loadHistoryOnce(): Boolean {
        // Load the durable epoch chain before the optional legacy lookup: a
        // persisted `runtime.started` is already enough to read its journal.
        var completed = loadTargets(knownTargets())
        if (!legacyDiscoveryDone) {
            val discovered = try {
                discoverLegacySessions()
            } catch (_: Exception) {
                return false
            }
            synchronized(lock) {
                for (sessionId in discovered.asReversed()) {
                    if (!epochOrder.contains(sessionId)) {
                        epochOrder.add(0, sessionId)
                        recordsBySession.getOrPut(sessionId) { mutableListOf() }
                    }
                }
                legacyDiscoveryDone = true
                if (discovered.isNotEmpty()) bumpLocked()
            }
        }
        completed = loadTargets(knownTargets()) && completed
        return completed && synchronized(lock) {
            epochOrder.all { it in loadedSessions }
        }
    }

    private fun knownTargets(): List<String> = synchronized(lock) {
        epochOrder.filter { it !in loadedSessions }
    }

    private fun loadTargets(targets: List<String>): Boolean {
        var completed = true
        for (sessionId in targets) {
            if (closed.get()) return true
            val remote = try {
                historyReader.load(sessionId)
            } catch (_: Exception) {
                completed = false
                continue
            }
            synchronized(lock) {
                mergeRemoteRecordsLocked(sessionId, remote)
                loadedSessions.add(sessionId)
                bumpLocked()
            }
        }
        return completed
    }

    /**
     * Pre-fix installs have no durable `runtime.started`; their Worker session
     * is still the minted `gb-<safe botId>` (or a rebuilt `gb-<safe>-<uuid>`)
     * under the Bot root. `session/list` is the authoritative source named by
     * `session-lifecycle.md` §5 case 5 and §7. The ids are projected but not
     * written as a new lifecycle epoch: the runtime decides adoption/rebuild
     * on the next turn.
     */
    private fun discoverLegacySessions(): List<String> {
        val response = transport.call(
            "session/list",
            JsonObject(linkedMapOf("_request" to JsonObject(emptyMap()))),
        )
        val items = (response["items"] as? JsonArray)?.values ?: return emptyList()
        val minted = "gb-${BotSessionWorkspace.safePathComponent(botId)}"
        val root = BotSessionWorkspace.botRoot(botId)
        val candidates = ArrayList<Pair<String, Long>>()
        for ((index, value) in items.withIndex()) {
            val members = (value as? JsonObject)?.members ?: continue
            val sessionId = (members["sessionId"] as? JsonString)?.value ?: continue
            if (!isChatEpochId(sessionId, minted)) continue
            val cwd = (members["cwd"] as? JsonString)?.value
            if (cwd != null && cwd != root) continue
            if (cwd == null && sessionId != minted) continue
            val updatedAt = (members["updatedAt"] as? JsonNumber)?.asLongOrNull()
                ?: (members["lastActivityAt"] as? JsonNumber)?.asLongOrNull()
                ?: (members["modifiedAt"] as? JsonNumber)?.asLongOrNull()
                ?: index.toLong()
            candidates += sessionId to updatedAt
        }
        return candidates.sortedBy { it.second }.map { it.first }
    }

    private fun isChatEpochId(sessionId: String, minted: String): Boolean {
        if (sessionId == minted) return true
        val prefix = "$minted-"
        if (!sessionId.startsWith(prefix)) return false
        return runCatching { UUID.fromString(sessionId.removePrefix(prefix)) }.isSuccess
    }

    /**
     * The journal is authoritative; a concurrent live record with the same
     * event id, DSH seq or user-action nonce is the same message and is
     * dropped. Records the journal cannot contain yet (a prompt whose page was
     * read before the commit) survive until the next rebuild.
     */
    private fun mergeRemoteRecordsLocked(
        sessionId: String,
        remote: List<BotSessionLogRecord>,
    ) {
        val existing = recordsBySession.getOrPut(sessionId) { mutableListOf() }
        if (remote.isNotEmpty()) {
            val localUserEventIds = existing.filter { it.type == "user/message" }
                .mapNotNull { row -> userMessageNonce(row)?.let { it to row.eventId } }
                .toMap()
            val reconciled = remote.map { row ->
                val localId = if (row.type == "user/message") localUserEventIds[userMessageNonce(row)] else null
                if (localId != null) row.copy(eventId = localId) else row
            }
            val remoteEventIds = reconciled.mapNotNull { it.eventId }.toHashSet()
            val remoteSeqs = remote.map { it.seq }.toHashSet()
            val remoteNonces = remote
                .filter { it.type == "user/message" }
                .mapNotNull(::userMessageNonce)
                .toHashSet()
            val kept = existing.filterNot { record ->
                (record.eventId != null && record.eventId in remoteEventIds) ||
                    (record.type == "user/message" &&
                        userMessageNonce(record)?.let { it in remoteNonces } == true) ||
                    record.seq in remoteSeqs
            }
            val merged = ArrayList<BotSessionLogRecord>(remote.size + kept.size)
            merged += reconciled
            merged += kept
            merged.sortWith(compareBy({ it.seq }, { it.eventId ?: "" }))
            existing.clear()
            existing.addAll(merged)
        }
        if (existing.isNotEmpty()) {
            localSeq = maxOf(localSeq, (existing.maxOfOrNull { it.seq } ?: 0L) + 1L)
        }
    }

    private fun userMessageNonce(record: BotSessionLogRecord): String? {
        (record.data["nonce"] as? JsonString)?.value?.takeIf { it.isNotEmpty() }
            ?.let { return it }
        val source = (record.data["source"] as? JsonObject)
            ?: ((record.data["message"] as? JsonObject)?.get("source") as? JsonObject)
            ?: return null
        return com.phonedsh.bot.session.BotTurnOrigin.chatActionNonce(source.members)
    }

    // ------------------------------------------------------------------ turns

    private fun startChatTurn(action: BotUserAction) {
        if (!started.compareAndSet(false, true)) {
            // A later message while a turn is live is still sent; the runtime
            // itself queues/steers it, so no second start gate is invented.
        }
        scope.launch {
            try {
                val text = action.text.orEmpty()
                runtime.sendUserMessage(
                    text = text,
                    requestId = "user-action:${action.nonce}",
                    attachments = action.attachments ?: emptyList(),
                )
            } catch (error: Exception) {
                appendNotice(
                    text = "Bot 运行时未连接：${error.message ?: error.javaClass.simpleName}",
                    code = "runtime_unavailable",
                )
            }
        }
    }

    private fun onRuntimeFrame(frame: BotSessionLiveFrame) {
        if (closed.get()) return
        when (frame) {
            BotSessionLiveFrame.StreamStart -> {
                liveFrames.tryEmit(BotLiveFrame.StreamStart)
            }
            is BotSessionLiveFrame.TextDelta -> {
                liveFrames.tryEmit(BotLiveFrame.TextDelta(frame.text))
            }
            is BotSessionLiveFrame.Event -> {
                val event = (frame.event as? JsonObject) ?: return
                val type = (event["type"] as? JsonString)?.value ?: frame.type
                val data = (event["data"] as? JsonObject)?.members ?: emptyMap()
                val time = (event["time"] as? JsonNumber)?.asLongOrNull() ?: clock()
                val eventId = (event["eventId"] as? JsonString)?.value
                synchronized(lock) {
                    val seq = (event["seq"] as? JsonNumber)?.asLongOrNull()
                        ?: nextSeqLocked()
                    val record = BotSessionLogRecord(
                        type = type,
                        seq = seq,
                        time = time,
                        data = data,
                        surfaceOp = BotSurfaceOp.decode(data["surfaceOp"]) ?: BotSurfaceOp.Append,
                        eventId = eventId,
                    )
                    addRecordLocked(record)
                    when (type) {
                        "turn/start" -> {
                            runtime.mainSessionIdentifier()?.let { onTurnBoundary(it, true) }
                            val turn = (data["turn"] as? JsonNumber)?.asLongOrNull()?.toInt()
                            activeTurnId = turn?.let { "turn-$it" } ?: "turn"
                            activity = BotActivity(
                                status = BotActivityStatus.STREAMING,
                                detail = "",
                                category = BotActivityCategory.REPLYING,
                                startedAt = time,
                            )
                        }
                        "tool/call" -> {
                            val name = (data["name"] as? JsonString)?.value.orEmpty()
                            activity = BotActivity(
                                status = BotActivityStatus.TOOL_RUNNING,
                                detail = name,
                                category = BotActivityCategory.GENERIC,
                                startedAt = time,
                            )
                        }
                        "assistant/message" -> {
                            activity = BotActivity(
                                status = BotActivityStatus.STREAMING,
                                detail = "",
                                category = BotActivityCategory.REPLYING,
                                startedAt = time,
                            )
                        }
                        "turn/end" -> {
                            runtime.mainSessionIdentifier()?.let { onTurnBoundary(it, false) }
                            activeTurnId = null
                            activity = null
                        }
                    }
                    bumpLocked()
                    presentationState.value = currentPresentationLocked()
                }
                liveFrames.tryEmit(BotLiveFrame.Event(event))
            }
        }
    }

    private fun appendNotice(text: String, code: String) {
        val eventId = "evt-notice-${UUID.randomUUID().toString().lowercase()}"
        val event = BotEvent(
            schemaVersion = BotEventCodec.CURRENT_SCHEMA_VERSION,
            type = "ui.notice",
            eventId = eventId,
            commitSeq = null,
            time = clock(),
            origin = BotEventOrigin.Local("runtime"),
            traceId = "trace:$eventId",
            principal = BotPrincipal(
                botId = botId,
                sessionId = runtime.mainSessionIdentifier(),
                kind = "chat",
                capabilities = emptyList(),
            ),
            causationId = null,
            correlationId = null,
            data = BotJson.objectOf(
                "text" to JsonString(text),
                "tone" to JsonString("error"),
                "code" to JsonString(code),
            ),
        )
        runCatching {
            synchronized(storeLock) { store.append(event) }
            synchronized(lock) { bumpLocked() }
        }
    }

    // -------------------------------------------------------------- projection

    private fun newPlanEvent(action: BotUserAction): BotEvent {
        val eventId = "evt-action-${UUID.randomUUID().toString().lowercase()}"
        val type = when (action.kind) {
            BotUserActionKind.CHAT -> "conversation.user_message"
            BotUserActionKind.CARD_ANSWER -> "card.answered"
            BotUserActionKind.CARD_DISMISS -> "card.dismissed"
            BotUserActionKind.APPROVAL -> "approval.decided"
            BotUserActionKind.STOP_TASK -> "task.stop_requested"
        }
        val base = LinkedHashMap<String, JsonValue>()
        base["action"] = JsonString(action.kind.wire)
        base["nonce"] = JsonString(action.nonce)
        action.text?.let { base["text"] = JsonString(it) }
        action.cardID?.let { base["cardID"] = JsonString(it) }
        action.optionID?.let { base["optionID"] = JsonString(it) }
        action.approvalID?.let { base["approvalID"] = JsonString(it) }
        action.decision?.let { base["decision"] = JsonString(it.wire) }
        action.digest?.let { base["digest"] = JsonString(it) }
        action.threadID?.let { base["threadID"] = JsonString(it) }
        action.attachments?.let { list -> base["attachments"] = JsonArray(list.map { it.toJson() }) }
        return BotEvent(
            schemaVersion = BotEventCodec.CURRENT_SCHEMA_VERSION,
            type = type,
            eventId = eventId,
            commitSeq = null,
            time = clock(),
            origin = BotEventOrigin.Local("user"),
            traceId = "trace:$eventId",
            principal = BotPrincipal(
                botId = action.botID.ifEmpty { botId },
                sessionId = runtime.mainSessionIdentifier(),
                kind = "chat",
                capabilities = emptyList(),
            ),
            causationId = null,
            correlationId = action.nonce,
            data = JsonObject(base),
        )
    }

    private fun userRecord(action: BotUserAction, eventId: String, seq: Long): BotSessionLogRecord {
        val attachments = action.attachments ?: emptyList()
        val body = withAttachments(action.text.orEmpty(), attachments)
        val data = LinkedHashMap<String, JsonValue>()
        data["role"] = JsonString("user")
        data["content"] = JsonArray(
            listOf(
                BotJson.objectOf(
                    "type" to JsonString("text"),
                    "text" to JsonString(body),
                ),
            ),
        )
        data["source"] = BotJson.objectOf(
            "kind" to JsonString("user"),
            "rpcId" to JsonString("$USER_ACTION_PREFIX${action.nonce}"),
        )
        data["surfaceOp"] = JsonString("append")
        data["nonce"] = JsonString(action.nonce)
        if (attachments.isNotEmpty()) {
            data["attachments"] = JsonArray(attachments.map { it.toJson() })
        }
        return BotSessionLogRecord(
            type = "user/message",
            seq = seq,
            time = clock(),
            data = data,
            surfaceOp = BotSurfaceOp.Append,
            eventId = eventId,
        )
    }

    private fun withAttachments(text: String, attachments: List<BotAttachment>): String {
        if (attachments.isEmpty()) return text
        val block = BotAttachmentPrompt.block(attachments)
        return if (text.isEmpty()) block.dropWhile { it == '\n' } else text + block
    }

    private fun addRecordLocked(record: BotSessionLogRecord) {
        val sessionId = runtime.mainSessionIdentifier()
        if (sessionId == null) {
            pendingRecords += record
        } else {
            ensureSessionLocked(sessionId)
            recordsBySession.getOrPut(sessionId) { mutableListOf() } += record
        }
    }

    private fun currentRecordsLocked(): List<BotSessionLogRecord> {
        val sessionId = runtime.mainSessionIdentifier()
            ?: return pendingRecords.toList()
        return recordsBySession[sessionId]?.toList() ?: emptyList()
    }

    private fun rebuildLocked() {
        val current = runtime.mainSessionIdentifier()
        if (current != null) {
            ensureSessionLocked(current)
            adoptPendingRecordsLocked(current)
        }
        val order = ArrayList(epochOrder)
        if (current != null && !order.contains(current)) order.add(current)
        val liveId = current ?: order.lastOrNull()
        val epochs = ArrayList<BotSessionEpochProjection>()
        for (sessionId in order) {
            val records = recordsBySession[sessionId]?.toList() ?: emptyList()
            // `session-lifecycle.md` §7: keep an older epoch only when its log
            // is non-empty; the live epoch is always represented.
            if (sessionId != liveId && records.isEmpty()) continue
            epochs += BotSessionEpochProjection(sessionId, records)
        }
        if (pendingRecords.isNotEmpty() && current == null &&
            epochs.none { it.sessionID == DEFAULT_SESSION_ID }
        ) {
            epochs += BotSessionEpochProjection(DEFAULT_SESSION_ID, pendingRecords.toList())
        }
        if (epochs.isEmpty()) {
            epochs += BotSessionEpochProjection(liveId ?: DEFAULT_SESSION_ID, emptyList())
        }
        val uiEvents = readUiEvents()
        history.rebuild(
            botID = botId,
            epochs = epochs,
            uiEvents = uiEvents,
        )
        presentationState.value = currentPresentationLocked()
    }

    private fun currentPresentationLocked(): BotRuntimePresentation = BotRuntimePresentation(
        fishState = if (activeTurnId != null) BotFishLifecycle.THINKING else BotFishLifecycle.IDLE,
        runningTurnID = activeTurnId,
        activity = activity,
    )

    private fun readUiEvents(): List<BotProjectionEvent> {
        val result = ArrayList<BotProjectionEvent>()
        synchronized(storeLock) {
            var after = 0
            while (true) {
                val page = store.events(after, PAGE_SIZE)
                if (page.isEmpty()) break
                for (event in page) {
                    val seq = event.commitSeq ?: continue
                    result += runCatching { BotProjectionEvent.fromJson(event.toJson()) }
                        .getOrNull() ?: continue
                    after = seq.toInt()
                }
                if (page.size < PAGE_SIZE) break
            }
        }
        return result
    }

    private fun buildProcesses(source: List<BotSessionLogRecord>): Map<Int, BotTurnProcess> {
        val result = LinkedHashMap<Int, MutableList<String>>()
        var turn = 0
        for (record in source) {
            when (record.type) {
                "turn/start" -> turn = (record.data["turn"] as? JsonNumber)
                    ?.asLongOrNull()?.toInt() ?: turn
                "tool/call" -> {
                    val name = (record.data["name"] as? JsonString)?.value ?: continue
                    val eventTurn = (record.data["turn"] as? JsonNumber)
                        ?.asLongOrNull()?.toInt() ?: turn
                    if (eventTurn <= 0) continue
                    val names = result.getOrPut(eventTurn) { mutableListOf() }
                    if (name !in names) names += name
                }
            }
        }
        return result.mapValues { (value, names) -> BotTurnProcess(value, names) }
    }

    private fun bumpLocked() {
        revision.value = revision.value + 1
    }

    private fun nextSeqLocked(): Long {
        var maximum = pendingRecords.maxOfOrNull { it.seq } ?: 0L
        for (values in recordsBySession.values) {
            maximum = maxOf(maximum, values.maxOfOrNull { it.seq } ?: 0L)
        }
        localSeq = maxOf(localSeq, maximum + 1L, LOCAL_SEQ_BASE)
        return localSeq++
    }

    private companion object {
        const val DEFAULT_SESSION_ID: String = "main"
        const val RUNTIME_STARTED: String = "runtime.started"
        const val PAGE_SIZE: Int = 500
        const val USER_ACTION_PREFIX: String = "user-action:"

        /** Above any realistic DSH `seq`, below `Long.MAX_VALUE`. */
        const val LOCAL_SEQ_BASE: Long = 1_000_000_000_000L

        /** Cold Worker boot retries; the page keeps the last snapshot meanwhile. */
        val HISTORY_RETRY_DELAYS_MS: LongArray = longArrayOf(250, 500, 1_000, 2_000, 4_000, 8_000, 8_000)

        fun seedLifecycleEvents(
            store: BotDomainStore,
            botId: String,
            storeLock: Any,
        ): List<BotSessionStoredEvent> = synchronized(storeLock) {
            val result = ArrayList<BotSessionStoredEvent>()
            var after = 0
            while (true) {
                val page = store.events(after, PAGE_SIZE)
                if (page.isEmpty()) break
                for (event in page) {
                    val commitSeq = event.commitSeq ?: continue
                    after = commitSeq.toInt()
                    if (event.type != RUNTIME_STARTED) continue
                    if (event.principal.botId != botId) continue
                    val kind = runCatching {
                        BotSessionKind.fromWire(event.principal.kind)
                    }.getOrNull() ?: continue
                    if (kind != BotSessionKind.CHAT) continue
                    val eventData = (event.data as? JsonObject)?.members ?: emptyMap()
                    val sessionId = (eventData["sessionId"] as? JsonString)?.value
                        ?: event.principal.sessionId
                        ?: continue
                    if (sessionId.isEmpty()) continue
                    result += BotSessionStoredEvent(
                        type = event.type,
                        principal = BotSessionPrincipal(
                            botId = event.principal.botId ?: botId,
                            sessionId = sessionId,
                            kind = kind,
                            capabilities = event.principal.capabilities,
                            expiresAt = 0,
                            incarnation = "",
                        ),
                        data = eventData,
                        eventId = event.eventId,
                        time = event.time,
                        commitSeq = commitSeq,
                    )
                }
                if (page.size < PAGE_SIZE) break
            }
            result
        }
    }
}
