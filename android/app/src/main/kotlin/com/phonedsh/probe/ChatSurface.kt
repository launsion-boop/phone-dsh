// The chat surface's host half: Worker events -> `ui-state/1` nodes, and the one
// `ChatScreenState` the page renders.
// SPDX-License-Identifier: MIT
//
// ---- why the mapping lives here and not in `:lib` -------------------------
// `:lib` owns the *pure* layer: `ChatScreenState.from(nodes, local, host)` folds a
// node sequence into rows, and `UiStateNode`/`ChatRow` are its types. What a node
// *is* comes from the host's event stream, which `:lib` must not know about: it
// has no `:core`/`:dsh` edge and no idea that a Worker exists. So the Worker's
// durable events (`turn/start`, `assistant/message`, `tool/call`, ...) become
// nodes here, in the App, and the page stays a pure function of the result.
//
// ---- what is a node here --------------------------------------------------
// Only what `ChatScreenState.from` reads is projected: a user bubble, an assistant
// bubble, the two halves of a tool row, and a visible turn-end row for an ending
// that is not `completed`. Structural nodes (`session`, the running `turn`) are
// added by [chatScreenState] because they describe the App's own current
// conversation, not the Worker's history. `usage` is folded into the message and
// has no row of its own (`event-kinds.md` §1).
//
// ---- what is live and what is durable -------------------------------------
// The streaming text is *not* a node: `ChatScreenState.from` would treat a
// streamed bubble as a settled row, and the durable `assistant/message` that
// arrives at the end replaces it anyway. `ChatUiState.streaming` is therefore
// drawn as one extra row while the turn runs and disappears when the settled
// message lands. Only durable rows are persisted (`ChatSessionStore`).
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.hostevents.HostEvent
import com.phonedsh.hostevents.HostEventKind
import com.phonedsh.hostevents.HostEventProjection
import com.phonedsh.ui.page.FilesImportReceipt
import com.phonedsh.ui.projection.UiStateKind
import com.phonedsh.ui.projection.UiStateNode
import com.phonedsh.ui.projection.UiStateSurface
import com.phonedsh.ui.state.ChatAttachment
import com.phonedsh.ui.state.ChatEmpty
import com.phonedsh.ui.state.ChatHostFacts
import com.phonedsh.ui.state.ChatLocalState
import com.phonedsh.ui.state.ChatPhase
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.state.ChatScreenState
import com.phonedsh.ui.state.ComposerStatsMode
import com.phonedsh.ui.state.RunStatus
import com.phonedsh.ui.page.PerformanceUsage
import com.phonedsh.ui.state.TranscriptState

/**
 * The chat screen's host state.
 *
 * @param chatId this App's stable conversation id; empty means "no conversation
 *   started yet" (a fresh 新建会话 before its first message).
 * @param title the user's name; empty renders the page's 新会话 word.
 * @param draft what the person typed.
 * @param nodes every durable row of the conversation, in order.
 * @param attachments imports the person added but has not sent.
 * @param running a turn is in flight.
 * @param activeTurnNodeId the `turn` node of the running turn, or `null`; it is
 *   what makes `ChatScreenState.from` report RUNNING and the dock show 停止.
 * @param streaming the live text the Worker has streamed for the running turn.
 * @param notice the last workspace-import status line; `null` hides it.
 * @param error the last send failure; `null` hides the banner.
 * @param attachmentError the last attachment failure; `null` hides the line.
 * @param updatedAtMs when this conversation last changed (list order).
 * @param bannerDismissed whether the person closed the current failure banner.
 */
internal data class ChatUiState(
    val chatId: String = "",
    val title: String = "",
    val draft: String = "",
    val nodes: List<UiStateNode> = emptyList(),
    /**
     * The Worker session the next turn continues, or `null` before the first
     * send.
     *
     * Persisted in the chat record, so it also survives a cold start. It is a
     * *resumable* id, not just a claim: the Worker keeps its session log under
     * `/dsh/home/sessions`, repacks it into every boot overlay, and
     * `session/prompt` resumes a non-live session from it — which is what keeps
     * the model's context equal to the transcript (`ChatTurnRunner`).
     */
    val workerSessionId: String? = null,
    /**
     * The prefix of this send's turn ids (`t<n>-`).
     *
     * A Worker session that had to be replaced (the stored log was really gone)
     * starts its turn numbering at `turn-0001` again, so the Worker's own turn id is not
     * unique inside one conversation. Prefixing it per send keeps every row's
     * nodeID unique — the page uses the id as its list key, and a duplicate key
     * crashed the frame (`IllegalArgumentException: Key ... was already used`,
     * measured 2026-11-02).
     */
    val turnToken: String = "",
    val attachments: List<ChatAttachment> = emptyList(),
    val running: Boolean = false,
    val activeTurnNodeId: String? = null,
    val streaming: String = "",
    val reasoningStreaming: String = "",
    val notice: String? = null,
    val error: String? = null,
    val attachmentError: String? = null,
    val updatedAtMs: Long = 0L,
    val bannerDismissed: Boolean = false,
    val sessionSnapshot: ChatSessionSnapshot = ChatSessionSnapshot(),
    val pendingNodes: List<UiStateNode> = emptyList(),
    val lastSubmission: String = "",
    val lastAttachments: List<ChatAttachment> = emptyList(),
    /** Stable `/api/session/prompt` identity for the original submission being retried. */
    val lastPromptRequestId: String? = null,
    /** New requests accepted locally but not yet matched to the durable inbox projection. */
    val localQueueItems: List<com.phonedsh.ui.state.ManagedQueueItemState> = emptyList(),
    /** Stable prompt identity reused only while retrying this unchanged failed busy submission. */
    val retryBusyPromptRequestId: com.phonedsh.ui.state.StateRequestId? = null,
    val imeVisible: Boolean = false,
    val pendingExpanded: Boolean = false,
    val expandedRowIds: Set<String> = emptySet(),
    val commandExecution: com.phonedsh.ui.page.ChatCommandExecution? = null,
    /** Cursor facts for a Worker session opened from the subagent catalog. */
    val subagentTranscript: SubagentTranscriptWindow? = null,
) {
    /** True when this state names a conversation the session list can show. */
    val hasConversation: Boolean get() = chatId.isNotEmpty()
}

