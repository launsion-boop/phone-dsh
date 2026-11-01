// phone-dsh — :net / com.phonedsh.gateway: JSON values, canonical bytes, SHA-256.
// SPDX-License-Identifier: MIT
//
// A host-managed MCP response is rewritten structurally and re-encoded with
// sorted keys, so the same input always produces the same bytes and a golden
// vector can pin them (spec/v1/gateway-security.md §6, gw-resp-005). Parsing is
// `:core`'s JsonValue — the project's one RFC 8259 parser — and this file adds
// only the tree-rewrite value model plus the gateway's canonical bytes, which
// are byte-compatible with the Python oracle (spec/v1/tools/gateway_check.py
// recomputes expect.body_sha256 from expect.body_json with sort_keys=True and
// separators=(",", ":")). `:core`'s JsonWriter preserves member order, and the
// Rust codec canonicalises channel frames only (integers, JNI), so this encoder
// is the unique implementation of the gateway's canonical form.

package com.phonedsh.gateway

import com.phonedsh.agentcore.HarnessDecodingException
import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue as HarnessJsonValue
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.security.MessageDigest

/** One JSON value. Object members keep input order until canonical encoding. */
sealed interface JsonValue {
    data class Member(val name: String, val value: JsonValue)

    data class Obj(val members: List<Member>) : JsonValue {
        /** The last member with [name], matching Python's duplicate-key behaviour. */
        fun get(name: String): JsonValue? = members.lastOrNull { it.name == name }?.value

        fun string(name: String): String? = (get(name) as? Str)?.value

        fun int(name: String): Int? = (get(name) as? Num)?.literal?.toIntOrNull()

        fun bool(name: String): Boolean? = (get(name) as? Bool)?.value

        fun obj(name: String): Obj? = get(name) as? Obj

        fun array(name: String): List<JsonValue>? = (get(name) as? Arr)?.items

        fun stringMap(name: String): Map<String, String>? {
            val members = obj(name)?.members ?: return null
            val values = LinkedHashMap<String, String>()
            for (member in members) {
                val value = member.value as? Str ?: return null
                values[member.name] = value.value
            }
            return values
        }
    }

    data class Arr(val items: List<JsonValue>) : JsonValue

    data class Str(val value: String) : JsonValue

    /** A number keeps its original literal so re-encoding cannot change it. */
    data class Num(val literal: String) : JsonValue

    data class Bool(val value: Boolean) : JsonValue

    data object Null : JsonValue

    companion object {
        fun obj(vararg members: Pair<String, JsonValue>): Obj =
            Obj(members.map { Member(it.first, it.second) })

        fun obj(members: Iterable<Member>): Obj = Obj(members.toList())

        fun objOfStrings(values: Map<String, String>): Obj =
            Obj(values.map { Member(it.key, Str(it.value)) })

        fun num(value: Int): Num = Num(value.toString())

        fun num(value: Long): Num = Num(value.toString())

        fun bool(value: Boolean): Bool = Bool(value)
    }
}

/** Thrown when a body or fixture is not valid JSON. */
class JsonParseException(message: String) : IllegalArgumentException(message)

/**
 * JSON parsing and canonical encoding.
 *
 * Parsing is `:core`'s [HarnessJsonValue], the project's one RFC 8259 parser;
 * this object only re-shapes it into the model the redactor rewrites.
 *
 * Canonical form: object members sorted by Unicode code point, `,`/`:` with no
 * insignificant whitespace, strings escaped like Python's `json.dumps` with
 * `ensure_ascii=False`, UTF-8 bytes. Numbers are emitted with their original
 * literal, which is exact for the integer values the vectors pin.
 */
object GatewayJson {
    fun parse(text: String): JsonValue = try {
        fromHarness(HarnessJsonValue.parse(text))
    } catch (failure: HarnessDecodingException) {
        throw JsonParseException(failure.message ?: "invalid JSON")
    }

    /** Parses [text] or returns null when it is not a single JSON value. */
    fun parseOrNull(text: String): JsonValue? = try {
        parse(text)
    } catch (exception: JsonParseException) {
        null
    }

    /** Parses [bytes] as strict UTF-8 JSON, or returns null. */
    fun parseOrNull(bytes: ByteArray): JsonValue? {
        val text = decodeUtf8(bytes) ?: return null
        return parseOrNull(text)
    }

