// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue

/** A routine snapshot member is missing or has the wrong JSON type. */
class RoutineDecodeException(message: String) : Exception(message)

/**
 * Typed member access for the routine/held-inbox codecs.
 *
 * The Swift reference is `Codable`: required members are decoded strictly,
 * optional members use `decodeIfPresent` and therefore accept an absent member
 * and an explicit `null` as the same value (CCR-7), and unknown members are
 * ignored. Encoders omit every nil optional so a Kotlin writer produces the
 * same canonical bytes as the iOS writer.
 */
internal object RoutineJson {
    fun objectOf(members: List<Pair<String, JsonValue?>>): JsonObject {
        val values = LinkedHashMap<String, JsonValue>()
        for ((key, value) in members) if (value != null) values[key] = value
        return JsonObject(values)
    }

    fun string(value: String): JsonString = JsonString(value)

    fun number(value: Long): JsonNumber = JsonNumber(value.toString())

    fun bool(value: Boolean): JsonBool = JsonBool(value)

    fun Map<String, JsonValue>.requiredString(key: String, path: String = key): String {
        val value = this[key] ?: throw RoutineDecodeException("missing member $path")
        return (value as? JsonString)?.value ?: throw RoutineDecodeException("$path must be a string")
    }

    fun Map<String, JsonValue>.optionalString(key: String, path: String = key): String? = when (val value = this[key]) {
        null, is JsonNull -> null
        is JsonString -> value.value
        else -> throw RoutineDecodeException("$path must be a string")
    }

    fun Map<String, JsonValue>.requiredLong(key: String, path: String = key): Long {
        val value = this[key] ?: throw RoutineDecodeException("missing member $path")
        return (value as? JsonNumber)?.asLongOrNull() ?: throw RoutineDecodeException("$path must be an integer")
    }

    fun Map<String, JsonValue>.optionalLong(key: String, path: String = key): Long? = when (val value = this[key]) {
        null, is JsonNull -> null
        is JsonNumber -> value.asLongOrNull() ?: throw RoutineDecodeException("$path must be an integer")
        else -> throw RoutineDecodeException("$path must be an integer")
    }

    fun Map<String, JsonValue>.requiredInt(key: String, path: String = key): Int {
        val value = requiredLong(key, path)
        if (value < Int.MIN_VALUE || value > Int.MAX_VALUE) {
            throw RoutineDecodeException("$path is out of range")
        }
        return value.toInt()
    }

    fun Map<String, JsonValue>.optionalInt(key: String, path: String = key): Int? {
        val value = optionalLong(key, path) ?: return null
        if (value < Int.MIN_VALUE || value > Int.MAX_VALUE) {
            throw RoutineDecodeException("$path is out of range")
        }
        return value.toInt()
    }

    fun Map<String, JsonValue>.requiredBool(key: String, path: String = key): Boolean {
        val value = this[key] ?: throw RoutineDecodeException("missing member $path")
        return (value as? JsonBool)?.value ?: throw RoutineDecodeException("$path must be a boolean")
    }

    fun Map<String, JsonValue>.optionalBool(key: String, path: String = key): Boolean? = when (val value = this[key]) {
        null, is JsonNull -> null
        is JsonBool -> value.value
        else -> throw RoutineDecodeException("$path must be a boolean")
    }

    fun Map<String, JsonValue>.requiredObject(key: String, path: String = key): Map<String, JsonValue> {
        val value = this[key] ?: throw RoutineDecodeException("missing member $path")
        return (value as? JsonObject)?.members ?: throw RoutineDecodeException("$path must be an object")
    }

    fun Map<String, JsonValue>.optionalObject(key: String, path: String = key): Map<String, JsonValue>? =
        when (val value = this[key]) {
            null, is JsonNull -> null
            is JsonObject -> value.members
            else -> throw RoutineDecodeException("$path must be an object")
        }

    fun Map<String, JsonValue>.requiredArray(key: String, path: String = key): List<JsonValue> {
        val value = this[key] ?: throw RoutineDecodeException("missing member $path")
        return (value as? JsonArray)?.values ?: throw RoutineDecodeException("$path must be an array")
    }

    fun Map<String, JsonValue>.optionalArray(key: String, path: String = key): List<JsonValue>? =
        when (val value = this[key]) {
            null, is JsonNull -> null
            is JsonArray -> value.values
            else -> throw RoutineDecodeException("$path must be an array")
        }

    /** `String.prefix(n)` over Unicode scalars, so a surrogate pair is never split. */
    fun prefixCodePoints(value: String, limit: Int): String {
        if (limit <= 0) return ""
        if (value.codePointCount(0, value.length) <= limit) return value
        return value.substring(0, value.offsetByCodePoints(0, limit))
    }

    fun codePointLength(value: String): Int = value.codePointCount(0, value.length)

    /** ICU `\s+` → one space, then trim (Swift `RoutineDeliveryFlags.clean`, titles, summaries). */
    fun collapseWhitespace(value: String): String {
        val out = StringBuilder(value.length)
        var pendingSpace = false
        for (character in value) {
            if (character.isWhitespace() || character == '\u00A0') {
                pendingSpace = out.isNotEmpty()
                continue
            }
            if (pendingSpace) {
                out.append(' ')
                pendingSpace = false
            }
            out.append(character)
        }
        return out.toString().trim()
    }
}
