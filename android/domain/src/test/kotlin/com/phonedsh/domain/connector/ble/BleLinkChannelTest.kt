// SPDX-License-Identifier: MIT
package com.phonedsh.domain.connector.ble

import com.phonedsh.domain.testing.MiniJson
import java.nio.file.Path
import org.junit.Assert.*
import org.junit.Test

class BleLinkChannelTest {
    private val generation = 77L
    private fun hello(tools: Boolean) = ByteArray(if (tools) 33 else 25).apply {
        this[1] = 2; this[2] = 1; this[19] = 42; this[24] = 2
        if (tools) { this[5] = 0x10; "PDSH".toByteArray(Charsets.US_ASCII).copyInto(this, 25); this[29] = 1; this[32] = 0x10 }
    }
    private fun packet(opcode: Int, id: Int, body: ByteArray = byteArrayOf()) =
        BleLinkCodec.Frame(opcode, id, body).segments(244).single()
    private fun name(effect: BleLinkChannel.Effect): String = when (effect) {
        is BleLinkChannel.Effect.Write -> "write"
        is BleLinkChannel.Effect.Ready -> if (effect.peer.supportsTools) "ready_tools" else "ready_legacy"
        is BleLinkChannel.Effect.Reject -> "reject"
        is BleLinkChannel.Effect.Complete -> "complete"
        is BleLinkChannel.Effect.Event -> "event"
        is BleLinkChannel.Effect.Unknown -> "unknown"
        is BleLinkChannel.Effect.Nak -> "nak"
        BleLinkChannel.Effect.Disconnect -> "disconnect"
    }

    @Test fun sharedTransitionScenariosDriveRealStateMachineAndCodec() {
        val path = Path.of(System.getProperty("pdsh.repo.root")).resolve("spec/device/v1/golden/android-link-channel.jsonl")
        val rows = path.toFile().readLines().filter(String::isNotBlank).map(MiniJson::parseObject)
        assertEquals(12, rows.size)
        for (row in rows) {
            val channel = BleLinkChannel(generation, 244)
            var write: BleLinkChannel.Effect.Write? = null
            var requestId = 0
            @Suppress("UNCHECKED_CAST")
            for (step in row.getValue("steps") as List<Map<String, Any?>>) {
                val input = step.getValue("in") as String
                val bytes = when (input) {
                    "hello_ack_tools" -> packet(0x81, 1, hello(true))
                    "hello_ack_legacy" -> packet(0x81, 1, hello(false))
                    "status_response" -> packet(0x82, requestId, byteArrayOf(9))
                    "wrong_id" -> packet(0x82, requestId + 1)
                    "wrong_opcode" -> packet(0x83, requestId)
                    "event" -> packet(0x6c, 0, byteArrayOf(7))
                    "nak" -> packet(0xff, requestId, byteArrayOf(14))
                    "hello_nak" -> packet(0xff, 1, byteArrayOf(14))
                    "bad_crc" -> packet(0x82, requestId).apply { this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte() }
                    else -> null
                }
                val effects = when (input) {
                    "open" -> channel.open(true, true)
                    "write_ok" -> channel.writeComplete(generation, write!!.token, true)
                    "stale_write_ok" -> channel.writeComplete(generation, write!!.token + 1, true)
                    "write_error" -> channel.writeComplete(generation, write!!.token, false)
                    "status" -> channel.request(2, byteArrayOf())
                    "tool" -> channel.request(0x54, byteArrayOf(1))
                    "timeout" -> channel.timeout(generation, requestId)
                    "cancel" -> channel.cancel(generation, requestId)
                    else -> channel.receive(generation, bytes ?: error("unknown input $input"))
                }
                for (effect in effects) if (effect is BleLinkChannel.Effect.Write) {
                    write = effect
                    val frame = BleLinkCodec.Reassembler().push(effect.bytes)!!
                    requestId = frame.requestId
                    if (input == "open") { assertEquals(1, frame.opcode); assertArrayEquals(BleLinkCodec.hello(), frame.body) }
                }
                @Suppress("UNCHECKED_CAST") val expected = step.getValue("out") as List<String>
                assertEquals("${row["name"]} / $input", expected, effects.map(::name))
            }
        }
    }

    private fun ready(channel: BleLinkChannel, writeLimit: Int = 244) {
        val write = channel.open(true, true).single() as BleLinkChannel.Effect.Write
        assertTrue(channel.writeComplete(generation, write.token, true).isEmpty())
        val segments = BleLinkCodec.Frame(0x81, 1, hello(true)).segments(writeLimit)
        assertTrue(segments.dropLast(1).flatMap { channel.receive(generation, it) }.isEmpty())
        assertTrue(channel.receive(generation, segments.last()).single() is BleLinkChannel.Effect.Ready)
    }

