// Segment naming and the 40-byte header against the wal.md §2 golden.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.wire.WalException
import com.phonedsh.wire.bytesToHex
import com.phonedsh.wire.hexToBytes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class WalSegmentTest {
    @Test
    fun segmentNameRoundTripsTheFixedWidthForm() {
        val name = WalSegmentName(1, 0)
        assertEquals("00000001.000000.xlwal", name.fileName)
        assertEquals("wal/00000001.000000.xlwal", name.manifestFile)
        assertEquals(name, WalSegmentName.parse(name.fileName))
        assertEquals(name, WalSegmentName.parse(name.manifestFile))

        val late = WalSegmentName(99_999_999, 999_999)
        assertEquals("99999999.999999.xlwal", late.fileName)
        assertEquals(late, WalSegmentName.parse(late.manifestFile))
        assertEquals("00000042.000003.xlwal", WalSegmentName(42, 3).fileName)
    }

    @Test
    fun segmentNameRejectsEveryOtherSpelling() {
        // Not the §1 fixed-width form: an unpadded field, a wrong extension,
        // an uppercase extension, an unrelated file and an out-of-range epoch.
        assertNull(WalSegmentName.parse("1.0.xlwal"))
        assertNull(WalSegmentName.parse("00000001.000000.xlwa"))
        assertNull(WalSegmentName.parse("00000001.000000.XLWAL"))
        assertNull(WalSegmentName.parse("notes.txt"))
        assertNull(WalSegmentName.parse("00000000.000000.xlwal"))
        assertNull(WalSegmentName.parse("00000001.1000000.xlwal"))
        assertNull(WalSegmentName.parse("wal/100000000.000000.xlwal"))
        assertEquals(
            "WAL_BAD_SEGMENT_NAME",
            assertThrows(WalException::class.java) {
                WalSegmentName.require("1.0.xlwal")
            }.code,
        )
    }

    @Test
    fun segmentNameOrdersByEpochThenSegment() {
        val names = listOf(
            WalSegmentName(2, 0),
            WalSegmentName(1, 3),
            WalSegmentName(1, 0),
        ).sorted()
        assertEquals(
            listOf(WalSegmentName(1, 0), WalSegmentName(1, 3), WalSegmentName(2, 0)),
            names,
        )
    }

    @Test
    fun headerMatchesTheHandComputedWalMdGolden() {
        // wal.md §2: first_mseq = 1, 16 zero boot_id bytes, CRC 0x0B0F9536.
        val header = WalSegmentHeader(firstMseq = 1, bootId = BootId.ZERO)
        val encoded = header.encode()
        assertEquals(WalSegmentHeader.BYTES, encoded.size)
        assertEquals(
            "584c57414c310000000100000000000000000001000000000000000000000000000000000b0f9536",
            bytesToHex(encoded),
        )
        assertEquals(0x0B0F9536, java.nio.ByteBuffer.wrap(encoded, 36, 4).int)
        assertEquals(header, WalSegmentHeader.decode(encoded))
    }

    @Test
    fun headerRoundTripsTheGoldenBootId() {
        val golden = hexToBytes(
            "584c57414c31000000010000000000000000002a00112233445566778899aabbccddeeffc8bf2ade",
        )
        val header = WalSegmentHeader.decode(golden)
        assertEquals(42L, header.firstMseq)
        assertEquals("00112233445566778899aabbccddeeff", header.bootId.hex)
        assertEquals(bytesToHex(golden), bytesToHex(header.encode()))
    }

    @Test
    fun headerRejectsEveryUnreadableField() {
        val good = WalSegmentHeader(firstMseq = 7, bootId = TEST_BOOT_ID).encode()

        fun codeOf(bytes: ByteArray): String =
            assertThrows(WalException::class.java) { WalSegmentHeader.decode(bytes) }.code

        assertEquals("WAL_TRUNCATED", codeOf(good.copyOf(39)))

        val badMagic = good.copyOf().also { it[0] = 0x00 }
        assertEquals("WAL_HEADER_INVALID", codeOf(badMagic))

        val badFormat = good.copyOf().also { it[9] = 2 }
        assertEquals("WAL_HEADER_INVALID", codeOf(badFormat))

        val badReserved = good.copyOf().also { it[11] = 1 }
        assertEquals("WAL_HEADER_INVALID", codeOf(badReserved))

        val zeroFirstMseq = good.copyOf().also { bytes ->
            for (index in 12..19) bytes[index] = 0
        }
        assertEquals("WAL_HEADER_INVALID", codeOf(zeroFirstMseq))

        val badCrc = good.copyOf().also { it[39] = (it[39].toInt() xor 0xFF).toByte() }
        assertEquals("WAL_HEADER_INVALID", codeOf(badCrc))
    }
}
