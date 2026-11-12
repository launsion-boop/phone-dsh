// SPDX-License-Identifier: MIT
// PCLink v1 codecs: base64url, base32, Crockford, hex and the CSPRNG (§2.1, §4.1).
package com.phonedsh.pclink

import java.security.SecureRandom

/** RFC 4648 base64url without padding; strict/canonical on decode. */
object PclinkBase64Url {
    private const val ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    private val lookup: Map<Byte, Int> = buildMap {
        ALPHABET.forEachIndexed { index, character ->
            put(character.code.toByte(), index)
        }
    }

    fun encode(data: ByteArray): String {
        val out = StringBuilder((data.size * 4 + 2) / 3)
        var index = 0
        while (index + 3 <= data.size) {
            val value = ((data[index].toInt() and 0xFF) shl 16) or
                ((data[index + 1].toInt() and 0xFF) shl 8) or
                (data[index + 2].toInt() and 0xFF)
            out.append(ALPHABET[(value shr 18) and 0x3F])
            out.append(ALPHABET[(value shr 12) and 0x3F])
            out.append(ALPHABET[(value shr 6) and 0x3F])
            out.append(ALPHABET[value and 0x3F])
            index += 3
        }
        when (data.size - index) {
            1 -> {
                val value = (data[index].toInt() and 0xFF) shl 16
                out.append(ALPHABET[(value shr 18) and 0x3F])
                out.append(ALPHABET[(value shr 12) and 0x3F])
            }
            2 -> {
                val value = ((data[index].toInt() and 0xFF) shl 16) or
                    ((data[index + 1].toInt() and 0xFF) shl 8)
                out.append(ALPHABET[(value shr 18) and 0x3F])
                out.append(ALPHABET[(value shr 12) and 0x3F])
                out.append(ALPHABET[(value shr 6) and 0x3F])
            }
        }
        return out.toString()
    }

    /**
     * Strict RFC 4648 base64url: rejects `=`, `+`, `/`, whitespace, non-ASCII,
     * an impossible length, a wrong decoded length and a non-canonical
     * re-encoding (the unused low bits of the last character must be zero).
     */
    fun decode(text: String, expectedLength: Int? = null): ByteArray {
        if (text.isEmpty()) throw badFrame("empty base64url")
        val values = IntArray(text.toByteArray(Charsets.UTF_8).size)
        var count = 0
        for (byte in text.toByteArray(Charsets.UTF_8)) {
            val value = lookup[byte] ?: throw badFrame("invalid base64url character")
            values[count++] = value
        }
        if (count % 4 == 1) throw badFrame("invalid base64url length")
        if (expectedLength != null) {
            val produced = count / 4 * 3 + intArrayOf(0, 0, 1, 2)[count % 4]
            if (produced != expectedLength) {
                throw badFrame("expected $expectedLength base64url bytes, got $produced")
            }
        }
        val out = ByteArray(count / 4 * 3 + 2)
        var written = 0
        var index = 0
        while (index + 4 <= count) {
            val value = (values[index] shl 18) or (values[index + 1] shl 12) or
                (values[index + 2] shl 6) or values[index + 3]
            out[written++] = ((value shr 16) and 0xFF).toByte()
            out[written++] = ((value shr 8) and 0xFF).toByte()
            out[written++] = (value and 0xFF).toByte()
            index += 4
        }
        when (count - index) {
            2 -> {
                val value = (values[index] shl 18) or (values[index + 1] shl 12)
                if (value and 0xFFFF != 0) throw badFrame("non-canonical base64url")
                out[written++] = ((value shr 16) and 0xFF).toByte()
            }
            3 -> {
                val value = (values[index] shl 18) or (values[index + 1] shl 12) or
                    (values[index + 2] shl 6)
                if (value and 0xFF != 0) throw badFrame("non-canonical base64url")
                out[written++] = ((value shr 16) and 0xFF).toByte()
                out[written++] = ((value shr 8) and 0xFF).toByte()
            }
        }
        val decoded = out.copyOf(written)
        if (expectedLength != null && decoded.size != expectedLength) {
            throw badFrame("expected $expectedLength base64url bytes, got ${decoded.size}")
        }
        // Defense in depth against a decoder bug: the canonical text must be
        // byte-identical to what we would emit.
        if (encode(decoded) != text) throw badFrame("non-canonical base64url")
        return decoded
    }

    private fun badFrame(message: String): PclinkError = PclinkError.BadFrame(message)
}

/** RFC 4648 base32 without padding (`A-Z2-7`), used for `machineId`. */
object PclinkBase32 {
    private const val ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

    fun encode(data: ByteArray): String {
        val out = StringBuilder()
        var buffer = 0
        var bits = 0
        for (byte in data) {
            buffer = (buffer shl 8) or (byte.toInt() and 0xFF)
            bits += 8
            while (bits >= 5) {
                bits -= 5
                out.append(ALPHABET[(buffer shr bits) and 0x1F])
            }
            // Keep only the bits that have not been emitted yet; 5 bits at most.
            buffer = buffer and ((1 shl bits) - 1)
        }
        if (bits > 0) out.append(ALPHABET[(buffer shl (5 - bits)) and 0x1F])
        return out.toString()
    }

