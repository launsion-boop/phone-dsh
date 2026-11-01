// The Kotlin wire API: a typed facade over the Rust codec, no protocol logic.
// SPDX-License-Identifier: MIT

package com.phonedsh.wire

/**
 * The wire codec facade used by the channel layer.
 *
 * Every operation is executed by `pdsh-wire` through [NativeWire]; this object
 * only translates native failures into [WireException] / [WirePanicException].
 * There is no Kotlin frame layout, canonical JSON or CRC implementation here.
 *
 * ### Frame JSON
 *
 * [encode] takes the golden-vector JSON shape of `spec/v1/golden/README.md` §1:
 * a `fields` member plus a `type` (the `channel.md` §2 name) or a `type_byte`.
 * A whole golden vector file can be passed unmodified; its `seq`, `payload_hex`
 * and `frame_hex` members are ignored, and the `seq` argument is written into
 * the header. For a binary frame `fields` follows the member tables of
 * `golden/README.md` §3 (`data_hex`, `body_hex`, `record_hex`, …).
 *
 * [decode] returns only the canonical JSON of the `fields` member: the frame
 * type is already carried by the 16-byte header the caller received.
 */
object WireCodec {
    /** CRC-32C of [bytes] (the WAL and frame checksum of the phone-dsh spec). */
    fun crc32c(bytes: ByteArray): Int = translate("crc32c") { NativeWire.crc32c(bytes) }

    /**
     * Encodes one frame from golden-`fields` JSON and writes [seq] into the
     * header.
     *
     * @throws WireException a `channel.md` §10 error, for example
     *   `BAD_PAYLOAD` for malformed JSON or a bad `fields` member.
     * @throws WireUnavailable the native library is not available.
     */
    fun encode(frameJson: String, seq: Long): ByteArray =
        translate("encodeFrame") { NativeWire.encodeFrame(seq, frameJson) }

    /**
     * Decodes one complete frame and returns the canonical JSON of its
     * `fields`.
     *
     * @throws WireException a `channel.md` §10 error, for example
     *   `BAD_MAGIC` or `BAD_PAYLOAD`.
     * @throws WireUnavailable the native library is not available.
     */
    fun decode(bytes: ByteArray): String = translate("decodeFrame") { NativeWire.decodeFrame(bytes) }

    /**
     * Re-encodes [json] as canonical JSON (`channel.md` §5): sorted members, no
     * insignificant whitespace, literal non-ASCII, integers only.
     *
     * @throws WireException `BAD_PAYLOAD` for duplicates, non-integer numbers
     *   or malformed JSON.
     */
    fun canonicalJson(json: String): String =
        translate("canonicalJson") { NativeWire.canonicalJson(json) }

    private inline fun <T> translate(operation: String, block: () -> T): T =
        try {
            block()
        } catch (unavailable: WireUnavailable) {
            throw unavailable
        } catch (error: RuntimeException) {
            throw WireErrors.translate(operation, error)
        }
}

/**
 * Maps the native exception ABI to the typed Kotlin exceptions.
 *
 * The Rust side throws only `java.lang.RuntimeException` (no Kotlin class is
 * constructed across JNI, so R8 cannot break the error path):
 *
 * - `"CODE: detail"` with a `channel.md` §10 code → [WireException];
 * - `"PDSH_JNI_PANIC: <operation>: <detail>"` → [WirePanicException];
 * - anything else is a JNI-level failure and is rethrown unchanged.
 */
internal object WireErrors {
    private const val PANIC_PREFIX = "PDSH_JNI_PANIC: "
    private val WIRE_CODE = Regex("[A-Z][A-Z0-9_]*")

    fun translate(operation: String, error: RuntimeException): RuntimeException {
        val message = error.message ?: return error
        if (message.startsWith(PANIC_PREFIX)) {
            val rest = message.removePrefix(PANIC_PREFIX)
            val separator = rest.indexOf(": ")
            val detail = if (separator >= 0) rest.substring(separator + 2) else rest
            return WirePanicException(operation, detail, error)
        }
        val separator = message.indexOf(": ")
        if (separator <= 0) {
            return error
        }
        val code = message.substring(0, separator)
        if (!WIRE_CODE.matches(code)) {
            return error
        }
        return WireException(code, message.substring(separator + 2), error)
    }
}
