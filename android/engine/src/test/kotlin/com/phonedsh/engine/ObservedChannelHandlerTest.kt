// phone-dsh — :engine / com.phonedsh.engine: the one-channel invariant, JVM-only.
// SPDX-License-Identifier: MIT
//
// Proves the pass-through property the plan promises: the payload the origin read
// is the SAME ByteArray instance the codec receives (no copy, no re-framing), the
// codec sends through a wrapper that counts outbound frames, and a second
// connection never reaches the codec. WebSocket transport itself is :net's
// conformance suite; WebViewEngine only wires this decorator in.

package com.phonedsh.engine

import com.phonedsh.loopback.ChannelCloseCause
import com.phonedsh.loopback.LoopbackChannelHandler
import com.phonedsh.loopback.LoopbackConnection
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

class ObservedChannelHandlerTest {
    private val logger = RecordingEngineLogger()
    private val telemetry = ChannelTelemetry(decoder = { error("the codec is not under test here") }, logger = logger)
    private val delegate = RecordingChannelHandler()
    private val observed = ObservedChannelHandler(delegate, telemetry, logger)

    @Test
    fun forwardsTheSamePayloadInstanceWithoutCopying() = runBlocking {
        val connection = FakeConnection("channel-1")
        val payload = frame(0x10)

        observed.onOpen(connection)
        observed.onBinary(connection, payload)

        assertSame(payload, delegate.lastPayload)
        assertEquals(listOf("open:channel-1", "binary:${payload.size}"), delegate.events)
        assertEquals(1L, telemetry.status.value.framesFromWorker)
        assertEquals(1, observed.liveChannels)
        assertEquals(1L, observed.channelsOpened)
        assertTrue(telemetry.status.value.connected)
    }

    @Test
    fun countsFramesTheCodecSendsThroughTheHandedOutConnection() = runBlocking {
        val connection = FakeConnection("channel-1")
        observed.onOpen(connection)
        val handedOut = delegate.openedConnection ?: error("the codec received no connection")
        // The codec never sees the origin's own connection object.
        assertNotSame(connection, handedOut)

        handedOut.sendBinary(frame(0x11))
        handedOut.sendBinary(frame(0x13))

        assertEquals(2L, telemetry.status.value.framesToWorker)
        assertEquals("VFS_RESYNC", telemetry.status.value.lastFrameType)
        assertEquals(2, connection.sent.size)
    }

    @Test
    fun forwardsTheCloseCauseExactlyOnce() = runBlocking {
        val connection = FakeConnection("channel-1")
        observed.onOpen(connection)
        observed.onClosed(connection, ChannelCloseCause.CLIENT_CLOSED)

        assertEquals(listOf("open:channel-1", "closed:channel-1:CLIENT_CLOSED"), delegate.events)
        assertEquals(0, observed.liveChannels)
        assertFalse(telemetry.status.value.connected)
        assertTrue(logger.contains("channel channel-1: closed cause=CLIENT_CLOSED (live=0)"))
    }

    /**
     * P22: the decorator is the engine's only seam for "the ordered channel is
     * gone", so it must report exactly one open and one close per live connection,
     * and never for the duplicate-channel path the engine refused itself.
     */
    @Test
    fun reportsTheOpenAndTheCloseOfALiveConnectionExactlyOnce() = runBlocking {
        val lost = CopyOnWriteArrayList<ChannelCloseCause>()
        var opened = 0
        val handler = ObservedChannelHandler(
            delegate = delegate,
            telemetry = telemetry,
            logger = logger,
            onChannelLost = { cause -> lost += cause },
            onChannelOpened = { opened += 1 },
        )
        val first = FakeConnection("channel-1")
        val refused = FakeConnection("channel-2")

        handler.onOpen(first)
        // A second live connection is refused by the slot: the engine never saw it
        // open, so neither its open nor its close may be reported as a channel.
        handler.onOpen(refused)
        assertEquals("a refused duplicate is not a new channel", 1, opened)

        handler.onClosed(first, ChannelCloseCause.CLIENT_CLOSED)
        assertEquals(1, opened)
        assertEquals(listOf(ChannelCloseCause.CLIENT_CLOSED), lost)

        handler.onClosed(refused, ChannelCloseCause.CLIENT_CLOSED)
        assertEquals("a close the engine never saw open is not a lost channel", 1, lost.size)
    }

    @Test
    fun aSecondLiveChannelIsClosedAndNeverReachesTheCodec() = runBlocking {
        val first = FakeConnection("channel-1")
        val second = FakeConnection("channel-2")
        observed.onOpen(first)
        observed.onOpen(second)

        assertEquals(listOf("open:channel-1"), delegate.events)
        assertEquals(ObservedChannelHandler.SECOND_CHANNEL_CLOSE_CODE, second.closed?.first)
        assertEquals(1, observed.liveChannels)
        assertTrue(logger.contains("a second live channel reached the engine"))

        // Once the first closes, a new connection is accepted again (page reload
        // after a renderer rebuild reopens the channel).
        observed.onClosed(first, ChannelCloseCause.TRANSPORT_LOST)
        assertEquals(0, observed.liveChannels)
        observed.onOpen(FakeConnection("channel-3"))
        assertEquals("open:channel-3", delegate.events.last())
    }

    @Test
    fun aCloseWithoutAForwardedOpenIsIgnored() = runBlocking {
        observed.onClosed(FakeConnection("ghost"), ChannelCloseCause.TRANSPORT_LOST)

        assertTrue(delegate.events.isEmpty())
        assertTrue(logger.contains("closed without a forwarded open"))
    }

    /** A `channel.md` §1 frame: magic, type byte, 16-byte header. */
    private fun frame(type: Int): ByteArray {
        val header = ByteArray(16)
        header[0] = 0x5A
        header[1] = 0x4C
        header[2] = type.toByte()
        header[15] = 1
        return header + byteArrayOf(0)
    }
}

private class FakeConnection(override val id: String) : LoopbackConnection {
    val sent = CopyOnWriteArrayList<ByteArray>()
    var closed: Pair<Short, String>? = null

    override suspend fun sendBinary(payload: ByteArray) {
        sent += payload
    }

    override suspend fun close(code: Short, reason: String) {
        closed = code to reason
    }
}

private class RecordingChannelHandler : LoopbackChannelHandler {
    val events = CopyOnWriteArrayList<String>()
    var lastPayload: ByteArray? = null
        private set
    var openedConnection: LoopbackConnection? = null
        private set

    override suspend fun onOpen(connection: LoopbackConnection) {
        openedConnection = connection
        events += "open:${connection.id}"
    }

    override suspend fun onBinary(connection: LoopbackConnection, payload: ByteArray) {
        lastPayload = payload
        events += "binary:${payload.size}"
    }

    override suspend fun onClosed(connection: LoopbackConnection, cause: ChannelCloseCause) {
        events += "closed:${connection.id}:$cause"
    }
}
