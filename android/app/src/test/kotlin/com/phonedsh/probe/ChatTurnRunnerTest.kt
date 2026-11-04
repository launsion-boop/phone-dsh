// Which failures may discard a conversation's Worker session (L85 P0).
// SPDX-License-Identifier: MIT
//
// ---- the rule this test pins ----------------------------------------------
// A Worker session id is **resumable**: the Worker persists its log under
// `/dsh/home/sessions`, the host repacks `/dsh/home` into every boot overlay, and
// `session/prompt` resumes a non-live session from that log. Only the Worker's own
// `session/not-found` verdict says the log is really gone. Every other failure
// leaves the log intact, so opening a new session on it would change "the model
// lost this turn" into "the model lost the conversation" — the worst state for a
// user, because the transcript still shows the earlier messages.
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.dsh.host.HostChannel
import com.phonedsh.dsh.host.HostFence
import com.phonedsh.dsh.host.HostHello
import com.phonedsh.dsh.host.HostLog
import com.phonedsh.dsh.host.WalUplink
import com.phonedsh.dsh.turn.DshTurnClient
import com.phonedsh.dsh.turn.DshTurnException
import com.phonedsh.loopback.ChannelCloseCause
import com.phonedsh.loopback.LoopbackConnection
import com.phonedsh.wire.WireCodec
import com.phonedsh.hostevents.HostEventKind
import java.util.LinkedHashMap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout

class ChatTurnRunnerTest {
    @Test
    fun retryReusesTheOriginalPromptIdempotencyIdentity() = runBlocking<Unit> {
        val peer = ScriptedRunnerPeer(this)
        val host = testHost()
        peer.attach(host)
        peer.connect()
        peer.turnEndDelayMillis = 1
        val runner = ChatTurnRunner(
            channel = host,
            client = DshTurnClient(host),
            firstEventTimeoutMillis = 500,
            nextReadTimeoutMillis = 20,
        )
        runner.run(
            workerSessionId = "session-existing",
            prompt = "the failed original prompt",
            promptRequestId = "stable-original-prompt-id",
            onSession = {},
            onEvent = {},
            onDelta = {},
        )
        assertEquals(listOf("stable-original-prompt-id"), peer.promptRequestIds)
    }

    @Test
    fun busySteerUsesTheWorkerSteerModeAndItsCallerRequestId() = runBlocking<Unit> {
        val peer = ScriptedRunnerPeer(this)
        val host = testHost()
        peer.attach(host)
        peer.connect()
        peer.turnEndDelayMillis = 1
        val runner = ChatTurnRunner(
            channel = host,
            client = DshTurnClient(host),
            firstEventTimeoutMillis = 500,
            nextReadTimeoutMillis = 20,
        )
        runner.run(
            workerSessionId = "worker-running",
            prompt = "steer this turn",
            onSession = {},
            onEvent = {},
            onDelta = {},
            promptRequestId = "ui.steer.action-1",
            promptMode = "steer",
        )
        assertEquals(listOf("ui.steer.action-1"), peer.promptRequestIds)
        assertEquals(listOf("steer"), peer.promptModes)
    }

    @Test
    fun followReaderReassemblesSplitUtf8AndContinuesAfterQuietWindow() = runBlocking<Unit> {
        val chunks = Channel<ByteArray>(Channel.UNLIMITED)
        val reader = FollowFrameReader(chunks)
        val line = """{"type":"item","value":{"text":"你好🙂"}}""".toByteArray(Charsets.UTF_8)
        val split = line.indexOfFirst { (it.toInt() and 0xC0) == 0xC0 }
        chunks.send(line.copyOfRange(0, split + 1))
        chunks.send(line.copyOfRange(split + 1, line.size) + byteArrayOf('\n'.code.toByte()))

        val item = reader.next(100)!!
        assertEquals("你好🙂", ((item["value"] as JsonObject)["text"] as com.phonedsh.agentcore.JsonString).value)
        assertNull(reader.next(1))
        assertFalse("a read timeout leaves the stream open", reader.isFinished)

        chunks.send("""{"type":"end"}""".toByteArray() + byteArrayOf('\n'.code.toByte()))
        assertEquals("end", (reader.next(100)!!["type"] as com.phonedsh.agentcore.JsonString).value)
        assertTrue(reader.isFinished)
        chunks.close()
    }

    @Test
    fun followReaderCancellationPropagatesAndDoesNotBecomeAQuietTimeout() = runBlocking<Unit> {
        val chunks = Channel<ByteArray>(Channel.UNLIMITED)
        val reader = FollowFrameReader(chunks)
        val waiting: Job = launch { reader.next(10_000) }
        kotlinx.coroutines.yield()
        waiting.cancelAndJoin()
        assertFalse(reader.isFinished)
        chunks.close()
    }

