// SPDX-License-Identifier: MIT
// PCLink v1 strict JSON value, parser and canonical encoder (§2.3).
//
// The contract requires a closed decoder: exactly one UTF-8 object, no BOM, no
// leading/trailing bytes, no duplicate member names at any depth, no literal NUL
// byte, no unpaired surrogates, no NaN/Infinity and no non-object root for wire
// frames. A legal escaped `\u0000` inside a string is JSON data and is preserved;
// only PCLink-owned fields reject the decoded U+0000 under their own field rule.
// `org.json`/kotlinx.serialization accept duplicate keys and do not produce the
// scalar-ordered canonical form used by the pairing MACs, so this module carries
// its own byte parser and encoder.
package com.phonedsh.pclink

/** One PCLink JSON value; integers keep their exact Long value. */
sealed interface PclinkJson {
    data object Null : PclinkJson
    data class Bool(val value: Boolean) : PclinkJson
    data class Integer(val value: Long) : PclinkJson
    data class Decimal(val value: Double) : PclinkJson
    data class Text(val value: String) : PclinkJson
    data class Array(val values: List<PclinkJson>) : PclinkJson
    data class Object(val members: Map<String, PclinkJson>) : PclinkJson

    val objectValue: Map<String, PclinkJson>? get() = (this as? Object)?.members
    val arrayValue: List<PclinkJson>? get() = (this as? Array)?.values
    val stringValue: String? get() = (this as? Text)?.value
    val longValue: Long? get() = (this as? Integer)?.value
    val boolValue: Boolean? get() = (this as? Bool)?.value
    val doubleValue: Double?
        get() = when (this) {
            is Decimal -> value
            is Integer -> value.toDouble()
            else -> null
        }

    operator fun get(key: String): PclinkJson? = objectValue?.get(key)
}

/** Builds an object literal with ordered members. */
fun pclinkObject(vararg members: Pair<String, PclinkJson>): PclinkJson =
    PclinkJson.Object(linkedMapOf(*members))

/** Strict parser. All failures are `bad_frame` (§2.3). */
object PclinkJsonParser {
    private const val MAX_DEPTH = 512

    /** Parses exactly one value with no BOM and no leading/trailing bytes. */
    fun parse(bytes: ByteArray): PclinkJson {
        if (bytes.isEmpty()) throw badFrame("empty JSON")
        rejectBom(bytes)
        if (isWhitespace(bytes[0])) throw badFrame("JSON has leading bytes")
        val parser = Parser(bytes)
        val value = parser.parseValue(0)
        if (parser.offset != bytes.size) {
            if (isWhitespace(bytes[parser.offset])) throw badFrame("JSON has trailing bytes")
            throw badFrame("JSON has trailing content at byte ${parser.offset}")
        }
        return value
    }

    fun parse(text: String): PclinkJson = parse(text.toByteArray(Charsets.UTF_8))

    /** Parses an object with no BOM and no leading/trailing bytes (a wire frame). */
    fun parseObject(bytes: ByteArray): PclinkJson = requireObject(parse(bytes))

    fun parseObject(text: String): PclinkJson = requireObject(parse(text))

    /**
     * Parses one document value from a fixture/configuration file, allowing
     * insignificant leading/trailing whitespace. Wire frames use [parse].
     */
    fun parseDocument(bytes: ByteArray): PclinkJson {
        if (bytes.isEmpty()) throw badFrame("empty JSON")
        rejectBom(bytes)
        val parser = Parser(bytes)
        parser.skipWhitespace()
        val value = parser.parseValue(0)
        parser.skipWhitespace()
        if (parser.offset != bytes.size) throw badFrame("JSON has trailing content")
        return value
    }

    fun parseDocument(text: String): PclinkJson = parseDocument(text.toByteArray(Charsets.UTF_8))

    fun parseDocumentObject(bytes: ByteArray): PclinkJson = requireObject(parseDocument(bytes))

    fun parseDocumentObject(text: String): PclinkJson = requireObject(parseDocument(text))

    private fun requireObject(value: PclinkJson): PclinkJson {
        if (value !is PclinkJson.Object) throw badFrame("JSON root is not an object")
        return value
    }

