// phone-dsh — :dsh / com.phonedsh.dsh.host: the host side of the one channel.
// SPDX-License-Identifier: MIT
//
// ---- where this object sits ------------------------------------------------
// :engine owns the WebView and the loopback origin, and takes its frame consumer
// from the host at construction time:
//
//   createDemoEngine(context, channelHandler = host.channelHandler, ...)
//
// `HostChannel` is that consumer. It is the only place in the Android tree where
// the *host* answers the handshake and routes the VFS frames, which makes the
// demo's "host HELLO" and "VFS_ACK" evidence a property of the facade rather
// than of the UI lane.
//
// ---- what it may and may not do -------------------------------------------
// :net (`LoopbackChannelHandler`) moves whole binary payloads and never looks
// inside one. This class reads exactly two header fields — magic and type — to
// route a frame, and hands everything else to the owners: the HELLO to
// `:core`'s WireCodec, `VFS_MUT`/`VFS_BARRIER` to [VfsSink] (which decodes
// through the same codec), `EXEC_REQ`/`EXEC_CTL` to [ExecBridge] (which parses
// through the same codec), `JOURNAL` to [JournalSink] (which persists the record
// before it acks), the `API_REQ`/`API_RES`/`API_END`/`API_ABORT` lane through
// [HostApi], and the diagnostic `CONSOLE` text. It does not decode the payload
// itself for VFS, EXEC or the journal; the `/api` payload encoding lives in
// [HostApi], and the journal acknowledgement stays with [JournalSink].
//
// The worker sends HELLO as the first frame of its direction (§4.1/§7). The host
// sends its own HELLO with `seq = 1` and exactly once per connection; a second
// HELLO from the worker is `PROTO_MISMATCH`, so answering it again would be a
// protocol error invented on our side. A host HELLO is withheld until the
// facade's `ready` gate is true: sending the not-yet-recovered HELLO would tell
// the worker a watermark the host has not established.

// ---- not implemented in this class (explicit gaps, do not assume them) -----
// * host `single_file_limit` / `VFS_REFUSED` budget refusal (`channel.md` §8) is
//   not a gap of this router: the tier is selected by [HostBudgetTier] and the
//   refusal is answered by [VfsSink], which owns every `VFS_MUT`;
// * not-implemented: 32 MiB flow control (§8);
// * not-implemented: 2 ms group commit (§3.2 allows per-mutation level-1 ACKs,
//   which is what the sink does);
// * not-implemented: a live execution store and in-flight duplicate joining
//   (see HostExec.kt). `EXEC_CTL` (`0x22`) itself is dispatched below; a
//   persistent exec ledger belongs to the bridge the composition root injects
//   (HostExec), not to this router;
// * not-implemented: journal acknowledgement level 1 (§3.6). The sink fsyncs
//   every accepted record before it acks, so it sends level 2 only; the
//   worker's tracker treats level 2 as implying level 1 for the same jseq, so
//   a `tool-journal` append's level-1 wait still resolves on this frame.
// `VFS_MUT`/`EXEC_REQ`/`EXEC_CTL`/`JOURNAL` arriving before the host HELLO is
// logged and ignored: the codec/transport own the protocol error, and no ACK
// may precede seq 1.
//
// ---- inbound seq enforcement (channel.md §7.2, §7.4) ----------------------
// The HELLO establishes one inbound seq space per connection: the first frame
// must be HELLO at seq 1, and from then on every inbound frame's `seq` MUST be
// the previous inbound seq + 1. A gap, duplicate or regression is `BAD_SEQ`
// (§10) and closes. [acceptInboundSeq] is that one check, in [onBinary] before
// any dispatch, so every frame type is covered by the same rule instead of the
// per-frame handlers each growing their own.
//
// Two special cases are deliberate:
//   * HELLO is exempt from the +1 rule. §4.1 makes a later HELLO
//     `PROTO_MISMATCH`; this class keeps its existing policy of logging that
//     frame and not answering it (a duplicate host HELLO would itself be a
//     protocol error), so it is neither seq-checked nor advanced;
//   * a frame before the host HELLO does not advance the space. The host
//     starts its direction with seq 1 and these frames are ignored by the
//     per-lane gate, so the worker's HELLO later still opens at 1. A
//     first-frame HELLO at any other seq is `BAD_SEQ` (§7.2), including before
//     `ready` is true: the watermark being unknown is not a reason to accept a
//     frame the connection rule already refused.

package com.phonedsh.dsh.host

