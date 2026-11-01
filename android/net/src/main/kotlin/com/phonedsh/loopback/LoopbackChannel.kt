// phone-dsh — :loopback / com.phonedsh.loopback: the frame-transparent channel seam.
// SPDX-License-Identifier: MIT
//
// spec/v1/channel.md §1 fixes one binary WebSocket that carries ordered frames.
// This package is deliberately BELOW that contract: it moves whole binary
// payloads in order, applies transport backpressure and reports the transport
// ending, but it never looks inside a payload. The 16-byte header, magic, seq,
// mseq, flag and direction checks are :core's job (:core/wire), per the A1
// decision that there is exactly one codec implementation.

package com.phonedsh.loopback

/** One live WebSocket connection, seen by a [LoopbackChannelHandler]. */
interface LoopbackConnection {
    /** Stable per-connection label (`channel-1`, `channel-2`, ...). Never a secret. */
    val id: String

    /**
     * Send one whole binary payload to the peer.
     *
     * Suspends while the transport is full: this never buffers without bound,
     * so a slow peer slows the producer down instead of growing the heap.
     */
    suspend fun sendBinary(payload: ByteArray)

    /** Close the channel. `code` is an RFC 6455 close code (1000 by default). */
    suspend fun close(code: Short = 1000, reason: String = "")
}

/** Why a channel ended, delivered exactly once through [LoopbackChannelHandler.onClosed]. */
enum class ChannelCloseCause {
    /** The peer finished with a close frame (normal half-close of the stream). */
    CLIENT_CLOSED,

    /** The origin is stopping; the connection did not fail. */
    SERVER_STOPPED,

    /** The transport died without a close frame (socket error, process death). */
    TRANSPORT_LOST,

    /** The peer sent a text frame; the channel is binary-only (channel.md §1). */
    UNSUPPORTED_FRAME,

    /** A payload exceeded `maxChannelFrameBytes`; the session closed with 1009. */
    FRAME_TOO_LARGE,

    /** The handler itself threw; the session closed with 1011. */
    HANDLER_FAILED,
}

/**
 * The consumer of the one ordered channel.
 *
 * Calls are strictly sequential on one connection: [onBinary] is never entered
 * again before the previous call returned, so the payload order is the wire
 * order and a slow handler applies backpressure all the way to the peer. Each
 * connection gets [onOpen] first and exactly one [onClosed] last.
 */
interface LoopbackChannelHandler {
    /** A channel was accepted. The token was already verified before this call. */
    suspend fun onOpen(connection: LoopbackConnection) {}

    /** One whole binary payload, unchanged and in order. */
    suspend fun onBinary(connection: LoopbackConnection, payload: ByteArray) {}

    /** The connection ended; [cause] says how. Called once, even on cancellation. */
    suspend fun onClosed(connection: LoopbackConnection, cause: ChannelCloseCause) {}

    companion object {
        /**
         * Default handler: accepts the channel and closes it at once with 1011.
         *
         * A server started without a consumer must fail loud rather than drop
         * frames silently; `:engine` always passes its codec handler.
         */
        val Unhandled: LoopbackChannelHandler = object : LoopbackChannelHandler {
            override suspend fun onOpen(connection: LoopbackConnection) {
                connection.close(1011, "no channel handler installed")
            }
        }
    }
}

/** Counters of one server instance, snapshot at call time. */
data class LoopbackMetrics(
    val activeChannels: Int = 0,
    val channelsAccepted: Long = 0,
    val channelsRejected: Long = 0,
    val framesIn: Long = 0,
    val framesOut: Long = 0,
    val bytesIn: Long = 0,
    val bytesOut: Long = 0,
    /**
     * Largest number of frames that were ever inside [LoopbackChannelHandler.onBinary]
     * at the same time. The applier is sequential, so this is 0 or 1.
     */
    val maxInFlightFrames: Int = 0,
    val unauthorizedRequests: Long = 0,
    /**
     * Uncaught failures the engine's own coroutine scope reported for this start.
     *
     * Zero while the origin is healthy. A non-zero value after `start()` returned
     * means the engine's accept loop died unexpectedly: the origin may no longer
     * be accepting, and [LoopbackServer.lastFailure] carries the cause. The
     * failure is recorded, never thrown, so the process keeps running.
     */
    val engineFailures: Long = 0,
) {
    companion object {
        val Idle: LoopbackMetrics = LoopbackMetrics()
    }
}
