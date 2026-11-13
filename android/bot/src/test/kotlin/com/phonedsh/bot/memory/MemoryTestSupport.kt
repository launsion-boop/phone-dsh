// SPDX-License-Identifier: MIT
package com.phonedsh.bot.memory

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventOrigin
import com.phonedsh.bot.store.BotPrincipal
import com.phonedsh.bot.store.SqliteJdbcDriver
import java.nio.file.Files
import java.nio.file.Path

/** Reads the P26 v2 goldens and schemas from disk; no vector is copied into Kotlin. */
object MemoryVectors {
    val repoRoot: Path = System.getProperty("pdsh.repo.root")?.let(Path::of)
        ?: generateSequence(Path.of("").toAbsolutePath()) { it.parent }
            .first { Files.isDirectory(it.resolve("spec/bot/v2/golden")) }

    fun golden(name: String): JsonObject =
        JsonValue.parse(Files.readString(repoRoot.resolve("spec/bot/v2/golden/$name.json"))) as JsonObject

    fun schema(name: String): JsonObject =
        JsonValue.parse(Files.readString(repoRoot.resolve("spec/bot/v2/$name.schema.json"))) as JsonObject

    fun v1Schema(name: String): JsonObject =
        JsonValue.parse(Files.readString(repoRoot.resolve("spec/bot/v1/$name.schema.json"))) as JsonObject

    fun objects(value: JsonValue?, vararg path: String): List<JsonObject> {
        var current: JsonValue? = value
        for (key in path) {
            current = (current as? JsonObject)?.members?.get(key)
        }
        return (current as? JsonArray)?.values?.map { it as JsonObject } ?: emptyList()
    }

    fun objectAt(value: JsonValue?, vararg path: String): JsonObject {
        var current: JsonValue? = value
        for (key in path) {
            current = (current as? JsonObject)?.members?.get(key)
        }
        return current as? JsonObject ?: throw AssertionError("missing object at ${path.joinToString(".")}")
    }

    fun string(value: JsonValue?, vararg path: String): String? {
        var current: JsonValue? = value
        for (key in path) {
            current = (current as? JsonObject)?.members?.get(key)
        }
        return (current as? JsonString)?.value
    }

    fun requireString(value: JsonValue?, vararg path: String): String =
        string(value, *path) ?: throw AssertionError("missing string at ${path.joinToString(".")}")

    fun long(value: JsonValue?, vararg path: String): Long? {
        var current: JsonValue? = value
        for (key in path) {
            current = (current as? JsonObject)?.members?.get(key)
        }
        return (current as? com.phonedsh.agentcore.JsonNumber)?.asLongOrNull()
    }

    fun requireLong(value: JsonValue?, vararg path: String): Long =
        long(value, *path) ?: throw AssertionError("missing integer at ${path.joinToString(".")}")

    fun bool(value: JsonValue?, vararg path: String): Boolean? {
        var current: JsonValue? = value
        for (key in path) {
            current = (current as? JsonObject)?.members?.get(key)
        }
        return (current as? com.phonedsh.agentcore.JsonBool)?.value
    }

    fun canonical(value: JsonValue): String = com.phonedsh.bot.BotJson.canonical(value)

    /** The simple shape checks the Kotlin codecs are expected to honour. */
    fun assertMatchesSchema(schemaName: String, value: JsonValue) {
        val schema = schema(schemaName)
        val branches = (schema.members["oneOf"] as? JsonArray)?.values ?: listOf(schema)
        val valueMembers = (value as? JsonObject)?.members
            ?: throw AssertionError("$schemaName: value is not an object")
        val branch = branches.map { it as JsonObject }.firstOrNull { candidate ->
            val required = (candidate.members["required"] as? JsonArray)?.values
                ?.mapNotNull { (it as? JsonString)?.value } ?: emptyList()
            required.all { it in valueMembers }
        } ?: throw AssertionError("$schemaName: no oneOf branch matches $valueMembers")
        val required = (branch.members["required"] as? JsonArray)?.values
            ?.mapNotNull { (it as? JsonString)?.value } ?: emptyList()
        for (key in required) {
            if (key !in valueMembers) throw AssertionError("$schemaName: missing required $key")
        }
        if ((branch.members["additionalProperties"] as? com.phonedsh.agentcore.JsonBool)?.value == false) {
            val properties = (branch.members["properties"] as? JsonObject)?.members?.keys ?: emptySet()
            val extra = valueMembers.keys - properties
            if (extra.isNotEmpty()) {
                throw AssertionError("$schemaName: unexpected ${extra.sorted()}")
            }
        }
    }
}

