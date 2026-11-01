// The boot identity in both forms wal.md fixes: 16 raw bytes and 32 hex characters.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import java.security.SecureRandom
import java.util.Locale

/**
 * The boot identity of D6, in the two forms `wal.md` needs.
 *
 * `wal.md` §2 stores the **16 raw bytes** in the segment header and §7 stores
 * the **32 lowercase hex characters** in `manifest.json`; they are the same
 * value, never two independent identities. This type keeps the hex form as the
 * single field and derives the raw bytes, so a header and a manifest written
 * from one [BootId] cannot disagree.
 *
 * Construction rejects anything that is not exactly 32 lowercase hex
 * characters: an uppercase or short value is not the D6 identifier and must
 * never reach a file.
 *
 * @property hex the 32 lowercase hex characters of D6.
 */
data class BootId(val hex: String) {
    init {
        require(hex.length == HEX_CHARS) {
            "boot_id must be $HEX_CHARS hex characters, was ${hex.length}"
        }
        require(hex.all { it in '0'..'9' || it in 'a'..'f' }) {
            "boot_id must be 32 lowercase hex characters"
        }
    }

    /** The 16 raw `boot_id` bytes of the `wal.md` §2 header. */
    val bytes: ByteArray
        get() = ByteArray(BYTES) { index ->
            hex.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }

    override fun toString(): String = hex

    companion object {
        /** Hex characters in the D6 form. */
        const val HEX_CHARS: Int = 32

        /** Raw bytes in the `wal.md` §2 field. */
        const val BYTES: Int = 16

        /** The all-zero identity; only fixtures and the §2 golden use it. */
        val ZERO: BootId = BootId("0".repeat(HEX_CHARS))

        /**
         * Wraps exactly [BYTES] raw bytes.
         *
         * @throws IllegalArgumentException when [bytes] is not 16 bytes long.
         */
        fun of(bytes: ByteArray): BootId {
            require(bytes.size == BYTES) { "boot_id needs $BYTES bytes, was ${bytes.size}" }
            val hex = StringBuilder(HEX_CHARS)
            for (byte in bytes) {
                val value = byte.toInt() and 0xFF
                hex.append(HEX_DIGITS[value ushr 4])
                hex.append(HEX_DIGITS[value and 0x0F])
            }
            return BootId(hex.toString())
        }

        /**
         * A fresh random identity, one per process boot.
         *
         * [random] is injectable so a test can pin the bytes; the default is a
         * `SecureRandom`, which is the only acceptable source for an identifier
         * that distinguishes boots in a recovery log.
         */
        fun random(random: SecureRandom = SecureRandom()): BootId {
            val bytes = ByteArray(BYTES)
            random.nextBytes(bytes)
            return of(bytes)
        }

        /**
         * Parses the manifest form, rejecting anything D6 does not allow.
         *
         * @throws IllegalArgumentException for a value that is not 32 lowercase
         *   hex characters.
         */
        fun parse(hex: String): BootId = BootId(hex.lowercase(Locale.ROOT)).also {
            // `lowercase` would silently accept uppercase input; D6 fixes the
            // lowercase form, so an uppercase caller is a bug and must fail.
            require(it.hex == hex) { "boot_id must be 32 lowercase hex characters" }
        }

        private const val HEX_DIGITS = "0123456789abcdef"
    }
}