    private fun rejectBom(bytes: ByteArray) {
        if (bytes.size >= 3 &&
            bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()
        ) {
            throw badFrame("JSON starts with a byte-order mark")
        }
    }

    private fun isWhitespace(byte: Byte): Boolean =
        byte == 0x20.toByte() || byte == 0x09.toByte() ||
            byte == 0x0A.toByte() || byte == 0x0D.toByte()

    private fun badFrame(message: String): PclinkError = PclinkError.BadFrame(message)

    private class Parser(private val bytes: ByteArray) {
        var offset: Int = 0

        fun skipWhitespace() {
            while (offset < bytes.size && isWhitespace(bytes[offset])) offset++
        }

        fun parseValue(depth: Int): PclinkJson {
            if (depth > MAX_DEPTH) throw badFrame("JSON nesting is too deep")
            skipWhitespace()
            if (offset >= bytes.size) throw badFrame("JSON ended unexpectedly")
            return when (bytes[offset].toInt() and 0xFF) {
                0x7B -> parseObject(depth)
                0x5B -> parseArray(depth)
                0x22 -> PclinkJson.Text(parseString())
                0x74 -> { expect("true"); PclinkJson.Bool(true) }
                0x66 -> { expect("false"); PclinkJson.Bool(false) }
                0x6E -> { expect("null"); PclinkJson.Null }
                0x2D, in 0x30..0x39 -> parseNumber()
                else -> throw badFrame("unexpected JSON character at byte $offset")
            }
        }

        private fun expect(literal: String) {
            for (expected in literal.toByteArray(Charsets.US_ASCII)) {
                if (offset >= bytes.size || bytes[offset] != expected) {
                    throw badFrame("expected JSON literal '$literal' at byte $offset")
                }
                offset++
            }
        }

        private fun parseObject(depth: Int): PclinkJson {
            offset++ // {
            val members = LinkedHashMap<String, PclinkJson>()
            val names = HashSet<String>()
            skipWhitespace()
            if (offset < bytes.size && bytes[offset] == 0x7D.toByte()) {
                offset++
                return PclinkJson.Object(members)
            }
            while (true) {
                skipWhitespace()
                if (offset >= bytes.size || bytes[offset] != 0x22.toByte()) {
                    throw badFrame("expected a JSON member name at byte $offset")
                }
                // Duplicate members are compared as decoded Unicode scalar
                // sequences: "a" and "\u0061" are the same member. A Kotlin
                // String comparison is the decoded UTF-16 sequence, which is the
                // same distinction the contract makes (surrogates are rejected).
                val key = parseString()
                if (!names.add(key)) throw badFrame("duplicate JSON member $key")
                skipWhitespace()
                if (offset >= bytes.size || bytes[offset] != 0x3A.toByte()) {
                    throw badFrame("expected ':' at byte $offset")
                }
                offset++
                members[key] = parseValue(depth + 1)
                skipWhitespace()
                if (offset >= bytes.size) throw badFrame("JSON ended unexpectedly")
                when (bytes[offset]) {
                    0x2C.toByte() -> {
                        offset++
                        skipWhitespace()
                        if (offset < bytes.size && bytes[offset] == 0x7D.toByte()) {
                            throw badFrame("trailing comma in JSON object at byte $offset")
                        }
                    }
                    0x7D.toByte() -> {
                        offset++
                        return PclinkJson.Object(members)
                    }
                    else -> throw badFrame("expected ',' or '}' at byte $offset")
                }
            }
        }

        private fun parseArray(depth: Int): PclinkJson {
            offset++ // [
            val values = ArrayList<PclinkJson>()
            skipWhitespace()
            if (offset < bytes.size && bytes[offset] == 0x5D.toByte()) {
                offset++
                return PclinkJson.Array(values)
            }
            while (true) {
                values.add(parseValue(depth + 1))
                skipWhitespace()
                if (offset >= bytes.size) throw badFrame("JSON ended unexpectedly")
                when (bytes[offset]) {
                    0x2C.toByte() -> {
                        offset++
                        skipWhitespace()
                        if (offset < bytes.size && bytes[offset] == 0x5D.toByte()) {
                            throw badFrame("trailing comma in JSON array at byte $offset")
                        }
                    }
                    0x5D.toByte() -> {
                        offset++
                        return PclinkJson.Array(values)
                    }
                    else -> throw badFrame("expected ',' or ']' at byte $offset")
                }
            }
        }

