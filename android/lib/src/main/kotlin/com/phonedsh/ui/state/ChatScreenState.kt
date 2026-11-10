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
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.projection.UiStateKind
import com.phonedsh.ui.projection.UiStateNode
import com.phonedsh.ui.surface.ChatFileChange
import com.phonedsh.ui.surface.ComposerMode
import com.phonedsh.ui.surface.ToolRowState
import com.phonedsh.ui.surface.lineDelta
import androidx.compose.runtime.Immutable
import kotlin.math.roundToInt

/** Compact or detailed presentation for the native composer metrics row. */
public enum class ComposerStatsMode { COMPACT, DETAILED }

/** Session-level activity metrics, present only when the host projection reports them. */
@Immutable
public data class SessionStats(
    public val turns: Long,
    public val steps: Long,
    public val llmMs: Double,
    public val toolMs: Double,
    public val ttftMs: Double,
    public val ttftSteps: Long,
    public val decodeMs: Double,
    public val decodeTokens: Long,
) {
    public val tokensPerSecond: Double? get() = if (decodeMs > 0) decodeTokens / (decodeMs / 1_000.0) else null
}

/** Session-level token counters. A missing object stays unavailable. */
@Immutable
public data class SessionTokenUsage(
    public val uncachedInputTokens: Long,
    public val outputTokens: Long,
    public val cacheReadTokens: Long,
    public val cacheWriteTokens: Long,
) {
    init {
        require(safeTokenSum(uncachedInputTokens, cacheReadTokens, cacheWriteTokens, outputTokens) != null) {
            "session token totals exceed the supported integer range"
        }
    }
    public val billedInputTokens: Long get() = safeTokenSum(uncachedInputTokens, cacheReadTokens, cacheWriteTokens)!!
    public val totalTokens: Long get() = safeTokenSum(uncachedInputTokens, cacheReadTokens, cacheWriteTokens, outputTokens)!!
    public val cacheHitPercent: Double? get() = if (billedInputTokens > 0) cacheReadTokens * 100.0 / billedInputTokens else null
}

private fun safeTokenSum(vararg values: Long): Long? {
    var sum = 0L
    for (value in values) {
        if (value < 0 || Long.MAX_VALUE - sum < value) return null
        sum += value
    }
    return sum
}

@Immutable
public data class ContextPressure(
    public val pressureTokens: Long?,
    public val projectedTokens: Long?,
    public val contextWindow: Long,
) {
    public val usedTokens: Long? get() = projectedTokens ?: pressureTokens
    public val percent: Int? get() = usedTokens?.let {
        (it * 100.0 / contextWindow).roundToInt().coerceIn(0, 100)
    }
}

@Immutable
public data class ContextBreakdown(
    public val systemTokens: Long,
    public val toolsTokens: Long,
    public val messageTokens: Long,
)

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
    /** Structured `tool/call.arguments`, retained for native per-tool details. */
    public val arguments: JsonObject? = null,
    /** Tool-result metadata when the host event supplied it. */
    public val metadata: JsonObject? = null,
    /** Number of host call/result events folded into this visual entry. */
    public val sourceEventCount: Int = 1,
    /** Tool kind derived from the actual tool name, never from its prose output. */
    public val variant: ToolVariant = ToolVariant.fromName(title),
) {
    /** The common iOS tool-row title mapping; unknown names keep their received label. */
    public val displayTitle: String
        get() = when (title) {
            "bash", "pwsh", "exec_command", "write_stdin" -> "运行命令"
            "read" -> "读取"
            "read_image" -> "读取图片"
            "grep" -> "搜索文件内容"
            "glob" -> "查找文件"
            "web_search" -> "网页搜索"
            "web_fetch" -> "网页获取"
            "edit", "apply_patch", "str_replace_editor" -> "编辑"
            "write" -> "写入"
            "todo_write" -> "更新任务清单"
            "ask_user_question", "request_user_input" -> "提问"
            "exit_plan_mode" -> "提交计划"
            else -> title
        }
}

/** Tool-detail families used by iOS `NativeToolCallModel`. */
public enum class ToolVariant {
    BASH, READ, WRITE, EDIT, SEARCH, WEB_SEARCH, WEB_FETCH, QUESTION, PLAN, TODO, GENERIC;

