// phone-dsh — :engine / com.phonedsh.engine: what the page and host exchanged.
// SPDX-License-Identifier: MIT
//
// This is the observability seam for the demo screen (D3): frame counts in both
// directions, the last frame type, a safe last error, and the HELLO summary
// decoded through the Rust codec (`:core`'s WireCodec). :engine still does not
// interpret payloads; it labels frames, asks the codec about HELLO only, and
// forwards every byte unchanged.
//
// Failure policy (parent contract, 2026-10-31): a HELLO that cannot be decoded —
// including "the JNI library is not packaged yet" — must NOT fail the engine. The
// handshake stays null, `lastError` says why, and the page keeps running.

package com.phonedsh.engine

import com.phonedsh.loopback.ChannelCloseCause
import com.phonedsh.wire.WireCodec
import com.phonedsh.wire.WireException
import com.phonedsh.wire.WireUnavailable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Decodes one whole frame to the canonical JSON of its `fields` (the codec seam). */
fun interface WireFrameDecoder {
    fun decode(payload: ByteArray): String
}

/** The production decoder: the one codec, in Rust, through `:core`'s JNI facade. */
object NativeWireFrameDecoder : WireFrameDecoder {
    override fun decode(payload: ByteArray): String = WireCodec.decode(payload)
}

/**
 * The channel/HELLO observability of one engine instance.
 *
 * Thread-safe: the origin calls it from Ktor IO threads, the engine from the UI
 * thread. Counters are cumulative per engine start (reset by [resetForStart]).
 */
