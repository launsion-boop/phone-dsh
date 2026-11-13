// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.rows.BotRow
import com.phonedsh.bot.rows.BotRowBodyType
import java.time.Instant
import java.time.ZoneId

/** The header's one of four phases (`ui-state.md` §4.6). */
public enum class BotHeaderPhase(public val wire: String) {
    IDLE("idle"),
    PROBLEM("problem"),
    WORKING("working"),
    WAITING_FOR_YOU("waitingForYou"),
}

/** The header fish motion. */
public enum class BotHeaderMotion(public val wire: String) {
    STANDARD("standard"),
    LIVELY("lively"),
}

/** The semantic settlement glyph id; the platform maps it to its icon. */
public enum class BotSettlementGlyph(public val wire: String) {
    XMARK_CIRCLE("xmark.circle"),
    CHECKMARK_CIRCLE("checkmark.circle"),
    CHECKMARK_CIRCLE_FILL("checkmark.circle.fill"),
    MINUS_CIRCLE("minus.circle"),
}

/** The settlement tone. */
public enum class BotSettlementTone(public val wire: String) {
    NEUTRAL("neutral"),
    SUCCESS("success"),
}

/** The one-line summary an interactive card collapses to (`BotCardSettlement`). */
public data class BotCardSettlement(
    public val glyph: BotSettlementGlyph,
    public val title: String,
    public val detail: String?,
    public val tone: BotSettlementTone = BotSettlementTone.NEUTRAL,
    public val monospacedDetail: Boolean = false,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "glyph" to JsonString(glyph.wire),
        "title" to JsonString(title),
        "detail" to (detail?.let(::JsonString) ?: JsonNull),
        "tone" to JsonString(tone.wire),
        "monospacedDetail" to JsonBool(monospacedDetail),
    )
}

/** One row's settlement, carrying the row id the transcript watcher needs. */
public data class BotRowSettlement(
    public val rowID: String,
    public val settlement: BotCardSettlement,
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["rowID"] = JsonString(rowID)
        members.putAll(settlement.toJson().members)
        return JsonObject(members)
    }
}

