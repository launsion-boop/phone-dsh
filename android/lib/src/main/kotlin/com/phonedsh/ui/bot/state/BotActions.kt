// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.bot.rows.BotActionResult
import com.phonedsh.bot.rows.BotRow
import com.phonedsh.bot.rows.BotRowBodyType

/** The four local action-state key families (`ui-state.md` §3.1). */
public object BotActionKeys {
    public fun card(rowID: String): String = "card:$rowID"
    public fun approval(rowID: String): String = "approval:$rowID"
    public fun dismiss(rowID: String): String = "dismiss:$rowID"
    public fun chat(localRowID: String): String = "chat:$localRowID"

    /** The row id of a `dismiss:` key, or null for another key family. */
    public fun dismissRowID(key: String): String? =
        key.removePrefix("dismiss:").takeIf { key.startsWith("dismiss:") && it.isNotEmpty() }
}

/** One key's local state: pending, accepted, or failed and retryable. */
public sealed interface BotActionState {
    public data object Pending : BotActionState
    public data object Accepted : BotActionState
    public data class Failed(public val reason: String) : BotActionState
}

/**
 * The per-key action state machine of §3.1, including the UI-2 decision: a
 * failed `cardDismiss` is retryable exactly like `cardAnswer` and `approval`
 * (`state == nil || state == failed`). A second tap while `pending` or
 * `accepted` is ignored, so no duplicate intent is produced.
 *
 * A denied approval that is part of "the next send" is marked pending by
 * [markAwaitingApprovalsPending], performed before the chat action, and
 * recorded by [finishAutoDecline] once the driver accepts it.
 */
