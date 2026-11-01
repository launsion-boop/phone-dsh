// phone-dsh — :loopback tests: a failed start is loud, synchronous and recoverable.
// SPDX-License-Identifier: MIT
//
// Why these exist: a bind failure used to escape as an uncaught exception in
// Ktor's accept coroutine (measured on the emulator as "the App starts and
// immediately crashes, with nothing reportable": no INTERNET permission). These
// tests pin the two halves of the fix — start() throws with the real cause and
// leaves no half-started server; an unexpected death of the engine's coroutine
// scope after start() is recorded instead of crashing the process.

package com.phonedsh.loopback

import kotlinx.coroutines.launch
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.net.BindException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.nio.file.Path
import java.util.concurrent.CopyOnWriteArrayList

class LoopbackStartFailureTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var assets: Path
    private val blocked = CopyOnWriteArrayList<ServerSocket>()

    @Before
    fun setUp() {
        assets = Fixtures.write(Path.of(temporary.newFolder("assets").absolutePath))
    }

    @After
    fun tearDown() {
        releaseBlockedPorts()
    }

    @Test
    fun startOnAnOccupiedPortThrowsSynchronouslyAndDoesNotCrash() {
        val port = occupyLoopbackPort()
        // A failure that escapes to this handler is what kills the Android process.
        val uncaught = CopyOnWriteArrayList<Throwable>()
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { _, failure -> uncaught.add(failure) }
        val server = LoopbackServer(LoopbackConfiguration(port = port))
        try {
            val thrown = expectStartFailure { server.start(assets) }
            assertEquals(port, thrown.configuredPort)
            val causeChain = ArrayList<Throwable>()
            var link: Throwable? = thrown
            while (link != null) {
                causeChain.add(link)
                link = link.cause
            }
            assertTrue(
                "the socket error must survive as the cause, was ${thrown.cause}",
                causeChain.any { it is BindException },
            )
            assertNull("a failed start must not report an endpoint", server.endpoint())
            assertSame(
                "the instance must keep the very failure start() reported",
                thrown.cause,
                server.lastFailure(),
            )
            assertTrue(
                "metrics must show the engine failure",
                server.metrics().engineFailures >= 1L,
            )
            // The engine reports its own death on its dispatcher, not on the
            // caller's thread; give that report time to surface if it were
            // going to reach the process-wide handler.
            Thread.sleep(200)
            assertTrue(
                "the engine's bind failure reached the process' uncaught handler: $uncaught",
                uncaught.isEmpty(),
            )
        } finally {
            Thread.setDefaultUncaughtExceptionHandler(previous)
            server.stop()
        }
    }

    @Test
    fun aFailedStartLeavesNoHalfStartedStateAndCanBeRetried() {
        val port = occupyLoopbackPort()
        val failed = LoopbackServer(LoopbackConfiguration(port = port))
        try {
            expectStartFailure { failed.start(assets) }
            assertNull("a failed start must not report an endpoint", failed.endpoint())
            // Release the port: the very same instance must start on it. A leaked
            // engine, a stale endpoint or a half-bound socket would surface here.
            releaseBlockedPorts()
            val retried = failed.start(assets)
            assertEquals(port, retried.port)
            assertEquals(retried, failed.endpoint())
            assertNull("a successful retry clears the recorded failure", failed.lastFailure())
            assertEquals(0L, failed.metrics().engineFailures)
            assertEquals(
                200,
                rawRequest(
                    retried.port,
                    "GET",
                    "/manifest.json",
                    mapOf("Authorization" to "Bearer ${retried.token}"),
                ).status,
            )
            failed.stop()
        } finally {
            failed.stop()
        }

        // And an OS-assigned port starts in the same process after that failure.
        LoopbackServer().use { server ->
            val endpoint = server.start(assets)
            assertTrue("the OS picked port ${endpoint.port}", endpoint.port in 1..65535)
            assertEquals(
                200,
                rawRequest(
                    endpoint.port,
                    "GET",
                    "/manifest.json",
                    mapOf("Authorization" to "Bearer ${endpoint.token}"),
                ).status,
            )
        }
    }

    @Test
    fun aRuntimeDeathOfTheEngineScopeIsRecordedAndDoesNotCrashTheProcess() {
        val uncaught = CopyOnWriteArrayList<Throwable>()
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { _, failure -> uncaught.add(failure) }
        try {
            LoopbackServer().use { server ->
                val endpoint = server.start(assets)
                val scope = requireNotNull(server.engineScope()) {
                    "a confirmed start must expose the scope its engine inherited"
                }
                val death = IllegalStateException("the accept loop died")
                // Ktor keeps its accept job private. A failing child of the very
                // scope the engine was started in takes the same delivery path an
                // accept-job death takes: uncaught in the engine's parent context,
                // handed to the CoroutineExceptionHandler installed there.
                scope.launch { throw death }
                awaitTrue(5_000, "the engine failure to be recorded") { server.lastFailure() === death }
                assertSame(death, server.lastFailure())
                assertTrue(
                    "metrics must show the engine failure",
                    server.metrics().engineFailures >= 1L,
                )
                assertEquals(
                    "the endpoint stays readable; health is reported separately",
                    endpoint,
                    server.endpoint(),
                )
                // Still serving, still alive: the failure was recorded, not thrown.
                assertEquals(
                    200,
                    rawRequest(
                        endpoint.port,
                        "GET",
                        "/manifest.json",
                        mapOf("Authorization" to "Bearer ${endpoint.token}"),
                    ).status,
                )
                assertTrue(
                    "the engine failure reached the process' uncaught handler: $uncaught",
                    uncaught.isEmpty(),
                )
            }
        } finally {
            Thread.setDefaultUncaughtExceptionHandler(previous)
        }
    }

    private fun expectStartFailure(block: () -> Unit): LoopbackStartException = try {
        block()
        throw AssertionError("a start on an occupied port must not return an endpoint")
    } catch (expected: LoopbackStartException) {
        expected
    }

    /** Binds a loopback port and keeps it for the duration of one assertion. */
    private fun occupyLoopbackPort(): Int {
        val socket = ServerSocket()
        socket.bind(InetSocketAddress(LoopbackConfiguration.LOOPBACK_HOST, 0))
        blocked.add(socket)
        return socket.localPort
    }

    private fun releaseBlockedPorts() {
        for (socket in blocked) runCatching { socket.close() }
        blocked.clear()
    }
}