/** A bounded `session/page` window; a null cursor means no earlier page exists. */
internal data class SubagentTranscriptWindow(
    val workerSessionId: String,
    val throughSeq: Long?,
    val beforeSeq: Long?,
    val hasMore: Boolean,
    val loadingEarlier: Boolean = false,
    val error: String? = null,
) {
    fun screenState(): TranscriptState = TranscriptState(
        hasMore = hasMore,
        loadingEarlier = loadingEarlier,
        error = error,
    )
}

/** Result of projecting one verified Worker history page into the app transcript. */
internal data class SubagentHistoryProjection(
    val nodes: List<UiStateNode>,
    val unsupportedReason: String? = null,
)

/** A page claiming more history must move the exclusive `beforeSeq` cursor backward. */
internal fun subagentHistoryCursorAdvanced(
    previousBeforeSeq: Long,
    nextBeforeSeq: Long?,
): Boolean = nextBeforeSeq != null && nextBeforeSeq < previousBeforeSeq

/** Terminal cursor stalls preserve the error/rows but stop advertising another page. */
internal fun transcriptAfterSubagentPageFailure(
    window: SubagentTranscriptWindow,
    message: String,
    terminalPagination: Boolean,
): SubagentTranscriptWindow = window.copy(
    hasMore = window.hasMore && !terminalPagination,
    loadingEarlier = false,
    error = message,
)

/** Reuse the production event normalizer and timeline projector for session/page history. */
internal fun projectSubagentHistory(
    chatId: String,
    rawEvents: List<JsonObject>,
    nonTextPlaceholder: String? = null,
): SubagentHistoryProjection {
    val nodes = ArrayList<UiStateNode>()
    var ordinal = 0
    for (raw in rawEvents.sortedBy { (it["seq"] as? com.phonedsh.agentcore.JsonNumber)?.asLongOrNull() ?: Long.MIN_VALUE }) {
        for (event in HostEventProjection.projectAll(raw)) {
            ordinal++
            if (event.kind == HostEventKind.USER_MESSAGE) {
                val content = event.data?.get("content")
                if (content == null && nonTextPlaceholder == null) {
                    return SubagentHistoryProjection(emptyList(), "用户消息历史内容无法读取；未打开子会话。")
                }
                val textParts = ArrayList<String>()
                var unsupported = false
                when (content) {
                    is JsonString -> textParts += content.value
                    is JsonArray -> content.values.forEach { blockValue ->
                        val block = blockValue as? JsonObject
                        if (block?.get("type") is JsonString && (block["type"] as JsonString).value == "text") {
                            (block["text"] as? JsonString)?.value?.let(textParts::add)
                                ?: run { unsupported = true }
                        } else if (blockValue != com.phonedsh.agentcore.JsonNull) {
                            unsupported = true
                        }
                    }
                    else -> unsupported = true
                }
                if (unsupported) {
                    if (nonTextPlaceholder == null) {
                        return SubagentHistoryProjection(emptyList(), "子会话包含本机未支持的历史消息类型；未打开子会话。")
                    }
                    textParts += nonTextPlaceholder
                }
                val text = textParts.joinToString("\n")
                if (text.isNotBlank()) nodes += durableUserNode(chatId, event, text, ordinal)
            } else {
                chatNodeOf(chatId, "", event, ordinal)?.let(nodes::add)
            }
        }
    }
    return SubagentHistoryProjection(nodes.distinctBy { it.nodeID })
}

internal fun projectPcSessionHistory(
    sessionId: String,
    rawEvents: List<JsonObject>,
): SubagentHistoryProjection = projectSubagentHistory(
    sessionId,
    rawEvents.filterNot { event ->
        val source = (event["data"] as? JsonObject)?.get("source") as? JsonObject
        val kind = (source?.get("kind") as? JsonString)?.value
        (event["type"] as? JsonString)?.value == "user/message" && kind != null && kind != "user"
    },
    nonTextPlaceholder = "电脑上的这段消息含有暂无法显示的内容。",
)

