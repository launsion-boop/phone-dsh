// SPDX-License-Identifier: MIT
package com.phonedsh.bot.watchdog

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.GoldenFixture
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.SqliteJdbcDriver
import java.io.File
import java.nio.file.Files

internal fun fixture(name: String): JsonObject = GoldenFixture.rawObject(name)

internal fun JsonValue?.objectOrNull(): Map<String, JsonValue>? =
    (this as? JsonObject)?.members

internal fun JsonValue?.arrayOrNull(): List<JsonValue>? =
    (this as? JsonArray)?.values

internal fun JsonValue?.stringOrNull(): String? =
    when (this) {
        null, JsonNull -> null
        is JsonString -> value
        else -> error("expected string or null, got $this")
    }

internal fun JsonValue?.requiredString(): String =
    stringOrNull() ?: error("expected string, got $this")

internal fun JsonValue?.longOrNull(): Long? =
    when (this) {
        null, JsonNull -> null
        is JsonNumber -> asLongOrNull()
        else -> error("expected integer or null, got $this")
    }

internal fun JsonValue?.doubleOrNull(): Double? =
    when (this) {
        null, JsonNull -> null
        is JsonNumber -> raw.toDoubleOrNull()
        else -> error("expected number or null, got $this")
    }

internal fun JsonValue?.evidenceObject(): Map<String, JsonValue> =
    objectOrNull() ?: emptyMap()

internal fun JsonObject.requireObject(key: String): Map<String, JsonValue> =
    members[key]?.objectOrNull() ?: error("missing object $key")

internal fun JsonObject.requireArray(key: String): List<JsonValue> =
    members[key]?.arrayOrNull() ?: error("missing array $key")

internal fun JsonObject.optionalArray(key: String): List<JsonValue> =
    members[key]?.arrayOrNull() ?: emptyList()

internal fun JsonObject.optionalObject(key: String): Map<String, JsonValue>? =
    members[key]?.objectOrNull()

internal fun JsonValue?.asUnitsJson(): JsonObject =
    this as? JsonObject ?: error("expected object, got $this")

internal fun assertCanonicalEquals(expected: JsonValue, actual: JsonValue, message: String = "") {
    val left = GoldenFixture.canonical(expected)
    val right = GoldenFixture.canonical(actual)
    if (left != right) {
        throw AssertionError("$message\nexpected: $left\nactual:   $right")
    }
}

internal fun <T> withTempStore(
    clock: () -> Long = { 0L },
    block: (BotDomainStore, File) -> T,
): T {
    val directory = Files.createTempDirectory("bot-watchdog-test").toFile()
    val file = File(directory, "domain.sqlite")
    val store = BotDomainStore(SqliteJdbcDriver(file.absolutePath), clock = clock)
    try {
        return block(store, file)
    } finally {
        store.close()
        directory.deleteRecursively()
    }
}

internal fun JsonObject.unitJson(): JsonObject = JsonObject(
    linkedMapOf(
        "kind" to JsonString(members.getValue("kind").requiredString()),
        "id" to JsonString(members.getValue("id").requiredString()),
        "botId" to (members["botId"] ?: JsonNull),
        "sessionId" to (members["sessionId"] ?: JsonNull),
        "startedAt" to JsonNumber(members.getValue("startedAt").longOrNull().toString()),
        "lastEventAt" to JsonNumber(members.getValue("lastEventAt").longOrNull().toString()),
        "deadlineAt" to (members["deadlineAt"]?.let { value ->
            value.longOrNull()?.let { JsonNumber(it.toString()) } ?: JsonNull
        } ?: JsonNull),
    ),
)
