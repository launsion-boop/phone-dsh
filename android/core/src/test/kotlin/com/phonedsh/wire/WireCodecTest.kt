// CRC, canonical JSON, error, panic and load-failure behavior of the binding.
// SPDX-License-Identifier: MIT

package com.phonedsh.wire

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WireCodecTest {
    @Test
    fun nativeLibraryIsAvailable() {
        assertTrue(
            "libpdsh_jni failed to load: ${NativeWire.failure}",
            NativeWire.available,
        )
    }

    @Test
    fun crc32cKnownAnswer() {
        assertEquals(
            0xE3069283.toInt(),
            WireCodec.crc32c("123456789".toByteArray(Charsets.US_ASCII)),
        )
        assertEquals(0, WireCodec.crc32c(ByteArray(0)))
    }

    @Test
    fun canonicalJsonSortsMembersAndKeepsUtf8() {
        assertEquals(
            "{\"a\":1,\"b\":[\"x\",\"/y\"]}",
            WireCodec.canonicalJson("""{ "b" : [ "x" , "\/y" ] , "a" : 1 }"""),
        )
        assertEquals(
            "{\"level\":\"info\",\"text\":\"ready ✓\"}",
            WireCodec.canonicalJson("""{ "text" : "ready \u2713" , "level" : "info" }"""),
        )
        val error = assertThrows(WireException::class.java) {
            WireCodec.canonicalJson("""{"a":1,"a":2}""")
        }
        assertEquals("BAD_PAYLOAD", error.code)
    }

    @Test
    fun invalidFrameThrowsWireExceptionInsteadOfCrashing() {
        val error = assertThrows(WireException::class.java) {
            WireCodec.decode(byteArrayOf(0, 1, 2))
        }
        assertEquals("BAD_PAYLOAD", error.code)
        assertTrue(error.detail.contains("frame header"))

        val valid = WireCodec.encode(
            """{"type":"VFS_ACK","fields":{"level":1,"upto_mseq":45}}""",
            3,
        )
        val badMagic = valid.copyOf()
        badMagic[0] = 0x00
        val magicError = assertThrows(WireException::class.java) { WireCodec.decode(badMagic) }
        assertEquals("BAD_MAGIC", magicError.code)
    }

    @Test
    fun unknownFrameTypeIsBadPayload() {
        // 16-byte header: magic 0x5A4C, type 0x02 (not in channel.md §2),
        // flags 0, seq 1, len 1, plus one payload byte.
        val frame = hexToBytes("5a4c020000000000000000010000000100")
        val error = assertThrows(WireException::class.java) { WireCodec.decode(frame) }
        assertEquals("BAD_PAYLOAD", error.code)
        assertTrue(error.detail.contains("unknown frame type byte"))
    }

    @Test
    fun encodeRejectsMalformedInput() {
        val malformed = assertThrows(WireException::class.java) { WireCodec.encode("{", 1) }
        assertEquals("BAD_PAYLOAD", malformed.code)

        val missingType = assertThrows(WireException::class.java) {
            WireCodec.encode("""{"fields":{"level":1}}""", 1)
        }
        assertEquals("BAD_PAYLOAD", missingType.code)

        val negativeSeq = assertThrows(WireException::class.java) {
            WireCodec.encode("""{"type":"VFS_ACK","fields":{"level":1,"upto_mseq":45}}""", -1)
        }
        assertEquals("BAD_SEQ", negativeSeq.code)
    }

    @Test
    fun rustPanicArrivesAsJavaException() {
        val error = assertThrows(RuntimeException::class.java) {
            NativeWire.panicForTest("intentional test hook")
        }
        assertTrue(
            "panic hook message was: ${error.message}",
            error.message.orEmpty().contains("PDSH_JNI_PANIC"),
        )
        assertTrue(error.message.orEmpty().contains("intentional test hook"))

        // A caught panic must leave the JVM and the native library usable.
        assertEquals(
            0xE3069283.toInt(),
            WireCodec.crc32c("123456789".toByteArray(Charsets.US_ASCII)),
        )
    }

    @Test
    fun unavailableBindingThrowsWireUnavailable() {
        val binding = NativeWireBinding(
            load = { throw UnsatisfiedLinkError("no libpdsh_jni in this test") },
            calls = ExplodingCalls(),
        )
        assertFalse(binding.available)
        assertNotNull(binding.failure)

        val methods: List<() -> Any?> = listOf(
            { binding.crc32c(ByteArray(0)) },
            { binding.encodeFrame(1, "{}") },
            { binding.decodeFrame(ByteArray(0)) },
            { binding.canonicalJson("{}") },
            { binding.panicForTest("never reached") },
        )
        for (call in methods) {
            val error = assertThrows(WireUnavailable::class.java) { call() }
            assertTrue(error.message.orEmpty().contains("libpdsh_jni is unavailable"))
            assertTrue(error.message.orEmpty().contains("no libpdsh_jni in this test"))
        }
    }

    @Test
    fun nativeExceptionShapesTranslateToTypedExceptions() {
        val wire = WireErrors.translate(
            "decodeFrame",
            RuntimeException("BAD_SEQ: expected 19 (ref_seq 18)"),
        )
        assertTrue(wire is WireException)
        assertEquals("BAD_SEQ", (wire as WireException).code)
        assertEquals("expected 19 (ref_seq 18)", wire.detail)

        val panic = WireErrors.translate(
            "encodeFrame",
            RuntimeException("PDSH_JNI_PANIC: encodeFrame: boom"),
        )
        assertTrue(panic is WirePanicException)
        assertEquals("encodeFrame", (panic as WirePanicException).operation)

        val plain = RuntimeException("pdsh-jni call failed: broken env")
        assertSame(plain, WireErrors.translate("decodeFrame", plain))
    }

    /** Fails loudly if a call reaches the native implementation while unavailable. */
    private class ExplodingCalls : NativeWireCalls {
        override fun crc32c(bytes: ByteArray): Int = fail()

        override fun encodeFrame(seq: Long, frameJson: String): ByteArray = fail()

        override fun decodeFrame(bytes: ByteArray): String = fail()

        override fun canonicalJson(json: String): String = fail()

        override fun panicForTest(message: String): String = fail()

        private fun fail(): Nothing =
            throw AssertionError("native call must not run while the library is unavailable")
    }
}