public data class BotActionStateMachine(
    public val states: Map<String, BotActionState> = emptyMap(),
    public val dismissedCardIDs: Set<String> = emptySet(),
    public val answeredOptionIDs: Map<String, String> = emptyMap(),
    public val autoDeclinedApprovalIDs: Set<String> = emptySet(),
) {
    public fun state(key: String): BotActionState? = states[key]

    /** A key is actionable only when absent or failed (UI-2). */
    public fun canBegin(key: String): Boolean = when (states[key]) {
        null, is BotActionState.Failed -> true
        is BotActionState.Pending, is BotActionState.Accepted -> false
    }

    /** Marks [key] pending; null means the tap is ignored (no duplicate intent). */
    public fun begin(key: String): BotActionStateMachine? =
        if (canBegin(key)) copy(states = states + (key to BotActionState.Pending)) else null

    /** `cardAnswer`: only a parsed question/steps card, not muted, non-empty option. */
    public fun beginAnswer(
        row: BotRow,
        optionID: String,
        mutedCardIDs: Collection<String> = emptyList(),
    ): BotActionStateMachine? {
        val kind = BotUICardContent.parse(row)?.kind
        if (kind != BotUICardKind.QUESTION && kind != BotUICardKind.STEPS) return null
        if (row.id in mutedCardIDs) return null
        if (optionID.isEmpty()) return null
        val next = begin(BotActionKeys.card(row.id)) ?: return null
        return next.copy(answeredOptionIDs = answeredOptionIDs + (row.id to optionID))
    }

    /**
     * `cardDismiss`: only a parsed question card (steps do not support dismiss)
     * and never a muted card.
     */
    public fun beginDismiss(
        row: BotRow,
        mutedCardIDs: Collection<String> = emptyList(),
    ): BotActionStateMachine? {
        if (BotUICardContent.parse(row)?.kind != BotUICardKind.QUESTION) return null
        if (row.id in mutedCardIDs) return null
        return begin(BotActionKeys.dismiss(row.id))
    }

    /** `approval`: only a parsed approval card. */
    public fun beginApproval(row: BotRow): BotActionStateMachine? {
        if (BotUICardContent.parse(row)?.kind != BotUICardKind.APPROVAL) return null
        return begin(BotActionKeys.approval(row.id))
    }

    /** `chat`: the local row id keys the pending send. */
    public fun beginChat(localRowID: String): BotActionStateMachine? =
        begin(BotActionKeys.chat(localRowID))

    /**
     * Applies one P27 result. Accepted/duplicate set `accepted`; any other
     * result sets `failed`. An accepted `cardDismiss` also records the dismissed
     * card so the question settles to 「已关闭」.
     */
    public fun finish(key: String, result: BotActionResult): BotActionStateMachine {
        val next = when (result) {
            is BotActionResult.Accepted, is BotActionResult.Duplicate -> BotActionState.Accepted
            is BotActionResult.Stale -> BotActionState.Failed(result.reason)
            is BotActionResult.Rejected -> BotActionState.Failed(result.reason)
        }
        var updated = copy(states = states + (key to next))
        if (next is BotActionState.Accepted) {
            BotActionKeys.dismissRowID(key)?.let { rowID ->
                updated = updated.copy(dismissedCardIDs = dismissedCardIDs + rowID)
            }
        }
        return updated
    }

    /** Finishes an auto-decline deny and records the local truth on acceptance. */
    public fun finishAutoDecline(
        approvalRowID: String,
        result: BotActionResult,
    ): BotActionStateMachine {
        val next = finish(BotActionKeys.approval(approvalRowID), result)
        return if (next.state(BotActionKeys.approval(approvalRowID)) is BotActionState.Accepted) {
            next.copy(autoDeclinedApprovalIDs = autoDeclinedApprovalIDs + approvalRowID)
        } else {
            next
        }
    }

    /** Approvals still awaiting a decision: pending status, no pending/accepted key. */
    public fun awaitingApprovals(rows: List<BotRow>): List<BotRow> = rows.filter { row ->
        row.body.type == BotRowBodyType.APPROVAL &&
            row.approvalStatus() == "pending" &&
            when (state(BotActionKeys.approval(row.id))) {
                is BotActionState.Pending, is BotActionState.Accepted -> false
                else -> true
            }
    }

    /**
     * Marks every still-awaiting approval `pending` synchronously, before the
     * next chat is performed (the deny actions run in order, then the chat).
     */
    public fun markAwaitingApprovalsPending(rows: List<BotRow>): BotActionStateMachine {
        var next = this
        for (row in awaitingApprovals(rows)) {
            next = next.copy(
                states = next.states +
                    (BotActionKeys.approval(row.id) to BotActionState.Pending))
        }
        return next
    }
}

/** The three card intents whose retry policy §3.1 freezes. */
public enum class BotActionIntentKind(public val wire: String) {
    DISMISS("dismiss"),
    ANSWER("answer"),
    APPROVAL("approval"),
    ;

    public companion object {
        public fun fromWire(value: String): BotActionIntentKind =
            entries.firstOrNull { it.wire == value }
                ?: throw IllegalArgumentException("unknown action intent: $value")
    }
}

/**
 * The §3.1 retry guard, including the UI-2 decision:
 *
 * - a `pending` or `accepted` key is never retryable (the tap is ignored);
 * - an absent (`null`) or `failed` key is actionable;
 * - `dismiss` is offered only on a parsed `question` card (steps has no dismiss);
 * - `answer` and `approval` use the same `state == nil || state == failed`
 *   guard as the reference view.
 *
 * `state == null` means the key is absent; [BotActionState.Failed] carries the
 * failure reason only for the runtime notice.
 */
public object BotActionRetryPolicy {
    public fun isRetryable(
        action: BotActionIntentKind,
        cardKind: BotUICardKind?,
        state: BotActionState?,
    ): Boolean {
        if (state is BotActionState.Pending || state is BotActionState.Accepted) return false
        return when (action) {
            BotActionIntentKind.DISMISS -> cardKind == BotUICardKind.QUESTION
            BotActionIntentKind.ANSWER, BotActionIntentKind.APPROVAL -> true
        }
    }
}
