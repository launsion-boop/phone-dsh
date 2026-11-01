// :testkit channel — the /api lane and the turn client, against a scripted worker peer.
// SPDX-License-Identifier: MIT
//
// The device test (`TurnOverChannelInstrumentedTest`) needs a worker that boots
// for ~20 s before it can say anything. This JVM test exercises the same driver
// against a peer that answers instantly, so a defect in frame encoding, seq
// allocation, the rpc envelope or the NDJSON mux parser is found here instead of
// on an emulator run. The peer uses the REAL Rust codec for both directions —
// the only thing it fakes is the Worker's decision about what to answer.

package com.phonedsh.testkit.channel

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.loopback.LoopbackChannelHandler
import com.phonedsh.loopback.LoopbackConnection
import com.phonedsh.wire.WireCodec
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ApiFrameChannelTest {
    @Test
    fun aUnaryCallCrossesTheApiLaneAtSequentialSeqs() = runBlocking {
        val peer = ScriptedWorker()
        val seam = Seam()
        val api = ApiFrameChannel(seam)
        seam.handler = object : LoopbackChannelHandler {
            override suspend fun onOpen(connection: LoopbackConnection) = Unit
            override suspend fun onBinary(connection: LoopbackConnection, payload: ByteArray) {
                api.onInbound(payload)
                peer.receive(payload)
            }

            override suspend fun onClosed(connection: LoopbackConnection, cause: com.phonedsh.loopback.ChannelCloseCause) = Unit
        }
        seam.onOpenForTest()
        peer.deliver = { bytes -> seam.handler?.onBinary(seam, bytes) }

        val response = api.request(
            method = "POST",
            path = "/api/session/create",
            headers = mapOf("content-type" to "application/json"),
            body = """{"type":"client-request"}""".toByteArray(),
        )
        assertEquals(200, response.head.status)
        assertTrue(response.bodyText(), response.bodyText().contains("\"sessionId\""))

        val frames = peer.received()
        assertEquals(1, frames.size)
        val request = frames.single()
        assertEquals("API_REQ", request.type)
        assertEquals(1L, request.seq)
        val head = request.fields["head"] as JsonObject
        assertEquals("/api/session/create", (head["path"] as JsonString).value)
        assertEquals("POST", (head["method"] as JsonString).value)
    }

    @Test
    fun theTurnClientDrivesCreatePromptAndFollowThroughTheApiLane() = runBlocking {
        val peer = ScriptedWorker()
        val seam = Seam()
        val api = ApiFrameChannel(seam)
        seam.handler = object : LoopbackChannelHandler {
            override suspend fun onOpen(connection: LoopbackConnection) = Unit
            override suspend fun onBinary(connection: LoopbackConnection, payload: ByteArray) {
                api.onInbound(payload)
                peer.receive(payload)
            }

            override suspend fun onClosed(connection: LoopbackConnection, cause: com.phonedsh.loopback.ChannelCloseCause) = Unit
        }
        seam.onOpenForTest()
        peer.deliver = { bytes -> seam.handler?.onBinary(seam, bytes) }
        val client = DshTurnClient(api)

        val sessionId = client.createSession()
        assertEquals("s-scripted-1", sessionId)
        client.prompt(sessionId, "run the phone info tool")

        val mux = client.openFollow(sessionId)
        val events = mux.collectEvents(stopWhen = { it.hostKind == "turn_ended" })
        mux.close()

        assertEquals(
            listOf("turn_started", "tool_call", "tool_result", "turn_ended"),
            events.map { it.hostKind },
        )
        assertEquals(
            listOf("turn/start", "tool/call", "tool/result", "turn/end"),
            events.map { it.dshType },
        )
        val toolCall = events.single { it.hostKind == "tool_call" }
        val data = toolCall.raw["data"] as JsonObject
        assertEquals("phone", (data["name"] as? JsonString)?.value)
        assertEquals("turn-0001", toolCall.turnId)
        assertTrue("every durable event has a seq", events.all { it.seq != null })

        val paths = peer.received().map { ((it.fields["head"] as JsonObject)["path"] as JsonString).value }
        assertTrue(paths.toString(), paths.contains("/api/session/create"))
        assertTrue(paths.toString(), paths.contains("/api/session/prompt"))
        assertTrue(paths.toString(), paths.contains("/api/remote.mux"))
    }

    // ------------------------------------------------------------------ peer

    /** A `LoopbackConnection` handed to the host; it feeds the seam and keeps frames. */
    private class Seam : LoopbackConnection {
        override val id: String = "channel-1"
        var handler: LoopbackChannelHandler? = null
        private val delivered = CopyOnWriteArrayList<ByteArray>()
        private var nextSeq = 1L

        override suspend fun sendBinary(payload: ByteArray) {
            delivered += payload
            handler?.onBinary(this, payload.copyOf())
        }

        override suspend fun close(code: Short, reason: String) = Unit

        suspend fun onOpenForTest() {
            handler?.onOpen(this)
        }

        fun sent(): List<ByteArray> = delivered.toList()
    }

    private data class ReceivedFrame(
        val type: String,
        val seq: Long,
        val fields: JsonObject,
    )

    /**
     * The scripted Worker: decodes [`API_REQ`], and answers from a fixed script.
     *
     * It owns the worker→host direction's `seq` space and writes through the same
     * `LoopbackConnection` the host wrote on, exactly like a real peer.
     */
    private class ScriptedWorker {
        /** Delivers one worker→host frame to the host's seam (never through the host's writer). */
        var deliver: (suspend (ByteArray) -> Unit)? = null
        private val frames = CopyOnWriteArrayList<ReceivedFrame>()
        private var workerSeq = 1L
        private var rpcId = "testkit-rpc-1"

        fun received(): List<ReceivedFrame> = frames.toList()

        suspend fun receive(payload: ByteArray) {
            val type = frameTypeOf(payload) ?: return
            if (type != API_REQ) return
            val fields = JsonValue.parse(WireCodec.decode(payload)) as JsonObject
            frames += ReceivedFrame("API_REQ", seqOf(payload), fields)
            answer(fields)
        }

        private suspend fun answer(request: JsonObject) {
            val reqId = (request["req_id"] as JsonNumber).asLongOrNull()!!.toInt()
            val head = request["head"] as JsonObject
            val path = (head["path"] as JsonString).value
            val headers = (head["headers"] as JsonObject).members.mapValues { (it.value as JsonString).value }
            val body = (request["body_hex"] as JsonString).value
            rpcId = Regex("\"rpcId\"\\s*:\\s*\"([^\"]+)\"")
                .find(String(unhex(body), Charsets.UTF_8))?.groupValues?.get(1) ?: "testkit-rpc-1"
            when {
                path == "/api/session/create" -> respondJson(reqId, """{"sessionId":"s-scripted-1"}""")
                path == "/api/session/prompt" -> respondJson(reqId, "{}")
                path == "/api/remote.mux" && headers["x-pdsh-mux-op"] == "send" -> respondJson(reqId, "{}")
                path == "/api/remote.mux" && headers["x-pdsh-mux-op"] == "receive" -> respondMuxStream(reqId)
                path == "/api/remote.mux" && headers["x-pdsh-mux-op"] == "close" -> respondJson(reqId, "{}")
                else -> respondJson(reqId, """{"error":"unscripted $path"}""")
            }
        }

        private suspend fun respondJson(reqId: Int, value: String) {
            val body = """{"type":"server-response","rpcId":"$rpcId","result":{"ok":true,"value":$value}}"""
                .toByteArray()
            sendApiRes(reqId, status = 200, body = body, withHead = true)
            sendApiEnd(reqId)
        }

        /** The NDJSON stream: a follow snapshot with the four events of one turn. */
        private suspend fun respondMuxStream(reqId: Int) {
            val events = listOf(
                """{"seq":1,"type":"turn/start","data":{"turn":1}}""",
                """{"seq":2,"type":"tool/call","data":{"turn":1,"name":"phone","callId":"c1"}}""",
                """{"seq":3,"type":"tool/result","data":{"turn":1,"callId":"c1","isError":false}}""",
                """{"seq":4,"type":"turn/end","data":{"turn":1,"reason":{"kind":"completed"}}}""",
            ).joinToString(",") { """{"event":$it}""" }
            val snapshot = """{"type":"item","streamId":"follow","value":{"type":"snapshot",""" +
                """"records":[$events]}}"""
            sendApiRes(reqId, status = 200, body = "".toByteArray(), withHead = true)
            sendApiRes(reqId, status = 200, body = (snapshot + "\n").toByteArray(), withHead = false)
            sendApiRes(reqId, status = 200, body = """{"type":"end"}""".toByteArray(), withHead = false)
            sendApiEnd(reqId)
        }

        private suspend fun sendApiRes(reqId: Int, status: Int, body: ByteArray, withHead: Boolean) {
            val fields = linkedMapOf<String, JsonValue>(
                "req_id" to JsonNumber(reqId.toString()),
                "body_hex" to JsonString(hex(body)),
            )
            if (withHead) {
                fields["head"] = JsonObject(
                    linkedMapOf(
                        "status" to JsonNumber(status.toString()),
                        "headers" to JsonObject(
                            linkedMapOf("content-type" to JsonString("application/json")),
                        ),
                    ),
                )
            } else {
                fields["head"] = JsonNull
            }
            send("API_RES", fields)
        }

        private suspend fun sendApiEnd(reqId: Int) {
            send("API_END", linkedMapOf("req_id" to JsonNumber(reqId.toString())))
        }

        private suspend fun send(type: String, fields: Map<String, JsonValue>) {
            val json = """{"type":"$type","fields":${JsonObject(LinkedHashMap(fields)).toJsonString()}}"""
            val bytes = WireCodec.encode(json, workerSeq)
            workerSeq += 1
            deliver?.invoke(bytes)
        }

        private fun hex(bytes: ByteArray): String = buildString(bytes.size * 2) {
            for (byte in bytes) {
                val value = byte.toInt() and 0xFF
                append("0123456789abcdef"[value ushr 4]).append("0123456789abcdef"[value and 0x0F])
            }
        }

        private fun unhex(text: String): ByteArray {
            val bytes = ByteArray(text.length / 2)
            for (index in bytes.indices) {
                bytes[index] = ((Character.digit(text[index * 2], 16) shl 4) or
                    Character.digit(text[index * 2 + 1], 16)).toByte()
            }
            return bytes
        }

        private fun frameTypeOf(payload: ByteArray): Int? {
            if (payload.size < 16) return null
            val magic = ((payload[0].toInt() and 0xFF) shl 8) or (payload[1].toInt() and 0xFF)
            if (magic != 0x5A4C) return null
            return payload[2].toInt() and 0xFF
        }

        private fun seqOf(payload: ByteArray): Long {
            var value = 0L
            for (offset in 4 until 12) value = (value shl 8) or (payload[offset].toLong() and 0xFF)
            return value
        }

        private companion object {
            const val API_REQ = 0x40
        }
    }

}