private fun durableUserNode(
    chatId: String,
    event: HostEvent,
    text: String,
    ordinal: Int,
    turnId: String = event.turnId ?: FALLBACK_TURN_ID,
): UiStateNode {
    val seq = event.seq?.toInt() ?: ordinal
    return UiStateNode(
        kind = UiStateKind.BUBBLE,
        nodeID = "session/$chatId/turn/$turnId/event/$seq/user-message",
        parentID = "session/$chatId/turn/$turnId",
        sessionID = chatId,
        turnID = turnId,
        seq = seq,
        text = bounded(text),
        props = JsonObject(
            linkedMapOf(
                "role" to JsonString("user"),
                "source" to JsonString("user"),
                "truncated" to JsonBool(text.length > TEXT_LIMIT),
            ),
        ),
    )
}

/**
 * Folds [ui] into the page's `ChatScreenState`.
 *
 * @param engineStarted the host is up, so an empty conversation is READY rather
 *   than 引擎还没启动.
 * @param providerNeedsKey no usable model service is configured.
 * @param canSend the host can accept a message right now.
 * @param files the workspace-relative paths the `@` menu offers; the host reads
 *   them off the same materialized tree as the files page, on its IO lane.
 * @param sessionTitles the unarchived session titles the `@` menu offers, with
 *   the current conversation already excluded by the host.
 */
internal fun chatScreenState(
    ui: ChatUiState,
    engineStarted: Boolean,
    providerNeedsKey: Boolean,
    canSend: Boolean,
    canSteer: Boolean = false,
    enterMode: com.phonedsh.ui.state.EnterMode = com.phonedsh.ui.state.EnterMode.QUEUE,
    lifecycle: com.phonedsh.ui.state.EngineLifecycleFacts? = null,
    performanceUsage: PerformanceUsage = PerformanceUsage.DETAILED,
    files: List<String> = emptyList(),
    sessionTitles: List<String> = emptyList(),
): ChatScreenState {
    val chatId = ui.chatId.ifEmpty { PENDING_CHAT_ID }
    val nodes = ArrayList<UiStateNode>(ui.nodes.size + 2)
    nodes += sessionNode(chatId)
    // A stored row that repeats a nodeID would be a duplicate list key in the page;
    // the first occurrence is the row the person saw.
    nodes += ui.nodes.distinctBy { it.nodeID }
    nodes += ui.pendingNodes
    if (ui.running && ui.reasoningStreaming.isNotEmpty()) {
        val turn = ui.activeTurnNodeId ?: "live"
        val thinking = UiStateNode(
            kind = UiStateKind.THINKING_PILL,
            nodeID = "session/$chatId/turn/$turn/event/0/thinking-live",
            parentID = "session/$chatId/turn/$turn", sessionID = chatId, turnID = turn, seq = 0,
            text = ui.reasoningStreaming, surface = UiStateSurface.THINKING_PILL,
            props = JsonObject(mapOf("streaming" to JsonBool(true))),
        )
        val insertion = nodes.indexOfFirst { it.kind == UiStateKind.TOOL_ROW && it.turnID == turn }
        if (insertion >= 0) nodes.add(insertion, thinking) else nodes += thinking
    }
    ui.activeTurnNodeId?.let { active ->
        val turn = turnNode(chatId, active)
        if (nodes.none { it.nodeID == turn.nodeID }) nodes += turn
    }
    if (ui.error != null && !ui.bannerDismissed) {
        nodes += bannerNode(
            chatId,
            ui.error,
            retryable = !ui.lastPromptRequestId.isNullOrBlank() &&
                (ui.lastSubmission.isNotBlank() || ui.lastAttachments.isNotEmpty()),
        )
    }
    val local = ChatLocalState(
        draft = ui.draft,
        attachments = ui.attachments,
        attachmentError = ui.attachmentError,
        fileImportNotice = ui.notice,
        dismissedBannerIds = if (ui.bannerDismissed) setOf(bannerId(chatId)) else emptySet(),
        imeVisible = ui.imeVisible,
        pendingSlotExpanded = ui.pendingExpanded,
        expandedRowIds = ui.expandedRowIds,
    )
    val host = ChatHostFacts(
        engineStarted = engineStarted,
        // Queue and steer are host-owned session/prompt modes. The typed action
        // table controls which one the page can submit while the turn is live.
        canSend = canSend,
        canSteer = canSteer,
        enterMode = enterMode,
        providerNeedsKey = providerNeedsKey,
        lifecycle = lifecycle,
        sessionStats = ui.sessionSnapshot.sessionStats,
        tokenUsage = ui.sessionSnapshot.tokenUsage,
        contextPressure = ui.sessionSnapshot.contextPressure,
        contextBreakdown = ui.sessionSnapshot.contextBreakdown,
        contextPercent = ui.sessionSnapshot.contextPressure?.percent,
        composerStatsMode = if (performanceUsage == PerformanceUsage.COMPACT) ComposerStatsMode.COMPACT else ComposerStatsMode.DETAILED,
        transcript = ui.subagentTranscript?.screenState() ?: TranscriptState(),
        todoItems = ui.sessionSnapshot.todos,
        accessModes = ui.sessionSnapshot.accessModes,
        currentAccessMode = ui.sessionSnapshot.currentAccessMode,
        commands = ui.sessionSnapshot.commands,
        workerSessionID = ui.workerSessionId,
        accessModeError = ui.sessionSnapshot.accessError,
        accessModeLoading = ui.sessionSnapshot.accessLoading,
        commandsError = ui.sessionSnapshot.commandsError,
        files = files.take(CHAT_MENTION_FILE_LIMIT),
        sessionTitles = sessionTitles.take(CHAT_MENTION_SESSION_LIMIT),
        models = ui.sessionSnapshot.modelRoutes.map { it.model }.distinct(),
        currentModel = ui.sessionSnapshot.currentModel,
        currentEffort = ui.sessionSnapshot.currentEffort,
        efforts = ui.sessionSnapshot.modelRoutes.firstOrNull { it.model == ui.sessionSnapshot.currentModel }?.efforts.orEmpty(),
        effortTitle = ui.sessionSnapshot.currentEffort?.let { effortTitle(it) },
        defaultEffortTitle = ui.sessionSnapshot.modelRoutes.firstOrNull { it.model == ui.sessionSnapshot.currentModel }
            ?.defaultEffort?.let { "默认强度 · ${effortTitle(it)}" } ?: com.phonedsh.ui.UiStrings.MODEL_DEFAULT_EFFORT,
        queueItems = ui.sessionSnapshot.queueItems?.map { item ->
            // Steer is legal only for the next-turn dock lane while a turn runs.
            item.copy(canSteer = ui.running && item.lane == "next-turn")
        }
            ?.let { durable -> com.phonedsh.ui.state.reconcileQueueRows(durable, ui.localQueueItems) }
            ?: ui.localQueueItems.takeIf { it.isNotEmpty() },
    )
    val base = ChatScreenState.from(nodes = nodes, local = local, host = host, goal = ui.sessionSnapshot.goal)
    val rows = if (ui.running && ui.streaming.isNotEmpty()) {
        base.rows + ChatRow.Assistant(
            id = "streaming/$chatId",
            text = ui.streaming,
            streaming = true,
        )
    } else {
        base.rows
    }
    return base.copy(
        rows = rows,
        // The transcript's empty-state choice is a host fact, not a projection: the
        // page shows A/B/C from these two readings.
        empty = when {
            !engineStarted -> ChatEmpty.ENGINE_NOT_STARTED
            providerNeedsKey -> ChatEmpty.PROVIDER_SETUP
            else -> ChatEmpty.READY
        },
        runStatus = if (engineStarted) RunStatus.STARTED else RunStatus.STOPPED,
        // `ChatScreenState.from` derives the phase from open turn nodes; an empty
        // conversation has none, and the host is the only layer that knows whether a
        // turn is running.
        phase = when {
            ui.running -> ChatPhase.RUNNING
            base.phase == ChatPhase.WAITING && engineStarted -> ChatPhase.IDLE
            else -> base.phase
        },
    )
}