import com.phonedsh.dsh.exec.ExecBridge
import com.phonedsh.dsh.exec.ExecControl
import com.phonedsh.dsh.exec.ExecControlException
import com.phonedsh.dsh.exec.ExecControlOutcome
import com.phonedsh.dsh.exec.ExecEvent
import com.phonedsh.dsh.exec.ExecRequest
import com.phonedsh.dsh.exec.ExecRequestException
import com.phonedsh.dsh.journal.JournalAck
import com.phonedsh.dsh.journal.JournalException
import com.phonedsh.dsh.journal.JournalSender
import com.phonedsh.dsh.journal.JournalSink
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.loopback.ChannelCloseCause
import com.phonedsh.loopback.LoopbackChannelHandler
import com.phonedsh.loopback.LoopbackConnection
import com.phonedsh.wire.WireCodec
import com.phonedsh.wire.WireException
import com.phonedsh.wire.WireUnavailable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The host's frame consumer, HELLO responder, VFS/EXEC/journal router and
 * `/api` lane.
 *
 * Thread-safe: `:net` calls it sequentially per connection but several
 * connections may exist over one boot (a renderer rebuild reopens the channel),
 * and the counters are read from a UI thread. [hello] is a provider rather than a
 * value so the watermark is read at send time, after recovery.
 *
 * @param hello the current HELLO value; read when a worker HELLO is answered.
 * @param logger the token-free log seam.
 * @param vfs the VFS sink that owns `VFS_MUT`/`VFS_BARRIER`; `null` when this
 *   build has no WAL, in which case those frames are ignored (and the host did
 *   not advertise `wal/1`).
 * @param journal the journal sink that owns `JOURNAL`; `null`, or a sink whose
 *   store never opened, means this boot has nowhere to persist a record, so the
 *   frame is logged and ignored instead of acked. `channel.md` §4.1 defines no
 *   host journal capability, so the HELLO is identical either way.
 * @param exec the exec bridge that owns `EXEC_REQ` and `EXEC_CTL`; `null` means
 *   `exec/1` was not advertised and either frame is refused with `PROTO_MISMATCH`.
 * @param ready the facade's preparation gate; while it returns `false` a host
 *   HELLO is not sent.
 * It is also the writer of the host-to-worker `/api` direction: [apiRequest]
 * and [openApiStream] allocate the same per-connection `seq` the HELLO and VFS
 * frames use, which is why [sendMutex] serialises every outbound frame.
 *
 * @param onConsole receives the text of each `CONSOLE` (`0x60`) frame. The
 *   Worker announces `XL_DSH_READY` there once its `/api` subscriber is
 *   installed; the App uses that as the "a prompt can be sent now" signal.
 * @param failures the facade's write-failure surface. A journal append the
 *   store could not perform is reported here (when its code is attributable)
 *   before the exception is rethrown, so the D14 state becomes `Failed`
 *   instead of only the transport closing.
 */
