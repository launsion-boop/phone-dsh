// A small reader for the JSON dialect the native WAL kernel returns.
// SPDX-License-Identifier: MIT

package com.phonedsh.log

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue

/**
 * Typed reads of the JSON objects [com.phonedsh.wire.NativeWal] returns.
 *
 * The shapes are the JNI dialect of `pdsh-wal` (`scanSegment`, `planRecovery`,
 * `records`); the Rust side is trusted, so a member that is missing or has the
 * wrong type is an integration bug and fails as [IllegalStateException], not as
 * a WAL error. A decode that a *caller* can get wrong (a manifest, a record
 * body) has its own typed path.
 *
 * The parser itself is [JsonValue.parse] from `com.phonedsh.agentcore`: the
 * host already ships one dependency-free JSON reader, and a second one in this
 * package would be a second interpretation of escapes and numbers.
 */
internal object WalJson {
    /** Parses one JSON document. */
    fun parse(text: String): JsonValue = try {
        JsonValue.parse(text)
    } catch (error: RuntimeException) {
        throw IllegalStateException("native WAL reply is not JSON: ${error.message}", error)
    }

    /** [value] as an object. */
    fun objectOf(value: JsonValue, context: String): JsonObject =
        value as? JsonObject ?: throw IllegalStateException("$context is not a JSON object")

    /** [value] as an array. */
    fun arrayOf(value: JsonValue, context: String): List<JsonValue> =
        (value as? JsonArray)?.values ?: throw IllegalStateException("$context is not a JSON array")

    /** The required member [name] of [object]. */
    fun member(obj: JsonObject, name: String, context: String): JsonValue =
        obj[name] ?: throw IllegalStateException("$context has no $name member")

    /** The required string member [name]. */
    fun string(obj: JsonObject, name: String, context: String): String =
        (member(obj, name, context) as? JsonString)?.value
            ?: throw IllegalStateException("$context $name is not a string")

    /** The required integer member [name]. */
    fun long(obj: JsonObject, name: String, context: String): Long =
        asLong(member(obj, name, context), "$context $name")

    /** The required boolean member [name]. */
    fun boolean(obj: JsonObject, name: String, context: String): Boolean =
        (member(obj, name, context) as? JsonBool)?.value
            ?: throw IllegalStateException("$context $name is not a boolean")

    /** The optional integer member [name]; `null` when absent or `null`. */
    fun optionalLong(obj: JsonObject, name: String, context: String): Long? {
        val value = obj[name] ?: return null
        if (value is JsonNull) return null
        return asLong(value, "$context $name")
    }

    /** The optional string member [name]; `null` when absent or `null`. */
    fun optionalString(obj: JsonObject, name: String, context: String): String? {
        val value = obj[name] ?: return null
        if (value is JsonNull) return null
        return (value as? JsonString)?.value
            ?: throw IllegalStateException("$context $name is not a string")
    }

    /** A string array, for the plan's segment-name lists. */
    fun strings(obj: JsonObject, name: String, context: String): List<String> =
        arrayOf(member(obj, name, context), "$context $name").mapIndexed { index, value ->
            (value as? JsonString)?.value
                ?: throw IllegalStateException("$context $name[$index] is not a string")
        }

    private fun asLong(value: JsonValue, context: String): Long =
        (value as? JsonNumber)?.asLongOrNull()
            ?: throw IllegalStateException("$context is not an integer")
}