/** The screen state of one stored record: what a cold start reopens. */
internal fun ChatRecord.toUiState(): ChatUiState = ChatUiState(
    chatId = id,
    title = title,
    nodes = nodes,
    workerSessionId = workerSessionIds.lastOrNull(),
    updatedAtMs = updatedAtMs,
)

/** This send's node turn id for one Worker turn number. */
internal fun ChatUiState.turnIdOf(workerTurn: String?): String {
    val base = workerTurn ?: "unknown"
    return if (turnToken.isEmpty()) base else "$turnToken-$base"
}

/** The structural `session` node of one conversation (`trajectory.md` §7). */
internal fun sessionNode(chatId: String): UiStateNode = UiStateNode(
    kind = UiStateKind.SESSION,
    nodeID = "session/$chatId",
    parentID = "root",
    sessionID = chatId,
    turnID = SESSION_SCOPE_TURN_ID,
    seq = 0,
)

/** The structural `turn` node of the running turn. */
internal fun turnNode(chatId: String, turnId: String): UiStateNode = UiStateNode(
    kind = UiStateKind.TURN,
    nodeID = "session/$chatId/turn/$turnId",
    parentID = "session/$chatId",
    sessionID = chatId,
    turnID = turnId,
    seq = 0,
)

/**
 * Applies one Worker event to the chat state.
 *
 * This is the state half of `onChatEvent`, kept here so the JVM suite can drive
 * the real projection (TURN_STARTED -> TURN node, tool rows, turn-end STATUS)
 * without an Android ViewModel.
 */
internal fun ChatUiState.applyChatEvent(chatId: String, event: HostEvent, ordinal: Int): ChatUiState {
    if (this.chatId != chatId) return this
    if (event.kind == HostEventKind.TURN_STARTED) {
        // A turn start is only meaningful while this send is still live. Without
        // this guard a late frame can re-add the TURN node after 停止 closed it,
        // which projects RUNNING again and cannot be stopped (running == false).
        if (!running) return this
        val id = turnIdOf(event.turnId)
        val turn = turnNode(chatId, id).copy(props = JsonObject(mapOf(
            "startedAtMs" to (event.raw["time"] ?: com.phonedsh.agentcore.JsonNull),
        )))
        return copy(
            activeTurnNodeId = id,
            streaming = "",
            reasoningStreaming = "",
            nodes = nodes.filterNot { it.nodeID == turn.nodeID } + turn,
        )
    }
    val node = if (event.kind == HostEventKind.USER_MESSAGE) {
        val data = event.data ?: return this
        val source = data["source"] as? JsonObject ?: return this
        if ((source["kind"] as? JsonString)?.value != "user") return this
        val rpcId = (source["rpcId"] as? JsonString)?.value
        if (rpcId != null && rpcId == lastPromptRequestId) return this
        val turnId = activeTurnNodeId ?: return this
        val content = data["content"] as? JsonArray ?: return this
        val text = content.values.mapNotNull { value ->
            val part = value as? JsonObject ?: return@mapNotNull null
            if ((part["type"] as? JsonString)?.value != "text") return@mapNotNull null
            (part["text"] as? JsonString)?.value
        }.joinToString("\n")
        if (text.isBlank()) return this
        durableUserNode(chatId, event, text, ordinal, turnId)
    } else {
        chatNodeOf(chatId, turnToken, event, ordinal) ?: return this
    }
    if (nodes.any { it.nodeID == node.nodeID }) return this
    return copy(
        nodes = nodes + node,
        reasoningStreaming = if (event.kind == HostEventKind.ASSISTANT_MESSAGE) "" else reasoningStreaming,
    )
}

