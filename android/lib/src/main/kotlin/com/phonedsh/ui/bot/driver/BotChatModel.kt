// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.driver

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.attachments.BotAttachment
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.profile.BotFishAppearance
import com.phonedsh.bot.rows.BotActionResult
import com.phonedsh.bot.rows.BotApprovalDecision
import com.phonedsh.bot.rows.BotRow
import com.phonedsh.bot.rows.BotRowBatch
import com.phonedsh.bot.rows.BotRowBody
import com.phonedsh.bot.rows.BotRowBodyType
import com.phonedsh.bot.rows.BotRowKind
import com.phonedsh.bot.rows.BotRowProvenance
import com.phonedsh.bot.rows.BotUserAction
import com.phonedsh.bot.rows.BotUserActionKind
import com.phonedsh.bot.rows.eventIDOrNull
import com.phonedsh.bot.rows.reasonOrNull
import com.phonedsh.ui.bot.state.BotActionKeys
import com.phonedsh.ui.bot.state.BotActionState
import com.phonedsh.ui.bot.state.BotActionStateMachine
import com.phonedsh.ui.bot.state.BotActivity
import com.phonedsh.ui.bot.state.BotActivityCategory
import com.phonedsh.ui.bot.state.BotActivityLine
import com.phonedsh.ui.bot.state.BotActivityLineState
import com.phonedsh.ui.bot.state.BotActivityPhrases
import com.phonedsh.ui.bot.state.BotActivityStatus
import com.phonedsh.ui.bot.state.BotCardSettlement
import com.phonedsh.ui.bot.state.BotChecklistProgress
import com.phonedsh.ui.bot.state.BotHeaderPresence
import com.phonedsh.ui.bot.state.BotLiveTurn
import com.phonedsh.ui.bot.state.BotRuntimePresentation
import com.phonedsh.ui.bot.state.BotStreamingState
import com.phonedsh.ui.bot.state.BotTimers
import com.phonedsh.ui.bot.state.BotTranscriptState
import com.phonedsh.ui.bot.state.BotUiContext
import com.phonedsh.ui.bot.state.BotUiStateDerivation
import com.phonedsh.ui.bot.state.BotUiStateInput
import com.phonedsh.ui.bot.state.BotUICardContent
import com.phonedsh.ui.bot.state.BotUIRendering
import com.phonedsh.ui.bot.state.BotUIRowCodec
import com.phonedsh.ui.bot.state.BotUiStrings
import com.phonedsh.ui.bot.state.BotUIHistoryPage
import com.phonedsh.ui.bot.state.JsonSupport
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.UUID

/** One file picked in the composer, before the `chat` action is performed. */
public data class BotDraftAttachment(
    public val id: String,
    public val attachment: BotAttachment,
) {
    public companion object {
        /** A draft chip built from a fixture attachment (previews/tests). */
        public fun fixture(attachment: BotAttachment): BotDraftAttachment =
            BotDraftAttachment(id = attachment.path.ifEmpty { attachment.name }, attachment = attachment)
    }
}

/** One segment of the running turn (`BotLiveTurn.Segment`). */
public sealed interface BotLiveSegment {
    /** Committed assistant text of this turn. */
    public data class Text(public val text: String) : BotLiveSegment

    /** Tool call ids, in arrival order; never rendered in the transcript. */
    public data class Tools(public val callIDs: List<String>) : BotLiveSegment
}

/**
 * The running main-chat turn, rebuilt from live frames in arrival order
 * (`BotLiveTurn.swift:97-159`). Tool rows are kept only so the durable
 * projection can catch up; the transcript draws text and the activity line.
 */
public data class BotLiveChatTurn(
    public val turn: Int? = null,
    public val startedAt: Long? = null,
    public val segments: List<BotLiveSegment> = emptyList(),
    public val buffer: String = "",
    public val toolNames: List<String> = emptyList(),
    public val ended: Boolean = false,
    public val pollsSinceEnd: Int = 0,
) {
    /** Applies one DSH event to the display-order projection. */
    public fun apply(event: JsonObject): BotLiveChatTurn {
        val type = JsonSupport.string(event["type"]) ?: return this
        val data = (event["data"] as? JsonObject)?.members ?: emptyMap()
        val eventTurn = JsonSupport.long(data["turn"])?.toInt() ?: turn
        var next = copy(turn = eventTurn, toolNames = toolNames)
        when (type) {
            "turn/start" -> next = next.copy(
                startedAt = JsonSupport.long(event["time"])?.times(1000),
            )
            "step/start" -> next = next.copy(buffer = "")
            "assistant/message" -> {
                val content = ((data["message"] as? JsonObject)?.members?.get("content")
                    as? JsonArray)?.values ?: emptyList()
                val text = content.mapNotNull { block ->
                    val members = (block as? JsonObject)?.members ?: return@mapNotNull null
                    if (JsonSupport.string(members["type"]) == "text") {
                        JsonSupport.string(members["text"])
                    } else {
                        null
                    }
                }.joinToString("")
                if (text.trim().isNotEmpty()) {
                    next = next.copy(segments = segments + BotLiveSegment.Text(text))
                }
                next = next.copy(buffer = "")
            }
            "tool/call" -> {
                val callID = JsonSupport.string(data["callId"])
                val name = JsonSupport.string(data["name"])
                if (!name.isNullOrEmpty()) {
                    val names = if (name in toolNames) toolNames else toolNames + name
                    next = next.copy(toolNames = names)
                }
                if (!callID.isNullOrEmpty()) {
                    val last = next.segments.lastOrNull()
                    next = if (last is BotLiveSegment.Tools) {
                        next.copy(
                            segments = next.segments.dropLast(1) +
                                BotLiveSegment.Tools(last.callIDs + callID),
                        )
                    } else {
                        next.copy(segments = next.segments + BotLiveSegment.Tools(listOf(callID)))
                    }
                }
            }
            "turn/end" -> {
                next = if (next.buffer.trim().isNotEmpty()) {
                    next.copy(segments = next.segments + BotLiveSegment.Text(next.buffer))
                } else {
                    next
                }
                next = next.copy(buffer = "", ended = true)
            }
        }
        return next
    }
}

