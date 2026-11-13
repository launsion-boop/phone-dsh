// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.driver

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.rows.BotActionResult
import com.phonedsh.bot.rows.BotRowBatch
import com.phonedsh.bot.rows.BotUserAction
import com.phonedsh.ui.bot.state.BotRuntimePresentation
import com.phonedsh.ui.bot.state.BotUIHistoryPage
import kotlinx.coroutines.flow.Flow

/**
 * One frame of the running main-chat turn (`BotLiveFrame`).
 *
 * `Event` carries the raw `turn/start`, `step/start`, `tool/call`,
 * `assistant/message` and `turn/end` events; the view owns only the
 * display-order projection of them (`BotLiveTurn.swift:97-159`).
 */
public sealed interface BotLiveFrame {
    /** The turn started streaming; no text yet. */
    public data object StreamStart : BotLiveFrame

    /** One text delta of the model attempt that is streaming now. */
    public data class TextDelta(public val text: String) : BotLiveFrame

    /** One DSH event of the turn, unchanged. */
    public data class Event(public val event: JsonObject) : BotLiveFrame
}

/**
 * Tool steps of one finished turn, keyed by DSH turn number.
 *
 * The chat page no longer renders tool/process rows (`spec/ui/v1/pages/bot-chat.md`
 * §4: "不显示工具行、思考行或回合过程行"), so [toolNames] is view-only data that
 * never becomes a message row. The projection owns the original rows; this is
 * the narrow value the driver seam exposes.
 */
public data class BotTurnProcess(
    public val turn: Int,
    public val toolNames: List<String> = emptyList(),
)

/**
 * The narrowest chat boundary, mirroring the frozen iOS surface
 * `BotChatDriver{history, watch, perform, stopCurrentTurn, turnProcesses,
 * liveFrames, presentation}` (`BotUIModels.swift:464-476`,
 * `spec/ui/v1/bot/ui-state.md` §1).
 *
 * `watch`, `liveFrames` and `presentation` are cold [Flow]s on Android: the
 * caller collects them for as long as the page is active. The other four
 * members are suspend/pull operations, exactly as on iOS.
 */
public interface BotChatDriver {
    /** Older rows before a row-id anchor; `limit` is at most 50 in the view. */
    public suspend fun history(before: String?, limit: Int): BotUIHistoryPage

    /**
     * Rows/deletes after a numeric cursor. Emits at most one batch per host
     * poll; a batch with `reset = true` replaces every non-local row.
     */
    public fun watch(cursor: Long): Flow<BotRowBatch>

    /** One user intent; exactly the P27 result vocabulary. */
    public suspend fun perform(action: BotUserAction): BotActionResult

    /** Stop the named turn (`null` = the current turn). */
    public suspend fun stopCurrentTurn(turnID: String?)

    /** Tool steps of finished turns; never a message row. */
    public suspend fun turnProcesses(): Map<Int, BotTurnProcess>

    /** Live frames of the running main-chat turn. */
    public fun liveFrames(): Flow<BotLiveFrame>

    /** The durable fish lifecycle, running turn id, activity and one-shot. */
    public fun presentation(): Flow<BotRuntimePresentation>
}