/** The resolved header value (`BotHeaderPresence`), derived, never inbound. */
public data class BotHeaderPresence(
    public val phase: BotHeaderPhase,
    public val line: BotActivity?,
    public val fishState: BotFishLifecycle,
    public val motion: BotHeaderMotion,
    public val workStyle: BotWorkStyle,
    public val lineIsQuiet: Boolean,
    public val lineIsProblem: Boolean,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "phase" to JsonString(phase.wire),
        "line" to (line?.toJson() ?: JsonNull),
        "fishState" to JsonString(fishState.wire),
        "motion" to JsonString(motion.wire),
        "workStyle" to JsonString(workStyle.wire),
        "lineIsQuiet" to JsonBool(lineIsQuiet),
        "lineIsProblem" to JsonBool(lineIsProblem),
    )

    public companion object {
        /** The only header rule (`ui-state.md` §4.6). */
        public fun resolve(
            turnActive: Boolean,
            lineActivity: BotActivity?,
            pendingApprovals: Int,
            fishState: BotFishLifecycle,
            problem: String?,
        ): BotHeaderPresence {
            val problemText = problemText(problem)
            if (problemText != null) {
                return BotHeaderPresence(
                    phase = BotHeaderPhase.PROBLEM,
                    line = BotActivity(
                        status = BotActivityStatus.THINKING,
                        detail = problemText,
                        category = BotActivityCategory.GENERIC,
                        startedAt = 0,
                    ),
                    fishState = fishState,
                    motion = BotHeaderMotion.STANDARD,
                    workStyle = BotWorkStyle.GENERIC,
                    lineIsQuiet = true,
                    lineIsProblem = true,
                )
            }
            if (turnActive && lineActivity != null) {
                return BotHeaderPresence(
                    phase = BotHeaderPhase.WORKING,
                    line = lineActivity,
                    fishState = workingFish(fishState),
                    motion = BotHeaderMotion.LIVELY,
                    workStyle = BotActivityPhrases.workStyle(lineActivity.category),
                    lineIsQuiet = lineActivity.category == BotActivityCategory.WAITING,
                    lineIsProblem = false,
                )
            }
            if (pendingApprovals > 0) {
                val text = if (pendingApprovals == 1) {
                    BotUiStrings.HEADER_WAITING_SINGLE
                } else {
                    BotUiStrings.format(
                        "header.waiting.plural", "count" to pendingApprovals)
                }
                return BotHeaderPresence(
                    phase = BotHeaderPhase.WAITING_FOR_YOU,
                    line = BotActivity(
                        status = BotActivityStatus.THINKING,
                        detail = text,
                        category = BotActivityCategory.WAITING,
                        startedAt = 0,
                    ),
                    fishState = fishState,
                    motion = BotHeaderMotion.STANDARD,
                    workStyle = BotWorkStyle.GENERIC,
                    lineIsQuiet = true,
                    lineIsProblem = false,
                )
            }
            return BotHeaderPresence(
                phase = BotHeaderPhase.IDLE,
                line = null,
                fishState = fishState,
                motion = BotHeaderMotion.STANDARD,
                workStyle = BotWorkStyle.GENERIC,
                lineIsQuiet = false,
                lineIsProblem = false,
            )
        }

        /** Splits on newlines, trims, drops empties and joins with `；`. */
        public fun problemText(raw: String?): String? {
            if (raw.isNullOrEmpty()) return null
            val parts = raw.split(Regex("[\\r\\n]")).map { it.trim() }.filter { it.isNotEmpty() }
            if (parts.isEmpty()) return null
            return parts.joinToString(BotUiStrings.HEADER_PROBLEM_JOIN)
        }

        /** `idle|sleeping|standby|waking|done` -> `thinking`; else unchanged. */
        public fun workingFish(state: BotFishLifecycle): BotFishLifecycle {
            return when (state) {
                BotFishLifecycle.IDLE,
                BotFishLifecycle.SLEEPING,
                BotFishLifecycle.STANDBY,
                BotFishLifecycle.WAKING,
                BotFishLifecycle.DONE,
                -> BotFishLifecycle.THINKING
                else -> state
            }
        }
    }
}

/** Drawer status colour (`ui-state.md` §4.9). */
public enum class BotDrawerStatusColor(public val wire: String) {
    WARNING("warning"),
    SECONDARY("secondary"),
}

/** The drawer row's one-line status. */
public data class BotDrawerStatus(
    public val text: String,
    public val color: BotDrawerStatusColor,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "text" to JsonString(text),
        "color" to JsonString(color.wire),
    )
}

/** The drawer unread badge. */
public data class BotUnreadBadge(
    public val shown: Boolean,
    public val text: String,
    public val accessibility: String,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "shown" to JsonBool(shown),
        "text" to JsonString(text),
        "accessibility" to JsonString(accessibility),
    )
}

/** A checklist send's local progress. */
public data class BotChecklistProgress(
    public val done: Int,
    public val total: Int,
    public val sending: Boolean,
    public val sent: Boolean,
)

/** The live-turn state: a turn number while the main-chat turn is live. */
public data class BotLiveTurn(
    public val turn: Int?,
    public val ended: Boolean,
)

/** The three streaming inputs of `isStreamingNow`. */
public data class BotStreamingState(
    public val pendingDelta: String = "",
    public val streamingText: String? = null,
    public val liveBuffer: String = "",
)

/** The chat page context. */
public data class BotUiContext(
    public val botID: String,
    public val botName: String,
    public val followingCount: Int? = null,
)

/** The drawer's roster row data the status/badge rules read. */
public data class BotDrawerState(
    public val isRunning: Boolean = false,
    public val lastMessageAt: Long? = null,
    public val unreadCount: Int = 0,
    public val activity: BotActivity? = null,
    public val fishState: BotFishLifecycle = BotFishLifecycle.IDLE,
)

