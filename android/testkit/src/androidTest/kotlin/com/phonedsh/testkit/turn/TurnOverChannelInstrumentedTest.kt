// :testkit turn — one complete turn over the REAL channel, on a device.
// SPDX-License-Identifier: MIT
//
// ---- what runs for real ----------------------------------------------------
//   * the prebuilt DSH worker (`examples/probe-app/Bundle/worker`) inside a real
//     WebView, on the loopback origin `:engine` binds;
//   * the real Android host facade (`DefaultPhoneDshHost`): HELLO, WAL recovery,
//     the VFS sink and the `phone info` exec accelerator;
//   * the real `/api` lane, as `channel.md` §3.7-3.10 defines it: this test sends
//     `API_REQ` frames over the same WebSocket the worker opened, and reads the
//     worker's `API_RES`/`API_END` frames. A prompt is a real
//     `session/prompt` request; the turn's events are the worker's own
//     `session/follow` records (`turn_started`, `tool_call`, …).
//   * the real `:net` gateway (`GatewaySession`) as the model egress: the
//     worker's model request reaches a loopback front, the gateway decides (one
//     exact origin entry), and the request is forwarded to the scripted model
//     upstream over a real socket.
//
// ---- what is scripted ------------------------------------------------------
// THE MODEL. `ScriptedModelUpstream` answers the first request with a `bash`
// tool call carrying `phone info`, and the second (which carries the tool
// result) with a final text. There is no inference and no provider key.
//
// ---- what this test may NOT claim ------------------------------------------
// * The `/v1/http` front is a test fixture: the app's own route is `src/main`
//   work this lane may not do, so the front lives in `:testkit`.
// * The `/api` lane driver (`ApiFrameChannel`, `DshTurnClient`) is also test
//   surface: `:dsh`'s `HostChannel` implements HELLO/VFS/EXEC only.
// Both are named in the report; neither is passed off as product code.