        private fun parseString(): String {
            offset++ // opening quote
            val out = StringBuilder()
            while (true) {
                if (offset >= bytes.size) throw badFrame("unterminated JSON string")
                val byte = bytes[offset].toInt() and 0xFF
                when {
                    byte == 0x22 -> {
                        offset++
                        return out.toString()
                    }
                    byte == 0x5C -> {
                        offset++
                        parseEscape(out)
                    }
                    // A literal C0 control byte inside a string is invalid JSON.
                    // U+007F and the C1 range are not C0 and may appear literally
                    // (a DSH serializer may emit them unescaped).
                    byte < 0x20 -> throw badFrame("unescaped control character in JSON string")
                    byte < 0x80 -> {
                        out.append(byte.toChar())
                        offset++
                    }
                    else -> out.appendCodePoint(decodeUtf8Scalar())
                }
            }
        }

        private fun parseEscape(out: StringBuilder) {
            if (offset >= bytes.size) throw badFrame("unterminated JSON escape")
            val escape = bytes[offset].toInt() and 0xFF
            offset++
            when (escape) {
                0x22 -> out.append('"')
                0x5C -> out.append('\\')
                0x2F -> out.append('/')
                0x62 -> out.append('\b')
                0x66 -> out.append('\u000C')
                0x6E -> out.append('\n')
                0x72 -> out.append('\r')
                0x74 -> out.append('\t')
                0x75 -> appendUnicodeEscape(out)
                else -> throw badFrame("invalid JSON escape")
            }
        }

        private fun appendUnicodeEscape(out: StringBuilder) {
            val first = parseHex4()
            if (first in 0xD800..0xDBFF) {
                if (offset + 1 >= bytes.size ||
                    bytes[offset] != 0x5C.toByte() || bytes[offset + 1] != 0x75.toByte()
                ) {
                    throw badFrame("unpaired JSON surrogate")
                }
                offset += 2
                val second = parseHex4()
                if (second !in 0xDC00..0xDFFF) throw badFrame("unpaired JSON surrogate")
                val codePoint = 0x10000 + ((first - 0xD800) shl 10) + (second - 0xDC00)
                out.appendCodePoint(codePoint)
                return
            }
            if (first in 0xDC00..0xDFFF) throw badFrame("unpaired JSON surrogate")
            out.append(first.toChar())
        }

        private fun parseHex4(): Int {
            if (offset + 4 > bytes.size) throw badFrame("short JSON unicode escape")
            var value = 0
            repeat(4) {
                val byte = bytes[offset].toInt() and 0xFF
                offset++
                val digit = when (byte) {
                    in 0x30..0x39 -> byte - 0x30
                    in 0x61..0x66 -> byte - 0x61 + 10
                    in 0x41..0x46 -> byte - 0x41 + 10
                    else -> throw badFrame("invalid JSON unicode escape")
                }
                value = (value shl 4) or digit
            }
            return value
        }

        /**
         * Decodes one complete strict UTF-8 scalar at [offset] (which is >= 0x80)
         * and advances past it. Overlong forms, encoded surrogates and code
         * points above U+10FFFF are rejected.
         */
        private fun decodeUtf8Scalar(): Int {
            val first = bytes[offset].toInt() and 0xFF
            val length: Int
            var codePoint: Int
            when {
                first and 0xE0 == 0xC0 -> {
                    length = 2
                    codePoint = first and 0x1F
                }
                first and 0xF0 == 0xE0 -> {
                    length = 3
                    codePoint = first and 0x0F
                }
                first and 0xF8 == 0xF0 -> {
                    length = 4
                    codePoint = first and 0x07
                }
                else -> throw badFrame("invalid UTF-8 in JSON")
            }
            if (offset + length > bytes.size) throw badFrame("truncated UTF-8 in JSON")
            for (index in 1 until length) {
                val byte = bytes[offset + index].toInt() and 0xFF
                if (byte and 0xC0 != 0x80) throw badFrame("invalid UTF-8 in JSON")
                codePoint = (codePoint shl 6) or (byte and 0x3F)
            }
            val minimum = when (length) {
                2 -> 0x80
                3 -> 0x800
                else -> 0x10000
            }
            if (codePoint < minimum || codePoint > 0x10FFFF) throw badFrame("invalid UTF-8 in JSON")
            if (codePoint in 0xD800..0xDFFF) throw badFrame("invalid UTF-8 in JSON")
            offset += length
            return codePoint
        }

