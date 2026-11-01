// Turn grouping for the session history and activity pages.
// SPDX-License-Identifier: MIT
//
// Spec: `spec/ui/v1/README.md` §3.1. A turn is a structural UiState node
// (`session/<sid>/turn/<tid>`): grouping the event nodes under it is a render-time
// fold over UiState, so it belongs to ScreenState and never rewrites the sequence.
// `spec/v1/trajectory.md` §7 forbids inventing a turn: a node with `turnID: "-"`
// (a session-level row) belongs to no group and is skipped here.
package com.phonedsh.ui.page

import com.phonedsh.ui.projection.UiStateKind
import com.phonedsh.ui.projection.UiStateNode
import com.phonedsh.ui.state.boolean
import com.phonedsh.ui.state.string

/** How a turn ended; `OPEN` means the stream carried no turn-end. */
internal enum class TurnOutcome { OPEN, COMPLETED, FAILED, CANCELLED }

/**
 * One turn: its structural node, its event nodes and the two counts a history row
 * can honestly show.
 *
 * @param nodes every node of the turn in projection order (the turn node first).
 */
internal data class TurnGroup(
    val turnID: String,
    val ordinal: Int,
    val outcome: TurnOutcome,
    val messageCount: Int,
    val toolCallCount: Int,
    val nodes: List<UiStateNode>,
)

/**
 * Groups the projection by turn, preserving projection order.
 *
 * A "message" is a `bubble` node; a "tool call" is a `tool-row` node with
 * `phase: call`. Results are not counted as calls, so a run of N calls and N
 * results reports N.
 */
internal fun groupTurns(nodes: List<UiStateNode>): List<TurnGroup> {
    val grouped = LinkedHashMap<String, MutableList<UiStateNode>>()
    nodes.forEach { node ->
        if (node.turnID == NO_TURN) return@forEach
        grouped.getOrPut(node.turnID) { mutableListOf() }.add(node)
    }
    return grouped.entries.mapIndexed { index, (turnID, turnNodes) ->
        val status = turnNodes.lastOrNull {
            it.kind == UiStateKind.STATUS && it.props.string("reason") != null
        }
        TurnGroup(
            turnID = turnID,
            ordinal = index + 1,
            outcome = status?.props?.string("reason").outcome(),
            messageCount = turnNodes.count { it.kind == UiStateKind.BUBBLE },
            toolCallCount = turnNodes.count {
                it.kind == UiStateKind.TOOL_ROW && it.props.string("phase") == CALL_PHASE
            },
            nodes = turnNodes,
        )
    }
}

/** A turn-end reason to the outcome the history shows. */
internal fun TurnOutcome.label(): String = when (this) {
    TurnOutcome.OPEN -> com.phonedsh.ui.UiStrings.TURN_OPEN
    TurnOutcome.COMPLETED -> com.phonedsh.ui.UiStrings.TURN_COMPLETED
    TurnOutcome.FAILED -> com.phonedsh.ui.UiStrings.FAILED_STATUS
    TurnOutcome.CANCELLED -> com.phonedsh.ui.UiStrings.TURN_CANCELLED
}

private fun String?.outcome(): TurnOutcome = when (this) {
    null -> TurnOutcome.OPEN
    "completed" -> TurnOutcome.COMPLETED
    "error", "failed" -> TurnOutcome.FAILED
    else -> TurnOutcome.CANCELLED
}

/** `tool-row` nodes that announce a call (a result carries another phase). */
private const val CALL_PHASE: String = "call"

/** The structural turn id of a session-level row (`spec/v1/trajectory.md` §7). */
private const val NO_TURN: String = "-"
