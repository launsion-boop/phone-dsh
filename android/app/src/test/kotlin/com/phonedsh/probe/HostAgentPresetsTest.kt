// `agentPresets/list`, `agentPresets/read` and 使用预设 through the real host client.
// SPDX-License-Identifier: MIT
//
// The page is a pure function of facts; this file tests the host half over a real
// `HostChannel`: the exact args each call sends, the `value.presets[]` /
// `value.content` projection, and that a failure publishes `code: message` instead
// of being swallowed. The 使用预设 case also drives the real `session/create` with
// `request.agentPreset` and the launcher order that only creates the durable chat
// after the Worker accepted the preset.
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.dsh.host.HostChannel
import com.phonedsh.dsh.host.HostFence
import com.phonedsh.dsh.host.HostHello
import com.phonedsh.dsh.host.HostLog
import com.phonedsh.dsh.host.WalUplink
import com.phonedsh.dsh.turn.DshTurnClient
import com.phonedsh.loopback.LoopbackConnection
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.nav.PdshActionOutcome
import com.phonedsh.ui.nav.PdshActionReceipt
import com.phonedsh.ui.page.AgentPresetDocument
import com.phonedsh.ui.page.NativeAgentPreset
import com.phonedsh.ui.page.NativeAgentPresetsFacts
import com.phonedsh.ui.page.NativeAgentPresetsScreenState
import com.phonedsh.ui.state.StateRequestId
import com.phonedsh.ui.state.StateRevision
import com.phonedsh.wire.WireCodec
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HostAgentPresetsTest {
    @Test
    fun `list sends an empty args object and projects value presets`() = runBlocking {
        val peer = ScriptedApiPeer { path, _ ->
            when (path) {
                "agentPresets/list" -> ok(
                    JsonObject(
                        mapOf(
                            "presets" to JsonArray(
                                listOf(
                                    JsonObject(
                                        mapOf(
                                            "id" to JsonString("cordis"),
                                            "name" to JsonString("Cordis"),
                                            "description" to JsonString("create presets"),
                                            "isDefault" to JsonBool(true),
                                            "custom" to JsonBool(true),
                                        ),
                                    ),
                                    JsonObject(
                                        mapOf(
                                            "id" to JsonString("bad"),
                                            "broken" to JsonString("manifest missing"),
                                        ),
                                    ),
                                ),
                            ),
                        ),
                    ),
                )
                else -> error("unexpected $path")
            }
        }
        val facts = readAgentPresets(client(peer))

        assertEquals(JsonObject(emptyMap()), peer.calls.single().second)
        assertNull(facts.error)
        assertEquals(listOf("cordis", "bad"), facts.presets!!.map { it.id })
        val cordis = facts.presets!!.first()
        assertEquals("Cordis", cordis.title)
        assertEquals("create presets", cordis.detail)
        assertTrue(cordis.isDefault)
        assertTrue(cordis.custom)
        assertEquals("manifest missing", facts.presets!![1].broken)
        // An id-less `name` row falls back to the id, exactly like iOS's `?? id`.
        assertEquals("bad", facts.presets!![1].title)
    }

    @Test
    fun `list failure publishes the worker code and message`() = runBlocking {
        val peer = ScriptedApiPeer { _, _ ->
            fail("unsupported", "ctx.agentPresets is not mounted in this profile")
        }
        val facts = readAgentPresets(client(peer))

        assertNull(facts.presets)
        assertEquals(
            "unsupported: ctx.agentPresets is not mounted in this profile",
            facts.error,
        )
    }

    @Test
    fun `a missing presets array is a failure not an empty roster`() = runBlocking {
        val peer = ScriptedApiPeer { _, _ -> ok(JsonObject(mapOf("roster" to JsonObject(emptyMap())))) }
        val facts = readAgentPresets(client(peer))

        assertNull("an empty answer must not read as no presets", facts.presets)
        assertTrue(facts.error!!.startsWith("invalid_response: agentPresets/list returned no presets array"))
    }

    @Test
    fun `read sends agentPreset and returns value content`() = runBlocking {
        val peer = ScriptedApiPeer { path, args ->
            assertEquals("agentPresets/read", path)
            assertEquals("cordis", (args["agentPreset"] as JsonString).value)
            ok(JsonObject(mapOf("content" to JsonString("name: cordis\nmodel: standard\n"))))
        }
        val outcome = readPresetDocument(client(peer), "cordis", "Cordis")

        assertNull(outcome.failure)
        assertEquals(
            AgentPresetDocument("cordis", "Cordis", "name: cordis\nmodel: standard\n"),
            outcome.document,
        )
        assertEquals(
            JsonObject(mapOf("agentPreset" to JsonString("cordis"))),
            peer.calls.single().second,
        )
    }

    @Test
    fun `read failure prints code and message`() = runBlocking {
        val peer = ScriptedApiPeer { _, _ ->
            fail("not-found", "Unknown agent preset: missing")
        }
        val outcome = readPresetDocument(client(peer), "missing", "missing")

        assertNull(outcome.document)
        assertEquals("not-found: Unknown agent preset: missing", outcome.failure)
    }

    @Test
    fun `read without content keeps the baseline no-document wording`() = runBlocking {
        val peer = ScriptedApiPeer { _, _ -> ok(JsonObject(emptyMap())) }
        val outcome = readPresetDocument(client(peer), "cordis", "Cordis")

        assertNull(outcome.document)
        assertEquals(NativeAgentPresetsScreenState.NO_DOCUMENT_FAILURE, outcome.failure)
    }

    @Test
    fun `use preset creates the worker session with agentPreset before the chat record`() = runBlocking {
        val peer = ScriptedApiPeer { path, args ->
            when (path) {
                "agentPresets/list" -> ok(
                    JsonObject(
                        mapOf(
                            "presets" to JsonArray(
                                listOf(
                                    JsonObject(
                                        mapOf(
                                            "id" to JsonString("cordis"),
                                            "isDefault" to JsonBool(false),
                                        ),
                                    ),
                                ),
                            ),
                        ),
                    ),
                )
                "session/create" -> {
                    val request = args["request"] as JsonObject
                    assertEquals("cordis", (request["agentPreset"] as JsonString).value)
                    ok(JsonObject(mapOf("sessionId" to JsonString("worker-cordis"))))
                }
                else -> error("unexpected $path")
            }
        }
        var createdWorker: String? = null
        val requestId = StateRequestId("ui.presets.use.test")
        val dsh = client(peer)
        val launcher = AgentPresetSessionLauncher(
            readPresets = { readAgentPresets(dsh) },
            createWorkerSession = { id ->
                dsh.createSession(agentPreset = id)
            },
            createChatSession = { request, worker ->
                createdWorker = worker
                PdshActionReceipt(
                    requestId = request,
                    sessionId = "chat-cordis",
                    revision = StateRevision(1),
                    outcome = PdshActionOutcome.SUCCEEDED,
                )
            },
        )

        val result = launcher.use("cordis", requestId)

        assertTrue(result.failure ?: "", result.succeeded)
        assertEquals("chat-cordis", result.sessionId)
        assertEquals("worker-cordis", createdWorker)
        assertTrue("the list must be re-read before create", peer.calls.any { it.first == "agentPresets/list" })
    }

    @Test
    fun `a broken preset stops before create and returns its own reason`() = runBlocking {
        var createdWorker = false
        val launcher = AgentPresetSessionLauncher(
            readPresets = {
                NativeAgentPresetsFacts(
                    presets = listOf(
                        NativeAgentPreset(id = "cordis", title = "Cordis", broken = "manifest missing"),
                    ),
                )
            },
            createWorkerSession = { createdWorker = true; "never" },
            createChatSession = { _, _ -> error("the durable chat must not be created") },
        )

        val result = launcher.use("cordis", StateRequestId("ui.presets.use.test"))

        assertEquals("manifest missing", result.failure)
        assertFalse(createdWorker)
    }

    @Test
    fun `a createSession failure returns the worker code and leaves the page reason`() = runBlocking {
        val peer = ScriptedApiPeer { path, _ ->
            when (path) {
                "agentPresets/list" -> ok(
                    JsonObject(
                        mapOf(
                            "presets" to JsonArray(
                                listOf(JsonObject(mapOf("id" to JsonString("cordis")))),
                            ),
                        ),
                    ),
                )
                "session/create" -> fail("conflict", "agent preset is locked")
                else -> error("unexpected $path")
            }
        }
        var chatCreated = false
        val dsh = client(peer)
        val launcher = AgentPresetSessionLauncher(
            readPresets = { readAgentPresets(dsh) },
            createWorkerSession = { id ->
                dsh.createSession(agentPreset = id)
            },
            createChatSession = { _, _ ->
                chatCreated = true
                error("must not run")
            },
        )

        val result = launcher.use("cordis", StateRequestId("ui.presets.use.test"))

        assertEquals("conflict: agent preset is locked", result.failure)
        assertFalse("a failed Worker create must not leave a visible new chat", chatCreated)
    }

    @Test
    fun `a missing preset is reported instead of creating an ordinary session`() = runBlocking {
        var createdWorker = false
        val launcher = AgentPresetSessionLauncher(
            readPresets = { NativeAgentPresetsFacts(presets = emptyList()) },
            createWorkerSession = { createdWorker = true; "never" },
            createChatSession = { _, _ -> error("must not run") },
        )

        val result = launcher.use("cordis", StateRequestId("ui.presets.use.test"))

        assertEquals(UiStrings.AGENT_PRESETS_PRESET_GONE, result.failure)
        assertFalse(createdWorker)
    }

    private fun client(peer: ScriptedApiPeer): DshTurnClient = DshTurnClient(host(peer))

    private fun host(peer: ScriptedApiPeer): HostChannel {
        val channel = HostChannel(
            hello = {
                HostHello(
                    bootId = "0123456789abcdef0123456789abcdef",
                    sessionEpoch = 0L,
                    fence = HostFence.LOCAL,
                    wal = WalUplink.down("preset host test has no WAL"),
                )
            },
            logger = HostLog.None,
        )
        runBlocking { peer.attach(channel) }
        return channel
    }

    private fun ok(value: JsonObject): JsonObject = JsonObject(
        linkedMapOf("ok" to JsonBool(true), "value" to value),
    )

    private fun fail(code: String, message: String): JsonObject = JsonObject(
        linkedMapOf(
            "ok" to JsonBool(false),
            "error" to JsonObject(
                mapOf("code" to JsonString(code), "message" to JsonString(message)),
            ),
        ),
    )

    private fun error(message: String): Nothing = throw IllegalStateException(message)

    /**
     * A real HostChannel peer for the management endpoints. [handler] returns the
     * `result` object (`ok`/`value` or `ok`/`error`) for one call; the exact args
     * are recorded so the tests can assert the wire body, not a mock parameter.
     */
    private class ScriptedApiPeer(
        private val handler: (path: String, args: JsonObject) -> JsonObject,
    ) : LoopbackConnection {
        override val id: String = "preset-api-test"
        private lateinit var channel: HostChannel
        private var workerSeq = 2L
        val calls: MutableList<Pair<String, JsonObject>> = mutableListOf()
        private var connected = false

        suspend fun attach(channel: HostChannel) {
            this.channel = channel
            if (!connected) connect()
        }

        private suspend fun connect() {
            connected = true
            channel.onOpen(this)
            channel.onBinary(
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
            if (payload.size < 16 || (payload[2].toInt() and 0xFF) != 0x40) return
            val frame = JsonValue.parse(WireCodec.decode(payload)) as JsonObject
            val reqId = (frame["req_id"] as JsonNumber).asLongOrNull()!!.toInt()
            val body = unhex((frame["body_hex"] as JsonString).value)
            val call = JsonValue.parse(String(body, Charsets.UTF_8)) as JsonObject
            val rpcId = (call["rpcId"] as JsonString).value
            val path = (call["method"] as JsonString).value
            val args = ((call["payload"] as JsonObject)["args"] as JsonObject)
            calls += path to args
            val result = handler(path, args)
            respond(reqId, rpcId, result)
        }

        private suspend fun respond(reqId: Int, rpcId: String, result: JsonObject) {
            val envelope = JsonObject(
                linkedMapOf(
                    "type" to JsonString("server-response"),
                    "rpcId" to JsonString(rpcId),
                    "result" to result,
                ),
            )
            sendFrame(
                "API_RES",
                JsonObject(
                    linkedMapOf(
                        "req_id" to JsonNumber(reqId.toString()),
                        "body_hex" to JsonString(hex(envelope.toJsonString().toByteArray(Charsets.UTF_8))),
                        "head" to JsonObject(
                            linkedMapOf(
                                "status" to JsonNumber("200"),
                                "headers" to JsonObject(mapOf("content-type" to JsonString("application/json"))),
                            ),
                        ),
                    ),
                ),
            )
            sendFrame("API_END", JsonObject(mapOf("req_id" to JsonNumber(reqId.toString()))))
        }

        private suspend fun sendFrame(type: String, fields: JsonObject) {
            channel.onBinary(
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
