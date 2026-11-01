// Host contract 1 — dependency-free JSON values for tool arguments and codecs.
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

import java.math.BigDecimal

/**
 * A JSON value; treat instances as immutable.
 *
 * `tool_call.arguments` is arbitrary JSON, so the host contract cannot type it;
 * the same value type backs the decoder helpers in [HarnessJson] and the DSH
 * cancel-cause projection in [AgentCancelCause.toDshCause]. Numbers keep their
 * source lexeme so an integer seq or token count never loses precision.
 *
 * This is a *value* type, not a schema validator: members the schemas do not
 * define are ignored by [HarnessJson], never rejected by [JsonValue].
 */
public sealed interface JsonValue {
    public companion object {
        /** Parses one JSON document (object, array or scalar) with no trailing garbage. */
        public fun parse(text: String): JsonValue = JsonParser(text).parseDocument()
    }
}

/** JSON `null`. */
public data object JsonNull : JsonValue

/** A JSON boolean. */
public data class JsonBool(public val value: Boolean) : JsonValue

/**
 * A JSON number, kept as its exact source lexeme.
 *
 * [asLongOrNull] accepts only integer-valued numbers that fit in a `Long`
 * (`1e3` is accepted, `1.5` is not).
 */
public data class JsonNumber(public val raw: String) : JsonValue {
    init {
        require(NUMBER_PATTERN.matches(raw)) { "invalid JSON number lexeme: $raw" }
    }

    /** The value as a `Long` when it is integer-valued and in range, else `null`. */
    public fun asLongOrNull(): Long? = try {
        if (raw.indexOf('.') >= 0 || raw.indexOf('e') >= 0 || raw.indexOf('E') >= 0) {
            BigDecimal(raw).longValueExact()
        } else {
            raw.toLongOrNull()
        }
    } catch (_: ArithmeticException) {
        null
    } catch (_: NumberFormatException) {
        null
    }

    private companion object {
        private val NUMBER_PATTERN = Regex("-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")
    }
}

/** A JSON string. */
public data class JsonString(public val value: String) : JsonValue

/** A JSON array. */
public data class JsonArray(public val values: List<JsonValue>) : JsonValue

/** A JSON object; member order is preserved for stable encoders. */
public data class JsonObject(public val members: Map<String, JsonValue>) : JsonValue {
    /** Returns the member named [key], or `null` when absent (a present JSON `null` is [JsonNull]). */
    public operator fun get(key: String): JsonValue? = members[key]
}

/** Encodes this value as compact JSON (no insignificant whitespace). */
public fun JsonValue.toJsonString(): String {
    val out = StringBuilder()
    JsonWriter.write(this, out)
    return out.toString()
}

/** A recursive-descent parser for RFC 8259 JSON with a nesting bound. */
internal class JsonParser(private val text: String) {
    private var index: Int = 0

    fun parseDocument(): JsonValue {
        skipWhitespace()
        val value = parseValue(0)
        skipWhitespace()
        if (index != text.length) {
            fail("trailing characters at offset $index")
        }
        return value
    }

    private fun parseValue(depth: Int): JsonValue {
        if (depth > MAX_DEPTH) {
            fail("nesting deeper than $MAX_DEPTH")
        }
        skipWhitespace()
        if (index >= text.length) {
            fail("unexpected end of input")
        }
        return when (val char = text[index]) {
            '{' -> parseObject(depth)
            '[' -> parseArray(depth)
            '"' -> JsonString(parseString())
            't' -> {
                expect("true")
                JsonBool(true)
            }
            'f' -> {
                expect("false")
                JsonBool(false)
            }
            'n' -> {
                expect("null")
                JsonNull
            }
            else -> if (char == '-' || char in '0'..'9') parseNumber() else fail("unexpected character '$char' at offset $index")
        }
    }

    private fun parseObject(depth: Int): JsonObject {
        expect('{')
        skipWhitespace()
        val members = LinkedHashMap<String, JsonValue>()
        if (peek('}')) {
            index++
            return JsonObject(members)
        }
        while (true) {
            skipWhitespace()
            if (!peek('"')) {
                fail("expected a member name at offset $index")
            }
            val key = parseString()
            skipWhitespace()
            expect(':')
            skipWhitespace()
            members[key] = parseValue(depth + 1)
            skipWhitespace()
            when {
                peek(',') -> index++
                peek('}') -> {
                    index++
                    return JsonObject(members)
                }
                else -> fail("expected ',' or '}' at offset $index")
            }
        }
    }