        private fun parseNumber(): PclinkJson {
            val start = offset
            if (bytes[offset] == 0x2D.toByte()) {
                offset++
                if (offset >= bytes.size) throw badFrame("invalid JSON number")
            }
            if (offset >= bytes.size) throw badFrame("invalid JSON number")
            if (bytes[offset] == 0x30.toByte()) {
                offset++
                if (offset < bytes.size && bytes[offset] in 0x30.toByte()..0x39.toByte()) {
                    throw badFrame("leading zero in JSON number")
                }
            } else if (bytes[offset] in 0x31.toByte()..0x39.toByte()) {
                while (offset < bytes.size && bytes[offset] in 0x30.toByte()..0x39.toByte()) offset++
            } else {
                throw badFrame("invalid JSON number")
            }
            var isInteger = true
            if (offset < bytes.size && bytes[offset] == 0x2E.toByte()) {
                isInteger = false
                offset++
                val digitsStart = offset
                while (offset < bytes.size && bytes[offset] in 0x30.toByte()..0x39.toByte()) offset++
                if (offset == digitsStart) throw badFrame("invalid JSON fraction")
            }
            if (offset < bytes.size &&
                (bytes[offset] == 0x65.toByte() || bytes[offset] == 0x45.toByte())
            ) {
                isInteger = false
                offset++
                if (offset < bytes.size &&
                    (bytes[offset] == 0x2B.toByte() || bytes[offset] == 0x2D.toByte())
                ) {
                    offset++
                }
                val digitsStart = offset
                while (offset < bytes.size && bytes[offset] in 0x30.toByte()..0x39.toByte()) offset++
                if (offset == digitsStart) throw badFrame("invalid JSON exponent")
            }
            val text = String(bytes, start, offset - start, Charsets.US_ASCII)
            if (isInteger) {
                text.toLongOrNull()?.let { return PclinkJson.Integer(it) }
            }
            val value = text.toDoubleOrNull()
            if (value == null || !value.isFinite()) throw badFrame("JSON number out of range")
            return PclinkJson.Decimal(value)
        }
    }
}

/** Canonical / compact JSON encoding (§2.3). */
object PclinkJsonEncoder {
    /**
     * Canonical JSON used by the pairing MACs: keys sorted ascending by Unicode
     * scalar value (the same order as UTF-8 bytes, not Kotlin's UTF-16
     * `String.compareTo`), no insignificant whitespace, `/` and non-ASCII
     * literal, lowercase short control escapes and no lone surrogates.
     */
    fun canonical(value: PclinkJson): ByteArray = encodeValue(value).toByteArray(Charsets.UTF_8)

    fun canonicalString(value: PclinkJson): String = encodeValue(value)

    /** Compact wire JSON; also canonical (sorted keys, literal `/`). */
    fun encode(value: PclinkJson): ByteArray = encodeValue(value).toByteArray(Charsets.UTF_8)

    fun encodeString(value: PclinkJson): String = encodeValue(value)

    private val hexDigits = "0123456789abcdef"

    private fun encodeValue(root: PclinkJson): String {
        val out = StringBuilder()
        append(root, out, 0)
        return out.toString()
    }