class HostChannel(
    private val hello: () -> HostHello,
    private val logger: HostLog = HostLog.Println,
    private val vfs: VfsSink? = null,
    private val journal: JournalSink? = null,
    private val exec: ExecBridge? = null,
    private val ready: () -> Boolean = { true },
    private val onConsole: ((String) -> Unit)? = null,
    private val failures: WriteFailureSink = WriteFailureSink.None,
) : LoopbackChannelHandler {
    private val lock = Any()

    /** Connection ids that already received the host HELLO. */
    private val answered = HashSet<String>()

    /**
     * The last inbound `seq` accepted on each connection, present only once the
     * host HELLO opened the space (seeded to [HostHello.HELLO_SEQ]).
     *
     * A connection id that is absent has no inbound space yet: frames before
     * the host HELLO keep the per-lane ignore policy and do not advance it.
     */
    private val lastInboundSeq = HashMap<String, Long>()

    /** The next seq this host will put on each connection's wire (§1/§7). */
    private val nextOutboundSeq = HashMap<String, Long>()

    /** The per-connection sender registered with [vfs]. */
    private val vfsSenders = HashMap<String, VfsSender>()

    /** The per-connection acknowledgement sender registered with [journal]. */
    private val journalSenders = HashMap<String, JournalSender>()

    /**
     * Serialises seq allocation, encoding and `sendBinary` for every outbound
     * frame. HELLO/VFS_ACK/EXEC_EVT and the `/api` lane share one host-to-worker
     * seq space (`channel.md` §1), so two producers that allocate outside one
     * lock can put seq 7 on the wire after seq 8 and the worker closes with
     * `BAD_SEQ`.
     */
    private val sendMutex = Mutex()

    /** The one live connection, for a caller that originates an `/api` request. */
    @Volatile
    private var liveConnection: LoopbackConnection? = null

    /** In-flight `/api` exchanges, keyed by the wire `req_id`. */
    private val apiExchanges = ConcurrentHashMap<Int, HostApiExchange>()
    private val apiIds = HostApiIds()
    private var apiFramesToWorkerInternal = 0L
    private var apiFramesFromWorkerInternal = 0L

    private var framesToWorkerInternal = 0L
    private var execFramesToWorkerInternal = 0L
    private var lastErrorInternal: String? = null
    private val mutableLastSentHello = MutableStateFlow<HostHello?>(null)

    /** The HELLO most recently put on the wire this boot, or `null` before the first one. */
    val lastSentHello: StateFlow<HostHello?> = mutableLastSentHello.asStateFlow()

    /** Host HELLO frames actually sent this boot. */
    val framesToWorker: Long
        get() = synchronized(lock) { framesToWorkerInternal }

    /** `EXEC_EVT` frames actually sent this boot (a diagnostic counter). */
    val execFramesToWorker: Long
        get() = synchronized(lock) { execFramesToWorkerInternal }

    /** `API_REQ` frames actually sent this boot. */
    val apiFramesToWorker: Long
        get() = synchronized(lock) { apiFramesToWorkerInternal }

    /** `API_RES`/`API_END`/`API_ABORT` frames actually received this boot. */
    val apiFramesFromWorker: Long
        get() = synchronized(lock) { apiFramesFromWorkerInternal }

    /** A short, token-free reason the last HELLO could not be sent, or `null`. */
    val lastError: String?
        get() = synchronized(lock) { lastErrorInternal }

    override suspend fun onOpen(connection: LoopbackConnection) {
        logger.info("channel open on ${connection.id}; waiting for the worker HELLO")
        liveConnection = connection
        // A fresh connection is a fresh seq space and a fresh set of in-flight
        // API requests: the old ones were terminated locally by onClosed, and a
        // request is never replayed across connections (channel.md §9.4).
        abortApiExchanges("connection_replaced")
        val sender = VfsSender { frame -> sendVfs(connection, frame) }
        val journalSender = JournalSender { ack -> sendJournalAck(connection, ack) }
        synchronized(lock) {
            // A reused connection id starts a fresh seq space and must be able
            // to HELLO again (§7.4).
            answered.remove(connection.id)
            lastInboundSeq.remove(connection.id)
            nextOutboundSeq[connection.id] = HostHello.HELLO_SEQ
            vfsSenders[connection.id] = sender
            journalSenders[connection.id] = journalSender
        }
        vfs?.attach(sender)
        journal?.attach(journalSender)
    }

    override suspend fun onBinary(connection: LoopbackConnection, payload: ByteArray) {
        val type = HostFrame.typeOf(payload)
        if (type == HostFrame.HELLO) {
            onHelloFrame(connection, payload)
            return
        }
        if (!acceptInboundSeq(connection, type, payload)) return
        when (type) {
            HostFrame.VFS_MUT -> dispatchVfs(connection, HostFrame.seqOf(payload)) { refSeq ->
                vfs?.onMut(payload, refSeq)
            }
            HostFrame.VFS_BARRIER -> dispatchVfs(connection, HostFrame.seqOf(payload)) { refSeq ->
                vfs?.onBarrier(payload, refSeq)
            }
            HostFrame.JOURNAL -> dispatchVfs(connection, HostFrame.seqOf(payload)) { refSeq ->
                dispatchJournal(connection, payload, refSeq)
            }
            HostFrame.EXEC_REQ -> dispatchExec(connection, payload)
            HostFrame.EXEC_CTL -> dispatchExecControl(connection, payload)
            HostFrame.API_RES,
            HostFrame.API_END,
            HostFrame.API_ABORT,
            -> dispatchApi(connection, payload)
            HostFrame.CONSOLE -> dispatchConsole(payload)
            else -> Unit
        }
    }

    override suspend fun onClosed(connection: LoopbackConnection, cause: ChannelCloseCause) {
        val sender = synchronized(lock) {
            answered.remove(connection.id)
            lastInboundSeq.remove(connection.id)
            nextOutboundSeq.remove(connection.id)
            vfsSenders.remove(connection.id)
        }
        val journalSender = synchronized(lock) { journalSenders.remove(connection.id) }
        if (liveConnection === connection) liveConnection = null
        vfs?.detach(sender)
        journal?.detach(journalSender)
        // Each side aborts its own in-flight requests with `connection_closed`;
        // the abort is local and is never written to a dead socket (§9.4).
        abortApiExchanges("connection_closed")
        logger.info("channel closed on ${connection.id}: ${cause.name}")
    }

    /**
     * Handles one inbound HELLO without letting it into the §7.4 `+1` rule.
     *
     * §7.2: a first-frame HELLO at another seq is `BAD_SEQ` and closes, even
     * before `ready` is true. §4.1: a later HELLO is `PROTO_MISMATCH`; this
     * class keeps its existing policy for it (log it, answer nothing), because
     * answering it would itself be a protocol error. Leaving it out of the seq
     * space also preserves the one legitimate retry: a HELLO that arrived
     * before recovery finished was not consumed, so the same worker may send it
     * again at seq 1 once the host is ready.
     */
    private suspend fun onHelloFrame(connection: LoopbackConnection, payload: ByteArray) {
        if (hostHelloSent(connection)) {
            // sendHostHello owns the duplicate-HELLO warning; the frame must not
            // advance or fail the seq space (§4.1 PROTO_MISMATCH, not BAD_SEQ).
            sendHostHello(connection)
            return
        }
        val seq = HostFrame.seqOf(payload)
        if (seq != HostHello.HELLO_SEQ) {
            logger.warn(
                "worker HELLO on ${connection.id} carried seq $seq; " +
                    "channel.md §7.2 requires the first frame at seq 1",
            )
            sendVfs(
                connection,
                VfsFrame.Error(
                    code = "BAD_SEQ",
                    message = "the first HELLO carries seq ${HostHello.HELLO_SEQ}, was $seq",
                    refSeq = seq,
                    closeConnection = true,
                ),
            )
            return
        }
        if (sendHostHello(connection)) {
            // channel.md §9 item 6: a path still waiting for a resync is
            // re-requested after HELLO. Called after sendHostHello released
            // sendMutex, because the sink's send takes it again.
            vfs?.onHelloAnswered()
        }
    }

    /**
     * The one inbound-seq check (`channel.md` §7.4).
     *
     * Returns `true` when the frame may be dispatched. A connection with no
     * inbound space yet (no host HELLO) is not checked: those frames keep the
     * per-lane ignore policy and never advance the space. A frame whose header
     * this router does not recognise (`type < 0`) is not dispatched and does not
     * advance either; the codec/transport own the header verdict.
     *
     * A gap, duplicate or regression sends one closing `BAD_SEQ` `ERROR`
     * naming the offending seq as `ref_seq` (§7.4, §10) and returns `false`.
     */
    private suspend fun acceptInboundSeq(
        connection: LoopbackConnection,
        type: Int,
        payload: ByteArray,
    ): Boolean {
        if (type < 0) return false
        val seq = HostFrame.seqOf(payload)
        var expected: Long? = null
        // Check and advance are one critical section: two frames of one
        // connection must not both read the same "last" and disagree.
        val inOrder = synchronized(lock) {
            val last = lastInboundSeq[connection.id]
            when {
                last == null -> true
                seq == last + 1L -> {
                    lastInboundSeq[connection.id] = seq
                    true
                }

                else -> {
                    expected = last + 1L
                    false
                }
            }
        }
        if (inOrder) return true
        val want = expected ?: return true
        logger.warn(
            "inbound seq on ${connection.id} is $seq, expected $want " +
                "(channel.md §7.4); closing with BAD_SEQ",
        )
        sendVfs(
            connection,
            VfsFrame.Error(
                code = "BAD_SEQ",
                message = "expected seq $want, got $seq",
                refSeq = seq,
                closeConnection = true,
            ),
        )
        return false
    }

    /**
     * Routes one VFS frame only after this connection received the host HELLO.
     *
     * A VFS frame before HELLO is a §7.2 protocol error, but this class does not
     * invent an ERROR frame for it here: no ACK may be sent before the HELLO's
     * seq 1, and the connection's own protocol errors belong to the codec and
     * the transport. It logs and ignores. The §7.4 seq rule is checked earlier,
     * in [onBinary], so it applies to every frame type, not only these.
     */
    private suspend fun dispatchVfs(
        connection: LoopbackConnection,
        refSeq: Long,
        handler: suspend (refSeq: Long) -> Unit,
    ) {
        val hostHelloSent = synchronized(lock) { connection.id in answered }
        if (!hostHelloSent) {
            logger.warn("VFS frame on ${connection.id} before the host HELLO; ignoring")
            return
        }
        handler(refSeq)
    }

    /**
     * Routes one `JOURNAL` (`0x30`) into the journal sink.
     *
     * The HELLO gate is [dispatchVfs]'s, because a journal record is a
     * side-effect frame too (§4.7 lists it): no ACK may precede seq 1. When no
     * store opened this boot there is nothing to persist into and no host
     * capability to negotiate (`channel.md` §4.1 defines none), so the frame is
     * logged and ignored — acking it would be the test seam's lie, not a host.
     *
     * A malformed frame is a §10 protocol error: one closing `ERROR` carrying
     * the codec's code. A host-side journal failure (`JOURNAL_QUOTA_EXCEEDED`,
     * `JOURNAL_IO`, …) has no §10 code, so it closes the transport without
     * inventing one and is reported through [failures]; the attributable codes
     * of [HostFailureRules] move the controller to `Failed` (admission closes,
     * every durable byte kept), while an unattributable exception keeps the
     * pre-existing close-and-rethrow behavior and does not fail the host.
     */
    private suspend fun dispatchJournal(
        connection: LoopbackConnection,
        payload: ByteArray,
        refSeq: Long,
    ) {
        val sink = journal
        if (sink == null || !sink.isOpen) {
            logger.warn(
                "JOURNAL on ${connection.id} ignored: no journal store opened this boot " +
                    "(no ACK is sent, so the worker cannot mistake it for durability)",
            )
            return
        }
        try {
            sink.onJournal(payload)
        } catch (failure: JournalException) {
            val code = failure.wireCode
            if (code == null) {
                val reported = HostFailureRules.journal(failure)
                if (reported != null) {
                    failures.reportQuietly(
                        reported.reason,
                        "journal append failed (${reported.code})",
                        logger,
                    )
                }
                logger.error(
                    "JOURNAL on ${connection.id} not persisted (${failure.failure.code}); " +
                        "closing the transport without a protocol ERROR",
                )
                throw failure
            }
            logger.warn("JOURNAL on ${connection.id} refused (${failure.failure.code})")
            sendVfs(
                connection,
                VfsFrame.Error(
                    code = code,
                    message = failure.detail,
                    refSeq = refSeq,
                    closeConnection = true,
                ),
            )
        }
    }

    /**
     * Routes one `EXEC_REQ` (`0x20`) into the bridge and sends every `EXEC_EVT`
     * (`0x21`) it produces.
     *
     * A malformed request is a `channel.md` §10 `BAD_PAYLOAD`: one closing ERROR
     * and the connection ends, before anything is executed. When no bridge is
     * wired, the host did not advertise `exec/1`, so an EXEC_REQ is
     * `PROTO_MISMATCH`.
     */
    private suspend fun dispatchExec(connection: LoopbackConnection, payload: ByteArray) {
        val refSeq = HostFrame.seqOf(payload)
        if (!hostHelloSent(connection)) {
            logger.warn("EXEC_REQ on ${connection.id} before the host HELLO; ignoring")
            return
        }
        val bridge = exec
        if (bridge == null) {
            sendVfs(
                connection,
                VfsFrame.Error(
                    code = "PROTO_MISMATCH",
                    message = "exec/1 is not available this boot",
                    refSeq = refSeq,
                    closeConnection = true,
                ),
            )
            return
        }
        val fields = try {
            WireCodec.decode(payload)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: WireException) {
            sendExecRefusal(connection, failure.code, "EXEC_REQ is not a valid frame", refSeq)
            return
        } catch (failure: RuntimeException) {
            sendExecRefusal(connection, "BAD_PAYLOAD", "EXEC_REQ could not be decoded", refSeq)
            return
        }
        val request = try {
            ExecRequest.parse(fields)
        } catch (failure: ExecRequestException) {
            // field/reason are member names, never argv or a path.
            sendExecRefusal(
                connection,
                failure.code,
                "EXEC_REQ refused (${failure.field}/${failure.reason.wireName})",
                refSeq,
            )
            return
        } catch (failure: WireException) {
            sendExecRefusal(connection, failure.code, "EXEC_REQ JSON was refused", refSeq)
            return
        }
        try {
            bridge.onRequest(request).collect { event -> sendExecEvent(connection, event) }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            logger.error("EXEC_EVT stream failed on ${connection.id} (${failure.javaClass.simpleName})")
        }
    }

    /**
     * Routes one `EXEC_CTL` (`0x22`) into the bridge's control entry point.
     *
     * `channel.md` §4.4 defines no reply frame, so the observable answer is the
     * live execution's own `EXEC_EVT` stream: [ExecControlOutcome.Applied] and
     * [ExecControlOutcome.Refused] were already written into it by the bridge
     * (the `EXEC_REQ` collector is still sending those events on this same
     * connection), and re-sending them here would duplicate a terminal event.
     * [ExecControlOutcome.Ignored] changes nothing at all — a cancel that names
     * no live execution is legal and silent.
     *
     * [ExecControlOutcome.Emit] is the one case this host must frame itself: the
     * bridge had no live stream to write the terminal refusal into, so the
     * event is sent as an independent terminal `EXEC_EVT` (`exec.md` §4.4 maps
     * a stdin control to an explicit refusal, never a dropped frame).
     *
     * ### Legal but stale is not a protocol error
     *
     * A well-formed control whose `exec_id` names no live execution is *late*,
     * not malformed: `cancel` is [ExecControlOutcome.Ignored] and is answered
     * with nothing at all, `stdin` gets the standalone terminal event above.
     * Only a frame that fails to decode or violates §4.4 — an unknown `op`, a
     * bad `exec_id` shape, `data` on `cancel`, a missing or non-base64 `data` —
     * is a `channel.md` §10 `BAD_PAYLOAD`: one closing `ERROR` naming this
     * frame's `seq` as `ref_seq`, exactly like a malformed `EXEC_REQ`. A late
     * `cancel` must never be escalated to a fatal error: ordinary network
     * reordering produces exactly that frame, and closing would punish a
     * conforming peer for timing it cannot control.
     *
     * When no bridge is wired, `exec/1` was not advertised, so the frame is
     * `PROTO_MISMATCH`.
     */
    private suspend fun dispatchExecControl(connection: LoopbackConnection, payload: ByteArray) {
        val refSeq = HostFrame.seqOf(payload)
        if (!hostHelloSent(connection)) {
            logger.warn("EXEC_CTL on ${connection.id} before the host HELLO; ignoring")
            return
        }
        val bridge = exec
        if (bridge == null) {
            sendVfs(
                connection,
                VfsFrame.Error(
                    code = "PROTO_MISMATCH",
                    message = "exec/1 is not available this boot",
                    refSeq = refSeq,
                    closeConnection = true,
                ),
            )
            return
        }
        val control = try {
            ExecControl.parse(WireCodec.decode(payload))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: ExecControlException) {
            // field/reason are member names, never the base64 data or an id.
            sendExecRefusal(
                connection,
                failure.code,
                "EXEC_CTL refused (${failure.field}/${failure.reason.wireName})",
                refSeq,
            )
            return
        } catch (failure: WireException) {
            sendExecRefusal(connection, failure.code, "EXEC_CTL is not a valid frame", refSeq)
            return
        } catch (failure: RuntimeException) {
            sendExecRefusal(connection, "BAD_PAYLOAD", "EXEC_CTL could not be decoded", refSeq)
            return
        }
        when (val outcome = bridge.onControl(control)) {
            ExecControlOutcome.Applied,
            ExecControlOutcome.Ignored,
            is ExecControlOutcome.Refused,
            -> Unit

            is ExecControlOutcome.Emit -> sendExecEvent(connection, outcome.event)
        }
    }

    // -------------------------------------------------------------- /api lane

    /**
     * One unary `/api` call: sends `API_REQ` (`0x40`), collects `API_RES`
     * (`0x41`) bodies and returns when `API_END` (`0x42`) arrives.
     *
     * The exchange is registered before the frame is sent, so a response that
     * comes back before this coroutine reaches `await` is not lost. A timeout
     * removes the exchange and fails the caller; the frame itself is not
     * replayed (`channel.md` §9.4).
     *
     * @throws HostApiException `no_channel`, `api_send_failed`, `timeout` or
     *   `api_aborted`; the message never carries a header, body or token.
     */
    suspend fun apiRequest(
        method: String,
        path: String,
        headers: Map<String, String> = emptyMap(),
        body: ByteArray = ByteArray(0),
        timeoutMillis: Long = API_REQUEST_TIMEOUT_MILLIS,
    ): HostApiResponse {
        val exchange = beginApiExchange()
        try {
            sendApiRequest(exchange.reqId, method, path, headers, body)
            val completed = withTimeoutOrNull(timeoutMillis) { exchange.done.await() }
            if (completed == null) {
                apiExchanges.remove(exchange.reqId)
                throw HostApiException(
                    "timeout",
                    "API_REQ ${exchange.reqId} did not finish within $timeoutMillis ms",
                )
            }
            exchange.abortReason?.let { reason ->
                // A channel that ended under the request is a *transport* failure,
                // not a turn the Worker aborted: P22 gave it its own code so the App
                // can say "the channel was lost" instead of the `api_aborted` that
                // used to stand for both (measured 12:47:39, emulator API 35).
                throw ChannelLoss.failure(reason, exchange.reqId)
            }
            val head = if (exchange.head.isCompleted) exchange.head.await() else null
            if (head == null) {
                // channel.md §3.8: the first API_RES chunk carries the head. An
                // API_END with no head is a protocol violation; returning a
                // fabricated status 0 would make the caller believe it has a
                // response it never received.
                throw HostApiException(
                    "invalid_response",
                    "API_END ${exchange.reqId} arrived before the first API_RES head",
                )
            }
            return HostApiResponse(head = head, body = exchange.drain())
        } catch (failure: Throwable) {
            apiExchanges.remove(exchange.reqId)
            throw failure
        }
    }

    /**
     * A long-lived `/api` call: sends `API_REQ` and returns the live response
     * stream. Each `API_RES` body chunk is delivered as the worker writes it;
     * the channel closes on `API_END` and fails on `API_ABORT`.
     */
    suspend fun openApiStream(
        method: String,
        path: String,
        headers: Map<String, String> = emptyMap(),
        body: ByteArray = ByteArray(0),
    ): HostApiStream {
        val exchange = beginApiExchange()
        try {
            sendApiRequest(exchange.reqId, method, path, headers, body)
        } catch (failure: Throwable) {
            apiExchanges.remove(exchange.reqId)
            throw failure
        }
        return HostApiStream(exchange.reqId, exchange) { apiExchanges.remove(it) }
    }

    private fun beginApiExchange(): HostApiExchange {
        val exchange = HostApiExchange(apiIds.mint())
        apiExchanges[exchange.reqId] = exchange
        return exchange
    }

    /**
     * Sends one `API_REQ` at the connection's next seq.
     *
     * The whole allocate/encode/send block takes [sendMutex]: the host HELLO,
     * VFS_ACK, EXEC_EVT and API_REQ share one direction's seq space.
     */
    private suspend fun sendApiRequest(
        reqId: Int,
        method: String,
        path: String,
        headers: Map<String, String>,
        body: ByteArray,
    ) {
        val connection = liveConnection
            ?: throw HostApiException("no_channel", "no channel connection is open")
        if (!hostHelloSent(connection)) {
            throw HostApiException("no_channel", "the host HELLO has not been answered yet")
        }
        sendMutex.withLock {
            val seq = nextSeq(connection)
                ?: throw HostApiException("no_channel", "the connection has no seq space")
            val frame = try {
                HostApiFrames.encodeRequest(reqId, method, path, headers, body, seq)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                throw HostApiException(
                    "api_send_failed",
                    "API_REQ $reqId could not be encoded (${failure.javaClass.simpleName})",
                )
            }
            try {
                connection.sendBinary(frame)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                throw HostApiException(
                    "api_send_failed",
                    "API_REQ $reqId could not be sent (${failure.javaClass.simpleName})",
                )
            }
            synchronized(lock) { apiFramesToWorkerInternal += 1 }
            // Path only: a header or a body could carry a token or a prompt.
            logger.info("api: API_REQ req_id=$reqId seq=$seq $method $path (${body.size} B)")
        }
    }

    /**
     * Routes one inbound `API_RES`/`API_END`/`API_ABORT`.
     *
     * Dispatch is by `req_id` into [apiExchanges]; a response for an exchange
     * this host already timed out or aborted is ignored, because a late frame is
     * legal and must not be mistaken for a protocol error.
     */
    private suspend fun dispatchApi(connection: LoopbackConnection, payload: ByteArray) {
        synchronized(lock) { apiFramesFromWorkerInternal += 1 }
        val fields = HostApiFrames.fields(payload)
        if (fields == null) {
            logger.warn("api: a response frame on ${connection.id} was not decodable; ignoring")
            return
        }
        val reqId = HostApiFrames.reqId(fields)
        if (reqId == null) {
            logger.warn("api: a response frame on ${connection.id} had no req_id; ignoring")
            return
        }
        val exchange = apiExchanges[reqId]
        if (exchange == null) {
            logger.debug("api: response for unknown req_id=$reqId; ignoring")
            return
        }
        when (HostFrame.typeOf(payload)) {
            HostFrame.API_RES -> {
                HostApiFrames.head(fields)?.let { head ->
                    if (!exchange.head.isCompleted) exchange.head.complete(head)
                }
                val bytes = HostApiFrames.body(fields)
                if (bytes.isNotEmpty()) exchange.body.trySend(bytes)
                logger.info("api: API_RES req_id=$reqId (${bytes.size} B)")
            }

            HostFrame.API_END -> {
                exchange.finish()
                apiExchanges.remove(reqId)
                logger.info("api: API_END req_id=$reqId")
            }

            HostFrame.API_ABORT -> {
                val reason = HostApiFrames.abortReason(fields)
                exchange.abort(reason)
                apiExchanges.remove(reqId)
                logger.warn("api: API_ABORT req_id=$reqId reason=$reason")
            }
        }
    }

    /** Delivers one `CONSOLE` text; the frame is diagnostic, never durable. */
    private suspend fun dispatchConsole(payload: ByteArray) {
        val fields = HostApiFrames.fields(payload) ?: return
        val text = (fields["text"] as? JsonString)?.value ?: return
        val level = (fields["level"] as? JsonString)?.value ?: "info"
        if (text.contains(WORKER_READY_MARKER)) {
            logger.info("worker console: ready announcement (level=$level)")
        }
        onConsole?.invoke(text)
    }

    /**
     * Terminates every in-flight API request locally and forgets it.
     *
     * Logged when it actually aborts something: on a lost channel this is the line
     * that says how much work the close took with it, which is the host's half of
     * "the loss is not silent".
     */
    private fun abortApiExchanges(reason: String) {
        if (apiExchanges.isEmpty()) return
        val exchanges = apiExchanges.values.toList()
        apiExchanges.clear()
        if (reason in ChannelLoss.REASONS) {
            logger.warn(
                "api: ${exchanges.size} in-flight request(s) aborted because the channel ended ($reason); " +
                    "the engine reloads the page and a later request uses the new channel",
            )
        }
        for (exchange in exchanges) exchange.abort(reason)
    }

    private suspend fun sendExecRefusal(
        connection: LoopbackConnection,
        code: String,
        message: String,
        refSeq: Long,
    ) {
        sendVfs(
            connection,
            VfsFrame.Error(
                code = code,
                message = message,
                refSeq = refSeq,
                closeConnection = true,
            ),
        )
    }

    private suspend fun sendExecEvent(connection: LoopbackConnection, event: ExecEvent) {
        sendMutex.withLock {
            val seq = nextSeq(connection) ?: return
            val bytes = try {
                event.encode(seq)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                logger.error("EXEC_EVT not encoded (${failure.javaClass.simpleName})")
                return
            }
            try {
                connection.sendBinary(bytes)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                logger.error("EXEC_EVT not sent on ${connection.id} (${failure.javaClass.simpleName})")
                return
            }
            synchronized(lock) { execFramesToWorkerInternal += 1 }
        }
    }

    /**
     * Encodes and sends one `JOURNAL_ACK` (`0x31`) at this connection's next seq.
     *
     * The sink calls this only after the record's fsync returned (see
     * [JournalSink.onJournal]), which is why this method takes a value rather
     * than reading the store: there is nothing here that could ack a byte that
     * is not durable. It shares [sendMutex] and [nextSeq] with every other
     * outbound frame, so a journal ACK cannot race a HELLO or a VFS_ACK for the
     * same `seq` space. A send failure is logged and dropped: the record stays
     * durable and the worker re-sends the jseq on the next connection, where the
     * sink's duplicate path acks it again.
     */
    private suspend fun sendJournalAck(connection: LoopbackConnection, ack: JournalAck) {
        sendMutex.withLock {
            val seq = nextSeq(connection) ?: return
            val bytes = try {
                ack.encode(seq)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                logger.error("JOURNAL_ACK not encoded (${failure.javaClass.simpleName})")
                return
            }
            try {
                connection.sendBinary(bytes)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                logger.error(
                    "JOURNAL_ACK not sent on ${connection.id} (${failure.javaClass.simpleName})",
                )
                return
            }
        }
    }

    /** `true` once this connection has received the host HELLO. */
    private fun hostHelloSent(connection: LoopbackConnection): Boolean =
        synchronized(lock) { connection.id in answered }

    /**
     * Encodes and sends one host HELLO.
     *
     * A codec failure (missing `libpdsh_jni`, a refused field) is recorded and
     * logged, never thrown: the page must keep running and the demo screen must
     * show the reason, which is the same policy :engine applies to its own HELLO
     * decode. A transport failure is recorded the same way; `:net` reports the
     * close through [onClosed].
     */
    private suspend fun sendHostHello(connection: LoopbackConnection): Boolean {
        if (!ready()) {
            logger.info(
                "worker HELLO on ${connection.id} before recovery finished; " +
                    "not answering yet (the HELLO watermark is not final)",
            )
            return false
        }
        val firstHello = synchronized(lock) {
            val first = answered.add(connection.id)
            if (first) {
                // §7.2/§7.4: HELLO is seq 1, so the worker's next frame is 2.
                // The space opens only now: a HELLO that was ignored while
                // `ready` was false has not started the host's direction.
                lastInboundSeq[connection.id] = HostHello.HELLO_SEQ
            }
            first
        }
        if (!firstHello) {
            logger.warn(
                "worker sent a second HELLO on ${connection.id}; not answering it " +
                    "(duplicate host HELLO is PROTO_MISMATCH, channel.md §4.1)",
            )
            return false
        }
        sendMutex.withLock {
            val value = hello()
            val seq = nextSeq(connection) ?: HostHello.HELLO_SEQ
            val frame = try {
                value.encode(seq)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                val reason = describeFailure(failure)
                noteError(reason)
                logger.error("host HELLO not encoded: $reason")
                return false
            }
            try {
                connection.sendBinary(frame)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                val reason = "host HELLO not sent (${failure.javaClass.simpleName})"
                noteError(reason)
                logger.error("$reason on ${connection.id}")
                return false
            }
            synchronized(lock) {
                framesToWorkerInternal += 1
                lastErrorInternal = null
                mutableLastSentHello.value = value
            }
            logger.info(
                "host HELLO sent on ${connection.id}: proto=${value.proto}, caps=${value.capabilities.describe()}, " +
                    "next_mseq=${value.watermark.nextMseq}, acked_mseq=${value.watermark.ackedMseq}, " +
                    "durable_mseq=${value.watermark.durableMseq}, boot_id=${value.bootId}, " +
                    "session_epoch=${value.sessionEpoch}, ${value.watermark.provenance}",
            )
        }
        return true
    }

    /**
     * Encodes and sends one VFS frame at this connection's next seq.
     *
     * A closing ERROR is followed by `close(1002)`; the frame is flushed by
     * [LoopbackConnection.sendBinary] before the close request.
     */
    private suspend fun sendVfs(connection: LoopbackConnection, frame: VfsFrame) {
        sendMutex.withLock {
            val seq = nextSeq(connection) ?: return
            val bytes = try {
                frame.encode(seq)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                logger.error("VFS frame not encoded (${failure.javaClass.simpleName})")
                return
            }
            try {
                connection.sendBinary(bytes)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                logger.error("VFS frame not sent on ${connection.id} (${failure.javaClass.simpleName})")
                return
            }
        }
        if (frame is VfsFrame.Error && frame.closeConnection) {
            try {
                connection.close(CLOSE_PROTOCOL_ERROR, frame.code)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                logger.warn("VFS ERROR close failed on ${connection.id} (${failure.javaClass.simpleName})")
            }
        }
    }

    /** Takes and advances the connection's outbound seq. */
    private fun nextSeq(connection: LoopbackConnection): Long? = synchronized(lock) {
        val next = nextOutboundSeq[connection.id] ?: return null
        nextOutboundSeq[connection.id] = next + 1
        next
    }

    private fun noteError(reason: String) {
        synchronized(lock) { lastErrorInternal = reason }
    }

    /** A safe, token-free reason: never the whole frame or the page URL. */
    private fun describeFailure(failure: Throwable): String = when (failure) {
        is WireUnavailable -> "hello encode unavailable (libpdsh_jni not packaged)"
        is WireException -> "hello encode failed (${failure.code})"
        else -> "hello encode failed (${failure.javaClass.simpleName})"
    }

    private companion object {
        /** `channel.md` §10: a closing protocol error. */
        const val CLOSE_PROTOCOL_ERROR: Short = 1002

        /** Generous enough for a cold `session/create`; the caller may override. */
        const val API_REQUEST_TIMEOUT_MILLIS: Long = 60_000L

        /** The Worker's announce marker; it means its `/api` subscriber is live. */
        const val WORKER_READY_MARKER: String = "XL_DSH_READY"
    }
}

