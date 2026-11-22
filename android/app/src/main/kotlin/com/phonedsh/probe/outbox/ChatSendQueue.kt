// SPDX-License-Identifier: MIT
// The Android composer's delivery of the durable send outbox
// (spec/host/v1/README.md sections 10 and 10.1;
// docs/protocol-changes/PC-20261114-ios-queued-engine-readiness.md).
//
// Kotlin end of `enqueueSend` / `drainSendOutbox` / `scheduleRecoveryQueueFlush`
// / `reconcileOutboxEntry` in `examples/probe-app/PhoneDSHProbe/ChatModel.swift`.
//
// One rule orders everything here: the entry is on disk before any transport is
// touched, and its `rpcId` is the request id of every attempt. This class
// decides *when* to deliver; the host seam owns the engine and the turn, and
// the outbox owns the states.
//
//   * enqueue never refuses for a stopped or starting engine or a running turn;
//   * one coalesced preparation job joins every request (no second timer or
//     lifecycle state machine): it asks [ChatDeliveryPreparation] and uses the
//     host's existing start transition;
//   * without execution eligibility nothing boots the engine; a foreground
//     return asks again; an explicit stop pauses queued preparation;
//   * an unknown outcome is settled only by the authoritative read-back, never
//     by a user retry, and is resent only after proof of absence, with the same
//     `rpcId`, once the settle delay has passed.
//
// The external admission journal is dispatched on the same triggers and its
// `linked` records are settled from the turn's own terminal event.
package com.phonedsh.probe.outbox

import com.phonedsh.probe.admission.AdmissionStage
import com.phonedsh.probe.admission.ExternalAdmissionJournal
import com.phonedsh.probe.admission.OutboxAdmissionDispatcher
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** What the queue needs from the host. Every method is the host's existing behaviour, not a new one. */
internal interface ChatSendHost {
    fun deliveryFacts(): ChatDeliveryFacts

    /** The existing start transition, awaited until the engine is ready or the bounded wait fails. */
    suspend fun startEngine()

    /** The existing transition that brings a parked engine back. */
    suspend fun resumeEngine()

    /** The Worker session the composer can deliver into now (the conversation on screen), or null. */
    fun activeSessionId(): String?

    /** A turn is running in [activeSessionId]. */
    fun turnRunning(): Boolean

    /**
     * Starts the turn that carries [entry]. The host reports the transport steps
     * through [ChatSendQueue.transportStarting], [ChatSendQueue.transportAccepted]
     * and [ChatSendQueue.deliveryEnded]. False when no turn can start now.
     */
    fun startTurn(entry: SendOutboxEntry): Boolean

    /** `session/prompt` into the running turn of [entry]'s session; throws when it did not return success. */
    suspend fun promptRunningTurn(entry: SendOutboxEntry, mode: String)

    /** The authoritative read-back of one entry. */
    suspend fun readBack(entry: SendOutboxEntry): SendOutboxReadBack

    fun sessionExists(sessionId: String): Boolean

    /** The id after `account:` of the signed-in account, or null. */
    fun signedInAccountId(): String?

    /** The entries changed; the host re-derives its 排队中 projection from them. */
    fun queueChanged(entries: List<SendOutboxEntry>)

    fun log(line: String)
}

/** How a mid-turn submission may proceed. */
internal enum class ChatPromptAdmission {
    /** The entry is durable and marked submitting: call the transport now with its `rpcId`. */
    SEND,

    /** The entry already exists with an unsettled outcome: do not call the transport; the read-back decides. */
    HELD,

    /** The entry could not be written or does not match: there is no acceptance. */
    REFUSED,
}