/**
 * Everything `ui-state.md` §4 derives from. `now` is always explicit; the
 * class never reads the wall clock.
 */
public data class BotUiStateInput(
    public val context: BotUiContext,
    public val rows: List<BotRow>,
    public val actionStates: Map<String, BotActionState> = emptyMap(),
    public val dismissedCardIDs: Set<String> = emptySet(),
    public val autoDeclinedApprovalIDs: Set<String> = emptySet(),
    public val answeredOptionIDs: Map<String, String> = emptyMap(),
    public val checklistProgress: Map<String, BotChecklistProgress> = emptyMap(),
    public val runtimePresentation: BotRuntimePresentation = BotRuntimePresentation(),
    public val livePresentation: BotRuntimePresentation? = null,
    public val live: BotLiveTurn? = null,
    public val runningTurnID: String? = null,
    public val awaitingTurn: Boolean = false,
    public val lineSuppressed: Boolean = false,
    public val idleSleeping: Boolean = false,
    public val streaming: BotStreamingState = BotStreamingState(),
    /** The §4.5 count from the projection; null means derive it from the rows. */
    public val pendingApprovalCount: Int? = null,
    /** `liveRunning ∨ remoteBusy ∨ routineRunning`, a §4.7 input. */
    public val running: Boolean = false,
    public val problem: String? = null,
    public val now: Long,
    public val drawer: BotDrawerState = BotDrawerState(),
)

/** The complete derived view state of one Bot chat page snapshot. */
public data class BotUiState(
    public val visibleRowIDs: List<String>,
    public val displayRowIDs: List<String>,
    public val mutedCardIDs: List<String>,
    public val settledRowIDs: List<String>,
    public val settlements: List<BotRowSettlement>,
    public val pendingApprovalCount: Int,
    public val needsAttentionCount: Int,
    public val followingCount: Int,
    public val fishState: BotFishLifecycle,
    public val header: BotHeaderPresence,
    public val lineActivity: BotActivity?,
    public val activityLine: BotActivityLine,
    public val drawerStatus: BotDrawerStatus,
    public val unreadBadge: BotUnreadBadge,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "visibleRowIDs" to JsonArray(visibleRowIDs.map(::JsonString)),
        "displayRowIDs" to JsonArray(displayRowIDs.map(::JsonString)),
        "mutedCardIDs" to JsonArray(mutedCardIDs.map(::JsonString)),
        "settledRowIDs" to JsonArray(settledRowIDs.map(::JsonString)),
        "settlements" to JsonArray(settlements.map { it.toJson() }),
        "pendingApprovalCount" to BotJson.number(pendingApprovalCount.toLong()),
        "needsAttentionCount" to BotJson.number(needsAttentionCount.toLong()),
        "followingCount" to BotJson.number(followingCount.toLong()),
        "fishState" to JsonString(fishState.wire),
        "header" to header.toJson(),
        "lineActivity" to (lineActivity?.toJson() ?: JsonNull),
        "activityLine" to activityLine.toJson(),
        "drawerStatus" to drawerStatus.toJson(),
        "unreadBadge" to unreadBadge.toJson(),
    )
}

/** Muted-card rule (`ui-state.md` §4.4). */
public object BotMutedCards {
    public fun ids(
        visibleRows: List<BotRow>,
        actionStates: Map<String, BotActionState>,
        checklistProgress: Map<String, BotChecklistProgress>,
    ): List<String> {
        val lastUserIndex = visibleRows.indexOfLast {
            it.role == "user" && it.body.type == BotRowBodyType.TEXT
        }
        if (lastUserIndex < 0) return emptyList()
        val muted = mutableListOf<String>()
        for (row in visibleRows.take(lastUserIndex)) {
            val card = BotUICardContent.parse(row) ?: continue
            if (card.kind !in setOf(
                    BotUICardKind.QUESTION, BotUICardKind.STEPS, BotUICardKind.CHECKLIST)) {
                continue
            }
            if (actionStates[BotActionKeys.card(row.id)] != null) continue
            if (card.kind == BotUICardKind.CHECKLIST) {
                val progress = checklistProgress[row.id]
                if (progress != null && (progress.sending || progress.sent)) continue
                if (JsonSupport.bool(row.body["interactive"]) == false) continue
            }
            muted.add(row.id)
        }
        return muted
    }
}