/**
 * The header fields the host needs before the codec sees a payload.
 *
 * Layout is `spec/v1/channel.md` §1: 16-byte header, `magic u16 = 0x5A4C` at
 * offset 0, `type u8` at offset 2, `seq u64` at offset 4. A payload shorter than
 * the header, or one whose magic disagrees, is not a frame this class will
 * answer; the codec closes the connection for a bad header, so guessing here
 * would only hide its verdict.
 */
internal object HostFrame {
    /** channel.md §1: every frame starts with this 16-byte header. */
    const val HEADER_BYTES: Int = 16

    /** channel.md §1: `magic u16 = 0x5A4C`, big-endian. */
    const val MAGIC: Int = 0x5A4C

    /** channel.md §1: `type` offset. */
    const val TYPE_OFFSET: Int = 2

    /** channel.md §1: `seq` offset. */
    const val SEQ_OFFSET: Int = 4

    /** channel.md §2: HELLO. */
    const val HELLO: Int = 0x01

    /** channel.md §2: VFS_MUT. */
    const val VFS_MUT: Int = 0x10

    /** channel.md §2: VFS_ACK. */
    const val VFS_ACK: Int = 0x11

    /** channel.md §2: VFS_BARRIER. */
    const val VFS_BARRIER: Int = 0x12