/**
 * Applies one event only if the callback still belongs to the live turn.
 *
 * The generation read and the state mutation happen in the caller's
 * `MutableStateFlow.update` block, so 停止 cannot interleave between the check
 * and the append. A late TURN_STARTED is also rejected by
 * [applyChatEvent]'s `running` guard.
 */
internal fun applyChatEventIfCurrent(
    current: ChatUiState,
    chatId: String,
    event: HostEvent,
    ordinal: Int,
    eventGeneration: Long,
    currentGeneration: Long,
): ChatUiState {
    if (current.chatId != chatId) return current
    if (eventGeneration != currentGeneration) return current
    return current.applyChatEvent(chatId, event, ordinal)
}

/**
 * Closes every turn that has no turn-end, without guessing which one was live.
 *
 * A stopped turn is still in [nodes] as a `TURN` node; the transcript only
 * leaves RUNNING when a matching turn-end STATUS closes it. The previous stop
 * path wrote an end for `turnIdOf("stopped")`, so the real turn stayed open
 * forever, including across a cold start. This adds one `cancelled` end per open
 * turn, using that turn's own nodeID/turnID/child seq.
 *
 * @param activeTurnNodeId the in-flight id when the state still has one; it is
 *   closed too even if its TURN node was not stored yet. Never the only source:
 *   the nodes are authoritative.
 * @param fallbackTurnId the id of a turn the Worker had not announced; used only
 *   when no TURN node is open, so a stop before TURN_STARTED still shows one
 *   cancelled row and cannot come back as RUNNING.
 */
internal fun closeOpenTurns(
    chatId: String,
    nodes: List<UiStateNode>,
    activeTurnNodeId: String?,
    fallbackTurnId: String?,
    atMs: Long,
): List<UiStateNode> {
    val ended = nodes.asSequence()
        .filter {
            it.kind == UiStateKind.STATUS &&
                (it.props["reason"] as? JsonString)?.value in CLOSING_TURN_REASONS
        }
        .map { it.nodeID.substringBefore("/event/") }
        .toSet()
    val open = LinkedHashSet<String>()
    nodes.filter { it.kind == UiStateKind.TURN }.forEach { turn ->
        if (turn.nodeID !in ended) open += turn.nodeID
    }
    activeTurnNodeId?.takeIf { it.isNotBlank() }?.let { id ->
        val turnNodeID = "session/$chatId/turn/$id"
        if (turnNodeID !in ended) open += turnNodeID
    }
    if (open.isEmpty() && fallbackTurnId != null) {
        val turnNodeID = "session/$chatId/turn/$fallbackTurnId"
        if (turnNodeID !in ended) open += turnNodeID
    }
    if (open.isEmpty()) return nodes
    val result = nodes.toMutableList()
    for (turnNodeID in open) {
        val turnId = turnNodeID.substringAfterLast("/turn/")
        // The old stop path also left a synthetic `<token>-stopped` cancelled row
        // next to the still-open real turn. Now that the real turn gets its own
        // end, drop that orphan so the person sees one 回合已取消, not two.
        val token = turnId.substringBeforeLast("-turn-", missingDelimiterValue = "")
        val syntheticTurn = if (token.isNotEmpty()) "$token-stopped" else "stopped"
        val orphan = "session/$chatId/turn/$syntheticTurn/"
        result.removeAll { node ->
            node.kind == UiStateKind.STATUS &&
                (node.props["reason"] as? JsonString)?.value == STOPPED_REASON &&
                node.nodeID.startsWith(orphan)
        }
        var seq = ((result.filter { it.nodeID == turnNodeID || it.nodeID.startsWith("$turnNodeID/") }
            .maxOfOrNull { it.seq } ?: -1) + 1).coerceAtLeast(0)
        while (result.any { it.nodeID == "$turnNodeID/event/$seq/turn-end" }) seq++
        result += UiStateNode(
            kind = UiStateKind.STATUS,
            nodeID = "$turnNodeID/event/$seq/turn-end",
            parentID = turnNodeID,
            sessionID = chatId,
            turnID = turnId,
            seq = seq,
            text = STOPPED_REASON,
            props = JsonObject(
                linkedMapOf(
                    "reason" to JsonString(STOPPED_REASON),
                    "detail" to JsonString(""),
                    "endedAtMs" to com.phonedsh.agentcore.JsonNumber(atMs.toString()),
                ),
            ),
        )
    }
    return result
}

