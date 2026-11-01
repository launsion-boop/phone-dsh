// The typed `pdsh-wal` error and its stable code table, surfaced by NativeWal.
// SPDX-License-Identifier: MIT

package com.phonedsh.wire

/**
 * The FFI diagnostic codes of `pdsh_wal::WalError::code()`, plus the bridge's
 * own input-argument code.
 *
 * The Rust table is the single source of truth: `pdsh-jni` throws
 * `java.lang.RuntimeException` with the message `"<CODE>: <detail>"`, and this
 * enum is the Kotlin-side copy used to recognise the code. A code that is not
 * listed here is **not** dropped — [WalException] keeps the raw string and
 * [WalException.isKnownCode] is `false` — so a newer Rust table stays readable
 * while this binding is at an older revision (the WAL ABI is experimental
 * until the R1 conclusion).
 *
 * The grouping is the `WalError` grouping: `WAL_CORRUPT` is the only
 * `wal.md` §10 state code, and several variants share a code because their
 * recovery consequence is the same.
 */
enum class WalErrorCode(val code: String) {
    /** `WAL_CORRUPT` (`wal.md` §10): recovery fails and admission closes. */
    CORRUPT("WAL_CORRUPT"),

    /** `manifest.json` is not the §7 schema; §7.2 treats it as missing. */
    MANIFEST_INVALID("WAL_MANIFEST_INVALID"),

    /** Fewer bytes than a header or a record needs. */
    TRUNCATED("WAL_TRUNCATED"),

    /** Magic, format, reserved, `first_mseq` or the header CRC is wrong. */
    HEADER_INVALID("WAL_HEADER_INVALID"),

    /** A segment name is not `wal/<epoch:08d>.<segment:06d>.xlwal`. */
    BAD_SEGMENT_NAME("WAL_BAD_SEGMENT_NAME"),

    /** `mseq` reached `u64::MAX`; D17 forbids reusing a number. */
    MSEQ_EXHAUSTED("WAL_MSEQ_EXHAUSTED"),

    /** The next epoch does not fit the 8-digit segment-name form. */
    EPOCH_EXHAUSTED("WAL_EPOCH_EXHAUSTED"),

    /** A bridge argument that is not the documented JSON/byte shape. */
    INPUT_INVALID("WAL_INPUT_INVALID"),
    ;

    companion object {
        /** The enum entry for [code], or `null` when the Rust table is newer. */
        fun fromCode(code: String): WalErrorCode? = entries.firstOrNull { it.code == code }
    }
}

/**
 * A WAL failure reported by the Rust kernel through JNI.
 *
 * Same style as [WireException]: the native side throws
 * `java.lang.RuntimeException` with `"<CODE>: <detail>"`, and this class is the
 * typed form. A panic is not a WAL error and is translated to
 * [WirePanicException] instead.
 *
 * @property code the FFI code, for example `WAL_CORRUPT`; preserved verbatim
 *   even when [isKnownCode] is `false`.
 * @property detail the human-readable detail after the code.
 * @property knownCode the recognised [WalErrorCode], or `null` for an unknown
 *   code (a newer Rust table, or a non-WAL prefix that still parsed as a code).
 * @param cause the native `RuntimeException`.
 */
class WalException(
    val code: String,
    val detail: String,
    cause: Throwable? = null,
) : RuntimeException("$code: $detail", cause) {
    /** The recognised code entry, or `null` when [code] is not known here. */
    val knownCode: WalErrorCode? = WalErrorCode.fromCode(code)

    /** Whether [code] is in this binding's [WalErrorCode] table. */
    val isKnownCode: Boolean
        get() = knownCode != null
}
