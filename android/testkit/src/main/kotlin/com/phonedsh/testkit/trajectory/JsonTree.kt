// :testkit trajectory — the mutable JSON tree the five stages operate on, and its canonical bytes.
// SPDX-License-Identifier: MIT
package com.phonedsh.testkit.trajectory

import com.phonedsh.agentcore.HarnessDecodingException
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import java.math.BigInteger

/**
 * The internal tree. `:core`'s `JsonValue.parse` is the only parser; this tree exists because
 * the pipeline mutates rows in place and because Python's `json` distinguishes an integer from
 * a float while `JsonValue` keeps only the source lexeme.
 */
internal sealed interface JsonTree

internal class JsonObjectTree(val members: LinkedHashMap<String, JsonTree>) : JsonTree {
    operator fun get(name: String): JsonTree? = members[name]

    fun string(name: String): String? = (members[name] as? JsonStringTree)?.value

    fun integer(name: String): BigInteger? =
        ((members[name] as? JsonNumberTree)?.value as? JsonNum.IntValue)?.value

    fun remove(name: String): JsonTree? = members.remove(name)
}

internal class JsonArrayTree(val items: MutableList<JsonTree>) : JsonTree

internal data class JsonStringTree(val value: String) : JsonTree

internal data class JsonNumberTree(val value: JsonNum) : JsonTree

internal data class JsonBoolTree(val value: Boolean) : JsonTree

internal object JsonNullTree : JsonTree

/** Python's `int` / `float` split; `1` and `1.0` are different kinds and print differently. */
internal sealed interface JsonNum {
    class IntValue(val value: BigInteger) : JsonNum
    class FloatValue(val value: Double) : JsonNum
}

/**
 * Parses one JSON document with `:core`'s dependency-free `JsonValue.parse`, rejects duplicate
 * member names (Python's `object_pairs_hook` does), and converts the value into [JsonTree].
 *
 * The duplicate scan cannot be delegated to `JsonValue` (its object map is last-wins), so a
 * second lightweight structural walk over the already-validated text collects every object's
 * member names. It runs on valid JSON only; the value parser has already rejected malformed
 * input, so the walk only needs structure, strings and separators.
 */
internal object JsonTreeCodec {
    fun parseDocument(text: String, where: String): JsonTree {
        val value = try {
            JsonValue.parse(text)
        } catch (failure: HarnessDecodingException) {
            throw NormError("BAD_JSON", where, failure.message ?: "invalid JSON", failure)
        }
        DuplicateMemberCheck.check(text, where)
        return fromJsonValue(value)
    }

    /** Serializes one row exactly as `json.dumps(..., ensure_ascii=False, sort_keys=True)`. */
    fun canonicalLine(tree: JsonTree, where: String): String {
        val out = StringBuilder()
        write(tree, out)
        val line = out.toString()
        if (line.contains('\n') || line.contains('\r')) {
            throw NormError("OUTPUT", where, "canonical line contains a raw newline")
        }
        return line
    }

    private fun fromJsonValue(value: JsonValue): JsonTree = when (value) {
        is JsonNull -> JsonNullTree
        is JsonBool -> JsonBoolTree(value.value)
        is JsonString -> JsonStringTree(value.value)
        is JsonNumber -> JsonNumberTree(numberOf(value.raw))
        is JsonArray -> {
            val items = ArrayList<JsonTree>(value.values.size)
            for (item in value.values) items += fromJsonValue(item)
            JsonArrayTree(items)
        }
        is JsonObject -> {
            val members = LinkedHashMap<String, JsonTree>(value.members.size)
            for ((name, member) in value.members) members[name] = fromJsonValue(member)
            JsonObjectTree(members)
        }
    }

    private fun numberOf(raw: String): JsonNum =
        if (raw.indexOf('.') >= 0 || raw.indexOf('e') >= 0 || raw.indexOf('E') >= 0) {
            JsonNum.FloatValue(raw.toDouble())
        } else {
            JsonNum.IntValue(BigInteger(raw))
        }

