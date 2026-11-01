// The ScreenState layer: the view state the screen owns.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §6 "Two layers: UiState and ScreenState".
//   * UiState is the event-anchored projection (`com.phonedsh.ui.projection`);
//     one event, one node, and the cross-platform assertion compares sequences.
//   * ScreenState is what only the screen can own: draft, focus, fold, the
//     pending-answer slot and the transient banner. It has no event anchor, so
//     it is not part of the UiState sequence.
//   * ScreenState MUST be a pure function of (UiState + local UI events + the
//     read-only host facts the screen is handed): no clock, no network, no
//     engine. That is what makes it replayable in a JVM test.
//   * A screenshot assertion is a third artifact and may only cover the six
//     signature surfaces; it never replaces the sequence assertion above.
//
// The row model mirrors the iOS baseline's `ChatItem.Kind` switch row for row
// (`examples/probe-app/PhoneDSHProbe/ChatPage.swift` ChatMessageRow + the
// `NativeTranscriptRow` grouping): a message bubble, an assistant answer, a
// thinking pill, a run of tool rows (one disclosure line per call/result), a
// group of injected context blocks and a system event. A kind whose iOS row
// needs data this host never reports (a timestamp, a usage block, a changed
// file) carries a nullable field and the row hides that piece; nothing is
// fabricated to fill it.
package com.phonedsh.ui.state

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.projection.UiStateKind
import com.phonedsh.ui.projection.UiStateNode
import com.phonedsh.ui.surface.ComposerMode
import com.phonedsh.ui.surface.ToolRowState

/** What the page shows around the list. */
public enum class ChatPhase {
    /** No engine connection yet: empty/waiting, never fabricated content. */
    WAITING,

    /** Connected, nothing running. */
    IDLE,

    /** A turn is running (or a tool row still runs). */
    RUNNING,

    /** The last turn failed; a fail-loud banner is on screen. */
    FAILED,
}

/**
 * One attachment (iOS `NativeMessageAttachment` / `HarnessAttachment`).
 *
 * @param name the file name shown on the chip.
 * @param mimeType the host MIME type; `null` falls back to the kind's word.
 * @param image true for an image attachment (the only kind the prompt path takes).
 * @param path the workspace-relative path the chip opens (iOS
 *   `NativeMessageAttachment.path`); `null` renders the chip as non-tappable.
 */
public data class ChatAttachment(
    public val name: String,
    public val mimeType: String? = null,
    public val image: Boolean = false,
    public val path: String? = null,
)

/**
 * One tool call or result inside a run (iOS `NativeToolCallRow`, one disclosure
 * line per item, each expanded on its own).
 *
 * @param id the UiState node id, which is also the expansion key.
 * @param title the tool name.
 * @param summary the one-line result (or the running word while the call runs).
 * @param state running / ok / error / stopped.
 * @param banner the detail card's title line.
 * @param body the expanded output.
 * @param filePath the workspace path a tool touched, when the host named one.
 */
public data class ToolEntry(
    public val id: String,
    public val title: String,
    public val summary: String,
    public val state: ToolRowState,
    public val banner: String = "",
    public val body: String = "",
    public val filePath: String? = null,
)

/**
 * One injected context block (iOS `NativeContextSourceGroup`).
 *
 * @param source the host's source name; the renderer translates it with
 *   [contextSourceName] and hides a name this app does not translate, so an
 *   internal word such as `user-approval` never reaches the screen.
 * @param text the injected text.
 */
public data class ContextEntry(
    public val source: String?,
    public val text: String,
)

/**
 * One visible row of the chat list.
 *
 * The members are the iOS `ChatItem.Kind` cases that produce a row, plus the
 * grouping `NativeTranscriptRow` adds (`tools`, `contexts`).
 */
public sealed interface ChatRow {
    /** Stable row id: the UiState node id of the row's anchor, or the run's first node. */
    public val id: String

    /**
     * A user message (iOS `userBubble` + optional attachment list + message actions).
     *
     * @param badge "已排队" / "已并入当前任务" / "发送中…"; `null` for a plain sent message.
     * @param attachments the message's attachments; empty hides the list. It only
     *   becomes reachable once `spec/host/v1`'s `user_message` carries
     *   attachments; until then the Android chain drops them at the host-event
     *   layer, so no projection can fill the list.
     * @param timestamp a clock reading; `null` hides it (this host reports none).
     */
    public data class User(
        override val id: String,
        public val text: String,
        public val badge: String? = null,
        public val attachments: List<ChatAttachment> = emptyList(),
        public val timestamp: String? = null,
    ) : ChatRow

    /**
     * An assistant answer (iOS `assistantBody`: no bubble chrome).
     *
     * @param streaming true while the answer still streams; `null`-backed by the
     *   host today, so it stays false and no halo/spinner is drawn.
     * @param closing true for the last assistant row of a closed turn, which is
     *   the only row iOS attaches the turn-wide actions to.
     */
    public data class Assistant(
        override val id: String,
        public val text: String,
        public val streaming: Boolean = false,
        public val closing: Boolean = false,
    ) : ChatRow

    /** A reasoning row (iOS `NativeThinkingRow`). */
    public data class Thinking(
        override val id: String,
        public val summary: String,
        public val streaming: Boolean,
    ) : ChatRow

