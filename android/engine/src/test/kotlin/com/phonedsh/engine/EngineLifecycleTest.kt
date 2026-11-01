// phone-dsh — :engine / com.phonedsh.engine: the DemoEngine state machine on the JVM.
// SPDX-License-Identifier: MIT
//
// This test drives the same EngineLifecycle instance WebViewEngine uses, so it
// proves the transition table and the log evidence that `start()` produces:
// Stopped -> Starting -> Running. WebView creation itself is NOT exercised here
// (it cannot exist on a JVM); that half is the instrumented test's job.

package com.phonedsh.engine

import com.phonedsh.platform.EngineHostState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EngineLifecycleTest {
    private val logger = RecordingEngineLogger()
    private val lifecycle = EngineLifecycle(logger)

    @Test
    fun startMovesStoppedToStartingToRunning() {
        assertEquals(EngineHostState.Stopped, lifecycle.snapshot())

        assertTrue(lifecycle.beginStart())
        assertEquals(EngineHostState.Starting, lifecycle.snapshot())

        assertTrue(lifecycle.markRunning("http://127.0.0.1:41234", 41234))
        assertEquals(
            EngineHostState.Running("http://127.0.0.1:41234", 41234),
            lifecycle.state.value,
        )

        assertEquals(listOf("Stopped", "Starting", "Running"), statesVisited())
        assertTrue(logger.contains("state: Stopped -> Starting"))
        assertTrue(logger.contains("state: Starting -> Running"))
    }

    @Test
    fun aSecondStartIsIgnoredWhileTheFirstOwnsIt() {
        assertTrue(lifecycle.beginStart())
        assertFalse(lifecycle.beginStart())
        assertTrue(lifecycle.markRunning("http://127.0.0.1:1", 1))
        assertFalse(lifecycle.beginStart())
    }

    @Test
    fun startIsAllowedAgainAfterAFailureAndAfterAStop() {
        lifecycle.beginStart()
        lifecycle.markFailed("boom")
        assertEquals(EngineHostState.Failed("boom"), lifecycle.snapshot())
        assertTrue(lifecycle.beginStart())

        lifecycle.markRunning("http://127.0.0.1:2", 2)
        assertTrue(lifecycle.beginStop())
        assertEquals(EngineHostState.Stopped, lifecycle.snapshot())
        assertTrue(lifecycle.beginStart())
    }

    @Test
    fun rendererRecoveryOnlyLeavesRunningAndReturnsToIt() {
        assertFalse(lifecycle.markRecovering()) // Stopped is not Running
        lifecycle.beginStart()
        assertFalse(lifecycle.markRecovering()) // Starting is not Running
        lifecycle.markRunning("http://127.0.0.1:3", 3)

        assertTrue(lifecycle.markRecovering())
        assertEquals(EngineHostState.Recovering, lifecycle.snapshot())
        assertEquals(1, lifecycle.recoveryCount)

        assertTrue(lifecycle.markRunning("http://127.0.0.1:3", 3))
        assertEquals(EngineHostState.Running("http://127.0.0.1:3", 3), lifecycle.snapshot())
        assertTrue(lifecycle.markRecovering())
        assertEquals(2, lifecycle.recoveryCount)
        assertTrue(logger.contains("-> Recovering"))
        assertTrue(logger.contains("Recovering -> Running"))
        assertEquals(
            listOf("Stopped", "Starting", "Running", "Recovering", "Running", "Recovering"),
            statesVisited(),
        )
    }

    @Test
    fun stopWinsOverEverythingAndLateCallbacksCannotResurrectIt() {
        lifecycle.beginStart()
        lifecycle.markRunning("http://127.0.0.1:4", 4)
        assertTrue(lifecycle.beginStop())
        assertEquals(EngineHostState.Stopped, lifecycle.snapshot())

        // Late callbacks from a cancelled start must be ignored.
        assertFalse(lifecycle.markRunning("http://127.0.0.1:4", 4))
        assertFalse(lifecycle.markRecovering())
        assertFalse(lifecycle.markFailed("late"))
        assertEquals(EngineHostState.Stopped, lifecycle.snapshot())
        assertFalse(lifecycle.beginStop())
    }

    @Test
    fun failureIsTerminalUntilRestart() {
        lifecycle.beginStart()
        assertTrue(lifecycle.markFailed("no webview provider"))
        assertFalse(lifecycle.markFailed("again"))
        assertEquals(EngineHostState.Failed("no webview provider"), lifecycle.snapshot())
    }

    /** The distinct states in the order the transition log visited them. */
    private fun statesVisited(): List<String> {
        val visited = ArrayList<String>()
        for (line in logger.lines) {
            if (!line.contains("state: ") || !line.contains(" -> ")) continue
            val transition = line.substringAfter("state: ")
            // Running(...) carries the origin/port; the test only tracks the state name.
            val from = transition.substringBefore(" -> ").substringBefore('(')
            val to = transition.substringAfter(" -> ").substringBefore('(')
            if (visited.lastOrNull() != from) visited += from
            if (visited.lastOrNull() != to) visited += to
        }
        return visited
    }
}
