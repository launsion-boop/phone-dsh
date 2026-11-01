// phone-dsh — :engine / com.phonedsh.engine: the real WebView on an emulator.
// SPDX-License-Identifier: MIT
//
// This is the only place a WebView actually exists in the engine's test story:
// WebView construction, the loopback origin, the materialized 65 MB bundle and
// the page boot all run for real. It is an instrumented test on purpose — a
// Robolectric shadow would "prove" a WebView that never ran Chromium.
//
// Run: cd android && ./gradlew :engine:connectedDebugAndroidTest
// Evidence: adb logcat -s PDSHEngine TestRunner System.out

package com.phonedsh.engine

import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.loopback.ChannelCloseCause
import com.phonedsh.loopback.LoopbackChannelHandler
import com.phonedsh.loopback.LoopbackConnection
import com.phonedsh.platform.EngineHostState
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class WebViewEngineInstrumentedTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val logger = BufferingEngineLogger()
    private val handler = TrackingChannelHandler()
    private var engine: WebViewEngine? = null

    @After
    fun stopTheEngine() {
        val live = engine ?: return
        runCatching { onMain { live.stop() } }
        await("engine stopped", STOP_TIMEOUT_MS) { live.state.value == EngineHostState.Stopped }
        await("no live WebView", STOP_TIMEOUT_MS) { WebViewEngine.liveWebViewCount() == 0 }
        System.out.println("=== engine log ===\n" + logger.lines.joinToString("\n"))
    }

    @Test
    fun startMovesStoppedToStartingToRunningAndStopReturnsToStopped() {
        val created = newEngine()
        assertEquals(EngineHostState.Stopped, created.state.value)

        onMain { created.start() }
        // beginStart() runs synchronously before the coroutine is launched.
        assertEquals(EngineHostState.Starting, created.state.value)

        assertTrue(
            "engine never reached Running; log:\n" + logger.lines.joinToString("\n"),
            await("engine Running", START_TIMEOUT_MS) {
                created.state.value is EngineHostState.Running
            },
        )
        val state = created.state.value as EngineHostState.Running
        assertTrue("origin=${state.origin}", state.origin.startsWith("http://127.0.0.1:"))
        assertEquals(state.port, java.net.URI(state.origin).port)

        // The exact transitions the demo UI shows, in order.
        val transitions = logger.lines.filter { it.contains("state: ") }
        assertTrue(transitions.toString(), transitions.any { it.contains("Stopped -> Starting") })
        assertTrue(transitions.toString(), transitions.any { it.contains("Starting -> Running") })
        assertTrue(logger.contains("webview created on the UI thread (live=1"))
        assertEquals(1, WebViewEngine.liveWebViewCount())

        onMain {
            val view = created.currentWebView
            assertNotNull(view)
            val settings = view!!.settings
            assertTrue("the worker page is JavaScript", settings.javaScriptEnabled)
            assertFalse("file:// must stay unreachable", settings.allowFileAccess)
            assertFalse("content:// must stay unreachable", settings.allowContentAccess)
            @Suppress("DEPRECATION")
            val universal = settings.allowUniversalAccessFromFileURLs
            assertFalse("file:// must not reach http(s)", universal)
            // The WebView-free seam the host attaches: same one instance, as View.
            val exposed = created.view()
            assertNotNull("the host needs the live page", exposed)
            assertSame(view, exposed)
        }

        onMain { created.stop() }
        assertEquals(EngineHostState.Stopped, created.state.value)
        await("no live WebView", STOP_TIMEOUT_MS) { WebViewEngine.liveWebViewCount() == 0 }
        assertNull("a stopped engine owns no view", created.view())
        assertTrue(logger.contains("stop requested from"))
        assertTrue(logger.contains("webview destroyed"))
    }

    @Test
    fun thePageBootsFromTheBundledAssetsAndOpensExactlyOneChannel() {
        val created = newEngine()
        onMain { created.start() }
        await("engine Running", START_TIMEOUT_MS) { created.state.value is EngineHostState.Running }

        // The page has to load `index.html` (origin), `boot.js`, `worker-entry.js`
        // and `image.tar.gz` (served by shouldInterceptRequest), then the worker
        // opens the one WebSocket: that is the D2 "boot -> channel" evidence.
        val opened = await("page opened the channel", CHANNEL_TIMEOUT_MS) {
            handler.opened.get() >= 1
        }
        assertTrue(
            "the page never opened the channel; engine log:\n" +
                logger.lines.joinToString("\n"),
            opened,
        )
        assertTrue("opened=${handler.opened.get()}", handler.opened.get() >= 1)
        val connectionCounts = created.channelConnectionCounts()
        assertTrue(connectionCounts.first >= 1L)
        assertEquals(1, connectionCounts.second)
        assertTrue(created.channel.value.connected)
        // The worker sends HELLO as its first frame; the header byte is enough to
        // label it, and the codec behind ChannelTelemetry decides whether a
        // handshake summary exists (libpdsh_jni is not packaged yet on this host).
        await("first frame labelled", 30_000) { created.channel.value.lastFrameType != null }
        assertEquals("HELLO", created.channel.value.lastFrameType)
        System.out.println(
            "channel: status=${created.channel.value} handshake=${created.handshake.value}",
        )
        onMain { System.out.println("page title after the channel opened: ${created.currentWebView?.title}") }
        assertTrue(logger.contains("channel channel-1: open"))
        assertTrue(logger.contains("page finished"))
    }

    private fun newEngine(): WebViewEngine {
        val context = instrumentation.targetContext
        val assets = WorkerAssets(ApkWorkerAssetSource(context), context.filesDir, logger)
        val created = WebViewEngine(context, handler, logger, assets)
        engine = created
        return created
    }

    private fun onMain(block: () -> Unit) = instrumentation.runOnMainSync(block)

    /** Waits for [predicate] on the test thread; null on timeout. */
    private fun await(what: String, timeoutMillis: Long, predicate: () -> Boolean): Boolean {
        val deadline = SystemClock.uptimeMillis() + timeoutMillis
        while (SystemClock.uptimeMillis() < deadline) {
            if (predicate()) return true
            SystemClock.sleep(POLL_MILLIS)
        }
        System.out.println("timeout waiting for $what after $timeoutMillis ms")
        return false
    }

    private companion object {
        const val START_TIMEOUT_MS = 240_000L
        const val STOP_TIMEOUT_MS = 30_000L
        const val CHANNEL_TIMEOUT_MS = 120_000L
        const val POLL_MILLIS = 100L
    }
}

/** Keeps every engine line; the test prints the buffer as its evidence. */
private class BufferingEngineLogger : EngineLogger {
    private val entries = CopyOnWriteArrayList<String>()

    val lines: List<String> get() = entries.toList()

    override fun log(level: EngineLogLevel, message: String) {
        entries += "[$level] $message"
        System.out.println("PDSHEngine[$level] $message")
    }

    fun contains(fragment: String): Boolean = lines.any { it.contains(fragment) }
}

/** Counts channel opens; the codec is out of scope for :engine. */
private class TrackingChannelHandler : LoopbackChannelHandler {
    val opened = AtomicInteger()

    override suspend fun onOpen(connection: LoopbackConnection) {
        opened.incrementAndGet()
    }

    override suspend fun onClosed(connection: LoopbackConnection, cause: ChannelCloseCause) = Unit
}
