// Test-only reader for the golden frame vectors and the inline channel.md one.
// SPDX-License-Identifier: MIT

package com.phonedsh.wire

import java.io.File
import org.junit.Assert.assertEquals

/**
 * One golden frame vector (`spec/v1/golden/README.md` §1).
 *
 * @property document the golden file text, or the synthesized `{"type",
 *   "fields"}` document for the inline vector; this is what [WireCodec.encode]
 *   accepts.
 */
class GoldenVector(
    val name: String,
    val type: String,
    val typeByte: Int,
    val seq: Long,
    val fields: String,
    val payloadHex: String,
    val frameHex: String,
    val document: String,
) {
    override fun toString(): String = name
}

/**
 * The fixed golden corpus: 34 files of `spec/v1/golden/frames` plus the inline
 * `channel.md` §4.8 ERROR vector, 35 vectors in total.
 *
 * The file list is pinned, so a removed, renamed or extra vector fails the suite
 * instead of silently passing. The inline vector is verified against the text of
 * `channel.md` so it cannot drift either.
 */
internal object GoldenCorpus {
    const val EXPECTED_VECTOR_COUNT: Int = 35

    /** Every golden frame file, sorted; a missing or extra file fails. */
    val EXPECTED_FILES: List<String> = listOf(
        "api-abort-1.json",
        "api-end-1.json",
        "api-req-1.json",
        "api-res-1.json",
        "api-res-continuation-1.json",
        "api-res-empty-body-1.json",
        "console-1.json",
        "console-2.json",
        "error-1.json",
        "error-2.json",
        "error-3.json",
        "exec-ctl-1.json",
        "exec-ctl-2.json",
        "exec-evt-1.json",
        "exec-evt-2.json",
        "exec-req-1.json",
        "exec-req-2.json",
        "exec-req-3.json",
        "fence-1.json",
        "hello-host-1.json",
        "hello-worker-1.json",
        "journal-1.json",
        "journal-ack-1.json",
        "lifecycle-1.json",
        "vfs-ack-1.json",
        "vfs-ack-2.json",
        "vfs-barrier-1.json",
        "vfs-mut-append-1.json",
        "vfs-mut-binary-1.json",
        "vfs-mut-chmod-1.json",
        "vfs-mut-mkdir-1.json",
        "vfs-mut-remove-1.json",
        "vfs-mut-write-1.json",
        "vfs-resync-1.json",
    )

    private const val INLINE_NAME = "inline-channel-md-error-2"
    private const val INLINE_TYPE = "ERROR"
    private const val INLINE_TYPE_BYTE = 0x7F
    private const val INLINE_SEQ = 9L
    private const val INLINE_PAYLOAD_HEX =
        "7b22636f6465223a225646535f52454655534544222c226c696d6974223a31353732383634302c226d657373616765223a224546424947222c2270617468223a222f6473682f776f726b73706163652f61222c22726561736f6e223a2266696c652d746f6f2d6c61726765227d"
    private const val INLINE_FRAME_HEX =
        "5a4c7f0000000000000000090000006d7b22636f6465223a225646535f52454655534544222c226c696d6974223a31353732383634302c226d657373616765223a224546424947222c2270617468223a222f6473682f776f726b73706163652f61222c22726561736f6e223a2266696c652d746f6f2d6c61726765227d"
    private const val INLINE_FIELDS =
        "{\"code\":\"VFS_REFUSED\",\"limit\":15728640,\"message\":\"EFBIG\",\"path\":\"/dsh/workspace/a\",\"reason\":\"file-too-large\"}"

    /** The repository root, injected by Gradle as `pdsh.repo.root`. */
    private fun repoRoot(): File = File(
        System.getProperty("pdsh.repo.root")
            ?: error("pdsh.repo.root is not set; run the wire suite through Gradle"),
    )

    /** The `.json` files actually present in `spec/v1/golden/frames`, sorted. */
    fun filesOnDisk(): List<String> {
        val directory = File(repoRoot(), "spec/v1/golden/frames")
        check(directory.isDirectory) { "missing golden directory: ${directory.path}" }
        return directory.listFiles { file -> file.isFile && file.name.endsWith(".json") }
            ?.map { it.name }
            ?.sorted()
            ?: error("cannot list ${directory.path}")
    }

    /** Loads the 35 vectors, asserting the fixed file set and the count. */
    fun load(): List<GoldenVector> {
        val names = filesOnDisk()
        assertEquals("golden frame file set", EXPECTED_FILES, names)
        val directory = File(repoRoot(), "spec/v1/golden/frames")
        val vectors = names.map { name ->
            parseVector(name, File(directory, name).readText())
        }
        val all = vectors + inlineVector()
        assertEquals("golden frame vector count", EXPECTED_VECTOR_COUNT, all.size)
        return all
    }

    private fun parseVector(name: String, document: String): GoldenVector {
        val members = JsonMemberScanner(document).members()
        assertEquals("$name: golden members", 6, members.size)
        val type = unquote(members.getValue("type"))
        val typeByte = members.getValue("type_byte").trim().toInt()
        val seq = members.getValue("seq").trim().toLong()
        val fields = members.getValue("fields")
        val payloadHex = unquote(members.getValue("payload_hex"))
        val frameHex = unquote(members.getValue("frame_hex"))
        check(fields.startsWith("{")) { "$name: fields member is not an object" }
        check(payloadHex == frameHex.substring(32)) {
            "$name: payload_hex is not the tail of frame_hex"
        }
        return GoldenVector(name, type, typeByte, seq, fields, payloadHex, frameHex, document)
    }