    /**
     * One run of consecutive tool rows: iOS renders the group as a `VStack` of
     * one disclosure line per item, not as a single merged line.
     */
    public data class ToolRun(
        override val id: String,
        public val entries: List<ToolEntry>,
    ) : ChatRow {
        /** The worst state of the run, for the group's accessibility value. */
        public val state: ToolRowState
            get() = when {
                entries.any { it.state == ToolRowState.ERROR } -> ToolRowState.ERROR
                entries.any { it.state == ToolRowState.RUNNING } -> ToolRowState.RUNNING
                entries.any { it.state == ToolRowState.STOPPED } -> ToolRowState.STOPPED
                else -> ToolRowState.OK
            }

        /** The first line's tool name. */
        public val title: String get() = entries.firstOrNull()?.title.orEmpty()

        /** The last line's summary. */
        public val summary: String get() = entries.lastOrNull()?.summary.orEmpty()
    }

    /** Consecutive injected context blocks, folded into one disclosure line. */
    public data class Context(
        override val id: String,
        public val entries: List<ContextEntry>,
    ) : ChatRow

    /**
     * A system event (iOS `NativeSystemEventRow`): a coloured dot, a title in
     * secondary ink and an optional detail line.
     *
     * @param isError a turn error (danger ink) rather than a warning event.
     */
    public data class SystemEvent(
        override val id: String,
        public val title: String,
        public val text: String = "",
        public val isError: Boolean = false,
    ) : ChatRow
}

/** A pending ask the user still has to answer. */
public data class PendingAnswer(
    public val id: String,
    public val requestId: String,
    /** `permission` or `question`. */
    public val kind: String,
    public val title: String,
    public val subtitle: String,
    public val options: List<String> = emptyList(),
    /** A question that accepts several answers (iOS `HarnessQuestionItem.multiple`). */
    public val multiple: Boolean = false,
)

/**
 * The pending-answer slot: at most two asks, the primary card on top and the
 * rest folded into one line (spec §2 "审批卡" fold rule).
 *
 * The two-card cap is a protocol invariant (one approval plus one question may be
 * pending); [hidden] exists so a host that violates it is visible instead of
 * silently losing an unanswered ask — the slot still renders at most two.
 */
public data class PendingSlot(
    public val primary: PendingAnswer? = null,
    public val folded: List<PendingAnswer> = emptyList(),
    /** Asks beyond the two-card cap; counted, never shown as cards. */
    public val hidden: Int = 0,
) {
    /** The asks the slot can show: at most two (spec §2). */
    public val displayedCount: Int get() = (if (primary != null) 1 else 0) + folded.size

    /** Every unanswered ask, shown or folded (used by the "N 项需要处理" line). */
    public val count: Int get() = displayedCount + hidden

    public val isEmpty: Boolean get() = count == 0

    /** True when both card types are pending, which is what folds the second one. */
    public val bothKinds: Boolean
        get() = primary != null && folded.isNotEmpty()
}

/**
 * How the pending-answer slot is presented.
 *
 * The keyboard case is a ScreenState decision, not a composable flag: spec §3
 * "键盘弹起（有待回答卡）" folds the area into one line, and a JVM replay has to
 * reach the same state from the same local UI events.
 */
public enum class PendingFold {
    /** The cards (or the empty slot) are shown at full height. */
    EXPANDED,

    /** The IME is up and the user did not expand it: one "N 项需要处理" line. */
    FOLDED,
}

/** Why the composer cannot send. The dock stays visible in every case (spec §2). */
public enum class ComposerLock {
    /** The dock is usable. */
    NONE,

    /** No engine connection yet: there is nothing to send to. */
    WAITING_ENGINE,

    /** An approval or question card is on screen (spec §2 "composer"). */
    PENDING_ANSWER,
}

/** A fail-loud banner currently on screen. */
public data class BannerState(
    public val id: String,
    public val message: String,
    public val reason: String,
    public val retryable: Boolean,
    public val dismissible: Boolean,
)

/** What the transcript area says about loading its own history. */
public data class TranscriptState(
    /** The host has older messages (iOS `model.transcriptHasMore`). */
    public val hasMore: Boolean = false,
    /** The "加载更早消息" request is in flight. */
    public val loadingEarlier: Boolean = false,
    /** A history read failed; shown above the list, never only in a log. */
    public val error: String? = null,
    /** The list is the previous session's cache while the engine boots. */
    public val showingCached: Boolean = false,
)

/**
 * The one status indicator's three states (iOS `RunStatusDot`): the engine is
 * running, parked in the background, or stopped.
 */
public enum class RunStatus {
    /** `RunStatusDot(started: true, parked: false)`. */
    STARTED,

    /** `RunStatusDot(started: _, parked: true)`: the host is parked in the background. */
    PARKED,

    /** `RunStatusDot(started: false, parked: false)`. */
    STOPPED,
}

/**
 * Which of the three mutually exclusive empty states the transcript shows
 * (iOS `emptyTimeline`: engine, provider, ready).
 */
public enum class ChatEmpty {
    /** A: the engine is not started. */
    ENGINE_NOT_STARTED,

    /** B: the engine runs but no model service is configured. */
    PROVIDER_SETUP,

    /** C: both are ready; the product mark and the tagline. */
    READY,
}

/** One command of the live DSH catalog, shown in the in-place slash menu. */
public data class ComposerCommand(
    public val name: String,
    public val description: String,
)

/** The in-place `/` menu: loading, a failure, matches, or "no match". */
public sealed interface SlashMenu {
    /** The catalog is being read and nothing is cached yet. */
    public data object Loading : SlashMenu

    /** The catalog read failed and nothing is cached; the menu offers a retry. */
    public data class Failed(public val message: String) : SlashMenu

    /** The matching commands (at most six, the host's order preserved). */
    public data class Matches(public val commands: List<ComposerCommand>) : SlashMenu

    /** The token matched nothing. */
    public data object Empty : SlashMenu
}