    public companion object {
        public fun fromName(name: String): ToolVariant = when (name) {
            "bash", "pwsh", "exec_command", "write_stdin" -> BASH
            "read", "read_image" -> READ
            "write" -> WRITE
            "edit", "apply_patch", "str_replace_editor" -> EDIT
            "grep", "glob", "session_search", "session_event_search", "session_trace" -> SEARCH
            "web_search" -> WEB_SEARCH
            "web_fetch" -> WEB_FETCH
            "ask_user_question", "request_user_input" -> QUESTION
            "exit_plan_mode" -> PLAN
            "todo_write" -> TODO
            else -> if (name.startsWith("terminal_")) BASH else GENERIC
        }
    }
}

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
     * @param changes the files the closed turn edited, in tool-call order; empty
     *   hides the "已编辑 N 个文件" card. The row renderer draws it under the body,
     *   the way `NativeChangedFilesCard.swift` sits inside `assistantBody`.
     */
    public data class Assistant(
        override val id: String,
        public val text: String,
        public val streaming: Boolean = false,
        public val closing: Boolean = false,
        public val changes: List<ChatFileChange> = emptyList(),
        public val usage: TurnUsage? = null,
    ) : ChatRow

    /** A reasoning row (iOS `NativeThinkingRow`). */
    public data class Thinking(
        override val id: String,
        public val summary: String,
        public val streaming: Boolean,
        /** Bounded source reasoning for disclosure; null when only a summary was supplied. */
        public val fullReasoning: String? = null,
        /** Whether [fullReasoning] lost source text to the UiState text limit; null for older hosts. */
        public val fullReasoningTruncated: Boolean? = null,
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

        /** The renderer's one-line preview; complete output remains in each entry's body. */
        public val summary: String get() = entries.lastOrNull()?.summary?.lineSequence()?.firstOrNull().orEmpty()
    }

    /** Consecutive reasoning and tool activity for one turn (iOS process group). */
    public data class ProcessGroup(
        override val id: String,
        public val turnID: String,
        public val entries: List<ChatRow>,
        public val categories: List<ChatProcessCategory>,
        public val title: String,
        public val running: Boolean,
        public val showsHeader: Boolean,
    ) : ChatRow

    /** Closed-turn control row; its entries are the foldable body before the final answer. */
    public data class TurnProcess(
        override val id: String,
        public val turnID: String,
        public val outcome: ChatTurnState,
        public val elapsedMillis: Long? = null,
        public val foldable: Boolean = false,
        public val expanded: Boolean = false,
        public val entries: List<ChatRow> = emptyList(),
        public val closingAssistant: Assistant? = null,
    ) : ChatRow

    /** One closed turn's action row; optional host facts remain absent. */
    public data class TurnTail(
        override val id: String,
        public val turnID: String,
        public val assistantText: String,
        public val timeMillis: Long? = null,
        public val usage: TurnUsage? = null,
        public val feedbackAvailable: Boolean = false,
        public val branchAvailable: Boolean = false,
    ) : ChatRow

    /** Consecutive injected context blocks, folded into one disclosure line. */
    public data class Context(
        override val id: String,
        public val entries: List<ContextEntry>,
    ) : ChatRow

    /** A late answer to a prior question request (iOS `NativeQuestionReplyBubble`). */
    public data class QuestionReply(
        override val id: String,
        public val text: String,
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

/** The outcomes the iOS turn-process control can display. */
public enum class ChatTurnState { RUNNING, COMPLETED, STOPPED, FAILED }

/** Only measured token counters are retained; missing counts are not zero-filled. */
public data class TurnUsage(
    public val inputTokens: Long? = null,
    public val outputTokens: Long? = null,
) {
    public val totalTokens: Long? get() = if (inputTokens != null && outputTokens != null) inputTokens + outputTokens else null
}

/** Activity categories and title rules mirrored from iOS `NativeProcessGroupModel`. */
public enum class ChatProcessCategory(
    public val runningLabel: String,
    public val finishedLabel: String,
) {
    THINKING("正在分析请求", "已完成分析"),
    READ("正在读取文件", "已读取文件"),
    READ_IMAGE("正在读取图片", "已读取图片"),
    SEARCH("正在搜索代码", "已搜索代码"),
    EDIT("正在编辑文件", "修改了文件"),
    WRITE("正在写入文件", "已写入文件"),
    COMMANDS("正在运行命令", "执行了命令"),
    CODE("正在运行代码", "运行了代码"),
    WEB_SEARCH("正在搜索网页", "已搜索网页"),
    WEB_FETCH("正在访问网页", "已访问网页"),
    SUBAGENTS("正在协调子智能体", "已协调子智能体"),
    PLAN("正在更新计划", "更新了计划"),
    QUESTIONS("等待你的操作", "向用户提出了问题"),
    TOOLS("正在调用工具", "已调用工具"),
    ;

    public companion object {
        public fun forTool(name: String): ChatProcessCategory = when (name) {
            "read" -> READ
            "read_image" -> READ_IMAGE
            "grep", "glob", "session_search", "session_event_search", "session_trace" -> SEARCH
            "edit", "apply_patch", "str_replace_editor" -> EDIT
            "write" -> WRITE
            "bash", "pwsh", "exec_command", "write_stdin" -> COMMANDS
            "run_code" -> CODE
            "web_search" -> WEB_SEARCH
            "web_fetch" -> WEB_FETCH
            "subagent", "list_agents", "list_subagent_models", "send_message", "wait_agent",
            "interrupt_agent", "spawn_teammate" -> SUBAGENTS
            "todo_write", "exit_plan_mode" -> PLAN
            "ask_user_question", "request_user_input" -> QUESTIONS
            else -> if (name.startsWith("terminal_")) COMMANDS else TOOLS
        }

        public fun title(categories: List<ChatProcessCategory>, running: Boolean): String {
            val unique = categories.distinct()
            val first = unique.firstOrNull() ?: THINKING
            if (running) {
                return if (unique.size == 1) first.runningLabel
                else unique.joinToString("，") { it.runningLabel } + "等"
            }
            if (unique.size == 1) return first.finishedLabel
            if (unique.size == 2) {
                val second = unique[1].finishedLabel
                return if (first.finishedLabel.startsWith("已") && second.startsWith("已")) {
                    first.finishedLabel + "并" + second.drop(1)
                } else {
                    first.finishedLabel + "并" + second
                }
            }
            return unique.take(3).joinToString("，") { it.finishedLabel } + "等"
        }
    }
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
    /** Structured question content when the host supplied it. Missing metadata stays null. */
    public val questionItems: List<PendingQuestionItem> = emptyList(),
    /** Submission facts are nullable because the event stream does not report them. */
    public val submitting: Boolean? = null,
    public val submissionError: String? = null,
    public val channelAvailable: Boolean? = null,
    public val initialProgress: PendingQuestionProgress? = null,
    public val form: QuestionFormState? = null,
    public val actionState: PendingAnswerActionState? = null,
) {
    public val typedRequestId: StateRequestId get() = StateRequestId(requestId)
}

public enum class PendingAnswerAction { SUBMIT, DISCARD, MINIMISE, REOPEN }
public enum class PendingAnswerActionStatus { PENDING, SUCCEEDED, FAILED }
public data class PendingAnswerActionState(
    public val requestId: StateRequestId,
    public val action: PendingAnswerAction,
    public val status: PendingAnswerActionStatus,
    public val error: String? = null,
)

/** One option label and optional host-provided description. */
public data class PendingQuestionOption(
    public val label: String,
    public val description: String? = null,
)

/** The independently answerable question shape used by the native question UI. */
public data class PendingQuestionItem(
    public val id: String,
    public val header: String? = null,
    public val prompt: String,
    public val detail: String? = null,
    public val options: List<PendingQuestionOption> = emptyList(),
    public val multiple: Boolean = false,
    public val intentKind: String? = null,
    public val approveWireLabel: String? = null,
    public val recommendedWireLabel: String? = null,
)

/** A host-reported question step and any prefilled answers; absent until reported. */
public data class PendingQuestionProgress(
    public val index: Int,
    public val drafts: Map<String, List<String>> = emptyMap(),
    public val customAnswers: Map<String, String> = emptyMap(),
)

/** Local form state keeps each question's multiple selections and custom text separately. */
public data class QuestionFormState(
    public val index: Int,
    public val questionIds: List<String>,
    public val answers: Map<String, List<String>> = emptyMap(),
    public val customAnswers: Map<String, String> = emptyMap(),
) {
    public val currentQuestionId: String? get() = questionIds.getOrNull(index)
    public val canGoBack: Boolean get() = index > 0 && index < questionIds.size
    public val canGoForward: Boolean get() = index >= 0 && index + 1 < questionIds.size
    public val missingRequiredQuestionIds: List<String> get() = questionIds.filter { id ->
        answers[id].orEmpty().none { it.isNotBlank() } && customAnswers[id].isNullOrBlank()
    }
    public val complete: Boolean get() = missingRequiredQuestionIds.isEmpty()
}

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

/** Host state needed for visible status, restart acknowledgement, and send-to-start. */
public enum class EngineLifecycleStatus { UNKNOWN, STOPPED, STARTING, RUNNING, RECOVERING, FAILED }

/** One measured lifecycle snapshot, shared by Chat and the General settings tab. */
@Immutable
public data class EngineLifecycleFacts(
    public val status: EngineLifecycleStatus = EngineLifecycleStatus.UNKNOWN,
    /** The host's safe state label, when it has one; never an error payload. */
    public val statusLabel: String? = null,
    public val needsReset: Boolean = false,
    public val canStartBySending: Boolean = false,
)

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
    /** Whether this command accepts an input value (host registry declaration). */
    public val hasInput: Boolean = true,
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
    /** Null while the host has not reported whether the catalog read completed. */
    public val catalogLoaded: Boolean? = null,
    /** True while the read is retried automatically; the control shows a spinner. */
    public val loading: Boolean = false,
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
    /** Null while the host has not reported whether the catalog read completed. */
    public val catalogLoaded: Boolean? = null,
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
    /** True while the access-mode read is retried automatically. */
    public val accessModeLoading: Boolean = false,
    public val accessModesLoaded: Boolean? = null,
    /** The model catalog. */
    public val models: List<String> = emptyList(),
    public val currentModel: String? = null,
    public val effortTitle: String? = null,
    public val efforts: List<EffortOption> = emptyList(),
    public val currentEffort: String? = null,
    public val modelsLoaded: Boolean? = null,
    public val defaultEffortTitle: String = UiStrings.MODEL_DEFAULT_EFFORT,
    /** Workspace relative paths for the `@` menu. */
    public val files: List<String> = emptyList(),
    /** Session titles for the `@` menu. */
    public val sessionTitles: List<String> = emptyList(),
    /** Worker session id for request-bound queue/steer/stop commands; null before one exists. */
    public val workerSessionID: String? = null,
    /** The permissions menu is mid-write (iOS `isSelectingAccessMode`). */
    public val selectingAccessMode: Boolean = false,
    /** The estimated context-window share; `null` hides the ring. */
    public val contextPercent: Int? = null,
    /** Current authoritative session-projection todos, when the host provides them. */
    public val todoItems: List<TodoDockItem> = emptyList(),
    /** Whether any phone agent/device is online; null means the host did not read it. */
    public val hasOnlineDevices: Boolean? = null,
    /** Host lifecycle details; `null` means not measured by this caller. */
    public val lifecycle: EngineLifecycleFacts? = null,
    /** Host-owned plan state; null means the host has not supplied a snapshot. */
    public val plan: PlanApprovalState? = null,
    public val queueItems: List<ManagedQueueItemState>? = null,
    public val commandReceipts: List<CommandExecutionReceipt>? = null,
    public val artifacts: List<ArtifactReference>? = null,
    public val contextLost: ContextLostReceipt? = null,
    public val snapshotRevision: StateRevision? = null,
    public val sessionStats: SessionStats? = null,
    public val tokenUsage: SessionTokenUsage? = null,
    public val contextPressure: ContextPressure? = null,
    public val contextBreakdown: ContextBreakdown? = null,
    public val composerStatsMode: ComposerStatsMode = ComposerStatsMode.DETAILED,
)

