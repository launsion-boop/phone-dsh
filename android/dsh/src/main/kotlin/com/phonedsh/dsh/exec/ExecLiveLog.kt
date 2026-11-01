// phone-dsh — :dsh / com.phonedsh.dsh.exec: the live exec event log (D10 join).
// SPDX-License-Identifier: MIT
//
// exec.md §2: "If the recorded stream is still live, the host replays the
// recorded prefix and continues from the provider; a second process is never
// started." The in-memory `RequestLedger` can only answer "in flight"; it cannot
// hand the duplicate the running execution. This file is that hand-off:
//
//   * one [LiveExecution] per `idem_key` while it runs (and while its result is
//     still in the process), holding the ordered [ExecEvent] list and a
//     `terminal` bit;
//   * [LiveExecution.stream] emits the recorded prefix from `seq = 0` and then
//     follows new appends until the terminal event, so a duplicate request
//     replays exactly what the Worker has already missed and then joins;
//   * [LiveExecutions] decides Start / Join / Conflict atomically, so two
//     requests with one `idem_key` can never both start an execution.
//
// The log is deliberately memory-only: exec.md §2's durable replay answers are
// the persisted dedup table (`RequestLedger`), and a process death turns a live
// entry into the terminal `interrupted` error. The live log is the *same*
// execution, not a second process; the event list is bounded by the tool result
// budget of ExecToolResult, so it is not a growing journal.
//
// A duplicate request that arrives after the execution ended replays from this
// log too (it is the exact record the ledger stored); after eviction the ledger
// answers instead. Neither path executes the tool again.

package com.phonedsh.dsh.exec

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow

/**
 * One execution that this process knows about, live or finished.
 *
 * Thread-safe: appends happen on the execution's driver coroutine while cancel
 * arrives from the channel thread, and any number of collectors replay/follow.
 *
 * @param idemKey the D10 key this execution is keyed by
 * @param execId the recorded D6 id; replayed events keep it even when the
 *   re-issued request carries another id (exec.md §2)
 * @param argv the recorded identity, the only conflict field besides [cwd]
 * @param cwd the recorded working directory
 * @param createdAtMs the ledger intent timestamp, reused by the record
 */
