// phone-dsh — :engine / com.phonedsh.engine: a logcat regression guard for page console text.
// SPDX-License-Identifier: MIT
//
// ---- the regression this test pins shut -------------------------------------
// WebViewEngine.onConsoleMessage writes two page-controlled strings: the message
// text and `message.sourceId()`. For an inline script Chromium reports the
// document URL as the source, and the engine's document URL is the launch URL:
// its `?env=` query carries the whole worker environment, including the
// per-start launch token. A page that logs `location.href` therefore put that
// URL into logcat. The fix routes both halves through EngineLogText.console()
// and EngineLogText.baseUrl(), which cut every URL at its first `?` or `#`.
//
// ---- why an instrumented test, and why a page asset -------------------------
// The stock worker bundle never logs a launch URL: every console line comes from
// `worker-entry.js`, an external script, whose sourceId is the script URL with no
// query. Only an inline script in the document reaches the sourceId branch, so
// `run-app-turn.sh` cannot see this path at all. This test serves a purpose-built
// page from the real loopback origin, loads it in the real WebView and reads the
// result back from logcat. Removing the sanitization makes it fail even though
// the page still boots.
//
// ---- what is asserted -------------------------------------------------------
//   1. POSITIVE: the `REGRESSION_GUARD` line is in logcat for THIS run (the
//      inline script executed and the record went through onConsoleMessage).
//      Without this the negative assertion below could pass on an empty log.
//   2. NEGATIVE: that same line contains neither `?` nor `env=`.
//   3. CONTROL: the page's plain console line is still present unchanged, so the
//      test cannot go green by turning console logging off.
//
// Run: cd android && ./gradlew :engine:connectedDebugAndroidTest
// Focused:
//   ./gradlew :engine:connectedDebugAndroidTest \
//     -Pandroid.testInstrumentationRunnerArguments.class=com.phonedsh.engine.ConsoleQueryRegressionInstrumentedTest
// Evidence: adb logcat -d -s PDSHEngineGuard

package com.phonedsh.engine

