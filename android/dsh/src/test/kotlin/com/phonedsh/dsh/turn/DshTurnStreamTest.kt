// The `session/follow` NDJSON reader: byte-accurate lines and quiet-period behaviour.
// SPDX-License-Identifier: MIT
//
// Two defects this pins down, both measured against the real Worker framing:
//
//  1. `plugins/worker-entry/src/mux-bridge.ts` writes one line per 4 MiB chunk
//     boundary, which is not a character boundary. Decoding each chunk with
//     `String(bytes, UTF_8)` replaces a straddling multi-byte character and makes
//     the line unparsable, so the event is silently dropped. `NdjsonLineBuffer`
//     splits the raw bytes and decodes complete lines only.
//  2. `collectEvents` used to break when one `next()` call timed out (45 s), even
//     though the caller's turn budget was 180 s. A long tool run or a slow first
//     token therefore ended the turn early. A quiet period is now only a chance
//     for the loop to re-check its own deadline.

package com.phonedsh.dsh.turn

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.dsh.host.HostApiExchange
import com.phonedsh.dsh.host.HostApiStream
import com.phonedsh.dsh.host.HostChannel
import com.phonedsh.dsh.host.HostFence
import com.phonedsh.dsh.host.HostHello
import com.phonedsh.dsh.host.HostLog
import com.phonedsh.dsh.host.WalUplink
import com.phonedsh.hostevents.HostEventKind
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NdjsonLineBufferTest {
    @Test
    fun `a line split inside every multi-byte character decodes intact`() {
        val line = """{"text":"中文事件🙂"}"""
        val bytes = line.toByteArray(Charsets.UTF_8)
        for (split in 0..bytes.size) {
            val buffer = NdjsonLineBuffer(initialCapacity = 8)
            buffer.append(bytes.copyOfRange(0, split))
            buffer.append(bytes.copyOfRange(split, bytes.size))
            buffer.append("\n".toByteArray(Charsets.UTF_8))
            assertEquals("split at byte $split", line, buffer.nextLine())
            assertNull("split at byte $split has no second line", buffer.nextLine())
        }
    }

    @Test
    fun `several lines in one chunk and a trailing partial line stay ordered`() {
        val buffer = NdjsonLineBuffer(initialCapacity = 4)
        buffer.append("first\nsecond\npartial".toByteArray(Charsets.UTF_8))
        assertEquals("first", buffer.nextLine())
        assertEquals("second", buffer.nextLine())
        assertNull("the unterminated tail is not a line", buffer.nextLine())
        assertEquals("partial".toByteArray(Charsets.UTF_8).size, buffer.pendingBytes)

        buffer.append(" line\n".toByteArray(Charsets.UTF_8))
        assertEquals("partial line", buffer.nextLine())
        assertNull(buffer.nextLine())
        assertEquals(0, buffer.pendingBytes)
    }

    @Test
    fun `an empty line is returned as an empty string and skipped by the caller`() {
        val buffer = NdjsonLineBuffer()
        buffer.append("\n".toByteArray(Charsets.UTF_8))
        assertEquals("", buffer.nextLine())
        assertNull(buffer.nextLine())
    }
}

class DshTurnStreamTest {
    private fun hello(): HostHello = HostHello(
        bootId = "0123456789abcdef0123456789abcdef",
        sessionEpoch = 0L,
        fence = HostFence.LOCAL,
        wal = WalUplink.down("test: no WAL"),
    )

    private fun follow(exchange: HostApiExchange): DshTurnClient.FollowStream {
        val client = DshTurnClient(
            HostChannel(hello = ::hello, logger = HostLog.None),
            log = {},
        )
        val stream = HostApiStream(exchange.reqId, exchange) {}
        return client.FollowStream("0123456789abcdef0123456789abcdef", stream, {})
    }

    private fun turnStartLine(text: String = "中文事件"): ByteArray =
        (
            """{"type":"item","streamId":"follow","value":{"type":"event","event":""" +
                """{"type":"turn/start","seq":1,"data":{"turn":1},"text":"$text"}}}""" + "\n"
            ).toByteArray(Charsets.UTF_8)

    @Test
    fun `a UTF-8 character split across transport chunks still parses`() = runBlocking {
        val exchange = HostApiExchange(1)
        val follow = follow(exchange)
        val line = turnStartLine()
        val marker = "中文事件".toByteArray(Charsets.UTF_8)
        val markerStart = (0..line.size - marker.size).first { start ->
            line.copyOfRange(start, start + marker.size).contentEquals(marker)
        }
        // Split inside the first Chinese character: three bytes long, so +1 is a
        // continuation byte and per-chunk decoding would produce U+FFFD.
        val split = markerStart + 1
        assertTrue("split must land inside the multi-byte character", split > markerStart)

        exchange.body.trySend(line.copyOfRange(0, split))
        exchange.body.trySend(line.copyOfRange(split, line.size))
        exchange.finish()

        val item = follow.next(timeoutMillis = 2_000)
        assertNotNull("the split line must be delivered, not dropped", item)
        val event = ((item!!["value"] as JsonObject)["event"] as JsonObject)
        assertEquals("中文事件", (event["text"] as com.phonedsh.agentcore.JsonString).value)
    }