    /** channel.md §2: VFS_RESYNC. */
    const val VFS_RESYNC: Int = 0x13

    /** channel.md §2: EXEC_REQ. */
    const val EXEC_REQ: Int = 0x20

    /** channel.md §2: EXEC_EVT. */
    const val EXEC_EVT: Int = 0x21

    /** channel.md §2: EXEC_CTL. */
    const val EXEC_CTL: Int = 0x22

    /** channel.md §2: JOURNAL (worker to host). */
    const val JOURNAL: Int = 0x30

    /** channel.md §2: API_REQ (host to worker). */
    const val API_REQ: Int = 0x40

    /** channel.md §2: API_RES (worker to host). */
    const val API_RES: Int = 0x41

    /** channel.md §2: API_END (worker to host). */
    const val API_END: Int = 0x42

    /** channel.md §2: API_ABORT (both). */
    const val API_ABORT: Int = 0x43

    /** channel.md §2: CONSOLE (worker to host). */
    const val CONSOLE: Int = 0x60

    /** `true` when [payload] is a complete frame whose type byte is HELLO. */
    fun isHello(payload: ByteArray): Boolean = typeOf(payload) == HELLO

    /**
     * The frame's type byte, or `-1` when the payload is not a complete frame
     * with this protocol's magic.
     */
    fun typeOf(payload: ByteArray): Int {
        if (payload.size < HEADER_BYTES || magicOf(payload) != MAGIC) return -1
        return payload[TYPE_OFFSET].toInt() and 0xFF
    }