/** One todo row from `session/projections.values.todos`; status remains a wire fact. */
public data class TodoDockItem(
    public val id: String,
    public val content: String,
    public val status: String,
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
        /** Parsed host lifecycle phase; null when an unknown phase word was received. */
        public val phaseKind: GoalPhase? = null,
        public val goalID: String? = null,
        public val canPause: Boolean? = null,
        public val canResume: Boolean? = null,
        public val canClear: Boolean? = null,
    ) : GoalBarState
}

public enum class GoalPhase { ACTIVE, PAUSED, BLOCKED }

/**
 * The local UI events of the screen. Nothing here is inferred from the engine:
 * a draft is what the user typed, an answered request is what the user tapped.
 */
public data class ChatLocalState(
    public val draft: String = "",
    /** Request ids the user already answered; their cards leave the slot. */
    public val answeredRequestIds: Set<String> = emptySet(),
    /** Typed, request-correlated pending-card action state; failed submissions retain input. */
    public val pendingAnswerActions: Map<StateRequestId, PendingAnswerActionState> = emptyMap(),
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
    /** Session whose transient form state this belongs to, when known. */
    public val sessionID: String? = null,
)

/** Opaque, typed request identity used to correlate async responses. */
@JvmInline
public value class StateRequestId(public val value: String)

/** A monotonically increasing host revision; absent revisions remain unknown. */
@JvmInline
public value class StateRevision(public val value: Long) : Comparable<StateRevision> {
    override fun compareTo(other: StateRevision): Int = value.compareTo(other.value)
}

/** Session-scoped revisioned snapshot. A different session is never implicitly adopted. */
public data class RevisionedSnapshot<T>(
    public val sessionID: String,
    public val revision: StateRevision,
    public val value: T,
)

/** Only an explicit user switch or a host-confirmed not-found may bind another session. */
public enum class SessionChangeCause { USER_SELECTED, SESSION_NOT_FOUND, RESTORE, INCIDENTAL_RESPONSE }