    @Test
    fun chatRunnerContinuesAfterSeveralQuietReadsUntilTheTurnEndEvent() = runBlocking<Unit> {
        val peer = ScriptedRunnerPeer(this)
        val host = testHost()
        peer.attach(host)
        peer.connect()
        peer.turnEndDelayMillis = 120
        val runner = ChatTurnRunner(
            channel = host,
            client = DshTurnClient(host),
            firstEventTimeoutMillis = 500,
            nextReadTimeoutMillis = 20,
        )
        val startedAt = System.currentTimeMillis()
        val outcome = withTimeout(2_000) {
            runner.run("session-existing", "wait for completion", {}, {}, {})
        }
        assertTrue("the peer held the stream quiet across multiple read windows", System.currentTimeMillis() - startedAt >= 80)
        assertTrue(outcome.completed)
        assertEquals(2, outcome.events.count { it.kind == HostEventKind.TURN_STARTED || it.kind == HostEventKind.TURN_ENDED })
    }

    @Test
    fun chatRunnerKeepsTheExistingFirstEventDeadline() = runBlocking<Unit> {
        val peer = ScriptedRunnerPeer(this)
        val host = testHost()
        peer.attach(host)
        peer.sendTurnStartedOnPrompt = false
        peer.connect()
        val runner = ChatTurnRunner(
            channel = host,
            client = DshTurnClient(host),
            firstEventTimeoutMillis = 40,
            nextReadTimeoutMillis = 10,
        )
        val failure = try {
            runner.run("session-existing", "never starts", {}, {}, {})
            null
        } catch (caught: DshTurnException) {
            caught
        }
        assertEquals("no_turn_started", failure?.code)
    }

    @Test
    fun chatRunnerCancellationAfterTurnStartPropagatesToItsCaller() = runBlocking<Unit> {
        val peer = ScriptedRunnerPeer(this)
        val host = testHost()
        peer.attach(host)
        peer.connect()
        val turnStarted = CompletableDeferred<Unit>()
        val runner = ChatTurnRunner(
            channel = host,
            client = DshTurnClient(host),
            firstEventTimeoutMillis = 500,
            nextReadTimeoutMillis = 20,
        )
        val running = async(SupervisorJob() + Dispatchers.Default) {
            runner.run("session-existing", "cancel me", {},
                { if (it.kind == HostEventKind.TURN_STARTED) turnStarted.complete(Unit) }, {})
        }
        try {
            withTimeout(2_000) { turnStarted.await() }
        } catch (failure: Throwable) {
            running.cancelAndJoin()
            throw AssertionError("runner did not start; scripted peer failure: ${peer.lastFailure}", failure)
        }
        running.cancelAndJoin()
        assertTrue(running.isCancelled)
        assertEquals("cancel cleanup must close the Worker mux", 1, peer.muxCloseIds.size)
        assertEquals(peer.openMuxId, peer.muxCloseIds.single())
    }

    @Test
    fun chatRunnerBoundsCancellationCleanupWhenMuxCloseSendStalls() = runBlocking<Unit> {
        val peer = ScriptedRunnerPeer(this).apply { stallMuxCloseSend = true }
        val host = testHost()
        peer.attach(host)
        peer.connect()
        val turnStarted = CompletableDeferred<Unit>()
        val runner = ChatTurnRunner(
            channel = host,
            client = DshTurnClient(host),
            firstEventTimeoutMillis = 500,
            nextReadTimeoutMillis = 20,
        )
        val running = async(SupervisorJob() + Dispatchers.Default) {
            runner.run("session-existing", "cancel with stalled close", {},
                { if (it.kind == HostEventKind.TURN_STARTED) turnStarted.complete(Unit) }, {})
        }
        withTimeout(2_000) { turnStarted.await() }
        val startedAt = System.nanoTime()
        running.cancel()
        withTimeout(6_500) { running.cancelAndJoin() }
        val elapsedMillis = (System.nanoTime() - startedAt) / 1_000_000L
        assertTrue("mux close request was sent before it stalled", peer.closeSendEntered.isCompleted)
        assertTrue("cancel cleanup should respect its 5s API timeout: ${elapsedMillis}ms", elapsedMillis < 6_500)
        assertEquals(peer.openMuxId, peer.muxCloseIds.single())
    }

