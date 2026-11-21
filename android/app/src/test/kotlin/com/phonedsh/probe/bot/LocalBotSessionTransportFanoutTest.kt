// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.session.BotFollowConnection
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Before
import org.junit.Test

/**
 * Regression for the live-follow fanout race in [LocalBotSessionTransport].
 *
 * The real history reader (`BotSessionHistoryReader.readCursor`) opens a
 * second `session/follow` for the session it is reading, consumes only the
 * snapshot cursor and closes it. During that window there are two open
 * same-session follows: the live turn follow and the history snapshot follow.
 * `LocalBotSessionTransport` used to hand every live event to the newest
 * matching follow only, so a prompt racing the history snapshot was delivered
 * to the snapshot follow and lost by the live turn follow.
 *
 * This test reproduces the window deterministically: both same-session follows
 * stay open across a real `session/prompt`, and both must receive the prompt's
 * `user/message`, `turn/start` and `assistant/message` in the same seq order.
 * Cross-session isolation is pinned as well. Every blocking `receive` is
 * bounded through `Future.get`, and the follows plus the executor are closed
 * in `finally`, so the regression fails in seconds rather than hanging.
 */
class LocalBotSessionTransportFanoutTest {
    private lateinit var transport: LocalBotSessionTransport
    private lateinit var receiver: ExecutorService

    /** Every follow opened here, oldest first; closed in reverse order. */
    private val followers = ArrayList<BotFollowConnection>()