public sealed interface SessionBindingResult {
    public data class Bound(public val sessionID: String) : SessionBindingResult
    public data class Retained(public val sessionID: String, public val rejectedSessionID: String) : SessionBindingResult
}

public fun bindSession(
    currentSessionID: String,
    requestedSessionID: String,
    cause: SessionChangeCause,
): SessionBindingResult = when {
    currentSessionID == requestedSessionID -> SessionBindingResult.Bound(currentSessionID)
    cause == SessionChangeCause.USER_SELECTED || cause == SessionChangeCause.SESSION_NOT_FOUND ->
        SessionBindingResult.Bound(requestedSessionID)
    else -> SessionBindingResult.Retained(currentSessionID, requestedSessionID)
}

/** Result of considering a snapshot update against current session and revision. */
public sealed interface SnapshotUpdate<out T> {
    public data class Applied<T>(public val snapshot: RevisionedSnapshot<T>) : SnapshotUpdate<T>
    public data class IgnoredOlder<T>(public val current: RevisionedSnapshot<T>) : SnapshotUpdate<T>
    public data class WrongSession<T>(public val expectedSessionID: String, public val receivedSessionID: String) : SnapshotUpdate<T>
}

/** Pure serialized/coalesced snapshot acceptance; late old snapshots cannot overwrite newer facts. */
public fun <T> acceptSnapshot(
    current: RevisionedSnapshot<T>?,
    expectedSessionID: String,
    incoming: RevisionedSnapshot<T>,
): SnapshotUpdate<T> = when {
    incoming.sessionID != expectedSessionID -> SnapshotUpdate.WrongSession(expectedSessionID, incoming.sessionID)
    current != null && current.sessionID == expectedSessionID && incoming.revision <= current.revision ->
        SnapshotUpdate.IgnoredOlder(current)
    else -> SnapshotUpdate.Applied(incoming)
}

/** A typed request may settle state only while it still owns that state slot. */
public data class StateRequest<T>(
    public val id: StateRequestId,
    public val sessionID: String,
    public val revision: StateRevision,
    public val value: T,
)

public fun <T> StateRequest<T>.isCurrent(
    activeRequestId: StateRequestId?,
    activeSessionID: String,
    minimumRevision: StateRevision?,
): Boolean = id == activeRequestId && sessionID == activeSessionID &&
    (minimumRevision == null || revision >= minimumRevision)

/** Submitted `exit_plan_mode` content and explicit host approval status. */
public data class PlanApprovalState(
    public val requestId: StateRequestId,
    public val markdown: String,
    public val status: PlanApprovalStatus = PlanApprovalStatus.PENDING,
    public val submissionError: String? = null,
)

public enum class PlanApprovalStatus { PENDING, APPROVED, REJECTED, DISMISSED }

/** Host-confirmed command result; callbacks alone are not a receipt. */
public data class CommandExecutionReceipt(
    public val requestId: StateRequestId,
    public val command: String,
    public val input: String? = null,
    public val outcome: CommandOutcome,
    public val message: String? = null,
)

public enum class CommandOutcome { SUCCEEDED, FAILED }

/** An artifact may be explicitly turn/session scoped or unattributed. */
public data class ArtifactReference(
    public val id: String,
    public val name: String,
    public val path: String? = null,
    public val scope: ArtifactScope = ArtifactScope.UNKNOWN,
    public val sessionID: String? = null,
    public val turnID: String? = null,
)

public enum class ArtifactScope { TURN, SESSION, UNKNOWN }

/** Durable context-loss fact kept visible after a failed action or restore. */
public data class ContextLostReceipt(
    public val requestId: StateRequestId,
    public val sessionID: String,
    public val message: String,
    public val contextID: String? = null,
)

/** Stable queue row: durable and local identifiers are distinct by construction. */
public data class ManagedQueueItemState(
    public val id: QueueItemId,
    public val text: String,
    public val state: QueueItemStatus? = null,
    public val canEdit: Boolean? = null,
    public val canRemove: Boolean? = null,
    public val canSteer: Boolean? = null,
    public val busy: Boolean? = null,
    public val actionRequestId: StateRequestId? = null,
    public val receipt: QueueActionReceipt? = null,
    /** Worker session that owns the durable inbox item; null for local-only rows. */
    public val sessionId: String? = null,
    public val lane: String? = null,
    /** Stable backend prompt identity for a locally pending queue/steer submission. */
    public val promptRequestId: StateRequestId? = null,
)

public data class QueueActionReceipt(
    public val requestId: StateRequestId,
    public val action: QueueAction,
    public val outcome: CommandOutcome,
    public val message: String? = null,
    public val sessionId: String? = null,
    public val itemId: String? = null,
)

public enum class QueueAction { QUEUE, EDIT, REMOVE, STEER }

public sealed interface QueueItemId {
    public data class Durable(public val value: String) : QueueItemId
    public data class Local(public val value: String) : QueueItemId
}

public enum class QueueItemStatus { QUEUED, SENDING, STEERED }

/**
 * Durable rows keep their actionable IDs; local echoes are never paired by text.
 *
 * DSH's QueueDock removes a pending submission once its `source.rpcId` appears
 * in the inbox. The same identity rule applies here: a durable row replaces the
 * local echo for that exact backend prompt, including a failed echo left by an
 * ambiguous prompt response.
 */
public fun reconcileQueueRows(
    durable: List<ManagedQueueItemState>,
    local: List<ManagedQueueItemState>,
): List<ManagedQueueItemState> {
    val durablePromptIds = durable.mapNotNull { it.promptRequestId }.toSet()
    return durable + local.filterNot { item ->
        item.promptRequestId != null && item.promptRequestId in durablePromptIds
    }
}

/** Retire only the local echo for the exact backend prompt acknowledged and read back. */
public fun retireAcceptedQueuePrompt(
    local: List<ManagedQueueItemState>,
    promptRequestId: StateRequestId,
): List<ManagedQueueItemState> = local.filterNot { item ->
    item.id is QueueItemId.Local && item.promptRequestId == promptRequestId
}

/**
 * A live inbox proves acceptance of every local echo whose backend rpcId it
 * carries. Retire those echoes instead of only hiding them at render time: once
 * the durable row is consumed, a retained echo would reappear as a ghost row.
 */
