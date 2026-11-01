// Host contract 1 — the persistent external ingress queue (plan §13.7 J2, P6).
// SPDX-License-Identifier: MIT
//
// Why this exists
// ---------------
// `AgentHarness` has exactly one entry point: `harness()` + `send`. A device, a
// personal connector or a voice trigger can knock while the app is backgrounded,
// while the session is recovering, or before the worker is up. Without a queue in
// front of `send`, the only way to make that work is to write the WAL directly
// from the connector — which is exactly the consistency failure the plan forbids
// (spec/host/v1/README.md §9: "a connector must not write the WAL directly").
//
// The queue is host behaviour ABOVE the host contract: there is no wire change,
// no schema change and no spec change. What it must preserve is the contract's
// own two promises:
//
//   idempotency — a `request_id` executes at most once, even if the connector
//                 retries (at-least-once delivery) or the process restarts;
//   ordering    — messages from one origin execute in `seq` order, whatever
//                 order they arrived in.
//
// It is deliberately *not* a batch API: each envelope becomes one `send` of the
// command it carries, so every existing contract rule (steer legality,
// permission answers, unknown-kind handling) still applies at the backend.
//
// Ordering needs a baseline, and a baseline cannot be guessed
// ----------------------------------------------------------
// "Deliver 2 before 1 and still execute 1 before 2" is only decidable if the
// queue knows which ordinal comes first. Guessing from the first arrival would
// make the outcome depend on the network: if 1 is merely late, accepting 2 as
// the baseline executes 2 first and turns 1 into a stale message. So an origin
// is **adopted** before its traffic runs — [IngressQueue.adopt] on the
// connector's handshake, or [IngressLog.watermark] after a restart. Until then
// its envelopes are accepted (durably, nothing lost) but parked. A wrong
// baseline is visible as a stalled `pendingCount`, never as silent reordering.
//
// Failure honesty, not optimism
// -----------------------------
//  * A delivery that throws leaves the envelope pending. The queue stops
//    draining (order is a promise, and skipping the failed item would break it),
//    records the failure, and returns the exception to the caller of
//    [IngressQueue.resume]; a later `resume()` retries. Redelivery is safe
//    because the backend deduplicates on `request_id` — that obligation is the
//    backend's and is stated in [AgentHarness.send].
//  * An envelope whose `seq` is already behind what this origin executed is
//    rejected as [IngressRejectionReason.STALE_SEQUENCE] instead of
//    being executed out of order. Executing it would be exactly the reordering
//    the queue exists to prevent; silently dropping it would hide a connector
//    bug.
//  * Two different `request_id`s claiming the same `(origin, seq)` are a
//    [IngressRejectionReason.SEQUENCE_CONFLICT]: one of the two is a
//    bug, and picking one by arrival order would make the outcome depend on
//    network timing.
//  * The queue starts parked. Nothing runs until the host says the session can
//    take work (`resume()` when `Running`, `park()` when it is not), which is the
//    "Parked 排队" half of the plan's J2 row.

package com.phonedsh.agentcore

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex

/**
 * One unit of external work waiting to reach a harness session.
 *
 * @param origin the connector/device identity, for example `device:dev-01`. Gaps
 *   and ordering are tracked **per origin**; two origins are independent.
 * @param requestId the idempotency key, globally unique (the contract's
 *   `request_id`, for example `dev:dev-01-000123`). A retry with the same key
 *   never executes twice.
 * @param seq the origin's monotonic ordinal. Gaps are legal in transit (the
 *   connector may retry out of order); the queue waits for the missing ordinal
 *   rather than executing a successor first.
 * @param command exactly what will be handed to [AgentHarness.send].
 */
public data class IngressEnvelope(
    public val origin: String,
    public val requestId: String,
    public val seq: Long,
    public val command: HarnessCommand,
) {
    init {
        require(origin.isNotBlank()) { "origin must not be blank" }
        require(requestId.isNotBlank()) { "requestId must not be blank" }
        require(seq >= 0) { "seq must be >= 0, was $seq" }
    }
}

