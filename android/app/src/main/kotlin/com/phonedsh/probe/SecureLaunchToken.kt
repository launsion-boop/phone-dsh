// phone-dsh — :app: the demo host's per-start launch token source.
// SPDX-License-Identifier: MIT
//
// The App is the composition root that owns freshness: every engine start draws
// 32 fresh bytes from a process-wide SecureRandom and hands them to
// createDemoEngine. The engine passes that one value to the loopback origin
// (gate + D22 launch cookie) and to the page's `env` parameter as
// PDSH_DSH_LAUNCH_TOKEN; boot.js forwards it to the worker's process.env.
//
// The value is never written to a file, a log line, an exception message, the
// UI or a notification. [current] exists only so the App's own `/v1/http` probe
// can authenticate to its own origin; it is not exposed beyond this package.

package com.phonedsh.probe

import com.phonedsh.engine.LaunchTokenSource
import java.security.SecureRandom

/**
 * A fresh 32-byte (64 lowercase hex character) token for every `start()`.
 *
 * 32 bytes is the demo host's size; the origin accepts anything at least 16
 * characters long without whitespace, and a hex value is a valid cookie value,
 * so the same string works as the loopback gate token, the `xl_launch_token`
 * cookie and the worker's `PDSH_DSH_LAUNCH_TOKEN` without re-encoding.
 */
internal class SecureLaunchToken : LaunchTokenSource {
    private val random = SecureRandom()

    @Volatile
    private var latest: String? = null

    override fun nextLaunchToken(): String {
        val raw = ByteArray(BYTE_COUNT)
        random.nextBytes(raw)
        val token = StringBuilder(BYTE_COUNT * 2)
        for (byte in raw) {
            val value = byte.toInt() and 0xFF
            token.append(HEX_DIGITS[value ushr 4]).append(HEX_DIGITS[value and 0x0F])
        }
        val value = token.toString()
        latest = value
        return value
    }

    /** The token the most recent start used, for the App's own origin request. */
    fun current(): String? = latest

    private companion object {
        const val BYTE_COUNT = 32
        const val HEX_DIGITS = "0123456789abcdef"
    }
}
