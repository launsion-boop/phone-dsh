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
     */
    data class Completed(
        val sessionId: String,
        val kinds: List<String>,
        val commands: List<TurnToolCommand> = emptyList(),
        val writes: List<TurnWrite> = emptyList(),
    ) : AppTurnState

    /** The turn did not complete; [reason] is a code or a class name. */
    data class Failed(val reason: String) : AppTurnState

    /** A one-line Chinese label for the card; the code stays in [toString]. */
    fun label(): String = when (this) {
        Idle -> "未开始"
        Running -> "进行中"
        is Completed -> "完成"
        is Failed -> "失败"
    }
}
