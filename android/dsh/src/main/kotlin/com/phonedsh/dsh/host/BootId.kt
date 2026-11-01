// phone-dsh — :dsh / com.phonedsh.dsh.host: the per-boot identity of D6.
// SPDX-License-Identifier: MIT
//
// channel.md §4.1 and D6: `boot_id` is exactly 32 lowercase hex characters, one
// per process boot, and the same identity is written into the WAL segment header
// (wal.md, 16 raw bytes) and the manifest. So generation is not cosmetic: two
// boots that produced the same id would look like the same epoch to recovery.
//
// There is no persistence here on purpose. A boot id is minted, not restored; the
// only durable copy is the one the WAL lane writes into its headers. [HostBoot]
// pairs it with the Clock reading at boot so a log line can order boots without
// inventing a date.

package com.phonedsh.dsh.host

import com.phonedsh.platform.Clock
import java.security.SecureRandom

/**
 * Generation and validation of the host `boot_id` (channel.md §4.1, D6).
 *
 * The generator is `SecureRandom`, not `Random`/`UUID.randomUUID()`: a UUID's
 * version/variant nibbles make it 32 hex characters that are *not* uniformly
 * distributed, and a predictable boot id is a correlation key a hostile page
 * could use across restarts. The format check is public so a HELLO received from
 * anywhere else can be validated before it is used as a filename component
 * (D6: any identifier used in a path is validated first).
 */
object BootId {
    /** Exactly 32 lowercase hex characters (channel.md §6). */
    const val LENGTH: Int = 32

    private const val BYTES: Int = LENGTH / 2

    private val DEFAULT_RANDOM: SecureRandom by lazy { SecureRandom() }

    /** The 32 lowercase hex characters; never a UUID, never upper case. */
    private val PATTERN: Regex = Regex("[0-9a-f]{$LENGTH}")

    /** A fresh 128-bit id as 32 lowercase hex characters. */
    fun generate(random: SecureRandom = DEFAULT_RANDOM): String {
        val bytes = ByteArray(BYTES)
        random.nextBytes(bytes)
        val hex = "0123456789abcdef"
        val out = StringBuilder(LENGTH)
        for (byte in bytes) {
            val value = byte.toInt() and 0xFF
            out.append(hex[value ushr 4]).append(hex[value and 0x0F])
        }
        return out.toString()
    }

    /** Whether [value] is exactly 32 lowercase hex characters. */
    fun isValid(value: String): Boolean = PATTERN.matches(value)
}

/**
 * The identity of one host process boot: a fresh [bootId] plus the wall-clock
 * instant it was minted at.
 *
 * [startedAtMillis] is for logs and diagnostics only; no deadline is ever
 * derived from it (those use [Clock.monotonicMillis]).
 */
data class HostBoot(
    val bootId: String,
    val startedAtMillis: Long,
) {
    init {
        require(BootId.isValid(bootId)) {
            "boot_id must be ${BootId.LENGTH} lowercase hex characters, was \"$bootId\""
        }
    }

    companion object {
        /** Mints a new boot identity; call once per process start. */
        fun generate(
            clock: Clock,
            random: SecureRandom = SecureRandom(),
        ): HostBoot = HostBoot(bootId = BootId.generate(random), startedAtMillis = clock.nowMillis())
    }
}