/** What happened to one [IngressQueue.accept] call. */
public sealed interface IngressAdmission {
    /**
     * New work, durably accepted. It runs once the queue is resumed **and** its
     * origin is adopted; until then it stays parked (visible in
     * [IngressQueue.pendingCount]).
     */
    public data object Accepted : IngressAdmission

    /** The `request_id` was already accepted or executed; nothing new will run. */
    public data object Duplicate : IngressAdmission

    /** Refused, and not executed. The caller must surface this, not swallow it. */
    public data class Rejected(
        public val reason: IngressRejectionReason,
        public val detail: String,
    ) : IngressAdmission
}

/** Why an [IngressAdmission.Rejected] envelope was refused. */
public enum class IngressRejectionReason {
    /**
     * Its `seq` is already behind what this origin executed. Executing it would
     * reorder a later message, so it is refused instead.
     */
    STALE_SEQUENCE,

    /**
     * Another `request_id` already holds this `(origin, seq)`. Accepting both
     * would make the order depend on arrival, i.e. on the network.
     */
    SEQUENCE_CONFLICT,
}

/**
 * The durable seam behind [IngressQueue].
 *
 * The queue's in-memory index is an optimisation; this interface is what makes
 * the promises survive process death:
 *
 *  * [append] must be durable **before** it returns (a WAL record or an fsync),
 *    otherwise an accepted message can vanish while the connector believes it
 *    was delivered;
 *  * [pending] must return every accepted-but-not-executed envelope, so a new
 *    process can resume in `seq` order;
 *  * [isDelivered] must answer for every key ever executed, which is what makes
 *    a retry after a restart a [IngressAdmission.Duplicate] instead of a second
 *    turn;
 *  * [watermark] lets the restarted queue resume at the right ordinal instead of
 *    guessing; a store that cannot answer returns `null`, and the host must then
 *    re-[adopt][IngressQueue.adopt] from the connector handshake;
 *  * [markDelivered] may run after the side effect committed: a crash in between
 *    redelivers, and the backend's `request_id` dedupe absorbs it.
 *
 * [InMemoryIngressLog] is the reference implementation for tests, not a durable
 * store: it says so in its name because a host that ships it would be claiming a
 * persistence guarantee it does not have.
 */
public interface IngressLog {
    fun append(envelope: IngressEnvelope)

    fun pending(): List<IngressEnvelope>

    fun markDelivered(envelope: IngressEnvelope, deliveredAtMillis: Long)

    fun isDelivered(requestId: String): Boolean

    /** Highest executed `seq` for [origin], or `null` when the store has no record. */
    fun watermark(origin: String): Long? = null
}

/** The in-memory reference [IngressLog]. Lost on process death by design. */
public class InMemoryIngressLog : IngressLog {
    private val appended = ArrayList<IngressEnvelope>()
    private val delivered = HashSet<String>()
    private val deliveredAt = HashMap<String, Long>()
    private val watermarks = HashMap<String, Long>()

    @Synchronized
    override fun append(envelope: IngressEnvelope) {
        appended += envelope
    }

    @Synchronized
    override fun pending(): List<IngressEnvelope> =
        appended.filter { it.requestId !in delivered }

    @Synchronized
    override fun markDelivered(envelope: IngressEnvelope, deliveredAtMillis: Long) {
        delivered += envelope.requestId
        deliveredAt[envelope.requestId] = deliveredAtMillis
        val previous = watermarks[envelope.origin]
        if (previous == null || envelope.seq > previous) {
            watermarks[envelope.origin] = envelope.seq
        }
    }

    @Synchronized
    override fun isDelivered(requestId: String): Boolean = requestId in delivered

    @Synchronized
    override fun watermark(origin: String): Long? = watermarks[origin]

    /** When [requestId] was marked delivered, or `null`. Test/observation seam. */
    @Synchronized
    public fun deliveredAtMillis(requestId: String): Long? = deliveredAt[requestId]
}

/** Where an admitted envelope actually goes. One call per envelope, never batched. */
public fun interface IngressSink {
    /** @throws Exception when the work did not reach the harness; it stays pending. */
    public suspend fun deliver(envelope: IngressEnvelope)
}

/**
 * The [AgentHarness] adapter: one ingress envelope becomes one `send`.
 *
 * No queue-level rule is added here: `Prompt`/`Steer` idempotency, `Steer`
 * legality and permission answers keep the backend's semantics. The queue only
 * decides *when* (parked vs running) and *in which order*.
 */
