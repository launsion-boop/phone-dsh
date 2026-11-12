// phone-dsh — :loopback tests: the Bot MCP listener lifecycle over real sockets.
// SPDX-License-Identifier: MIT
//
// Pins the §10 behaviour: IPv4-loopback-only bind, an ephemeral port, a TCP
// probe before the URL is published, recovery on the same instance with the
// same bearer, and a new bearer only for a new instance (PC D13 ruling 12).

package com.phonedsh.loopback

import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BotMcpListenerTest {
    private class PingingHandler : BotMcpRequestHandler {
        override val mcpSessionId: String = "session"
        override suspend fun handle(request: BotMcpRequest): BotMcpResponse =
            BotMcpResponse.Json(200, """{"ok":true}""".toByteArray())
    }

    @Test
    fun startBindsIpv4LoopbackOnAnEphemeralPortAndAnnouncesIt() {
        val seen = CopyOnWriteArrayList<BotMcpEndpoint>()
        BotMcpListener(PingingHandler(), onEndpointChange = { seen.add(it) }).use { listener ->
            val result = listener.start()
            assertTrue("start must publish a probed endpoint: $result", result is BotMcpStartResult.Started)
            val endpoint = (result as BotMcpStartResult.Started).endpoint
            assertEquals("127.0.0.1", endpoint.host)
            assertTrue(endpoint.port in 1..65535)
            assertEquals("http://127.0.0.1:${endpoint.port}", endpoint.origin)
            assertEquals(endpoint, listener.endpoint())
            assertEquals(listOf(endpoint), seen)
            assertTrue("a published endpoint is healthy", listener.isHealthy())
            val ping = botMcpRawRequest(
                endpoint.port,
                "/mcp",
                mapOf("Authorization" to "Bearer ${endpoint.token}"),
                """{"jsonrpc":"2.0","id":1,"method":"ping"}""".toByteArray(),
            )
            assertEquals(200, ping.status)
        }
    }

    @Test
    fun theTokenIs128BitLowercaseHexAndANewInstanceRotatesIt() {
        val first = BotMcpListener(PingingHandler())
        val second = BotMcpListener(PingingHandler())
        try {
            val firstEndpoint = first.startOrThrow()
            val secondEndpoint = second.startOrThrow()
            assertTrue("at least 128 bits as lowercase hex", Regex("[0-9a-f]{32,}").matches(firstEndpoint.token))
            assertTrue(Regex("[0-9a-f]{32,}").matches(secondEndpoint.token))
            assertNotEquals(
                "a host restart (a new listener instance) gets a new bearer",
                firstEndpoint.token,
                secondEndpoint.token,
            )
            // Both origins are live at once and each accepts only its own value.
            assertEquals(
                200,
                botMcpRawRequest(
                    secondEndpoint.port,
                    "/mcp",
                    mapOf("Authorization" to "Bearer ${secondEndpoint.token}"),
                    """{"jsonrpc":"2.0","id":1,"method":"ping"}""".toByteArray(),
                ).status,
            )
            assertEquals(
                401,
                botMcpRawRequest(
                    secondEndpoint.port,
                    "/mcp",
                    mapOf("Authorization" to "Bearer ${firstEndpoint.token}"),
                    """{"jsonrpc":"2.0","id":1,"method":"ping"}""".toByteArray(),
                ).status,
            )
        } finally {
            first.close()
            second.close()
        }
    }

    @Test
    fun aRebindOnTheSameInstanceKeepsTheTokenAndPublishesTheChangedUrl() {
        val seen = CopyOnWriteArrayList<BotMcpEndpoint>()
        BotMcpListener(PingingHandler(), onEndpointChange = { seen.add(it) }).use { listener ->
            val first = listener.startOrThrow()
            val token = first.token
            listener.stop()
            assertNull(listener.endpoint())

            // Occupy the previous port: the same instance must fall back to an
            // ephemeral port, keep its bearer, and announce the new URL.
            ServerSocket().use { occupied ->
                occupied.reuseAddress = false
                occupied.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), first.port))
                val restarted = listener.start()
                assertTrue("the fallback bind must succeed: $restarted", restarted is BotMcpStartResult.Started)
                val second = (restarted as BotMcpStartResult.Started).endpoint
                assertEquals("a rebind never rotates the bearer", token, second.token)
                assertNotEquals("the occupied port is not reused", first.port, second.port)
                assertEquals(second, listener.endpoint())
                assertEquals("the changed URL is published before use", second, seen.last())
                assertNotNull(
                    botMcpRawRequest(
                        second.port,
                        "/mcp",
                        mapOf("Authorization" to "Bearer $token"),
                    ),
                )
            }
        }
    }

    @Test
    fun ensureListeningLeavesAHealthyListenerUnchanged() {
        BotMcpListener(PingingHandler(), token = "aa".repeat(16)).use { listener ->
            val endpoint = listener.startOrThrow()
            val result = listener.ensureListening()
            assertTrue("a live listener must not be rebound: $result", result is BotMcpEnsureResult.Unchanged)
            assertEquals(endpoint, (result as BotMcpEnsureResult.Unchanged).endpoint)
            assertEquals(endpoint, listener.endpoint())
        }
    }

    @Test
    fun ensureListeningRebindsAfterAFailedProbeWithTheSameToken() {
        val seen = CopyOnWriteArrayList<BotMcpEndpoint>()
        BotMcpListener(PingingHandler(), token = "bb".repeat(16), onEndpointChange = { seen.add(it) }).use { listener ->
            val before = listener.startOrThrow()
            var probes = 0
            // The first probe reports the reaped socket; the rebind probe on the
            // same preferred port reports healthy again.
            listener.probeForTesting {
                probes++
                probes != 1
            }
            val result = listener.ensureListening()
            assertTrue("a failed probe must rebind: $result", result is BotMcpEnsureResult.Recovered)
            val recovered = result as BotMcpEnsureResult.Recovered
            assertEquals(before, recovered.previous)
            assertEquals("a rebind never rotates the bearer", before.token, recovered.endpoint.token)
            assertEquals(before.port, recovered.endpoint.port)
            assertEquals(recovered.endpoint, listener.endpoint())
            assertEquals("1 failed probe + 1 successful rebind probe", 2, probes)
            assertEquals("the same URL is not announced twice", 1, seen.size)
        }
    }

    @Test
    fun aProbeFailureIsAnExplicitFailedResultAndLeavesNoEndpoint() {
        val listener = BotMcpListener(PingingHandler())
        try {
            listener.probeForTesting { false }
            val result = listener.start()
            assertTrue("a failed probe must not be reported as a start: $result", result is BotMcpStartResult.Failed)
            val failed = result as BotMcpStartResult.Failed
            assertTrue("the real cause is kept", failed.cause is java.io.IOException)
            assertTrue(failed.attemptedPorts.isNotEmpty())
            assertNull(listener.endpoint())
            assertFalse(listener.isHealthy())
        } finally {
            listener.close()
        }
    }

    @Test
    fun ensureListeningIsExplicitWhenTheListenerWasNeverStarted() {
        BotMcpListener(PingingHandler()).use { listener ->
            val result = listener.ensureListening()
            assertTrue(result is BotMcpEnsureResult.Failed)
            assertNull(listener.endpoint())
        }
    }

    @Test
    fun stopIsIdempotentAndClosesThePublishedPort() {
        val listener = BotMcpListener(PingingHandler())
        val endpoint = listener.startOrThrow()
        listener.stop()
        listener.stop()
        assertNull(listener.endpoint())
        val rejected = try {
            java.net.Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", endpoint.port), 500)
            }
            false
        } catch (expected: java.io.IOException) {
            true
        }
        assertTrue("the stopped listener must stop accepting", rejected)
    }
}
