// SPDX-License-Identifier: MIT
package com.phonedsh.bot.projection

import com.phonedsh.bot.rows.BotRow
import com.phonedsh.bot.rows.BotRowBatch

/**
 * The one-snapshot row history (`projection.md` §9).
 *
 * `rebuild` projects the inputs, reconciles them with the current snapshot and
 * returns a reset batch; `watch(after)` returns the delta after a cursor. The
 * snapshot is in memory only.
 */
public class BotRowHistory(
    snapshot: BotRowProjectionSnapshot = BotRowProjectionSnapshot.EMPTY,
    private val projector: BotSessionLogProjector = BotSessionLogProjector(),
) {
    private var snapshot: BotRowProjectionSnapshot = snapshot

    public fun history(): List<BotRow> = snapshot.rows

    public fun tombstones(): List<BotRow> = snapshot.tombstones

    public fun cursor(): Long = snapshot.cursor

    public fun rebuild(
        botID: String,
        sessionID: String,
        sessionEvents: List<BotSessionLogRecord>,
        uiEvents: List<BotProjectionEvent> = emptyList(),
        heldRequestNonces: Map<String, String> = emptyMap(),
    ): BotRowBatch = rebuild(
        botID = botID,
        epochs = listOf(BotSessionEpochProjection(sessionID, sessionEvents)),
        uiEvents = uiEvents,
        heldRequestNonces = heldRequestNonces,
    )

    public fun rebuild(
        botID: String,
        epochs: List<BotSessionEpochProjection>,
        uiEvents: List<BotProjectionEvent> = emptyList(),
        heldRequestNonces: Map<String, String> = emptyMap(),
    ): BotRowBatch {
        val projected = projector.project(botID, epochs, uiEvents, heldRequestNonces)
        snapshot = reconciled(projected)
        return resetBatch()
    }

    public fun replaceWithRebuiltCache(rebuilt: BotRowProjectionSnapshot) {
        snapshot = reconciled(rebuilt)
    }

    public fun watch(after: Long): BotRowBatch {
        if (after <= 0 || after > snapshot.cursor) return resetBatch()
        val selected = snapshot.changes.filter { it.updatedSeq > after }
        val latest = LinkedHashMap<String, BotRowChange>()
        for (change in selected) latest[change.id] = change
        val ordered = latest.values.sortedBy { it.updatedSeq }
        return BotRowBatch(
            rows = ordered.mapNotNull { (it as? BotRowChange.Upsert)?.row },
            deletes = ordered.filter { it.isDelete }.map { it.id },
            cursor = snapshot.cursor,
            reset = false,
        )
    }

    private fun reconciled(projected: BotRowProjectionSnapshot): BotRowProjectionSnapshot {
        if (snapshot.cursor == 0L && snapshot.rows.isEmpty() &&
            snapshot.tombstones.isEmpty() && snapshot.changes.isEmpty()
        ) {
            return projected
        }
        val rows = LinkedHashMap<String, BotRow>()
        for (row in snapshot.rows) rows[row.id] = row
        val tombstones = LinkedHashMap<String, BotRow>()
        for (row in snapshot.tombstones) tombstones[row.id] = row
        val changes = ArrayList(snapshot.changes)
        var cursor = snapshot.cursor
        val projectedRowIDs = projected.rows.map { it.id }.toHashSet()
        val projectedTombstoneIDs = projected.tombstones.map { it.id }.toHashSet()

        for (candidate in projected.rows) {
            if (tombstones.containsKey(candidate.id)) continue
            val old = rows[candidate.id]
            if (old != null && BotSessionLogProjector.sameContent(old, candidate)) {
                rows[candidate.id] = old
                continue
            }
            cursor += 1
            val inserted = candidate.copy(updatedSeq = cursor)
            rows[candidate.id] = inserted
            changes.add(BotRowChange.Upsert(inserted))
        }

        for (candidate in projected.tombstones) {
            if (tombstones.containsKey(candidate.id)) continue
            cursor += 1
            val deleted = candidate.copy(updatedSeq = cursor)
            rows.remove(candidate.id)
            tombstones[candidate.id] = deleted
            changes.add(BotRowChange.Delete(candidate.id, cursor))
        }

        for (previous in snapshot.rows) {
            if (projectedRowIDs.contains(previous.id)) continue
            if (projectedTombstoneIDs.contains(previous.id)) continue
            if (tombstones.containsKey(previous.id)) continue
            if (rows.remove(previous.id) == null) continue
            cursor += 1
            changes.add(BotRowChange.Delete(previous.id, cursor))
        }
        return BotRowProjectionSnapshot(
            rows = rows.values.sortedWith { lhs, rhs ->
                BotSessionLogProjector.rowComparator(lhs, rhs)
            },
            tombstones = tombstones.values.sortedWith { lhs, rhs ->
                BotSessionLogProjector.rowComparator(lhs, rhs)
            },
            cursor = cursor,
            changes = changes,
        )
    }

    private fun resetBatch(): BotRowBatch = BotRowBatch(
        rows = snapshot.rows,
        deletes = snapshot.tombstones.sortedBy { it.updatedSeq }.map { it.id },
        cursor = snapshot.cursor,
        reset = true,
    )
}