    @Test
    fun `only the events stream ready item yields a client id`() {
        val ready = JsonValue.parse(
            """{"type":"item","streamId":"events","value":{"type":"ready","clientId":"client-17"}}""",
        ) as JsonObject
        assertEquals("client-17", eventsReadyClientId(ready))

        val followSnapshot = JsonValue.parse(
            """{"type":"item","streamId":"follow","value":{"type":"snapshot","records":[]}}""",
        ) as JsonObject
        assertNull(eventsReadyClientId(followSnapshot))

        val eventBeforeReady = JsonValue.parse(
            """{"type":"item","streamId":"events","value":{"type":"waterfall","eventId":"event-1"}}""",
        ) as JsonObject
        assertNull(eventsReadyClientId(eventBeforeReady))
    }

    @Test
    fun `live reasoning fragments are forwarded as content and never mistaken for answer deltas`() {
        val reasoning = JsonValue.parse("""{"type":"reasoning-delta","text":"Checking the request."}""")
        assertEquals("Checking the request.", reasoningDeltaOf(reasoning))
        val answer = JsonValue.parse("""{"type":"text-delta","text":"The answer."}""")
        assertNull(reasoningDeltaOf(answer))
    }

    @Test
    fun onlyTheWorkersNotFoundVerdictRetiresTheSession() {
        assertTrue(
            "session/not-found is the one answer that means the durable log is gone, " +
                "so it is the one answer that may open a new session",
            workerSessionGone("session/not-found"),
        )
        for (code in listOf(
            // The symptom the old code misread as "stale session": the stream
            // produced no turn. The prompt may have been deduplicated or the model
            // may have failed; neither is evidence about the log.
            "no_turn_started",
            "stream_error",
            "invalid_response",
            "session_create_unavailable",
            // The session exists but another writer owns it: opening a new one
            // would be a second conversation, not a repair.
            "session/writer-held",
            "gateway/internal",
            "HostApiException",
            "",
            null,
        )) {
            assertFalse(
                "a failure with code ${code ?: "<null>"} must not discard the stored " +
                    "Worker session: the durable history is still there and the person " +
                    "must be told, not given a fresh context",
                workerSessionGone(code),
            )
        }
    }

    private fun testHost(): HostChannel {
        val hello = HostHello(
            bootId = "0123456789abcdef0123456789abcdef",
            sessionEpoch = 0,
            fence = HostFence.LOCAL,
            wal = WalUplink.down("stream test has no WAL"),
        )
        return HostChannel(hello = { hello }, logger = HostLog.None)
    }

    /** Minimal API peer on the real HostChannel; only the Worker responses are scripted. */
    private class ScriptedRunnerPeer(private val scope: CoroutineScope) : LoopbackConnection {
        override val id: String = "chat-runner-stream-test"
        lateinit var host: HostChannel
        var sendTurnStartedOnPrompt: Boolean = true
        var turnEndDelayMillis: Long? = null
        val promptRequestIds = mutableListOf<String>()
        val promptModes = mutableListOf<String>()
        var openMuxId: String? = null
        val muxCloseIds = mutableListOf<String>()
        var stallMuxCloseSend: Boolean = false
        val closeSendEntered = CompletableDeferred<Unit>()
        private val neverFinishCloseSend = CompletableDeferred<Unit>()
        var lastFailure: Throwable? = null
        private var workerSeq = 2L
        private var followRequestId: Int? = null

        fun attach(host: HostChannel) { this.host = host }

        suspend fun connect() {
            host.onOpen(this)
            host.onBinary(
                this,
                WireCodec.encode(
                    """
                    {"type":"HELLO","fields":{
                      "boot_id":"ffeeddccbbaa99887766554433221100",
                      "caps":["channel/1","api/1"],
                      "fence":{"generation":0,"owner":"phone","wal_seq":0},
                      "last_mseq":0,"proto":1,"role":"worker","session_epoch":0
                    }}
                    """.trimIndent(),
                    1L,
                ),
            )
        }

        override suspend fun sendBinary(payload: ByteArray) {
            try {
                handleApiRequest(payload)
            } catch (failure: Throwable) {
                lastFailure = failure
                throw failure
            }
        }