/** The one settlement rule (`ui-state.md` §4.3). */
public object BotSettlementRules {
    public fun settlement(
        row: BotRow,
        actionStates: Map<String, BotActionState>,
        dismissedCardIDs: Set<String>,
        autoDeclinedApprovalIDs: Set<String>,
        answeredOptionIDs: Map<String, String>,
        mutedCardIDs: Collection<String>,
        checklistProgress: Map<String, BotChecklistProgress>,
    ): BotCardSettlement? {
        val card = BotUICardContent.parse(row) ?: return null
        val id = row.id
        return when (card.kind) {
            BotUICardKind.QUESTION, BotUICardKind.STEPS ->
                choiceSettlement(row, card, id, actionStates, dismissedCardIDs,
                    mutedCardIDs, answeredOptionIDs)
            BotUICardKind.CHECKLIST ->
                checklistSettlement(row, card, id, mutedCardIDs, checklistProgress)
            BotUICardKind.APPROVAL ->
                approvalSettlement(row, card, id, actionStates, autoDeclinedApprovalIDs)
            else -> null
        }
    }

    private fun choiceSettlement(
        row: BotRow,
        card: BotUICardContent,
        id: String,
        actionStates: Map<String, BotActionState>,
        dismissedCardIDs: Set<String>,
        mutedCardIDs: Collection<String>,
        answeredOptionIDs: Map<String, String>,
    ): BotCardSettlement? {
        val state = actionStates[BotActionKeys.card(id)]
        if (state is BotActionState.Pending || state is BotActionState.Failed) return null
        val prompt = JsonSupport.firstString(row.body.additionalProperties, "question", "prompt")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
        val detail = prompt
            ?: if (card.kind == BotUICardKind.STEPS) BotUiStrings.SETTLEMENT_STEPSSUGGESTION else null
        val status = JsonSupport.string(row.body["status"])
        if (id in dismissedCardIDs || status == "dismissed") {
            return BotCardSettlement(
                glyph = BotSettlementGlyph.XMARK_CIRCLE,
                title = BotUiStrings.SETTLEMENT_DISMISSED,
                detail = detail,
            )
        }
        if (state is BotActionState.Accepted || status == "answered") {
            val label = chosenLabel(row, card, answeredOptionIDs)
            val title = if (label != null) {
                BotUiStrings.format("settlement.selected", "label" to label)
            } else {
                BotUiStrings.SETTLEMENT_SENT
            }
            return BotCardSettlement(
                glyph = BotSettlementGlyph.CHECKMARK_CIRCLE,
                title = title,
                detail = detail,
            )
        }
        if (id in mutedCardIDs) {
            return BotCardSettlement(
                glyph = BotSettlementGlyph.MINUS_CIRCLE,
                title = BotUiStrings.SETTLEMENT_SKIPPED,
                detail = detail,
            )
        }
        return null
    }

    private fun chosenLabel(
        row: BotRow,
        card: BotUICardContent,
        answeredOptionIDs: Map<String, String>,
    ): String? {
        val durable = row.body["answeredOptionID"] as? JsonString
        val optionID = durable?.value ?: answeredOptionIDs[row.id] ?: return null
        if (optionID.isEmpty()) return null
        val key = if (card.kind == BotUICardKind.STEPS) "steps" else "options"
        return BotUIChoice.parseList(row.body[key]).firstOrNull { it.id == optionID }?.label
    }