import android.content.res.AssetManager
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.loopback.ChannelCloseCause
import com.phonedsh.loopback.LoopbackChannelHandler
import com.phonedsh.loopback.LoopbackConnection
import com.phonedsh.platform.EngineHostState
import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ConsoleQueryRegressionInstrumentedTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()

    /** Production logcat path plus a buffer for diagnostics; see [RecordingLogcatLogger]. */
    private val logger = RecordingLogcatLogger(TAG, AndroidEngineLogger(TAG))
    private val handler = SilentChannelHandler()
    private var engine: WebViewEngine? = null
    private var logcatReadFailure: String? = null

    @After
    fun stopTheEngine() {
        val live = engine ?: return
        runCatching { onMain { live.stop() } }
        await("engine stopped", STOP_TIMEOUT_MS) { live.state.value == EngineHostState.Stopped }
        await("no live WebView", STOP_TIMEOUT_MS) { WebViewEngine.liveWebViewCount() == 0 }
        // The raw buffer is deliberately not printed: under the vulnerable code
        // it holds the launch URL, i.e. the very secret this test protects. The
        // logcat lines printed by the test body are redacted the same way.
        System.out.println(
            "PDSHEngineGuard: ${logger.lines.size} buffered lines on tag $TAG " +
                "(raw lines withheld; a leak would contain the launch token)",
        )
    }

    @Test
    fun anInlineScriptConsoleLineCarriesNoLaunchQuery() {
        val nonce = "g" + System.nanoTime()
        val created = newEngine(nonce)
        onMain { created.start() }
        assertTrue(
            "engine never reached Running; redacted buffer:\n" + redactedBuffer(),
            await("engine Running", START_TIMEOUT_MS) {
                created.state.value is EngineHostState.Running
            },
        )
        val origin = (created.state.value as EngineHostState.Running).origin

        // 1. POSITIVE. The line has to be in logcat before "no query" means
        //    anything: it is the proof that the inline script executed and that
        //    onConsoleMessage ran at all.
        val guardLine = awaitLogcatLine("the inline-script console line") { line ->
            line.contains("$GUARD_MARKER $origin/")
        } ?: throw AssertionError(
            "no '$GUARD_MARKER' console line for $origin appeared in logcat, so the " +
                "inline script did not reach onConsoleMessage. The negative assertion " +
                "would be vacuous; check tag $TAG in logcat." + logcatStatus(),
        )

        // 2. NEGATIVE. The same line must not carry the launch query. The failure
        //    messages carry booleans only: printing the line would print the
        //    launch token when this guard is red.
        assertFalse(
            "the console line still carries the launch query " +
                "(questionMark=${guardLine.contains("?")}, " +
                "envParameter=${guardLine.contains("env=")})",
            guardLine.contains("?"),
        )
        assertFalse(
            "the console line still carries the env parameter " +
                "(questionMark=${guardLine.contains("?")}, " +
                "envParameter=${guardLine.contains("env=")})",
            guardLine.contains("env="),
        )
        assertTrue(
            "the console line no longer shows the page text this guard is about: " +
                redact(guardLine),
            guardLine.contains("$GUARD_MARKER $origin/"),
        )

        // 3. CONTROL. The same page's plain console line is still logged
        //    unchanged, so silencing console logging cannot make the test green.
        val controlLine = awaitLogcatLine("the plain console line") { line ->
            line.contains("$CONTROL_MARKER $nonce")
        } ?: throw AssertionError(
            "plain console logging disappeared: no '$CONTROL_MARKER $nonce' line in " +
                "logcat." + logcatStatus(),
        )

        System.out.println("PDSH_REGRESSION_GUARD_LOGCAT_POSITIVE: ${redact(guardLine)}")
        System.out.println(
            "PDSH_REGRESSION_GUARD_LOGCAT_NEGATIVE: " +
                "questionMark=${guardLine.contains("?")} " +
                "envParameter=${guardLine.contains("env=")}",
        )
        System.out.println("PDSH_REGRESSION_GUARD_LOGCAT_CONTROL: ${redact(controlLine)}")
    }

    /**
     * Builds the engine against a test-only page materialized from
     * `androidTest/assets/regression-guard/index.html`.
     *
     * The construction mirrors `WebViewEngineInstrumentedTest.newEngine`, with
     * one difference: the asset source is this test's page, not the 65 MB worker
     * bundle. The page still comes from the real loopback origin, the real
     * WebView and the real launch URL, so the callback under test is genuine.
     */
    private fun newEngine(nonce: String): WebViewEngine {
        val context = instrumentation.targetContext
        val pageAssets = TestPageAssetSource(context.assets, PAGE_ASSET)
        val assets = WorkerAssets(
            source = pageAssets,
            filesDir = File(context.filesDir, FILES_DIR),
            logger = logger,
        )
        val created = WebViewEngine(
            context = context,
            channelHandler = handler,
            logger = logger,
            workerAssets = assets,
            // `guard` is an ordinary page parameter; the engine only reserves
            // token/image/channel/env and the boot overlay's overlay/overlay[].
            // It reaches the page through the real launch URL, and the page
            // echoes it on the control line.
            pageParams = mapOf("guard" to nonce),
            // A fixed, obviously fake token keeps even a red run from putting a
            // real launch secret into logcat. The URL shape is exactly the
            // production one; only the value is a fixture.
            launchToken = LaunchTokenSource { TEST_LAUNCH_TOKEN },
        )
        engine = created
        return created
    }

    /** Reads this process's logcat through the shell identity, so the read is not UID-filtered. */
    private fun readLogcat(): String = try {
        val descriptor = instrumentation.uiAutomation.executeShellCommand(
            "logcat -d -v brief -s $TAG",
        )
        ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { stream ->
            stream.readBytes().toString(Charsets.UTF_8)
        }
    } catch (failure: Throwable) {
        logcatReadFailure = failure::class.java.simpleName + ": " + failure.message.orEmpty()
        ""
    }

    /** Waits for a logcat line matching [predicate]; null on timeout. */
    private fun awaitLogcatLine(what: String, predicate: (String) -> Boolean): String? {
        val deadline = SystemClock.uptimeMillis() + LOGCAT_TIMEOUT_MS
        while (SystemClock.uptimeMillis() < deadline) {
            readLogcat().lineSequence().firstOrNull(predicate)?.let { return it }
            SystemClock.sleep(POLL_MILLIS)
        }
        System.out.println("timeout waiting for $what after $LOGCAT_TIMEOUT_MS ms" + logcatStatus())
        return null
    }

    private fun logcatStatus(): String =
        if (logcatReadFailure == null) "" else " (logcat read failure: $logcatReadFailure)"

    /**
     * The line with every query-bearing tail cut off.
     *
     * Only used in evidence and never in a negative assertion's message, so a red
     * run cannot print the launch token that the vulnerable sourceId carries.
     */
    private fun redact(line: String): String {
        val questionMark = line.indexOf('?')
        val envParameter = line.indexOf("env=")
        val cut = listOf(questionMark, envParameter)
            .filter { it >= 0 }
            .minOrNull()
            ?: return line
        return line.substring(0, cut) + "<redacted>"
    }

    private fun redactedBuffer(): String = logger.lines.joinToString("\n") { redact(it) }

    private fun onMain(block: () -> Unit) = instrumentation.runOnMainSync(block)

    /** Waits for [predicate] on the test thread; false on timeout. */
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
        /** Dedicated tag, so the assertion reads only this test's engine lines. */
        const val TAG: String = "PDSHEngineGuard"

        /** Asset in `src/androidTest/assets`; the WorkerAssets entry point name. */
        const val PAGE_ASSET: String = "regression-guard/index.html"

        /** Private materialization root, so the stock bundle copy is never touched. */
        const val FILES_DIR: String = "console-query-regression"

        const val GUARD_MARKER: String = "REGRESSION_GUARD"
        const val CONTROL_MARKER: String = "REGRESSION_GUARD_CONSOLE_OK"

        /**
         * 64 lowercase hex characters: the shape the origin and the cookie accept.
         * It is deliberately all zeros, so even a red run cannot print a real
         * per-start secret.
         */
        const val TEST_LAUNCH_TOKEN: String =
            "00000000000000000000000000000000" + "00000000000000000000000000000000"

        const val START_TIMEOUT_MS = 120_000L
        const val LOGCAT_TIMEOUT_MS = 90_000L
        const val STOP_TIMEOUT_MS = 30_000L
        const val POLL_MILLIS = 250L
    }
}

