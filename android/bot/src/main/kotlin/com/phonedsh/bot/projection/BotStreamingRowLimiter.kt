// SPDX-License-Identifier: MIT
package com.phonedsh.bot.projection

import com.phonedsh.bot.rows.BotRow

/**
 * The 10-updates-per-second streaming surface (`projection.md` §10).
 *
 * It is in-memory only and never durable; projected rows stay
 * `streaming == false`. Times are monotonic seconds.
 */
public class BotStreamingRowLimiter {
    private val visible = LinkedHashMap<String, BotRow>()
    private val pending = LinkedHashMap<String, BotRow>()
    private val pendingOrder = HashMap<String, Int>()
    private var insertionCounter = 0
    private val emissions = ArrayList<Double>()
    private var lastNow = 0.0

    /** Returns the emitted overlay, or null when the one-second window is full. */
    public fun submit(row: BotRow, now: Double): BotRow? {
        val clock = monotonic(now)
        prune(clock)
        val overlay = row.copy(streaming = true)
        if (!pending.containsKey(overlay.id)) {
            pendingOrder[overlay.id] = insertionCounter
            insertionCounter += 1
        }
        pending[overlay.id] = overlay
        if (emissions.size >= MAXIMUM_UPDATES_PER_SECOND) return null
        return emit(overlay.id, clock)
    }

    /** Emits pending rows oldest-first while the window has capacity. */
    public fun flush(now: Double): List<BotRow> {
        val clock = monotonic(now)
        prune(clock)
        val output = ArrayList<BotRow>()
        while (emissions.size < MAXIMUM_UPDATES_PER_SECOND) {
            val id = nextPendingId() ?: break
            emit(id, clock)?.let { output.add(it) }
        }
        return output
    }

    /** Visible rows sorted by `(seq, id)`. */
    public fun rows(): List<BotRow> = visible.values.sortedWith { lhs, rhs ->
        if (lhs.seq != rhs.seq) lhs.seq.compareTo(rhs.seq) else lhs.id.compareTo(rhs.id)
    }

    public fun pendingCount(): Int = pending.size

    /** Nil when nothing is pending, else the earliest retained emission + 1 s. */
    public fun nextFlushAt(): Double? {
        if (pending.isEmpty()) return null
        return emissions.minOrNull()?.plus(1.0)
    }

    public fun remove(id: String) {
        pending.remove(id)
        pendingOrder.remove(id)
        visible.remove(id)
    }

    public fun clear() {
        pending.clear()
        pendingOrder.clear()
        visible.clear()
        emissions.clear()
    }

    private fun monotonic(now: Double): Double {
        lastNow = maxOf(lastNow, now)
        return lastNow
    }

    private fun prune(now: Double) {
        emissions.removeAll { it <= now - 1.0 }
    }

    private fun nextPendingId(): String? {
        var best: String? = null
        var bestOrder = Int.MAX_VALUE
        for (id in pending.keys) {
            val order = pendingOrder[id] ?: Int.MAX_VALUE
            if (order < bestOrder) {
                best = id
                bestOrder = order
            }
        }
        return best
    }

    private fun emit(id: String, now: Double): BotRow? {
        val row = pending.remove(id) ?: return null
        pendingOrder.remove(id)
        visible[id] = row
        emissions.add(now)
        return row
    }

    public companion object {
        public const val MAXIMUM_UPDATES_PER_SECOND: Int = 10
    }
}
