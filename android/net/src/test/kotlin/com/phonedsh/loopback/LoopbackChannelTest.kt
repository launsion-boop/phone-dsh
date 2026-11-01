// phone-dsh — :loopback tests: the one ordered binary channel.
// SPDX-License-Identifier: MIT
//
// What is asserted here is the transport contract only (channel.md §7 and the
// 16-byte header of §1): whole binary payloads in wire order, untouched bytes,
// backpressure in both directions, one clean observation of the peer's close,
// and nothing else reaching the handler.

package com.phonedsh.loopback

import io.ktor.client.plugins.websocket.DefaultClientWebSocketSession
import io.ktor.client.request.header
import io.ktor.client.plugins.websocket.webSocket
import io.ktor.http.HttpHeaders
import io.ktor.websocket.CloseReason
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.send
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.nio.file.Path
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

class LoopbackChannelTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var assets: Path

    @Before
    fun setUp() {
        assets = Fixtures.write(Path.of(temporary.newFolder("assets").absolutePath))
    }

    @Test
    fun binaryPayloadsArriveInWireOrderAndUnchanged() = runBlocking {
        val handler = RecordingHandler()
        LoopbackServer(handler = handler).use { server ->
            val endpoint = server.start(assets)
            val frames = listOf(
                channelFrame(0x01, 1, """{"proto":1,"role":"worker"}""".toByteArray()),
                channelFrame(0x10, 2, ByteArray(512) { index -> index.toByte() }),
                channelFrame(0x7F, 3, byteArrayOf(0x00, 0xFF.toByte(), 0x7F)),
            )
            newClient().use { http ->
                http.withChannel(endpoint) {
                    for (frame in frames) send(Frame.Binary(true, frame))
                    awaitUntil(5_000, "all ${frames.size} frames") { handler.payloads.size == frames.size }
                }
            }
            assertEquals(frames.size, handler.payloads.size)
            frames.forEachIndexed { index, frame ->
                assertArrayEquals("frame $index must be byte-identical", frame, handler.payloads[index])
            }
            awaitTrue(5_000, "the peer close") { handler.closed.size == 1 }
            assertEquals(1, handler.opened.get())
            assertEquals(ChannelCloseCause.CLIENT_CLOSED, handler.closed.single())
            assertEquals(3L, server.metrics().framesIn)
            assertEquals(
                frames.sumOf { it.size.toLong() },
                server.metrics().bytesIn,
            )
        }
    }

    @Test
    fun theHostDirectionIsTheSameChannel() = runBlocking {
        val helloAck = channelFrame(0x11, 1, byteArrayOf(9, 8, 7, 6))
        val handler = object : LoopbackChannelHandler {
            override suspend fun onOpen(connection: LoopbackConnection) {
                connection.sendBinary(helloAck)
            }

            override suspend fun onBinary(connection: LoopbackConnection, payload: ByteArray) {
                connection.sendBinary(channelFrame(0x11, 2, byteArrayOf(payload.size.toByte())))
            }
        }
        LoopbackServer(handler = handler).use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                http.withChannel(endpoint) {
                    assertArrayEquals("host → worker passes through untouched", helloAck, awaitBinary())
                    // The handler sees the WHOLE channel frame, header included:
                    // 16 bytes + "seven!!" = 23, which proves there is no
                    // application-level decoding in this package.
                    send(Frame.Binary(true, channelFrame(0x10, 1, "seven!!".toByteArray())))
                    assertArrayEquals(channelFrame(0x11, 2, byteArrayOf(23)), awaitBinary())
                }
            }
        }
    }

    @Test
    fun aSlowConsumerStopsTheReaderInsteadOfBuffering() = runBlocking {
        val gate = CompletableDeferred<Unit>()
        val delivered = AtomicInteger()
        val handler = object : LoopbackChannelHandler {
            override suspend fun onBinary(connection: LoopbackConnection, payload: ByteArray) {
                if (delivered.incrementAndGet() == 1) gate.await()
            }
        }
        LoopbackServer(handler = handler).use { server ->
            val endpoint = server.start(assets)
            val finish = CompletableDeferred<Unit>()
            newClient().use { http ->
                val sender = launch(Dispatchers.IO) {
                    http.withChannel(endpoint) {
                        val payload = ByteArray(4096) { 0x5A }
                        repeat(200) { send(Frame.Binary(true, payload)) }
                        finish.await()
                    }
                }
                awaitTrue(10_000, "the first frame") { delivered.get() >= 1 }
                Thread.sleep(500)
                assertEquals(
                    "the reader must not run ahead of the blocked handler",
                    1,
                    delivered.get(),
                )
                assertEquals("no payload is queued anywhere", 1, server.metrics().maxInFlightFrames)
                gate.complete(Unit)
                awaitTrue(20_000, "all 200 frames") { delivered.get() == 200 }
                assertEquals(1, server.metrics().maxInFlightFrames)
                assertEquals(200L, server.metrics().framesIn)
                finish.complete(Unit)
                sender.join()
            }
        }
    }

    @Test
    fun outboundSendsSuspendWhenThePeerStopsReading() {
        val chunkSize = 256 * 1024
        val frameCount = 64 // 16 MiB in total
        val acceptedBytes = 8L * 1024 * 1024 // what a stalled sender may hold
        val completed = AtomicInteger()
        val maxSendMillis = AtomicLong()
        val handler = object : LoopbackChannelHandler {
            override suspend fun onOpen(connection: LoopbackConnection) {
                val chunk = ByteArray(chunkSize) { index -> (index % 251).toByte() }
                repeat(frameCount) {
                    val started = System.nanoTime()
                    connection.sendBinary(chunk)
                    val elapsedMillis = (System.nanoTime() - started) / 1_000_000
                    if (elapsedMillis > maxSendMillis.get()) maxSendMillis.set(elapsedMillis)
                    completed.incrementAndGet()
                }
            }
        }
        LoopbackServer(handler = handler).use { server ->
            val endpoint = server.start(assets)
            RawWebSocketClient.connect(endpoint.port, LoopbackConfiguration.CHANNEL_PATH, endpoint.token).use { raw ->
                // The peer reads nothing: the origin must stop at the wire, not
                // accumulate the whole payload in the heap.
                Thread.sleep(1_500)
                val stalled = completed.get()
                assertTrue(
                    "a peer that does not read may not absorb ${stalled * chunkSize / 1024 / 1024} MiB; " +
                        "the origin is buffering instead of applying backpressure",
                    stalled.toLong() * chunkSize < acceptedBytes,
                )
                // Drain the wire: the sender resumes, finishes, and the bytes
                // arrive unchanged and in order.
                var bytes = 0L
                var frames = 0
                while (frames < frameCount) {
                    val payload = raw.readBinaryFrame()
                    assertEquals(chunkSize, payload.size)
                    // The pattern is index % 251, so this also proves the bytes
                    // are not re-chunked or shifted by the origin.
                    assertEquals(0, payload[0].toInt() and 0xFF)
                    assertEquals(1, payload[1].toInt() and 0xFF)
                    assertEquals(250, payload[250].toInt() and 0xFF)
                    assertEquals(0, payload[251].toInt() and 0xFF)
                    bytes += payload.size.toLong()
                    frames++
                }
                awaitTrue(10_000, "the sender to finish") { completed.get() == frameCount }
                assertEquals(frameCount.toLong() * chunkSize, bytes)
                assertTrue(
                    "a send must have waited for the wire (longest ${maxSendMillis.get()}ms)",
                    maxSendMillis.get() > 300,
                )
                assertEquals(frameCount.toLong(), server.metrics().framesOut)
            }
        }
    }

    @Test
    fun aPeerCloseIsObservedExactlyOnceAndTheOriginKeepsServing() = runBlocking {
        val handler = RecordingHandler()
        LoopbackServer(handler = handler).use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                http.withChannel(endpoint) {
                    (1..3).forEach { index ->
                        send(Frame.Binary(true, channelFrame(0x10, index.toLong(), byteArrayOf(index.toByte()))))
                    }
                    awaitUntil(5_000, "three frames") { handler.payloads.size == 3 }
                    close(CloseReason(CloseReason.Codes.NORMAL, "worker done"))
                    val reason = withTimeout(5_000) { closeReason.await() }
                        ?: throw AssertionError("the channel must report a close reason")
                    assertEquals(1000, reason.code.toInt())
                }
                awaitTrue(5_000, "the server to notice the close") { handler.closed.size == 1 }
                assertEquals(ChannelCloseCause.CLIENT_CLOSED, handler.closed.single())
                awaitTrue(5_000, "the channel to leave the active set") { server.metrics().activeChannels == 0 }
                assertEquals(1L, server.metrics().channelsAccepted)
                // The half-close ended one channel, not the origin.
                assertEquals(200, http.getAsset(endpoint, "/manifest.json").status.value)
                http.withChannel(endpoint) {
                    send(Frame.Binary(true, channelFrame(0x10, 4, byteArrayOf(9))))
                    awaitUntil(5_000, "a frame on the new channel") { handler.payloads.size == 4 }
                }
                awaitTrue(5_000, "the second close") { handler.closed.size == 2 }
                assertEquals(2, handler.opened.get())
                assertEquals(2L, server.metrics().channelsAccepted)
            }
        }
    }

    @Test
    fun textFramesAreRefused() = runBlocking {
        val handler = RecordingHandler()
        LoopbackServer(handler = handler).use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                http.withChannel(endpoint) {
                    send(Frame.Text("not a channel frame"))
                    val reason = withTimeoutOrNull(5_000) { closeReason.await() }
                        ?: throw AssertionError("a text frame must end the channel")
                    assertEquals(1003, reason.code.toInt())
                }
            }
            awaitTrue(5_000, "the close") { handler.closed.size == 1 }
            assertEquals(ChannelCloseCause.UNSUPPORTED_FRAME, handler.closed.single())
            assertTrue("no text frame may reach the handler", handler.payloads.isEmpty())
        }
    }

    @Test
    fun aFailingHandlerClosesTheChannelButNotTheOrigin() = runBlocking {
        val closed = java.util.concurrent.CopyOnWriteArrayList<ChannelCloseCause>()
        val handler = object : LoopbackChannelHandler {
            override suspend fun onBinary(connection: LoopbackConnection, payload: ByteArray) {
                throw IllegalStateException("the codec exploded")
            }

            override suspend fun onClosed(connection: LoopbackConnection, cause: ChannelCloseCause) {
                closed.add(cause)
            }
        }
        LoopbackServer(handler = handler).use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                http.withChannel(endpoint) {
                    send(Frame.Binary(true, channelFrame(0x10, 1, byteArrayOf(1))))
                    val reason = withTimeoutOrNull(5_000) { closeReason.await() }
                        ?: throw AssertionError("a failing handler must end the channel")
                    assertEquals(1011, reason.code.toInt())
                }
                awaitTrue(5_000, "the close") { closed.size == 1 }
                assertEquals(ChannelCloseCause.HANDLER_FAILED, closed.single())
                // One channel died; the origin did not.
                assertEquals(200, http.getAsset(endpoint, "/manifest.json").status.value)
                awaitTrue(5_000, "the slot to free up") { server.metrics().activeChannels == 0 }
            }
        }
    }

    @Test
    fun aPayloadAboveTheConfiguredCapClosesTheChannel() = runBlocking {
        val handler = RecordingHandler()
        LoopbackServer(LoopbackConfiguration(maxChannelFrameBytes = 4096), handler).use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                http.withChannel(endpoint) {
                    send(Frame.Binary(true, ByteArray(8192)))
                    val reason = withTimeoutOrNull(5_000) { closeReason.await() }
                        ?: throw AssertionError("an oversized payload must end the channel")
                    assertTrue(
                        "close code ${reason.code}",
                        reason.code.toInt() == 1009 || reason.code.toInt() == 1006,
                    )
                }
            }
            awaitTrue(5_000, "the close") { handler.closed.size == 1 }
            assertTrue("an oversized payload must not reach the handler", handler.payloads.isEmpty())
            assertEquals(0L, server.metrics().framesIn)
        }
    }

    @Test
    fun aSecondChannelIsRefusedWhileOneIsOpen() = runBlocking {
        val handler = RecordingHandler()
        LoopbackServer(handler = handler).use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                http.withChannel(endpoint) {
                    val refused = rawRequest(endpoint.port, "GET", "/channel", upgradeHeaders(endpoint.token))
                    assertEquals(409, refused.status)
                    assertTrue(refused.bodyText.contains("channel_in_use"))
                    // The incumbent channel is untouched by the refusal.
                    send(Frame.Binary(true, channelFrame(0x10, 1, byteArrayOf(1))))
                    awaitUntil(5_000, "the incumbent frame") { handler.payloads.size == 1 }
                }
            }
            awaitTrue(5_000, "the rejection counter") { server.metrics().channelsRejected == 1L }
            assertEquals(1L, server.metrics().channelsAccepted)
            assertEquals(1, handler.opened.get())
        }
    }

    @Test
    fun aConcurrentUpgradeRaceAcceptsExactlyOneChannel() = runBlocking {
        val handler = RecordingHandler()
        LoopbackServer(handler = handler).use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                val start = CompletableDeferred<Unit>()
                val attempts = (1..2).map {
                    async(Dispatchers.IO) {
                        start.await()
                        runCatching {
                            http.webSocket(
                                urlString = endpoint.channelUrl(),
                                request = { header(HttpHeaders.Authorization, "Bearer ${endpoint.token}") },
                            ) {
                                delay(1_500)
                            }
                        }
                    }
                }
                start.complete(Unit)
                awaitTrue(5_000, "both attempts to settle") {
                    server.metrics().channelsAccepted + server.metrics().channelsRejected == 2L
                }
                assertEquals("one channel at a time", 1L, server.metrics().channelsAccepted)
                assertEquals(1L, server.metrics().channelsRejected)
                assertEquals(1, handler.opened.get())
                attempts.forEach { it.await() }
            }
        }
    }
}

/** The next binary payload of a client channel, skipping control frames. */
private suspend fun DefaultClientWebSocketSession.awaitBinary(): ByteArray {
    while (true) {
        val frame = incoming.receive()
        if (frame is Frame.Binary) return frame.data
    }
}
