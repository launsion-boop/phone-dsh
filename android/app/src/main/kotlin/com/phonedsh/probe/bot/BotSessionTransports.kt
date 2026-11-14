// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.projection.BotSessionLogParser
import com.phonedsh.bot.projection.BotSessionLogRecord
import com.phonedsh.bot.projection.BotSurfaceOp
import com.phonedsh.bot.session.BotFollowConnection
import com.phonedsh.bot.session.BotSessionRemoteException
import com.phonedsh.bot.session.BotSessionTransport
import com.phonedsh.dsh.host.HostChannel
import com.phonedsh.dsh.turn.DshTurnClient
import com.phonedsh.dsh.turn.DshTurnException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.attribute.FileTime
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking

/**
 * The production [BotSessionTransport] over the App's one [HostChannel].
 *
 * The engine and `:dsh` expose the same ordered channel; this adapter is the
 * single place where the synchronous P27 port meets the suspend `/api` lane.
 * All methods are called from [AppBotChatDriver]'s IO scope, never from the
 * Compose main thread.
 *
 * `call` is a one-to-one mapping; no result is invented. A Worker that has
 * not implemented the Bot presets (`phone-bot`) fails `session/create` exactly
 * as the runtime's contract requires, and the driver records that failure as a
 * durable notice row instead of pretending a turn started.
 */
class DshBotSessionTransport(
    private val channel: HostChannel,
    private val log: (String) -> Unit = {},
) : BotSessionTransport {
    private val client = DshTurnClient(channel, log)

    override fun call(endpoint: String, args: JsonObject): JsonObject = try {
        runBlocking { client.call(endpoint, args) } as? JsonObject
            ?: throw BotSessionRemoteException("invalid_response", "$endpoint returned no object")
    } catch (error: DshTurnException) {
        throw BotSessionRemoteException(error.code, error.message ?: error.code)
    }

    override fun openFollow(): BotFollowConnection = DshFollowConnection(client, log)

    private class DshFollowConnection(
        private val client: DshTurnClient,
        private val log: (String) -> Unit,
    ) : BotFollowConnection {
        private val lock = Any()
        private var sessionId: String? = null
        private var stream: DshTurnClient.FollowStream? = null
        private var closed = false

        override fun send(frame: JsonObject) {
            synchronized(lock) {
                if (sessionId != null) return
                sessionId = extractSessionId(frame)
            }
        }

        override fun receive(): JsonObject? {
            val active = synchronized(lock) {
                if (closed) return null
                stream ?: openStream()
            } ?: return null
            return runBlocking {
                try {
                    active.next()
                } catch (error: DshTurnException) {
                    throw BotSessionRemoteException(error.code, error.message ?: error.code)
                }
            }
        }

        private fun openStream(): DshTurnClient.FollowStream? {
            val id = sessionId ?: return null
            return try {
                runBlocking { client.follow(id) }.also { stream = it }
            } catch (error: DshTurnException) {
                log("bot follow open failed: ${error.code}")
                throw BotSessionRemoteException(error.code, error.message ?: error.code)
            }
        }

        override fun close() {
            val active = synchronized(lock) {
                if (closed) return
                closed = true
                stream.also { stream = null }
            } ?: return
            runBlocking {
                runCatching { active.close() }
            }
        }

        private fun extractSessionId(frame: JsonObject): String? {
            val request = ((frame["payload"] as? JsonObject)
                ?.members?.get("args") as? JsonObject)
                ?.members?.get("request") as? JsonObject
            val address = request?.members?.get("address") as? JsonObject
            return (address?.members?.get("sessionId") as? JsonString)?.value
                ?: (request?.members?.get("sessionId") as? JsonString)?.value
        }
    }
}

/**
 * Reads the materialized DSH journal for a Bot epoch (P27 §7).
 * When no local journal exists, read the same records from the Worker:
 *
 * 1. open `session/follow` only to read `snapshot.cursor`, then close it;
 * 2. call `session/page` with that `throughSeq`;
 * 3. while `hasMore`, page again with `beforeSeq` = the oldest seq already
 *    collected and the same `throughSeq`;
 * 4. return the records oldest-first, deduplicated by `seq`.
 *
 * The records are decoded with the same required/optional member rules as
 * `projection.md` §2.3; a malformed line is skipped rather than aborting the
 * whole epoch. This class only reads: it never prompts, creates, archives or
 * claims a session.
 */