    /** The big-endian `u64` at [SEQ_OFFSET]; callers have a complete frame. */
    fun seqOf(payload: ByteArray): Long {
        var value = 0L
        for (offset in SEQ_OFFSET until SEQ_OFFSET + 8) {
            value = (value shl 8) or (payload[offset].toLong() and 0xFF)
        }
        return value
    }

    /** The big-endian `u16` at offset 0. */
    fun magicOf(payload: ByteArray): Int {
        if (payload.size < 2) return -1
        return ((payload[0].toInt() and 0xFF) shl 8) or (payload[1].toInt() and 0xFF)
    }
}

/**
 * The stable failure of a `/api` request whose channel ended under it (P22).
 *
 * Module-visible because the `:dsh` test asserts the code the App renders, and a
 * hard-coded string in three places would drift the day one of them changes.
 *
 * Two shapes reach a caller: [HostChannel.apiRequest] throws the failure directly,
 * and [HostApiStream] closes its chunk channel with it and
 * [com.phonedsh.dsh.turn.DshTurnClient] re-raises the code. Both come from
 * [failure] so a lost transport can never be reported as `api_aborted` (which is
 * what a *Worker-sent* `API_ABORT` means).
 */
internal object ChannelLoss {
    /** `HostApiException.code` for a request whose connection closed under it. */
    const val CODE: String = "channel_lost"

    /**
     * The local abort reasons that mean "the connection ended", not "the turn
     * ended". `connection_replaced` is the fresh-connection path in
     * [HostChannel.onOpen]; an `API_ABORT` the Worker sends is never one of these.
     */
    val REASONS: Set<String> = setOf("connection_closed", "connection_replaced")

    /** The typed failure for a local abort [reason] of request [reqId]. */
    fun failure(reason: String, reqId: Int? = null): HostApiException {
        val request = if (reqId == null) "the request" else "API_REQ $reqId"
        return if (reason in REASONS) {
            HostApiException(
                CODE,
                "the ordered channel closed while $request was in flight ($reason); " +
                    "the engine is reopening the page",
            )
        } else {
            HostApiException("api_aborted", "$request: $reason")
        }
    }
}