internal class LiveExecution(
    val idemKey: String,
    val execId: String,
    val argv: List<String>,
    val cwd: String,
    val createdAtMs: Long,
) {
    private data class Progress(val events: List<ExecEvent>, val terminal: Boolean)

    private val lock = Any()
    private val progress = MutableStateFlow(Progress(emptyList(), false))
    private var stdoutBytes = 0L
    private var stderrBytes = 0L
    private var settled = false

    /** Whether the terminal event has been published; no later event is emitted. */
    val isTerminal: Boolean get() = progress.value.terminal

    /** Whether the driver coroutine has finished; only settled entries are evictable. */
    val isSettled: Boolean get() = synchronized(lock) { settled }

    /** The event list as recorded so far, in seq order. */
    fun snapshot(): List<ExecEvent> = progress.value.events

    /**
     * Publishes the `start` event exactly once.
     *
     * Called before the tool body runs, so a duplicate that joins later replays
     * at least a well-formed prefix instead of a stream that begins mid-way.
     */
    fun begin(): Boolean = append(ExecEvent.Start(execId = execId, seq = ExecEvent.SEQUENCE_START))

    /**
     * Appends one event unless the stream is terminal or the event is a
     * duplicate `start`; `seq` is assigned by this log, never by the caller.
     *
     * @return false when the event was dropped because the execution already
     *   ended (the cancellation rule: no event may follow the terminal one)
     */
    fun append(event: ExecEvent): Boolean = synchronized(lock) {
        val current = progress.value
        if (current.terminal) return false
        if (event is ExecEvent.Start && current.events.isNotEmpty()) return true
        val recorded = event.withSeq(current.events.size.toLong())
        when (recorded) {
            is ExecEvent.Output -> when (recorded.stream) {
                ExecEvent.Stream.STDOUT -> stdoutBytes += recorded.decodedSize()
                ExecEvent.Stream.STDERR -> stderrBytes += recorded.decodedSize()
            }

            else -> Unit
        }
        progress.value = Progress(
            events = current.events + recorded,
            terminal = recorded.isTerminal(),
        )
        true
    }

    /** Publishes a completed tool result; a leading `start` is not duplicated. */
    fun publish(events: List<ExecEvent>): Boolean {
        for (event in events) {
            if (event is ExecEvent.Start) {
                begin()
                continue
            }
            if (!append(event)) return false
        }
        return true
    }

    /**
     * Publishes a recorded stream verbatim (the ledger replay). It keeps the
     * recorded `exec_id` and `seq` values, marks the `start` event as a replay
     * (exec.md §2) and ends at the recorded terminal event.
     */
    fun publishRecord(record: ExecRecord): Boolean = synchronized(lock) {
        if (progress.value.terminal) return false
        progress.value = Progress(
            events = record.events.map { event ->
                if (event is ExecEvent.Start) event.copy(replayed = true) else event
            },
            terminal = true,
        )
        true
    }

    /**
     * Publishes one terminal error with no `start` (a refused replay, for
     * example the recovered `interrupted` entry). seq = 0, exactly like the
     * preflight refusals of the bridge.
     */
    fun publishStandaloneError(code: String, message: String): Boolean = synchronized(lock) {
        if (progress.value.terminal) return false
        progress.value = Progress(
            events = listOf(
                ExecEvent.Error(
                    execId = execId,
                    seq = ExecEvent.SEQUENCE_START,
                    code = code,
                    message = message,
                ),
            ),
            terminal = true,
        )
        true
    }

    /**
     * Ends a live execution with the exec-bridge `cancelled` exit.
     *
     * An in-process accelerator has no process to signal, so the honest act is
     * to close the observed execution: the terminal `exit` is recorded, every
     * later event is dropped by [append], and the eventual tool result is
     * discarded. `stdout_bytes`/`stderr_bytes` count the output that was
     * already published, so the exit stays consistent with the prefix.
     *
     * @return false when the execution had already ended
     */
    fun cancel(): Boolean = synchronized(lock) {
        val current = progress.value
        if (current.terminal) return false
        val events = if (current.events.isEmpty()) {
            listOf(ExecEvent.Start(execId = execId, seq = ExecEvent.SEQUENCE_START))
        } else {
            current.events
        }
        progress.value = Progress(
            events = events + ExecEvent.Exit(
                execId = execId,
                seq = events.size.toLong(),
                code = null,
                signal = null,
                status = ExecEvent.ExitStatus.CANCELLED,
                quiescent = true,
                stdoutBytes = stdoutBytes,
                stderrBytes = stderrBytes,
            ),
            terminal = true,
        )
        true
    }

    /** Ends the execution with a terminal `error`; a `start` is added if absent. */
    fun failTerminal(code: String, message: String): Boolean = synchronized(lock) {
        val current = progress.value
        if (current.terminal) return false
        var events = current.events
        if (events.isEmpty()) {
            events = listOf(ExecEvent.Start(execId = execId, seq = ExecEvent.SEQUENCE_START))
        }
        progress.value = Progress(
            events = events + ExecEvent.Error(
                execId = execId,
                seq = events.size.toLong(),
                code = code,
                message = message,
            ),
            terminal = true,
        )
        true
    }

    /** Marks the driver finished; the store may now evict this entry. */
    fun markSettled() {
        synchronized(lock) { settled = true }
    }

    /**
     * The completed record for the durable ledger.
     *
     * @throws IllegalStateException the execution has not reached its terminal event
     */
    fun toRecord(): ExecRecord {
        val current = progress.value
        check(current.terminal) { "an unfinished execution has no record" }
        return ExecRecord(
            idemKey = idemKey,
            execId = execId,
            argv = argv,
            cwd = cwd,
            createdAtMs = createdAtMs,
            events = current.events,
        )
    }

    /**
     * The ordered event stream: the recorded prefix from seq 0, then every
     * later append, ending at the terminal event.
     *
     * [replayed] marks the `start` event of a joiner (`exec.md §2`); the
     * execution's own first subscriber passes false. Events are read from the
     * log's current state, so a subscriber never misses an event because a
     * StateFlow update was conflated.
     */
    fun stream(replayed: Boolean): Flow<ExecEvent> = flow {
        var index = 0
        while (true) {
            val current = progress.value
            while (index < current.events.size) {
                val event = current.events[index]
                index += 1
                emit(
                    if (replayed && event is ExecEvent.Start) {
                        event.copy(replayed = true)
                    } else {
                        event
                    },
                )
            }
            if (current.terminal) return@flow
            progress.first { state -> state.terminal || state.events.size > index }
        }
    }

    private fun ExecEvent.Output.decodedSize(): Long =
        java.util.Base64.getDecoder().decode(data).size.toLong()

    private fun ExecEvent.isTerminal(): Boolean = this is ExecEvent.Exit || this is ExecEvent.Error
}