/**
 * Everything the stateless [com.phonedsh.ui.bot.page.chat.BotChatPage] draws.
 * The model is the only owner of the view-local state described by
 * `spec/ui/v1/bot/ui-state.md` §4; this value is derived, never mutated by the
 * page.
 */
public data class BotChatSnapshot(
    public val context: BotUiContext,
    public val botName: String,
    public val isMainBot: Boolean,
    public val appearance: BotFishAppearance,
    /** The transcript rows after `visibleRows`/`displayRows`, in order. */
    public val rows: List<BotRow>,
    public val settlements: Map<String, BotCardSettlement>,
    public val mutedCardIDs: Set<String>,
    public val checklistProgress: Map<String, BotChecklistProgress>,
    public val actionStates: Map<String, BotActionState>,
    public val pendingApprovalCount: Int,
    public val needsAttentionCount: Int,
    public val followingCount: Int,
    public val presence: BotHeaderPresence,
    public val fishState: BotFishLifecycle,
    public val reaction: com.phonedsh.ui.bot.state.BotFishReaction?,
    public val activityLine: BotActivityLine,
    public val live: BotLiveChatTurn?,
    public val streamingText: String?,
    public val loadingHistory: Boolean,
    public val hasMoreHistory: Boolean,
    public val runtimeNotice: String?,
    public val deepLinkError: String?,
    public val draft: String,
    public val draftAttachments: List<BotDraftAttachment>,
    public val attachmentNotice: String?,
    public val runningTurnID: String?,
    public val awaitingTurn: Boolean,
    public val scrollRequestID: String?,
) {
    /** True when the message area has no content (`bot.chat.empty`). */
    public val isEmpty: Boolean
        get() = rows.isEmpty() && live == null && streamingText == null
}

/** What a checklist card sends back as one normal `chat` message. */
private data class ChecklistSend(
    val rowID: String,
    val done: Int,
    val total: Int,
)

/**
 * The page-side state holder of the Bot chat (`BotChatModel.swift`).
 *
 * The durable projection is reached only through [BotChatDriver]. Every derived
 * value comes from `com.phonedsh.ui.bot.state` (P09): `BotTranscriptState` for
 * batch application, `BotActionStateMachine` for the UI-2 action rules,
 * `BotUiStateDerivation` for rows/cards/settlement/counts/header, and
 * `BotActivityLineState`/`BotFishProjection` for the line and the fish.
 *
 * @param clock the event clock in epoch milliseconds; tests pass a pinned
 *   clock and call [tick] instead of waiting on wall time.
 * @param scope the page's coroutine scope; the page closes it in `DisposableEffect`.
 */
