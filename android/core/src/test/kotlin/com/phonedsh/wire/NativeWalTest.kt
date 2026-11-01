// Entry-point, error, panic and load-failure behavior of the NativeWal binding.
// SPDX-License-Identifier: MIT

package com.phonedsh.wire

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeWalTest {
    private val golden: WalGoldenVector
        get() = WalGoldenCorpus.load().first()

    @Test
    fun nativeLibraryIsAvailable() {
        assertTrue(
            "libpdsh_jni failed to load: ${NativeWal.failure}",
            NativeWal.available,
        )
        assertNull(NativeWal.failure)
    }

    @Test
    fun recordsReturnsAnEmptyArrayForAHeaderOnlySegment() {
        assertEquals(
            "a header-only segment holds no record",
            "[]",
            NativeWal.records(hexToBytes(golden.headerHex)),
        )
    }

    @Test
    fun recordsRejectsAnUnreadableHeaderAndANonTailFailure() {
        val empty = assertThrows(WalException::class.java) { NativeWal.records(ByteArray(0)) }
        assertEquals("WAL_TRUNCATED", empty.code)
        assertEquals(WalErrorCode.TRUNCATED, empty.knownCode)

        val badMagic = hexToBytes(golden.headerHex).also { it[0] = 0x00 }
        val magic = assertThrows(WalException::class.java) { NativeWal.records(badMagic) }
        assertEquals("WAL_HEADER_INVALID", magic.code)
        assertEquals(WalErrorCode.HEADER_INVALID, magic.knownCode)

        // Byte 56 is the first body byte of record 1, covered by its CRC32C.
        val badRecord = hexToBytes(golden.fileHex).also { it[56] = (it[56].toInt() xor 0xFF).toByte() }
        val crc = assertThrows(WalException::class.java) { NativeWal.records(badRecord) }
        assertEquals("WAL_CORRUPT", crc.code)
        assertEquals(WalErrorCode.CORRUPT, crc.knownCode)
    }

    @Test
    fun decodeRecordDecodesOneBodyAndRejectsShortTrailingAndCrcFrames() {
        val first = golden.records.first()
        val frame = hexToBytes(first.member("record_hex").stringValue())
        val decoded = WalJsonParser.parse(NativeWal.decodeRecord(frame)).objectMembers()
        for ((name, value) in first.member("fields").objectMembers()) {
            assertEquals("decodeRecord $name", value, decoded[name])
        }

        val trailingError = assertThrows(WalException::class.java) {
            NativeWal.decodeRecord(frame + byteArrayOf(0))
        }
        assertEquals("WAL_INPUT_INVALID", trailingError.code)

        val short = assertThrows(WalException::class.java) {
            NativeWal.decodeRecord(frame.copyOfRange(0, 4))
        }
        assertEquals("WAL_TRUNCATED", short.code)

        val crcFrame = frame.copyOf().also { it[it.lastIndex] = (it[it.lastIndex].toInt() xor 0xFF).toByte() }
        val crc = assertThrows(WalException::class.java) { NativeWal.decodeRecord(crcFrame) }
        assertEquals("WAL_CORRUPT", crc.code)
    }

    @Test
    fun appendedReplayCoversAllThreeVerdictsAndRejectsNegatives() {
        val data = "world\n".toByteArray(Charsets.US_ASCII)
        assertEquals(
            "{\"verdict\":\"applied\"}",
            NativeWal.appendedReplay(6, 6, data, data),
        )
        assertEquals(
            "{\"verdict\":\"skip\"}",
            NativeWal.appendedReplay(12, 6, data, data),
        )
        assertEquals(
            "{\"verdict\":\"resync\"}",
            NativeWal.appendedReplay(12, 6, data, null),
        )

        val negativeSize = assertThrows(WalException::class.java) {
            NativeWal.appendedReplay(-1, 0, data, data)
        }
        assertEquals("WAL_INPUT_INVALID", negativeSize.code)
        assertTrue(negativeSize.detail.contains("currentSize"))

        val negativeOffset = assertThrows(WalException::class.java) {
            NativeWal.appendedReplay(0, -1, data, data)
        }
        assertEquals("WAL_INPUT_INVALID", negativeOffset.code)
        assertTrue(negativeOffset.detail.contains("appendFrom"))
    }

    @Test
    fun planRecoveryInputErrorsAreTyped() {
        val error = assertThrows(WalException::class.java) {
            NativeWal.planRecovery("not json")
        }
        assertEquals("WAL_INPUT_INVALID", error.code)
        assertEquals(WalErrorCode.INPUT_INVALID, error.knownCode)
    }

    @Test
    fun verifyRecordReportsABadFrameAsAValueNotAnException() {
        val verdict = NativeWal.verifyRecord(byteArrayOf(1, 2, 3))
        assertTrue("verifyRecord: $verdict", verdict.startsWith("{\"ok\":false"))
        assertTrue("verifyRecord: $verdict", verdict.contains("\"code\":\"WAL_TRUNCATED\""))
    }

    @Test
    fun rustPanicArrivesAsJavaExceptionAndTheLibraryStaysUsable() {
        val error = assertThrows(RuntimeException::class.java) {
            NativeWal.panicForTestNative("intentional WAL panic")
        }
        // The exact class the Rust boundary throws: not an
        // UnsatisfiedLinkError, not a JVM abort, and not a translated
        // WirePanicException (this hook is the raw native method).
        assertEquals(RuntimeException::class.java, error.javaClass)
        assertTrue(
            "panic message was: ${error.message}",
            error.message.orEmpty().contains("PDSH_JNI_PANIC"),
        )
        assertTrue(error.message.orEmpty().contains("intentional WAL panic"))

        // Reaching this line proves the JVM survived the unwind; the calls
        // below prove the native library is still usable afterwards.
        val segment = hexToBytes(golden.fileHex)
        assertEquals("{\"verdict\":\"clean\"}", NativeWal.classifyTail(segment))
        assertTrue(
            "scanSegment after the panic: ${NativeWal.scanSegment(segment)}",
            NativeWal.scanSegment(segment).startsWith("{\"header_ok\":true"),
        )
    }

    @Test
    fun unavailableBindingThrowsWireUnavailableForEveryMethod() {
        val binding = NativeWalBinding(
            load = { throw UnsatisfiedLinkError("no libpdsh_jni in this test") },
            calls = ExplodingCalls(),
        )
        assertFalse(binding.available)
        assertNotNull(binding.failure)

        val methods: List<() -> Any?> = listOf(
            { binding.classifyTail(ByteArray(0)) },
            { binding.scanSegment(ByteArray(0)) },
            { binding.planRecovery("{}") },
            { binding.parseManifest(ByteArray(0)) },
            { binding.emitManifest("{}") },
            { binding.verifyRecord(ByteArray(0)) },
            { binding.records(ByteArray(0)) },
            { binding.decodeRecord(ByteArray(0)) },
            { binding.appendedReplay(0, 0, ByteArray(0), null) },
        )
        for (call in methods) {
            val error = assertThrows(WireUnavailable::class.java) { call() }
            assertTrue(error.message.orEmpty().contains("libpdsh_jni is unavailable"))
            assertTrue(error.message.orEmpty().contains("no libpdsh_jni in this test"))
        }
    }

    @Test
    fun nativeExceptionShapesTranslateToTypedExceptions() {
        val known = WalErrors.translate("records", RuntimeException("WAL_CORRUPT: boom"))
        assertTrue(known is WalException)
        known as WalException
        assertEquals("WAL_CORRUPT", known.code)
        assertEquals("boom", known.detail)
        assertEquals(WalErrorCode.CORRUPT, known.knownCode)
        assertTrue(known.isKnownCode)

        val unknown = WalErrors.translate("records", RuntimeException("WAL_FUTURE_CODE: later"))
        assertTrue(unknown is WalException)
        unknown as WalException
        assertEquals("WAL_FUTURE_CODE", unknown.code)
        assertFalse(unknown.isKnownCode)
        assertNull(unknown.knownCode)

        val panic = WalErrors.translate("records", RuntimeException("PDSH_JNI_PANIC: records: boom"))
        assertTrue(panic is WirePanicException)
        assertEquals("records", (panic as WirePanicException).operation)
        assertEquals("boom", panic.detail)

        val plain = RuntimeException("pdsh-jni call failed: broken env")
        assertSame(plain, WalErrors.translate("records", plain))
    }

    @Test
    fun walErrorCodeTableIsPinned() {
        assertEquals(
            listOf(
                "WAL_CORRUPT",
                "WAL_MANIFEST_INVALID",
                "WAL_TRUNCATED",
                "WAL_HEADER_INVALID",
                "WAL_BAD_SEGMENT_NAME",
                "WAL_MSEQ_EXHAUSTED",
                "WAL_EPOCH_EXHAUSTED",
                "WAL_INPUT_INVALID",
            ),
            WalErrorCode.entries.map { it.code },
        )
        assertEquals(WalErrorCode.CORRUPT, WalErrorCode.fromCode("WAL_CORRUPT"))
        assertNull(WalErrorCode.fromCode("WAL_NOT_A_CODE"))
    }

    /** Fails loudly if a call reaches the native implementation while unavailable. */
    private class ExplodingCalls : NativeWalCalls {
        override fun classifyTail(segment: ByteArray): String = fail()

        override fun scanSegment(segment: ByteArray): String = fail()

        override fun planRecovery(input: String): String = fail()

        override fun parseManifest(manifest: ByteArray): String = fail()

        override fun emitManifest(manifestJson: String): ByteArray = fail()

        override fun verifyRecord(record: ByteArray): String = fail()

        override fun records(segment: ByteArray): String = fail()

        override fun decodeRecord(record: ByteArray): String = fail()

        override fun appendedReplay(
            currentSize: Long,
            appendFrom: Long,
            data: ByteArray,
            existingAtOffset: ByteArray?,
        ): String = fail()

        private fun fail(): Nothing =
            throw AssertionError("native call must not run while the library is unavailable")
    }
}
