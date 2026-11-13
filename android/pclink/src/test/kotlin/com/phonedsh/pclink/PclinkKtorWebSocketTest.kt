// SPDX-License-Identifier: MIT
// One real-transport test: the Ktor client adapter against a loopback Ktor
// server WebSocket. This proves the production `PclinkWebSocket` adapter and the
// relay client agree on the `relay.challenge`/`peer.auth`/`relay.ready` bytes;
// it never contacts a real relay and uses only 127.0.0.1.
package com.phonedsh.pclink

import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import io.ktor.server.routing.routing
import io.ktor.server.websocket.WebSockets
import io.ktor.server.websocket.webSocket
import io.ktor.websocket.CloseReason
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.readText
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PclinkKtorWebSocketTest {
    private val phone = TestSupport.identity("pclink-v1/test/identity/phone")
    private val relayNonce: ByteArray = TestSupport.b64(
        TestSupport.at(TestSupport.vectors(), "relay_auth"),
        "nonce",
    ) ?: throw AssertionError("missing relay nonce")

    @Test
    fun realKtorClientAuthenticatesAgainstALocalRelay() = runBlocking {
        val authReceived = CompletableDeferred<PclinkJson>()
        val server = embeddedServer(CIO, port = 0) {
            install(WebSockets)
            routing {
                webSocket("/") {
                    val port = call.request.local.localPort
                    val origin = "http://127.0.0.1:$port"
                    send(
                        Frame.Text(
                            PclinkJsonEncoder.encodeString(
                                FakeRelay.challenge(origin, relayNonce),
                            ),
                        ),
                    )
                    val authFrame = incoming.receive() as Frame.Text
                    val auth = PclinkJsonParser.parseObject(authFrame.readText())
                    authReceived.complete(auth)
                    send(
                        Frame.Text(
                            PclinkJsonEncoder.encodeString(
                                FakeRelay.ready(phone.machineId, "phone"),
                            ),
                        ),
                    )
                    send(
                        Frame.Text(
                            PclinkJsonEncoder.encodeString(
                                FakeRelay.offline(phone.machineId, id = "call-ktor", sid = sid()),
                            ),
                        ),
                    )
                    delay(50)
                    close(CloseReason(CloseReason.Codes.NORMAL, "done"))
                }
            }
        }
        server.start(wait = false)
        val port = server.engine.resolvedConnectors().first().port
        val socketFactory = KtorPclinkWebSocketFactory()
        val relay = PclinkRelayClient(
            configuration = PclinkRelayClient.Configuration(
                origin = "http://127.0.0.1:$port",
                identity = phone,
                heartbeatEnabled = false,
            ),
            socketFactory = socketFactory,
        )
        try {
            relay.connect()
            val auth = withTimeout(5_000) { authReceived.await() }
            assertEquals(phone.machineId, auth["machineId"]?.stringValue)
            assertEquals("phone", auth["role"]?.stringValue)
            val signature = PclinkBase64Url.decode(auth.requiredString("sig"), expectedLength = 64)
            val transcript = PclinkCrypto.relayAuthTranscript(
                "http://127.0.0.1:$port",
                relayNonce,
            )
            assertTrue(
                "the Ktor path must sign the exact challenge origin and nonce",
                PclinkCrypto.ed25519Verify(phone.publicKey, transcript, signature),
            )

            val offline = withTimeout(5_000) { relay.incoming.first() }
            assertEquals("relay.offline", offline["type"]?.stringValue)
            assertEquals("call-ktor", offline["id"]?.stringValue)
            withTimeout(5_000) {
                while (relay.closeCode == null) delay(5)
            }
            assertEquals(1000, relay.closeCode)
        } finally {
            relay.close(1000, "")
            socketFactory.close()
            server.stop(0, 0)
        }
    }

    @Test
    fun `the real socket enforces the relay frame ceiling`() = runBlocking {
        val oversized = "x".repeat(PclinkLimits.MAX_RELAY_FRAME_BYTES + 1)
        val server = embeddedServer(CIO, port = 0) {
            install(WebSockets)
            routing {
                webSocket("/") {
                    send(Frame.Text(oversized))
                    delay(50)
                    close(CloseReason(CloseReason.Codes.NORMAL, "done"))
                }
            }
        }
        server.start(wait = false)
        val port = server.engine.resolvedConnectors().first().port
        val socketFactory = KtorPclinkWebSocketFactory()
        try {
            val socket = socketFactory.connect("ws://127.0.0.1:$port/")
            val failure = runCatching { socket.incoming.first() }.exceptionOrNull()
            assertTrue(
                "expected frame_too_large, got $failure",
                failure is PclinkError.FrameTooLarge,
            )
            socket.close(1009, "frame_too_large")
        } finally {
            socketFactory.close()
            server.stop(0, 0)
        }
    }

    private fun sid(): String = TestSupport.requireString(
        TestSupport.at(TestSupport.vectors(), "handshake"),
        "sid",
    )
}
