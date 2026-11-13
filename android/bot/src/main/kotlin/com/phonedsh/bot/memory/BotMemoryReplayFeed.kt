// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventErasureCommit
import com.phonedsh.bot.store.BotEventErasureTarget

/** The read side of the P25 durable log used by the memory replay feed. */
public interface BotMemoryEventSource {
    public fun headCommitSeq(): Long

    public fun events(after: Int, limit: Int): List<BotEvent>
}

/** The write + erasure side used by the SQL memory store. */
public interface BotMemoryEventLog : BotMemoryEventSource {
    public fun append(event: BotEvent): Long

    public fun appendBatch(events: List<BotEvent>): List<Long>

    public fun event(withId: String): BotEvent?

    /**
     * Runs [block] inside the P25 write transaction. Memory stores use this
     * around the replayed version check and the append, so two writers cannot
     * both commit the same document version.
     */
    public fun <T> writeTransaction(block: () -> T): T

    /** Appends inside an already open [writeTransaction]. */
    public fun appendWithinTransaction(event: BotEvent): Long

    public fun erasureTargets(commitSeqs: List<Int>): List<BotEventErasureTarget>

    public fun erasePayloads(
        commitSeqs: List<Int>,
        erasureEvent: BotEvent,
        atMs: Long,
    ): BotEventErasureCommit

    public fun secureEraseStorage()
}

/**
 * Adapter from the existing P25 [BotDomainStore] to the memory event seam. No
 * P25 SQL is duplicated here; the store remains the single event authority.
 */
public class BotDomainMemoryEventLog(
    private val store: BotDomainStore,
) : BotMemoryEventLog {
    override fun headCommitSeq(): Long = store.headCommitSeq()

    override fun events(after: Int, limit: Int): List<BotEvent> = store.events(after, limit)

    override fun append(event: BotEvent): Long = store.append(event)

    override fun appendBatch(events: List<BotEvent>): List<Long> = store.appendBatch(events)

    override fun event(withId: String): BotEvent? = store.event(withId)

    override fun <T> writeTransaction(block: () -> T): T =
        synchronized(store) { store.inTransaction(block) }

    override fun appendWithinTransaction(event: BotEvent): Long = synchronized(store) {
        com.phonedsh.bot.store.BotEventCodec.validate(
            event,
            com.phonedsh.bot.store.BotEventCodec.Mode.APPEND,
        )
        store.existingSequence(event.eventId)?.let { return@synchronized it }
        val sequence = store.headCommitSeqInternal() + 1
        store.insertEvent(event, sequence)
        sequence
    }

    override fun erasureTargets(commitSeqs: List<Int>): List<BotEventErasureTarget> =
        store.erasureTargets(commitSeqs)

    override fun erasePayloads(
        commitSeqs: List<Int>,
        erasureEvent: BotEvent,
        atMs: Long,
    ): BotEventErasureCommit = store.erasePayloads(commitSeqs, erasureEvent, atMS = atMs)

    override fun secureEraseStorage() = store.secureEraseStorage()
}

/**
 * Incremental, append-only view of memory events (`memory.written`,
 * `memory.forgotten`, `memory.document_written`, `memory.document_deleted` and
 * `erasure`). The first scan is a full replay; later calls read only the
 * newly committed delta. The cursor is owned here; each store keeps its own
 * index into the returned history.
 */
public class BotMemoryReplayFeed(
    public val pageSize: Int = 500,
) {
    private var cursor = 0L
    private val history = ArrayList<BotEvent>()
    private var hasScanned = false
    private var fullReplayCount = 0
    private var incrementalReplayCount = 0
    private var scannedEventCount = 0

    init {
        require(pageSize > 0) { "pageSize must be positive" }
    }

    @Synchronized
    public fun memoryEvents(fromIndex: Int, source: BotMemoryEventSource): List<BotEvent> {
        val head = source.headCommitSeq()
        if (!hasScanned) {
            hasScanned = true
            fullReplayCount += 1
        } else if (head > cursor) {
            incrementalReplayCount += 1
        }
        while (cursor < head) {
            val page = source.events(cursor.toInt(), pageSize)
            if (page.isEmpty()) break
            for (event in page) {
                val sequence = event.commitSeq
                    ?: throw BotMemoryStoreException(
                        "corrupted", "durable memory event has no commitSeq",
                    )
                cursor = sequence
                scannedEventCount += 1
                if (event.type in MEMORY_EVENT_TYPES) history += event
                if (cursor >= head) break
            }
            if (page.size < pageSize) break
        }
        if (fromIndex < 0 || fromIndex >= history.size) return emptyList()
        return ArrayList(history.subList(fromIndex, history.size))
    }

    @Synchronized
    public fun diagnostics(): FeedDiagnostics = FeedDiagnostics(
        fullReplayCount = fullReplayCount,
        incrementalReplayCount = incrementalReplayCount,
        scannedEventCount = scannedEventCount,
    )

    public data class FeedDiagnostics(
        public val fullReplayCount: Int,
        public val incrementalReplayCount: Int,
        public val scannedEventCount: Int,
    )

    public companion object {
        public val MEMORY_EVENT_TYPES: Set<String> = setOf(
            "memory.written", "memory.forgotten",
            "memory.document_written", "memory.document_deleted",
            "erasure",
        )
    }
}

/**
 * Process-wide feed registry keyed by durable log identity, so a process scans
 * the event log once and all memory stores attached to the same log consume
 * the same history. Entries are weak: a reopened log starts from commit 0.
 */
public object BotMemoryReplayFeedRegistry {
    private val entries = java.util.WeakHashMap<Any, BotMemoryReplayFeed>()

    @Synchronized
    public fun feedFor(source: Any, pageSize: Int = 500): BotMemoryReplayFeed =
        entries.getOrPut(source) { BotMemoryReplayFeed(pageSize) }
}
