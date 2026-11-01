// phone-dsh — :loopback tests: random port, start/stop lifecycle, thread hygiene.
// SPDX-License-Identifier: MIT

package com.phonedsh.loopback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.file.Path

class LoopbackLifecycleTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var assets: Path

    @Before
    fun setUp() {
        assets = Fixtures.write(Path.of(temporary.newFolder("assets").absolutePath))
    }

    @Test
    fun startBindsARandomPortOnTheLoopbackInterface() {
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            assertTrue("the OS picked port ${endpoint.port}", endpoint.port in 1..65535)
            assertEquals("http://127.0.0.1:${endpoint.port}", endpoint.origin)
            assertEquals("127.0.0.1", endpoint.host)
            assertEquals(endpoint, server.endpoint())
        }
    }

    @Test
    fun twoServersRunningAtTheSameTimeGetDifferentPorts() {
        val first = LoopbackServer()
        val second = LoopbackServer()
        try {
            val firstEndpoint = first.start(assets)
            val secondEndpoint = second.start(assets)
            assertNotEquals(
                "port 0 must ask the OS for a fresh port every start",
                firstEndpoint.port,
                secondEndpoint.port,
            )
        } finally {
            first.stop()
            second.stop()
        }
    }

    @Test
    fun restartAfterStopBindsANewPort() {
        val server = LoopbackServer()
        try {
            val firstEndpoint = server.start(assets)
            server.stop()
            assertNull("the old endpoint is gone after stop", server.endpoint())
            val secondEndpoint = server.start(assets)
            assertNotEquals(firstEndpoint.port, secondEndpoint.port)
            assertEquals(secondEndpoint, server.endpoint())
        } finally {
            server.stop()
        }
    }

    @Test
    fun stopReleasesThePort() {
        val server = LoopbackServer()
        val endpoint = server.start(assets)
        server.stop()
        assertNull(server.endpoint())
        awaitTrue(5_000, "port ${endpoint.port} to close") { !isListening(endpoint.port) }
    }

    @Test
    fun endpointIsNullBeforeStartAndStopIsIdempotent() {
        val server = LoopbackServer()
        assertNull(server.endpoint())
        server.stop()
        server.stop()
        assertEquals(LoopbackMetrics.Idle, server.metrics())
        server.start(assets)
        server.stop()
        server.stop()
        assertNull(server.endpoint())
    }

    @Test
    fun startTwiceWithoutStopThrows() {
        LoopbackServer().use { server ->
            server.start(assets)
            try {
                server.start(assets)
                fail("a second start on the same instance must not leak the first engine")
            } catch (expected: IllegalStateException) {
                assertTrue(expected.message!!.contains("already started"))
            }
        }
    }

    @Test
    fun repeatedStartStopDoesNotLeakThreads() {
        // Warm up the shared coroutine IO pool so the measured cycles reuse it.
        repeat(3) {
            val warm = LoopbackServer()
            warm.start(assets)
            warm.stop()
        }
        val baseline = aliveThreads()
        val handler = RecordingHandler()
        repeat(5) {
            val server = LoopbackServer(handler = handler)
            val endpoint = server.start(assets)
            val response = rawRequest(
                endpoint.port,
                "GET",
                "/manifest.json",
                mapOf("Authorization" to "Bearer ${endpoint.token}"),
            )
            assertEquals(200, response.status)
            server.stop()
        }
        awaitTrue(5_000, "worker threads to settle") { aliveThreads() <= baseline + 2 }
        assertTrue(
            "5 start/stop cycles grew the live thread count from $baseline to ${aliveThreads()}",
            aliveThreads() <= baseline + 2,
        )
        val leaked = aliveThreadNames().filter { name ->
            name.contains("CIO", ignoreCase = true) || name.contains("ktor", ignoreCase = true)
        }
        assertTrue("the engine left threads behind: $leaked", leaked.isEmpty())
    }

    @Test
    fun aMissingAssetDirectoryFailsWithoutLeavingAnEngineBehind() {
        val server = LoopbackServer()
        try {
            server.start(assets.resolve("does-not-exist"))
            fail("a missing asset directory must not start the origin")
        } catch (expected: IllegalArgumentException) {
            assertTrue(expected.message!!.contains("assetsDir is not a directory"))
        }
        assertNull(server.endpoint())
        // The instance is still usable afterwards.
        val endpoint = server.start(assets)
        assertEquals(200, rawRequest(endpoint.port, "GET", "/manifest.json", mapOf("Authorization" to "Bearer ${endpoint.token}")).status)
        server.stop()
    }

    @Test
    fun endpointBuildsUrlsWithoutLeakingTheTokenByDefault() {
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            assertEquals("${endpoint.origin}/", endpoint.urlFor("/"))
            assertEquals("${endpoint.origin}/worker-entry.js", endpoint.urlFor("/worker-entry.js"))
            assertFalse(endpoint.urlFor("/").contains(endpoint.token))
            assertEquals("ws://127.0.0.1:${endpoint.port}/channel", endpoint.channelUrl())
            assertFalse(endpoint.channelUrl().contains(endpoint.token))
            assertEquals(
                "ws://127.0.0.1:${endpoint.port}/channel?token=${endpoint.token}",
                endpoint.channelUrl(true),
            )
            val launch = endpoint.launchUrl(mapOf("image" to "/image/base", "channel" to endpoint.channelUrl(true)))
            assertTrue(launch.startsWith("${endpoint.origin}/?token=${endpoint.token}"))
            assertTrue(launch.contains("channel=ws%3A%2F%2F127.0.0.1%3A${endpoint.port}%2Fchannel%3Ftoken%3D"))
            assertFalse("the endpoint value must never print the token", endpoint.toString().contains(endpoint.token))
            assertTrue(endpoint.toString().contains("<redacted>"))
            try {
                endpoint.urlFor("no-slash")
                fail("a relative path must be rejected")
            } catch (expected: IllegalArgumentException) {
                assertTrue(expected.message!!.contains("must start with '/'"))
            }
        }
    }

    @Test
    fun anInjectedTokenIsHonoured() {
        val pinned = "0123456789abcdef0123456789abcdef"
        LoopbackServer(LoopbackConfiguration(token = pinned)).use { server ->
            val endpoint = server.start(assets)
            assertEquals(pinned, endpoint.token)
            val authorized = rawRequest(
                endpoint.port,
                "GET",
                "/manifest.json",
                mapOf("Authorization" to "Bearer $pinned"),
            )
            assertEquals(200, authorized.status)
        }
    }

    @Test
    fun configurationRejectsNonsense() {
        try {
            LoopbackConfiguration(port = -1)
            fail("a negative port must be rejected")
        } catch (expected: IllegalArgumentException) {
            assertTrue(expected.message!!.contains("port must be"))
        }
        try {
            LoopbackConfiguration(token = "short")
            fail("a short injected token must be rejected")
        } catch (expected: IllegalArgumentException) {
            assertTrue(expected.message!!.contains("at least"))
        }
        try {
            LoopbackConfiguration(maxChannelFrameBytes = LoopbackConfiguration.MAX_CHANNEL_FRAME_BYTES + 1)
            fail("a frame cap above 16 MiB + header must be rejected")
        } catch (expected: IllegalArgumentException) {
            assertTrue(expected.message!!.contains("maxChannelFrameBytes"))
        }
    }

    private fun isListening(port: Int): Boolean = try {
        Socket().use { socket ->
            socket.connect(InetSocketAddress(LoopbackConfiguration.LOOPBACK_HOST, port), 250)
            true
        }
    } catch (refused: IOException) {
        false
    }
}