    private fun inlineVector(): GoldenVector {
        val channel = File(repoRoot(), "spec/v1/channel.md").readText()
        check(channel.contains(INLINE_PAYLOAD_HEX)) {
            "channel.md §4.8 payload_hex drifted from the Kotlin suite"
        }
        check(channel.contains(INLINE_FRAME_HEX)) {
            "channel.md §4.8 frame_hex drifted from the Kotlin suite"
        }
        return GoldenVector(
            name = INLINE_NAME,
            type = INLINE_TYPE,
            typeByte = INLINE_TYPE_BYTE,
            seq = INLINE_SEQ,
            fields = INLINE_FIELDS,
            payloadHex = INLINE_PAYLOAD_HEX,
            frameHex = INLINE_FRAME_HEX,
            document = "{\"type\":\"$INLINE_TYPE\",\"fields\":$INLINE_FIELDS}",
        )
    }

    private fun unquote(value: String): String {
        check(value.length >= 2 && value.first() == '"' && value.last() == '"') {
            "not a JSON string member: $value"
        }
        check('\\' !in value) { "the golden scalar members must not need JSON escapes" }
        return value.substring(1, value.length - 1)
    }
}

/**
 * Minimal top-level member scanner for a golden file.
 *
 * It does not canonicalize or normalize anything: it only locates the six
 * top-level members so the test can feed the raw `fields` object to the Rust
 * codec. The JSON itself stays the Rust parser's job.
 */
private class JsonMemberScanner(private val text: String) {
    private var index: Int = 0

    fun members(): Map<String, String> {
        val members = LinkedHashMap<String, String>()
        skipWhitespace()
        check(index < text.length && text[index] == '{') { "golden document is not a JSON object" }
        index++
        skipWhitespace()
        if (index < text.length && text[index] == '}') {
            return members
        }
        while (true) {
            skipWhitespace()
            val key = parseString()
            skipWhitespace()
            check(index < text.length && text[index] == ':') { "expected ':' after $key" }
            index++
            skipWhitespace()
            val start = index
            skipValue()
            members[key] = text.substring(start, index).trim()
            skipWhitespace()
            check(index < text.length) { "unterminated golden object" }
            when (text[index]) {
                ',' -> index++
                '}' -> return members
                else -> error("unexpected ${text[index]} at $index")
            }
        }
    }

    private fun skipWhitespace() {
        while (index < text.length && text[index].isWhitespace()) {
            index++
        }
    }

    private fun parseString(): String {
        check(index < text.length && text[index] == '"') { "expected a JSON string at $index" }
        index++
        val out = StringBuilder()
        while (index < text.length) {
            when (val char = text[index++]) {
                '"' -> return out.toString()
                '\\' -> {
                    val escape = text[index++]
                    when (escape) {
                        '"' -> out.append('"')
                        '\\' -> out.append('\\')
                        '/' -> out.append('/')
                        'b' -> out.append('\b')
                        'f' -> out.append('\u000C')
                        'n' -> out.append('\n')
                        'r' -> out.append('\r')
                        't' -> out.append('\t')
                        'u' -> {
                            out.append(text.substring(index, index + 4).toInt(16).toChar())
                            index += 4
                        }
                        else -> error("unsupported JSON escape \\$escape")
                    }
                }
                else -> out.append(char)
            }
        }
        error("unterminated JSON string")
    }

    private fun skipValue() {
        check(index < text.length) { "missing JSON value" }
        when (text[index]) {
            '"' -> parseString()
            '{', '[' -> {
                var depth = 0
                var inString = false
                while (index < text.length) {
                    val char = text[index]
                    if (inString) {
                        if (char == '\\') {
                            index += 2
                            continue
                        }
                        if (char == '"') {
                            inString = false
                        }
                    } else {
                        when (char) {
                            '"' -> inString = true
                            '{', '[' -> depth++
                            '}', ']' -> {
                                depth--
                                if (depth == 0) {
                                    index++
                                    return
                                }
                            }
                        }
                    }
                    index++
                }
                error("unterminated JSON value")
            }
            else -> {
                while (index < text.length && text[index] != ',' && text[index] != '}') {
                    index++
                }
            }
        }
    }
}

/** Decodes lowercase hex for test inputs; the codec itself takes bytes. */
internal fun hexToBytes(hex: String): ByteArray {
    require(hex.length % 2 == 0) { "odd hex length: ${hex.length}" }
    return ByteArray(hex.length / 2) { position ->
        hex.substring(position * 2, position * 2 + 2).toInt(16).toByte()
    }
}

/** Lowercase hex of [bytes], for assertions against `*_hex` members. */
internal fun bytesToHex(bytes: ByteArray): String {
    val out = StringBuilder(bytes.size * 2)
    for (byte in bytes) {
        val value = byte.toInt() and 0xFF
        out.append(HEX_DIGITS[value ushr 4])
        out.append(HEX_DIGITS[value and 0x0F])
    }
    return out.toString()
}

private const val HEX_DIGITS = "0123456789abcdef"