    private fun checklistSettlement(
        row: BotRow,
        card: BotUICardContent,
        id: String,
        mutedCardIDs: Collection<String>,
        checklistProgress: Map<String, BotChecklistProgress>,
    ): BotCardSettlement? {
        if (JsonSupport.bool(row.body["interactive"]) == false) return null
        val progress = checklistProgress[id]
        if (progress?.sending == true) return null
        val items = card.checklist
        val done = progress?.done ?: items.count { it.done }
        val total = progress?.total ?: items.size
        val title = JsonSupport.string(row.body["title"]) ?: ""
        val detail = BotUiStrings.format(
            "settlement.checklistDetail", "title" to title, "done" to done, "total" to total)
        if (progress?.sent == true) {
            return BotCardSettlement(
                glyph = BotSettlementGlyph.CHECKMARK_CIRCLE,
                title = BotUiStrings.SETTLEMENT_CHECKLISTSENT,
                detail = detail,
            )
        }
        if (id in mutedCardIDs) {
            return BotCardSettlement(
                glyph = BotSettlementGlyph.MINUS_CIRCLE,
                title = BotUiStrings.SETTLEMENT_SKIPPED,
                detail = detail,
            )
        }
        return null
    }

    private fun approvalSettlement(
        row: BotRow,
        card: BotUICardContent,
        id: String,
        actionStates: Map<String, BotActionState>,
        autoDeclinedApprovalIDs: Set<String>,
    ): BotCardSettlement? {
        val state = actionStates[BotActionKeys.approval(id)]
        if (state is BotActionState.Pending || state is BotActionState.Failed) return null
        val ask = (row.body["ask"] as? JsonObject)?.members ?: emptyMap()
        val status = row.approvalStatus()
        val action = JsonSupport.firstString(
            row.body.additionalProperties, "action", "title", "text")
            ?: JsonSupport.string(ask["action"])
            ?: BotUiStrings.SETTLEMENT_APPROVALDEFAULTACTION
        val command = JsonSupport.firstString(
            row.body.additionalProperties, "command", "target")
            ?: JsonSupport.string(ask["target"])
            ?: ""
        val detail = if (command.isEmpty()) action else command
        val mono = command.isNotEmpty()
        if (id in autoDeclinedApprovalIDs) {
            return BotCardSettlement(
                glyph = BotSettlementGlyph.XMARK_CIRCLE,
                title = BotUiStrings.SETTLEMENT_APPROVALAUTODECLINED,
                detail = detail,
                monospacedDetail = mono,
            )
        }
        if (status == "pending") return null
        val allowed = status == "allowed" || status == "always"
        val scope = JsonSupport.firstString(row.body.additionalProperties, "alwaysScope")
            ?: JsonSupport.string(ask["alwaysScope"])
            ?: "until"
        val title = when (status) {
            "allowed" -> BotUiStrings.SETTLEMENT_APPROVALALLOWEDONCE
            "always" -> if (scope == "session") {
                BotUiStrings.SETTLEMENT_APPROVALSESSIONALLOWED
            } else {
                BotUiStrings.SETTLEMENT_APPROVALALWAYS
            }
            "denied", "never" -> BotUiStrings.SETTLEMENT_APPROVALDENIED
            "timed-out" -> BotUiStrings.SETTLEMENT_APPROVALTIMEDOUT
            "expired" -> BotUiStrings.SETTLEMENT_APPROVALEXPIRED
            else -> BotUiStrings.SETTLEMENT_APPROVALHANDLED
        }
        return BotCardSettlement(
            glyph = if (allowed) BotSettlementGlyph.CHECKMARK_CIRCLE_FILL
            else BotSettlementGlyph.XMARK_CIRCLE,
            title = title,
            detail = detail,
            tone = if (allowed) BotSettlementTone.SUCCESS else BotSettlementTone.NEUTRAL,
            monospacedDetail = mono,
        )
    }
}