public class BotChatModel(
    public val context: BotUiContext,
    private val driver: BotChatDriver? = null,
    initialRows: List<BotRow> = emptyList(),
    private val fixtureHistory: List<BotRow> = emptyList(),
    private val fixtureActions: Boolean = false,
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    botName: String = context.botName,
    appearance: BotFishAppearance = BotFishAppearance.CLASSIC,
    isMainBot: Boolean = false,
) {
    private var transcript: BotTranscriptState = BotTranscriptState(
        rows = initialRows.sortedBy { it.seq },
        hasMoreHistory = driver != null || fixtureHistory.isNotEmpty(),
    )
    private var loadingHistory: Boolean = false
    private var actionMachine: BotActionStateMachine = BotActionStateMachine()
    private val checklistProgress: MutableMap<String, BotChecklistProgress> = LinkedHashMap()
    private var runtimePresentation: BotRuntimePresentation = BotRuntimePresentation()
    private var livePresentation: BotRuntimePresentation? = null
    private var live: BotLiveChatTurn? = null
    private var pendingDelta: String = ""
    private var streamingText: String? = null
    private var runningTurnID: String? = null
    private var awaitingTurn: Boolean = false
    private var lineSuppressed: Boolean = false
    private var idleSleeping: Boolean = false
    private var reaction: com.phonedsh.ui.bot.state.BotFishReaction? = null
    private var deepLinkError: String? = null
    private var draft: String = ""
    private val draftAttachments: MutableList<BotDraftAttachment> = mutableListOf()
    private var attachmentNotice: String? = null
    private var scrollRequestID: String? = null
    private var botName: String = botName
    private var appearance: BotFishAppearance = appearance
    private var isMainBot: Boolean = isMainBot
    private var pageActive: Boolean = true
    private var nowMs: Long = clock()
    private var sequence: Long = initialRows.maxOfOrNull { it.seq } ?: 0L
    private val lineState: BotActivityLineState = BotActivityLineState()
    private val cancelledTurnIDs: MutableSet<String> = mutableSetOf()
    private val fixtureResults: MutableMap<String, String> = LinkedHashMap()
    private var fixtureAccepted: Int = 0
    private var pendingChecklist: ChecklistSend? = null
    private var watchJob: Job? = null
    private var presentationJob: Job? = null
    private var liveJob: Job? = null
    private var deltaFlush: Job? = null
    private var noticeExpiry: Job? = null
    private var awaitingTimeout: Job? = null
    private var sleepJob: Job? = null

    private val mutableState: MutableStateFlow<BotChatSnapshot> =
        MutableStateFlow(buildSnapshot(nowMs))
    private val _state: StateFlow<BotChatSnapshot> = mutableState.asStateFlow()

    /** The one value the page reads; a new value after every change. */
    public val state: StateFlow<BotChatSnapshot> get() = _state

    /** The batch cursor the next `watch` starts from. */
    public val watchCursor: Long get() = transcript.watchCursor

    /** The row-id anchor the next history page ends before. */
    public val historyCursor: String? get() = transcript.historyCursor

    /** Starts the three driver flows if a driver exists and the page is active. */
    public fun start() {
        val source = driver ?: return
        if (!pageActive) return
        if (watchJob?.isActive != true) launchWatchLoop(source)
        if (presentationJob?.isActive != true) {
            presentationJob = scope.launch {
                try {
                    source.presentation().collect { presentation ->
                        applyDurablePresentation(presentation)
                        tick()
                    }
                } catch (error: Exception) {
                    setRuntimeNotice(
                        BotUiStrings.format(
                            "error.watchFailed",
                            "error" to (error.message ?: error.toString()),
                        ),
                    )
                    tick()
                }
            }
        }
        if (liveJob?.isActive != true) {
            liveJob = scope.launch {
                source.liveFrames().collect { frame ->
                    if (pageActive) receive(frame)
                }
            }
        }
    }

    /**
     * The watch loop: apply one batch, then read the finished-turn processes.
     * A failed subscription reports the header problem and retries at the
     * frozen poll interval while the page stays active (`BotChatModel.swift:914-936`).
     */
    private fun launchWatchLoop(source: BotChatDriver) {
        watchJob = scope.launch {
            while (pageActive) {
                var failed = false
                try {
                    source.watch(transcript.watchCursor).collect { batch ->
                        applyBatch(batch)
                        runCatching { source.turnProcesses() }
                        settleLive()
                        tick()
                    }
                } catch (error: Exception) {
                    failed = true
                    setRuntimeNotice(
                        BotUiStrings.format(
                            "error.watchFailed",
                            "error" to (error.message ?: error.toString()),
                        ),
                    )
                    tick()
                }
                if (!failed || !pageActive) return@launch
                delay(BotTimers.WATCH_POLL)
            }
        }
    }

    /** Pauses/resumes the page (`ui-state.md` §4.11). */
    public fun setPageActive(active: Boolean) {
        if (pageActive == active) return
        pageActive = active
        if (active) {
            start()
            if (transcript.runtimeNotice != null) armNoticeExpiry()
            if (awaitingTurn) markAwaitingTurn()
            scheduleIdleSleep()
            tick()
            return
        }
        watchJob?.cancel()
        watchJob = null
        presentationJob?.cancel()
        presentationJob = null
        liveJob?.cancel()
        liveJob = null
        deltaFlush?.cancel()
        deltaFlush = null
        noticeExpiry?.cancel()
        noticeExpiry = null
        awaitingTimeout?.cancel()
        awaitingTimeout = null
        sleepJob?.cancel()
        sleepJob = null
        pendingDelta = ""
        streamingText = null
        live = null
        livePresentation = null
        reaction = null
        tick()
    }

    /** Mirrors the profile center's name/appearance into the page. */
    public fun updateProfile(name: String, appearance: BotFishAppearance) {
        botName = name
        this.appearance = appearance
        tick()
    }

    public fun setMainBot(isMain: Boolean) {
        if (isMainBot == isMain) return
        isMainBot = isMain
        tick()
    }

    /** The composer's draft text. */
    public fun setDraft(text: String) {
        if (draft == text) return
        draft = text
        noteInteraction()
        tick()
    }

    /** Adds one already-readable attachment chip to the draft. */
    public fun addDraftAttachment(attachment: BotAttachment): Boolean {
        if (draftAttachments.size >= com.phonedsh.bot.attachments.BotAttachmentPolicy.MAX_COUNT) {
            return false
        }
        draftAttachments.add(BotDraftAttachment.fixture(attachment))
        attachmentNotice = null
        noteInteraction()
        tick()
        return true
    }

    public fun removeDraftAttachment(index: Int) {
        if (index !in draftAttachments.indices) return
        draftAttachments.removeAt(index)
        noteInteraction()
        tick()
    }

    public fun dismissAttachmentNotice() {
        attachmentNotice = null
        tick()
    }

    /**
     * Any touch, keystroke or send wakes an idle fish and restarts the
     * 60-second sleep clock (`BotChatModel.swift:772-783`).
     */
    public fun noteInteraction() {
        if (idleSleeping) idleSleeping = false
        if (runningTurnID == null && live == null) {
            scheduleIdleSleep(reset = true)
        } else {
            sleepJob?.cancel()
            sleepJob = null
        }
        tick()
    }

    /** Sends the current draft and attachments as one `chat` action. */
    public fun send() {
        send(
            text = draft,
            attachments = draftAttachments.map { it.attachment },
        )
    }

    /**
     * Appends the local optimistic row, auto-denies every still-pending
     * approval, then performs the single `chat` action.
     */
    public fun send(text: String, attachments: List<BotAttachment> = emptyList()) {
        val trimmed = text.trim()
        if (trimmed.isEmpty() && attachments.isEmpty()) return
        noteInteraction()
        clearRuntimeNotice()
        draft = ""
        draftAttachments.clear()
        attachmentNotice = null
        val nonce = UUID.randomUUID().toString()
        val localID = "${BotTranscriptState.LOCAL_PREFIX}$nonce"
        val rows = LinkedHashMap<String, JsonValue>()
        rows["text"] = JsonString(trimmed)
        if (attachments.isNotEmpty()) {
            rows["attachments"] = JsonArray(attachments.map { it.toJson() })
        }
        sequence += 1
        val local = BotRow(
            id = localID,
            botID = context.botID,
            seq = sequence,
            updatedSeq = sequence,
            kind = BotRowKind.SEND_MESSAGE,
            role = "user",
            body = BotRowBody(
                type = BotRowBodyType.TEXT,
                additionalProperties = rows,
            ),
            provenance = BotRowProvenance(
                eventIDs = listOf("local:$nonce"),
                trust = BotRowProvenance.OWNER_DIRECT,
                tainted = false,
            ),
            streaming = false,
            createdAt = clock(),
        )
        upsertRow(local)

        val awaiting = actionMachine.awaitingApprovals(rowsOf(transcript))
        val autoDeclines = awaiting.filter { approvalAction(it, BotApprovalDecision.DENY) != null }
        actionMachine = actionMachine.markAwaitingApprovalsPending(rowsOf(transcript))

        if (runningTurnID == null) markAwaitingTurn()
        if (driver == null && fixtureActions && runningTurnID == null) beginTurn("fixture-turn")
        val checklist = pendingChecklist

        scope.launch {
            for (row in autoDeclines) autoDecline(row)
            performChat(
                nonce = nonce,
                text = trimmed,
                attachments = attachments,
                localID = localID,
                checklist = checklist,
            )
        }
        tick()
    }

    /** Sends a checklist's checked result as a normal chat message. */
    public fun sendChecklist(rowID: String, done: Int, total: Int, message: String) {
        if (message.trim().isEmpty()) return
        val progress = checklistProgress[rowID]
        if (progress?.sent == true || progress?.sending == true) return
        checklistProgress[rowID] = BotChecklistProgress(done, total, sending = true, sent = false)
        pendingChecklist = ChecklistSend(rowID, done, total)
        send(text = message)
        tick()
    }

    /** Records a checklist's local toggles so a skipped card shows its count. */
    public fun noteChecklistProgress(rowID: String, done: Int, total: Int) {
        val progress = checklistProgress[rowID]
        if (progress?.sent == true || progress?.sending == true) return
        checklistProgress[rowID] = BotChecklistProgress(done, total, sending = false, sent = false)
        tick()
    }

    /** `cardAnswer`: a second tap while pending/accepted is ignored. */
    public fun answer(rowID: String, optionID: String) {
        val row = rowsOf(transcript).firstOrNull { it.id == rowID } ?: return
        val next = actionMachine.beginAnswer(row, optionID, mutedCardIDs()) ?: return
        actionMachine = next
        val action = BotUserAction(
            nonce = UUID.randomUUID().toString(),
            botID = row.botID,
            kind = BotUserActionKind.CARD_ANSWER,
            cardID = row.id,
            optionID = optionID,
        )
        scope.launch { perform(action, BotActionKeys.card(row.id), localRowID = null) }
    }

    /** `cardDismiss`; UI-2 makes a failed dismiss retryable. */
    public fun dismiss(rowID: String) {
        val row = rowsOf(transcript).firstOrNull { it.id == rowID } ?: return
        val next = actionMachine.beginDismiss(row, mutedCardIDs()) ?: return
        actionMachine = next
        val action = BotUserAction(
            nonce = UUID.randomUUID().toString(),
            botID = row.botID,
            kind = BotUserActionKind.CARD_DISMISS,
            cardID = row.id,
        )
        scope.launch { perform(action, BotActionKeys.dismiss(row.id), localRowID = null) }
    }

    /** `approval`: allow once / always / deny. */
    public fun decide(rowID: String, decision: BotApprovalDecision) {
        val row = rowsOf(transcript).firstOrNull { it.id == rowID } ?: return
        val next = actionMachine.beginApproval(row) ?: return
        val action = approvalAction(row, decision) ?: return
        actionMachine = next
        scope.launch { perform(action, BotActionKeys.approval(row.id), localRowID = null) }
    }

    /** Stops the running turn and hides the line while the live text stays. */
    public fun stop() {
        clearAwaitingTurn()
        lineSuppressed = true
        val turnID = runningTurnID ?: run {
            tick()
            return
        }
        cancelledTurnIDs.add(turnID)
        runningTurnID = null
        streamingText = null
        deltaFlush?.cancel()
        deltaFlush = null
        scheduleIdleSleep(reset = true)
        scope.launch { driver?.stopCurrentTurn(turnID) }
        tick()
    }

    /** Marks a turn started (the host's `turn/start`). */
    public fun beginTurn(turnID: String) {
        clearAwaitingTurn()
        lineSuppressed = false
        cancelledTurnIDs.remove(turnID)
        runningTurnID = turnID
        streamingText = null
        sleepJob?.cancel()
        sleepJob = null
        idleSleeping = false
        tick()
    }

    /** Loads one older history page before the current anchor. */
    public fun loadHistory() {
        if (!transcript.hasMoreHistory || loadingHistory) return
        loadingHistory = true
        tick()
        scope.launch {
            try {
                val page: BotUIHistoryPage = when {
                    driver != null -> {
                        val anchor = transcript.historyCursor
                            ?: rowsOf(transcript).firstOrNull {
                                !it.id.startsWith(BotTranscriptState.LOCAL_PREFIX)
                            }?.id
                        driver.history(anchor, BotTranscriptState.HISTORY_PAGE_SIZE)
                    }
                    fixtureActions || fixtureHistory.isNotEmpty() -> {
                        val page = fixtureHistory.take(BotTranscriptState.HISTORY_PAGE_SIZE)
                        BotUIHistoryPage(page, page.firstOrNull()?.id, false)
                    }
                    else -> throw IllegalStateException(BotUiStrings.ERROR_RUNTIMEUNAVAILABLE)
                }
                val noticeBefore = transcript.runtimeNotice
                transcript = transcript.apply(
                    BotRowBatch(
                        rows = page.rows,
                        deletes = emptyList(),
                        cursor = transcript.watchCursor,
                        reset = false,
                    ),
                )
                transcript = transcript.copy(
                    rows = transcript.rows.sortedBy { it.seq },
                    runtimeNotice = noticeBefore,
                    historyCursor = page.nextCursor,
                    hasMoreHistory = page.hasMore,
                )
            } catch (error: Exception) {
                setRuntimeNotice(
                    BotUiStrings.format("error.historyFailed", "error" to
                        (error.message ?: error.toString())),
                )
            } finally {
                loadingHistory = false
                tick()
            }
        }
    }

    /** Resolves a row deep link; a routine link is the host hub's destination. */
    public fun openDeepLink(botID: String, rowID: String): Boolean {
        if (botID != context.botID || rowsOf(transcript).none { it.id == rowID }) {
            deepLinkError = BotUiStrings.CHAT_DEEPLINK_UNAVAILABLE
            tick()
            return false
        }
        deepLinkError = null
        scrollRequestID = rowID
        tick()
        return true
    }

    public fun consumeScrollRequest() {
        if (scrollRequestID == null) return
        scrollRequestID = null
        tick()
    }

    public fun dismissDeepLinkError() {
        deepLinkError = null
        tick()
    }

    /** Reports a host/live/history/action failure on the header problem line. */
    public fun showProblem(text: String) {
        setRuntimeNotice(text)
        tick()
    }

    /** Clears the view-local problem text (the next send does this too). */
    public fun dismissProblem() {
        clearRuntimeNotice()
        tick()
    }

    /** Applies the durable presentation (page open and every watch poll). */
    public fun applyPresentation(presentation: BotRuntimePresentation) {
        applyDurablePresentation(presentation)
        tick()
    }

    /** Advances the activity-line clock (rotation, pending switch, minute suffix). */
    public fun tick(now: Long = clock()) {
        nowMs = now
        lineState.tick(now)
        mutableState.value = buildSnapshot(now)
    }

    /** Cancels every model job. The page calls this in `DisposableEffect`. */
    public fun close() {
        watchJob?.cancel()
        presentationJob?.cancel()
        liveJob?.cancel()
        deltaFlush?.cancel()
        noticeExpiry?.cancel()
        awaitingTimeout?.cancel()
        sleepJob?.cancel()
    }

    // --------------------------------------------------------------- projection

    private fun buildSnapshot(now: Long): BotChatSnapshot {
        val currentRows = rowsOf(transcript)
        val checklist = checklistProgress.toMap()
        val input = BotUiStateInput(
            context = BotUiContext(context.botID, botName, context.followingCount),
            rows = currentRows,
            actionStates = actionMachine.states,
            dismissedCardIDs = actionMachine.dismissedCardIDs,
            autoDeclinedApprovalIDs = actionMachine.autoDeclinedApprovalIDs,
            answeredOptionIDs = actionMachine.answeredOptionIDs,
            checklistProgress = checklist,
            runtimePresentation = runtimePresentation,
            livePresentation = livePresentation,
            live = live?.let { BotLiveTurn(it.turn, it.ended) },
            runningTurnID = runningTurnID,
            awaitingTurn = awaitingTurn,
            lineSuppressed = lineSuppressed,
            idleSleeping = idleSleeping,
            streaming = BotStreamingState(
                pendingDelta = pendingDelta,
                streamingText = streamingText,
                liveBuffer = live?.buffer ?: "",
            ),
            running = runningTurnID != null || live != null,
            problem = transcript.runtimeNotice,
            now = now,
        )
        val derived = BotUiStateDerivation.derive(input)
        lineState.receive(derived.header.line, now)
        val visible = BotUiStateDerivation.visibleRows(currentRows).associateBy { it.id }
        val displayRows = derived.displayRowIDs.mapNotNull { visible[it] }
        return BotChatSnapshot(
            context = context.copy(botName = botName),
            botName = botName,
            isMainBot = isMainBot,
            appearance = appearance,
            rows = displayRows,
            settlements = derived.settlements.associate { it.rowID to it.settlement },
            mutedCardIDs = derived.mutedCardIDs.toSet(),
            checklistProgress = checklist,
            actionStates = actionMachine.states,
            pendingApprovalCount = derived.pendingApprovalCount,
            needsAttentionCount = derived.needsAttentionCount,
            followingCount = derived.followingCount,
            presence = derived.header,
            fishState = derived.fishState,
            reaction = reaction,
            activityLine = BotActivityLine(lineState.text, lineState.nextDeadline),
            live = live,
            streamingText = streamingText,
            loadingHistory = loadingHistory,
            hasMoreHistory = transcript.hasMoreHistory,
            runtimeNotice = transcript.runtimeNotice,
            deepLinkError = deepLinkError,
            draft = draft,
            draftAttachments = draftAttachments.toList(),
            attachmentNotice = attachmentNotice,
            runningTurnID = runningTurnID,
            awaitingTurn = awaitingTurn,
            scrollRequestID = scrollRequestID,
        )
    }

    private fun rowsOf(state: BotTranscriptState): List<BotRow> = state.rows

    private fun mutedCardIDs(): Set<String> = com.phonedsh.ui.bot.state.BotMutedCards.ids(
        BotUiStateDerivation.visibleRows(rowsOf(transcript)),
        actionMachine.states,
        checklistProgress,
    ).toSet()

    private fun upsertRow(row: BotRow) {
        transcript = transcript.copy(rows = transcript.rows + row)
    }

    private fun replaceRow(rowID: String, transform: (BotRow) -> BotRow) {
        transcript = transcript.copy(
            rows = transcript.rows.map { if (it.id == rowID) transform(it) else it },
        )
    }

    // -------------------------------------------------------------- driver apply

    /** Applies one watch batch in the frozen `BotTranscriptState` order. */
    private fun applyBatch(batch: BotRowBatch) {
        val noticeBefore = transcript.runtimeNotice
        transcript = transcript.apply(batch)
        sequence = maxOf(sequence, transcript.rows.maxOfOrNull { it.seq } ?: 0L)
        if (transcript.runtimeNotice != null && transcript.runtimeNotice != noticeBefore) {
            armNoticeExpiry()
        }
    }

    private fun applyDurablePresentation(presentation: BotRuntimePresentation) {
        runtimePresentation = presentation
        if (live == null) reaction = presentation.reaction
        if (live != null) {
            tick()
            return
        }
        if (presentation.runningTurnID != null) {
            val turn = presentation.runningTurnID
            if (runningTurnID == null && turn !in cancelledTurnIDs) runningTurnID = turn
            clearAwaitingTurn()
        } else if (runningTurnID != null && runningTurnID !in cancelledTurnIDs) {
            runningTurnID = null
            streamingText = null
            deltaFlush?.cancel()
            deltaFlush = null
        }
        scheduleIdleSleep()
    }

    /** One live frame (`BotChatModel.receive(_:)`, `:971-1021`). */
    private fun receive(frame: BotLiveFrame) {
        when (frame) {
            BotLiveFrame.StreamStart -> {
                pendingDelta = ""
                if (live == null) lineSuppressed = false
                live = (live ?: BotLiveChatTurn()).copy(buffer = "")
            }
            is BotLiveFrame.TextDelta -> {
                if (live == null) {
                    lineSuppressed = false
                    live = BotLiveChatTurn()
                }
                pendingDelta += frame.text
                if (deltaFlush == null) {
                    deltaFlush = scope.launch {
                        delay(BotTimers.LIVE_TEXT_FLUSH)
                        flushDelta()
                    }
                }
            }
            is BotLiveFrame.Event -> {
                val event = frame.event
                val type = JsonSupport.string(event["type"]) ?: ""
                if (type == "turn/start") {
                    pendingDelta = ""
                    deltaFlush?.cancel()
                    deltaFlush = null
                    lineSuppressed = false
                    live = BotLiveChatTurn()
                    sleepJob?.cancel()
                    sleepJob = null
                    idleSleeping = false
                } else {
                    flushDelta()
                    if (live == null) lineSuppressed = false
                }
                val next = (live ?: BotLiveChatTurn()).apply(event)
                live = next
                when (type) {
                    "turn/start" -> {
                        runningTurnID = next.turn?.let { "turn-$it" } ?: runningTurnID
                        streamingText = null
                    }
                    "turn/end" -> {
                        runningTurnID = null
                        scheduleIdleSleep(reset = true)
                    }
                    "tool/call" -> {
                        val name = JsonSupport.string(
                            (event["data"] as? JsonObject)?.members?.get("name")) ?: ""
                        if (name.isNotEmpty()) {
                            val arguments = (event["data"] as? JsonObject)?.get("arguments")
                            val args = when (arguments) {
                                is JsonObject -> arguments.members
                                is JsonString -> runCatching { JsonValue.parse(arguments.value) as? JsonObject }
                                    .getOrNull()?.members.orEmpty()
                                else -> emptyMap()
                            }
                            val activity = BotActivityPhrases.toolActivity(name, args)
                            livePresentation = BotRuntimePresentation(
                                fishState = runtimePresentation.fishState,
                                runningTurnID = runningTurnID,
                                activity = BotActivity(
                                    status = BotActivityStatus.TOOL_RUNNING,
                                    detail = activity.text,
                                    category = activity.category,
                                    startedAt = clock(),
                                ),
                            )
                        }
                    }
                    "assistant/message", "step/start" -> {
                        livePresentation = BotRuntimePresentation(
                            fishState = runtimePresentation.fishState,
                            runningTurnID = runningTurnID,
                            activity = BotActivity(
                                status = BotActivityStatus.STREAMING,
                                detail = "",
                                category = BotActivityCategory.REPLYING,
                                startedAt = clock(),
                            ),
                        )
                    }
                }
            }
        }
        if (runningTurnID != null || live != null) clearAwaitingTurn()
        tick()
    }

    private fun flushDelta() {
        deltaFlush?.cancel()
        deltaFlush = null
        val turn = live
        if (pendingDelta.isEmpty() || turn == null || turn.ended) {
            pendingDelta = ""
            return
        }
        live = turn.copy(buffer = turn.buffer + pendingDelta)
        pendingDelta = ""
        tick()
    }

    /** After `turn/end` the live view yields to the durable rows (`:1062-1074`). */
    private fun settleLive() {
        val turn = live ?: return
        if (!turn.ended) return
        val next = turn.copy(pollsSinceEnd = turn.pollsSinceEnd + 1)
        val committed = next.turn?.let { number ->
            rowsOf(transcript).any { row ->
                row.role == "assistant" &&
                    row.body.type == BotRowBodyType.TEXT &&
                    JsonSupport.long(row.body["turn"]) == number.toLong()
            }
        } ?: true
        live = if ((committed && next.pollsSinceEnd >= 2) || next.pollsSinceEnd >= 4) {
            scheduleIdleSleep(reset = true)
            null
        } else {
            next
        }
    }

    // ------------------------------------------------------------------- actions

    private suspend fun performChat(
        nonce: String,
        text: String,
        attachments: List<BotAttachment>,
        localID: String,
        checklist: ChecklistSend?,
    ) {
        val action = BotUserAction(
            nonce = nonce,
            botID = context.botID,
            kind = BotUserActionKind.CHAT,
            text = text,
            attachments = attachments.ifEmpty { null },
        )
        perform(action, BotActionKeys.chat(localID), localRowID = localID)
        if (checklist != null) {
            val accepted = actionMachine.state(BotActionKeys.chat(localID)) is BotActionState.Accepted
            checklistProgress[checklist.rowID] = if (accepted) {
                BotChecklistProgress(checklist.done, checklist.total, sending = false, sent = true)
            } else {
                BotChecklistProgress(checklist.done, checklist.total, sending = false, sent = false)
            }
            pendingChecklist = null
            tick()
        }
    }

    private suspend fun perform(action: BotUserAction, key: String, localRowID: String?) {
            val result: BotActionResult = when {
                driver != null -> driver.perform(action)
                fixtureActions -> fixturePerform(action)
                else -> BotActionResult.Rejected(BotUiStrings.ERROR_RUNTIMEUNAVAILABLE)
            }
            actionMachine = actionMachine.finish(key, result)
            val eventID = result.eventIDOrNull
            if (eventID != null) {
                if (localRowID != null) {
                    replaceRow(localRowID) { row ->
                        row.copy(provenance = row.provenance.copy(eventIDs = listOf(eventID)))
                    }
                }
                val decision = action.decision
                val approvalID = action.approvalID
                if (action.kind == BotUserActionKind.APPROVAL &&
                    decision != null && approvalID != null
                ) {
                    applyApprovalDecision(approvalID, decision)
                }
            } else {
                if (localRowID != null) {
                    transcript = transcript.copy(
                        rows = transcript.rows.filterNot { it.id == localRowID },
                    )
                }
                clearAwaitingTurn()
                setRuntimeNotice(result.reasonOrNull ?: ACTION_NOT_COMPLETED)
            }
            tick()
    }

    private suspend fun autoDecline(row: BotRow) {
        val key = BotActionKeys.approval(row.id)
        if (actionMachine.state(key) != BotActionState.Pending) return
        val action = approvalAction(row, BotApprovalDecision.DENY) ?: return
        val result: BotActionResult = when {
            driver != null -> driver.perform(action)
            fixtureActions -> fixturePerform(action)
            else -> BotActionResult.Rejected(BotUiStrings.ERROR_RUNTIMEUNAVAILABLE)
        }
        actionMachine = actionMachine.finishAutoDecline(row.id, result)
        val approvalID = action.approvalID
        if (result.eventIDOrNull != null && approvalID != null) {
            applyApprovalDecision(approvalID, BotApprovalDecision.DENY)
        }
        tick()
    }

    private fun approvalAction(
        row: BotRow,
        decision: BotApprovalDecision,
    ): BotUserAction? {
        val ask = (row.body["ask"] as? JsonObject)?.members ?: emptyMap()
        val approvalID = JsonSupport.firstString(
            row.body.additionalProperties, "approvalID", "requestId", "id",
        ) ?: JsonSupport.string(ask["requestId"]) ?: return null
        val digest = JsonSupport.string(row.body["digest"]) ?: return null
        return BotUserAction(
            nonce = UUID.randomUUID().toString(),
            botID = row.botID,
            kind = BotUserActionKind.APPROVAL,
            approvalID = approvalID,
            decision = decision,
            digest = digest,
        )
    }

    private fun applyApprovalDecision(approvalID: String, decision: BotApprovalDecision) {
        val row = rowsOf(transcript).firstOrNull { candidate ->
            val ask = (candidate.body["ask"] as? JsonObject)?.members ?: emptyMap()
            (JsonSupport.firstString(
                candidate.body.additionalProperties, "approvalID", "requestId", "id",
            ) ?: JsonSupport.string(ask["requestId"])) == approvalID
        } ?: return
        val status = when (decision) {
            BotApprovalDecision.ALLOW_ONCE -> "allowed"
            BotApprovalDecision.ALWAYS -> "always"
            BotApprovalDecision.DENY -> "denied"
        }
        replaceRow(row.id) { current ->
            current.copy(
                body = current.body.with("status", JsonString(status)),
                updatedSeq = current.updatedSeq + 1,
            )
        }
    }

    private fun fixturePerform(action: BotUserAction): BotActionResult {
        fixtureResults[action.nonce]?.let { return BotActionResult.Duplicate(it) }
        fixtureAccepted += 1
        val eventID = "evt-action-$fixtureAccepted"
        fixtureResults[action.nonce] = eventID
        return BotActionResult.Accepted(eventID)
    }

    // -------------------------------------------------------------------- timers

    private fun setRuntimeNotice(text: String?) {
        transcript = transcript.copy(runtimeNotice = text)
        if (text != null) armNoticeExpiry() else {
            noticeExpiry?.cancel()
            noticeExpiry = null
        }
    }

    private fun clearRuntimeNotice() {
        if (transcript.runtimeNotice == null) return
        setRuntimeNotice(null)
    }

    private fun armNoticeExpiry() {
        noticeExpiry?.cancel()
        noticeExpiry = scope.launch {
            delay(BotTimers.RUNTIME_NOTICE)
            transcript = transcript.copy(runtimeNotice = null)
            tick()
        }
    }

    private fun markAwaitingTurn() {
        lineSuppressed = false
        awaitingTurn = true
        awaitingTimeout?.cancel()
        awaitingTimeout = scope.launch {
            delay(BotTimers.AWAITING_TURN)
            awaitingTurn = false
            tick()
        }
    }

    private fun clearAwaitingTurn() {
        awaitingTimeout?.cancel()
        awaitingTimeout = null
        if (!awaitingTurn) return
        awaitingTurn = false
        tick()
    }

    private fun scheduleIdleSleep(reset: Boolean = false) {
        if (reset) {
            sleepJob?.cancel()
            sleepJob = null
        } else if (sleepJob != null) {
            return
        }
        if (runningTurnID != null || live != null ||
            actionMachine.awaitingApprovals(rowsOf(transcript)).isNotEmpty()
        ) {
            sleepJob?.cancel()
            sleepJob = null
            return
        }
        sleepJob = scope.launch {
            delay(BotTimers.IDLE_SLEEP)
            if (runningTurnID == null && live == null &&
                actionMachine.awaitingApprovals(rowsOf(transcript)).isEmpty()
            ) {
                idleSleeping = true
                tick()
            }
        }
    }

    /** Convenience for a driver-less preview: parse fixture rows through the P09 decoder. */
    public companion object {
        /** Decodes fixture rows exactly as the driver does. */
        public fun rowsFromJson(values: List<JsonValue>): List<BotRow> =
            BotUIRowCodec.fromJsonList(values)
    }
}

/** `BotChatModel.swift:1140`; the fallback when a result carries no reason. */
private const val ACTION_NOT_COMPLETED: String = "动作未完成"
