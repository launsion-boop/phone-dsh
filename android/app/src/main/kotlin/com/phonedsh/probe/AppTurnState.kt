// phone-dsh — :app: the one turn's UI-visible state.
// SPDX-License-Identifier: MIT
//
// The screen never invents a completed turn. [Idle] before the button,
// [Running] while the client is on the channel, [Completed] only after the
// Worker's own `turn_ended` with reason `completed`, and [Failed] with a short
// token-free reason otherwise.
//
// [Completed] also carries what the turn's own `tool_call` events named: the
// commands it ran and the paths a write tool produced. Those are the two things
// the workbench sheet can show without reading anything the worker did not send.
// Nothing is inferred from a tool name alone: a command row exists only when the
// event carried a command string, and a file row only when a write tool named a
// path. The fields default to empty so a caller cannot claim a tool ran.

package com.phonedsh.probe

import com.phonedsh.domain.session.ArchivedTurn

/** One command a `tool_call` event named, with its call id. */
internal data class TurnToolCommand(
    val id: String,
    val command: String,
)

/** One path a write tool named, with the tool that named it. */
internal data class TurnWrite(
    val path: String,
    val toolName: String?,
)

/** The turn surface of the probe screen. */
internal sealed interface AppTurnState {
    /** No turn has been started this process. */
    data object Idle : AppTurnState

    /** A prompt is in flight; the events are logged as they are projected. */
    data object Running : AppTurnState

    /**
     * The Worker reported `turn_ended(reason=completed)`.
     *
     * @param sessionId the Worker's session id.
     * @param kinds the projected host kinds, in wire order.
     * @param commands the tool calls that named a command.
     * @param writes the write tools that named a path.
     * @param restored true only when this turn came back from the
     *   [com.phonedsh.domain.session.SessionArchive] at launch, i.e. the
     *   **previous** process completed it. The screen must not present that as a
     *   completion of the current process: `完成` and `完成（上次进程）` are
     *   different claims, and before this flag existed the card could only say
     *   the first.
     */
    data class Completed(
        val sessionId: String,
        val kinds: List<String>,
        val commands: List<TurnToolCommand> = emptyList(),
        val writes: List<TurnWrite> = emptyList(),
        val restored: Boolean = false,
    ) : AppTurnState

    /** The turn did not complete; [reason] is a code or a class name. */
    data class Failed(val reason: String) : AppTurnState

    /**
     * A one-line Chinese label for the card; the code stays in [toString].
     *
     * A restored completion says so in the label. The card's own line
     * ([RESTORED_LINE]) is the longer sentence; the label is the glanceable one.
     */
    fun label(): String = when (this) {
        Idle -> "未开始"
        Running -> "进行中"
        is Completed -> if (restored) RESTORED_LABEL else "完成"
        is Failed -> "失败"
    }

    companion object {
        /**
         * The label of a turn the previous process completed.
         *
         * iOS writes a status line instead of a label
         * (`ChatModel.swift:2576`: `显示上次对话，引擎在后台启动…`); the label has
         * to fit the card's caption slot, so the provenance is the short half.
         */
        const val RESTORED_LABEL: String = "完成（上次进程）"

        /**
         * The sentence a restored completion shows under its card.
         *
         * The baseline's own words are `显示上次对话，引擎在后台启动…`
         * (`ChatModel.swift:2576`, set together with `isShowingCachedTranscript`).
         * Android keeps the opening claim verbatim and states the one fact the
         * iOS sentence leaves implicit: the turn was completed by the previous
         * process. The baseline's trailing clause is not copied: it is a
         * transient status on iOS (the next host message overwrites it), while
         * this line stays on screen until the next turn, so repeating
         * 「引擎在后台启动…」 after the engine had started would become false.
         */
        const val RESTORED_LINE: String = "显示上次对话 · 上次进程的回合"
    }
}

/**
 * The projection of an archived turn back into the screen's state.
 *
 * Nothing is invented: an archived turn is one the Worker completed, so it maps
 * to [AppTurnState.Completed] and never to [AppTurnState.Running]. It is marked
 * [AppTurnState.Completed.restored] because this process did not run it — that
 * flag is what lets the card say 「上次进程的回合」 instead of claiming a
 * completion the person did not just watch.
 *
 * It lives here, next to the state it produces, so the mapping is a plain
 * function the JVM suite can drive without a device.
 */
internal fun ArchivedTurn.toRestoredCompleted(): AppTurnState.Completed =
    AppTurnState.Completed(
        sessionId = sessionId,
        kinds = kinds,
        commands = commands.map { TurnToolCommand(it.id, it.command) },
        writes = writes.map { TurnWrite(it.path, it.toolName) },
        restored = true,
    )

