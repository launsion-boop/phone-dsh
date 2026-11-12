// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.session.BotFollowConnection
import com.phonedsh.bot.session.BotSessionRemoteException
import com.phonedsh.bot.session.BotSessionTransport
import com.phonedsh.dsh.host.HostChannel
import com.phonedsh.dsh.turn.DshTurnClient
import com.phonedsh.dsh.turn.DshTurnException
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
    private var follow: LocalFollow? = null
    private val sessionCwd = mutableMapOf<String, String>()

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
                        ?: mainSessionId
                    json("sessionId" to JsonString(id ?: "local-session"))
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
                    follow?.let { enqueueEnd(it, id, turn, cancelled = true) }
                    json("ok" to JsonBool(true))
                }
                "session/list" -> {
                    val items = sessionCwd.entries.map { (id, cwd) ->
                        json("sessionId" to JsonString(id), "cwd" to JsonString(cwd))
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
            return LocalFollow().also { follow = it }
        }
    }

    private fun enqueueTurn(sessionId: String, text: String, requestId: String?) {
        val active = follow ?: return
        val turn = ++nextTurn
        val replyText = reply(text)
        active.enqueue(
            item(event(
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
            )),
        )
        active.enqueue(
            item(event(
                type = "turn/start",
                seq = nextSeq(),
                data = json("turn" to JsonNumber(turn.toString())),
            )),
        )
        active.enqueue(
            item(event(
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
            )),
        )
        if (autoComplete) {
            enqueueEnd(active, sessionId, turn, cancelled = false)
        } else {
            pendingEnd = sessionId to turn
        }
    }

    /** Completes the turn held by `autoComplete = false`. */
    fun completeTurn() {
        val (sessionId, turn) = synchronized(lock) {
            pendingEnd.also { pendingEnd = null }
        } ?: return
        val active = synchronized(lock) { follow } ?: return
        enqueueEnd(active, sessionId, turn, cancelled = false)
    }

    private fun enqueueEnd(
        active: LocalFollow,
        sessionId: String,
        turn: Int,
        cancelled: Boolean,
    ) {
        active.enqueue(
            item(event(
                type = "turn/end",
                seq = nextSeq(),
                data = json(
                    "turn" to JsonNumber(turn.toString()),
                    "reason" to json(
                        "kind" to JsonString(if (cancelled) "aborted" else "completed"),
                    ),
                ),
            )),
        )
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
        private var sessionId: String? = null
        private var closed = false
        private var snapshotSent = false

        init {
            queue.put(
                json(
                    "type" to JsonString("item"),
                    "streamId" to JsonString("follow"),
                    "value" to json("type" to JsonString("snapshot")),
                ),
            )
        }

        override fun send(frame: JsonObject) {
            val request = ((frame["payload"] as? JsonObject)
                ?.members?.get("args") as? JsonObject)
                ?.members?.get("request") as? JsonObject
            val address = request?.members?.get("address") as? JsonObject
            sessionId = (address?.members?.get("sessionId") as? JsonString)?.value
                ?: (request?.members?.get("sessionId") as? JsonString)?.value
        }

        override fun receive(): JsonObject? {
            while (true) {
                if (closed) return null
                val item = queue.poll(1, TimeUnit.SECONDS) ?: continue
                return if ((item["type"] as? JsonString)?.value == "end") {
                    closed = true
                    item
                } else {
                    item
                }
            }
        }

        override fun close() {
            closed = true
            queue.clear()
        }

        fun enqueue(item: JsonObject) {
            if (!closed) queue.put(item)
        }

        fun finishTurn(sessionId: String, cancelled: Boolean) {
            enqueue(
                event(
                    type = "turn/end",
                    seq = nextSeq(),
                    data = json(
                        "reason" to json(
                            "kind" to JsonString(if (cancelled) "aborted" else "completed"),
                        ),
                    ),
                ),
            )
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
