// phone-dsh — :loopback tests: connection admission policy under load.
// SPDX-License-Identifier: MIT
//
// The origin serves HTTP concurrently (static assets), but it carries exactly
// one channel: while a channel is open a second upgrade is answered 409 and the
// incumbent is untouched; after the incumbent closes a new one is accepted.

package com.phonedsh.loopback

import io.ktor.client.request.get
import io.ktor.client.request.header
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.nio.file.Path

class LoopbackConcurrencyTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var assets: Path

    @Before
    fun setUp() {
        assets = Fixtures.write(Path.of(temporary.newFolder("assets").absolutePath))
    }

    @Test
    fun parallelStaticRequestsAreAllAccepted() = runBlocking {
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                val responses = coroutineScope {
                    (1..16).map { index ->
                        async(Dispatchers.IO) {
                            http.get(endpoint.urlFor(if (index % 2 == 0) "/manifest.json" else "/engine.wasm")) {
                                header("Authorization", "Bearer ${endpoint.token}")
                            }
                        }
                    }.awaitAll()
                }
                assertEquals(16, responses.size)
                assertTrue("every parallel request must be served", responses.all { it.status.value == 200 })
            }
        }
    }

    @Test
    fun theChannelIsAcceptedAgainAfterThePreviousOneCloses() = runBlocking {
        val handler = RecordingHandler()
        LoopbackServer(handler = handler).use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                http.withChannel(endpoint) {
                    send(io.ktor.websocket.Frame.Binary(true, channelFrame(0x10, 1, byteArrayOf(1))))
                    awaitUntil(5_000, "the first frame") { handler.payloads.size == 1 }
                }
                awaitTrue(5_000, "the first channel to close") { handler.closed.size == 1 }
                awaitTrue(5_000, "the slot to free up") { server.metrics().activeChannels == 0 }
                http.withChannel(endpoint) {
                    send(io.ktor.websocket.Frame.Binary(true, channelFrame(0x10, 2, byteArrayOf(2))))
                    awaitUntil(5_000, "the second frame") { handler.payloads.size == 2 }
                }
                awaitTrue(5_000, "the second channel to close") { handler.closed.size == 2 }
                assertEquals(2, handler.opened.get())
                assertEquals(2L, server.metrics().channelsAccepted)
                assertEquals(0L, server.metrics().channelsRejected)
            }
        }
    }

    @Test
    fun theOriginStaysUsableWhileAChannelIsOpen() = runBlocking {
        val handler = RecordingHandler()
        LoopbackServer(handler = handler).use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                http.withChannel(endpoint) {
                    assertEquals(200, http.getAsset(endpoint, "/engine.wasm").status.value)
                    assertEquals(200, http.getAsset(endpoint, "/manifest.json").status.value)
                    assertEquals(
                        "a query probe is still refused while the channel is open",
                        401,
                        http.get("${endpoint.origin}/manifest.json?token=${endpoint.token}").status.value,
                    )
                }
            }
        }
    }
}