    @Test fun fragmentedWritesWaitForExactCallbacksAndEarlyResponse() {
        val channel = BleLinkChannel(generation, 20); ready(channel, 20)
        val payload = ByteArray(70) { it.toByte() }
        var write = channel.request(0x54, payload).single() as BleLinkChannel.Effect.Write
        val assembler = BleLinkCodec.Reassembler(); var count = 0
        while (true) {
            count++; assertTrue(write.bytes.size <= 20)
            val decoded = assembler.push(write.bytes)
            if (decoded != null) {
                assertEquals(2, decoded.requestId); assertArrayEquals(payload, decoded.body)
                assertTrue(channel.receive(generation, packet(0xd4, 2, byteArrayOf(4))).isEmpty())
                assertEquals(BleLinkChannel.Rejection.BUSY, (channel.request(2, byteArrayOf()).single() as BleLinkChannel.Effect.Reject).reason)
                val completed = channel.writeComplete(generation, write.token, true).single() as BleLinkChannel.Effect.Complete
                assertEquals(2, completed.requestId); assertArrayEquals(byteArrayOf(4), completed.body); break
            }
            val prior = write
            write = channel.writeComplete(generation, prior.token, true).single() as BleLinkChannel.Effect.Write
            assertNotEquals(prior.token, write.token)
            assertTrue(channel.writeComplete(generation, prior.token, true).isEmpty())
            assertTrue(channel.writeComplete(generation - 1, write.token, false).isEmpty())
        }
        assertTrue(count > 1)
    }

    @Test fun disconnectClearsStateAndOldCallbacksCannotAdvanceNewGeneration() {
        val first = BleLinkChannel(generation, 20); ready(first, 20)
        val old = first.request(2, byteArrayOf()).single() as BleLinkChannel.Effect.Write
        assertEquals(listOf("unknown", "disconnect"), first.disconnected(generation).map(::name))
        assertTrue(first.receive(generation, packet(0x82, 2)).isEmpty())
        assertTrue(first.writeComplete(generation, old.token, true).isEmpty())
        val next = BleLinkChannel(generation + 1, 20)
        val firstWrite = next.open(true, true).single() as BleLinkChannel.Effect.Write
        assertTrue(next.writeComplete(generation, firstWrite.token, true).isEmpty())
        assertTrue(next.receive(generation, packet(0x81, 1, hello(true))).isEmpty())
        assertTrue(next.writeComplete(generation + 1, firstWrite.token, true).isEmpty())
        val segments = BleLinkCodec.Frame(0x81, 1, hello(true)).segments(20)
        assertTrue(segments.dropLast(1).flatMap { next.receive(generation + 1, it) }.isEmpty())
        assertTrue(next.receive(generation + 1, segments.last()).single() is BleLinkChannel.Effect.Ready)
    }

    @Test fun exhaustionNeverReusesRequestIdOrWrites() {
        val channel = BleLinkChannel(generation, 244); ready(channel)
        for (id in 2..65535) {
            val write = channel.request(2, byteArrayOf()).single() as BleLinkChannel.Effect.Write
            assertEquals(id, BleLinkCodec.Reassembler().push(write.bytes)!!.requestId)
            assertTrue(channel.writeComplete(generation, write.token, true).isEmpty())
            assertTrue(channel.receive(generation, packet(0x82, id)).single() is BleLinkChannel.Effect.Complete)
        }
        assertEquals(BleLinkChannel.Rejection.EXHAUSTED, (channel.request(2, byteArrayOf()).single() as BleLinkChannel.Effect.Reject).reason)
    }

    @Test fun scopedTimeoutAndCancellationDoNotKillLaterExchange() {
        val channel = BleLinkChannel(generation, 244); ready(channel)
        val first = channel.request(2, byteArrayOf()).single() as BleLinkChannel.Effect.Write
        channel.writeComplete(generation, first.token, true); channel.receive(generation, packet(0x82, 2))
        val second = channel.request(2, byteArrayOf()).single() as BleLinkChannel.Effect.Write
        assertTrue(channel.timeout(generation, 2).isEmpty()); assertTrue(channel.cancel(generation - 1, 3).isEmpty())
        assertEquals(listOf("unknown", "disconnect"), channel.cancel(generation, 3).map(::name))
        assertTrue(channel.writeComplete(generation, second.token, true).isEmpty())
    }

