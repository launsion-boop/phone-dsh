// The segment name of wal.md §1: wal/<epoch:08d>.<segment:06d>.xlwal.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.wire.WalException
import java.nio.file.Path

/**
 * One `wal/<epoch:08d>.<segment:06d>.xlwal` segment name (`wal.md` §1).
 *
 * The name is `<epoch, segment>` in decimal, zero-padded, epoch from 1 and
 * segment from 0 within its epoch. Both the bare directory form
 * (`00000001.000000.xlwal`) and the manifest form (`wal/00000001.000000.xlwal`)
 * parse to the same value, and the single spelling [fileName] round-trips both,
 * so a segment never has two names.
 *
 * `wal.md` §5.2/D18 fixes the epoch-close emitter, and §1 fixes the roll:
 * a segment rolls before a mutation that would exceed 8 MiB. This type carries
 * no policy; it only names.
 *
 * @property epoch the epoch number, `1..MAX_EPOCH`.
 * @property segment the segment number inside [epoch], `0..MAX_SEGMENT`.
 * @throws IllegalArgumentException when a range is violated (use [parse] for
 *   untrusted text, which reports [WalException] instead).
 */
data class WalSegmentName(val epoch: Int, val segment: Int) : Comparable<WalSegmentName> {
    init {
        require(epoch in 1..MAX_EPOCH) { "segment epoch $epoch is outside 1..$MAX_EPOCH" }
        require(segment in 0..MAX_SEGMENT) {
            "segment number $segment is outside 0..$MAX_SEGMENT"
        }
    }

    /** The bare file name, `00000001.000000.xlwal`. */
    val fileName: String
        get() = padded(epoch, EPOCH_DIGITS) + "." + padded(segment, SEGMENT_DIGITS) + "." + EXTENSION

    /** The `manifest.json` form, `wal/00000001.000000.xlwal` (`wal.md` §7). */
    val manifestFile: String
        get() = "$DIRECTORY/$fileName"

    /** Resolves the bare name inside a `wal/` directory. */
    fun resolveIn(directory: Path): Path = directory.resolve(fileName)

    override fun compareTo(other: WalSegmentName): Int {
        val byEpoch = epoch.compareTo(other.epoch)
        return if (byEpoch != 0) byEpoch else segment.compareTo(other.segment)
    }

    override fun toString(): String = manifestFile

    companion object {
        /** The relative directory of every segment (`wal.md` §1). */
        const val DIRECTORY: String = "wal"

        /** The fixed extension of every segment (`wal.md` §1). */
        const val EXTENSION: String = "xlwal"

        /** Digits of the epoch field. */
        const val EPOCH_DIGITS: Int = 8

        /** Digits of the segment field. */
        const val SEGMENT_DIGITS: Int = 6

        /** Largest epoch the 8-digit form can express. */
        const val MAX_EPOCH: Int = 99_999_999

        /** Largest segment the 6-digit form can express. */
        const val MAX_SEGMENT: Int = 999_999

        private val BARE = Regex("^[0-9]{$EPOCH_DIGITS}\\.[0-9]{$SEGMENT_DIGITS}\\.$EXTENSION$")

        /**
         * Parses a bare or manifest-form name, or returns `null` for an
         * unrelated directory entry.
         *
         * A name is accepted only in the one fixed-width spelling of §1:
         * `2024.1.xlwal`, `00000000.000000.xlwal` and `00000001.000000.XLWAL`
         * are all `null`. Recovery lists the directory, so "not a segment" must
         * be a value, not an exception.
         */
        fun parse(text: String): WalSegmentName? {
            val bare = text.removePrefix("$DIRECTORY/")
            if (!BARE.matches(bare)) {
                return null
            }
            val epoch = bare.substring(0, EPOCH_DIGITS).toInt()
            val segment = bare.substring(EPOCH_DIGITS + 1, EPOCH_DIGITS + 1 + SEGMENT_DIGITS).toInt()
            return if (epoch in 1..MAX_EPOCH && segment in 0..MAX_SEGMENT) {
                WalSegmentName(epoch, segment)
            } else {
                null
            }
        }

        /**
         * Parses a name that must be valid, for call sites that already trust
         * the source (a manifest entry, a plan result).
         *
         * @throws WalException `WAL_BAD_SEGMENT_NAME` when [text] is not the
         *   fixed-width §1 form.
         */
        fun require(text: String): WalSegmentName = parse(text)
            ?: throw WalException(
                "WAL_BAD_SEGMENT_NAME",
                "not wal/<epoch:08d>.<segment:06d>.xlwal: $text",
            )

        private fun padded(value: Int, width: Int): String {
            val digits = value.toString()
            return if (digits.length >= width) digits else "0".repeat(width - digits.length) + digits
        }
    }
}