public fun retireQueuePromptsPresentIn(
    local: List<ManagedQueueItemState>,
    durable: List<ManagedQueueItemState>,
): List<ManagedQueueItemState> {
    if (local.isEmpty() || durable.isEmpty()) return local
    val observed = durable.mapNotNull { it.promptRequestId }.toSet()
    if (observed.isEmpty()) return local
    return local.filterNot { item ->
        item.promptRequestId != null && item.promptRequestId in observed
    }
}

/** The complete screen state of the chat page. */
public data class ChatScreenState(
    public val sessionID: String,
    /** Worker session id for management RPCs; absent before the first Worker session exists. */
    public val workerSessionID: String? = null,
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
    /** The access-mode read failure; shown in the access-mode menu, never as a page banner. */
    public val accessModeError: String? = null,
    /** The command-catalog read failure; the composer's banner shows it. */
    public val commandsError: String? = null,
    /** The composer's access-mode menu. */
    public val accessModeMenu: AccessModeMenu = AccessModeMenu(),
    /** The composer's model menu. */
    public val modelMenu: ModelMenu = ModelMenu(),
    /** The estimated share of the context window in use; `null` hides the ring. */
    public val contextPercent: Int? = null,
    /** The host's current todo snapshot; empty means no rows were supplied. */
    public val todoItems: List<TodoDockItem> = emptyList(),
    /** The phone status icon's online marker; null hides only the marker. */
    public val hasOnlineDevices: Boolean? = null,
    /** The host lifecycle facts the page can render and use to unlock send-to-start. */
    public val lifecycle: EngineLifecycleFacts? = null,
    public val plan: PlanApprovalState? = null,
    public val queueItems: List<ManagedQueueItemState>? = null,
    public val commandReceipts: List<CommandExecutionReceipt>? = null,
    public val artifacts: List<ArtifactReference>? = null,
    public val contextLost: ContextLostReceipt? = null,
    public val snapshotRevision: StateRevision? = null,
    public val sessionStats: SessionStats? = null,
    public val tokenUsage: SessionTokenUsage? = null,
    public val contextPressure: ContextPressure? = null,
    public val contextBreakdown: ContextBreakdown? = null,
    public val composerStatsMode: ComposerStatsMode = ComposerStatsMode.DETAILED,
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
            // Session-bound transient forms and queue markers must not leak to a
            // different session. Preserve the draft so a switch cannot silently
            // discard user input; clear only state that names prior-session rows.
            val uiLocal = if (local.sessionID != null && local.sessionID != sessionID) {
                local.copy(
                    answeredRequestIds = emptySet(), dismissedBannerIds = emptySet(),
                    pendingAnswerActions = emptyMap(),
                    expandedRowIds = emptySet(), badges = emptyMap(), attachments = emptyList(),
                    attachmentError = null, fileImportNotice = null, pendingSlotExpanded = false,
                )
            } else local
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
                // A row with nothing to say is not a row. On a restored session the
                // host's result node can arrive without a name and without output
                // (the call/result pair lost its `callId`), and the page painted a
                // bare `工具调用 ·` line for each of them — two per call, on the
                // real transcript. iOS only draws a line it can name.
                val built = builder.build()
                if (built.entries.isNotEmpty()) rows.add(built)
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
                            node.props.string("reasoning")?.takeIf { it.isNotBlank() }?.let { reasoning ->
                                rows.add(ChatRow.Thinking(id = "${node.nodeID}/reasoning", summary = reasoning, streaming = false))
                            }
                            assistantTurns[node.nodeID] = node.nodeID.substringBefore("/event/")
                            rows.add(
                                ChatRow.Assistant(
                                    id = node.nodeID,
                                    text = text,
                                    usage = node.props.usage(),
                                ),
                            )
                        } else {
                            rows.add(
                                ChatRow.User(
                                    id = node.nodeID,
                                    text = text,
                                    badge = uiLocal.badges[node.nodeID],
                                ),
                            )
                        }
                    }

                    UiStateKind.CONTEXT -> {
                        flushRun()
                        if (node.props.string("source") == QUESTION_REPLY_SOURCE) {
                            rows.add(ChatRow.QuestionReply(node.nodeID, node.text.orEmpty()))
                            return@forEach
                        }
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
                                fullReasoning = node.props.string("fullReasoning"),
                                fullReasoningTruncated = node.props.nullableBoolean("fullReasoningTruncated"),
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
                        if (requestId in uiLocal.answeredRequestIds) return@forEach
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
                                questionItems = node.props.questionItems(),
                                submitting = node.props.nullableBoolean("submitting"),
                                submissionError = node.props.string("submissionError"),
                                channelAvailable = node.props.nullableBoolean("channelAvailable"),
                                initialProgress = node.props.questionProgress(),
                                form = node.props.questionForm(),
                                actionState = uiLocal.pendingAnswerActions[StateRequestId(requestId)],
                            ),
                        )
                    }

                    UiStateKind.FAIL_LOUD_BANNER -> {
                        flushRun()
                        val reason = node.props.string("reason") ?: "error"
                        failed = true
                        if (node.nodeID !in uiLocal.dismissedBannerIds) {
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
            // turn-wide actions; only a *closed* turn has one. The same row also
            // carries the turn's changed files (`NativeTranscriptProjector.changes`),
            // because iOS renders that card inside `assistantBody` (`ChatPage.swift:3699`).
            val closed = settled.map { row ->
                val turn = if (row is ChatRow.Assistant) assistantTurns[row.id] else null
                if (row is ChatRow.Assistant && turn != null && turn !in openTurns) {
                    val lastAssistant = settled.lastOrNull {
                        it is ChatRow.Assistant && assistantTurns[it.id] == turn
                    }
                    if (lastAssistant?.id == row.id) {
                        row.copy(closing = true, changes = changedFilesFor(nodes, turn))
                    } else {
                        row
                    }
                } else {
                    row
                }
            }

            val timeline = turnAwareRows(closed, nodes, openTurns, uiLocal.expandedRowIds)

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
            val fold = if (slot.isEmpty || uiLocal.pendingSlotExpanded || !uiLocal.imeVisible) {
                PendingFold.EXPANDED
            } else {
                PendingFold.FOLDED
            }
            val lock = when {
                phase == ChatPhase.WAITING && host.lifecycle?.canStartBySending != true -> ComposerLock.WAITING_ENGINE
                !slot.isEmpty -> ComposerLock.PENDING_ANSWER
                else -> ComposerLock.NONE
            }
            val running = phase == ChatPhase.RUNNING
            val steering = host.enterMode == EnterMode.STEER
            // iOS `composerEnabled`: an ask on screen or a permission write in
            // flight freezes the dock; while a turn runs the *steer/queue* capability
            // decides, otherwise `canSend` does.
            val enabled = lock == ComposerLock.NONE && !host.selectingAccessMode &&
                if (running) (if (steering) host.canSteer else host.canSend)
                else host.canSend || host.lifecycle?.canStartBySending == true
            val trimmed = uiLocal.draft.trim()
            val hasText = trimmed.isNotEmpty()
            val hasAttachments = uiLocal.attachments.isNotEmpty()
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
                workerSessionID = host.workerSessionID,
                phase = phase,
                rows = timeline,
                pending = slot,
                banners = banners,
                composer = ComposerState(
                    draft = uiLocal.draft,
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
                    attachments = uiLocal.attachments,
                    attachmentError = uiLocal.attachmentError,
                    fileImportNotice = uiLocal.fileImportNotice,
                    slash = slashMenu(uiLocal.draft, host),
                    reference = referenceMenu(uiLocal.draft, host),
                ),
                goal = goal,
                expandedRowIds = uiLocal.expandedRowIds,
                stats = stats,
                pendingFold = fold,
                pendingExpanded = uiLocal.pendingSlotExpanded,
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
                    catalogLoaded = host.accessModesLoaded,
                    loading = host.accessModeLoading,
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
                    catalogLoaded = host.modelsLoaded,
                ),
                contextPercent = host.contextPercent,
                sessionStats = host.sessionStats,
                tokenUsage = host.tokenUsage,
                contextPressure = host.contextPressure,
                contextBreakdown = host.contextBreakdown,
                composerStatsMode = host.composerStatsMode,
                todoItems = host.todoItems,
                hasOnlineDevices = host.hasOnlineDevices,
                lifecycle = host.lifecycle,
                plan = host.plan,
                queueItems = host.queueItems,
                commandReceipts = host.commandReceipts,
                artifacts = host.artifacts,
                contextLost = host.contextLost,
                snapshotRevision = host.snapshotRevision,
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
                    val arguments = node.props["arguments"].asObject()
                    val variant = ToolVariant.fromName(name.orEmpty())
                    entries[callId] = ToolEntry(
                        id = node.nodeID,
                        title = name ?: node.text.orEmpty(),
                        summary = UiStrings.TOOL_RUNNING,
                        state = ToolRowState.RUNNING,
                        banner = name ?: node.text.orEmpty(),
                        filePath = arguments.pathFor(variant),
                        arguments = arguments,
                        metadata = node.props["meta"] as? JsonObject,
                        sourceEventCount = 1,
                        variant = variant,
                    )
                }

                else -> {
                    val state = if (node.props.boolean("isError") || node.props.string("state") == ERROR) {
                        ToolRowState.ERROR
                    } else {
                        ToolRowState.OK
                    }
                    val output = node.props.string("body") ?: node.text.orEmpty()
                    val arguments = existing?.arguments
                    entries[callId] = ToolEntry(
                        // A result without a preceding call is its own line, anchored
                        // on its own node so the expansion key is stable.
                        id = existing?.id ?: node.nodeID,
                        title = name ?: existing?.title ?: output,
                        summary = output,
                        state = state,
                        banner = name ?: existing?.title.orEmpty(),
                        body = output,
                        filePath = (node.props["meta"] as? JsonObject)?.string("path") ?: existing?.filePath,
                        arguments = arguments,
                        metadata = (node.props["meta"] as? JsonObject) ?: existing?.metadata,
                        sourceEventCount = (existing?.sourceEventCount ?: 0) + 1,
                        variant = ToolVariant.fromName(name ?: existing?.title.orEmpty()),
                    )
                }
            }
        }

        fun build(): ChatRow.ToolRun = ChatRow.ToolRun(
            id = firstNodeID,
            entries = entries.values.filterNot { entry ->
                entry.title.isEmpty() && entry.summary.isEmpty() && entry.body.isEmpty()
            },
        )
    }
}

