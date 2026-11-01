// phone-dsh — :loopback tests: the token gate and the launch-page query exception.
// SPDX-License-Identifier: MIT
//
// Rule under test (spec/v1/channel.md §7.1, the worker page's own contract and
// the D22 launch cookie):
//   * missing token and wrong token are both 401, on every path;
//   * `Authorization: Bearer <token>` is the only accepted credential for
//     static assets, unknown paths and the `/channel` upgrade;
//   * the launch page (`/`, `/index.html`) additionally accepts `?token=`, and
//     a page request that used it is answered with `303 Location: /` plus the
//     `xl_launch_token` cookie instead of the markup (D22 exchange);
//   * that cookie is an accepted credential once it is set.

package com.phonedsh.loopback

import io.ktor.client.plugins.websocket.webSocket
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsBytes
import io.ktor.websocket.Frame
import io.ktor.websocket.send
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.nio.file.Files
import java.nio.file.Path

class LoopbackTokenGateTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var assets: Path

    @Before
    fun setUp() {
        assets = Fixtures.write(Path.of(temporary.newFolder("assets").absolutePath))
    }

    @Test
    fun aMissingTokenIs401OnEveryPath() = runBlocking {
        val handler = RecordingHandler()
        LoopbackServer(handler = handler).use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                for (path in listOf("/", "/index.html", "/manifest.json", "/worker-entry.js", "/engine.wasm", "/missing.txt")) {
                    assertEquals("path $path without a token", 401, http.get(endpoint.urlFor(path)).status.value)
                }
            }
            val upgrade = rawRequest(endpoint.port, "GET", "/channel", upgradeHeaders(token = null))
            assertEquals("an unauthenticated upgrade must be rejected before the channel exists", 401, upgrade.status)
            assertTrue(upgrade.bodyText.contains("unauthorized"))
            assertEquals(0, handler.opened.get())
            assertEquals(0L, server.metrics().channelsAccepted)
            assertEquals(0, server.metrics().activeChannels)
        }
    }

    @Test
    fun aWrongTokenIs401() = runBlocking {
        val wrong = "0".repeat(32)
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                assertEquals(401, http.getAsset(endpoint, "/manifest.json", token = wrong).status.value)
                assertEquals(401, http.getAsset(endpoint, "/", token = wrong).status.value)
                assertEquals(401, http.get("${endpoint.origin}/?token=$wrong").status.value)
                assertEquals(401, http.getAsset(endpoint, "/manifest.json", token = endpoint.token + "x").status.value)
            }
            assertEquals(401, rawRequest(endpoint.port, "GET", "/channel", upgradeHeaders(wrong)).status)
        }
    }

    @Test
    fun aCorrectHeaderTokenIsAccepted() = runBlocking {
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                val response = http.getAsset(endpoint, "/manifest.json")
                assertEquals(200, response.status.value)
                assertEquals(Fixtures.MANIFEST, response.bodyAsBytes().toString(Charsets.UTF_8))
                assertEquals(200, http.getAsset(endpoint, "/").status.value)
            }
        }
    }

    @Test
    fun theLaunchPageExchangesTheQueryTokenForTheCookie() {
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            // D22: the page spelling that carries `?token=` answers the cookie
            // exchange instead of the markup, so the token does not stay in the
            // address bar. A raw client is used because the Ktor client follows
            // redirects and would hide the 303.
            for (page in listOf("/", "/index.html")) {
                val exchange = rawRequest(endpoint.port, "GET", "$page?token=${endpoint.token}")
                assertEquals("status of $page?token=", 303, exchange.status)
                assertEquals("/", exchange.header("Location"))
                assertEquals("no-store", exchange.header("Cache-Control"))
                assertEquals(
                    LaunchCookie.headerValue(endpoint.token),
                    exchange.header("Set-Cookie"),
                )
                assertFalse(
                    "the exchange must not repeat the token in Location",
                    exchange.header("Location")!!.contains(endpoint.token),
                )
                assertFalse(
                    "the 303 body must not echo the token",
                    exchange.bodyText.contains(endpoint.token),
                )
            }
            // The page itself is reachable with the cookie alone.
            val page = rawRequest(
                endpoint.port,
                "GET",
                "/",
                mapOf("Cookie" to LaunchCookie.headerValue(endpoint.token)),
            )
            assertEquals(200, page.status)
            assertEquals(Fixtures.INDEX_HTML, page.bodyText)
            // The token is still required: the query exchange is an alternative
            // transport, not an exemption.
            assertEquals(401, rawRequest(endpoint.port, "GET", "/").status)
        }
    }

    @Test
    fun theQueryTokenIsIgnoredOutsideTheLaunchPage() = runBlocking {
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                for (path in listOf("/manifest.json", "/worker-entry.js", "/engine.wasm", "/missing.txt")) {
                    assertEquals(
                        "a query token must not authenticate $path",
                        401,
                        http.get("${endpoint.origin}$path?token=${endpoint.token}").status.value,
                    )
                }
            }
            val upgrade = rawRequest(
                endpoint.port,
                "GET",
                "/channel?token=${endpoint.token}",
                upgradeHeaders(token = null),
            )
            assertEquals("the channel is header-only by default", 401, upgrade.status)
        }
    }

    @Test
    fun theQueryTokenOnTheChannelIsOptIn() = runBlocking {
        val handler = RecordingHandler()
        val configuration = LoopbackConfiguration(allowQueryTokenOnChannel = true)
        LoopbackServer(configuration, handler).use { server ->
            val endpoint = server.start(assets)
            val upgrade = rawRequest(
                endpoint.port,
                "GET",
                "/channel?token=${endpoint.token}",
                upgradeHeaders(token = null),
            )
            assertEquals("an opted-in query token must upgrade", 101, upgrade.status)
            awaitTrue(5_000, "the channel to open") { handler.opened.get() == 1 }
            awaitTrue(5_000, "the raw upgrade to be released") { server.metrics().activeChannels == 0 }
            // The raw client dropped the socket without a close frame.
            assertEquals(ChannelCloseCause.TRANSPORT_LOST, handler.closed.single())
            // …and the worker can use it with no header at all.
            newClient().use { http ->
                http.webSocket(urlString = "${endpoint.channelUrl()}?token=${endpoint.token}") {
                    send(Frame.Binary(true, channelFrame(0x01, 1, "hello".toByteArray())))
                    awaitUntil(5_000, "the query-token frame") { handler.payloads.size == 1 }
                }
            }
        }
    }

    @Test
    fun unauthorizedResponsesAreUniformAndNeverCarryTheToken() = runBlocking {
        val wrong = "e".repeat(32)
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            newClient().use { http ->
                val missing = http.get(endpoint.urlFor("/manifest.json"))
                val rejected = http.getAsset(endpoint, "/manifest.json", token = wrong)
                assertEquals(401, missing.status.value)
                assertEquals(401, rejected.status.value)
                assertArrayEquals(missing.bodyAsBytes(), rejected.bodyAsBytes())
                assertFalse(missing.bodyAsBytes().toString(Charsets.UTF_8).contains(endpoint.token))
                val headers = missing.headers.entries().joinToString(" ") { "${it.key}: ${it.value}" }
                assertFalse("a 401 response must not echo the token", headers.contains(endpoint.token))
                assertEquals("Bearer realm=\"pdsh-loopback\"", missing.headers["WWW-Authenticate"])
                assertEquals("no-store", missing.headers["Cache-Control"])
                assertFalse(endpoint.toString().contains(endpoint.token))
                assertEquals(2L, server.metrics().unauthorizedRequests)
            }
        }
    }

    @Test
    fun theTokenNeverReachesAResponseBodyOrTheEndpointValue() {
        // Nothing in this package logs, so the only ways a token could reach a
        // log line are an object's toString and an echoed body. Both are checked.
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            assertFalse(endpoint.toString().contains(endpoint.token))
            val html = Files.readString(assets.resolve("index.html"))
            assertFalse("the served markup must not contain the token", html.contains(endpoint.token))
            val missing = rawRequest(
                endpoint.port,
                "GET",
                "/missing.txt",
                mapOf("Authorization" to "Bearer ${endpoint.token}"),
            )
            assertEquals(404, missing.status)
            assertFalse(missing.bodyText.contains(endpoint.token))
        }
    }
}
