// phone-dsh — :dsh / com.phonedsh.dsh.tools: the requestId idempotency ledger.
// SPDX-License-Identifier: MIT
//
// plan §13.7-J4: a tool call may be retried by the worker (reconnect, black-hole
// timeout, renderer death). The host must never run the same `requestId` twice —
// a double `write` or a double `exec` is a real side effect, not a duplicated log
// line. The ledger is the one gate in front of every tool, and the gate is
// deliberately above the tool: a tool that forgets to be idempotent is still
// called once.
//
// ---- P3 persistence contract (this is why the interface exists now) --------
// The in-memory implementation dies with the process, so a kill in the middle of
// a tool call loses the "was it started?" answer. P3 replaces it with a
// `Durability`-backed implementation that:
//   1. records `requestId -> tool` durably *before* the tool runs, so a restart
//      cannot re-run an unknown state;
//   2. records the outcome atomically (`:platform.Durability.atomicReplace`)
//      before the result is published to the worker;
//   3. keeps the same three methods, so [PhoneToolBridge] does not change.
// Until then, an in-flight entry is only protected within one process.

package com.phonedsh.dsh.tools

/**
 * The idempotency gate keyed by `requestId`.
 *
 * Implementations must be thread-safe: dispatch may arrive from a channel thread
 * while a UI-triggered call is in flight.
 */
interface RequestLedger {
    /**
     * Claims [requestId] for [tool].
     *
     * A new id is recorded as in-flight and answers [Admission.Proceed]; a
     * completed id answers [Admission.Replay]; an id whose first call has not
     * finished answers [Admission.InFlight] (it must not run).
     */
    fun admit(requestId: String, tool: String): Admission

    /** Stores [outcome] for [requestId]; the id answers [Admission.Replay] from now on. */
    fun complete(requestId: String, outcome: ToolOutcome)

    /** Forgets [requestId] so a later call may run again (used when the caller was cancelled). */
    fun abandon(requestId: String)

    /** What [admit] decided. */
    sealed interface Admission {
        /** New request: the caller owns it and must call [complete] or [abandon]. */
        data object Proceed : Admission

        /** Already completed for [tool]; [outcome] is the stored answer, not a re-run. */
        data class Replay(val tool: String, val outcome: ToolOutcome) : Admission

        /** Still running for another caller; the duplicate must not execute. */
        data object InFlight : Admission
    }
}

/**
 * The P3 placeholder: a bounded, in-memory ledger.
 *
 * [maxEntries] bounds memory for a long-lived process; when it is exceeded the
 * oldest *completed* entries are evicted and in-flight entries are never evicted
 * (forgetting an in-flight call would allow a double execution). Eviction can
 * therefore only shrink the idempotency window, never the correctness of a
 * currently running call.
 */
class InMemoryRequestLedger(private val maxEntries: Int = DEFAULT_MAX_ENTRIES) : RequestLedger {
    init {
        require(maxEntries > 0) { "maxEntries must be positive, was $maxEntries" }
    }

    private class Entry(val tool: String, var outcome: ToolOutcome? = null)

    private val entries = LinkedHashMap<String, Entry>()

    override fun admit(requestId: String, tool: String): RequestLedger.Admission =
        synchronized(this) {
            val existing = entries[requestId]
            when {
                existing == null -> {
                    entries[requestId] = Entry(tool)
                    RequestLedger.Admission.Proceed
                }

                existing.outcome == null -> RequestLedger.Admission.InFlight
                else -> RequestLedger.Admission.Replay(existing.tool, existing.outcome!!)
            }
        }

    override fun complete(requestId: String, outcome: ToolOutcome) {
        synchronized(this) {
            entries[requestId]?.outcome = outcome
            trim()
        }
    }

    override fun abandon(requestId: String) {
        synchronized(this) { entries.remove(requestId) }
    }

    /** Entries currently tracked, in admission order (tests and diagnostics). */
    fun tracked(): List<String> = synchronized(this) { entries.keys.toList() }

    private fun trim() {
        if (entries.size <= maxEntries) return
        val iterator = entries.entries.iterator()
        while (entries.size > maxEntries && iterator.hasNext()) {
            if (iterator.next().value.outcome != null) iterator.remove()
        }
    }

    companion object {
        /** Enough for a turn's tool calls without unbounded growth. */
        const val DEFAULT_MAX_ENTRIES: Int = 1024
    }
}