/** The file path iOS exposes for read/write/edit calls, from their real arguments. */
private fun JsonObject?.pathFor(variant: ToolVariant): String? {
    if (variant !in setOf(ToolVariant.READ, ToolVariant.WRITE, ToolVariant.EDIT)) return null
    return this?.string("file_path") ?: this?.string("path")
}

/** Accept the raw object or the JSON string form carried by a host bridge. */
private fun JsonValue?.asObject(): JsonObject? = when (this) {
    is JsonObject -> this
    is JsonString -> (runCatching { JsonValue.parse(value) }.getOrNull() as? JsonObject)
    else -> null
}

/** The leading `/token` or `@token` while it is still a bare token (iOS trigger). */
/** Builds the iOS-style per-turn timeline from the event-anchored rows. */
private fun turnAwareRows(
    rows: List<ChatRow>,
    nodes: List<UiStateNode>,
    openTurns: Set<String>,
    expandedRowIds: Set<String>,
): List<ChatRow> {
    val explicitEnd = LinkedHashMap<String, UiStateNode>()
    val startTimes = HashMap<String, Long>()
    nodes.forEach { node ->
        if (node.kind == UiStateKind.TURN) {
            node.props.long("startedAtMs")?.let { startTimes[turnKey(node.nodeID)] = it }
        }
        if (node.kind == UiStateKind.STATUS && node.props.string("reason") in TURN_END_REASONS) {
            explicitEnd[turnKey(node.nodeID)] = node
        }
    }

    val groupedProcesses = mutableListOf<ChatRow>()
    var processKey: String? = null
    var processEntries = mutableListOf<ChatRow>()
    fun flushProcess() {
        if (processEntries.isEmpty()) return
        val key = processKey.orEmpty()
        val categories = processEntries.flatMap { row ->
            when (row) {
                is ChatRow.Thinking -> listOf(ChatProcessCategory.THINKING)
                is ChatRow.ToolRun -> row.entries.map { ChatProcessCategory.forTool(it.title) }
                else -> emptyList()
            }
        }.distinct()
        val isRunning = processEntries.any { row ->
            when (row) {
                is ChatRow.Thinking -> row.streaming
                is ChatRow.ToolRun -> row.entries.any { it.state == ToolRowState.RUNNING }
                else -> false
            }
        }
        val memberCount = processEntries.sumOf { row ->
            when (row) {
                is ChatRow.Thinking -> 1
                is ChatRow.ToolRun -> row.entries.sumOf { it.sourceEventCount }
                else -> 1
            }
        }
        groupedProcesses += ChatRow.ProcessGroup(
            id = "process/$key/${processEntries.first().id}",
            turnID = key,
            entries = processEntries.toList(),
            categories = categories,
            title = ChatProcessCategory.title(categories, isRunning),
            running = isRunning,
            showsHeader = memberCount > 1,
        )
        processEntries = mutableListOf()
        processKey = null
    }
    rows.forEach { row ->
        val key = row.turnIDOrNull()
        val process = row is ChatRow.Thinking || row is ChatRow.ToolRun
        if (!process) {
            flushProcess()
            groupedProcesses += row
        } else {
            if (processEntries.isNotEmpty() && processKey != key) flushProcess()
            if (processKey == null) processKey = key
            processEntries += row
        }
    }
    flushProcess()

    val byTurn = LinkedHashMap<String, MutableList<ChatRow>>()
    groupedProcesses.forEach { row ->
        val key = row.turnIDOrNull()
        if (key != null) byTurn.getOrPut(key) { mutableListOf() }.add(row)
    }
    val result = mutableListOf<ChatRow>()
    // The projection order is the timeline order; each turn is a contiguous slice.
    val consumed = HashSet<String>()
    groupedProcesses.forEach { row ->
        val key = row.turnIDOrNull()
        if (key == null) {
            result += row
        } else if (consumed.add(key)) {
            val items = byTurn.getValue(key)
            val end = explicitEnd[key]
            val isOpen = openTurns.any { turnKey(it) == key }
            val assistants = items.filterIsInstance<ChatRow.Assistant>()
            val closing = assistants.lastOrNull()
            val reason = end?.props?.string("reason")
            val outcome = when {
                isOpen -> ChatTurnState.RUNNING
                reason == ERROR || reason == FAILED -> ChatTurnState.FAILED
                reason == CANCELLED || reason == ABORTED || reason == INTERRUPTED -> ChatTurnState.STOPPED
                else -> ChatTurnState.COMPLETED
            }
            val hasEnded = end != null || (!isOpen && closing != null)
            val inputRows = items.filter {
                it is ChatRow.User || it is ChatRow.Context || it is ChatRow.QuestionReply
            }
            val contentRows = items.filterNot {
                it is ChatRow.User || it is ChatRow.Context || it is ChatRow.QuestionReply
            }
            val hasProcess = contentRows.any { it is ChatRow.ProcessGroup || it is ChatRow.Thinking || it is ChatRow.ToolRun }
            val foldable = outcome == ChatTurnState.COMPLETED && closing != null && hasProcess
            result += inputRows
            if (hasEnded) {
                val endTime = end?.props?.long("endedAtMs")
                val elapsed = end?.props?.long("elapsedMillis")
                    ?: startTimes[key]?.let { start -> endTime?.minus(start)?.coerceAtLeast(0L) }
                val processID = "turn-process/$key"
                result += ChatRow.TurnProcess(
                    id = processID,
                    turnID = key,
                    outcome = outcome,
                    elapsedMillis = elapsed,
                    foldable = foldable,
                    expanded = !foldable || processID in expandedRowIds,
                    entries = contentRows,
                    closingAssistant = closing,
                )
                if (closing != null) {
                    val allAssistantText = assistants.joinToString("\n\n") { it.text }
                    val usage = turnUsage(items)
                    result += ChatRow.TurnTail(
                        id = "turn-tail/$key",
                        turnID = key,
                        assistantText = allAssistantText,
                        timeMillis = endTime,
                        usage = usage,
                    )
                }
            } else {
                result += contentRows
            }
        }
    }
    return result
}

