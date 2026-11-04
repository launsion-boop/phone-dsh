// `session/create.request.agentPreset`: the preset carried by a new session.
// SPDX-License-Identifier: MIT
//
// The PR26 iOS preset page creates a session through `session/create` with
// `request.agentPreset`. Android's [DshTurnClient] used to know only `cwd`, so
// the preset could not reach the Worker at all. These tests drive the real
// client over the real HostChannel and assert the request body the Worker sees,
// not a mock invocation.
package com.phonedsh.dsh.turn

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
import com.phonedsh.loopback.LoopbackConnection
import com.phonedsh.wire.WireCodec
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DshTurnCreateSessionTest {
    @Test
    fun `an absent agentPreset leaves the request body unchanged`() = runBlocking {
        val peer = ScriptedCreatePeer()
        val host = testHost()
        peer.attach(host)
        peer.connect()

        val sessionId = DshTurnClient(host).createSession(cwd = "/dsh/workspace")

        assertEquals("session-worker-1", sessionId)
        val request = peer.lastCreateRequest
        assertEquals("/dsh/workspace", (request["cwd"] as JsonString).value)
        assertEquals(
            "no agentPreset key, exactly the pre-preset body",
            setOf("cwd"),
            request.members.keys,
        )
    }

    @Test
    fun `createSession carries the preset inside request`() = runBlocking {
        val peer = ScriptedCreatePeer()
        val host = testHost()
        peer.attach(host)
        peer.connect()

        val sessionId = DshTurnClient(host).createSession(
            cwd = "/dsh/workspace",
            agentPreset = "cordis",
        )

        assertEquals("session-worker-1", sessionId)
        val request = peer.lastCreateRequest
        assertEquals("/dsh/workspace", (request["cwd"] as JsonString).value)
        assertEquals("cordis", (request["agentPreset"] as JsonString).value)
        // The Worker's session/create reads the preset at request.agentPreset,
        // not at the envelope or args root.
        assertEquals(JsonObject(mapOf("request" to request)), peer.lastArgs)
    }

    @Test
    fun `createSessionWhenReady passes the preset on every attempt shape`() = runBlocking {
        val peer = ScriptedCreatePeer()
        val host = testHost()
        peer.attach(host)
        peer.connect()

        val sessionId = DshTurnClient(host).createSessionWhenReady(
            agentPreset = "cordis",
            totalTimeoutMillis = 2_000,
            perAttemptMillis = 1_000,
        )

        assertEquals("session-worker-1", sessionId)
        assertEquals("cordis", (peer.lastCreateRequest["agentPreset"] as JsonString).value)
    }

    @Test
    fun `a createSession failure keeps the worker code and message`() = runBlocking {
        val peer = ScriptedCreatePeer(
            error = JsonObject(
                mapOf(
                    "code" to JsonString("agent-preset/not-found"),
                    "message" to JsonString("Unknown agent preset: missing"),
                ),
            ),
        )
        val host = testHost()
        peer.attach(host)
        peer.connect()

        val failure = runCatching {
            DshTurnClient(host).createSession(agentPreset = "missing")
        }.exceptionOrNull()

        assertTrue("the failure must be a DshTurnException", failure is DshTurnException)
        val dsh = failure as DshTurnException
        assertEquals("agent-preset/not-found", dsh.code)
        assertEquals("agent-preset/not-found: Unknown agent preset: missing", dsh.message)
    }

    private fun testHost(): HostChannel {
        val hello = HostHello(
            bootId = "0123456789abcdef0123456789abcdef",
            sessionEpoch = 0L,
            fence = HostFence.LOCAL,
            wal = WalUplink.down("preset create test has no WAL"),
        )
        return HostChannel(hello = { hello }, logger = HostLog.None)
    }

    /** A real HostChannel peer that answers only `session/create`. */
    private class ScriptedCreatePeer(
        private val error: JsonObject? = null,
    ) : LoopbackConnection {
        override val id: String = "preset-create-test"
        private lateinit var host: HostChannel
        private var workerSeq = 2L
        lateinit var lastCreateRequest: JsonObject
            private set
        lateinit var lastArgs: JsonObject
            private set

        fun attach(host: HostChannel) {
            this.host = host
        }

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
            if (payload.size < 16 || (payload[2].toInt() and 0xFF) != 0x40) return
            val frame = JsonValue.parse(WireCodec.decode(payload)) as JsonObject
            val reqId = (frame["req_id"] as JsonNumber).asLongOrNull()!!.toInt()
            val body = unhex((frame["body_hex"] as JsonString).value)
            val call = JsonValue.parse(String(body, Charsets.UTF_8)) as JsonObject
            val rpcId = (call["rpcId"] as JsonString).value
            assertEquals("session/create", (call["method"] as JsonString).value)
            val args = (call["payload"] as JsonObject)["args"] as JsonObject
            lastArgs = args
            lastCreateRequest = args["request"] as JsonObject
            val result = if (error == null) {
                JsonObject(
                    linkedMapOf(
                        "ok" to JsonBool(true),
                        "value" to JsonObject(mapOf("sessionId" to JsonString("session-worker-1"))),
                    ),
                )
            } else {
                JsonObject(linkedMapOf("ok" to JsonBool(false), "error" to error))
            }
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
            val fields = linkedMapOf<String, JsonValue>(
                "req_id" to JsonNumber(reqId.toString()),
                "body_hex" to JsonString(hex(envelope.toJsonString().toByteArray(Charsets.UTF_8))),
                "head" to JsonObject(
                    linkedMapOf(
                        "status" to JsonNumber("200"),
                        "headers" to JsonObject(mapOf("content-type" to JsonString("application/json"))),
                    ),
                ),
            )
            sendFrame("API_RES", JsonObject(fields))
            sendFrame("API_END", JsonObject(mapOf("req_id" to JsonNumber(reqId.toString()))))
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
