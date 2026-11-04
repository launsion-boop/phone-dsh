// The paging window of one device session's history.
// SPDX-License-Identifier: MIT
//
// `session/page` is a windowed read: it answers with the newest `maxMessages`
// records up to a cursor, and a `beforeSeq` cursor walks backwards through older
// ones. Two properties follow, and both are load-bearing for the page:
//
//  1. **Deduplication by `seq`.** Windows overlap at their edges (a new record
//     arrives between two reads), so records live in a map keyed by `seq` and the
//     projection always re-reads the ordered map, never the raw page arrays.
//  2. **Progress is asserted, not assumed.** A page whose oldest record is not
//     older than the current `beforeSeq` did not advance. Treating it as success
//     would loop forever on the same window, so it is reported as
//     [HistoryAdvance.STALLED] and paging stops with the reason on screen — the
//     same refusal the iOS model encodes as
//     `NativeDeviceSessionModelError.historyDidNotAdvance`.
//
// Nothing here touches a transport: this is the arithmetic of the window, so a
// JVM test drives it with plain values.
package com.phonedsh.domain.connector

/**
 * One `session/page` request.
 *
 * The three arguments are the ones the wire command names, spelled the same way,
 * because a second vocabulary in the host would have to be translated back at
 * every call site.
 *
 * @property throughSeq read up to and including this sequence number; `null` reads
 *   the newest window (the iOS caller passes `null` before it has a cursor).
 * @property beforeSeq read only records older than this one; `null` for the first
 *   (newest) window.
 * @property maxMessages the window size.
 */
data class DeviceHistoryRequest(
    val throughSeq: Long? = null,
    val beforeSeq: Long? = null,
    val maxMessages: Int = DEFAULT_PAGE_SIZE,
) {
    init {
        require(maxMessages > 0) { "maxMessages must be positive, was $maxMessages" }
    }

    companion object {
        /** The window the iOS session page asks for (`maxMessages: 60`). */
        const val DEFAULT_PAGE_SIZE: Int = 60
    }
}

/**
 * One `session/page` answer.
 *
 * @property records the window's records, in the device's own order.
 * @property hasMore whether older records exist beyond this window.
 */
data class DeviceHistoryPage(
    val records: List<DeviceTranscriptRecord>,
    val hasMore: Boolean,
)

/** What one paging step did to the window. */
enum class HistoryAdvance {
    /** The window grew (or was replaced) with older records. */
    ADVANCED,

    /** The answer carried no record older than the current cursor; paging stops. */
    STALLED,
}

/**
 * The paged history of one session: a `seq`-keyed window plus its two cursors.
 *
 * @property records every record read so far, keyed by `seq`.
 * @property beforeSeq the oldest record read so far; the next older read's cursor.
 * @property throughSeq the newest cursor the window was read through.
 * @property hasMore whether the device said older records exist.
 */
data class DeviceSessionHistory(
    val records: Map<Long, DeviceTranscriptRecord> = emptyMap(),
    val beforeSeq: Long? = null,
    val throughSeq: Long? = null,
    val hasMore: Boolean = false,
) {
    /** The window in consequence order; the projection's only input. */
    val ordered: List<DeviceTranscriptRecord>
        get() = records.keys.sorted().mapNotNull { records[it] }

    /**
     * Replaces the window with a first (newest) page.
     *
     * @param throughSeq the cursor the page was read through, kept for the next
     *   older read.
     */
    fun reset(page: DeviceHistoryPage, throughSeq: Long?): DeviceSessionHistory {
        val merged = LinkedHashMap<Long, DeviceTranscriptRecord>()
        page.records.forEach { merged[it.seq] = it }
        val oldest = merged.keys.minOrNull()
        return DeviceSessionHistory(
            records = merged,
            beforeSeq = oldest,
            throughSeq = throughSeq ?: merged.keys.maxOrNull(),
            hasMore = page.hasMore,
        )
    }

    /**
     * Adds one older page.
     *
     * @return the new window and what the step did. [HistoryAdvance.STALLED] leaves
     *   the window as it was and clears [hasMore], so the caller can stop offering
     *   the action and explain why.
     */
    fun applyEarlier(page: DeviceHistoryPage): Pair<DeviceSessionHistory, HistoryAdvance> {
        val next = page.records.minOfOrNull { it.seq }
        val cursor = beforeSeq
        if (next == null || cursor == null || next >= cursor) {
            return copy(hasMore = false) to HistoryAdvance.STALLED
        }
        val merged = LinkedHashMap(records)
        page.records.forEach { merged[it.seq] = it }
        return copy(
            records = merged,
            beforeSeq = next,
            hasMore = page.hasMore,
        ) to HistoryAdvance.ADVANCED
    }
}