/** The in-place `@` menu: matching workspace files and session titles. */
public data class ReferenceMenu(
    public val files: List<String> = emptyList(),
    public val sessions: List<String> = emptyList(),
) {
    /** True when nothing matched, which is the menu's own empty line. */
    public val isEmpty: Boolean get() = files.isEmpty() && sessions.isEmpty()
}

/** One selectable access mode, already translated by the host. */
public data class AccessModeOption(
    public val id: String,
    public val title: String,
)

/** The composer's access-mode menu (iOS `accessModeMenu`). */
public data class AccessModeMenu(
    public val options: List<AccessModeOption> = emptyList(),
    /** The mode in force, or `null` when the host reports none. */
    public val currentID: String? = null,
    /** Its translated title; `null` while unknown. */
    public val currentTitle: String? = null,
    /** The last read failure; the menu shows it in a "暂不可用" group. */
    public val error: String? = null,
    /** False while a turn runs or an ask is pending (iOS disables the menu). */
    public val enabled: Boolean = false,
) {
    /** iOS `accessModeTitle`: the current title, or the bare product word. */
    public val label: String get() = currentTitle ?: UiStrings.ACCESS_MODE_TITLE_FALLBACK

    /** True when the safest mode is not in force, i.e. writes ask first. */
    public val asksBeforeWrite: Boolean get() = currentTitle != FULL_PERMISSION_TITLE
}

/** One reasoning-effort choice of the model menu. */
public data class EffortOption(
    public val id: String,
    public val title: String,
)

/** The composer's model menu (iOS `modelMenu`). */
public data class ModelMenu(
    /** The model in force; empty renders the bare product word (iOS "模型"). */
    public val modelName: String = "",
    /** The effort label the row appends, when the host reports one. */
    public val effortTitle: String? = null,
    /** Available model names, one line each. */
    public val models: List<String> = emptyList(),
    /** The model in force, for the checkmark. */
    public val currentModel: String? = null,
    /** The effort choices of the current model. */
    public val efforts: List<EffortOption> = emptyList(),
    /** The effort in force, for the checkmark. */
    public val currentEffort: String? = null,
    /** "默认强度" or "默认强度 · 高". */
    public val defaultEffortTitle: String = UiStrings.MODEL_DEFAULT_EFFORT,
    /** False while a turn runs or an ask is pending (iOS disables the menu). */
    public val enabled: Boolean = false,
) {
    /** True when the host reports no model catalog at all. */
    public val unavailable: Boolean get() = models.isEmpty() && modelName.isEmpty()

    /** The row's model label. */
    public val label: String get() = modelName.ifEmpty { UiStrings.MODEL_FALLBACK }
}

/**
 * The read-only facts the screen is handed (never read from the engine here).
 *
 * Defaults are the "host reported nothing" values: `engineStarted = false` makes
 * the page show empty state A, and the menus render empty rather than inventing
 * entries. A caller that knows a fact passes it in; the projection itself has no
 * such field, which is why they are parameters instead of node props.
 */
public data class ChatHostFacts(
    /** The engine is up (iOS `model.isStarted`). */
    public val engineStarted: Boolean = false,
    /** The host is parked in the background (iOS `model.parked`). */
    public val parked: Boolean = false,
    /** A start is in flight, so the empty state's key reads 正在启动… (iOS `model.busy`). */
    public val starting: Boolean = false,
    /** A model service still needs its key (iOS `providerNeedsKey`). */
    public val providerNeedsKey: Boolean = false,
    /** The host can accept a message now (iOS `model.canSend`). */
    public val canSend: Boolean = true,
    /** The host can take a steer message into the running turn (iOS `model.canSteer`). */
    public val canSteer: Boolean = true,
    /** Enter sends into the running turn (`steer`) instead of queueing (`queue`). */
    public val enterMode: EnterMode = EnterMode.QUEUE,
    /** The row a send failure belongs to; `null` puts the failure in the top banner. */
    public val failedItemID: String? = null,
    /** The transcript's own loading facts. */
    public val transcript: TranscriptState = TranscriptState(),
    /** The live command catalog for the `/` menu. */
    public val commands: List<ComposerCommand> = emptyList(),
    public val commandsLoading: Boolean = false,
    public val commandsError: String? = null,
    /** The access-mode catalog. */
    public val accessModes: List<AccessModeOption> = emptyList(),
    public val currentAccessMode: AccessModeOption? = null,
    public val accessModeError: String? = null,
    /** The model catalog. */
    public val models: List<String> = emptyList(),
    public val currentModel: String? = null,
    public val effortTitle: String? = null,
    public val efforts: List<EffortOption> = emptyList(),
    public val currentEffort: String? = null,
    public val defaultEffortTitle: String = UiStrings.MODEL_DEFAULT_EFFORT,
    /** Workspace relative paths for the `@` menu. */
    public val files: List<String> = emptyList(),
    /** Session titles for the `@` menu. */
    public val sessionTitles: List<String> = emptyList(),
    /** The permissions menu is mid-write (iOS `isSelectingAccessMode`). */
    public val selectingAccessMode: Boolean = false,
    /** The estimated context-window share; `null` hides the ring. */
    public val contextPercent: Int? = null,
)

/** What the Enter key does while a turn runs (iOS `busyEnterMode`). */
public enum class EnterMode {
    /** Queue the message behind the running turn. */
    QUEUE,

    /** Fold the message into the running turn. */
    STEER,
}