public class HarnessIngressSink(
    private val harness: AgentHarness,
    private val sessionId: String,
) : IngressSink {
    override suspend fun deliver(envelope: IngressEnvelope) {
        harness.send(envelope.command, sessionId)
    }
}

/** A delivery failure, kept for the log / runtime details. */
public data class IngressFailure(
    public val requestId: String,
    public val origin: String,
    public val reason: String,
    public val atMillis: Long,
)

/**
 * The external ingress queue: at-least-once, `request_id` deduplicated, parked
 * until the host admits work, and executed in per-origin `seq` order.
 *
 * Not thread-safe by accident: every state read and write is inside one monitor,
 * so two connectors posting concurrently cannot interleave a hole in the order.
 * Delivery itself runs outside the monitor (it suspends), but only one drainer
 * exists at a time, which is what makes "in order" also mean "not concurrently".
 *
 * @param clock wall clock for the failure record; injectable for tests.
 */
public class IngressQueue(
    private val log: IngressLog,
    private val sink: IngressSink,
    private val clock: () -> Long = { System.currentTimeMillis() },
) {
    private val monitor = Any()
    private val drainGate = Mutex()

    /** Per-origin pending envelopes, ordered by `seq`; the in-memory index. */
    private val pendingByOrigin = HashMap<String, java.util.TreeMap<Long, IngressEnvelope>>()

    /** The next ordinal each **adopted** origin may execute. */
    private val nextExpected = HashMap<String, Long>()

    /** requestIds this process has accepted (pending or executed). */
    private val known = HashSet<String>()

    private var admitted = false
    private var failure: IngressFailure? = null

    init {
        // A process restart resumes what the durable store still holds. The
        // watermark is the baseline; without one the origin stays unadopted and
        // its work waits for the connector handshake instead of guessing.
        for (envelope in log.pending()) {
            known += envelope.requestId
            index(envelope)
            val watermark = log.watermark(envelope.origin)
            if (watermark != null) {
                nextExpected[envelope.origin] = watermark + 1
            }
        }
        for (origin in pendingByOrigin.keys.toList()) {
            val expected = nextExpected[origin] ?: continue
            val bySeq = pendingByOrigin[origin] ?: continue
            // A store that reports an envelope below its own watermark contradicts
            // itself; do not execute it above the watermark.
            bySeq.keys.removeAll { seq -> seq < expected }
            if (bySeq.isEmpty()) pendingByOrigin.remove(origin)
        }
    }

    /** How many accepted envelopes have not executed yet. */
    public val pendingCount: Int
        get() = synchronized(monitor) { pendingByOrigin.values.sumOf { it.size } }

    /** True until [resume] admits work (the initial state), or after [park]. */
    public val parked: Boolean
        get() = synchronized(monitor) { !admitted }

    /** The last delivery failure, or `null` after a successful drain. */
    public fun lastFailure(): IngressFailure? = synchronized(monitor) { failure }

    /** True when [origin] has a baseline to order against. */
    public fun isAdopted(origin: String): Boolean = synchronized(monitor) { origin in nextExpected }

    /**
     * Declares the first ordinal [origin] will deliver. Idempotent.
     *
     * Called from the connector handshake (the device knows its own outbox
     * position) or from persisted state after a restart. Without it the origin's
     * envelopes are accepted but never executed, because the queue cannot tell
     * "first message" from "gap before it".
     */
    public fun adopt(origin: String, nextSeq: Long) {
        require(origin.isNotBlank()) { "origin must not be blank" }
        require(nextSeq >= 0) { "nextSeq must be >= 0, was $nextSeq" }
        synchronized(monitor) {
            if (origin in nextExpected) return
            nextExpected[origin] = nextSeq
            val bySeq = pendingByOrigin[origin] ?: return
            // Envelopes below the baseline are already executed by the origin's
            // own account; keeping them would stall the queue forever.
            bySeq.keys.removeAll { seq -> seq < nextSeq }
            if (bySeq.isEmpty()) pendingByOrigin.remove(origin)
        }
    }

    /**
     * Accepts one envelope: appends it durably, then indexes it in `seq` order.
     *
     * Never executes anything itself — execution is [resume]'s job, so the host
     * keeps one place where the "is the session Running?" decision is made.
     */
    public fun accept(envelope: IngressEnvelope): IngressAdmission = synchronized(monitor) {
        if (envelope.requestId in known || log.isDelivered(envelope.requestId)) {
            return IngressAdmission.Duplicate
        }
        val expected = nextExpected[envelope.origin]
        if (expected != null && envelope.seq < expected) {
            // Executing this now would put it after a message the connector
            // ordered after it. Refuse and let the connector decide.
            return IngressAdmission.Rejected(
                IngressRejectionReason.STALE_SEQUENCE,
                "origin ${envelope.origin} expects seq >= $expected; seq ${envelope.seq} is late",
            )
        }
        val holder = pendingByOrigin[envelope.origin]?.get(envelope.seq)
        if (holder != null && holder.requestId != envelope.requestId) {
            return IngressAdmission.Rejected(
                IngressRejectionReason.SEQUENCE_CONFLICT,
                "origin ${envelope.origin} seq ${envelope.seq} is already held by " +
                    "${holder.requestId}, not ${envelope.requestId}",
            )
        }
        log.append(envelope)
        index(envelope)
        known += envelope.requestId
        IngressAdmission.Accepted
    }

    /** Stops admitting work; an in-flight delivery finishes, nothing new starts. */
    public fun park() {
        synchronized(monitor) { admitted = false }
    }

    /**
     * Admits work and drains what is deliverable, in per-origin `seq` order.
     *
     * Suspends until there is nothing deliverable (a hole in an origin's sequence
     * is a stop, not a skip) or a delivery fails. Concurrent callers are
     * serialized: the second one waits, then re-checks, so a message accepted
     * during the first drain is not stranded.
     *
     * @throws Exception the delivery failure, after the envelope stayed pending
     *   and the queue parked itself. Rethrowing is deliberate: a host that never
     *   saw the failure would report a healthy queue that executes nothing.
     */
    public suspend fun resume() {
        synchronized(monitor) { admitted = true }
        drainGate.lock()
        try {
            drain()
        } finally {
            drainGate.unlock()
        }
    }

    private suspend fun drain() {
        while (true) {
            val next = synchronized(monitor) { nextDeliverable() } ?: return
            val failureAt = try {
                sink.deliver(next)
                null
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (thrown: Throwable) {
                thrown
            }
            synchronized(monitor) {
                if (failureAt == null) {
                    log.markDelivered(next, clock())
                    remove(next)
                    nextExpected[next.origin] = next.seq + 1
                    failure = null
                } else {
                    // Order is a promise: keep the failed envelope at the head and
                    // stop. A later resume() retries it; the backend's request_id
                    // dedupe makes the redelivery harmless.
                    admitted = false
                    failure = IngressFailure(
                        requestId = next.requestId,
                        origin = next.origin,
                        reason = failureAt.message ?: failureAt::class.java.simpleName,
                        atMillis = clock(),
                    )
                }
            }
            if (failureAt != null) throw failureAt
        }
    }

    /** The lowest `seq` an adopted origin can execute now, or `null`. */
    private fun nextDeliverable(): IngressEnvelope? {
        if (!admitted) return null
        var best: IngressEnvelope? = null
        for ((origin, bySeq) in pendingByOrigin) {
            val expected = nextExpected[origin] ?: continue // unadopted: park, never guess
            val candidate = bySeq[expected] ?: continue // a hole: wait, never skip
            if (best == null || candidate.seq < best.seq ||
                (candidate.seq == best.seq && candidate.origin < best.origin)
            ) {
                best = candidate
            }
        }
        return best
    }

    private fun index(envelope: IngressEnvelope) {
        pendingByOrigin.getOrPut(envelope.origin) { java.util.TreeMap() }[envelope.seq] = envelope
    }

    private fun remove(envelope: IngressEnvelope) {
        val bySeq = pendingByOrigin[envelope.origin] ?: return
        bySeq.remove(envelope.seq)
        if (bySeq.isEmpty()) pendingByOrigin.remove(envelope.origin)
    }
}
