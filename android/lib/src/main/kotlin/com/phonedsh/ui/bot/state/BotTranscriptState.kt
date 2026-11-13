// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.bot.rows.BotRow
import com.phonedsh.bot.rows.BotRowBatch
import com.phonedsh.bot.rows.BotRowBodyType
import com.phonedsh.bot.rows.BotRowKind
import com.phonedsh.bot.rows.BotWidgetCardType

/**
 * The view-owned transcript after one `watch` batch (`ui-state.md` §2.1).
 *
 * The durable row types are `:bot`'s `BotRow`/`BotRowBatch`; this state only
 * applies the frozen view rules:
 * - `reset` drops every non-`local-` row, adopts at most the last 50 incoming
 *   rows, and sets the history cursor from the first adopted row;
 * - `deletes` remove stored rows by id before incoming rows are applied;
 * - a same-id row with a larger `updatedSeq` replaces the stored row (equal or
 *   larger, matching the reference's `>` guard);
 * - a progress row with the same `cardKey` updates in place;
 * - a `deleted` body removes the row;
 * - a host-error `notice` in a **non-reset** batch arms [runtimeNotice] and
 *   never becomes a transcript row; a reset batch never replays one.
 *
 * `runtimeNotice` is view-local, display-only: the caller clears it on the next
 * send/success or after `BotTimers.RUNTIME_NOTICE`.
 */
public data class BotTranscriptState(
    public val rows: List<BotRow> = emptyList(),
    public val watchCursor: Long = 0,
    public val historyCursor: String? = null,
    public val hasMoreHistory: Boolean = false,
    public val runtimeNotice: String? = null,
) {
    /** Applies one watch result. */
    public fun apply(batch: BotRowBatch): BotTranscriptState {
        var nextRows = rows
        var incoming = batch.rows
        var history = historyCursor
        var hasMore = hasMoreHistory
        if (batch.reset) {
            nextRows = nextRows.filter { it.id.startsWith(LOCAL_PREFIX) }
            if (incoming.size > HISTORY_PAGE_SIZE) {
                incoming = incoming.takeLast(HISTORY_PAGE_SIZE)
                hasMore = true
            } else {
                hasMore = false
            }
            history = incoming.firstOrNull()?.id
        }
        if (batch.deletes.isNotEmpty()) {
            val deleted = batch.deletes.toSet()
            nextRows = nextRows.filterNot { it.id in deleted }
        }
        var notice = runtimeNotice
        if (!batch.reset) {
            val known = nextRows.map { it.id }.toSet()
            val fresh = incoming.lastOrNull { row ->
                row.id !in known &&
                    row.body.type == BotRowBodyType.NOTICE &&
                    BotUIRendering.isRenderable(row) &&
                    (JsonSupport.string(row.body["tone"]) ?: "error") == "error"
            }
            if (fresh != null) {
                notice = JsonSupport.string(fresh.body["text"])
            }
        }
        for (row in incoming) {
            nextRows = upsert(nextRows, row)
        }
        return copy(
            rows = nextRows,
            watchCursor = batch.cursor,
            historyCursor = history,
            hasMoreHistory = hasMore,
            runtimeNotice = notice,
        )
    }

    /** Clears the view-local notice channel without touching the transcript. */
    public fun clearRuntimeNotice(): BotTranscriptState = copy(runtimeNotice = null)

    /** The rows `ui-state.md` §4.1 treats as the transcript. */
    public fun visibleRows(): List<BotRow> = BotUiStateDerivation.visibleRows(rows)

    private fun upsert(current: List<BotRow>, row: BotRow): List<BotRow> {
        if (row.body.type == BotRowBodyType.DELETED) {
            return current.filterNot { it.id == row.id }
        }
        val next = current.toMutableList()
        var index = next.indexOfFirst { it.id == row.id }
        if (index < 0 && row.body.cardType == BotWidgetCardType.PROGRESS &&
            row.body.cardKey != null
        ) {
            index = next.indexOfFirst {
                it.body.cardType == BotWidgetCardType.PROGRESS &&
                    it.body.cardKey == row.body.cardKey
            }
        }
        if (index < 0) {
            val eventIDs = row.provenance.eventIDs.toSet()
            index = next.indexOfFirst { stored ->
                stored.id.startsWith(LOCAL_PREFIX) &&
                    stored.provenance.eventIDs.any { it in eventIDs }
            }
        }
        if (index >= 0) {
            val stored = next[index]
            if (stored.id == row.id && stored.updatedSeq > row.updatedSeq) {
                return current
            }
            next[index] = row
        } else {
            next.add(row)
        }
        return next
    }

    public companion object {
        /** The only view-created row prefix. */
        public const val LOCAL_PREFIX: String = "local-"

        /** The reference view's `historyPageSize`. */
        public const val HISTORY_PAGE_SIZE: Int = 50
    }
}

/** True for a row the transcript never renders (`notice`), even when parseable. */
public fun BotRow.isTranscriptNotice(): Boolean = body.type == BotRowBodyType.NOTICE

/** True for the `local-<nonce>` optimistic rows the view created. */
public fun BotRow.isLocalRow(): Boolean = id.startsWith(BotTranscriptState.LOCAL_PREFIX)

/** The row kind values a text bubble may carry. */
public fun BotRow.isTextBubbleKind(): Boolean =
    kind == BotRowKind.MESSAGE || kind == BotRowKind.SEND_MESSAGE

/**
 * One older-history page before a row-id anchor (`BotUIHistoryPage`,
 * `ui-state.md` §1). Rows keep the projection's order.
 */
public data class BotUIHistoryPage(
    public val rows: List<BotRow>,
    public val nextCursor: String?,
    public val hasMore: Boolean,
)