/** The composer's view state. */
public data class ComposerState(
    public val draft: String = "",
    /** `STOP` when the main key is the stop key (a turn runs and cannot be submitted to). */
    public val mode: ComposerMode = ComposerMode.SEND,
    public val enabled: Boolean = true,
    /** Queued messages behind the running turn (iOS `queuedMessages`). */
    public val queuedCount: Int = 0,
    /** The queued messages' first lines, in projection order. */
    public val queued: List<String> = emptyList(),
    /** The placeholder, already resolved from the three iOS cases. */
    public val placeholder: String = UiStrings.COMPOSER_PLACEHOLDER_IDLE,
    /** The send key's accessibility label, already resolved. */
    public val sendLabel: String = UiStrings.COMPOSER_SEND_LABEL,
    /** iOS `canSubmit`: the send key is live. */
    public val canSubmit: Boolean = false,
    /** A turn is running (drives the running spinner and the stop key). */
    public val running: Boolean = false,
    /** Enter steers the running turn instead of queueing. */
    public val steering: Boolean = false,
    /** Pending image attachments, in the order they were added. */
    public val attachments: List<ChatAttachment> = emptyList(),
    /** The attachment/import failure line; `null` hides it. */
    public val attachmentError: String? = null,
    /** The workspace-import status line; `null` hides it. */
    public val fileImportNotice: String? = null,
    /** The `/` menu; `null` means the trigger is not open. */
    public val slash: SlashMenu? = null,
    /** The `@` menu; `null` means the trigger is not open. */
    public val reference: ReferenceMenu? = null,
)

/** The goal bar. A goal is read through the goal API, not a harness event. */
public sealed interface GoalBarState {
    /** No goal read yet, or no goal: the bar is not shown. */
    public data object Hidden : GoalBarState

    /** A goal is visible: phase + one-line objective + pause/resume + clear. */
    public data class Visible(
        public val phase: String,
        public val objective: String,
    ) : GoalBarState
}

/**
 * The local UI events of the screen. Nothing here is inferred from the engine:
 * a draft is what the user typed, an answered request is what the user tapped.
 */
public data class ChatLocalState(
    public val draft: String = "",
    /** Request ids the user already answered; their cards leave the slot. */
    public val answeredRequestIds: Set<String> = emptySet(),
    /** Banner node ids the user dismissed. */
    public val dismissedBannerIds: Set<String> = emptySet(),
    /** Rows the user expanded (tool entry ids and thinking pill ids). */
    public val expandedRowIds: Set<String> = emptySet(),
    /** Local row labels, keyed by node id ("已排队", "已并入当前任务"). */
    public val badges: Map<String, String> = emptyMap(),
    /** Pending image attachments the user added. */
    public val attachments: List<ChatAttachment> = emptyList(),
    /** The last attachment/import failure the user has not closed. */
    public val attachmentError: String? = null,
    /** The last workspace-import status the user has not closed. */
    public val fileImportNotice: String? = null,
    /**
     * The IME is up. This is a platform observation the host feeds in as a local
     * UI event; the state machine never reads `WindowInsets` itself.
     */
    public val imeVisible: Boolean = false,
    /** The user tapped the folded slot to see the asks while the keyboard is up. */
    public val pendingSlotExpanded: Boolean = false,
)

