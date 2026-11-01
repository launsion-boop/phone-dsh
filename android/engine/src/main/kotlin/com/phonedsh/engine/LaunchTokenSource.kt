// phone-dsh — :engine / com.phonedsh.engine: the per-start launch token source.
// SPDX-License-Identifier: MIT
//
// The loopback origin's gate token and the worker's PDSH_DSH_LAUNCH_TOKEN are
// one secret: the host generates it for every start, hands it to the origin
// (LoopbackServer.start(..., launchToken)) and the engine hands it to the page
// through the `env` page parameter, which boot.js forwards to the worker's
// process.env. It is never persisted, never logged, and never a URL transport
// key of its own: the page URL carries it only inside the `env` value that
// boot.js scrubs from the visible URL immediately (`BOOT_TRANSPORT_PARAMS`).

package com.phonedsh.engine

import java.security.SecureRandom

/**
 * Supplies the per-start launch token.
 *
 * The host owns freshness: [nextLaunchToken] is called once per `start()`, so a
 * restart gets a new origin token and a new worker environment. Implementations
 * must return at least 16 characters with no whitespace or control character
 * (the origin refuses anything else) and must not reuse a token across starts.
 */
fun interface LaunchTokenSource {
    /** A fresh secret for exactly one start. */
    fun nextLaunchToken(): String

    companion object {
        /** 32 bytes -> 64 lowercase hex characters, the demo host's size. */
        const val DEFAULT_BYTE_COUNT: Int = 32

        /**
         * A source that draws a fresh token from a process-wide [SecureRandom].
         *
         * The engine's default so a host cannot forget the token; `:app` passes
         * its own source so the generation site is the composition root.
         */
        fun fresh(byteCount: Int = DEFAULT_BYTE_COUNT): LaunchTokenSource {
            require(byteCount >= 16) { "a launch token needs at least 16 bytes" }
            val random = SecureRandom()
            return LaunchTokenSource { hex(random, byteCount) }
        }
    }
}

/** [byteCount] random bytes as lowercase hex; the shape the origin and the cookie accept. */
internal fun hex(random: SecureRandom, byteCount: Int): String {
    val raw = ByteArray(byteCount)
    random.nextBytes(raw)
    val digits = "0123456789abcdef"
    val output = StringBuilder(byteCount * 2)
    for (byte in raw) {
        val value = byte.toInt() and 0xFF
        output.append(digits[value ushr 4]).append(digits[value and 0x0F])
    }
    return output.toString()
}