/**
 * The live execution table, keyed by `idem_key`.
 *
 * [claim] is the single concurrency gate: the first request puts an entry in and
 * becomes the owner, and every later request gets the same [LiveExecution] back.
 * A different `argv` or `cwd` for one key is a conflict (exec.md §2 compares
 * exactly those two fields), never a second execution.
 *
 * Completed entries are evicted oldest-first once the table exceeds
 * [maxEntries]; an entry whose driver has not settled is never evicted, because
 * forgetting it would let a duplicate start a second execution.
 */
internal class LiveExecutions(private val maxEntries: Int = DEFAULT_MAX_ENTRIES) {
    init {
        require(maxEntries > 0) { "maxEntries must be positive, was $maxEntries" }
    }

    /** What [claim] decided. */
    sealed interface Claim {
        /** The key is new: this caller owns the execution and must drive it. */
        data class Start(val execution: LiveExecution) : Claim

        /** The key is already live (or still retained): replay its prefix and follow. */
        data class Join(val execution: LiveExecution) : Claim

        /** The key exists with another identity; nothing executes. */
        data class Conflict(val execution: LiveExecution) : Claim
    }

    private val lock = Any()
    private val byKey = LinkedHashMap<String, LiveExecution>()
    private val byExecId = HashMap<String, LiveExecution>()

    /**
     * Claims [request]'s `idem_key`.
     *
     * @param createdAtMs the ledger intent timestamp for a new execution
     */
    fun claim(request: ExecRequest, createdAtMs: Long): Claim = synchronized(lock) {
        val existing = byKey[request.idemKey]
        if (existing != null) {
            return if (existing.argv == request.argv && existing.cwd == request.cwd) {
                Claim.Join(existing)
            } else {
                Claim.Conflict(existing)
            }
        }
        val created = LiveExecution(
            idemKey = request.idemKey,
            execId = request.execId,
            argv = request.argv,
            cwd = request.cwd,
            createdAtMs = createdAtMs,
        )
        byKey[request.idemKey] = created
        byExecId[created.execId] = created
        trim()
        Claim.Start(created)
    }

    /** The retained execution for [idemKey], or null when it was evicted. */
    fun find(idemKey: String): LiveExecution? = synchronized(lock) { byKey[idemKey] }

    /** The execution whose recorded `exec_id` is [execId]; the EXEC_CTL target. */
    fun findByExecId(execId: String): LiveExecution? = synchronized(lock) { byExecId[execId] }

    /** Marks [execution] finished and trims the table. */
    fun settled(execution: LiveExecution) {
        execution.markSettled()
        synchronized(lock) { trim() }
    }

    /** Entries currently retained, in claim order (tests and diagnostics). */
    fun tracked(): List<String> = synchronized(lock) { byKey.keys.toList() }

    private fun trim() {
        if (byKey.size <= maxEntries) return
        val iterator = byKey.entries.iterator()
        while (byKey.size > maxEntries && iterator.hasNext()) {
            val entry = iterator.next()
            if (!entry.value.isSettled) continue
            iterator.remove()
            byExecId.remove(entry.value.execId)
        }
    }

    companion object {
        /** Same bound as the in-memory ledger; live executions are short-lived. */
        const val DEFAULT_MAX_ENTRIES: Int = 1024
    }
}

/** Copies an event with the sequence the log assigned. */
private fun ExecEvent.withSeq(seq: Long): ExecEvent = when (this) {
    is ExecEvent.Start -> copy(seq = seq)
    is ExecEvent.Output -> copy(seq = seq)
    is ExecEvent.Exit -> copy(seq = seq)
    is ExecEvent.Quiescent -> copy(seq = seq)
    is ExecEvent.Error -> copy(seq = seq)
}