    private fun parseArray(depth: Int): JsonArray {
        expect('[')
        skipWhitespace()
        val values = ArrayList<JsonValue>()
        if (peek(']')) {
            index++
            return JsonArray(values)
        }
        while (true) {
            values += parseValue(depth + 1)
            skipWhitespace()
            when {
                peek(',') -> index++
                peek(']') -> {
                    index++
                    return JsonArray(values)
                }
                else -> fail("expected ',' or ']' at offset $index")
            }
        }
    }

    private fun parseString(): String {
        expect('"')
        val out = StringBuilder()
        while (true) {
            if (index >= text.length) {
                fail("unterminated string")
            }
            val char = text[index++]
            when {
                char == '"' -> return out.toString()
                char == '\\' -> {
                    if (index >= text.length) {
                        fail("unterminated escape")
                    }
                    when (val escape = text[index++]) {
                        '"' -> out.append('"')
                        '\\' -> out.append('\\')
                        '/' -> out.append('/')
                        'b' -> out.append('\b')
                        'f' -> out.append('\u000C')
                        'n' -> out.append('\n')
                        'r' -> out.append('\r')
                        't' -> out.append('\t')
                        'u' -> {
                            if (index + 4 > text.length) {
                                fail("short unicode escape at offset $index")
                            }
                            val hex = text.substring(index, index + 4)
                            val code = hex.toIntOrNull(16) ?: fail("bad unicode escape '\\u$hex'")
                            index += 4
                            out.append(code.toChar())
                        }
                        else -> fail("bad escape '\\$escape' at offset ${index - 1}")
                    }
                }
                char < ' ' -> fail("unescaped control character at offset ${index - 1}")
                else -> out.append(char)
            }
        }
    }

    private fun parseNumber(): JsonNumber {
        val start = index
        if (peek('-')) {
            index++
        }
        if (index >= text.length) {
            fail("unexpected end in number")
        }
        if (peek('0')) {
            index++
        } else {
            if (text[index] !in '1'..'9') {
                fail("invalid number at offset $index")
            }
            while (index < text.length && text[index] in '0'..'9') {
                index++
            }
        }
        if (index < text.length && text[index] == '.') {
            index++
            if (index >= text.length || text[index] !in '0'..'9') {
                fail("invalid fraction at offset $index")
            }
            while (index < text.length && text[index] in '0'..'9') {
                index++
            }
        }
        if (index < text.length && (text[index] == 'e' || text[index] == 'E')) {
            index++
            if (index < text.length && (text[index] == '+' || text[index] == '-')) {
                index++
            }
            if (index >= text.length || text[index] !in '0'..'9') {
                fail("invalid exponent at offset $index")
            }
            while (index < text.length && text[index] in '0'..'9') {
                index++
            }
        }
        return JsonNumber(text.substring(start, index))
    }

    private fun skipWhitespace() {
        while (index < text.length) {
            when (text[index]) {
                ' ', '\t', '\n', '\r' -> index++
                else -> return
            }
        }
    }

    private fun expect(expected: String) {
        if (!text.startsWith(expected, index)) {
            fail("expected '$expected' at offset $index")
        }
        index += expected.length
    }

    private fun expect(expected: Char) {
        if (index >= text.length || text[index] != expected) {
            fail("expected '$expected' at offset $index")
        }
        index++
    }

    private fun peek(expected: Char): Boolean = index < text.length && text[index] == expected

    private fun fail(message: String): Nothing = throw HarnessDecodingException("json", message)

    private companion object {
        private const val MAX_DEPTH = 256
    }
}

/** Serializes values deterministically enough for golden comparison (member order preserved). */
internal object JsonWriter {
    fun write(value: JsonValue, out: StringBuilder) {
        when (value) {
            is JsonNull -> out.append("null")
            is JsonBool -> out.append(if (value.value) "true" else "false")
            is JsonNumber -> out.append(value.raw)
            is JsonString -> writeString(value.value, out)
            is JsonArray -> {
                out.append('[')
                value.values.forEachIndexed { index, item ->
                    if (index > 0) out.append(',')
                    write(item, out)
                }
                out.append(']')
            }
            is JsonObject -> {
                out.append('{')
                var first = true
                for ((key, member) in value.members) {
                    if (!first) out.append(',')
                    first = false
                    writeString(key, out)
                    out.append(':')
                    write(member, out)
                }
                out.append('}')
            }
        }
    }

    private fun writeString(value: String, out: StringBuilder) {
        out.append('"')
        for (char in value) {
            when (char) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                else -> if (char < ' ') {
                    out.append("\\u")
                    out.append(char.code.toString(16).padStart(4, '0'))
                } else {
                    out.append(char)
                }
            }
        }
        out.append('"')
    }
}