    @Test
    fun `a quiet period shorter than the turn timeout does not end collection`() = runBlocking {
        val exchange = HostApiExchange(1)
        val follow = follow(exchange)
        val collected = async(Dispatchers.Default) {
            follow.collectEvents(
                timeoutMillis = 5_000,
                nextTimeoutMillis = 40,
            ) { it.kind == HostEventKind.TURN_STARTED }
        }

        // Several quiet windows pass with no bytes at all. The old code returned
        // an empty list here because the first `next()` timeout broke the loop.
        delay(250)
        assertFalse("the turn must still be collecting", collected.isCompleted)

        exchange.body.trySend(turnStartLine())
        exchange.finish()
        val events = withTimeout(2_000) { collected.await() }
        assertEquals(1, events.size)
        assertEquals(HostEventKind.TURN_STARTED, events.single().kind)
    }

    @Test
    fun `a terminal end frame stops collection before the turn deadline`() = runBlocking {
        val exchange = HostApiExchange(1)
        val follow = follow(exchange)
        exchange.body.trySend("""{"type":"end","streamId":"follow"}""".toByteArray() + "\n".toByteArray())
        exchange.finish()

        val started = System.currentTimeMillis()
        val events = follow.collectEvents(timeoutMillis = 10_000, nextTimeoutMillis = 40) { false }
        assertTrue("the end frame must end collection", events.isEmpty())
        assertTrue(
            "collection must not wait for the full turn budget",
            System.currentTimeMillis() - started < 5_000,
        )
    }

    @Test
    fun `the overall deadline caps a longer per-read window`() = runBlocking {
        val exchange = HostApiExchange(1)
        val follow = follow(exchange)
        val started = System.currentTimeMillis()
        val events = withTimeout(2_000) {
            // A 10 s read window must not extend a 150 ms overall budget.
            follow.collectEvents(timeoutMillis = 150, nextTimeoutMillis = 10_000) { false }
        }
        val elapsed = System.currentTimeMillis() - started
        assertTrue("the quiet stream must end at the overall deadline", events.isEmpty())
        assertTrue("collection must stop near 150 ms, was ${elapsed} ms", elapsed < 1_500)
    }

    @Test
    fun `cancelling collection interrupts the outstanding read promptly`() = runBlocking {
        val exchange = HostApiExchange(1)
        val follow = follow(exchange)
        val job = launch(Dispatchers.Default) {
            follow.collectEvents(timeoutMillis = 10_000, nextTimeoutMillis = 5_000) { false }
        }
        delay(50)
        withTimeout(2_000) { job.cancelAndJoin() }
        assertTrue("the read loop must end cancelled", job.isCancelled)
    }

    @Test
    fun `follow close sends mux cleanup even when its owner is cancelled`() = runBlocking {
        val follow = follow(HostApiExchange(1))
        val closeStarted = CompletableDeferred<Unit>()
        val closeFinished = CompletableDeferred<Unit>()
        follow.apiClose = {
            closeStarted.complete(Unit)
            delay(1)
            closeFinished.complete(Unit)
        }

        val job = launch {
            try {
                awaitCancellation()
            } finally {
                follow.close()
            }
        }
        kotlinx.coroutines.yield()
        job.cancelAndJoin()

        assertTrue("the close callback must start during cancellation cleanup", closeStarted.isCompleted)
        assertTrue("NonCancellable cleanup must finish the mux-close request", closeFinished.isCompleted)
    }

    @Test
    fun `follow close bounds an api close callback that never completes`() = runBlocking {
        val follow = follow(HostApiExchange(1))
        val closeStarted = CompletableDeferred<Unit>()
        val neverFinishes = CompletableDeferred<Unit>()
        follow.apiClose = {
            closeStarted.complete(Unit)
            neverFinishes.await()
        }

        val startedAt = System.nanoTime()
        withTimeout(7_000) { follow.close() }
        val elapsedMillis = (System.nanoTime() - startedAt) / 1_000_000L
        assertTrue("the close callback was attempted", closeStarted.isCompleted)
        assertTrue("close should use its 5 second budget, not wait indefinitely: ${elapsedMillis}ms", elapsedMillis < 6_500)
    }
}
