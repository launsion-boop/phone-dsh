// SPDX-License-Identifier: MIT
// Base64url, base32, Crockford, hex and CSPRNG codec tests. The manual-code
// cases come from the shared `pairing.manual` vector; RFC 4648 vectors pin the
// generic alphabets.
package com.phonedsh.pclink

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PclinkEncodingTest {
    @Test
    fun base64UrlRfcVectorsAndStrictness() {
        val vectors = listOf(
            "" to "",
            "f" to "Zg",
            "fo" to "Zm8",
            "foo" to "Zm9v",
            "foob" to "Zm9vYg",
            "fooba" to "Zm9vYmE",
            "foobar" to "Zm9vYmFy",
        )
        for ((plain, encoded) in vectors) {
            val bytes = plain.toByteArray(Charsets.US_ASCII)
            assertEquals(encoded, PclinkBase64Url.encode(bytes))
            if (encoded.isNotEmpty()) assertArrayEquals(bytes, PclinkBase64Url.decode(encoded))
        }
        // Empty text is not a valid base64url *decode* (a wire field is never
        // empty), while encoding the empty byte array yields the empty string.
        assertPclinkCode("bad_frame") { PclinkBase64Url.decode("") }

        // Padding, the standard alphabet, whitespace and non-ASCII are rejected.
        for (bad in listOf("Zg==", "Zm9v+", "Zm9v/", "Zm 9v", "Zm9v\n", "Zm9v\u00E9", "A")) {
            assertPclinkCode("bad_frame", "base64url '$bad'") { PclinkBase64Url.decode(bad) }
        }
        // The unused low bits of the last character must be zero.
        assertPclinkCode("bad_frame") { PclinkBase64Url.decode("Zh") }
        // Exact expected decoded length.
        assertPclinkCode("bad_frame") {
            PclinkBase64Url.decode("Zm9v", expectedLength = 2)
        }
        assertEquals(3, PclinkBase64Url.decode("Zm9v", expectedLength = 3).size)
    }

    @Test
    fun base32RfcVectorsAndMachineId() {
        val vectors = listOf(
            "" to "",
            "f" to "MY",
            "fo" to "MZXQ",
            "foo" to "MZXW6",
            "foob" to "MZXW6YQ",
            "fooba" to "MZXW6YTB",
            "foobar" to "MZXW6YTBOI",
        )
        for ((plain, encoded) in vectors) {
            val bytes = plain.toByteArray(Charsets.US_ASCII)
            assertEquals(encoded, PclinkBase32.encode(bytes))
            assertArrayEquals(bytes, PclinkBase32.decode(encoded))
            assertArrayEquals(bytes, PclinkBase32.decode(encoded.lowercase()))
        }
        assertPclinkCode("bad_frame") { PclinkBase32.decode("MZ") }
        assertPclinkCode("bad_frame") { PclinkBase32.decode("M1") }

        val identities = TestSupport.at(TestSupport.vectors(), "identities")
            ?: throw AssertionError("missing identities")
        for (name in listOf("phone", "pc")) {
            val publicKey = TestSupport.b64(identities, name, "public_key")
                ?: throw AssertionError("$name public key")
            assertEquals(
                "$name machineId",
                TestSupport.requireString(identities, name, "machine_id"),
                PclinkBase32.machineId(publicKey),
            )
        }
    }

    @Test
    fun crockfordManualCodeFromTheSharedVector() {
        val manual = TestSupport.at(TestSupport.vectors(), "pairing", "manual")
            ?: throw AssertionError("missing pairing.manual")
        val normalized = TestSupport.requireString(manual, "normalized")
        val canonical = TestSupport.requireString(manual, "canonical")
        val display = TestSupport.requireString(manual, "display")
        val secret = TestSupport.hex(TestSupport.requireString(manual, "secret_hex"))

        assertEquals(normalized, canonical)
        assertEquals(16, canonical.length)
        for (input in TestSupport.objects(manual, "equivalent_inputs").mapNotNull { it.stringValue }) {
            assertEquals("normalize '$input'", normalized, PclinkCrockford.normalize(input))
        }
        assertEquals("normalize input", normalized,
            PclinkCrockford.normalize(TestSupport.requireString(manual, "input")))
        assertEquals(display, PclinkCrockford.display(normalized))
        assertEquals(display, PclinkCrockford.display(TestSupport.requireString(manual, "input")))
        assertArrayEquals(secret, PclinkCrockford.decode(TestSupport.requireString(manual, "input")))
        assertEquals(canonical, PclinkCrockford.encode(secret))

        // `U` and every other non-alphabet character are rejected, and the
        // length is exactly 16 characters.
        assertPclinkCode("bad_frame") { PclinkCrockford.decode("U8DJ-RFAE-BXG7-30MK") }
        assertPclinkCode("bad_frame") { PclinkCrockford.decode("18DJ-RFAE") }
        assertPclinkCode("bad_frame") { PclinkCrockford.decode("18DJ-RFAE-BXG7-30M!") }
        assertPclinkCode("bad_frame") { PclinkCrockford.encode(ByteArray(9)) }
    }

    @Test
    fun hexIsLowercaseAndAcceptsEitherCase() {
        val bytes = byteArrayOf(0x00, 0x0A, 0x7F, 0xFF.toByte())
        assertEquals("000a7fff", PclinkHex.encode(bytes))
        assertArrayEquals(bytes, PclinkHex.decode("000a7fff"))
        assertArrayEquals(bytes, PclinkHex.decode("000A7FFF"))
        assertPclinkCode("bad_frame") { PclinkHex.decode("abc") }
        assertPclinkCode("bad_frame") { PclinkHex.decode("zz") }
    }

    @Test
    fun randomBytesAreTheRequestedLength() {
        for (length in listOf(10, 16, 22, 32)) {
            val bytes = PclinkRandom.bytes(length)
            assertEquals(length, bytes.size)
            assertFalse("CSPRNG returned all zeroes", bytes.all { it == 0.toByte() })
        }
        assertEquals(0, PclinkRandom.bytes(0).size)
        assertFalse(
            "two 32-byte draws must differ",
            PclinkRandom.bytes(32).contentEquals(PclinkRandom.bytes(32)),
        )
        assertTrue(PclinkRandom.nonce(16).size == 16)
    }
}
