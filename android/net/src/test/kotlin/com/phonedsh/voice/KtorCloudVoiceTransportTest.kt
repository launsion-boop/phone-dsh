// SPDX-License-Identifier: MIT
// phone-dsh — :net voice tests: the real Ktor client against a local Ktor
// server (one WebSocket, one HTTP streaming body). This is the transport path
// the fake cannot prove: subprotocol `pdsh-asr.v1`, the `start`/`started` order,
// ordered binary bodies, close/cancel, and whole-sample PCM re-chunking. Nothing
// contacts pdsh.tonoai.cn.

package com.phonedsh.voice

import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import io.ktor.server.request.receiveText
import io.ktor.server.response.respond
import io.ktor.server.response.respondBytes
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import io.ktor.server.websocket.WebSockets
import io.ktor.server.websocket.webSocket
import io.ktor.websocket.CloseReason
import io.ktor.websocket.Frame
import io.ktor.websocket.readBytes
import io.ktor.websocket.readText
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class KtorCloudVoiceTransportTest {
    private fun timing() = CloudVoiceTiming(
        connectTimeoutMs = 5_000,
        startedTimeoutMs = 5_000,
        finishTimeoutDefaultMs = 5_000,
        finishGraceMs = 1_000,
    )

    @Test
    fun subprotocolStartedGateOrderingAndCompletion() = runBlocking {
        val protocol = CompletableDeferred<String?>()
        val authorization = CompletableDeferred<String?>()
        val startText = CompletableDeferred<String>()
        val releaseStarted = CompletableDeferred<Unit>()
        val bodies = CopyOnWriteArrayList<ByteArray>()
        val closed = CompletableDeferred<CloseReason?>()

        val server = embeddedServer(CIO, port = 0) {
            install(WebSockets)
            routing {
                webSocket("/v1/asr/stream", protocol = CloudVoice.ASR_SUBPROTOCOL) {
                    protocol.complete(call.request.headers[HttpHeaders.SecWebSocketProtocol])
                    authorization.complete(call.request.headers[HttpHeaders.Authorization])
                    startText.complete((incoming.receive() as Frame.Text).readText())
                    releaseStarted.await()
                    send(Frame.Text(startedMessage()))
                    while (bodies.size < 3) {
                        val frame = incoming.receive()
                        if (frame is Frame.Binary) bodies.add(frame.readBytes())
                    }
                    send(Frame.Text(finalMessage(1, "打开电池")))
                    send(Frame.Text("""{"type":"completed","session_id":"s1","final":true,"end_reason":"single_utterance"}"""))
                    closed.complete(withTimeoutOrNull(5_000) { closeReason.await() })
                }
            }
        }
        server.start(wait = false)
        val port = server.engine.resolvedConnectors().first().port
        val factory = KtorCloudVoiceSocketFactory()
        try {
            val session = CloudASRSession(
                turnId = 7u,
                credentials = { "tok-local" },
                socketFactory = factory,
                url = "ws://127.0.0.1:$port/v1/asr/stream",
                timing = timing(),
                scope = this,
            )
            session.open()
            val start = withTimeout(5_000) { startText.await() }
            assertTrue("start must be the pdsh-asr versioned start: $start", start.contains("\"type\":\"start\""))
            assertTrue(start.contains("\"client_ref\":\"tonolink-7\""))

            session.send(byteArrayOf(0x01, 0x02))
            session.send(byteArrayOf(0x03))
            session.send(byteArrayOf(0x04, 0x05, 0x06))
            assertEquals("nothing may reach the server before started", 0, bodies.size)

            releaseStarted.complete(Unit)
            assertTrue(withTimeout(5_000) { session.ready() })
            withTimeout(5_000) { while (bodies.size < 3) delay(5) }
            assertArrayEquals(byteArrayOf(0x01, 0x02), bodies[0])
            assertArrayEquals(byteArrayOf(0x03), bodies[1])
            assertArrayEquals(byteArrayOf(0x04, 0x05, 0x06), bodies[2])
            assertEquals(3, session.sentPackets)

            assertEquals(
                CloudASRTranscript.Outcome.Text("打开电池"),
                withTimeout(5_000) { session.outcome() },
            )
            assertEquals(CloudVoice.ASR_SUBPROTOCOL, withTimeout(5_000) { protocol.await() })
            assertEquals("Bearer tok-local", withTimeout(5_000) { authorization.await() })
            assertEquals(CloseReason.Codes.NORMAL.code.toInt(), withTimeout(5_000) { closed.await() }?.code?.toInt())
        } finally {
            factory.close()
            server.stop(0, 0)
        }
    }

    @Test
    fun cancelIsWrittenBeforeTheNormalClose() = runBlocking {
        val cancelText = CompletableDeferred<String>()
        val closed = CompletableDeferred<CloseReason?>()

        val server = embeddedServer(CIO, port = 0) {
            install(WebSockets)
            routing {
                webSocket("/v1/asr/stream", protocol = CloudVoice.ASR_SUBPROTOCOL) {
                    incoming.receive()
                    send(Frame.Text(startedMessage()))
                    val frame = withTimeout(5_000) { incoming.receive() }
                    cancelText.complete((frame as Frame.Text).readText())
                    closed.complete(withTimeoutOrNull(5_000) { closeReason.await() })
                }
            }
        }
        server.start(wait = false)
        val port = server.engine.resolvedConnectors().first().port
        val factory = KtorCloudVoiceSocketFactory()
        try {
            val session = CloudASRSession(
                turnId = 1u,
                credentials = { "tok-local" },
                socketFactory = factory,
                url = "ws://127.0.0.1:$port/v1/asr/stream",
                timing = timing(),
                scope = this,
            )
            session.open()
            assertTrue(withTimeout(5_000) { session.ready() })
            session.cancel()
            assertEquals(
                CloudASRTranscript.Outcome.Failed("cancelled"),
                withTimeout(5_000) { session.outcome() },
            )
            assertEquals(
                String(CloudVoice.cancelMessage),
                withTimeout(5_000) { cancelText.await() },
            )
            assertEquals(
                CloseReason.Codes.NORMAL.code.toInt(),
                withTimeout(5_000) { closed.await() }?.code?.toInt(),
            )
        } finally {
            factory.close()
            server.stop(0, 0)
        }
    }

    @Test
    fun asrHandshake401IsSurfacedForCredentialInvalidation() = runBlocking {
        val server = embeddedServer(CIO, port = 0) {
            routing {
                get("/v1/asr/stream") { call.respond(HttpStatusCode.Unauthorized) }
            }
        }
        server.start(wait = false)
        val port = server.engine.resolvedConnectors().first().port
        val factory = KtorCloudVoiceSocketFactory()
        try {
            val session = CloudASRSession(
                turnId = 1u,
                credentials = { "expired" },
                socketFactory = factory,
                url = "ws://127.0.0.1:$port/v1/asr/stream",
                timing = timing(),
                scope = this,
            )
            session.open()
            assertEquals(
                CloudASRTranscript.Outcome.Failed("closed without a result"),
                withTimeout(5_000) { session.outcome() },
            )
            assertEquals(401, session.handshakeStatus)
        } finally {
            factory.close()
            server.stop(0, 0)
        }
    }

    @Test
    fun ttsStreamsTheLocalPcmBodyAndSendsTheContractRequest() = runBlocking {
        val authorization = CompletableDeferred<String?>()
        val body = CompletableDeferred<String>()
        val server = embeddedServer(CIO, port = 0) {
            routing {
                post("/v1/tts/speech") {
                    authorization.complete(call.request.headers[HttpHeaders.Authorization])
                    body.complete(call.receiveText())
                    call.respondBytes(ByteArray(7001) { 7 }, ContentType.Application.OctetStream)
                }
            }
        }
        server.start(wait = false)
        val port = server.engine.resolvedConnectors().first().port
        val transport = KtorCloudTtsTransport()
        try {
            val client = CloudTTSClient(
                credentials = { "tok-local" },
                transport = transport,
                url = "http://127.0.0.1:$port/v1/tts/speech",
            )
            val audio = client.stream("你好").toList()
            assertEquals(7000, audio.sumOf { it.size })
            assertTrue(audio.all { it.size % 2 == 0 })
            assertEquals("Bearer tok-local", withTimeout(5_000) { authorization.await() })
            val request = GatewayJson.parse(body.await()) as JsonValue.Obj
            assertEquals("你好", request.string("input"))
            assertEquals("pcm", request.string("response_format"))
        } finally {
            transport.close()
            server.stop(0, 0)
        }
    }
}