package com.phonedsh.testkit.turn

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.toJsonString
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.dsh.host.DefaultPhoneDshHost
import com.phonedsh.dsh.host.HostLog
import com.phonedsh.dsh.host.asHostWal
import com.phonedsh.engine.ApkWorkerAssetSource
import com.phonedsh.engine.EngineLogLevel
import com.phonedsh.engine.EngineLogger
import com.phonedsh.engine.WorkerAssets
import com.phonedsh.engine.createDemoEngine
import com.phonedsh.gateway.AllowListEgressPolicy
import com.phonedsh.gateway.CredentialScope
import com.phonedsh.gateway.GatewayCredential
import com.phonedsh.gateway.GatewayCredentialProvider
import com.phonedsh.gateway.GatewayDispatch
import com.phonedsh.gateway.GatewayHostRule
import com.phonedsh.gateway.GatewaySession
import com.phonedsh.log.BootId as LogBootId
import com.phonedsh.log.WalPaths
import com.phonedsh.log.WorkspaceLog
import com.phonedsh.loopback.ChannelCloseCause
import com.phonedsh.loopback.LoopbackChannelHandler
import com.phonedsh.loopback.LoopbackConnection
import com.phonedsh.platform.EngineHostState
import com.phonedsh.platform.testing.FakePlatform
import com.phonedsh.testkit.channel.ApiFrameChannel
import com.phonedsh.testkit.channel.DshTurnClient
import com.phonedsh.testkit.channel.TurnEvent
import com.phonedsh.testkit.upstream.GatewayFrontServer
import com.phonedsh.testkit.upstream.ScriptedModelUpstream
import com.phonedsh.testkit.upstream.UrlConnectionGatewayTransport
import com.phonedsh.wire.WireCodec
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TurnOverChannelInstrumentedTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    private lateinit var platform: FakePlatform
    private lateinit var scope: CoroutineScope
    private lateinit var workspaceLog: WorkspaceLog
    private lateinit var paths: WalPaths
    private lateinit var host: DefaultPhoneDshHost
    private lateinit var engine: com.phonedsh.engine.DemoEngine
    private lateinit var seam: TurnSeam
    private lateinit var upstream: ScriptedModelUpstream
    private lateinit var front: GatewayFrontServer
    private lateinit var gateway: GatewaySession

    private val engineLog = BufferingEngineLogger()
    private val hostLog = RecordingHostLog()
    private val turnEvents = CopyOnWriteArrayList<TurnEvent>()
    private val execResults = CopyOnWriteArrayList<String>()
    private val frameTrace = CopyOnWriteArrayList<String>()
    private val consoleLines = CopyOnWriteArrayList<String>()
    private val vfsMutations = AtomicInteger()
    private val journalRecords = AtomicInteger()

    @Before
    fun startEverything() {
        // 1. the scripted model and the gateway front (both real loopback sockets).
        upstream = ScriptedModelUpstream().start()
        val grant = GatewayHostRule.parse("http://127.0.0.1:${upstream.port}")
            ?: throw IllegalStateException("the exact-origin grant must parse")
        gateway = GatewaySession(
            transport = UrlConnectionGatewayTransport(),
            credentialProvider = object : GatewayCredentialProvider {
                // Anonymous: the scripted upstream needs no key, and the gateway's
                // header policy is still exercised (caller authorization is stripped).
                override fun resolve(scope: CredentialScope): GatewayCredential = GatewayCredential.None
            },
            egress = AllowListEgressPolicy(listOf(grant)),
        )
        front = GatewayFrontServer(gateway, upstream.baseUrl).start()
        upstream.onRequest = { request ->
            log(
                "model request ${request.path} toolResult=${request.carriesToolResult} " +
                    "bytes=${request.body.length} body=${request.body.take(220)}",
            )
        }
        log("upstream=${upstream.baseUrl} front=${front.baseUrl}")

        // 2. the real WAL under the app's private directory.
        platform = FakePlatform()
        val logRoot = File(context.filesDir, LOG_DIRECTORY)
        deleteTree(logRoot.toPath())
        paths = WalPaths(logRoot.toPath())
        workspaceLog = WorkspaceLog(
            paths = paths,
            durability = platform,
            clock = platform,
            bootId = LogBootId.random(),
        )
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

        // 3. the real engine, with a page environment that points the worker's
        //    model client at the gateway front. `PDSH_DSH_LAUNCH_TOKEN` is added
        //    by the engine itself; putting a key in `env` here is how a host
        //    supplies non-secret configuration (the launch token precedent).
        val env = buildString {
            append("{\"DEEPSEEK_BASE_URL\":\"").append(front.baseUrl).append("\",")
            append("\"DEEPSEEK_API_KEY\":\"testkit-scripted-key\",")
            append("\"DSH_TELEMETRY_DISABLED\":\"1\",")
            append("\"PDSH_MODEL_NAME\":\"deepseek-flash\"}")
        }
        log("worker env base url points at the gateway front (token-free: it is a port)")
        seam = TurnSeam(
            onConsole = { line ->
                consoleLines += line
                if (line.contains("XL_DSH_READY")) Log.i(TAG, "worker ready announcement: $line")
            },
            trace = { direction, type, seq ->
                frameTrace += "$direction $type seq=$seq"
                // The frame sequence IS the evidence for "the host really executed
                // it": EXEC_REQ went in, EXEC_EVT came back, on the same WebSocket.
                if (type !in QUIET_FRAME_TYPES) Log.i(TAG, "frame $direction $type seq=$seq")
            },
            onExecEvent = { execResults += it },
            onVfsMutation = { vfsMutations.incrementAndGet() },
            onHostError = { log("worker ERROR frame: $it") },
            journalRecords = journalRecords,
        )
        engine = createDemoEngine(
            context = context,
            channelHandler = seam,
            logger = engineLog,
            workerAssets = WorkerAssets(
                source = ApkWorkerAssetSource(context),
                filesDir = context.filesDir,
                logger = engineLog,
            ),
            pageParams = mapOf("env" to env),
            launchToken = { LAUNCH_TOKEN },
        )

        // 4. the real host facade; it starts the engine after WAL recovery.
        host = DefaultPhoneDshHost(
            engine = engine,
            controller = ControllerStateMachine.boot(persistedState = null),
            clock = platform,
            signals = platform,
            notifier = platform,
            wal = workspaceLog.asHostWal(),
            logger = hostLog,
            scope = scope,
        )
        seam.hostHandler = host.channelHandler
        onMain { host.start() }
        runBlocking {
            withTimeout(HOST_READY_TIMEOUT_MILLIS) { host.ready.first { it } }
        }
        log("host ready; caps=${host.hello.capabilities.describe()}")
        await("engine Running", ENGINE_TIMEOUT_MILLIS) {
            engine.state.value is EngineHostState.Running
        }
        await("a channel connection", CHANNEL_TIMEOUT_MILLIS) { seam.apiLive() }
        // The worker sends HELLO first; the host answers with its own. Only after
        // that may the /api lane send anything (channel.md §7.2).
        await("host HELLO answered", CHANNEL_TIMEOUT_MILLIS) {
            frameTrace.any { it.startsWith("worker->host HELLO") } &&
                frameTrace.count { it.startsWith("host->worker") } >= 1
        }
    }

    @After
    fun stopEverything() {
        runCatching { onMain { host.stop() } }
        runCatching { upstream.stop() }
        runCatching { front.stop() }
        runCatching { scope.cancel() }
        runCatching { platform.close() }
        log("engine log tail:")
        for (line in engineLog.lines.takeLast(40)) log("engine: $line")
    }

    @Test
    fun aPromptRunsOneTurnThroughTheModelGatewayAndTheHostExecLane() {
        val api = seam.requireApi()
        val client = DshTurnClient(api, onMuxLine = { line -> log("mux: ${line.take(400)}") })

        // The worker's `/api` frame subscriber is installed at the END of its
        // tree boot, so a request sent at HELLO time is dropped without an error.
        // The tree announces itself on CONSOLE with `XL_DSH_READY <port>`; wait for
        // that, then still retry the first call (the subscriber may be a frame
        // behind) instead of assuming a fixed delay is enough.
        await("worker tree serving", TREE_TIMEOUT_MILLIS) {
            consoleLines.any { it.contains("XL_DSH_READY") }
        }
        Thread.sleep(TREE_SETTLE_MILLIS)

        // ---- the prompt -----------------------------------------------------
        val sessionId = retrying("session/create") {
            runBlocking { client.createSession(cwd = WORKSPACE, timeoutMillis = FIRST_CALL_TIMEOUT_MILLIS) }
        }
        log("session/create -> $sessionId")
        val follow = runBlocking { client.openFollow(sessionId) }
        try {
            runBlocking { client.prompt(sessionId, PROMPT) }
            log("session/prompt queued: $PROMPT")

            // ---- the turn, as the WORKER reports it ------------------------
            val events = runBlocking {
                follow.collectEvents(stopWhen = { it.hostKind == "turn_ended" })
            }
            turnEvents += events
            for (event in events) log("host event: ${event.describe()}")

            // ---- assertions -------------------------------------------------
            assertTrue(
                "the worker reported no turn events; frames=${frameTrace.takeLast(20)}",
                events.isNotEmpty(),
            )
            val kinds = events.mapNotNull { it.hostKind }
            assertTrue("turn_started missing: $kinds", kinds.contains("turn_started"))
            assertTrue("tool_call missing: $kinds", kinds.contains("tool_call"))
            assertTrue("tool_result missing: $kinds", kinds.contains("tool_result"))
            assertTrue("turn_ended missing: $kinds", kinds.contains("turn_ended"))
            assertEquals(
                "the turn's first durable event must be turn_started",
                "turn_started",
                kinds.first(),
            )
            assertEquals(
                "the turn must end last",
                "turn_ended",
                kinds.last(),
            )
            assertTrue(
                "a tool call must sit between the turn's edges: $kinds",
                kinds.indexOf("tool_call") in
                    (kinds.indexOf("turn_started") + 1) until kinds.indexOf("turn_ended"),
            )

            val toolCall = events.first { it.hostKind == "tool_call" }
            val toolResult = events.first { it.hostKind == "tool_result" }
            val turnEnd = events.first { it.hostKind == "turn_ended" }
            log("tool_call: ${toolCall.raw.toCompactString()}")
            log("tool_result: ${toolResult.raw.toCompactString()}")
            log("turn_ended: ${turnEnd.raw.toCompactString()}")

            // The host really executed the accelerator: its frames prove it.
            val hostFrames = hostFrames()
            assertTrue(
                "the host never received an EXEC_REQ: $hostFrames",
                hostFrames.any { it.contains(" EXEC_REQ ") },
            )
            assertTrue(
                "the host never sent an EXEC_EVT: $hostFrames",
                hostFrames.any { it.contains(" EXEC_EVT ") },
            )
            assertTrue("the exec lane produced no result", execResults.isNotEmpty())
            log("exec results: $execResults")
            assertTrue(
                "the exec result is not a successful exit: $execResults",
                execResults.any { it.contains("exited", ignoreCase = true) },
            )

            // The model was reached through the REAL gateway: two exchanges, both
            // dispatched, both to the exact allow-listed upstream.
            val exchanges = front.exchanges
            // Three model calls: the session-title call DSH makes for a new session,
            // then the turn's tool-call call and its final call.
            assertEquals("title + two turn requests", 3, exchanges.size)
            assertTrue(exchanges.all { it.dispatch == GatewayDispatch.ALLOW })
            assertTrue(
                "the gateway's outbound URL must be the scripted upstream: " +
                    exchanges.map { it.outboundUrl },
                exchanges.all { it.outboundUrl.startsWith(upstream.baseUrl) },
            )
            val requests = upstream.requests
            val turnRequests = requests.filter { !it.isTitleRequest }
            assertEquals(
                "one scripted model request per assistant turn: ${requests.map { it.path }}",
                2,
                turnRequests.size,
            )
            assertTrue(
                "the first turn request carries no tool result",
                !turnRequests[0].carriesToolResult,
            )
            assertTrue(
                "the second turn request carries the tool result",
                turnRequests[1].carriesToolResult,
            )
            val assistant = events.filter { it.hostKind == "assistant_message" }
            assertTrue(
                "the scripted final text must be the answer the worker reports: " +
                    assistant.map { it.raw.toCompactString() },
                assistant.any { it.raw.toCompactString().contains(SCRIPTED_FINAL_TEXT) },
            )
            // The tool result the model saw is the host's real `phone info` payload.
            assertTrue(
                "the tool result does not carry the host's device facts: " +
                    toolResult.raw.toCompactString().take(300),
                toolResult.raw.toCompactString().contains("\"sdk\":35") ||
                    toolResult.raw.toCompactString().contains("manufacturer"),
            )

            // ---- the turn's trace in the VFS -------------------------------
            assertTrue(
                "the worker sent no VFS_MUT frames during the turn",
                vfsMutations.get() > 0,
            )
            val recorded = findTurnTrace(sessionId, PROMPT)
            log("VFS trace: mutations=${vfsMutations.get()} matching files=$recorded")
            assertTrue(
                "no materialized file records this turn (session=$sessionId); " +
                    "workspace=${listFiles(paths.materializedWorkspace)} " +
                    "home=${listFiles(paths.materializedHome)}",
                recorded.isNotEmpty(),
            )
        } finally {
            runCatching { runBlocking { follow.close() } }
        }
    }

    // ---------------------------------------------------------------- helpers

    private fun hostFrames(): List<String> =
        frameTrace.filter { it.contains("EXEC_REQ") || it.contains("EXEC_EVT") }

    /**
     * Files under the materialized home/workspace that name [sessionId] or [prompt].
     *
     * The tree is live: the worker may be mid-write while this scans, so a file
     * that disappears between `walk` and `read` is skipped, never a test failure
     * of its own. What is asserted is that at least one materialized file names
     * this turn.
     */
    private fun findTurnTrace(sessionId: String, prompt: String): List<String> {
        val matches = ArrayList<String>()
        for (root in listOf(paths.materializedHome, paths.materializedWorkspace)) {
            if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS)) continue
            try {
                Files.walk(root).use { stream ->
                    val iterator = stream.iterator()
                    while (iterator.hasNext()) {
                        val entry = try {
                            iterator.next()
                        } catch (_: java.io.IOException) {
                            break
                        } catch (_: java.io.UncheckedIOException) {
                            break
                        }
                        try {
                            if (!Files.isRegularFile(entry, LinkOption.NOFOLLOW_LINKS)) continue
                            if (Files.size(entry) > MAX_SCANNED_BYTES) continue
                            val text = String(Files.readAllBytes(entry), Charsets.UTF_8)
                            if (text.contains(sessionId) || text.contains(prompt)) {
                                matches += paths.root.relativize(entry).toString()
                            }
                        } catch (_: java.io.IOException) {
                            // A file that vanished mid-walk is a live tree, not a defect.
                        }
                    }
                }
            } catch (_: java.io.IOException) {
                continue
            } catch (_: java.io.UncheckedIOException) {
                continue
            }
        }
        return matches
    }

    private fun listFiles(root: Path): List<String> {
        if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS)) return emptyList()
        val out = ArrayList<String>()
        try {
            Files.walk(root).use { stream ->
                for (entry in stream) {
                    if (!Files.isRegularFile(entry, LinkOption.NOFOLLOW_LINKS)) continue
                    out += root.relativize(entry).toString()
                    if (out.size >= 20) break
                }
            }
        } catch (_: java.io.IOException) {
            return out
        } catch (_: java.io.UncheckedIOException) {
            return out
        }
        return out
    }

    private fun <T> retrying(what: String, attempts: Int = 4, block: () -> T): T {
        var last: Exception? = null
        repeat(attempts) { attempt ->
            try {
                return block()
            } catch (failure: Exception) {
                last = failure
                log("$what attempt ${attempt + 1}/$attempts failed: ${failure.message}")
                Thread.sleep(1_000)
            }
        }
        throw AssertionError("$what never answered", last)
    }

    private fun onMain(block: () -> Unit) = instrumentation.runOnMainSync(block)

    private fun await(what: String, timeoutMillis: Long, predicate: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            if (predicate()) return
            Thread.sleep(POLL_MILLIS)
        }
        throw AssertionError(
            "$what did not happen within $timeoutMillis ms; frames=${frameTrace.takeLast(20)} " +
                "hostErrors=${hostLog.errors.takeLast(10)}",
        )
    }

    private fun deleteTree(root: Path) {
        if (!Files.exists(root, LinkOption.NOFOLLOW_LINKS)) return
        Files.walk(root).use { stream ->
            stream.sorted(Comparator.reverseOrder<Path>()).forEach { Files.deleteIfExists(it) }
        }
    }

    private fun log(message: String) {
        Log.i(TAG, message)
    }

    private fun JsonObject.toCompactString(): String = toJsonString()

    /**
     * The engine→host seam: forwards every frame to the real host and feeds the
     * `/api` driver, which is the half of the lane `:dsh` does not implement.
     */
    private class TurnSeam(
        private val onConsole: (String) -> Unit,
        private val trace: (String, String, Long) -> Unit,
        private val onExecEvent: (String) -> Unit,
        private val onVfsMutation: () -> Unit,
        private val onHostError: (String) -> Unit,
        private val journalRecords: java.util.concurrent.atomic.AtomicInteger,
    ) : LoopbackChannelHandler {
        @Volatile
        var hostHandler: LoopbackChannelHandler? = null

        @Volatile
        private var api: ApiFrameChannel? = null

        fun apiLive(): Boolean = api != null

        fun requireApi(): ApiFrameChannel =
            api ?: throw IllegalStateException("the channel was never opened")

        override suspend fun onOpen(connection: LoopbackConnection) {
            val channel = ApiFrameChannel(
                target = connection,
                trace = trace,
                onOutboundFrame = { type, payload -> observeOutbound(type, payload) },
            )
            api = channel
            hostHandler?.onOpen(channel)
        }

        override suspend fun onBinary(connection: LoopbackConnection, payload: ByteArray) {
            val channel = api ?: return
            channel.onInbound(payload)
            runBlocking { observe(payload) }
            hostHandler?.onBinary(channel, payload)
        }

        override suspend fun onClosed(connection: LoopbackConnection, cause: ChannelCloseCause) {
            hostHandler?.onClosed(connection, cause)
            api = null
        }

        /**
         * Host→worker payloads: the `EXEC_EVT` the assertions need is one of them,
         * and it never reaches `onBinary` (that direction is worker→host).
         */
        private fun observeOutbound(type: Int, payload: ByteArray) {
            if (type != 0x21) return
            runCatching {
                val fields = JsonValue.parse(WireCodec.decode(payload))
                onExecEvent(fields.toJsonString())
            }
        }

        /** Reads the frames the assertions name; never consumes them. */
        private suspend fun observe(payload: ByteArray) {
            if (payload.size < 16) return
            val type = payload[2].toInt() and 0xFF
            if (type == 0x30) {
                // JOURNAL (0x30): `:dsh`'s HostChannel does not implement the
                // journal lane, so it never answers (the Worker restarts the
                // channel after a 30 s durability wait). The test seam answers
                // level-1 for the records it sees, and says so: it is a TEST
                // stand-in for a missing host lane, not host persistence.
                runCatching {
                    val fields = JsonValue.parse(WireCodec.decode(payload)) as JsonObject
                    val jseq = (fields["jseq"] as? com.phonedsh.agentcore.JsonNumber)?.asLongOrNull()
                        ?: return@runCatching
                    val sessionId = (fields["session_id"] as? com.phonedsh.agentcore.JsonString)?.value
                        ?: return@runCatching
                    journalRecords.incrementAndGet()
                    val ack = JsonObject(
                        linkedMapOf(
                            "level" to com.phonedsh.agentcore.JsonNumber("1"),
                            "session_id" to com.phonedsh.agentcore.JsonString(sessionId),
                            "upto_jseq" to com.phonedsh.agentcore.JsonNumber(jseq.toString()),
                        ),
                    )
                    api?.sendFrame("JOURNAL_ACK", ack)
                }
            }
            if (type == 0x7F) {
                runCatching {
                    val fields = JsonValue.parse(WireCodec.decode(payload)).toJsonString()
                    onHostError(fields)
                }
            }
            if (type == 0x21) {
                runCatching {
                    val fields = JsonValue.parse(WireCodec.decode(payload))
                    onExecEvent(fields.toJsonString())
                }
            }
            if (type == 0x10) onVfsMutation()
            if (type == 0x60) {
                // The worker's console line is how the tree announces itself
                // (`XL_DSH_READY <port>`); it is also the only signal that the
                // `/api` frame subscriber is installed.
                runCatching {
                    val fields = JsonValue.parse(WireCodec.decode(payload))
                    val text = (fields as? JsonObject)?.get("text")
                    if (text is com.phonedsh.agentcore.JsonString) onConsole(text.value)
                }
            }
        }
    }

    /** The engine's log seam, buffered for the failure message. */
    private class BufferingEngineLogger : EngineLogger {
        val lines = CopyOnWriteArrayList<String>()

        override fun log(level: EngineLogLevel, message: String) {
            lines += "${level.name}: $message"
            Log.i("PDSHEngine", message)
        }
    }

    /** The host facade's log seam, buffered; errors are part of a failure message. */
    private class RecordingHostLog : HostLog {
        val errors = CopyOnWriteArrayList<String>()

        override fun debug(message: String) {
            Log.d("PDSHHost", message)
        }

        override fun info(message: String) {
            Log.i("PDSHHost", message)
        }

        override fun warn(message: String) {
            Log.w("PDSHHost", message)
        }

        override fun error(message: String) {
            errors += message
            Log.e("PDSHHost", message)
        }
    }

    private companion object {
        const val TAG = "PDSHTurn"

        /** The per-start secret the origin gate and the worker env share. */
        const val LAUNCH_TOKEN = "0123456789abcdef0123456789abcdef0123456789abcdef"

        /** Where the worker's session tree lives inside its VFS. */
        const val WORKSPACE = "/dsh/workspace"

        const val PROMPT = "Run phone info and tell me what it says."

        /** The scripted script's final text; the fixture is the authority, this names it. */
        const val SCRIPTED_FINAL_TEXT = "The host executed `phone info`; done."
        const val LOG_DIRECTORY = "turn-test-xl"
        const val HOST_READY_TIMEOUT_MILLIS = 60_000L
        const val ENGINE_TIMEOUT_MILLIS = 120_000L
        const val CHANNEL_TIMEOUT_MILLIS = 120_000L
        const val TREE_TIMEOUT_MILLIS = 180_000L
        const val TREE_SETTLE_MILLIS = 800L
        const val FIRST_CALL_TIMEOUT_MILLIS = 20_000L
        const val POLL_MILLIS = 200L
        const val MAX_SCANNED_BYTES = 4L * 1024 * 1024

        /** High-frequency frames are counted, not logged one by one (they would bury the turn). */
        val QUIET_FRAME_TYPES = setOf("CONSOLE", "VFS_MUT", "VFS_ACK", "JOURNAL", "JOURNAL_ACK")
    }
}
