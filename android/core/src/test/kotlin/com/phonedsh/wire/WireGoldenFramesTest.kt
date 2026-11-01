// The 33 golden frame vectors, decoded and re-encoded on the Kotlin side.
// SPDX-License-Identifier: MIT

package com.phonedsh.wire

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/**
 * One JUnit case per golden vector: 32 files of `spec/v1/golden/frames` plus the
 * inline `channel.md` §4.8 ERROR vector.
 *
 * Each case proves the full Kotlin → JNI → Rust round trip:
 *
 * 1. `decode(frame_hex)` returns the canonical form of the vector's `fields`;
 * 2. `encode(decoded or the golden document, seq)` is byte-for-byte
 *    `frame_hex`, and its tail is `payload_hex`;
 * 3. the decoded fields re-encode when wrapped with the type name and with the
 *    type byte.
 */
@RunWith(Parameterized::class)
class WireGoldenFramesTest(private val vector: GoldenVector) {
    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{index}: {0}")
        fun vectors(): List<GoldenVector> = GoldenCorpus.load()
    }

    @Test
    fun goldenVectorDecodesAndReEncodesByteForByte() {
        val frameBytes = hexToBytes(vector.frameHex)

        val decodedFields = WireCodec.decode(frameBytes)
        assertEquals(
            "${vector.name}: canonical fields",
            WireCodec.canonicalJson(vector.fields),
            decodedFields,
        )

        val encoded = WireCodec.encode(vector.document, vector.seq)
        assertArrayEquals("${vector.name}: frame_hex", frameBytes, encoded)
        assertEquals("${vector.name}: frame_hex text", vector.frameHex, bytesToHex(encoded))
        assertEquals(
            "${vector.name}: payload_hex",
            vector.payloadHex,
            bytesToHex(encoded.copyOfRange(16, encoded.size)),
        )

        val roundTripped = WireCodec.encode(
            "{\"type\":\"${vector.type}\",\"fields\":$decodedFields}",
            vector.seq,
        )
        assertArrayEquals("${vector.name}: decode then encode", frameBytes, roundTripped)

        val byByte = WireCodec.encode(
            "{\"type_byte\":${vector.typeByte},\"fields\":$decodedFields}",
            vector.seq,
        )
        assertArrayEquals("${vector.name}: type_byte envelope", frameBytes, byByte)
    }
}

/** The corpus itself: a fixed 33 vectors covering all 18 frame types. */
class WireGoldenCorpusTest {
    @Test
    fun corpusIsFixedAtThirtyThreeVectors() {
        val vectors = GoldenCorpus.load()
        assertEquals("vector count", 33, vectors.size)
        assertEquals("file count", 32, GoldenCorpus.EXPECTED_FILES.size)
        assertEquals("file set", GoldenCorpus.EXPECTED_FILES, GoldenCorpus.filesOnDisk())
        assertEquals(
            "all 18 channel.md §2 frame types have a vector",
            18,
            vectors.map { it.typeByte }.distinct().size,
        )
        assertEquals(
            "the inline channel.md §4.8 vector is the 33rd",
            "inline-channel-md-error-2",
            vectors.last().name,
        )
    }
}