private fun turnUsage(rows: List<ChatRow>): TurnUsage? {
    val assistant = rows.filterIsInstance<ChatRow.Assistant>().lastOrNull() ?: return null
    val raw = assistant.usage ?: return null
    return raw
}

/** Structural turn key from a row's anchored node id. */
private fun ChatRow.turnIDOrNull(): String? = when (this) {
    is ChatRow.ProcessGroup -> turnID
    is ChatRow.TurnProcess -> turnID
    is ChatRow.TurnTail -> turnID
    else -> turnKey(id).takeIf { it.isNotEmpty() }
}

private fun turnKey(nodeID: String): String {
    val turn = nodeID.substringBefore("/event/").substringAfterLast("/turn/", "")
    if (turn.isEmpty()) return ""
    if (turn.endsWith("-local")) return turn.removeSuffix("-local")
    val workerSuffix = TURN_SUFFIX.find(turn)
    return if (workerSuffix != null && workerSuffix.range.first > 0) {
        turn.removeRange(workerSuffix.range)
    } else {
        turn
    }
}

private fun JsonObject.long(key: String): Long? =
    (this[key] as? com.phonedsh.agentcore.JsonNumber)?.asLongOrNull()

private fun JsonObject.usage(): TurnUsage? {
    val usage = this["usage"] as? JsonObject ?: return null
    val input = usage.long("inputTokens") ?: usage.long("input_tokens")
    val output = usage.long("outputTokens") ?: usage.long("output_tokens")
    if (input == null && output == null) return null
    return TurnUsage(inputTokens = input, outputTokens = output)
}

private val TURN_SUFFIX = Regex("-turn-[0-9]{4}$")
private val TURN_END_REASONS = setOf(
    "completed", "error", "failed", "cancelled", "aborted", "interrupted", "max_tokens", "max-tokens",
)

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