/** The complete screen state of the chat page. */
public data class ChatScreenState(
    public val sessionID: String,
    public val phase: ChatPhase,
    public val rows: List<ChatRow>,
    public val pending: PendingSlot,
    public val banners: List<BannerState>,
    public val composer: ComposerState,
    public val goal: GoalBarState,
    public val expandedRowIds: Set<String>,
    public val stats: String?,
    /** Whether the answer slot is folded for the keyboard (spec §3). */
    public val pendingFold: PendingFold = PendingFold.EXPANDED,
    /**
     * Whether the second ask is open (iOS `cardsExpanded`). While it is false the
     * slot shows one card plus the "还有 1 个待确认" line.
     */
    public val pendingExpanded: Boolean = false,
    /** Why the dock is locked; [ComposerState.enabled] is derived from it. */
    public val composerLock: ComposerLock = ComposerLock.NONE,
    /** The transcript's own loading facts (iOS `transcriptHasMore` & friends). */
    public val transcript: TranscriptState = TranscriptState(),
    /** Which mutually exclusive empty state the transcript shows. */
    public val empty: ChatEmpty = ChatEmpty.ENGINE_NOT_STARTED,
    /** The header's run-status indicator (iOS `RunStatusDot`). */
    public val runStatus: RunStatus = RunStatus.STOPPED,
    /** The empty state's start key is in flight. */
    public val starting: Boolean = false,
    /** The row a send failure belongs to (iOS `model.failedItemID`). */
    public val failedItemID: String? = null,
    /** The last user-facing failure (iOS `model.userFacingError`). */
    public val userFacingError: String? = null,
    /** The access-mode read failure; the composer's banner shows it. */
    public val accessModeError: String? = null,
    /** The command-catalog read failure; the composer's banner shows it. */
    public val commandsError: String? = null,
    /** The composer's access-mode menu. */
    public val accessModeMenu: AccessModeMenu = AccessModeMenu(),
    /** The composer's model menu. */
    public val modelMenu: ModelMenu = ModelMenu(),
    /** The estimated share of the context window in use; `null` hides the ring. */
    public val contextPercent: Int? = null,
) {
    /** True when the list has nothing to show yet. */
    public val isEmpty: Boolean get() = rows.isEmpty()

    public companion object {
        /**
         * Projects a node sequence into the screen state.
         *
         * Pure: the same `(nodes, local, goal, stats, host)` always yields the
         * same state, so a test can replay a golden trajectory and assert the row
         * sequence instead of comparing pixels.
         *
         * @param nodes the UiState projection, in order.
         * @param local the local UI events (draft, folds, badges, attachments).
         * @param goal the goal the host read, if any.
         * @param stats the stat pill's text, if the host reported one.
         * @param host the read-only host facts (engine, catalogs, transcript).
         */
        public fun from(
            nodes: List<UiStateNode>,
            local: ChatLocalState = ChatLocalState(),
            goal: GoalBarState = GoalBarState.Hidden,
            stats: String? = null,
            host: ChatHostFacts = ChatHostFacts(),
        ): ChatScreenState {
            val sessionID = nodes.firstOrNull { it.kind == UiStateKind.SESSION }?.sessionID
                ?: nodes.firstOrNull()?.sessionID
                ?: ""
            val rows = mutableListOf<ChatRow>()
            val pending = mutableListOf<PendingAnswer>()
            val banners = mutableListOf<BannerState>()
            var run: RunBuilder? = null
            var failed = false
            // run id -> enclosing turn node id, so a closed turn can settle its rows.
            val runTurn = HashMap<String, String>()
            // A turn closes on its turn-end row; an open turn is what makes the
            // composer show "stop" and the header dot "running".
            val openTurns = LinkedHashSet<String>()
            // The turn node each assistant row belongs to, for the closing-row rule.
            // Stored as the turn *node* path so it compares against `openTurns`
            // directly; the event's own `turnID` is the short id.
            val assistantTurns = LinkedHashMap<String, String>()

            fun flushRun() {
                val builder = run ?: return
                rows.add(builder.build())
                run = null
            }

            nodes.forEach { node ->
                // A tool row is the only grouped kind the projection emits: a
                // *content* row closes the open run first, exactly like the iOS
                // `timelineRows` fold. Structural nodes (`turn-event`) do not: they
                // sit between a call and its result, and closing on them would put
                // one entry in every run.
                //
                // Injected context blocks group the same way (iOS
                // `NativeTranscriptRow.contexts`): one `ChatRow.Context` holds a
                // run of consecutive blocks, anchored on the first block's node
                // id and never re-ordered. A context block is content, so it
                // closes an open tool run first — exactly like a bubble.
                when (node.kind) {
                    UiStateKind.TOOL_ROW -> {
                        if (run == null) {
                            run = RunBuilder(node.nodeID)
                            // Same reason as the turn-end branch below: a tool row is a
                            // slot below its `turn-event` node, so `parentID` names the
                            // event, not the turn, and `runTurn` is compared against
                            // `openTurns` (turn nodeIDs). Reading the parent here made
                            // every running tool row render as STOPPED while its turn was
                            // still open — no fixture caught it because they all hand-built
                            // nodes with the pre-event-node parentage.
                        }
                        // Every tool node is settled against its own turn, because a
                        // run's entries are keyed by node id, not by the run's id.
                        runTurn[node.nodeID] = node.nodeID.substringBefore("/event/")
                        val builder = run ?: return@forEach
                        builder.add(node)
                    }

                    UiStateKind.BUBBLE -> {
                        flushRun()
                        val role = node.props.string("role")
                        val text = node.text.orEmpty()
                        if (role == "assistant") {
                            assistantTurns[node.nodeID] = node.nodeID.substringBefore("/event/")
                            rows.add(ChatRow.Assistant(node.nodeID, text))
                        } else {
                            rows.add(
                                ChatRow.User(
                                    id = node.nodeID,
                                    text = text,
                                    badge = local.badges[node.nodeID],
                                ),
                            )
                        }
                    }

                    UiStateKind.CONTEXT -> {
                        flushRun()
                        val entry = ContextEntry(
                            // The host source name stays un-translated here; the row
                            // renderer calls `contextSourceName` and hides a word it
                            // does not translate.
                            source = node.props.string("source"),
                            text = node.text.orEmpty(),
                        )
                        val previous = rows.lastOrNull()
                        if (previous is ChatRow.Context) {
                            // Consecutive blocks are one disclosure row; consecutive
                            // is decided by the rows, so the structural `turn-event`
                            // node between two events does not split the group.
                            rows[rows.size - 1] = previous.copy(entries = previous.entries + entry)
                        } else {
                            rows.add(ChatRow.Context(id = node.nodeID, entries = listOf(entry)))
                        }
                    }

                    UiStateKind.THINKING_PILL -> {
                        flushRun()
                        rows.add(
                            ChatRow.Thinking(
                                id = node.nodeID,
                                summary = node.text.orEmpty(),
                                streaming = node.props.boolean("streaming"),
                            ),
                        )
                    }

                    UiStateKind.STATUS -> {
                        flushRun()
                        val reason = node.props.string("reason")
                        if (reason != null) {
                            // A turn-end row: closing the turn is state, showing a row
                            // is policy. Only a notable ending becomes visible.
                            //
                            // The turn node is the **grandparent**, not the parent: per
                            // `spec/v1/trajectory.md` §7 a row lives at
                            // `.../turn/<tid>/event/<seq>[/<slot>]`, so its parent is its
                            // `turn-event` node and `parentID` stopped naming the turn when
                            // the projector started emitting that node. This read the
                            // parent while the turn-event node did not exist yet, which is
                            // why it looked correct. `openTurns` is keyed by the turn
                            // node's nodeID, so cut the path at `/event/`.
                            openTurns.remove(node.nodeID.substringBefore("/event/"))
                            if (reason != COMPLETED) {
                                // The host's wire word ("error", "cancelled") is not copy:
                                // iOS shows a translated system-event row, never the token.
                                rows.add(
                                    ChatRow.SystemEvent(
                                        id = node.nodeID,
                                        title = turnReasonTitle(reason),
                                        text = node.props.string("detail").orEmpty(),
                                        isError = reason == ERROR || reason == FAILED,
                                    ),
                                )
                            }
                        } else {
                            val phase = node.props.string("phase")
                            if (phase != null) {
                                rows.add(
                                    ChatRow.SystemEvent(
                                        id = node.nodeID,
                                        title = progressTitle(phase),
                                        text = "",
                                    ),
                                )
                            }
                        }
                    }

                    UiStateKind.APPROVAL_CARD -> {
                        flushRun()
                        val requestId = node.props.string("requestId") ?: node.nodeID
                        if (requestId in local.answeredRequestIds) return@forEach
                        val kind = node.props.string("kind") ?: PERMISSION
                        pending.add(
                            PendingAnswer(
                                id = node.nodeID,
                                requestId = requestId,
                                kind = kind,
                                title = if (kind == QUESTION) {
                                    UiStrings.QUESTION_CARD_TITLE
                                } else {
                                    UiStrings.WAITING_AUTHORIZATION
                                },
                                subtitle = node.text.orEmpty(),
                                options = node.props.stringList("options"),
                                multiple = node.props.boolean("multiple"),
                            ),
                        )
                    }

                    UiStateKind.FAIL_LOUD_BANNER -> {
                        flushRun()
                        val reason = node.props.string("reason") ?: "error"
                        failed = true
                        if (node.nodeID !in local.dismissedBannerIds) {
                            banners.add(
                                BannerState(
                                    id = node.nodeID,
                                    message = node.text ?: UiStrings.TURN_FAILED,
                                    reason = reason,
                                    retryable = node.props.boolean("retryable"),
                                    dismissible = node.props.boolean("dismissible"),
                                ),
                            )
                        }
                    }

                    UiStateKind.TURN -> openTurns.add(node.nodeID)

                    UiStateKind.ROOT,
                    UiStateKind.SESSION,
                    UiStateKind.TURN_EVENT,
                    UiStateKind.COMPOSER,
                    -> Unit
                }
            }
            flushRun()

            // A turn that ended cannot still be running anything: settle a row whose
            // result never arrived to "stopped" instead of leaving it shimmering
            // forever (spec §3 "turn cleanup").
            val settled = rows.map { row ->
                if (row is ChatRow.ToolRun) {
                    val entries = row.entries.map { entry ->
                        if (entry.state == ToolRowState.RUNNING &&
                            runTurn[entry.id]?.let { it !in openTurns } == true
                        ) {
                            entry.copy(
                                state = ToolRowState.STOPPED,
                                summary = if (entry.summary == ToolRowState.RUNNING.label) {
                                    ToolRowState.STOPPED.label
                                } else {
                                    entry.summary
                                },
                            )
                        } else {
                            entry
                        }
                    }
                    if (entries != row.entries) row.copy(entries = entries) else row
                } else {
                    row
                }
            }

            // iOS `isTurnClosingAssistant`: the turn's last assistant row carries the
            // turn-wide actions; only a *closed* turn has one.
            val closed = settled.map { row ->
                if (row is ChatRow.Assistant && assistantTurns[row.id]?.let { it !in openTurns } == true) {
                    val turn = assistantTurns[row.id]
                    val lastAssistant = settled.lastOrNull {
                        it is ChatRow.Assistant && assistantTurns[it.id] == turn
                    }
                    if (lastAssistant?.id == row.id) row.copy(closing = true) else row
                } else {
                    row
                }
            }

            // At most two asks share the slot: the permission card stays on top,
            // the other folds into one line (spec §2 "审批卡" fold rule). A third
            // ask is a protocol violation; it is counted, not dropped silently.
            val primary = pending.lastOrNull { it.kind == PERMISSION } ?: pending.lastOrNull()
            val folded = pending.filterNot { it === primary }.takeLast(MAX_FOLDED_ASKS)
            val slot = PendingSlot(
                primary = primary,
                folded = folded,
                hidden = pending.size - folded.size - (if (primary != null) 1 else 0),
            )
            val phase = when {
                nodes.isEmpty() -> ChatPhase.WAITING
                failed -> ChatPhase.FAILED
                openTurns.isNotEmpty() -> ChatPhase.RUNNING
                else -> ChatPhase.IDLE
            }
            // Spec §3: keyboard up and not manually expanded folds the whole area.
            val fold = if (slot.isEmpty || local.pendingSlotExpanded || !local.imeVisible) {
                PendingFold.EXPANDED
            } else {
                PendingFold.FOLDED
            }
            val lock = when {
                phase == ChatPhase.WAITING -> ComposerLock.WAITING_ENGINE
                !slot.isEmpty -> ComposerLock.PENDING_ANSWER
                else -> ComposerLock.NONE
            }
            val running = phase == ChatPhase.RUNNING
            val steering = host.enterMode == EnterMode.STEER
            // iOS `composerEnabled`: an ask on screen or a permission write in
            // flight freezes the dock; while a turn runs the *steer/queue* capability
            // decides, otherwise `canSend` does.
            val enabled = lock == ComposerLock.NONE && !host.selectingAccessMode &&
                if (running) (if (steering) host.canSteer else host.canSend) else host.canSend
            val trimmed = local.draft.trim()
            val hasText = trimmed.isNotEmpty()
            val hasAttachments = local.attachments.isNotEmpty()
            // iOS `canSubmit`: steering cannot carry attachments.
            val canSubmit = enabled && when {
                running && steering -> hasText && !hasAttachments
                running -> hasText
                else -> hasText || hasAttachments
            }
            val placeholder = when {
                !running -> UiStrings.COMPOSER_PLACEHOLDER_IDLE
                steering -> UiStrings.COMPOSER_PLACEHOLDER_STEER
                else -> UiStrings.COMPOSER_PLACEHOLDER_QUEUE
            }
            val sendLabel = when {
                !running -> UiStrings.COMPOSER_SEND_LABEL
                steering -> UiStrings.COMPOSER_SEND_LABEL_STEER
                else -> UiStrings.COMPOSER_SEND_LABEL_QUEUE
            }
            val queued = closed.filterIsInstance<ChatRow.User>()
                .filter { it.badge == UiStrings.QUEUED_TAG }
                .map { firstLine(it.text) }
            val empty = when {
                !host.engineStarted -> ChatEmpty.ENGINE_NOT_STARTED
                host.providerNeedsKey -> ChatEmpty.PROVIDER_SETUP
                else -> ChatEmpty.READY
            }
            val runStatus = when {
                host.parked -> RunStatus.PARKED
                host.engineStarted -> RunStatus.STARTED
                else -> RunStatus.STOPPED
            }
            return ChatScreenState(
                sessionID = sessionID,
                phase = phase,
                rows = closed,
                pending = slot,
                banners = banners,
                composer = ComposerState(
                    draft = local.draft,
                    // The main key is the stop key only while a turn runs and the
                    // draft cannot be submitted to it (iOS `actionButton`).
                    mode = if (running && !canSubmit) ComposerMode.STOP else ComposerMode.SEND,
                    // A pending ask keeps the dock visible but disabled (spec §2).
                    enabled = enabled,
                    queuedCount = queued.size,
                    queued = queued,
                    placeholder = placeholder,
                    sendLabel = sendLabel,
                    canSubmit = canSubmit,
                    running = running,
                    steering = steering,
                    attachments = local.attachments,
                    attachmentError = local.attachmentError,
                    fileImportNotice = local.fileImportNotice,
                    slash = slashMenu(local.draft, host),
                    reference = referenceMenu(local.draft, host),
                ),
                goal = goal,
                expandedRowIds = local.expandedRowIds,
                stats = stats,
                pendingFold = fold,
                pendingExpanded = local.pendingSlotExpanded,
                composerLock = lock,
                transcript = TranscriptState(
                    hasMore = host.transcript.hasMore,
                    loadingEarlier = host.transcript.loadingEarlier,
                    error = host.transcript.error,
                    showingCached = host.transcript.showingCached,
                ),
                empty = empty,
                runStatus = runStatus,
                starting = host.starting,
                failedItemID = host.failedItemID,
                userFacingError = banners.firstOrNull()?.message,
                accessModeError = host.accessModeError,
                commandsError = host.commandsError,
                accessModeMenu = AccessModeMenu(
                    options = host.accessModes,
                    currentID = host.currentAccessMode?.id,
                    currentTitle = host.currentAccessMode?.title,
                    error = host.accessModeError,
                    // iOS disables the menu while a turn runs, an ask is pending or a
                    // write is in flight.
                    enabled = enabled && !running && slot.isEmpty,
                ),
                modelMenu = ModelMenu(
                    modelName = host.currentModel.orEmpty(),
                    effortTitle = host.effortTitle,
                    models = host.models,
                    currentModel = host.currentModel,
                    efforts = host.efforts,
                    currentEffort = host.currentEffort,
                    defaultEffortTitle = host.defaultEffortTitle,
                    enabled = enabled && !running && slot.isEmpty,
                ),
                contextPercent = host.contextPercent,
            )
        }

        /** The in-place `/` menu, or `null` while the trigger is not open. */
        private fun slashMenu(draft: String, host: ChatHostFacts): SlashMenu? {
            val token = triggerToken(draft, '/') ?: return null
            if (host.commandsLoading && host.commands.isEmpty()) return SlashMenu.Loading
            val error = host.commandsError
            if (error != null && host.commands.isEmpty()) return SlashMenu.Failed(error)
            val matches = when {
                token.isEmpty() -> host.commands.take(MAX_COMMANDS)
                else -> host.commands.filter {
                    it.name.contains(token, ignoreCase = true) ||
                        it.description.contains(token, ignoreCase = true)
                }.take(MAX_COMMANDS)
            }
            return if (matches.isEmpty()) SlashMenu.Empty else SlashMenu.Matches(matches)
        }

        /** The in-place `@` menu, or `null` while the trigger is not open. */
        private fun referenceMenu(draft: String, host: ChatHostFacts): ReferenceMenu? {
            val token = triggerToken(draft, '@') ?: return null
            val files = host.files
                .filter { token.isEmpty() || it.contains(token, ignoreCase = true) }
                .take(MAX_COMMANDS)
            val sessions = if (token.isEmpty()) {
                emptyList()
            } else {
                host.sessionTitles.filter { it.contains(token, ignoreCase = true) }.take(MAX_SESSIONS)
            }
            return ReferenceMenu(files = files, sessions = sessions)
        }
    }

    /** Accumulates consecutive tool-row nodes into one visible run. */
    private class RunBuilder(private val firstNodeID: String) {
        private val entries = LinkedHashMap<String, ToolEntry>()
        private val names = LinkedHashMap<String, String>()

        fun add(node: UiStateNode) {
            val phase = node.props.string("phase")
            val callId = node.props.string("callId") ?: node.nodeID
            val name = node.props.string("name") ?: names[callId]
            if (name != null) names[callId] = name
            val existing = entries[callId]
            when (phase) {
                CALL_PHASE -> {
                    entries[callId] = ToolEntry(
                        id = node.nodeID,
                        title = name ?: node.text.orEmpty(),
                        summary = UiStrings.TOOL_RUNNING,
                        state = ToolRowState.RUNNING,
                        banner = name ?: node.text.orEmpty(),
                    )
                }

                else -> {
                    val state = if (node.props.boolean("isError") || node.props.string("state") == ERROR) {
                        ToolRowState.ERROR
                    } else {
                        ToolRowState.OK
                    }
                    val output = node.text.orEmpty()
                    entries[callId] = ToolEntry(
                        // A result without a preceding call is its own line, anchored
                        // on its own node so the expansion key is stable.
                        id = existing?.id ?: node.nodeID,
                        title = name ?: existing?.title ?: output,
                        summary = output,
                        state = state,
                        banner = name ?: existing?.title.orEmpty(),
                        body = output,
                    )
                }
            }
        }

        fun build(): ChatRow.ToolRun = ChatRow.ToolRun(id = firstNodeID, entries = entries.values.toList())
    }
}