/** The chat state after the person pressed 停止. */
internal fun ChatUiState.markStopped(atMs: Long): ChatUiState = copy(
    running = false,
    streaming = "",
    reasoningStreaming = "",
    activeTurnNodeId = null,
    pendingNodes = emptyList(),
    nodes = closeOpenTurns(
        chatId = chatId,
        nodes = nodes,
        activeTurnNodeId = activeTurnNodeId,
        fallbackTurnId = turnIdOf("stopped"),
        atMs = atMs,
    ),
    updatedAtMs = atMs,
)

/** A stored chat cannot reopen a turn this process is not running. */
internal fun ChatRecord.closeStaleTurns(): ChatRecord {
    val closed = closeOpenTurns(
        chatId = id,
        nodes = nodes,
        activeTurnNodeId = null,
        fallbackTurnId = null,
        atMs = updatedAtMs,
    )
    return if (closed == nodes) this else copy(nodes = closed)
}

/**
 * Repairs and persists one stored chat's stale open turns.
 *
 * [liveTurn] is the one exception: the conversation this process is really
 * running keeps its open turn untouched. Every other record is safe to close,
 * so a conversation damaged by the old stop path opens IDLE after an update.
 */
internal fun ChatSessionStore.repairStaleChatTurns(record: ChatRecord, liveTurn: Boolean): ChatRecord {
    if (liveTurn) return record
    val repaired = record.closeStaleTurns()
    if (repaired.nodes != record.nodes) save(repaired)
    return repaired
}

/** The transient fail-loud banner of a send failure; never persisted. */
private fun bannerNode(chatId: String, message: String, retryable: Boolean): UiStateNode = UiStateNode(
    kind = UiStateKind.FAIL_LOUD_BANNER,
    nodeID = bannerId(chatId),
    parentID = "session/$chatId",
    sessionID = chatId,
    turnID = SESSION_SCOPE_TURN_ID,
    seq = 0,
    surface = UiStateSurface.FAIL_LOUD_BANNER,
    text = message,
    props = JsonObject(
        linkedMapOf(
            "reason" to JsonString("error"),
            "retryable" to JsonBool(retryable),
            "dismissible" to JsonBool(true),
        ),
    ),
)

private fun bannerId(chatId: String): String = "session/$chatId/banner/send"

/**
 * Projects one Worker event into the node(s) the screen shows for it.
 *
 * @return the node, or `null` when this event has no row (a turn start, a usage
 *   fold, a completed turn end).
 */
internal fun chatNodeOf(
    chatId: String,
    turnToken: String,
    event: HostEvent,
    ordinal: Int,
): UiStateNode? {
    val workerTurn = event.turnId ?: FALLBACK_TURN_ID
    val turnId = if (turnToken.isEmpty()) workerTurn else "$turnToken-$workerTurn"
    val seq = event.seq?.toInt() ?: ordinal
    fun nodeID(slot: String): String = "session/$chatId/turn/$turnId/event/$seq/$slot"
    return when (event.kind) {
        HostEventKind.ASSISTANT_MESSAGE -> {
            val text = assistantTextOf(event)
            if (text.isBlank()) return null
            // The reasoning row is a real Worker payload too. Keep the complete
            // value when it fits the ui-state text bound, and say explicitly
            // when it does not; summary-only rendering loses the source and
            // makes a clipped value look complete.
            val reasoning = assistantReasoningOf(event)
            UiStateNode(
                kind = UiStateKind.BUBBLE,
                nodeID = nodeID("assistant-message"),
                parentID = "session/$chatId/turn/$turnId",
                sessionID = chatId,
                turnID = turnId,
                seq = seq,
                text = bounded(text),
                props = JsonObject(
                    linkedMapOf(
                        "role" to JsonString("assistant"),
                        "truncated" to JsonBool(text.length > TEXT_LIMIT),
                        "usage" to (event.data?.get("usage")
                            ?: (event.data?.get("message") as? JsonObject)?.get("usage")
                            ?: com.phonedsh.agentcore.JsonNull),
                        "fullReasoning" to JsonString(bounded(reasoning)),
                        "fullReasoningTruncated" to JsonBool(reasoning.length > TEXT_LIMIT),
                    ),
                ),
            )
        }

        HostEventKind.TOOL_CALL -> {
            val data = event.data ?: return null
            val name = (data["name"] as? JsonString)?.value.orEmpty()
            val callId = (data["callId"] as? JsonString)?.value
                ?: (data["call_id"] as? JsonString)?.value
                ?: nodeID("tool-call")
            UiStateNode(
                kind = UiStateKind.TOOL_ROW,
                nodeID = nodeID("tool-call"),
                parentID = "session/$chatId/turn/$turnId",
                sessionID = chatId,
                turnID = turnId,
                seq = seq,
                surface = UiStateSurface.TOOL_ROW,
                text = name.ifEmpty { null },
                props = JsonObject(
                    linkedMapOf(
                        "arguments" to (data["arguments"] ?: data["input"] ?: JsonString("")),
                        "callId" to JsonString(callId),
                        "name" to JsonString(name),
                        "phase" to JsonString("call"),
                        "state" to JsonString("running"),
                    ),
                ),
            )
        }

        HostEventKind.TOOL_RESULT -> {
            val data = event.data ?: return null
            val message = data["message"] as? JsonObject
            val callId = (data["callId"] as? JsonString)?.value
                ?: (data["call_id"] as? JsonString)?.value
                ?: (message?.get("toolCallId") as? JsonString)?.value
                ?: ((message?.get("source") as? JsonObject)?.get("callId") as? JsonString)?.value
                ?: nodeID("tool-result")
            val isError = (data["isError"] as? JsonBool)?.value
                ?: (message?.get("isError") as? JsonBool)?.value
                ?: (data["error"] != null && data["error"] != com.phonedsh.agentcore.JsonNull)
            val summary = toolResultTextOf(event)
            UiStateNode(
                kind = UiStateKind.TOOL_ROW,
                nodeID = nodeID("tool-result"),
                parentID = "session/$chatId/turn/$turnId",
                sessionID = chatId,
                turnID = turnId,
                seq = seq,
                surface = UiStateSurface.TOOL_ROW,
                text = bounded(summary.lineSequence().firstOrNull()?.trim().orEmpty())
                    .ifEmpty { null },
                props = JsonObject(
                    linkedMapOf(
                        "callId" to JsonString(callId),
                        "isError" to JsonBool(isError),
                        "phase" to JsonString("result"),
                        "state" to JsonString(if (isError) "error" else "ok"),
                        "body" to JsonString(bounded(summary)),
                        "meta" to (data["meta"] ?: com.phonedsh.agentcore.JsonNull),
                    ),
                ),
            )
        }

        HostEventKind.TURN_ENDED -> {
            val reason = event.turnEndReason ?: return null
            UiStateNode(
                kind = UiStateKind.STATUS,
                nodeID = nodeID("turn-end"),
                parentID = "session/$chatId/turn/$turnId",
                sessionID = chatId,
                turnID = turnId,
                seq = seq,
                text = reason,
                props = JsonObject(
                    linkedMapOf(
                        "reason" to JsonString(reason),
                        "detail" to JsonString(turnEndDetail(event).orEmpty()),
                        "endedAtMs" to (event.raw["time"] ?: com.phonedsh.agentcore.JsonNull),
                    ),
                ),
            )
        }

        else -> null
    }
}