class BotSessionHistoryReader(
    private val transport: BotSessionTransport,
    private val pageSize: Int = 100,
    private val materializedSessions: Path? = null,
) {
    fun load(sessionId: String): List<BotSessionLogRecord> {
        readMaterializedJournal(sessionId)?.let { return it }
        val cursor = readCursor(sessionId) ?: -1L
        val bySeq = LinkedHashMap<Long, BotSessionLogRecord>()
        var beforeSeq: Long? = null
        var pages = 0
        while (pages++ < MAX_PAGES) {
            val request = LinkedHashMap<String, JsonValue>()
            request["address"] = JsonObject(
                linkedMapOf(
                    "kind" to JsonString("session"),
                    "sessionId" to JsonString(sessionId),
                ),
            )
            request["throughSeq"] = JsonNumber(cursor.toString())
            beforeSeq?.let { request["beforeSeq"] = JsonNumber(it.toString()) }
            request["maxMessages"] = JsonNumber(pageSize.toString())
            val response = transport.call(
                "session/page",
                JsonObject(linkedMapOf("request" to JsonObject(request))),
            )
            val records = (response["records"] as? JsonArray)?.values ?: break
            var smallest: Long? = null
            for (value in records) {
                val event = (value as? JsonObject)?.get("event") as? JsonObject ?: continue
                val record = decodeRecord(event) ?: continue
                bySeq.putIfAbsent(record.seq, record)
                if (smallest == null || record.seq < smallest!!) smallest = record.seq
            }
            val hasMore = (response["hasMore"] as? JsonBool)?.value == true
            if (!hasMore) break
            val next = smallest ?: break
            if (next == beforeSeq) break
            beforeSeq = next
        }
        return bySeq.values.sortedBy { it.seq }
    }

    private fun readMaterializedJournal(sessionId: String): List<BotSessionLogRecord>? {
        val root = materializedSessions ?: return null
        var newest: Path? = null
        var newestModified: FileTime? = null
        return try {
            Files.walkFileTree(root, object : SimpleFileVisitor<Path>() {
                override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                    val name = file.fileName.toString()
                    if (attrs.isRegularFile && file.parent.fileName.toString() == sessionId &&
                        name.startsWith("session.v") && name.endsWith(".jsonl")
                    ) {
                        val modified = attrs.lastModifiedTime()
                        if (newestModified?.let { modified > it } != false) {
                            newest = file
                            newestModified = modified
                        }
                    }
                    return FileVisitResult.CONTINUE
                }
            })
            newest?.let { file ->
                Files.newInputStream(file, NOFOLLOW_LINKS).bufferedReader().use { reader ->
                    BotSessionLogParser.parseJsonl(reader.readText()).records
                }
            }
        } catch (_: NoSuchFileException) {
            null
        }
    }

    private fun readCursor(sessionId: String): Long? {
        val mux = transport.openFollow()
        try {
            mux.send(followRequestFrame(sessionId))
            while (true) {
                val frame = mux.receive() ?: return null
                when ((frame["type"] as? JsonString)?.value) {
                    "error" -> {
                        val error = frame["error"] as? JsonObject
                        throw BotSessionRemoteException(
                            (error?.members?.get("code") as? JsonString)?.value ?: "stream_error",
                            (error?.members?.get("message") as? JsonString)?.value
                                ?: "session/follow failed",
                        )
                    }
                    "end" -> return null
                    "item" -> {
                        if ((frame["streamId"] as? JsonString)?.value != "follow") continue
                        val value = frame["value"] as? JsonObject ?: continue
                        when ((value["type"] as? JsonString)?.value) {
                            "snapshot" -> return (value["cursor"] as? JsonNumber)?.asLongOrNull()
                            "end" -> return null
                        }
                    }
                }
            }
        } finally {
            runCatching { mux.close() }
        }
    }

    private fun decodeRecord(event: JsonObject): BotSessionLogRecord? {
        val type = (event["type"] as? JsonString)?.value ?: return null
        val seq = (event["seq"] as? JsonNumber)?.asLongOrNull() ?: return null
        val time = (event["time"] as? JsonNumber)?.asLongOrNull() ?: return null
        val data = (event["data"] as? JsonObject)?.members ?: return null
        val eventId = when (val value = event["eventId"]) {
            null, is com.phonedsh.agentcore.JsonNull -> null
            is JsonString -> value.value
            else -> return null
        }
        val surfaceOp = when (val surface = event["surfaceOp"]) {
            null, is com.phonedsh.agentcore.JsonNull -> null
            else -> BotSurfaceOp.decode(surface) ?: return null
        }
        return BotSessionLogRecord(
            type = type,
            seq = seq,
            time = time,
            data = data,
            surfaceOp = surfaceOp,
            eventId = eventId,
        )
    }

    private companion object {
        const val MAX_PAGES: Int = 200
    }
}