/** Counts (`ui-state.md` §4.5). */
public object BotCounts {
    public fun pendingApprovals(
        visibleRows: List<BotRow>,
        actionStates: Map<String, BotActionState>,
    ): Int = visibleRows.count { row ->
        row.body.type == BotRowBodyType.APPROVAL &&
            row.approvalStatus() == "pending" &&
            when (actionStates[BotActionKeys.approval(row.id)]) {
                is BotActionState.Pending, is BotActionState.Accepted -> false
                else -> true
            }
    }

    public fun needsAttention(
        visibleRows: List<BotRow>,
        actionStates: Map<String, BotActionState>,
        checklistProgress: Map<String, BotChecklistProgress>,
        mutedCardIDs: Collection<String>,
        dismissedCardIDs: Set<String> = emptySet(),
        autoDeclinedApprovalIDs: Set<String> = emptySet(),
        answeredOptionIDs: Map<String, String> = emptyMap(),
    ): Int {
        var count = pendingApprovals(visibleRows, actionStates)
        for (row in visibleRows) {
            val card = BotUICardContent.parse(row) ?: continue
            when (card.kind) {
                BotUICardKind.QUESTION, BotUICardKind.STEPS -> {
                    if (actionStates[BotActionKeys.card(row.id)] is BotActionState.Pending) continue
                    if (settlement(
                            row, actionStates, checklistProgress, mutedCardIDs,
                            dismissedCardIDs, autoDeclinedApprovalIDs, answeredOptionIDs) == null
                    ) {
                        count++
                    }
                }
                BotUICardKind.CHECKLIST -> {
                    if (JsonSupport.bool(row.body["interactive"]) == false) continue
                    if (checklistProgress[row.id]?.sending == true) continue
                    if (settlement(
                            row, actionStates, checklistProgress, mutedCardIDs,
                            dismissedCardIDs, autoDeclinedApprovalIDs, answeredOptionIDs) == null
                    ) {
                        count++
                    }
                }
                else -> Unit
            }
        }
        return count
    }

    public fun following(visibleRows: List<BotRow>, injected: Int?): Int {
        if (injected != null) return injected
        var count = 0
        for (row in visibleRows) {
            val card = BotUICardContent.parse(row) ?: continue
            val body = card.body
            when (card.kind) {
                BotUICardKind.AUTOMATION -> {
                    val automation = (body["automation"] as? JsonObject)?.members
                    val status = JsonSupport.string(body["status"])
                        ?: JsonSupport.string(automation?.get("status"))
                        ?: "sent"
                    if (status == "running" || status == "confirming") count++
                }
                BotUICardKind.PROGRESS -> {
                    val status = JsonSupport.string(body["state"]) ?: "running"
                    if (status == "running") count++
                }
                BotUICardKind.TASK -> {
                    val task = (body["task"] as? JsonObject)?.members
                    val status = JsonSupport.string(body["status"])
                        ?: JsonSupport.string(task?.get("status"))
                        ?: ""
                    if (status in setOf("running", "active", "in_progress", "working")) count++
                }
                else -> Unit
            }
        }
        return count
    }

    private fun settlement(
        row: BotRow,
        actionStates: Map<String, BotActionState>,
        checklistProgress: Map<String, BotChecklistProgress>,
        mutedCardIDs: Collection<String>,
        dismissedCardIDs: Set<String>,
        autoDeclinedApprovalIDs: Set<String>,
        answeredOptionIDs: Map<String, String>,
    ): BotCardSettlement? = BotSettlementRules.settlement(
        row = row,
        actionStates = actionStates,
        dismissedCardIDs = dismissedCardIDs,
        autoDeclinedApprovalIDs = autoDeclinedApprovalIDs,
        answeredOptionIDs = answeredOptionIDs,
        mutedCardIDs = mutedCardIDs,
        checklistProgress = checklistProgress,
    )
}