/**
 * One-file [WorkerAssetSource] over the `androidTest` asset tree.
 *
 * [versionStamp] is the page's content hash, so editing the fixture re-copies it
 * into [WorkerAssets] instead of reusing a stale file from an earlier run.
 */
private class TestPageAssetSource(
    private val assets: AssetManager,
    private val bundleAssetPath: String,
) : WorkerAssetSource {
    override val versionStamp: String by lazy { contentStamp() }

    override fun listAssets(): List<String> = listOf(WorkerAssets.ENTRY_POINT)

    override fun open(assetPath: String): InputStream {
        require(assetPath == WorkerAssets.ENTRY_POINT) {
            "the regression-guard source lists only ${WorkerAssets.ENTRY_POINT}"
        }
        return assets.open(bundleAssetPath)
    }

    private fun contentStamp(): String {
        val digest = MessageDigest.getInstance("SHA-256")
        assets.open(bundleAssetPath).use { input ->
            val buffer = ByteArray(STAMP_BUFFER_BYTES)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        val hex = digest.digest().joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
        return "regression-guard:$hex"
    }

    private companion object {
        const val STAMP_BUFFER_BYTES = 8 * 1024
    }
}

/**
 * Engine logger that writes through the production [AndroidEngineLogger] and
 * keeps the same lines in memory for the test's own diagnostics.
 *
 * Writing through the production logger is the point: the assertion reads the
 * line back from logcat, not from this buffer.
 */
private class RecordingLogcatLogger(
    tag: String,
    private val logcat: EngineLogger = AndroidEngineLogger(tag),
) : EngineLogger {
    private val entries = CopyOnWriteArrayList<String>()

    val lines: List<String> get() = entries.toList()

    override fun log(level: EngineLogLevel, message: String) {
        entries += "[$level] $message"
        logcat.log(level, message)
    }
}

/** The page under test never opens the channel; the engine still requires a handler. */
private class SilentChannelHandler : LoopbackChannelHandler {
    override suspend fun onOpen(connection: LoopbackConnection) = Unit

    override suspend fun onClosed(connection: LoopbackConnection, cause: ChannelCloseCause) = Unit
}