    fun decode(text: String): ByteArray {
        val out = ArrayList<Byte>(text.length * 5 / 8)
        var buffer = 0
        var bits = 0
        for (character in text.uppercase()) {
            val index = ALPHABET.indexOf(character)
            if (index < 0) throw PclinkError.BadFrame("invalid base32")
            buffer = (buffer shl 5) or index
            bits += 5
            if (bits >= 8) {
                bits -= 8
                out.add(((buffer shr bits) and 0xFF).toByte())
                buffer = buffer and ((1 shl bits) - 1)
            }
        }
        // Unused trailing bits must be zero.
        if (bits > 0 && (buffer and ((1 shl bits) - 1)) != 0) {
            throw PclinkError.BadFrame("invalid base32")
        }
        return out.toByteArray()
    }

    /** `machineId = lower(base32_nopad(sha256(E)))[0:26]` (§2.2). */
    fun machineId(publicKey: ByteArray): String {
        val digest = PclinkCrypto.sha256(publicKey)
        return encode(digest).take(26).lowercase()
    }
}

/** Crockford base32 manual code (§4.1): 16 characters == a 10-byte value. */
object PclinkCrockford {
    const val CANONICAL_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    /**
     * Normalizes manual-code input: uppercases, removes `-`, spaces and other
     * whitespace, maps `O`→`0` and `I`/`L`→`1`, then requires exactly 16
     * characters from the canonical alphabet. `U` and everything else is
     * rejected.
     */
    fun normalize(input: String): String {
        val out = StringBuilder()
        var index = 0
        while (index < input.length) {
            val codePoint = input.codePointAt(index)
            index += Character.charCount(codePoint)
            if (codePoint == '-'.code || Character.isWhitespace(codePoint) ||
                Character.isSpaceChar(codePoint)
            ) {
                continue
            }
            when (val upper = Character.toUpperCase(codePoint)) {
                'O'.code -> out.append('0')
                'I'.code, 'L'.code -> out.append('1')
                else -> {
                    if (upper > 0x7F || CANONICAL_ALPHABET.indexOf(upper.toChar()) < 0) {
                        throw PclinkError.BadFrame("invalid Crockford base32 input")
                    }
                    out.append(upper.toChar())
                }
            }
        }
        if (out.length != 16) throw PclinkError.BadFrame("manual code must be 16 characters")
        return out.toString()
    }

    /** Decodes the 16 characters as a big-endian 80-bit value into 10 bytes. */
    fun decode(input: String): ByteArray {
        val normalized = normalize(input)
        val bytes = ByteArray(10)
        var accumulator = 0
        var bits = 0
        var byteIndex = 0
        for (character in normalized) {
            val value = CANONICAL_ALPHABET.indexOf(character)
            if (value < 0) throw PclinkError.BadFrame("invalid Crockford base32 input")
            accumulator = (accumulator shl 5) or value
            bits += 5
            if (bits >= 8) {
                bits -= 8
                bytes[byteIndex++] = ((accumulator shr bits) and 0xFF).toByte()
                accumulator = accumulator and ((1 shl bits) - 1)
            }
        }
        if (byteIndex != 10 || bits != 0) {
            throw PclinkError.BadFrame("invalid Crockford base32 input")
        }
        return bytes
    }

    /** Encodes a 10-byte value as the 16-character canonical manual code. */
    fun encode(data: ByteArray): String {
        if (data.size != 10) {
            throw PclinkError.BadFrame("manual code needs exactly 10 bytes, got ${data.size}")
        }
        val out = StringBuilder(16)
        var accumulator = 0
        var bits = 0
        for (byte in data) {
            accumulator = (accumulator shl 8) or (byte.toInt() and 0xFF)
            bits += 8
            while (bits >= 5) {
                bits -= 5
                out.append(CANONICAL_ALPHABET[(accumulator shr bits) and 0x1F])
            }
            accumulator = accumulator and ((1 shl bits) - 1)
        }
        return out.toString()
    }

    /** `XXXX-XXXX-XXXX-XXXX`. */
    fun display(input: String): String {
        val normalized = normalize(input)
        return normalized.chunked(4).joinToString("-")
    }
}

/** Lowercase hex output; accepts upper- or lowercase input. */
object PclinkHex {
    private const val DIGITS = "0123456789abcdef"

    fun encode(data: ByteArray): String {
        val out = StringBuilder(data.size * 2)
        for (byte in data) {
            val value = byte.toInt() and 0xFF
            out.append(DIGITS[value shr 4])
            out.append(DIGITS[value and 0x0F])
        }
        return out.toString()
    }

    fun decode(text: String): ByteArray {
        if (text.length % 2 != 0) throw PclinkError.BadFrame("invalid hex")
        val out = ByteArray(text.length / 2)
        var index = 0
        var written = 0
        while (index < text.length) {
            val high = hexDigit(text[index])
            val low = hexDigit(text[index + 1])
            out[written++] = ((high shl 4) or low).toByte()
            index += 2
        }
        return out
    }

    private fun hexDigit(character: Char): Int = when (character) {
        in '0'..'9' -> character - '0'
        in 'a'..'f' -> character - 'a' + 10
        in 'A'..'F' -> character - 'A' + 10
        else -> throw PclinkError.BadFrame("invalid hex")
    }
}

/** CSPRNG bytes for `sid`, nonces, S/C and the identity seed (§2.1, §4.1). */
object PclinkRandom {
    private val random = SecureRandom()

    fun bytes(count: Int): ByteArray {
        if (count <= 0) return ByteArray(0)
        return try {
            ByteArray(count).also(random::nextBytes)
        } catch (error: RuntimeException) {
            throw PclinkError.Storage("CSPRNG failed: ${error.message}")
        }
    }

    fun nonce(count: Int): ByteArray = bytes(count)
}