/** The §6.2 follow-open request; only the snapshot cursor is read here. */
private fun followRequestFrame(sessionId: String): JsonObject = JsonObject(
    linkedMapOf(
        "type" to JsonString("open"),
        "streamId" to JsonString("follow"),
        "endpoint" to JsonString("session/follow"),
        "payload" to JsonObject(
            linkedMapOf(
                "args" to JsonObject(
                    linkedMapOf(
                        "request" to JsonObject(
                            linkedMapOf(
                                "address" to JsonObject(
                                    linkedMapOf(
                                        "kind" to JsonString("session"),
                                        "sessionId" to JsonString(sessionId),
                                    ),
                                ),
                                "maxMessages" to JsonNumber("1"),
                                "assistantStream" to JsonBool(true),
                            ),
                        ),
                    ),
                ),
            ),
        ),
    ),
)

/**
 * A deterministic in-process [BotSessionTransport] for the UI-path fallback and
 * for tests that need a real turn without an Android Worker.
 *
 * It answers the frozen session/create shape (including the composed
 * `phone-bot` preset), opens an already-snapshotted follow stream and appends
 * one assistant message per prompt. It is explicit about being local: the
 * driver's caller chooses this adapter; no production path silently substitutes
 * it for a failed Worker call.
 */
class LocalBotSessionTransport(
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val reply: (String) -> String = { text -> "收到：$text" },
) : BotSessionTransport {
    /** Endpoint names in call order; useful to prove a stop reached the transport. */
    val calls: MutableList<String> = java.util.concurrent.CopyOnWriteArrayList()

    /** When false, a turn stops after its assistant message until [completeTurn]. */
    @Volatile
    var autoComplete: Boolean = true

    private val lock = Any()
    private var pendingEnd: Pair<String, Int>? = null
    private var nextSession = 0
    private var nextTurn = 0
    private var nextSeq = 0L
    private var mainSessionId: String? = null
    private val follows = ArrayList<LocalFollow>()
    private val sessionCwd = mutableMapOf<String, String>()
    private val journals = mutableMapOf<String, MutableList<JsonObject>>()

    override fun call(endpoint: String, args: JsonObject): JsonObject {
        calls += endpoint
        synchronized(lock) {
            return when (endpoint) {
                "session/create" -> {
                    val request = request(args)
                    val id = (request["sessionId"] as? JsonString)?.value
                        ?: "local-session-${nextSession++}"
                    val preset = (request["agentPreset"] as? JsonString)?.value ?: "phone-bot"
                    mainSessionId = id
                    sessionCwd[id] = (request["cwd"] as? JsonString)?.value.orEmpty()
                    json(
                        "sessionId" to JsonString(id),
                        "agentPreset" to JsonString(preset),
                    )
                }
                "phone/botClaimSession" -> json("ok" to JsonBool(true))
                "session/page" -> {
                    val request = request(args)
                    val address = request["address"] as? JsonObject
                    val id = (address?.members?.get("sessionId") as? JsonString)?.value
                        ?: mainSessionId ?: "local-session"
                    val through = (request["throughSeq"] as? JsonNumber)?.asLongOrNull()
                    val before = (request["beforeSeq"] as? JsonNumber)?.asLongOrNull()
                    val maximum = (request["maxMessages"] as? JsonNumber)?.asLongOrNull()
                        ?.toInt()?.coerceAtLeast(1) ?: 50
                    val all = journals[id].orEmpty()
                        .filter { event ->
                            val seq = (event["seq"] as? JsonNumber)?.asLongOrNull()
                                ?: return@filter false
                            if (through != null && through >= 0 && seq > through) {
                                return@filter false
                            }
                            if (before != null && seq >= before) return@filter false
                            true
                        }
                        .sortedBy { (it["seq"] as? JsonNumber)?.asLongOrNull() ?: 0L }
                    val page = all.takeLast(maximum)
                    JsonObject(
                        linkedMapOf(
                            "sessionId" to JsonString(id),
                            "records" to JsonArray(page.map { event ->
                                JsonObject(linkedMapOf("event" to event))
                            }),
                            "hasMore" to JsonBool(all.size > page.size),
                        ),
                    )
                }
                "session/prompt" -> {
                    val request = request(args)
                    val id = (request["sessionId"] as? JsonString)?.value
                        ?: mainSessionId ?: "local-session"
                    val requestId = (request["requestId"] as? JsonString)?.value
                    val text = textOf(request["content"])
                    enqueueTurn(id, text, requestId)
                    json("accepted" to JsonBool(true))
                }
                "session/cancel" -> {
                    val request = request(args)
                    val id = (request["sessionId"] as? JsonString)?.value
                        ?: mainSessionId ?: "local-session"
                    val turn = pendingEnd?.second ?: nextTurn
                    pendingEnd = null
                    enqueueToSession(id, item(event(
                        type = "turn/end",
                        seq = nextSeq(),
                        data = json(
                            "turn" to JsonNumber(turn.toString()),
                            "reason" to json("kind" to JsonString("aborted")),
                        ),
                    )))
                    json("ok" to JsonBool(true))
                }
                "session/list" -> {
                    val items = sessionCwd.entries.map { (id, cwd) ->
                        val last = journals[id]?.maxOfOrNull {
                            (it["time"] as? JsonNumber)?.asLongOrNull() ?: 0L
                        } ?: 0L
                        json(
                            "sessionId" to JsonString(id),
                            "cwd" to JsonString(cwd),
                            "updatedAt" to JsonNumber(last.toString()),
                        )
                    }
                    JsonObject(linkedMapOf("items" to JsonArray(items)))
                }
                "workspace/archiveSession", "workspace/unarchiveSession" ->
                    json("ok" to JsonBool(true))
                else -> json("ok" to JsonBool(true))
            }
        }
    }

    override fun openFollow(): BotFollowConnection {
        synchronized(lock) {
            return LocalFollow().also { follows += it }
        }
    }

    private fun enqueueTurn(sessionId: String, text: String, requestId: String?) {
        val turn = ++nextTurn
        val replyText = reply(text)
        enqueueToSession(sessionId, item(event(
            type = "user/message",
            seq = nextSeq(),
            data = json(
                "role" to JsonString("user"),
                "content" to JsonArray(
                    listOf(json("type" to JsonString("text"), "text" to JsonString(text))),
                ),
                "source" to json(
                    "kind" to JsonString("user"),
                    "rpcId" to JsonString(requestId ?: "user-action:local"),
                ),
                "surfaceOp" to JsonString("append"),
                "turn" to JsonNumber(turn.toString()),
            ),
        )))
        enqueueToSession(sessionId, item(event(
            type = "turn/start",
            seq = nextSeq(),
            data = json("turn" to JsonNumber(turn.toString())),
        )))
        enqueueToSession(sessionId, item(event(
            type = "assistant/message",
            seq = nextSeq(),
            data = json(
                "turn" to JsonNumber(turn.toString()),
                "message" to json(
                    "role" to JsonString("assistant"),
                    "content" to JsonArray(
                        listOf(json("type" to JsonString("text"), "text" to JsonString(replyText))),
                    ),
                ),
            ),
        )))
        if (autoComplete) {
            enqueueEnd(sessionId, turn, cancelled = false)
        } else {
            pendingEnd = sessionId to turn
        }
    }

    /** Completes the turn held by `autoComplete = false`. */
    fun completeTurn() {
        val (sessionId, turn) = synchronized(lock) {
            pendingEnd.also { pendingEnd = null }
        } ?: return
        enqueueEnd(sessionId, turn, cancelled = false)
    }

    private fun enqueueEnd(sessionId: String, turn: Int, cancelled: Boolean) {
        enqueueToSession(sessionId, item(event(
            type = "turn/end",
            seq = nextSeq(),
            data = json(
                "turn" to JsonNumber(turn.toString()),
                "reason" to json(
                    "kind" to JsonString(if (cancelled) "aborted" else "completed"),
                ),
            ),
        )))
    }

    /**
     * Persist one live event in the session journal and hand it to the newest
     * still-open follow for that session. A history reader's snapshot-only
     * follow is never mistaken for the turn's stream.
     */
    private fun enqueueToSession(sessionId: String, value: JsonObject) {
        val event = (value["value"] as? JsonObject)?.get("event") as? JsonObject
        synchronized(lock) {
            if (event != null) {
                journals.getOrPut(sessionId) { mutableListOf() } += event
            }
            val target = follows.lastOrNull { it.sessionId == sessionId }
                ?: follows.lastOrNull { it.sessionId == null }
            target?.enqueue(value)
        }
    }

    private fun journalCursor(sessionId: String?): Long {
        if (sessionId == null) return 0L
        return synchronized(lock) {
            journals[sessionId].orEmpty()
                .maxOfOrNull { (it["seq"] as? JsonNumber)?.asLongOrNull() ?: 0L } ?: 0L
        }
    }

    private fun item(event: JsonObject): JsonObject = json(
        "type" to JsonString("item"),
        "streamId" to JsonString("follow"),
        "value" to json(
            "type" to JsonString("event"),
            "event" to event,
        ),
    )

    private fun event(type: String, seq: Long, data: JsonObject): JsonObject = json(
        "type" to JsonString(type),
        "seq" to JsonNumber(seq.toString()),
        "time" to JsonNumber(clock().toString()),
        "eventId" to JsonString("local-$seq"),
        "data" to data,
    )

    private fun nextSeq(): Long = synchronized(lock) { nextSeq += 1; nextSeq }

    private inner class LocalFollow : BotFollowConnection {
        private val queue = LinkedBlockingQueue<JsonObject>()
        @Volatile
        var sessionId: String? = null
        @Volatile
        private var closed = false
        private var snapshotSent = false

        override fun send(frame: JsonObject) {
            val request = ((frame["payload"] as? JsonObject)
                ?.members?.get("args") as? JsonObject)
                ?.members?.get("request") as? JsonObject
            val address = request?.members?.get("address") as? JsonObject
            sessionId = (address?.members?.get("sessionId") as? JsonString)?.value
                ?: (request?.members?.get("sessionId") as? JsonString)?.value
        }

        override fun receive(): JsonObject? {
            if (!snapshotSent) {
                snapshotSent = true
                return json(
                    "type" to JsonString("item"),
                    "streamId" to JsonString("follow"),
                    "value" to json(
                        "type" to JsonString("snapshot"),
                        "cursor" to JsonNumber(journalCursor(sessionId).toString()),
                    ),
                )
            }
            while (true) {
                if (closed) return null
                val item = queue.poll(1, TimeUnit.SECONDS) ?: continue
                if ((item["type"] as? JsonString)?.value == "end") {
                    closed = true
                }
                return item
            }
        }

        override fun close() {
            closed = true
            queue.clear()
            synchronized(lock) { follows.remove(this) }
        }

        fun enqueue(item: JsonObject) {
            if (!closed) queue.put(item)
        }
    }

    private fun request(args: JsonObject): Map<String, JsonValue> =
        (args.members["request"] as? JsonObject)?.members ?: args.members

    private fun textOf(content: JsonValue?): String =
        (content as? JsonArray)?.values?.mapNotNull { block ->
            val members = (block as? JsonObject)?.members ?: return@mapNotNull null
            if ((members["type"] as? JsonString)?.value != "text") return@mapNotNull null
            (members["text"] as? JsonString)?.value
        }?.joinToString("").orEmpty()

    private fun json(vararg fields: Pair<String, JsonValue>): JsonObject =
        JsonObject(linkedMapOf(*fields))
}