/** The leading `/token` or `@token` while it is still a bare token (iOS trigger). */
private fun triggerToken(draft: String, marker: Char): String? {
    val trimmed = draft.trim()
    if (!trimmed.startsWith(marker)) return null
    val body = trimmed.drop(1)
    if (body.any { it.isWhitespace() }) return null
    return body
}

/** The first non-empty line of a message, for one-line rows. */
private fun firstLine(text: String): String =
    text.lineSequence().firstOrNull { it.isNotBlank() }?.trim().orEmpty()

/**
 * The Chinese source name of an injected context block (iOS `NativeSourceName`).
 * A name this app does not translate returns `null` and is hidden, never printed:
 * `user-approval` and `command` are host-internal words, not copy.
 *
 * Public because the row renderer is the only place a context block becomes
 * visible; the projection emits no context kind yet, so this is where the iOS
 * translation table lives until one exists.
 *
 * @param raw the host's source name.
 * @return the Chinese name, or `null` when it must stay hidden.
 */
public fun contextSourceName(raw: String?): String? = when (raw?.trim()?.lowercase()) {
    "user-approval", "user_approval" -> UiStrings.CONTEXT_SOURCE_APPROVAL
    "file", "workspace", "files" -> UiStrings.CONTEXT_SOURCE_FILES
    "command", "shell" -> UiStrings.CONTEXT_SOURCE_COMMAND
    "search", "web-search" -> UiStrings.CONTEXT_SOURCE_SEARCH
    else -> null
}