        private suspend fun handleApiRequest(payload: ByteArray) {
            if (payload.size < 16 || (payload[2].toInt() and 0xFF) != 0x40) return
            val fields = JsonValue.parse(WireCodec.decode(payload)) as JsonObject
            val reqId = (fields["req_id"] as JsonNumber).asLongOrNull()!!.toInt()
            val head = fields["head"] as JsonObject
            val path = (head["path"] as JsonString).value
            val headers = head["headers"] as JsonObject
            val body = unhex((fields["body_hex"] as JsonString).value)
            val rpcId = runCatching {
                (JsonValue.parse(String(body, Charsets.UTF_8)) as JsonObject)["rpcId"] as? JsonString
            }.getOrNull()?.value
            when {
                path == "/api/remote.mux" && (headers["x-pdsh-mux-op"] as? JsonString)?.value == "receive" -> {
                    openMuxId = (headers["x-pdsh-mux-id"] as? JsonString)?.value
                    followRequestId = reqId
                    sendApiRes(reqId, ByteArray(0), withHead = true)
                    sendFollowLine(
                        """{"type":"item","streamId":"events","value":{"type":"ready","clientId":"client-stream-test"}}""",
                    )
                }
                path == "/api/remote.mux" && (headers["x-pdsh-mux-op"] as? JsonString)?.value == "close" -> {
                    (headers["x-pdsh-mux-id"] as? JsonString)?.value?.let(muxCloseIds::add)
                    if (stallMuxCloseSend) {
                        closeSendEntered.complete(Unit)
                        neverFinishCloseSend.await()
                    } else {
                        sendUnaryResponse(reqId, rpcId)
                    }
                }
                path == "/api/session/prompt" -> {
                    val request = (((JsonValue.parse(String(body, Charsets.UTF_8)) as JsonObject)["payload"] as JsonObject)
                        ["args"] as JsonObject)["request"] as JsonObject
                    promptRequestIds += (request["requestId"] as JsonString).value
                    promptModes += (request["mode"] as JsonString).value
                    if (sendTurnStartedOnPrompt) {
                        sendFollowLine(
                            """{"type":"item","streamId":"follow","value":{"type":"event","event":{"seq":1,"type":"turn/start","data":{"turn":1}}}}""",
                        )
                    }
                    val delayMillis = turnEndDelayMillis
                    if (delayMillis != null) scope.launch {
                        delay(delayMillis)
                        sendFollowLine(
                            """{"type":"item","streamId":"follow","value":{"type":"event","event":{"seq":2,"type":"turn/end","data":{"turn":1,"reason":{"kind":"completed"}}}}}""",
                        )
                    }
                    sendUnaryResponse(reqId, rpcId)
                }
                else -> sendUnaryResponse(reqId, rpcId)
            }
        }

        private suspend fun sendUnaryResponse(reqId: Int, rpcId: String?) {
            val envelope = JsonObject(
                linkedMapOf(
                    "type" to JsonString("server-response"),
                    "rpcId" to JsonString(rpcId ?: "test-no-rpc"),
                    "result" to JsonObject(
                        linkedMapOf("ok" to JsonBool(true), "value" to JsonObject(emptyMap())),
                    ),
                ),
            )
            sendApiRes(reqId, envelope.toJsonString().toByteArray(Charsets.UTF_8), withHead = true)
            sendApiEnd(reqId)
        }

        private suspend fun sendFollowLine(line: String) {
            val requestId = checkNotNull(followRequestId) { "follow receive must open before the prompt" }
            sendApiRes(requestId, (line + "\n").toByteArray(Charsets.UTF_8), withHead = false)
        }

        private suspend fun sendApiRes(reqId: Int, body: ByteArray, withHead: Boolean) {
            val fields = linkedMapOf<String, com.phonedsh.agentcore.JsonValue>(
                "req_id" to JsonNumber(reqId.toString()),
                "body_hex" to JsonString(hex(body)),
            )
            if (withHead) {
                fields["head"] = JsonObject(
                    linkedMapOf(
                        "status" to JsonNumber("200"),
                        "headers" to JsonObject(mapOf("content-type" to JsonString("application/json"))),
                    ),
                )
            } else {
                fields["head"] = JsonNull
            }
            sendFrame("API_RES", JsonObject(fields))
        }

        private suspend fun sendApiEnd(reqId: Int) {
            sendFrame("API_END", JsonObject(linkedMapOf("req_id" to JsonNumber(reqId.toString()))))
        }

        private suspend fun sendFrame(type: String, fields: JsonObject) {
            host.onBinary(
                this,
                WireCodec.encode(
                    JsonObject(linkedMapOf("type" to JsonString(type), "fields" to fields)).toJsonString(),
                    workerSeq++,
                ),
            )
        }

        override suspend fun close(code: Short, reason: String) = Unit

        private fun hex(bytes: ByteArray): String = buildString(bytes.size * 2) {
            for (byte in bytes) {
                val value = byte.toInt() and 0xFF
                append("0123456789abcdef"[value ushr 4]).append("0123456789abcdef"[value and 0x0F])
            }
        }

        private fun unhex(text: String): ByteArray = ByteArray(text.length / 2) { index ->
            ((Character.digit(text[index * 2], 16) shl 4) or Character.digit(text[index * 2 + 1], 16)).toByte()
        }
    }
}