class MemoryHarness(
    botId: String = "bot-a",
    private val replayFeed: BotMemoryReplayFeed = BotMemoryReplayFeed(),
) : AutoCloseable {
    val database: Path = Files.createTempFile("bot-memory", ".sqlite").also { Files.deleteIfExists(it) }
    private val driver = SqliteJdbcDriver(database.toString())
    val domain: BotDomainStore = BotDomainStore(driver, clock = { 1_760_000_000_000 })
    val eventLog: BotDomainMemoryEventLog = BotDomainMemoryEventLog(domain)
    val store: BotSqlMemoryDocumentStore = BotSqlMemoryDocumentStore(
        eventLog = eventLog,
        botId = botId,
        now = { 1_760_000_000_000 },
        replayFeed = replayFeed,
    )

    fun storeFor(botId: String): BotSqlMemoryDocumentStore = BotSqlMemoryDocumentStore(
        eventLog = eventLog,
        botId = botId,
        now = { 1_760_000_000_000 },
        replayFeed = replayFeed,
    )

    fun memoryFor(
        botId: String = "bot-a",
        prepareIndexes: Boolean = false,
    ): BotMemory = BotMemory(
        store = storeFor(botId),
        botId = botId,
        now = { 1_760_000_000_000 },
        prepareIndexes = prepareIndexes,
    )

    fun append(
        type: String,
        eventId: String,
        data: JsonObject,
        botId: String = "bot-a",
        kind: String = "chat",
        sessionId: String? = "gb-main",
        time: Long = 1_760_000_000_000,
    ): Long = eventLog.append(
        BotEvent(
            schemaVersion = 1,
            type = type,
            eventId = eventId,
            commitSeq = null,
            time = time,
            origin = BotEventOrigin.Local("memory-service"),
            traceId = "trace-$eventId",
            principal = BotPrincipal(botId, sessionId, kind, emptyList()),
            causationId = null,
            correlationId = null,
            data = data,
        ),
    )

    override fun close() {
        domain.close()
        Files.deleteIfExists(database)
        Files.deleteIfExists(Path.of("$database-wal"))
        Files.deleteIfExists(Path.of("$database-shm"))
    }
}

val CHAT_AUTHOR: BotMemoryAuthor = BotMemoryAuthor(
    botId = "bot-a",
    sessionId = "gb-main",
    kind = BotMemoryAuthorKind.CHAT,
)

fun seedDocument(
    store: BotMemoryDocumentStore,
    path: String,
    content: String,
    version: Int,
    evidence: List<String> = emptyList(),
    trust: BotMemoryTrust? = null,
    author: BotMemoryAuthor = CHAT_AUTHOR,
    updatedAtMs: Long? = null,
) {
    for (current in 1..version) {
        writeDocumentVersion(
            store = store,
            path = path,
            content = content,
            expectedVersion = current - 1,
            evidence = evidence,
            trust = trust,
            author = author,
            atMs = updatedAtMs ?: (1_760_000_000_000 + current),
        )
    }
}

fun writeDocumentVersion(
    store: BotMemoryDocumentStore,
    path: String,
    content: String,
    expectedVersion: Int,
    evidence: List<String> = emptyList(),
    trust: BotMemoryTrust? = null,
    author: BotMemoryAuthor = CHAT_AUTHOR,
    atMs: Long = 1_760_000_000_000,
): BotMemoryStoreWriteOutcome {
    val outcome = store.write(
        BotMemoryStoreWriteRequest(
            action = BotMemoryAction.WRITE,
            path = path,
            content = content,
            expectedVersion = expectedVersion,
            author = author,
            evidence = evidence,
            trust = trust,
            source = null,
            atMs = atMs,
        ),
    )
    if (outcome !is BotMemoryStoreWriteOutcome.Written) {
        throw AssertionError("write $path#$expectedVersion failed: $outcome")
    }
    return outcome
}

fun seedHistory(
    store: BotMemoryDocumentStore,
    path: String,
    history: List<Pair<Int, String>>,
    evidence: List<String> = emptyList(),
    author: BotMemoryAuthor = CHAT_AUTHOR,
) {
    for ((version, content) in history.sortedBy { it.first }) {
        val expected = version - 1
        val outcome = store.write(
            BotMemoryStoreWriteRequest(
                action = BotMemoryAction.WRITE,
                path = path,
                content = content,
                expectedVersion = expected,
                author = author,
                evidence = evidence,
                trust = null,
                source = null,
                atMs = 1_760_000_000_000 + version,
            ),
        )
        if (outcome !is BotMemoryStoreWriteOutcome.Written) {
            throw AssertionError("seed $path#$version failed: $outcome")
        }
    }
}

fun writeContext(
    botId: String = "bot-a",
    sessionId: String? = "gb-main",
    authorKind: BotMemoryAuthorKind = BotMemoryAuthorKind.CHAT,
    sourceKind: BotMemorySourceKind = BotMemorySourceKind.USER_TURN,
    trust: BotMemoryTrust? = null,
    isMainBot: Boolean = true,
    batchId: String? = null,
    isHostRollback: Boolean = false,
    currentUserTurnReference: String? = null,
): BotMemoryWriteContext = BotMemoryWriteContext(
    botId = botId,
    sessionId = sessionId,
    authorKind = authorKind,
    source = BotMemorySource(sourceKind, sessionId, "1"),
    trust = trust,
    isMainBot = isMainBot,
    batchId = batchId,
    isHostRollback = isHostRollback,
    currentUserTurnReference = currentUserTurnReference,
)