/** A turn-end reason as the Chinese system-event title (never the wire word). */
private fun turnReasonTitle(reason: String): String = when (reason) {
    ERROR, FAILED -> UiStrings.SYSTEM_EVENT_TURN_FAILED
    CANCELLED, ABORTED, INTERRUPTED -> UiStrings.SYSTEM_EVENT_TURN_CANCELLED
    MAX_TOKENS -> UiStrings.SYSTEM_EVENT_MAX_TOKENS
    else -> UiStrings.SYSTEM_EVENT_TURN
}

/** A progress row's Chinese title (iOS shows a system-event row for these too). */
private fun progressTitle(phase: String): String = when {
    phase == LLM_RETRY || phase.startsWith("$LLM_RETRY/") -> UiStrings.SYSTEM_EVENT_RETRY
    phase == COMPACTION || phase.startsWith("$COMPACTION/") -> UiStrings.SYSTEM_EVENT_COMPACTION
    else -> UiStrings.SYSTEM_EVENT_TURN
}

/** Reads a string prop, or `null` when absent or not a string. */
internal fun com.phonedsh.agentcore.JsonObject.string(key: String): String? =
    (this[key] as? JsonString)?.value

/** Reads a boolean prop; absent means false. */
internal fun com.phonedsh.agentcore.JsonObject.boolean(key: String): Boolean =
    (this[key] as? JsonBool)?.value ?: false

