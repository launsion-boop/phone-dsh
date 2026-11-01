// phone-dsh — :engine / com.phonedsh.engine: the one channel, as :engine sees it.
// SPDX-License-Identifier: MIT
//
// :engine is below the codec on purpose (A1: one Wire implementation, in Rust via
// JNI). The LoopbackChannelHandler given to WebViewEngine receives every binary
// payload unchanged: no copy, no header rewrite, no re-framing. This decorator
// only counts, labels and enforces the "exactly one live WebSocket" invariant on
// top of the origin's own single-channel slot. It also hands the codec a wrapped
// LoopbackConnection so frames the codec *sends* are counted for [ChannelStatus].

package com.phonedsh.engine

import com.phonedsh.loopback.ChannelCloseCause
import com.phonedsh.loopback.LoopbackChannelHandler
import com.phonedsh.loopback.LoopbackConnection
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Pass-through [LoopbackChannelHandler] that owns the single-channel slot.
 *
 * The origin already closes a second upgrade with 409 (or 1013 on the losing side
 * of a race). This class is the second belt: if a second connection is ever
 * handed over anyway, it is closed here and the delegate never sees it, so the
 * codec above cannot end up with two streams writing the same session.
 *
 * @param onChannelLost told exactly once per live connection, after the frame
 *   consumer has been told and the counters have been updated. It is the seam
 *   P22 added: the ordered channel dying has an owner ([ChannelReopenLane])
 *   instead of only a log line.
 * @param onChannelOpened told after a connection was accepted and handed to the
 *   codec; it ends a reopen episode (the page may have reconnected by itself).
 */
class ObservedChannelHandler(
    private val delegate: LoopbackChannelHandler,
    private val telemetry: ChannelTelemetry,
    private val logger: EngineLogger,
    private val onChannelLost: ((ChannelCloseCause) -> Unit)? = null,
    private val onChannelOpened: (() -> Unit)? = null,
) : LoopbackChannelHandler {
    private val live: MutableSet<LoopbackConnection> = ConcurrentHashMap.newKeySet()
    private val handedOut: MutableMap<LoopbackConnection, LoopbackConnection> = ConcurrentHashMap()
    private val slot = AtomicInteger()
    private val opened = AtomicLong()

    /** Connections accepted since construction; explicit reconnects add up. */
    val channelsOpened: Long get() = opened.get()

    /** Channels live right now; 0 or 1 by the invariant. */
    val liveChannels: Int get() = live.size

    override suspend fun onOpen(connection: LoopbackConnection) {
        if (!slot.compareAndSet(0, 1)) {
            logger.error(
                "channel ${connection.id}: a second live channel reached the engine; " +
                    "closing it (the App owns exactly one ordered WebSocket)",
            )
            runCatching {
                connection.close(SECOND_CHANNEL_CLOSE_CODE, SECOND_CHANNEL_REASON)
            }.onFailure {
                logger.warn("channel ${connection.id}: closing the duplicate failed: ${EngineLogText.reasonOf(it)}")
            }
            return
        }
        live.add(connection)
        opened.incrementAndGet()
        telemetry.onChannelOpen()
        // The codec sends through this wrapper so outbound frames are counted too.
        val wrapped = CountingConnection(connection, telemetry)
        handedOut[connection] = wrapped
        logger.info("channel ${connection.id}: open (live=1); frames are forwarded to the codec unchanged")
        delegate.onOpen(wrapped)
        // After the codec has the connection: the reopen lane's success criterion
        // is the channel being usable again, not the upgrade alone.
        onChannelOpened?.invoke()
    }

    override suspend fun onBinary(connection: LoopbackConnection, payload: ByteArray) {
        telemetry.onInbound(payload)
        // The same ByteArray instance the origin read: :engine never copies or
        // interprets a payload (the codec above decodes it).
        delegate.onBinary(handedOut[connection] ?: connection, payload)
    }

    override suspend fun onClosed(connection: LoopbackConnection, cause: ChannelCloseCause) {
        telemetry.onChannelClosed(cause)
        val wrapped = handedOut.remove(connection)
        if (!live.remove(connection)) {
            logger.warn("channel ${connection.id}: closed without a forwarded open; ignored")
            return
        }
        slot.set(0)
        logger.info("channel ${connection.id}: closed cause=$cause (live=0)")
        if (wrapped != null) delegate.onClosed(wrapped, cause)
        // Last, and once: the reopen lane reacts to the close the codec has
        // already seen, so nothing it does can race the frame consumer.
        onChannelLost?.invoke(cause)
    }

    companion object {
        /** RFC 6455 "try again later": the same code the origin uses for a busy channel. */
        const val SECOND_CHANNEL_CLOSE_CODE: Short = 1013
        internal const val SECOND_CHANNEL_REASON = "the App owns exactly one ordered WebSocket"
    }
}

/** Forwards to the origin's connection and counts what the codec sends. */
private class CountingConnection(
    private val delegate: LoopbackConnection,
    private val telemetry: ChannelTelemetry,
) : LoopbackConnection {
    override val id: String get() = delegate.id

    override suspend fun sendBinary(payload: ByteArray) {
        delegate.sendBinary(payload)
        // Counted only after the transport accepted it: a failed send is not a
        // frame on the wire. The same array is forwarded, never copied.
        telemetry.onOutbound(payload)
    }

    override suspend fun close(code: Short, reason: String) {
        delegate.close(code, reason)
    }
}