/** Full reasoning text carried by this Worker's durable assistant payload. */
internal fun assistantReasoningOf(event: HostEvent): String =
    ((event.data?.get("message") as? JsonObject)?.get("content") as? JsonArray)?.values.orEmpty()
        .mapNotNull { raw ->
            (raw as? JsonObject)?.let { block ->
                if ((block["type"] as? JsonString)?.value == "reasoning") {
                    (block["text"] as? JsonString)?.value
                } else null
            }
        }
        .joinToString("\n")

/**
 * The durable row that says this conversation's earlier model context is gone.
 *
 * Written when the Worker answers `session/not-found` for the conversation's
 * stored session and the send has to open a new one. It is a `status` node, not
 * a banner: a transcript that still shows the earlier bubbles must say, in the
 * transcript itself, that the model can no longer see them — otherwise reopening
 * the chat presents two different histories as one (`ChatTurnRunner`).
 *
 * @param chatId this App's conversation id.
 * @param turnToken the send's turn prefix, so the row's id is unique per send.
 * @param message the user-facing sentence; also the row's `detail`.
 */
internal fun contextLostNode(chatId: String, turnToken: String, message: String): UiStateNode {
    val turnId = "${turnToken.ifEmpty { "context" }}-context-lost"
    return UiStateNode(
        kind = UiStateKind.STATUS,
        nodeID = "session/$chatId/turn/$turnId/event/0/context-lost",
        parentID = "session/$chatId/turn/$turnId",
        sessionID = chatId,
        turnID = turnId,
        seq = 0,
        text = message,
        props = JsonObject(
            linkedMapOf(
                "reason" to JsonString("context_lost"),
                "detail" to JsonString(message),
            ),
        ),
    )
}

/** The bubble the person's own message becomes, created before the Worker echoes it. */
internal fun userNodeOf(chatId: String, turnToken: String, text: String, ordinal: Int): UiStateNode {
    val turnId = if (turnToken.isEmpty()) "local-$ordinal" else "$turnToken-local"
    return UiStateNode(
        kind = UiStateKind.BUBBLE,
        nodeID = "session/$chatId/turn/$turnId/event/$ordinal/user-message",
        parentID = "session/$chatId/turn/$turnId",
        sessionID = chatId,
        turnID = turnId,
        seq = ordinal,
        text = bounded(text),
        props = JsonObject(
            linkedMapOf(
                "role" to JsonString("user"),
                "source" to JsonString("user"),
                "truncated" to JsonBool(text.length > TEXT_LIMIT),
            ),
        ),
    )
}

/** The text of one `tool_result` event: the Worker's own result, never a guess. */
internal fun toolResultTextOf(event: HostEvent): String {
    val data = event.data ?: return ""
    val message = data["message"] as? JsonObject
    val content = (message?.get("content") as? JsonArray)?.values.orEmpty()
        .mapNotNull { block -> (block as? JsonObject)?.let { entry ->
            if ((entry["type"] as? JsonString)?.value == "text") (entry["text"] as? JsonString)?.value else null
        } }.joinToString("\n")
    if (content.isNotEmpty()) return content
    ((data["error"] as? JsonObject)?.get("reason") as? JsonString)?.value?.let { return it }
    for (member in listOf("text", "result", "output", "summary")) {
        when (val value = data[member]) {
            is JsonString -> return value.value
            is JsonObject -> {
                (value["text"] as? JsonString)?.value?.let { return it }
                (value["content"] as? JsonArray)?.values?.forEach { block ->
                    (block as? JsonObject)?.let { entry ->
                        if ((entry["type"] as? JsonString)?.value == "text") {
                            (entry["text"] as? JsonString)?.value?.let { return it }
                        }
                    }
                }
            }

            is JsonArray -> {
                value.values.forEach { block ->
                    (block as? JsonObject)?.let { entry ->
                        if ((entry["type"] as? JsonString)?.value == "text") {
                            (entry["text"] as? JsonString)?.value?.let { return it }
                        }
                    }
                }
            }

            else -> Unit
        }
    }
    return ""
}

