// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.BotJsonException

/** Decoding helpers shared by the P09 value codecs. */
internal object JsonSupport {
    /** A raw JSON string, or null when the member is absent or `null`. */
    fun string(value: JsonValue?): String? = (value as? JsonString)?.value

    /** A boolean, or null when the member is absent or `null`. */
    fun bool(value: JsonValue?): Boolean? = (value as? JsonBool)?.value

    /** An integer-valued number, or null when absent/`null`. */
    fun long(value: JsonValue?): Long? = (value as? JsonNumber)?.asLongOrNull()

    /** True when [value] is a JSON array with at least one element. */
    fun hasItems(value: JsonValue?): Boolean =
        (value as? com.phonedsh.agentcore.JsonArray)?.values?.isNotEmpty() == true

    /** True when [text] is a string and not the empty string (whitespace counts). */
    fun nonEmpty(value: JsonValue?): String? = string(value)?.takeIf { it.isNotEmpty() }

    /**
     * First member in [keys] that is a non-empty string; whitespace counts as
     * non-empty, matching the reference `BotUIBody.string` helpers.
     */
    fun firstString(members: Map<String, JsonValue>, vararg keys: String): String? {
        for (key in keys) {
            nonEmpty(members[key])?.let { return it }
        }
        return null
    }

    fun objectMembers(value: JsonValue?, path: String): Map<String, JsonValue> =
        (value as? JsonObject)?.members ?: throw BotJsonException("$path must be an object")

    fun optionalObject(value: JsonValue?, path: String): Map<String, JsonValue>? =
        when (value) {
            null, is JsonNull -> null
            is JsonObject -> value.members
            else -> throw BotJsonException("$path must be an object")
        }

    fun array(value: JsonValue?, path: String): List<JsonValue> =
        (value as? com.phonedsh.agentcore.JsonArray)?.values
            ?: throw BotJsonException("$path must be an array")

    fun optionalArray(value: JsonValue?, path: String): List<JsonValue>? =
        when (value) {
            null, is JsonNull -> null
            is com.phonedsh.agentcore.JsonArray -> value.values
            else -> throw BotJsonException("$path must be an array")
        }

    fun requiredString(members: Map<String, JsonValue>, key: String, path: String = key): String =
        string(members[key] ?: throw BotJsonException("missing member $path"))
            ?: throw BotJsonException("$path must be a string")

    fun optionalString(members: Map<String, JsonValue>, key: String, path: String = key): String? =
        when (val value = members[key]) {
            null, is JsonNull -> null
            is JsonString -> value.value
            else -> throw BotJsonException("$path must be a string")
        }

    fun requiredBool(members: Map<String, JsonValue>, key: String, path: String = key): Boolean =
        bool(members[key] ?: throw BotJsonException("missing member $path"))
            ?: throw BotJsonException("$path must be a boolean")

    fun optionalBool(members: Map<String, JsonValue>, key: String, path: String = key): Boolean? =
        when (val value = members[key]) {
            null, is JsonNull -> null
            is JsonBool -> value.value
            else -> throw BotJsonException("$path must be a boolean")
        }

    fun requiredLong(members: Map<String, JsonValue>, key: String, path: String = key): Long =
        long(members[key] ?: throw BotJsonException("missing member $path"))
            ?: throw BotJsonException("$path must be an integer")

    fun requiredNonNegativeLong(
        members: Map<String, JsonValue>,
        key: String,
        path: String = key,
    ): Long {
        val value = requiredLong(members, key, path)
        if (value < 0) throw BotJsonException("$path must be >= 0")
        return value
    }

    fun optionalLong(members: Map<String, JsonValue>, key: String, path: String = key): Long? =
        when (val value = members[key]) {
            null, is JsonNull -> null
            is JsonNumber -> value.asLongOrNull() ?: throw BotJsonException("$path must be an integer")
            else -> throw BotJsonException("$path must be an integer")
        }

    fun optionalNonNegativeLong(
        members: Map<String, JsonValue>,
        key: String,
        path: String = key,
    ): Long? {
        val value = optionalLong(members, key, path) ?: return null
        if (value < 0) throw BotJsonException("$path must be >= 0")
        return value
    }

    fun requiredNonNegativeInt(
        members: Map<String, JsonValue>,
        key: String,
        path: String = key,
    ): Int {
        val value = requiredLong(members, key, path)
        if (value < 0) throw BotJsonException("$path must be >= 0")
        if (value > Int.MAX_VALUE) throw BotJsonException("$path is out of range")
        return value.toInt()
    }

    fun optionalNonNegativeInt(
        members: Map<String, JsonValue>,
        key: String,
        path: String = key,
    ): Int? {
        val value = optionalLong(members, key, path) ?: return null
        if (value < 0) throw BotJsonException("$path must be >= 0")
        if (value > Int.MAX_VALUE) throw BotJsonException("$path is out of range")
        return value.toInt()
    }

    fun requiredStringArray(
        members: Map<String, JsonValue>,
        key: String,
        path: String = key,
    ): List<String> = array(members[key] ?: throw BotJsonException("missing member $path"), path)
        .map { item -> string(item) ?: throw BotJsonException("$path[] must be a string") }

    fun stringArrayOrEmpty(value: JsonValue?, path: String): List<String> =
        optionalArray(value, path)?.map { item ->
            string(item) ?: throw BotJsonException("$path[] must be a string")
        } ?: emptyList()

    fun objectArrayOrEmpty(value: JsonValue?, path: String): List<Map<String, JsonValue>> =
        optionalArray(value, path)?.mapIndexed { index, item ->
            objectMembers(item, "$path[$index]")
        } ?: emptyList()

    fun optionalJson(value: JsonValue?): JsonValue = value ?: JsonNull

    fun json(value: Boolean?): JsonValue = value?.let(::JsonBool) ?: JsonNull

    fun json(value: Long?): JsonValue = value?.let(BotJson::number) ?: JsonNull

    fun json(value: String?): JsonValue = value?.let(::JsonString) ?: JsonNull
}

/** Encodes a nullable detail member as JSON null. */
internal fun JsonValue?.orNullValue(): JsonValue = this ?: JsonNull