class ChannelTelemetry(
    private val decoder: WireFrameDecoder = NativeWireFrameDecoder,
    private val logger: EngineLogger,
    private val clock: () -> Long = { System.currentTimeMillis() },
) {
    private val mutableStatus = MutableStateFlow(EMPTY)
    private val mutableHandshake = MutableStateFlow<HandshakeSummary?>(null)

    private val lock = Any()
    private var proto = 0
    private var workerCapabilities: List<String> = emptyList()
    private var hostCapabilities: List<String> = emptyList()
    private var nextMseq = 0L
    private var ackedMseq = 0L
    private var receivedAtMillis = 0L

    /** Frame counts, connection flag, last frame type and safe last error. */
    val status: StateFlow<ChannelStatus> = mutableStatus.asStateFlow()

    /** The merged HELLO summary; null before the first HELLO and after `stop()`. */
    val handshake: StateFlow<HandshakeSummary?> = mutableHandshake.asStateFlow()

    /** A new `start()` begins a new run: counters restart, handshake is cleared. */
    fun resetForStart() {
        synchronized(lock) { clearPendingLocked() }
        mutableStatus.value = EMPTY
    }

    /** The page's channel was accepted (token already verified by the origin). */
    fun onChannelOpen() {
        mutableStatus.update { it.copy(connected = true) }
    }

    /** One datagram arrived from the page. Counted, labelled, HELLO decoded. */
    fun onInbound(payload: ByteArray) {
        val typeByte = typeByteOf(payload)
        mutableStatus.update {
            it.copy(
                framesFromWorker = it.framesFromWorker + 1,
                lastFrameType = labelOf(typeByte),
            )
        }
        if (typeByte >= 0 && FrameType.isHello(typeByte)) decodeHello(payload, inbound = true)
    }

    /** One frame was sent to the page through the connection this engine handed out. */
    fun onOutbound(payload: ByteArray) {
        val typeByte = typeByteOf(payload)
        mutableStatus.update {
            it.copy(
                framesToWorker = it.framesToWorker + 1,
                lastFrameType = labelOf(typeByte),
            )
        }
        if (typeByte >= 0 && FrameType.isHello(typeByte)) decodeHello(payload, inbound = false)
    }

    /** The channel ended; [cause] decides whether it is worth showing as an error. */
    fun onChannelClosed(cause: ChannelCloseCause) {
        val note = when (cause) {
            ChannelCloseCause.TRANSPORT_LOST -> "channel lost (transport)"
            ChannelCloseCause.UNSUPPORTED_FRAME -> "channel closed: text frame on a binary channel"
            ChannelCloseCause.FRAME_TOO_LARGE -> "channel closed: frame too large"
            ChannelCloseCause.HANDLER_FAILED -> "channel closed: handler failed"
            // A page-initiated close is a close with a *reason code*: the worker's
            // own client (normal shutdown or a fatal protocol error such as
            // BAD_MSEQ) or a page reload. It used to leave lastError at its old
            // value, which made the one close that actually kills the channel the
            // only silent one on the screen (measured 2026-11-01, P22).
            ChannelCloseCause.CLIENT_CLOSED -> "channel closed by the page (client_closed)"
            ChannelCloseCause.SERVER_STOPPED -> null
        }
        mutableStatus.update { it.copy(connected = false, lastError = note ?: it.lastError) }
    }

    /** Records a caller-supplied, token-free diagnostic (e.g. `renderer gone`). */
    fun noteError(safeMessage: String) {
        logger.warn("channel: $safeMessage")
        mutableStatus.update { it.copy(lastError = safeMessage) }
    }

    /** `stop()`: the channel is gone and the handshake summary is cleared. */
    fun onEngineStopped() {
        synchronized(lock) { clearPendingLocked() }
        mutableStatus.update { it.copy(connected = false) }
    }

    // ------------------------------------------------------------- internals

    private fun decodeHello(payload: ByteArray, inbound: Boolean) {
        val json = try {
            decoder.decode(payload)
        } catch (failure: Throwable) {
            // Missing .so (WireUnavailable), protocol errors (WireException) and
            // anything else stay on the screen as a reason, never as a crash.
            val reason = when (failure) {
                is WireUnavailable -> "hello decode unavailable (libpdsh_jni not packaged)"
                is WireException -> "hello decode failed (${failure.code})"
                else -> "hello decode failed (${failure.javaClass.simpleName})"
            }
            noteError(reason)
            return
        }
        try {
            val fieldsProto = HelloFields.proto(json)
            val caps = HelloFields.caps(json)
            synchronized(lock) {
                if (fieldsProto != 0) proto = fieldsProto
                if (inbound) {
                    workerCapabilities = caps
                    if (receivedAtMillis == 0L) receivedAtMillis = clock()
                } else {
                    hostCapabilities = caps
                    nextMseq = HelloFields.nextMseq(json)
                    ackedMseq = HelloFields.ackedMseq(json)
                }
                publishLocked()
            }
        } catch (failure: Throwable) {
            noteError("hello fields unreadable (${failure.javaClass.simpleName})")
        }
    }

    private fun publishLocked() {
        val summary = HandshakeSummary(
            proto = proto,
            workerCapabilities = workerCapabilities,
            hostCapabilities = hostCapabilities,
            nextMseq = nextMseq,
            ackedMseq = ackedMseq,
            receivedAtMillis = receivedAtMillis,
        )
        mutableHandshake.value = summary
        mutableStatus.update { it.copy(lastError = null) }
        logger.info(
            "handshake: proto=${summary.proto}, workerCaps=${summary.workerCapabilities}, " +
                "hostCaps=${summary.hostCapabilities}, next_mseq=${summary.nextMseq}, " +
                "acked_mseq=${summary.ackedMseq}",
        )
    }

    private fun clearPendingLocked() {
        proto = 0
        workerCapabilities = emptyList()
        hostCapabilities = emptyList()
        nextMseq = 0L
        ackedMseq = 0L
        receivedAtMillis = 0L
        mutableHandshake.value = null
    }

    private fun typeByteOf(payload: ByteArray): Int =
        if (payload.size <= FrameType.TYPE_OFFSET) -1 else payload[FrameType.TYPE_OFFSET].toInt()

    private fun labelOf(typeByte: Int): String =
        if (typeByte < 0) FrameType.MALFORMED else FrameType.nameOf(typeByte)

    private companion object {
        val EMPTY = ChannelStatus(
            connected = false,
            framesFromWorker = 0,
            framesToWorker = 0,
            lastFrameType = null,
            lastError = null,
        )
    }
}