    /**
     * Re-shapes one `:core` JSON value into this module's model.
     *
     * Duplicate object names collapse last-wins exactly as Python's `json.loads`
     * and the vector checker do; the redactor collapses rewritten names anyway.
     */
    private fun fromHarness(value: HarnessJsonValue): JsonValue = when (value) {
        is JsonNull -> JsonValue.Null
        is JsonBool -> JsonValue.Bool(value.value)
        is JsonNumber -> JsonValue.Num(value.raw)
        is JsonString -> JsonValue.Str(value.value)
        is JsonArray -> JsonValue.Arr(value.values.map(::fromHarness))
        is JsonObject -> JsonValue.Obj(
            value.members.map { (name, member) -> JsonValue.Member(name, fromHarness(member)) },
        )
        else -> throw JsonParseException("unsupported JSON value ${value::class.simpleName}")
    }

    /** Strict UTF-8 decoding: invalid byte sequences return null, never U+FFFD. */
    fun decodeUtf8(bytes: ByteArray): String? = try {
        StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
            .toString()
    } catch (exception: CharacterCodingException) {
        null
    }

    fun canonicalText(value: JsonValue): String {
        val out = StringBuilder()
        appendCanonical(out, value)
        return out.toString()
    }

    fun canonicalBytes(value: JsonValue): ByteArray =
        canonicalText(value).toByteArray(StandardCharsets.UTF_8)

    /** Structural equality: equal exactly when the canonical bytes are equal. */
    fun structuralEquals(left: JsonValue, right: JsonValue): Boolean =
        canonicalBytes(left).contentEquals(canonicalBytes(right))

    fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        val out = StringBuilder(digest.size * 2)
        for (byte in digest) {
            val value = byte.toInt() and 0xFF
            out.append(HEX[value ushr 4])
            out.append(HEX[value and 0x0F])
        }
        return out.toString()
    }

    private val HEX = "0123456789abcdef".toCharArray()

    private fun appendCanonical(out: StringBuilder, value: JsonValue) {
        when (value) {
            JsonValue.Null -> out.append("null")
            is JsonValue.Bool -> out.append(if (value.value) "true" else "false")
            is JsonValue.Num -> out.append(value.literal)
            is JsonValue.Str -> appendString(out, value.value)
            is JsonValue.Arr -> {
                out.append('[')
                value.items.forEachIndexed { index, item ->
                    if (index > 0) out.append(',')
                    appendCanonical(out, item)
                }
                out.append(']')
            }
            is JsonValue.Obj -> {
                out.append('{')
                val sorted = value.members.sortedWith(Comparator { left, right ->
                    compareCodePoints(left.name, right.name)
                })
                sorted.forEachIndexed { index, member ->
                    if (index > 0) out.append(',')
                    appendString(out, member.name)
                    out.append(':')
                    appendCanonical(out, member.value)
                }
                out.append('}')
            }
        }
    }

    private fun appendString(out: StringBuilder, value: String) {
        out.append('"')
        for (character in value) {
            when (character) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                else -> if (character < ' ') {
                    out.append("\\u")
                    appendHex4(out, character.code)
                } else {
                    out.append(character)
                }
            }
        }
        out.append('"')
    }

    private fun appendHex4(out: StringBuilder, value: Int) {
        out.append(HEX[(value ushr 12) and 0x0F])
        out.append(HEX[(value ushr 8) and 0x0F])
        out.append(HEX[(value ushr 4) and 0x0F])
        out.append(HEX[value and 0x0F])
    }

    /** Python sorts object keys by Unicode code point; Kotlin compares UTF-16 units. */
    fun compareCodePoints(left: String, right: String): Int {
        var leftIndex = 0
        var rightIndex = 0
        while (leftIndex < left.length && rightIndex < right.length) {
            val leftPoint = left.codePointAt(leftIndex)
            val rightPoint = right.codePointAt(rightIndex)
            if (leftPoint != rightPoint) return leftPoint.compareTo(rightPoint)
            leftIndex += Character.charCount(leftPoint)
            rightIndex += Character.charCount(rightPoint)
        }
        return when {
            leftIndex < left.length -> 1
            rightIndex < right.length -> -1
            else -> 0
        }
    }
}