    @Test fun subscriptionsAndInvalidHelloFailClosed() {
        val channel = BleLinkChannel(generation, 244)
        assertEquals(BleLinkChannel.Rejection.NOT_READY, (channel.open(true, false).single() as BleLinkChannel.Effect.Reject).reason)
        val write = channel.open(true, true).single() as BleLinkChannel.Effect.Write
        channel.writeComplete(generation, write.token, true)
        assertEquals(listOf("unknown", "disconnect"), channel.receive(generation, packet(0x81, 1, byteArrayOf(0))).map(::name))
        assertEquals(BleLinkChannel.Rejection.NOT_READY, (channel.request(2, byteArrayOf()).single() as BleLinkChannel.Effect.Reject).reason)
    }

    @Test fun earlyNakWaitsForWriteAndWriteFailureOverridesIt() {
        val channel = BleLinkChannel(generation, 244); ready(channel)
        val write = channel.request(2, byteArrayOf()).single() as BleLinkChannel.Effect.Write
        assertTrue(channel.receive(generation, packet(0xff, 2, byteArrayOf(14))).isEmpty())
        assertEquals(listOf("unknown", "disconnect"), channel.writeComplete(generation, write.token, false).map(::name))
    }

    @Test fun allExtensionOpcodesAreRejectedForLegacyPeer() {
        val channel = BleLinkChannel(generation, 244)
        val write = channel.open(true, true).single() as BleLinkChannel.Effect.Write
        channel.writeComplete(generation, write.token, true)
        assertFalse((channel.receive(generation, packet(0x81, 1, hello(false))).single() as BleLinkChannel.Effect.Ready).peer.supportsTools)
        for (opcode in 0x54..0x56) {
            assertEquals(BleLinkChannel.Rejection.TOOLS_UNSUPPORTED, (channel.request(opcode, byteArrayOf()).single() as BleLinkChannel.Effect.Reject).reason)
        }
    }

    @Test fun legacyHelloDoesNotDeliverUnnegotiatedToolEvents() {
        val channel = BleLinkChannel(generation, 244)
        val helloWrite = channel.open(true, true).single() as BleLinkChannel.Effect.Write
        channel.writeComplete(generation, helloWrite.token, true)
        assertFalse((channel.receive(generation, packet(0x81, 1, hello(false))).single() as BleLinkChannel.Effect.Ready).peer.supportsTools)
        val request = channel.request(2, byteArrayOf()).single() as BleLinkChannel.Effect.Write
        channel.writeComplete(generation, request.token, true)
        assertTrue(channel.receive(generation, packet(0x6c, 0, byteArrayOf(7))).isEmpty())
        assertTrue(channel.receive(generation, packet(0x82, 2)).single() is BleLinkChannel.Effect.Complete)
    }

    @Test fun prematureMatchingResponseOrNakFailsClosedBeforeFinalWrite() {
        for (opcode in listOf(0xd4, 0xff)) {
            val channel = BleLinkChannel(generation, 20); ready(channel, 20)
            val first = channel.request(0x54, ByteArray(70)).single() as BleLinkChannel.Effect.Write
            assertTrue(channel.receive(generation, packet(opcode, 3)).isEmpty())
            val second = channel.writeComplete(generation, first.token, true).single() as BleLinkChannel.Effect.Write
            assertEquals(listOf("unknown", "disconnect"), channel.receive(generation, packet(opcode, 2)).map(::name))
            assertTrue(channel.writeComplete(generation, second.token, true).isEmpty())
            assertEquals(BleLinkChannel.Rejection.NOT_READY, (channel.request(2, byteArrayOf()).single() as BleLinkChannel.Effect.Reject).reason)
        }
    }

    @Test fun ordinaryNakCompletesExchangeAndChannelStaysReady() {
        val channel = BleLinkChannel(generation, 244); ready(channel)
        val first = channel.request(2, byteArrayOf()).single() as BleLinkChannel.Effect.Write
        channel.writeComplete(generation, first.token, true)
        val nak = channel.receive(generation, packet(0xff, 2, byteArrayOf(14))).single() as BleLinkChannel.Effect.Nak
        assertEquals(2, nak.requestId); assertArrayEquals(byteArrayOf(14), nak.body)
        assertTrue(channel.request(2, byteArrayOf()).single() is BleLinkChannel.Effect.Write)
    }

    @Test fun helloNakClosesAndCannotReopen() {
        val channel = BleLinkChannel(generation, 244)
        val first = channel.open(true, true).single() as BleLinkChannel.Effect.Write
        assertTrue(channel.receive(generation, packet(0xff, 1, byteArrayOf(14))).isEmpty())
        assertEquals(listOf("nak", "disconnect"), channel.writeComplete(generation, first.token, true).map(::name))
        assertEquals(BleLinkChannel.Rejection.NOT_READY, (channel.open(true, true).single() as BleLinkChannel.Effect.Reject).reason)
        assertTrue(channel.receive(generation, packet(0x81, 1, hello(true))).isEmpty())
    }
}
