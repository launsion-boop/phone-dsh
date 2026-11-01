// phone-dsh — :loopback / com.phonedsh.loopback: the per-start secret.
// SPDX-License-Identifier: MIT
//
// The token is generated once per start and handed to the caller through
// LoopbackEndpoint. It is never written to a log, never part of an exception
// message and never echoed by a response body (see LoopbackServerTest).

package com.phonedsh.loopback

import java.security.SecureRandom

internal object LoopbackToken {
    private const val TOKEN_BYTES = 16
    private val HEX = "0123456789abcdef".toCharArray()
    private val random = SecureRandom()

    /** A fresh 128-bit secret as 32 lowercase hex characters. */
    fun generate(): String {
        val raw = ByteArray(TOKEN_BYTES)
        random.nextBytes(raw)
        val hex = CharArray(TOKEN_BYTES * 2)
        for (index in raw.indices) {
            val value = raw[index].toInt() and 0xFF
            hex[index * 2] = HEX[value ushr 4]
            hex[index * 2 + 1] = HEX[value and 0x0F]
        }
        return String(hex)
    }

    /**
     * Validates a host-supplied per-start token.
     *
     * Same rule as a pinned [LoopbackConfiguration.token]: long enough not to be
     * guessable and free of whitespace/control characters (the value travels in
     * a URL query during the launch exchange). The message never repeats the
     * value.
     */
    fun requireUsable(token: String) {
        require(token.length >= LoopbackConfiguration.MIN_PINNED_TOKEN_LENGTH) {
            "a per-start token must be at least " +
                "${LoopbackConfiguration.MIN_PINNED_TOKEN_LENGTH} characters"
        }
        require(token.none { it.isWhitespace() || it.isISOControl() }) {
            "a per-start token must not contain whitespace or control characters"
        }
    }

    /**
     * Constant-time comparison. The running time depends on the two lengths
     * only, never on how many leading bytes happen to match, so a wrong token
     * cannot be discovered byte by byte.
     */
    fun matches(candidate: String?, expected: String): Boolean {
        if (candidate == null) return false
        val left = candidate.toByteArray(Charsets.UTF_8)
        val right = expected.toByteArray(Charsets.UTF_8)
        var difference = left.size xor right.size
        val length = maxOf(left.size, right.size)
        for (index in 0 until length) {
            val a = if (index < left.size) left[index].toInt() else 0
            val b = if (index < right.size) right[index].toInt() else 0
            difference = difference or (a xor b)
        }
        return difference == 0
    }
}