/** The pure §4 derivations. */
public object BotUiStateDerivation {
    public fun visibleRows(rows: List<BotRow>): List<BotRow> = rows.filter { row ->
        BotUIRendering.isRenderable(row) && row.body.type != BotRowBodyType.NOTICE
    }

    public fun displayRows(rows: List<BotRow>, live: BotLiveTurn?): List<BotRow> {
        val turn = live?.turn ?: return rows
        return rows.filterNot { row ->
            row.role == "assistant" &&
                row.body.type == BotRowBodyType.TEXT &&
                JsonSupport.long(row.body["turn"]) == turn.toLong()
        }
    }

    public fun showsActivityLine(input: BotUiStateInput): Boolean {
        if (input.awaitingTurn) return true
        if (input.runningTurnID != null) return true
        val live = input.live
        return live != null && !live.ended && !input.lineSuppressed
    }

    public fun isStreamingNow(input: BotUiStateInput): Boolean {
        if (input.streaming.pendingDelta.isNotEmpty()) return true
        if (!input.streaming.streamingText.isNullOrEmpty()) return true
        return input.live != null && input.streaming.liveBuffer.trim().isNotEmpty()
    }

    public fun lineActivity(input: BotUiStateInput, pendingApprovals: Int): BotActivity? {
        if (!showsActivityLine(input)) return null
        if (pendingApprovals > 0) {
            return BotActivity(
                status = BotActivityStatus.THINKING,
                detail = "",
                category = BotActivityCategory.WAITING,
                startedAt = 0,
            )
        }
        if (isStreamingNow(input)) {
            return BotActivity(
                status = BotActivityStatus.STREAMING,
                detail = "",
                category = BotActivityCategory.REPLYING,
                startedAt = 0,
            )
        }
        val factory = if (input.live != null) {
            input.livePresentation?.activity
        } else {
            input.runtimePresentation.activity
        }
        return factory ?: BotActivity(
            status = BotActivityStatus.THINKING,
            detail = "",
            category = BotActivityCategory.THINKING,
            startedAt = 0,
        )
    }

    public fun drawerStatus(
        input: BotUiStateInput,
        pendingApprovals: Int,
    ): BotDrawerStatus {
        val drawer = input.drawer
        if (pendingApprovals > 0) {
            return BotDrawerStatus(
                text = BotUiStrings.format("drawer.pending", "count" to pendingApprovals),
                color = BotDrawerStatusColor.WARNING,
            )
        }
        if (drawer.isRunning) {
            val activity = drawer.activity
            val text = when {
                activity == null -> when (drawer.fishState) {
                    BotFishLifecycle.THINKING -> BotUiStrings.DRAWER_STATE_THINKING
                    BotFishLifecycle.WORKING -> BotUiStrings.DRAWER_STATE_WORKING
                    BotFishLifecycle.SPEAKING,
                    BotFishLifecycle.STREAMING,
                    -> BotUiStrings.DRAWER_STATE_REPLYING
                    BotFishLifecycle.ALERTING -> BotUiStrings.DRAWER_STATE_ALERTING
                    BotFishLifecycle.SLEEPING -> BotUiStrings.DRAWER_STATE_SLEEPING
                    else -> BotUiStrings.DRAWER_STATE_RUNNING
                }
                activity.detail.isNotEmpty() -> activity.detail
                else -> BotActivityPhrases.primaryPhrase(activity.category)
            }
            return BotDrawerStatus(text = text, color = BotDrawerStatusColor.SECONDARY)
        }
        return BotDrawerStatus(
            text = relativeTime(drawer.lastMessageAt, input.now),
            color = BotDrawerStatusColor.SECONDARY,
        )
    }