/** `turn/end.data.reason.cause` rendered as one token-free detail line. */
private fun turnEndDetail(event: HostEvent): String? {
    val reason = event.data?.get("reason") as? JsonObject ?: return null
    val cause = reason["cause"] as? JsonObject ?: return null
    val kind = (cause["kind"] as? JsonString)?.value
    val message = (cause["message"] as? JsonString)?.value
    return listOfNotNull(kind, message?.substringBefore('\n')?.take(240))
        .joinToString(": ")
        .ifBlank { null }
}

private fun bounded(text: String): String =
    if (text.length <= TEXT_LIMIT) text else text.take(TEXT_LIMIT)

/** The schema's `text.maxLength` (`ui-state-sequence.schema.json`). */
private const val TEXT_LIMIT: Int = 20_000

/** The session-scope turn id (`event-kinds.md` §1). */
private const val SESSION_SCOPE_TURN_ID: String = "-"

/** A turn id for an event the Worker did not tag with one. */
private const val FALLBACK_TURN_ID: String = "turn-0000"

/** The conversation id a never-started chat renders under. */
internal const val PENDING_CHAT_ID: String = "pending"

/** The host-read candidates behind the `@` menu, loaded once off the UI thread. */
internal data class ChatMentionFacts(
    val files: List<String> = emptyList(),
    val sessionTitles: List<String> = emptyList(),
)

/** How many workspace paths the `@` menu is allowed to carry into one screen state. */
internal const val CHAT_MENTION_FILE_LIMIT: Int = 200

/** How many session titles the `@` menu is allowed to carry into one screen state. */
internal const val CHAT_MENTION_SESSION_LIMIT: Int = 100

/**
 * The `@` menu's session candidates: the active conversation titles, in store
 * order, excluding the conversation that is already on screen.
 *
 * Pure so the host's IO read can be tested without a device: the caller supplies
 * the store rows and the current conversation id.
 */
internal fun chatMentionSessionTitles(
    records: List<ChatRecord>,
    currentChatId: String,
    limit: Int = CHAT_MENTION_SESSION_LIMIT,
): List<String> = records.asSequence()
    .filter { !it.archived && it.id != currentChatId }
    .map { it.title.trim() }
    .filter { it.isNotEmpty() }
    .distinct()
    .take(limit)
    .toList()

/**
 * True while [draft] is the in-place `@` menu's trigger token.
 *
 * This is the same shape `ChatScreenState` projects (`@` then a token with no
 * whitespace), kept on the host side so the candidates can be re-read exactly
 * when the menu opens. It is one boolean, not the draft itself: typing inside
 * the token must not re-walk the workspace on every character.
 */
internal fun isReferenceMenuOpen(draft: String): Boolean {
    val trimmed = draft.trim()
    if (!trimmed.startsWith("@")) return false
    return trimmed.drop(1).none { it.isWhitespace() }
}

/**
 * The state that must make the `@` menu re-read its candidates on the IO lane.
 *
 * The chat/session/settings keys alone leave the menu stale after a workspace
 * change that produces none of them: a 文件 page import writes
 * [FilesImportReceipt] on its own (it is not an attachment), an agent turn writes
 * files that only [artifactWrites] reports, and a file can change while the menu
 * is closed. `referenceMenuOpen` is the cheap catch-all: opening the trigger
 * re-reads once, so a deleted or externally changed file cannot survive in the
 * menu. The lists are compared structurally, so an unrelated recomposition does
 * not repeat the walk.
 */
internal fun chatMentionRefreshKey(
    chatId: String = "",
    attachments: List<ChatAttachment> = emptyList(),
    notice: String? = null,
    sessions: List<HostSessionRecord> = emptyList(),
    archivedSessions: List<HostSessionRecord> = emptyList(),
    settingsRevision: Int = 0,
    importReceipt: Pair<String, FilesImportReceipt>? = null,
    artifactWrites: List<String> = emptyList(),
    referenceMenuOpen: Boolean = false,
): List<Any?> = listOf(
    chatId,
    attachments,
    notice,
    sessions,
    archivedSessions,
    settingsRevision,
    importReceipt,
    artifactWrites,
    referenceMenuOpen,
)

/** The one turn-end reason that closes a turn without a visible row. */
private const val COMPLETED: String = "completed"

/** The status reason this lane writes when the person stops a turn. */
private const val STOPPED_REASON: String = "cancelled"

/** The reasons a STATUS row closes its turn (mirrors ChatScreenState). */
private val CLOSING_TURN_REASONS = setOf(
    "completed", "error", "failed", "cancelled", "aborted", "interrupted", "max_tokens", "max-tokens",
)