internal class ChatSendQueue(
    private val outbox: SendOutbox,
    /** Opened on first use, off the caller's thread: opening sweeps the directory. */
    private val journal: Lazy<ExternalAdmissionJournal?>,
    private val host: ChatSendHost,
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val nowMs: () -> Long = System::currentTimeMillis,
    private val waitPollMillis: Long = 100L,
    private val maxWaitPolls: Int = 300,
    private val onSettleDue: ((Long) -> Unit)? = null,
) {
    private val gate = Mutex()
    private val deliveryPass = Mutex()

    /** Entries a live sender of this process is delivering right now. Not persisted: a restart has no such proof. */
    private val inFlight = HashSet<String>()

    /** `steer` submissions of this process; the stored entry has no mode and a redelivery is a plain queue prompt. */
    private val modes = HashMap<String, String>()

    /** User messages seen since the last turn start, for attributing the turn's terminal event. */
    private val openTurnRpcIds = LinkedHashSet<String>()

    @Volatile private var paused = false
    @Volatile private var flushRequested = false
    private var flushJob: Job? = null
    private var settleJob: Job? = null
    private var settleDeadlineMs = 0L

    val isPaused: Boolean get() = paused

    // ------------------------------------------------------------------ startup

    /**
     * The startup scan: collect orphan attachment directories, then resume what
     * an earlier process left. It never invents an `rpcId`; a `submitting` entry
     * found here was not sent by this process and is settled by the read-back.
     */
    fun startup() {
        scope.launch {
            withContext(io) { outbox.collectOrphanAttachments() }
            publish()
            requestDelivery()
        }
    }

    // ------------------------------------------------------------------ enqueue

    /**
     * Durably enqueues one prompt for [sessionId] and returns its entry; delivery
     * is a separate step. With [rpcId] of an existing entry (a retry of the same
     * row) nothing new is written and nothing is made retryable: the same entry
     * is returned when its session and text match, else null. Null also means
     * the write failed: there is no acceptance.
     */
    suspend fun enqueue(sessionId: String, text: String, rpcId: String? = null): SendOutboxEntry? {
        val entry = gate.withLock {
            withContext(io) {
                val existing = rpcId?.let(outbox::entry)
                if (existing != null) {
                    existing.takeIf { it.sessionId == sessionId && it.text == text }
                } else {
                    try {
                        outbox.enqueue(sessionId = sessionId, text = text, rpcId = rpcId)
                    } catch (failure: SendOutboxException) {
                        host.log("send outbox: enqueue refused (${failure.javaClass.simpleName})")
                        null
                    }
                }
            }
        } ?: return null
        // A new send is the person asking for delivery again after a stop.
        paused = false
        publish()
        requestDelivery()
        return entry
    }

    /**
     * A submission into a running turn: enqueue (or find) the entry and mark it
     * submitting in one step, so the caller may touch the transport next.
     */
    suspend fun admitRunningPrompt(sessionId: String, text: String, rpcId: String, mode: String): ChatPromptAdmission {
        val admission = gate.withLock {
            withContext(io) {
                val existing = outbox.entry(rpcId)
                try {
                    val entry = existing ?: outbox.enqueue(sessionId = sessionId, text = text, rpcId = rpcId)
                    when {
                        entry.sessionId != sessionId || entry.text != text -> ChatPromptAdmission.REFUSED
                        entry.state != SendOutboxState.QUEUED -> ChatPromptAdmission.HELD
                        else -> {
                            outbox.markSubmitting(rpcId)
                            synchronized(inFlight) {
                                inFlight.add(rpcId)
                                modes[rpcId] = mode
                            }
                            ChatPromptAdmission.SEND
                        }
                    }
                } catch (failure: SendOutboxException) {
                    host.log("send outbox: busy prompt refused (${failure.javaClass.simpleName})")
                    ChatPromptAdmission.REFUSED
                }
            }
        }
        publish()
        if (admission == ChatPromptAdmission.HELD) requestDelivery()
        return admission
    }

    // ---------------------------------------------------------- transport steps

    /**
     * Immediately before the transport call of a turn started by [ChatSendHost.startTurn].
     * Durable before the call returns. A second call for the same live delivery
     * means the first attempt was definitely refused before anything was written
     * (the session was not found): the entry goes back through the two existing
     * edges and is submitted again with the same `rpcId`.
     */
    suspend fun transportStarting(rpcId: String) {
        gate.withLock {
            withContext(io) {
                val entry = outbox.entry(rpcId) ?: return@withContext
                if (entry.state == SendOutboxState.SUBMITTING && isInFlight(rpcId)) {
                    outbox.markOutcomeUnknown(rpcId, "refused before submission")
                    outbox.requeue(rpcId)
                }
                outbox.markSubmitting(rpcId)
            }
        }
        publish()
    }

    /** The transport call returned success. A local acknowledgement: it deletes nothing. */
    suspend fun transportAccepted(rpcId: String) {
        gate.withLock { withContext(io) { runCatching { outbox.markAccepted(rpcId) } } }
        publish()
    }

    /** The busy prompt of [admitRunningPrompt] did not return success: the outcome is unknown. */
    suspend fun transportUnknown(rpcId: String, error: String) {
        gate.withLock {
            synchronized(inFlight) { inFlight.remove(rpcId) }
            withContext(io) { runCatching { outbox.markOutcomeUnknown(rpcId, error) } }
        }
        publish()
        requestDelivery()
    }

    /** The busy prompt of [admitRunningPrompt] returned success. */
    suspend fun runningPromptAccepted(rpcId: String) {
        gate.withLock {
            synchronized(inFlight) { inFlight.remove(rpcId) }
            withContext(io) { runCatching { outbox.markAccepted(rpcId) } }
        }
        publish()
    }

    /**
     * The live delivery started by [ChatSendHost.startTurn] is over. [failure] is
     * null when the turn ran to its end. An entry that never reached the
     * transport stays `queued`; one that was being submitted becomes
     * `outcomeUnknown`; both keep their `rpcId`, and nothing is resent here.
     */
    suspend fun deliveryEnded(rpcId: String, failure: String?) {
        gate.withLock {
            synchronized(inFlight) {
                inFlight.remove(rpcId)
                modes.remove(rpcId)
            }
            withContext(io) {
                val entry = outbox.entry(rpcId) ?: return@withContext
                if (entry.state == SendOutboxState.SUBMITTING) {
                    runCatching { outbox.markOutcomeUnknown(rpcId, failure ?: "the turn ended during submission") }
                }
            }
        }
        publish()
        // An entry that never reached the transport waits for the next trigger
        // (a foreground return, a new send or a retry): retrying it here would
        // spin against an engine that just failed.
        val state = withContext(io) { outbox.entry(rpcId)?.state }
        if (failure == null || (state != null && state != SendOutboxState.QUEUED)) requestDelivery()
    }

    // ------------------------------------------------------- authoritative events

    /** A turn started in the followed session. */
    fun onTurnStarted() {
        synchronized(openTurnRpcIds) { openTurnRpcIds.clear() }
    }

    /** The authoritative `user_message` with this `source.rpcId` was read from the engine. */
    fun onAuthoritativeUserMessage(rpcId: String) {
        synchronized(openTurnRpcIds) { openTurnRpcIds.add(rpcId) }
        scope.launch {
            gate.withLock { withContext(io) { runCatching { outbox.observeAuthoritativeUserMessage(rpcId) } } }
            publish()
        }
    }

    /**
     * The turn's terminal event. Every admission whose message opened or joined
     * this turn is settled from it: `completed` only for a normal end, `failed`
     * for a failed or cancelled turn. A `linked` record with no such evidence is
     * left alone.
     */
    fun onTurnEnded(reasonKind: String?) {
        val ids = synchronized(openTurnRpcIds) { openTurnRpcIds.toList().also { openTurnRpcIds.clear() } }
        if (ids.isEmpty()) return
        scope.launch {
            withContext(io) {
                val journal = journal.value ?: return@withContext
                for (rpcId in ids) {
                    val record = journal.recordForDownstreamId(rpcId) ?: continue
                    if (record.stage != AdmissionStage.LINKED) continue
                    runCatching {
                        if (reasonKind == "completed") journal.complete(record.admissionId)
                        else journal.fail(record.admissionId, if (reasonKind == null) REASON_TURN_FAILED else REASON_TURN_ENDED)
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- lifecycle

    /** The App returned to the foreground: retained queued work is prepared again. */
    fun onForeground() = requestDelivery()

    /** The person stopped the engine: queued preparation pauses and a boot it started never drains. */
    fun pause() {
        paused = true
        flushJob?.cancel()
    }

    /** The person started the engine again. */
    fun unpause() {
        paused = false
        requestDelivery()
    }

    /** An admission was written: dispatch on the same trigger as everything else. */
    fun onAdmission() = requestDelivery()

    // ------------------------------------------------------------- preparation

    /**
     * Asks for one delivery pass. Requests made while the job runs are joined:
     * the job runs once more when it ends.
     */
    fun requestDelivery() {
        synchronized(this) {
            if (flushJob?.isActive == true) {
                flushRequested = true
                return
            }
            flushRequested = false
            flushJob = scope.launch {
                try {
                    deliveryPass.withLock { prepareAndDrain() }
                } finally {
                    val again = synchronized(this@ChatSendQueue) {
                        flushJob = null
                        flushRequested.also { flushRequested = false }
                    }
                    if (again && !paused && host.deliveryFacts().executionEligible) requestDelivery()
                }
            }
        }
    }

    suspend fun drainForWake() = deliveryPass.withLock {
        if (host.deliveryFacts().decide(paused) == ChatDeliveryPreparation.READY) drain()
    }

    suspend fun dispatchForWake() = deliveryPass.withLock { dispatchAdmissions() }

    private suspend fun prepareAndDrain() {
        dispatchAdmissions()
        // One preparation per job: after a start the loop waits for readiness
        // instead of booting twice.
        var prepared = false
        repeat(maxWaitPolls) {
            // A lost entry waits for the person, not the engine: it never boots one.
            if (withContext(io) { outbox.entries() }.none { it.state != SendOutboxState.TARGET_LOST }) return
            when (host.deliveryFacts().decide(paused)) {
                ChatDeliveryPreparation.READY -> {
                    drain()
                    return
                }
                ChatDeliveryPreparation.START, ChatDeliveryPreparation.RESUME -> {
                    if (prepared) return
                    prepared = true
                    val resume = host.deliveryFacts().parked
                    host.log("send outbox: preparing the engine for queued delivery")
                    try {
                        if (resume) host.resumeEngine() else host.startEngine()
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (failure: Exception) {
                        host.log("send outbox: engine preparation failed; queued entries are kept")
                        return
                    }
                    if (paused) return
                }
                ChatDeliveryPreparation.DEFERRED -> {
                    host.log("send outbox: saved; waiting for the foreground or a held turn window")
                    return
                }
                ChatDeliveryPreparation.NEEDS_ATTENTION -> {
                    host.log("send outbox: saved; the engine needs the person's attention")
                    return
                }
                ChatDeliveryPreparation.WAIT -> delay(waitPollMillis)
            }
        }
        host.log("send outbox: saved; engine preparation is still waiting on lifecycle readiness")
    }

    /** Hands `dsh-session` admissions to the outbox. Needs no engine: it only writes files. */
    private suspend fun dispatchAdmissions(): Boolean {
        val linked = withContext(io) {
            val journal = journal.value ?: return@withContext false
            runCatching {
                journal.runDispatchPass(OutboxAdmissionDispatcher(outbox, host::sessionExists, host::signedInAccountId))
            }.onFailure { host.log("admission journal: dispatch pass stopped (${it.javaClass.simpleName})") }
                .getOrNull()?.linked?.isNotEmpty() == true
        }
        publish()
        return linked
    }

    /**
     * Delivers in per-session FIFO order. Only the session the composer can
     * deliver into is sent to; an entry of another session keeps its place and
     * waits, and never blocks a different session.
     */
    private suspend fun drain() {
        val entries = withContext(io) { outbox.entries() }
        val blocked = HashSet<String>()
        for (stale in entries) {
            val entry = withContext(io) { outbox.entry(stale.rpcId) } ?: continue
            if (entry.sessionId in blocked) continue
            when (entry.state) {
                SendOutboxState.DURABLE -> gate.withLock { withContext(io) { runCatching { outbox.deleteIfDurable(entry.rpcId) } } }
                SendOutboxState.SUBMITTING -> {
                    if (isInFlight(entry.rpcId)) {
                        // This process is submitting it right now; later entries wait their turn.
                        blocked.add(entry.sessionId)
                    } else {
                        // Left by a process that died mid-submit. Never resent on its own.
                        gate.withLock {
                            withContext(io) {
                                runCatching { outbox.markOutcomeUnknown(entry.rpcId, "resumed after a crash mid-submit") }
                            }
                        }
                        if (!reconcile(entry.rpcId)) blocked.add(entry.sessionId)
                    }
                }
                SendOutboxState.ACCEPTED -> if (!isInFlight(entry.rpcId)) reconcile(entry.rpcId)
                SendOutboxState.OUTCOME_UNKNOWN -> if (!reconcile(entry.rpcId)) blocked.add(entry.sessionId)
                SendOutboxState.QUEUED -> if (!deliver(entry)) blocked.add(entry.sessionId)
                // Resting (host/v1 §10 Lost target): it waits for the person, never for the engine,
                // and it does not hold a FIFO of any live session.
                SendOutboxState.TARGET_LOST -> Unit
            }
        }
        publish()
    }

    /** True when the session's FIFO may continue past this entry. */
    private suspend fun deliver(entry: SendOutboxEntry): Boolean {
        val facts = host.deliveryFacts()
        if (paused || facts.decide(paused) != ChatDeliveryPreparation.READY) return false
        if (entry.sessionId != host.activeSessionId()) {
            host.log("send outbox: held, the target session is not the active one")
            return false
        }
        // Every byte reference is verified before the first submit and before
        // every retry; a blocked entry is never sent as text alone.
        val verified = withContext(io) {
            try {
                outbox.verifiedAttachmentData(entry.rpcId)
                true
            } catch (missing: SendOutboxException.AttachmentMissing) {
                runCatching { outbox.recordAttachmentFailure(entry.rpcId, SendOutboxAttachmentFailure.MISSING) }
                false
            } catch (mismatch: SendOutboxException.AttachmentDigestMismatch) {
                runCatching { outbox.recordAttachmentFailure(entry.rpcId, SendOutboxAttachmentFailure.DIGEST_MISMATCH) }
                false
            } catch (_: SendOutboxException) {
                false
            }
        }
        if (!verified) return false
        if (!host.turnRunning()) {
            // This entry opens the turn. The entries behind it follow once its
            // prompt has been accepted (the host reports that and asks again).
            if (isInFlightAny(entry.sessionId)) return false
            synchronized(inFlight) { inFlight.add(entry.rpcId) }
            if (!host.startTurn(entry)) synchronized(inFlight) { inFlight.remove(entry.rpcId) }
            return false
        }
        val mode = synchronized(inFlight) { modes[entry.rpcId] } ?: MODE_QUEUE
        val submitted = gate.withLock {
            withContext(io) { runCatching { outbox.markSubmitting(entry.rpcId) }.isSuccess }
        }
        if (!submitted) return false
        // Eligibility can change during the durable write above. This live branch
        // has not called the transport, so it may put the entry back itself.
        if (paused || !host.deliveryFacts().executionEligible || !host.turnRunning() ||
            entry.sessionId != host.activeSessionId()
        ) {
            gate.withLock {
                withContext(io) {
                    runCatching {
                        outbox.markOutcomeUnknown(entry.rpcId, "lifecycle changed before transport submission")
                        outbox.requeue(entry.rpcId)
                    }
                }
            }
            return false
        }
        return try {
            host.promptRunningTurn(entry, mode)
            gate.withLock { withContext(io) { runCatching { outbox.markAccepted(entry.rpcId) } } }
            true
        } catch (cancelled: CancellationException) {
            withContext(kotlinx.coroutines.NonCancellable + io) {
                runCatching { outbox.markOutcomeUnknown(entry.rpcId, "cancelled during submission") }
            }
            throw cancelled
        } catch (failure: Exception) {
            gate.withLock {
                withContext(io) {
                    runCatching { outbox.markOutcomeUnknown(entry.rpcId, failure.message?.substringBefore('\n') ?: "unknown") }
                }
            }
            reconcile(entry.rpcId)
        }
    }

    /**
     * Settles an `accepted` or `outcomeUnknown` entry against the engine's own
     * history. True when the entry no longer holds its session's FIFO.
     */
    private suspend fun reconcile(rpcId: String): Boolean {
        val entry = withContext(io) { outbox.entry(rpcId) } ?: return true
        if (entry.state != SendOutboxState.ACCEPTED && entry.state != SendOutboxState.OUTCOME_UNKNOWN) return true
        val unsettled = entry.state == SendOutboxState.OUTCOME_UNKNOWN
        val result = host.readBack(entry)
        return gate.withLock {
            withContext(io) {
                when (result) {
                    SendOutboxReadBack.JOURNALED -> {
                        runCatching { outbox.observeAuthoritativeUserMessage(rpcId) }
                        true
                    }
                    // The engine holds it; its user message follows the next turn start.
                    SendOutboxReadBack.HELD -> {
                        if (unsettled) runCatching { outbox.markAccepted(rpcId) }
                        true
                    }
                    SendOutboxReadBack.ABSENT -> {
                        if (!unsettled) return@withContext true
                        // A submit that only just failed may still land: absence
                        // counts only after the settle delay, which grows with attempts.
                        val now = nowMs()
                        val settledAt = (entry.outcomeUnknownAtMs ?: now) + SendOutboxReadBack.settleDelayMs(entry.attempts)
                        if (now < settledAt) {
                            scheduleSettle(settledAt - now)
                            false
                        } else {
                            if (runCatching { outbox.requeue(rpcId) }.isSuccess) {
                                host.log("send outbox: read-back proved an unknown send absent; queued again with the same request")
                                flushRequested = true
                            }
                            false
                        }
                    }
                    // No proof either way: stay put, never guess and resend.
                    SendOutboxReadBack.INCONCLUSIVE -> !unsettled
                }
            }
        }
    }

    /** One wake-up for the earliest unknown send that still has to settle. */
    private fun scheduleSettle(afterMs: Long) {
        synchronized(this) {
            val deadline = nowMs() + afterMs
            if (onSettleDue != null) {
                onSettleDue(deadline)
                return
            }
            if (settleJob?.isActive == true && settleDeadlineMs <= deadline) return
            settleJob?.cancel()
            settleDeadlineMs = deadline
            settleJob = scope.launch {
                delay(afterMs.coerceAtLeast(100L))
                requestDelivery()
            }
        }
    }

    private fun isInFlight(rpcId: String): Boolean = synchronized(inFlight) { rpcId in inFlight }

    private fun isInFlightAny(sessionId: String): Boolean {
        val ids = synchronized(inFlight) { inFlight.toList() }
        return ids.any { outbox.entry(it)?.sessionId == sessionId }
    }

    private suspend fun publish() {
        val entries = withContext(io) { outbox.entries() }
        host.queueChanged(entries)
    }

    companion object {
        const val MODE_QUEUE: String = "queue"
        const val REASON_TURN_FAILED: String = "turn_failed"
        const val REASON_TURN_ENDED: String = "turn_not_completed"
    }
}