/** Reads a string array prop; absent means empty. */
internal fun com.phonedsh.agentcore.JsonObject.stringList(key: String): List<String> =
    (this[key] as? com.phonedsh.agentcore.JsonArray)?.values?.mapNotNull { (it as? JsonString)?.value }
        ?: emptyList()

/** The `kind` prop value of a permission ask. */
private const val PERMISSION: String = "permission"

/** The `kind` prop value of a question ask. */
private const val QUESTION: String = "question"

/** The one turn-end reason that closes a turn without a visible row. */
private const val COMPLETED: String = "completed"

/** The turn-end reasons that read as a failure. */
private const val ERROR: String = "error"
private const val FAILED: String = "failed"
private const val CANCELLED: String = "cancelled"
private const val ABORTED: String = "aborted"
private const val INTERRUPTED: String = "interrupted"
private const val MAX_TOKENS: String = "max_tokens"

/** The progress phases that become a system-event row. */
private const val LLM_RETRY: String = "llm/retry"
private const val COMPACTION: String = "compaction"

/** The `tool-row` phase that announces a call. */
private const val CALL_PHASE: String = "call"

/**
 * How many asks beyond the primary card the slot may show (spec §2 "合计最多 2 项").
 */
private const val MAX_FOLDED_ASKS: Int = 1

/** How many items the in-place `/` and `@` menus list (iOS `.prefix(6)`). */
private const val MAX_COMMANDS: Int = 6

/** How many sessions the `@` menu lists (iOS `.prefix(3)`). */
private const val MAX_SESSIONS: Int = 3

/** The one access-mode title that means "never ask again" (iOS literal). */
private const val FULL_PERMISSION_TITLE: String = "完全权限"