    public fun unreadBadge(unreadCount: Int): BotUnreadBadge {
        if (unreadCount <= 0) return BotUnreadBadge(false, "", "")
        return BotUnreadBadge(
            shown = true,
            text = if (unreadCount > 99) BotUiStrings.DRAWER_UNREAD_OVERFLOW
            else unreadCount.toString(),
            accessibility = BotUiStrings.format("drawer.unread", "count" to unreadCount),
        )
    }

    public fun relativeTime(ms: Long?, now: Long): String {
        if (ms == null || ms == 0L) return BotUiStrings.DRAWER_NOMESSAGES
        val seconds = (now - ms) / 1000.0
        if (seconds < 60) return BotRelativeTimeCopy.JUST_NOW
        if (seconds < 3_600) return "${(seconds / 60).toInt()}${BotRelativeTimeCopy.MINUTES_AGO}"
        if (seconds < 86_400) return "${(seconds / 3_600).toInt()}${BotRelativeTimeCopy.HOURS_AGO}"
        val date = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).toLocalDate()
        return "${date.monthValue}月${date.dayOfMonth}日"
    }

    /** Derives the complete state; the only entry point pages need. */
    public fun derive(input: BotUiStateInput): BotUiState {
        val visible = visibleRows(input.rows)
        val display = displayRows(visible, input.live)
        val muted = BotMutedCards.ids(visible, input.actionStates, input.checklistProgress)
        val settlements = display.mapNotNull { row ->
            BotSettlementRules.settlement(
                row = row,
                actionStates = input.actionStates,
                dismissedCardIDs = input.dismissedCardIDs,
                autoDeclinedApprovalIDs = input.autoDeclinedApprovalIDs,
                answeredOptionIDs = input.answeredOptionIDs,
                mutedCardIDs = muted,
                checklistProgress = input.checklistProgress,
            )?.let { BotRowSettlement(row.id, it) }
        }
        val pending = BotCounts.pendingApprovals(visible, input.actionStates)
        val attention = BotCounts.needsAttention(
            visible, input.actionStates, input.checklistProgress, muted,
            input.dismissedCardIDs, input.autoDeclinedApprovalIDs, input.answeredOptionIDs)
        val following = BotCounts.following(visible, input.context.followingCount)
        val turnActive = showsActivityLine(input)
        val line = lineActivity(input, pending)
        val fishState = BotFishProjection.resolve(
            BotFishProjectionInput(
                pendingApprovalCount = input.pendingApprovalCount ?: pending,
                running = input.running,
                idleSleeping = input.idleSleeping,
                livePresentation = input.livePresentation,
                durablePresentation = input.runtimePresentation,
                liveTurn = input.live != null,
                now = input.now,
            ),
        )
        val header = BotHeaderPresence.resolve(
            turnActive = turnActive,
            lineActivity = line,
            pendingApprovals = pending,
            fishState = fishState,
            problem = input.problem,
        )
        val lineState = BotActivityLineState()
        lineState.receive(header.line, input.now)
        return BotUiState(
            visibleRowIDs = visible.map { it.id },
            displayRowIDs = display.map { it.id },
            mutedCardIDs = muted,
            settledRowIDs = settlements.map { it.rowID },
            settlements = settlements,
            pendingApprovalCount = pending,
            needsAttentionCount = attention,
            followingCount = following,
            fishState = fishState,
            header = header,
            lineActivity = line,
            activityLine = BotActivityLine(lineState.text, lineState.nextDeadline),
            drawerStatus = drawerStatus(input, pending),
            unreadBadge = unreadBadge(input.drawer.unreadCount),
        )
    }
}

/**
 * The three relative-time words §4.9 freezes (`刚刚`, `分钟前`, `小时前`) and
 * the `M月d日` calendar form. They are not ids in `strings.json`; the spec
 * checker and the reference use the same literals. If the owner moves them
 * into the data file, this object is the single place to change.
 */
public object BotRelativeTimeCopy {
    public const val JUST_NOW: String = "刚刚"
    public const val MINUTES_AGO: String = " 分钟前"
    public const val HOURS_AGO: String = " 小时前"
}