/**
 * The files a closed turn changed, from its tool-call arguments.
 *
 * Mirror: `NativeTranscriptProjector.changes(forTurn:in:)`
 * (`NativeTranscriptProjector.swift:155-193`). iOS scans the turn's `toolCall`
 * items whose state settled to `.ok`, keeps the tools that write (`write`,
 * `edit`, `str_replace_editor`), reads the path and the old/new text from the
 * call's arguments, and runs the LCS diff in `lineDelta`. A later call for the
 * same path replaces the earlier entry *in place*, which is what the `positions`
 * map does there and what [LinkedHashMap] does here.
 *
 * @param nodes the UiState projection, in order.
 * @param turn the turn's node id (`.../turn/<tid>`); a node belongs to it when its
 *   own id has that prefix before `/event/`.
 * @return one entry per file, in first-touch order; empty when the turn edited none.
 */
private fun changedFilesFor(nodes: List<UiStateNode>, turn: String): List<ChatFileChange> {
    // The call node carries the arguments; only a settled, successful result makes
    // the iOS projector count it (`item.toolState == .ok`).
    val settled = HashMap<String, Boolean>()
    nodes.forEach { node ->
        if (node.kind != UiStateKind.TOOL_ROW) return@forEach
        if (node.props.string("phase") != PHASE_RESULT) return@forEach
        val callId = node.props.string("callId") ?: return@forEach
        settled[callId] = !node.props.boolean("isError")
    }

    val files = LinkedHashMap<String, ChatFileChange>()
    nodes.forEach { node ->
        if (node.kind != UiStateKind.TOOL_ROW) return@forEach
        if (node.nodeID.substringBefore("/event/") != turn) return@forEach
        if (node.props.string("phase") != PHASE_CALL) return@forEach
        val name = node.props.string("name") ?: return@forEach
        if (name !in CHANGE_TOOLS) return@forEach
        val callId = node.props.string("callId") ?: node.nodeID
        if (settled[callId] != true) return@forEach
        val raw = node.props.string("arguments") ?: return@forEach
        val args = (runCatching { JsonValue.parse(raw) }.getOrNull() as? JsonObject) ?: return@forEach
        val path = (args["file_path"] ?: args["path"]).asString() ?: return@forEach
        if (path.isEmpty()) return@forEach
        var oldText: String? = null
        var newText: String? = null
        when (name) {
            "write" -> newText = args["content"].asString()
            "edit" -> {
                oldText = args["old_string"].asString()
                newText = args["new_string"].asString()
            }
            else -> when (args["command"].asString()) {
                "create" -> newText = args["file_text"].asString() ?: ""
                "str_replace" -> {
                    oldText = args["old_str"].asString()
                    newText = args["new_str"].asString() ?: ""
                }
                "insert" -> newText = args["new_str"].asString()
            }
        }
        val text = newText ?: return@forEach
        val (added, deleted) = lineDelta(oldText, text)
        files[path] = ChatFileChange(path = path, display = path, added = added, deleted = deleted)
    }
    return files.values.toList()
}

/** A JSON value as a string, or `null` when it is absent or not a string. */
private fun com.phonedsh.agentcore.JsonValue?.asString(): String? = (this as? JsonString)?.value

/** Reads only the question fields retained by `ui-state/1`; absent metadata stays absent. */
private fun JsonObject.questionItems(): List<PendingQuestionItem> =
    ((this["questionItems"] as? JsonArray)?.values.orEmpty()).mapNotNull { raw ->
        val item = raw as? JsonObject ?: return@mapNotNull null
        val id = item.string("id") ?: return@mapNotNull null
        val prompt = item.string("prompt") ?: return@mapNotNull null
        val options = ((item["options"] as? JsonArray)?.values.orEmpty()).mapNotNull { value ->
            when (value) {
                is JsonString -> PendingQuestionOption(value.value)
                is JsonObject -> value.string("label")?.let { PendingQuestionOption(it, value.string("description")) }
                else -> null
            }
        }
        PendingQuestionItem(
            id = id,
            header = item.string("header"),
            prompt = prompt,
            detail = item.string("detail"),
            options = options,
            multiple = item.boolean("multiple"),
            intentKind = item.string("intentKind"),
            approveWireLabel = item.string("approveWireLabel"),
            recommendedWireLabel = item.string("recommendedWireLabel"),
        )
    }

/** Reads a boolean only when the host actually supplied one. */
private fun JsonObject.nullableBoolean(key: String): Boolean? = (this[key] as? JsonBool)?.value

/** Reads optional multi-question progress and answer drafts. */
private fun JsonObject.questionProgress(): PendingQuestionProgress? {
    val progress = this["initialProgress"] as? JsonObject ?: return null
    val index = (progress["index"] as? com.phonedsh.agentcore.JsonNumber)?.asLongOrNull()?.toInt() ?: return null
    val drafts = (progress["drafts"] as? JsonObject)?.members.orEmpty().mapNotNull { (id, value) ->
        val answers = when (value) {
            is JsonString -> listOf(value.value)
            is JsonArray -> value.values.mapNotNull { (it as? JsonString)?.value }
            else -> emptyList()
        }
        if (answers.isEmpty()) null else id to answers
    }.toMap()
    val customAnswers = (progress["customAnswers"] as? JsonObject)?.members.orEmpty()
        .mapNotNull { (id, value) -> (value as? JsonString)?.value?.let { id to it } }
        .toMap()
    return PendingQuestionProgress(index = index, drafts = drafts, customAnswers = customAnswers)
}

private fun JsonObject.questionForm(): QuestionFormState? {
    val items = questionItems()
    if (items.isEmpty()) return null
    val progress = questionProgress()
    return QuestionFormState(
        index = progress?.index ?: 0,
        questionIds = items.map { it.id },
        answers = progress?.drafts.orEmpty(),
        customAnswers = progress?.customAnswers.orEmpty(),
    )
}

/** The tools whose calls count as a changed file (iOS `changes(forTurn:)`, `:159`). */
private val CHANGE_TOOLS: Set<String> = setOf("write", "edit", "str_replace_editor")

/** The projector's tool-call phases (`UiStateProjector.toolCall` / `toolResult`). */
private const val PHASE_CALL: String = "call"
private const val PHASE_RESULT: String = "result"
private const val QUESTION_REPLY_SOURCE: String = "user-question-reply"

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