    private fun append(value: PclinkJson, out: StringBuilder, depth: Int) {
        if (depth > 512) throw PclinkError.BadFrame("JSON nesting is too deep")
        when (value) {
            is PclinkJson.Null -> out.append("null")
            is PclinkJson.Bool -> out.append(if (value.value) "true" else "false")
            is PclinkJson.Integer -> out.append(value.value)
            is PclinkJson.Decimal -> {
                if (!value.value.isFinite()) throw PclinkError.BadFrame("non-finite JSON number")
                // PCLink-owned canonical objects only carry integers and strings;
                // a decimal can only appear inside a DSH passthrough value, which
                // is never MACed. Keep the JVM spelling stable and finite.
                out.append(if (value.value == 0.0) "0" else value.value.toString())
            }
            is PclinkJson.Text -> appendString(value.value, out)
            is PclinkJson.Array -> {
                out.append('[')
                value.values.forEachIndexed { index, item ->
                    if (index > 0) out.append(',')
                    append(item, out, depth + 1)
                }
                out.append(']')
            }
            is PclinkJson.Object -> {
                out.append('{')
                val keys = value.members.keys.sortedWith(SCALAR_ORDER)
                keys.forEachIndexed { index, key ->
                    if (index > 0) out.append(',')
                    appendString(key, out)
                    out.append(':')
                    append(value.members.getValue(key), out, depth + 1)
                }
                out.append('}')
            }
        }
    }

    private fun appendString(value: String, out: StringBuilder) {
        out.append('"')
        var index = 0
        while (index < value.length) {
            val codePoint = value.codePointAt(index)
            when {
                codePoint == 0x22 -> out.append("\\\"")
                codePoint == 0x5C -> out.append("\\\\")
                codePoint == 0x08 -> out.append("\\b")
                codePoint == 0x09 -> out.append("\\t")
                codePoint == 0x0A -> out.append("\\n")
                codePoint == 0x0C -> out.append("\\f")
                codePoint == 0x0D -> out.append("\\r")
                codePoint in 0x00..0x1F -> {
                    // U+0000 has no short form and is always the lowercase
                    // six-character escape; the rest use lowercase \u00xx.
                    out.append("\\u")
                    out.append(hexDigits[(codePoint shr 12) and 0xF])
                    out.append(hexDigits[(codePoint shr 8) and 0xF])
                    out.append(hexDigits[(codePoint shr 4) and 0xF])
                    out.append(hexDigits[codePoint and 0xF])
                }
                codePoint in 0xD800..0xDFFF -> throw PclinkError.BadFrame("lone JSON surrogate")
                else -> out.appendCodePoint(codePoint)
            }
            index += Character.charCount(codePoint)
        }
        out.append('"')
    }

    /** Ascending Unicode scalar value == UTF-8 byte lexicographic order. */
    private val SCALAR_ORDER = Comparator<String> { left, right ->
        var i = 0
        var j = 0
        while (i < left.length && j < right.length) {
            val a = left.codePointAt(i)
            val b = right.codePointAt(j)
            if (a != b) return@Comparator a.compareTo(b)
            i += Character.charCount(a)
            j += Character.charCount(b)
        }
        when {
            i < left.length -> 1
            j < right.length -> -1
            else -> 0
        }
    }
}

/**
 * Requires an object whose members are exactly [required] plus [optional].
 * Unknown members are `bad_frame` (§2.3).
 */
fun PclinkJson.closedObject(
    required: Set<String>,
    optional: Set<String> = emptySet(),
): Map<String, PclinkJson> {
    val members = objectValue ?: throw PclinkError.BadFrame("expected a JSON object")
    for (key in members.keys) {
        if (key !in required && key !in optional) {
            throw PclinkError.BadFrame("unknown member $key")
        }
    }
    for (key in required) {
        if (key !in members) throw PclinkError.BadFrame("missing member $key")
    }
    return members
}

fun PclinkJson.requiredString(key: String): String =
    this[key]?.stringValue ?: throw PclinkError.BadFrame("$key must be a string")

fun PclinkJson.requiredLong(key: String): Long =
    this[key]?.longValue ?: throw PclinkError.BadFrame("$key must be an integer")

fun PclinkJson.requiredBool(key: String): Boolean =
    this[key]?.boolValue ?: throw PclinkError.BadFrame("$key must be a boolean")
