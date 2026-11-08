// SPDX-License-Identifier: MIT
package com.phonedsh.domain.connector.ble

import com.phonedsh.domain.testing.MiniJson
import java.nio.file.Path
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class BleLinkCodecTest {
    private val golden = Path.of(
        System.getProperty("pdsh.repo.root")
            ?: error("pdsh.repo.root is not set; the :domain test task supplies it"),
    ).resolve("spec/device/v1/golden")

    private fun rows(name: String): List<Map<String, Any?>> =
        golden.resolve(name).toFile().readLines().filter { it.isNotBlank() }.map(MiniJson::parseObject)

    private fun hex(text: String): ByteArray {
        require(text.length % 2 == 0)
        return ByteArray(text.length / 2) { index -> text.substring(index * 2, index * 2 + 2).toInt(16).toByte() }
    }

    private inline fun rejects(block: () -> Unit) {
        try {
            block()
            fail("expected malformed Link input to be rejected")
        } catch (_: IllegalArgumentException) {
            // Expected rejection by the real codec.
        }
    }

    @Test
    fun allSharedValidFramesRoundTripAndReassemble() {
        val legacy = rows("xiaozhi-ctl.jsonl")
        val pdsh = rows("pdsh-link.jsonl")
        assertEquals(165, legacy.size)
        assertEquals(6, pdsh.size)
        for (row in legacy + pdsh) {
            val name = row["name"] as String
            val bytes = hex(row["hex"] as String)
            val frame = BleLinkCodec.decode(bytes)
            if (row.containsKey("op")) assertEquals(name, (row["op"] as Long).toInt(), frame.opcode)
            if (row.containsKey("req_id")) assertEquals(name, (row["req_id"] as Long).toInt(), frame.requestId)
            assertArrayEquals(name, bytes, frame.encode())
            // Exercise the ATT minimum, an intermediate size and the max budget.
            for (limit in listOf(20, 61, 244)) {
                val segments = frame.segments(limit)
                val assembler = BleLinkCodec.Reassembler()
                for ((index, segment) in segments.withIndex()) {
                    assertTrue("$name: invalid segment size", segment.size in 2..limit)
                    val result = assembler.push(segment)
                    if (index == segments.lastIndex) assertEquals(name, frame, result)
                    else assertNull(name, result)
                }
            }
        }
    }

    @Test
    fun allSharedInvalidFramesAreRejected() {
        val invalid = rows("invalid-ctl.jsonl")
        assertEquals(3, invalid.size)
        invalid.forEach { row -> rejects { BleLinkCodec.decode(hex(row["hex"] as String)) } }
    }

    @Test
    fun frameLimitsAndPayloadOwnership() {
        val body = ByteArray(505) { it.toByte() }
        val frame = BleLinkCodec.Frame(255, 65535, body)
        body[0] = 99
        val encoded = frame.encode()
        assertEquals(512, encoded.size)
        assertEquals(0, frame.body[0].toInt())
        val returned = frame.body
        returned[0] = 100
        assertArrayEquals(encoded, frame.encode())
        assertEquals(frame, BleLinkCodec.decode(encoded))
        rejects { BleLinkCodec.Frame(256, 1, byteArrayOf()) }
        rejects { BleLinkCodec.Frame(1, 65536, byteArrayOf()) }
        rejects { BleLinkCodec.Frame(1, 1, ByteArray(506)) }
        rejects { BleLinkCodec.decode(ByteArray(513)) }
        rejects { frame.segments(19) }
        assertTrue(frame.segments(Int.MAX_VALUE).all { it.size <= 244 })
    }

    @Test
    fun invalidSegmentsClearStateAndReconnectStartsFresh() {
        val frame = BleLinkCodec.Frame(0x54, 42, ByteArray(140) { it.toByte() })
        val chunks = frame.segments(20)
        val assembler = BleLinkCodec.Reassembler()
        rejects { assembler.push(byteArrayOf(1, 1)) } // orphan LAST
        rejects { assembler.push(byteArrayOf(2)) } // no fragment
        rejects { assembler.push(byteArrayOf(4, 1)) } // reserved bits
        rejects { assembler.push(ByteArray(245) { if (it == 0) 2 else 1 }) }

        assertNull(assembler.push(chunks[0]))
        assembler.reset() // disconnect/reconnect
        rejects { assembler.push(chunks[1]) }
        var finished: BleLinkCodec.Frame? = null
        chunks.forEach { finished = assembler.push(it) }
        assertEquals(frame, finished)

        // Both existing endpoints discard a partial message on a new FIRST.
        assertNull(assembler.push(chunks[0]))
        val replacement = BleLinkCodec.Frame(2, 3, byteArrayOf())
        assertEquals(replacement, assembler.push(replacement.segments(20).single()))
        rejects { assembler.push(chunks[1]) }

        val first = ByteArray(244) { if (it == 0) 2 else 1 }
        val continuation = ByteArray(244) { if (it == 0) 0 else 1 }
        assertNull(assembler.push(first))
        assertNull(assembler.push(continuation))
        rejects { assembler.push(ByteArray(28) { if (it == 0) 0 else 1 }) }
        assertEquals(replacement, assembler.push(replacement.segments(20).single()))
    }

    @Test
    fun detectableReorderingAndBadFinalFrameDoNotPoisonNextFrame() {
        val frame = BleLinkCodec.Frame(0x54, 7, ByteArray(140) { it.toByte() })
        val segments = frame.segments(20).toMutableList()
        val swap = segments[1]; segments[1] = segments[2]; segments[2] = swap
        val assembler = BleLinkCodec.Reassembler()
        segments.dropLast(1).forEach { assertNull(assembler.push(it)) }
        rejects { assembler.push(segments.last()) }
        val next = BleLinkCodec.Frame(2, 8, byteArrayOf())
        assertEquals(next, assembler.push(next.segments(20).single()))
        // An incomplete final frame must also reset before the next message.
        rejects { assembler.push(byteArrayOf(3, 0)) }
        assertEquals(next, assembler.push(next.segments(20).single()))
    }

    @Test
    fun helloNegotiatesToolsOnlyWithFullTagAndNeverRequestsTasks() {
        val pdshHello = rows("pdsh-link.jsonl").first { it["name"] == "hello_pdsh" }
        assertArrayEquals(BleLinkCodec.decode(hex(pdshHello["hex"] as String)).body, BleLinkCodec.hello())
        val ack = ByteArray(33)
        ack[1] = 2; ack[2] = 1 // version 0x0102
        ack[5] = 0x10 // dev_caps bit 20
        ack[19] = 0xef.toByte(); ack[20] = 0xcd.toByte(); ack[21] = 0xab.toByte(); ack[22] = 0x89.toByte()
        ack[24] = 2 // max_msg = 512
        "PDSH".toByteArray().copyInto(ack, 25)
        ack[29] = 1; ack[32] = 16 // extension=1, max_rpc=4096
        val peer = BleLinkCodec.decodeHelloAck(ack)
        assertEquals(0x0102, peer.version)
        assertEquals(1L shl 20, peer.capabilities)
        assertEquals(0x89abcdefL, peer.bootId)
        assertTrue(peer.supportsTools)
        assertFalse(BleLinkCodec.decodeHelloAck(ack.copyOf(25)).supportsTools)
        assertFalse(BleLinkCodec.decodeHelloAck(ack.copyOf(32)).supportsTools)
        val noCap = ack.copyOf(); noCap[5] = 0
        assertFalse(BleLinkCodec.decodeHelloAck(noCap).supportsTools)
        val badTag = ack.copyOf(); badTag[25] = 0
        assertFalse(BleLinkCodec.decodeHelloAck(badTag).supportsTools)
        val badVersion = ack.copyOf(); badVersion[29] = 2
        assertFalse(BleLinkCodec.decodeHelloAck(badVersion).supportsTools)
        val badRpc = ack.copyOf(); badRpc[32] = 15
        assertFalse(BleLinkCodec.decodeHelloAck(badRpc).supportsTools)
        val badStatus = ack.copyOf(); badStatus[0] = 1
        rejects { BleLinkCodec.decodeHelloAck(badStatus) }
        val major = ack.copyOf(); major[2] = 2
        rejects { BleLinkCodec.decodeHelloAck(major) }
        val shortMax = ack.copyOf(); shortMax[24] = 1
        rejects { BleLinkCodec.decodeHelloAck(shortMax) }
        rejects { BleLinkCodec.decodeHelloAck(ack.copyOf(24)) }
        assertNotNull(peer)
    }
}
