// SPDX-License-Identifier: MIT
package com.phonedsh.bot

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue

/** A frozen Bot contract value could not be decoded. */
public class BotJsonException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * JSON helpers shared by the Bot codecs.
 *
 * The repository's `JsonValue` is the value model (`:core`); this object adds
 * the canonical encoder the Bot golden comparison needs and the typed member
 * accessors the codecs use. It is not a schema validator: unknown members are
 * ignored by the codecs, matching the Swift `Codable` reference. Required
 * members are type-checked because the goldens round-trip those bytes.
 */
public object BotJson {
    public fun objectOf(vararg members: Pair<String, JsonValue>): JsonObject =
        JsonObject(linkedMapOf(*members))

    public fun arrayOf(values: List<JsonValue>): JsonArray = JsonArray(values)

    public fun number(value: Long): JsonNumber = JsonNumber(value.toString())

    public fun string(value: JsonValue?): String? = (value as? JsonString)?.value

    public fun bool(value: JsonValue?): Boolean? = (value as? JsonBool)?.value

    public fun long(value: JsonValue?): Long? = (value as? JsonNumber)?.asLongOrNull()

    /** First member in [keys] that is a non-blank string, matching `BotRowJSON.nonEmptyString`. */
    public fun nonEmptyString(members: Map<String, JsonValue>, keys: List<String>): String? {
        for (key in keys) {
            val text = string(members[key]) ?: continue
            if (text.trim().isNotEmpty()) return text
        }
        return null
    }

    /** True when any member in [keys] is a non-empty array. */
    public fun hasItems(members: Map<String, JsonValue>, keys: List<String>): Boolean =
        keys.any { key -> ((members[key] as? JsonArray)?.values?.isNotEmpty() == true) }

    /** Array length of [value], or 0 when it is absent/not an array. */
    public fun arraySize(value: JsonValue?): Int = (value as? JsonArray)?.values?.size ?: 0

    /**
     * Canonical JSON: UTF-8, object keys sorted, `/` not escaped, no
     * insignificant whitespace and only the JSON control escapes. This is the
     * comparison form used for the shared golden bytes (README §8.1).
     */
    public fun canonical(value: JsonValue): String {
        val out = StringBuilder()
        appendCanonical(value, out)
        return out.toString()
    }

    private fun appendCanonical(value: JsonValue, out: StringBuilder) {
        when (value) {
            is JsonNull -> out.append("null")
            is JsonBool -> out.append(if (value.value) "true" else "false")
            is JsonNumber -> out.append(value.raw)
            is JsonString -> appendString(value.value, out)
            is JsonArray -> {
                out.append('[')
                value.values.forEachIndexed { index, item ->
                    if (index > 0) out.append(',')
                    appendCanonical(item, out)
                }
                out.append(']')
            }
            is JsonObject -> {
                out.append('{')
                value.members.keys.sorted().forEachIndexed { index, key ->
                    if (index > 0) out.append(',')
                    appendString(key, out)
                    out.append(':')
                    appendCanonical(value.members.getValue(key), out)
                }
                out.append('}')
            }
        }
    }

    private fun appendString(value: String, out: StringBuilder) {
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

internal fun Map<String, JsonValue>.requiredObject(key: String, path: String = key): Map<String, JsonValue> {
    val value = this[key] ?: throw BotJsonException("missing member $path")
    return (value as? JsonObject)?.members ?: throw BotJsonException("$path must be an object")
}

internal fun Map<String, JsonValue>.optionalObject(key: String): Map<String, JsonValue>? =
    when (val value = this[key]) {
        null, is JsonNull -> null
        is JsonObject -> value.members
        else -> throw BotJsonException("$key must be an object")
    }

internal fun Map<String, JsonValue>.requiredArray(key: String, path: String = key): List<JsonValue> {
    val value = this[key] ?: throw BotJsonException("missing member $path")
    return (value as? JsonArray)?.values ?: throw BotJsonException("$path must be an array")
}

internal fun Map<String, JsonValue>.optionalArray(key: String): List<JsonValue>? =
    when (val value = this[key]) {
        null, is JsonNull -> null
        is JsonArray -> value.values
        else -> throw BotJsonException("$key must be an array")
    }

internal fun Map<String, JsonValue>.requiredString(key: String, path: String = key): String {
    val value = this[key] ?: throw BotJsonException("missing member $path")
    return (value as? JsonString)?.value ?: throw BotJsonException("$path must be a string")
}

internal fun Map<String, JsonValue>.optionalString(key: String): String? =
    when (val value = this[key]) {
        null, is JsonNull -> null
        is JsonString -> value.value
        else -> throw BotJsonException("$key must be a string")
    }

internal fun Map<String, JsonValue>.requiredBool(key: String, path: String = key): Boolean {
    val value = this[key] ?: throw BotJsonException("missing member $path")
    return (value as? JsonBool)?.value ?: throw BotJsonException("$path must be a boolean")
}

internal fun Map<String, JsonValue>.optionalBool(key: String): Boolean? =
    when (val value = this[key]) {
        null, is JsonNull -> null
        is JsonBool -> value.value
        else -> throw BotJsonException("$key must be a boolean")
    }

internal fun Map<String, JsonValue>.requiredLong(key: String, path: String = key): Long {
    val value = this[key] ?: throw BotJsonException("missing member $path")
    return (value as? JsonNumber)?.asLongOrNull() ?: throw BotJsonException("$path must be an integer")
}

internal fun Map<String, JsonValue>.optionalLong(key: String): Long? =
    when (val value = this[key]) {
        null, is JsonNull -> null
        is JsonNumber -> value.asLongOrNull() ?: throw BotJsonException("$key must be an integer")
        else -> throw BotJsonException("$key must be an integer")
    }

