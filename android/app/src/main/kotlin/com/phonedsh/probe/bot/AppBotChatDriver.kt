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
import com.phonedsh.bot.session.BotSessionLiveFrame
import com.phonedsh.bot.session.BotSessionPrincipal
import com.phonedsh.bot.session.BotSessionRemoteException
import com.phonedsh.bot.session.BotSessionRuntime
import com.phonedsh.bot.session.BotSessionStoredEvent
import com.phonedsh.bot.session.BotSessionTokenRegistry
import com.phonedsh.bot.session.BotSessionTransport
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
import com.phonedsh.bot.fish.BotFishLifecycle
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.isActive

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
) : BotChatDriver, AutoCloseable {
    private val lock = Any()
    private val storeLock = Any()
    private val history = BotRowHistory()
    private val records = ArrayList<BotSessionLogRecord>(seedRecords)
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
    private var localSeq: Long = (seedRecords.maxOfOrNull { it.seq } ?: 0L) + 1L
    private val started = AtomicBoolean(false)

    private val runtime: BotSessionRuntime = BotSessionRuntime(
        transport = transport,
        botId = botId,
        tokens = tokens,
        now = clock,
        onSessionRegistered = { sessionId ->
            synchronized(lock) {
                if (records.none { it.type == RUNTIME_STARTED && it.dataText("sessionId") == sessionId }) {
                    // The runtime's durable lifecycle event is mirrored into the
                    // row projection as a synthetic record so history stays
                    // usable before the first DSH log file exists.
                    records += BotSessionLogRecord(
                        type = RUNTIME_STARTED,
                        seq = nextSeq(),
                        time = clock(),
                        data = linkedMapOf(
                            "sessionId" to JsonString(sessionId),
                            "botId" to JsonString(botId),
                            "cwd" to JsonString(""),
                        ),
                    )
                }
                bumpLocked()
            }
        },
        seedEvents = seedLifecycleEvents(store, botId),
    )

    private val liveToken: Long = runtime.subscribeLiveFrames(::onRuntimeFrame)

    init {
        synchronized(lock) { rebuildLocked() }
    }

    override suspend fun history(before: String?, limit: Int): BotUIHistoryPage =
        withContext(Dispatchers.IO) {
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
                        val commitSeq = synchronized(storeLock) {
                            store.event(result.eventID)?.commitSeq
                        }
                        records += userRecord(action, result.eventID, plan.commitSeq
                            ?: commitSeq ?: nextSeq())
                    }
                    bumpLocked()
                }
                if (action.kind == BotUserActionKind.CHAT) {
                    startChatTurn(action)
                }
            }
            result
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
            buildProcesses(records)
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
                val seq = (event["seq"] as? JsonNumber)?.asLongOrNull() ?: nextSeq()
                val time = (event["time"] as? JsonNumber)?.asLongOrNull() ?: clock()
                val eventId = (event["eventId"] as? JsonString)?.value
                val record = BotSessionLogRecord(
                    type = type,
                    seq = seq,
                    time = time,
                    data = data,
                    surfaceOp = BotSurfaceOp.decode(data["surfaceOp"]) ?: BotSurfaceOp.Append,
                    eventId = eventId,
                )
                synchronized(lock) {
                    records += record
                    when (type) {
                        "turn/start" -> {
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
            "rpcId" to JsonString("user-action:${action.nonce}"),
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

    private fun rebuildLocked() {
        val sessionId = runtime.mainSessionIdentifier() ?: DEFAULT_SESSION_ID
        val uiEvents = synchronized(storeLock) { readUiEvents() }
        history.rebuild(
            botID = botId,
            epochs = listOf(BotSessionEpochProjection(sessionId, records.toList())),
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

    private fun nextSeq(): Long {
        synchronized(lock) {
            localSeq = maxOf(localSeq, (records.maxOfOrNull { it.seq } ?: 0L) + 1L)
            return localSeq++
        }
    }

    private fun BotSessionLogRecord.dataText(key: String): String? =
        (data[key] as? JsonString)?.value

    private companion object {
        const val DEFAULT_SESSION_ID: String = "main"
        const val RUNTIME_STARTED: String = "runtime.started"
        const val PAGE_SIZE: Int = 500

        fun seedLifecycleEvents(store: BotDomainStore, botId: String): List<BotSessionStoredEvent> {
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
                    val eventData = (event.data as? JsonObject)?.members ?: emptyMap()
                    val sessionId = (eventData["sessionId"] as? JsonString)?.value
                        ?: event.principal.sessionId
                        ?: continue
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
            return result
        }
    }
}