    @Before
    fun setUp() {
        transport = LocalBotSessionTransport(
            clock = { 1_000L },
            reply = { text -> "reply:$text" },
        )
        receiver = Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "local-bot-follow-receive").apply { isDaemon = true }
        }
    }

    @After
    fun tearDown() {
        // The test also closes in its own finally; this guard covers a failure
        // thrown before that block is entered. Both paths are idempotent.
        closeAll()
    }

    private fun closeAll() {
        // close() is what unblocks a follower blocked in its 1 s queue poll.
        followers.asReversed().forEach { follow -> runCatching { follow.close() } }
        followers.clear()
        if (this::receiver.isInitialized) {
            receiver.shutdownNow()
            runCatching { receiver.awaitTermination(5, TimeUnit.SECONDS) }
        }
    }

    @Test
    fun liveFollowAndLaterHistorySnapshotForTheSameSessionBothReceiveThePromptTurn() {
        try {
            val sessionId = "fanout-session"
            val otherSessionId = "fanout-other-session"
            createSession(sessionId)
            createSession(otherSessionId)

            // The live turn follow: open it and consume its initial snapshot.
            val live = openFollowAndSnapshot(turnFollowFrame(sessionId), "live turn follow")

            // The history reader's cursor-only follow (the real reader uses
            // maxMessages = 1 in BotSessionHistoryReader.readCursor). The real
            // reader closes it after the snapshot; here it stays open so the
            // race window between the snapshot and the next close is
            // deterministic.
            val history = openFollowAndSnapshot(
                historySnapshotFollowFrame(sessionId),
                "history snapshot follow",
            )
            assertEquals(
                "both same-session follows must snapshot the same pre-prompt cursor",
                live.cursor,
                history.cursor,
            )

            // A follow for another session must stay silent for this prompt.
            val other = openFollowAndSnapshot(
                turnFollowFrame(otherSessionId),
                "other-session follow",
            )

            val accepted = prompt(sessionId, "fanout hello")
            assertEquals(
                "the real session/prompt must be accepted before the receives are bounded",
                true,
                (accepted["accepted"] as? JsonBool)?.value,
            )

            val expectedTypes = listOf("user/message", "turn/start", "assistant/message")
            val liveEvents = awaitEvents(live.follow, expectedTypes, "live turn follow")
            val historyEvents = awaitEvents(
                history.follow,
                expectedTypes,
                "history snapshot follow",
            )

            assertEquals(
                "the oldest same-session live follow must receive the whole first turn sequence",
                expectedTypes,
                liveEvents.map { it.type },
            )
            assertEquals(
                "the later history snapshot follow must receive the same first turn sequence",
                expectedTypes,
                historyEvents.map { it.type },
            )
            assertEquals(
                "both same-session follows must observe the same event seq order",
                liveEvents.map { it.seq },
                historyEvents.map { it.seq },
            )

            val liveTurn = liveEvents[1].turn
            assertNotNull("live follow turn/start must identify its turn", liveTurn)
            assertNotNull(
                "history follow turn/start must identify its turn",
                historyEvents[1].turn,
            )
            assertEquals(
                "both same-session follows must observe the same turn/start turn",
                liveTurn,
                historyEvents[1].turn,
            )
            assertEquals(
                "the live assistant/message must belong to the live turn/start",
                liveTurn,
                liveEvents[2].turn,
            )
            assertEquals(
                "the history assistant/message must belong to the same turn/start",
                liveTurn,
                historyEvents[2].turn,
            )
            assertEquals("reply:fanout hello", liveEvents[2].text)
            assertEquals(
                "both same-session follows must observe the same assistant text",
                liveEvents[2].text,
                historyEvents[2].text,
            )

            assertNoEvent(other.follow, "other-session follow")
        } finally {
            closeAll()
        }
    }

    // ------------------------------------------------------------------
    // Session and follow setup
    // ------------------------------------------------------------------

    private fun createSession(sessionId: String) {
        val created = transport.call(
            "session/create",
            json(
                "request" to json(
                    "sessionId" to JsonString(sessionId),
                    "cwd" to JsonString("/tmp/fanout"),
                    "agentPreset" to JsonString("phone-bot"),
                ),
            ),
        )
        assertEquals(sessionId, (created["sessionId"] as? JsonString)?.value)
    }

    private fun prompt(sessionId: String, text: String): JsonObject = transport.call(
        "session/prompt",
        json(
            "request" to json(
                "requestId" to JsonString("fanout-request-1"),
                "sessionId" to JsonString(sessionId),
                "mode" to JsonString("queue"),
                "content" to JsonArray(
                    listOf(
                        json(
                            "type" to JsonString("text"),
                            "text" to JsonString(text),
                        ),
                    ),
                ),
            ),
        ),
    )

    private data class OpenedFollow(val follow: BotFollowConnection, val cursor: Long)

    private fun openFollowAndSnapshot(frame: JsonObject, description: String): OpenedFollow {
        val follow = transport.openFollow()
        followers += follow
        follow.send(frame)
        val snapshotFrame = awaitFrame(follow, "$description snapshot")
        assertEquals("$description: first frame type", "item", stringField(snapshotFrame, "type"))
        assertEquals("$description: stream id", "follow", stringField(snapshotFrame, "streamId"))
        val value = snapshotFrame["value"] as? JsonObject
            ?: throw AssertionError("$description: snapshot frame has no value object")
        assertEquals("$description: first value type", "snapshot", stringField(value, "type"))
        val cursor = (value["cursor"] as? JsonNumber)?.asLongOrNull()
            ?: throw AssertionError("$description: snapshot has no integer cursor")
        return OpenedFollow(follow = follow, cursor = cursor)
    }

    // ------------------------------------------------------------------
    // Bounded receives
    // ------------------------------------------------------------------

    private fun awaitFrame(follow: BotFollowConnection, description: String): JsonObject {
        val future = receiver.submit<JsonObject?> { follow.receive() }
        return try {
            future.get(EVENT_WAIT_MILLIS, TimeUnit.MILLISECONDS)
                ?: throw AssertionError("$description: follow ended before the expected frame")
        } catch (timeout: TimeoutException) {
            throw AssertionError(
                "$description: no follow frame arrived within $EVENT_WAIT_MILLIS ms",
                timeout,
            )
        }
    }

    private fun awaitEvents(
        follow: BotFollowConnection,
        expectedTypes: List<String>,
        description: String,
    ): List<ObservedEvent> {
        val events = ArrayList<ObservedEvent>(expectedTypes.size)
        for (index in expectedTypes.indices) {
            val expectedType = expectedTypes[index]
            val frame = awaitEventFrame(
                follow,
                "$description event ${index + 1} (expected $expectedType)",
            )
            val event = observe(frame, description)
            events += event
            assertEquals(
                "$description event ${index + 1} type",
                expectedType,
                event.type,
            )
        }
        return events
    }

    private fun awaitEventFrame(follow: BotFollowConnection, description: String): JsonObject {
        val future = receiver.submit<JsonObject?> { follow.receive() }
        return try {
            future.get(EVENT_WAIT_MILLIS, TimeUnit.MILLISECONDS)
                ?: throw AssertionError("$description: follow ended before the event arrived")
        } catch (timeout: TimeoutException) {
            throw AssertionError(
                "$description: no event arrived within $EVENT_WAIT_MILLIS ms; " +
                    "newest-only routing hands each live event to one same-session follow, " +
                    "so the other open same-session follow lost it",
                timeout,
            )
        }
    }

    private fun assertNoEvent(follow: BotFollowConnection, description: String) {
        val future = receiver.submit<JsonObject?> { follow.receive() }
        try {
            val frame = future.get(NO_EVENT_WAIT_MILLIS, TimeUnit.MILLISECONDS)
            throw AssertionError(
                "$description received another session's prompt frame: $frame",
            )
        } catch (_: TimeoutException) {
            // Expected: routing is per session, not a global broadcast.
        } finally {
            future.cancel(true)
        }
    }

    private fun observe(frame: JsonObject, description: String): ObservedEvent {
        assertEquals("$description: frame type", "item", stringField(frame, "type"))
        val value = frame["value"] as? JsonObject
            ?: throw AssertionError("$description: item frame has no value object")
        assertEquals("$description: value type", "event", stringField(value, "type"))
        val event = value["event"] as? JsonObject
            ?: throw AssertionError("$description: item value has no event object")
        val type = stringField(event, "type")
            ?: throw AssertionError("$description: event has no type")
        val seq = (event["seq"] as? JsonNumber)?.asLongOrNull()
            ?: throw AssertionError("$description: event $type has no integer seq")
        val data = event["data"] as? JsonObject
        val turn = (data?.get("turn") as? JsonNumber)?.asLongOrNull()
        return ObservedEvent(
            type = type,
            seq = seq,
            turn = turn,
            text = assistantText(data),
        )
    }

    private fun assistantText(data: JsonObject?): String? {
        val message = data?.get("message") as? JsonObject ?: return null
        val blocks = (message["content"] as? JsonArray)?.values ?: return null
        return blocks.mapNotNull { block ->
            val members = (block as? JsonObject)?.members ?: return@mapNotNull null
            if ((members["type"] as? JsonString)?.value != "text") return@mapNotNull null
            (members["text"] as? JsonString)?.value
        }.joinToString("")
    }

    // ------------------------------------------------------------------
    // Follow-open frames (same shapes the runtime and history reader send)
    // ------------------------------------------------------------------

    private fun turnFollowFrame(sessionId: String): JsonObject =
        followFrame(sessionId, maxMessages = 64)

    private fun historySnapshotFollowFrame(sessionId: String): JsonObject =
        followFrame(sessionId, maxMessages = 1)

    private fun followFrame(sessionId: String, maxMessages: Int): JsonObject = json(
        "type" to JsonString("open"),
        "streamId" to JsonString("follow"),
        "endpoint" to JsonString("session/follow"),
        "payload" to json(
            "args" to json(
                "request" to json(
                    "address" to json(
                        "kind" to JsonString("session"),
                        "sessionId" to JsonString(sessionId),
                    ),
                    "maxMessages" to JsonNumber(maxMessages.toString()),
                    "assistantStream" to JsonBool(true),
                ),
            ),
        ),
    )

    private fun stringField(value: JsonObject?, key: String): String? =
        (value?.get(key) as? JsonString)?.value

    private fun json(vararg fields: Pair<String, JsonValue>): JsonObject =
        JsonObject(linkedMapOf(*fields))

    private data class ObservedEvent(
        val type: String,
        val seq: Long,
        val turn: Long?,
        val text: String?,
    )

    private companion object {
        /** Bound on one receive; a correct fanout queues events before the prompt returns. */
        const val EVENT_WAIT_MILLIS: Long = 5_000L

        /** Short window used only to prove another session's follow stays silent. */
        const val NO_EVENT_WAIT_MILLIS: Long = 1_000L
    }
}
