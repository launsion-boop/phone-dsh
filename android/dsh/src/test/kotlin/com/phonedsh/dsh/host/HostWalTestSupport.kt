// phone-dsh — :dsh unit-test doubles for the WAL seam.
// SPDX-License-Identifier: MIT
//
// These live in the test source set on purpose: the production code must not
// grow a "fake WAL" that could be wired by mistake. `:dsh`'s JVM tests use
// [FakeHostWal] for the facade assertions and one real `WorkspaceLog` on a
// temporary directory for the integration assertion.

package com.phonedsh.dsh.host

import com.phonedsh.log.MseqAllocator
import com.phonedsh.log.MutationBody
import com.phonedsh.loopback.LoopbackConnection
import com.phonedsh.platform.DurabilityLevel
import com.phonedsh.wire.WireCodec
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking

/**
 * A [HostWal] whose recovery result is fixed by the test.
 *
 * @param recovery returned by [recover] unless [gate] or [failure] says
 *   otherwise.
 * @param level reported by [durabilityClaim] without any promotion.
 * @param failure thrown by [recover] instead of returning [recovery]; the
 *   message may contain a path so the facade's redaction can be asserted.
 * @param gate when set, [recover] suspends on it before returning; this is how
 *   the async-start test keeps `start()` provably non-blocking.
 * @param appendFailure thrown by [append] instead of returning an append; the
 *   write-failure tests use it to make the seam fail with a store code.
 * @param closeFailure thrown by [closeEpoch]; the kind of failure budgets.md §2
 *   names as "an unrepaired base mismatch at an epoch close".
 * @param closeGate when set, [closeEpoch] records the call and suspends on it.
 *   This is how the drain tests hold a `Draining` entry open while they feed the
 *   next signal, and how they prove the close is not cancelled by a deadline.
 */
internal class FakeHostWal(
    private val recovery: WalRecovery = WalRecovery.Recovered(
        nextMseq = 42,
        ackedMseq = 41,
        durableMseq = 40,
    ),
    private val level: DurabilityLevel = DurabilityLevel.LEVEL_1_PROCESS_KILL,
    private val failure: RuntimeException? = null,
    private val gate: CompletableDeferred<Unit>? = null,
    private val appendFailure: Exception? = null,
    private val closeFailure: Exception? = null,
    private val closeGate: CompletableDeferred<Unit>? = null,
    /** Returned by [pendingResync]; a test sets this to hold the periodic close. */
    var pendingResyncValue: WalResync? = null,
) : HostWal {
    /** How many times the facade asked for recovery. */
    var recoverCalls: Int = 0
        private set

    /** How many times the facade asked for a real re-recovery. */
    var resetCalls: Int = 0
        private set

    /** Whether an epoch close is inside the seam right now (drain tests). */
    val isClosing: Boolean get() = closing

    /** Every body the sink appended, in call order. */
    val appendedBodies = mutableListOf<MutationBody>()

    /** How many epoch closes the sink asked for. */
    var closeCalls: Int = 0
        private set

    private var nextAppendMseq: Long =
        (recovery as? WalRecovery.Recovered)?.nextMseq ?: 1L

    override suspend fun recover(): WalRecovery {
        recoverCalls += 1
        gate?.await()
        failure?.let { throw it }
        return recovery
    }

    override suspend fun resetForRecovery() {
        resetCalls += 1
    }

    override fun pendingResync(): WalResync? = pendingResyncValue

    override fun durabilityClaim(): DurabilityLevel = level

    override fun appliedMseq(): Long = (recovery as? WalRecovery.Recovered)?.ackedMseq ?: 0L

    override fun allocator(): MseqAllocator =
        MseqAllocator(lastMseq = nextAppendMseq - 1, nextMseq = nextAppendMseq)

    override suspend fun appendWorker(body: MutationBody, mseq: Long): WalWorkerAppend {
        appendFailure?.let { throw it }
        val tail = nextAppendMseq - 1
        if (mseq <= tail) return WalWorkerAppend.Behind(tail)
        if (mseq != nextAppendMseq) return WalWorkerAppend.Ahead(nextAppendMseq)
        appendedBodies += body
        nextAppendMseq += 1
        return WalWorkerAppend.Appended(WalAppend(mseq = mseq, materializedUptoMseq = mseq))
    }

    override suspend fun closeEpoch(): WalClose {
        closeFailure?.let { throw it }
        closeCalls += 1
        closing = true
        try {
            closeGate?.await()
        } finally {
            closing = false
        }
        return WalClose(durableUpto = (nextAppendMseq - 1).coerceAtLeast(0L))
    }

    /** Set while [closeEpoch] is suspended on [closeGate]. */
    @Volatile
    private var closing: Boolean = false
}

/**
 * A proof that a real [VfsSink] opened on [recovered].
 *
 * Tests that need a `WalUplink.Up` go through the production gate rather than
 * poking at a constructor: the sink is real, only its [HostWal] is a fake.
 */
internal fun wiredProof(
    recovered: WalRecovery.Recovered = WalRecovery.Recovered(42, 41, 40),
): VfsSink.Wired {
    val sink = VfsSink(FakeHostWal(recovered), HostLog.None)
    return runBlocking { sink.open(recovered) }
}

/** A legal `WalUplink.Up` built through the sink proof. */
internal fun wiredUplink(
    nextMseq: Long = 42,
    ackedMseq: Long = 41,
    durableMseq: Long = 40,
): WalUplink.Up {
    val recovered = WalRecovery.Recovered(nextMseq, ackedMseq, durableMseq)
    return WalUplink.up(
        MseqWatermark.Observed(nextMseq, ackedMseq, durableMseq),
        wiredProof(recovered),
    )
}

/** A [HostLog] that keeps every line so a test can assert what was (not) logged. */
internal class RecordingHostLog : HostLog {
    private val lock = Any()
    private val recorded = mutableListOf<String>()

    /** Every line, in order, without the level prefix. */
    val messages: List<String>
        get() = synchronized(lock) { recorded.toList() }

    override fun debug(message: String) = add(message)

    override fun info(message: String) = add(message)

    override fun warn(message: String) = add(message)

    override fun error(message: String) = add(message)

    private fun add(message: String) {
        synchronized(lock) { recorded += message }
    }
}

/** A connection that records the frames the host sends; no socket. */
internal class RecordingLoopbackConnection(
    override val id: String,
) : LoopbackConnection {
    val sent = mutableListOf<ByteArray>()

    /** Every close request, as `(code, reason)`. */
    val closes = mutableListOf<Pair<Short, String>>()

    override suspend fun sendBinary(payload: ByteArray) {
        sent += payload.copyOf()
    }

    override suspend fun close(code: Short, reason: String) {
        closes += code to reason
    }
}

/** A worker HELLO as `worker-entry.js` sends it (channel.md §4.1, worker variant). */
internal fun workerHelloFrame(seq: Long = HostHello.HELLO_SEQ): ByteArray = WireCodec.encode(
    """
    {"type":"HELLO","fields":{
      "boot_id":"ffeeddccbbaa99887766554433221100",
      "caps":["channel/1","vfs-sink/1","journal/1","api/1"],
      "fence":{"generation":3,"owner":"phone","wal_seq":41},
      "last_mseq":41,
      "proto":1,
      "role":"worker",
      "session_epoch":7
    }}
    """.trimIndent(),
    seq,
)