    private fun write(value: JsonTree, out: StringBuilder) {
        when (value) {
            is JsonNullTree -> out.append("null")
            is JsonBoolTree -> out.append(if (value.value) "true" else "false")
            is JsonStringTree -> writeString(value.value, out)
            is JsonNumberTree -> when (val number = value.value) {
                is JsonNum.IntValue -> out.append(number.value.toString())
                is JsonNum.FloatValue -> {
                    if (!number.value.isFinite()) {
                        throw NormError("OUTPUT", "row", "non-finite number cannot be serialized")
                    }
                    out.append(PythonSemantics.floatRepr(number.value))
                }
            }
            is JsonArrayTree -> {
                out.append('[')
                for ((index, item) in value.items.withIndex()) {
                    if (index > 0) out.append(',')
                    write(item, out)
                }
                out.append(']')
            }
            is JsonObjectTree -> {
                out.append('{')
                val names = value.members.keys.sortedWith(Comparator { left, right ->
                    PythonSemantics.compareCodePoints(left, right)
                })
                for ((index, name) in names.withIndex()) {
                    if (index > 0) out.append(',')
                    writeString(name, out)
                    out.append(':')
                    write(value.members.getValue(name), out)
                }
                out.append('}')
            }
        }
    }

    /** Python's `json` string escape with `ensure_ascii=False`: only controls, `"` and `\`. */
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

/** Rejects a JSON document that declares the same member twice, at any object depth. */
private object DuplicateMemberCheck {
    fun check(text: String, where: String) {
        val scanner = Scanner(text, where)
        scanner.value(scanner.skipWhitespace(0))
    }

    private class Scanner(private val text: String, private val where: String) {
        fun value(start: Int): Int {
            val index = skipWhitespace(start)
            if (index >= text.length) fail("unexpected end of input")
            return when (text[index]) {
                '{' -> obj(index)
                '[' -> array(index)
                '"' -> string(index).second
                else -> scalar(index)
            }
        }

        fun skipWhitespace(start: Int): Int {
            var index = start
            while (index < text.length) {
                when (text[index]) {
                    ' ', '\t', '\n', '\r' -> index++
                    else -> return index
                }
            }
            return index
        }

        private fun obj(start: Int): Int {
            var index = skipWhitespace(start + 1)
            if (index < text.length && text[index] == '}') return index + 1
            val names = HashSet<String>()
            while (true) {
                index = skipWhitespace(index)
                if (index >= text.length || text[index] != '"') fail("expected a member name")
                val (name, afterName) = string(index)
                index = skipWhitespace(afterName)
                if (!names.add(name)) fail("duplicate JSON member '$name'")
                if (index >= text.length || text[index] != ':') fail("expected ':'")
                index = value(index + 1)
                index = skipWhitespace(index)
                if (index >= text.length) fail("unterminated object")
                when (text[index]) {
                    ',' -> index++
                    '}' -> return index + 1
                    else -> fail("expected ',' or '}'")
                }
            }
        }

        private fun array(start: Int): Int {
            var index = skipWhitespace(start + 1)
            if (index < text.length && text[index] == ']') return index + 1
            while (true) {
                index = value(index)
                index = skipWhitespace(index)
                if (index >= text.length) fail("unterminated array")
                when (text[index]) {
                    ',' -> index++
                    ']' -> return index + 1
                    else -> fail("expected ',' or ']'")
                }
            }
        }

        /** Reads and decodes one JSON string; returns the value and the index after it. */
        private fun string(start: Int): Pair<String, Int> {
            if (start >= text.length || text[start] != '"') fail("expected a string")
            val out = StringBuilder()
            var index = start + 1
            while (index < text.length) {
                when (val char = text[index]) {
                    '"' -> return out.toString() to index + 1
                    '\\' -> {
                        index++
                        if (index >= text.length) fail("unterminated escape")
                        when (val escape = text[index]) {
                            '"' -> out.append('"')
                            '\\' -> out.append('\\')
                            '/' -> out.append('/')
                            'b' -> out.append('\b')
                            'f' -> out.append('\u000C')
                            'n' -> out.append('\n')
                            'r' -> out.append('\r')
                            't' -> out.append('\t')
                            'u' -> {
                                if (index + 4 >= text.length) fail("short unicode escape")
                                val hex = text.substring(index + 1, index + 5)
                                val code = hex.toIntOrNull(16) ?: fail("bad unicode escape '$hex'")
                                out.append(code.toChar())
                                index += 4
                            }
                            else -> fail("bad escape '\\$escape'")
                        }
                        index++
                    }
                    else -> {
                        out.append(char)
                        index++
                    }
                }
            }
            fail("unterminated string")
        }

        /** A number, `true`, `false` or `null`: already validated, so only the extent is needed. */
        private fun scalar(start: Int): Int {
            var index = start
            while (index < text.length) {
                when (text[index]) {
                    ',', ']', '}' -> return index
                    ' ', '\t', '\n', '\r' -> return index
                    else -> index++
                }
            }
            return index
        }

        private fun fail(detail: String): Nothing = throw NormError("BAD_JSON", where, detail)
    }
}
