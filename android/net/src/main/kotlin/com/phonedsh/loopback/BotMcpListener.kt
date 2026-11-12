// phone-dsh — :net / com.phonedsh.loopback: the second loopback listener.
// SPDX-License-Identifier: MIT
//
// `spec/bot/v1/mcp-endpoint.md` §1/§2/§10 add a second HTTP origin next to the
// one launch/channel origin: the Bot MCP listener. It binds IPv4 loopback only
// (`127.0.0.1`, never `.any`), carries its own bearer, and is reached only
// through the host's `/v1/http` egress.
//
// Lifecycle contract:
//   * the bearer belongs to the BotMcpListener *instance* (PC D13 ruling 12).
//     A rebind/recovery on the same instance keeps it; a Worker restart reuses
//     the same instance and therefore the same value; only a new host start
//     (a new instance) generates a new one.
//   * the port is ephemeral. start() prefers the previous port, probes it with
//     a plain TCP connect bounded by 1.5 s, and only publishes the URL after
//     that probe succeeded. A bind/probe failure is returned as an explicit
//     Failed result, never swallowed.
//   * ensureListening() re-probes the live endpoint. On a failed probe or an
//     accept-loop failure it cancels the old listener, retries the previous port
//     twice (100 ms apart), then falls back to an ephemeral port. A changed URL
//     is announced before the new endpoint is handed back.
//   * the probe is a liveness check only: one TCP connect, no HTTP request, no
//     bearer and no MCP message (§10).
//
// The wire is a small HTTP/1.1 subset because §11 freezes exact bytes that a
// generic server engine changes: one request per connection, `Connection:
// close`, no chunked response, and an SSE head with neither `Content-Length`
// nor `Transfer-Encoding`.

package com.phonedsh.loopback

import com.phonedsh.agentcore.toJsonString
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * The published address of one live Bot MCP listener.
 *
 * [origin] is `http://127.0.0.1:<port>` with no trailing slash, matching
 * [LoopbackEndpoint]. The token is the listener's own bearer; [toString] never
 * prints it.
 */
data class BotMcpEndpoint(
    val port: Int,
    /** The per-instance Bot bearer. Redacted by [toString]. */
    val token: String,
    /** `http://127.0.0.1:<port>`, no trailing slash. */
    val origin: String,
) {
    val host: String get() = LoopbackConfiguration.LOOPBACK_HOST

    /** Absolute URL of [path] on this origin. The token is not attached. */
    fun urlFor(path: String): String {
        require(path.startsWith("/")) { "path must start with '/', was '$path'" }
        return origin + path
    }

    /** The Bot MCP endpoint `/mcp` (the Worker's `PDSH_PHONE_MCP_URL`). */
    fun mcpUrl(): String = urlFor("/mcp")

    override fun toString(): String =
        "BotMcpEndpoint(origin=$origin, port=$port, token=<redacted>)"
}

/** The result of one [BotMcpListener.start]. */
sealed interface BotMcpStartResult {
    data class Started(val endpoint: BotMcpEndpoint) : BotMcpStartResult

    /**
     * No listener is live. [attemptedPorts] lists every port tried, including
     * `0` (the ephemeral fallback); [cause] is the last bind/probe failure.
     */
    data class Failed(
        val cause: Throwable,
        val attemptedPorts: List<Int>,
    ) : BotMcpStartResult
}

/** The result of one [BotMcpListener.ensureListening] recovery pass. */
sealed interface BotMcpEnsureResult {
    /** The live endpoint still answered its TCP probe; it was not changed. */
    data class Unchanged(val endpoint: BotMcpEndpoint) : BotMcpEnsureResult

    /** A new listener is live. [previous] is the endpoint that failed the probe. */
    data class Recovered(
        val previous: BotMcpEndpoint,
        val endpoint: BotMcpEndpoint,
    ) : BotMcpEnsureResult

    /** Recovery could not bind/probe any port; no endpoint is live. */
    data class Failed(
        val cause: Throwable,
        val lastEndpoint: BotMcpEndpoint?,
    ) : BotMcpEnsureResult
}

/** Thrown by [BotMcpListener.startOrThrow]; carries the engine's own failure. */
class BotMcpStartException(
    message: String,
    cause: Throwable,
) : Exception(message, cause)

/**
 * The Bot MCP listener (`spec/bot/v1/mcp-endpoint.md` §2/§10).
 *
 * @param handler the App's B5a1 application seam; `:net` does not interpret
 *   JSON-RPC methods.
 * @param token the per-instance bearer. The default is a fresh 128-bit
 *   lowercase-hex value; pass a pinned value only for a deterministic test.
 * @param preferredPort the port to try first (normally the previous start's
 *   port). `0` asks the OS for an ephemeral port. A failure falls back to an
 *   ephemeral port.
 * @param nativeMcp optional legacy `/mcp/native` server. It is buffered and has
 *   no SSE form (GAP-36); most Bot listeners do not carry it.
 * @param timing the frozen 5 s / 15 s / 1.5 s values; tests may scale them.
 * @param onEndpointChange called on the first publish and whenever recovery
 *   changes the URL, before the new endpoint is returned to the caller.
 */
class BotMcpListener(
    private val handler: BotMcpRequestHandler,
    val token: String = LoopbackToken.generate(),
    private val preferredPort: Int = 0,
    private val nativeMcp: NativeMcpServing? = null,
    private val timing: BotMcpSseTiming = BotMcpSseTiming.STANDARD,
    private var onEndpointChange: ((BotMcpEndpoint) -> Unit)? = null,
) : AutoCloseable {
    init {
        require(preferredPort in 0..LoopbackConfiguration.MAX_PORT) {
            "preferredPort must be 0...${LoopbackConfiguration.MAX_PORT}, was $preferredPort"
        }
        LoopbackToken.requireUsable(token)
    }

    private val lock = ReentrantLock()
    private var running: Running? = null
    private var lastPort: Int = preferredPort

    /** The most recent published origin, or null while stopped. */
    @Volatile
    private var currentOrigin: String? = null

    /** Test-only liveness override; production always uses the real TCP probe. */
    @Volatile
    private var probeOverride: ((Int) -> Boolean)? = null

    /** The live endpoint, or null before [start] and after [stop]. */
    fun endpoint(): BotMcpEndpoint? = lock.withLock { running?.endpoint }

    /** Whether the current listener has neither an accept-loop failure nor a failed probe. */
    fun isHealthy(): Boolean = lock.withLock {
        val current = running ?: return false
        current.failures.get() == null && !current.server.isClosed && probe(current.endpoint.port)
    }

    /**
     * Starts the listener.
     *
     * Tries [preferredPort] (or the previous start's port) first, then an
     * ephemeral port. Each candidate is bound and probed; only a probed
     * listener is published. The token is never regenerated here.
     */
    fun start(): BotMcpStartResult = lock.withLock {
        check(running == null) { "the Bot MCP listener is already started; call stop() first" }
        val candidates = LinkedHashSet<Int>()
        if (lastPort in 1..LoopbackConfiguration.MAX_PORT) candidates.add(lastPort)
        candidates.add(0)
        val failures = ArrayList<Throwable>()
        for (port in candidates) {
            try {
                val started = bindAndProbe(port)
                running = started
                lastPort = started.endpoint.port
                announce(previous = null, endpoint = started.endpoint)
                return BotMcpStartResult.Started(started.endpoint)
            } catch (failure: Throwable) {
                failures.add(failure)
            }
        }
        val cause = failures.lastOrNull()
            ?: IllegalStateException("the Bot MCP listener bound no port")
        BotMcpStartResult.Failed(cause, candidates.toList())
    }

    /** [start], but a failure is an exception instead of a result. */
    fun startOrThrow(): BotMcpEndpoint = when (val result = start()) {
        is BotMcpStartResult.Started -> result.endpoint
        is BotMcpStartResult.Failed -> throw BotMcpStartException(
            "the Bot MCP listener could not start on any of ${result.attemptedPorts}",
            result.cause,
        )
    }

    /**
     * Probes the current endpoint and rebinds when it no longer accepts.
     *
     * The previous port is retried twice with 100 ms between attempts; only an
     * occupied/failed port falls back to `.any` (an ephemeral port). The
     * instance token is unchanged, and a URL change is passed to
     * [onEndpointChange] before the new endpoint is returned.
     */
    fun ensureListening(): BotMcpEnsureResult = lock.withLock {
        val current = running
            ?: return BotMcpEnsureResult.Failed(
                IllegalStateException("the Bot MCP listener is not started"),
                null,
            )
        val previous = current.endpoint
        val healthy = current.failures.get() == null &&
            !current.server.isClosed &&
            probe(previous.port)
        if (healthy) return BotMcpEnsureResult.Unchanged(previous)

        stopRunningLocked(current)
        val failures = ArrayList<Throwable>()
        repeat(2) { attempt ->
            try {
                val started = bindAndProbe(previous.port)
                running = started
                lastPort = started.endpoint.port
                announce(previous, started.endpoint)
                return BotMcpEnsureResult.Recovered(previous, started.endpoint)
            } catch (failure: Throwable) {
                failures.add(failure)
            }
            if (attempt == 0) {
                try {
                    Thread.sleep(REBIND_RETRY_MILLIS)
                } catch (interrupted: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return BotMcpEnsureResult.Failed(
                        IOException("the Bot MCP rebind was interrupted", interrupted),
                        previous,
                    )
                }
            }
        }
        try {
            val started = bindAndProbe(0)
            running = started
            lastPort = started.endpoint.port
            announce(previous, started.endpoint)
            BotMcpEnsureResult.Recovered(previous, started.endpoint)
        } catch (failure: Throwable) {
            failures.add(failure)
            BotMcpEnsureResult.Failed(failures.last(), previous)
        }
    }

    /** Stops and joins the listener. Idempotent; the token stays on the instance. */
    fun stop() {
        val current = lock.withLock {
            val snapshot = running
            running = null
            currentOrigin = null
            snapshot
        } ?: return
        stopRunning(current)
    }

    /** Same as [stop]; makes the listener usable with `use { }`. */
    override fun close() {
        stop()
    }

    /** Replaces the endpoint-change observer (host wiring may attach one late). */
    fun setOnEndpointChange(callback: ((BotMcpEndpoint) -> Unit)?) {
        lock.withLock { onEndpointChange = callback }
    }

    /**
     * Test-only: force the liveness probe to [result] so the explicit
     * bind-ok/probe-failed branch can be exercised without a mock HTTP stack.
     * The real probe still runs for every test that does not install a hook.
     */
    internal fun probeForTesting(result: ((Int) -> Boolean)?) {
        probeOverride = result
    }

    // -------------------------------------------------------------- binding

    private fun bindAndProbe(port: Int): Running {
        val server = ServerSocket()
        val failures = AtomicReference<Throwable?>(null)
        val sockets = ConcurrentHashMap.newKeySet<Socket>()
        val executor = Executors.newCachedThreadPool { task ->
            Thread(task, "pdsh-bot-mcp").apply { isDaemon = true }
        }
        try {
            server.reuseAddress = true
            server.bind(
                InetSocketAddress(InetAddress.getByName(LoopbackConfiguration.LOOPBACK_HOST), port),
                ACCEPT_BACKLOG,
            )
            val boundPort = server.localPort
            val endpoint = BotMcpEndpoint(
                port = boundPort,
                token = token,
                origin = "http://${LoopbackConfiguration.LOOPBACK_HOST}:$boundPort",
            )
            val serving = BotMcpServing(
                handler = handler,
                token = token,
                origin = { currentOrigin },
                nativeMcp = nativeMcp,
                timing = timing,
            )
            val running = Running(server, endpoint, serving, executor, sockets, failures)
            val accept = Thread({ acceptLoop(running) }, "pdsh-bot-mcp-accept").apply { isDaemon = true }
            running.acceptThread = accept
            accept.start()
            if (!probe(boundPort)) {
                throw IOException(
                    "the Bot MCP listener did not confirm its loopback origin on " +
                        "${endpoint.origin} within ${timing.probeTimeoutMillis} ms",
                )
            }
            // The URL is published only after the TCP probe succeeded; the
            // serving layer needs the origin for the first real request.
            currentOrigin = endpoint.origin
            failures.get()?.let { reported ->
                throw IllegalStateException("the Bot MCP accept loop failed while starting", reported)
            }
            return running
        } catch (failure: Throwable) {
            runCatching { server.close() }
            for (socket in sockets) runCatching { socket.close() }
            executor.shutdownNow()
            currentOrigin = null
            throw failure
        }
    }

    private fun acceptLoop(running: Running) {
        try {
            while (!running.server.isClosed) {
                val socket = running.server.accept()
                running.sockets.add(socket)
                try {
                    running.executor.execute {
                        try {
                            handle(socket, running)
                        } catch (cancelled: InterruptedException) {
                            Thread.currentThread().interrupt()
                        } catch (_: Throwable) {
                            // A dead peer is not a listener failure; the
                            // connection was one request and is already gone.
                        } finally {
                            running.sockets.remove(socket)
                            runCatching { socket.close() }
                        }
                    }
                } catch (rejected: java.util.concurrent.RejectedExecutionException) {
                    runCatching { socket.close() }
                }
            }
        } catch (failure: SocketException) {
            if (!running.server.isClosed) running.failures.compareAndSet(null, failure)
        } catch (failure: IOException) {
            if (!running.server.isClosed) running.failures.compareAndSet(null, failure)
        } catch (failure: Throwable) {
            if (!running.server.isClosed) running.failures.compareAndSet(null, failure)
        }
    }

    private fun handle(socket: Socket, running: Running) {
        socket.soTimeout = REQUEST_TIMEOUT_MILLIS
        val input = BufferedInputStream(socket.getInputStream())
        val request = readRequest(input) ?: return
        val exchange = RawExchange(socket, input, handler.mcpSessionId, request)
        try {
            runBlocking { running.serving.serve(exchange) }
        } catch (cancelled: InterruptedException) {
            Thread.currentThread().interrupt()
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            // The socket or the listener went away; the handler's deferred is
            // not cancelled (a dropped connection is not a cancellation signal).
        } catch (_: Throwable) {
            exchange.failInternal()
        }
    }

    private fun stopRunningLocked(current: Running) {
        currentOrigin = null
        stopRunning(current)
    }

    private fun stopRunning(current: Running) {
        // The legacy native server, when mounted here, settles its pending
        // receipts before the origin disappears (native-mcp.md host shutdown).
        nativeMcp?.let { server ->
            runCatching {
                runBlocking { withTimeoutOrNull(NATIVE_SETTLE_MILLIS) { server.cancelPendingOperations() } }
            }
        }
        runCatching { current.server.close() }
        for (socket in current.sockets) runCatching { socket.close() }
        current.executor.shutdownNow()
        runCatching { current.executor.awaitTermination(STOP_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS) }
        runCatching { current.acceptThread?.interrupt() }
    }

    // ---------------------------------------------------------------- probe

    /**
     * One TCP liveness probe (`spec/bot/v1/mcp-endpoint.md` §10). It opens and
     * immediately closes a loopback connection: no HTTP request, no bearer and
     * no MCP message.
     */
    private fun probe(port: Int): Boolean {
        probeOverride?.let { return it(port) }
        if (port <= 0) return false
        return try {
            Socket().use { socket ->
                socket.connect(
                    InetSocketAddress(InetAddress.getByName(LoopbackConfiguration.LOOPBACK_HOST), port),
                    timing.probeTimeoutMillis,
                )
            }
            true
        } catch (failure: IOException) {
            false
        } catch (failure: SecurityException) {
            false
        }
    }

    private fun announce(previous: BotMcpEndpoint?, endpoint: BotMcpEndpoint) {
        if (previous?.origin == endpoint.origin) return
        onEndpointChange?.invoke(endpoint)
    }

    // --------------------------------------------------------------- wire

    private fun readRequest(input: InputStream): WireRequest? {
        val head = readHead(input) ?: return null
        val lines = head.split("\r\n")
        if (lines.size < 2) return null
        val requestLine = lines.first().split(' ', limit = 3)
        if (requestLine.size < 2) return null
        val headers = LinkedHashMap<String, String>()
        val lowered = LinkedHashMap<String, String>()
        for (line in lines.drop(1)) {
            val colon = line.indexOf(':')
            if (colon <= 0) continue
            val original = line.substring(0, colon).trim()
            if (original.isEmpty()) continue
            val name = original.lowercase()
            val value = line.substring(colon + 1).trim()
            headers[original] = headers[original]?.let { "$it, $value" } ?: value
            lowered[name] = lowered[name]?.let { "$it, $value" } ?: value
        }
        val declared = lowered["content-length"]?.toLongOrNull()
        val chunked = lowered["transfer-encoding"]
            ?.split(',')
            ?.any { it.trim().equals("chunked", ignoreCase = true) } == true
        return WireRequest(requestLine[0], requestLine[1], headers, chunked, declared)
    }

    /** Reads the header block (inclusive of its final CRLFCRLF) with a hard cap. */
    private fun readHead(input: InputStream): String? {
        val out = ByteArrayOutputStream()
        var matched = 0
        while (out.size() < MAX_HEADER_BYTES) {
            val value = input.read()
            if (value < 0) return null
            out.write(value)
            matched = when {
                value == '\r'.code -> if (matched == 2) 3 else 1
                value == '\n'.code -> when (matched) {
                    1 -> 2
                    3 -> 4
                    else -> 0
                }
                else -> 0
            }
            if (matched == 4) {
                return out.toByteArray().toString(Charsets.ISO_8859_1)
            }
        }
        return null
    }

    private data class WireRequest(
        val method: String,
        val target: String,
        val headers: Map<String, String>,
        val chunked: Boolean,
        val declaredLength: Long?,
    )

    private class Running(
        val server: ServerSocket,
        val endpoint: BotMcpEndpoint,
        val serving: BotMcpServing,
        val executor: ExecutorService,
        val sockets: MutableSet<Socket>,
        val failures: AtomicReference<Throwable?>,
    ) {
        @Volatile
        var acceptThread: Thread? = null
    }

    /**
     * One accepted connection as [BotMcpServing] sees it.
     *
     * Every write is the exact §11 byte form: a JSON answer has
     * `Content-Type: application/json`, `Content-Length` and `Connection: close`;
     * an SSE answer has `text/event-stream`, `Cache-Control: no-cache`,
     * `Connection: close` and neither length nor transfer encoding.
     */
    private class RawExchange(
        private val socket: Socket,
        private val input: InputStream,
        private val sessionId: String,
        private val request: WireRequest,
    ) : BotMcpExchange {
        private val output: OutputStream = socket.getOutputStream()
        private var responded = false
        private var bodyRead = false
        private var cachedBody: ByteArray? = null

        override val method: String get() = request.method
        override val target: String get() = request.target
        override val headers: Map<String, String> get() = request.headers
        override val declaredLength: Long? get() = request.declaredLength

        override fun header(name: String): String? =
            headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value

        override suspend fun readBody(limit: Int): ByteArray? {
            if (bodyRead) return cachedBody
            bodyRead = true
            val bytes = when {
                request.chunked -> readChunked(limit)
                else -> {
                    val declared = request.declaredLength ?: 0L
                    if (declared > limit) return null
                    if (declared == 0L) ByteArray(0) else readExactly(input, declared.toInt()) ?: ByteArray(0)
                }
            }
            cachedBody = bytes
            return bytes
        }

        override suspend fun respondJson(status: Int, body: ByteArray, session: Boolean) {
            if (responded) return
            // An early refusal (origin/bearer/method/target) is decided before
            // the body. Drain a bounded body first so closing the socket does
            // not turn the frozen response into a TCP reset. A 413 is the one
            // exception: it is decided from the declared length and must not
            // read the body (mcp-endpoint.md §11).
            if (!bodyRead && status != 413) {
                runCatching {
                    readBody(BotMcpServing.MAXIMUM_BODY_BYTES + BotMcpServing.READ_HEADROOM)
                }
            }
            responded = true
            val head = buildString {
                append("HTTP/1.1 ").append(status).append(' ').append(reason(status)).append("\r\n")
                append("Content-Type: application/json\r\n")
                append("Content-Length: ").append(body.size).append("\r\n")
                if (session) append(BotMcpServing.MCP_SESSION_ID).append(": ").append(sessionId).append("\r\n")
                append("Connection: close\r\n\r\n")
            }
            output.write(head.toByteArray(Charsets.ISO_8859_1))
            output.write(body)
            output.flush()
        }

        override suspend fun respondSse(session: Boolean, producer: suspend BotMcpSseEmitter.() -> Unit) {
            if (responded) return
            responded = true
            val head = buildString {
                append("HTTP/1.1 200 ").append(reason(200)).append("\r\n")
                append("Content-Type: text/event-stream\r\n")
                append("Cache-Control: no-cache\r\n")
                if (session) append(BotMcpServing.MCP_SESSION_ID).append(": ").append(sessionId).append("\r\n")
                append("Connection: close\r\n\r\n")
            }
            output.write(head.toByteArray(Charsets.ISO_8859_1))
            output.flush()
            val emitter = RawSseEmitter(output)
            producer(emitter)
            output.flush()
        }

        fun failInternal() {
            runCatching {
                if (!responded) {
                    responded = true
                    val body = """{"error":"internal error"}""".toByteArray(Charsets.UTF_8)
                    val head = "HTTP/1.1 500 Internal Server Error\r\n" +
                        "Content-Type: application/json\r\n" +
                        "Content-Length: ${body.size}\r\n" +
                        "Connection: close\r\n\r\n"
                    output.write(head.toByteArray(Charsets.ISO_8859_1))
                    output.write(body)
                    output.flush()
                }
            }
        }

        private fun readChunked(limit: Int): ByteArray? {
            val out = ByteArrayOutputStream()
            while (true) {
                val line = readLine(input, MAX_CHUNK_LINE_BYTES) ?: return out.toByteArray()
                val size = line.substringBefore(';').trim().toLongOrNull(16) ?: return null
                if (size == 0L) {
                    // Consume the trailer section (bounded by the caller's read
                    // deadline); the payload is already complete.
                    while (true) {
                        val trailer = readLine(input, MAX_CHUNK_LINE_BYTES) ?: break
                        if (trailer.isEmpty()) break
                    }
                    return out.toByteArray()
                }
                if (size < 0 || size > Int.MAX_VALUE) return null
                if (out.size().toLong() + size > limit) return null
                val chunk = readExactly(input, size.toInt()) ?: return null
                out.write(chunk)
                readExactly(input, 2) ?: return null
            }
        }

        private fun readLine(input: InputStream, maximum: Int): String? {
            val out = ByteArrayOutputStream()
            while (out.size() <= maximum) {
                val value = input.read()
                if (value < 0) {
                    return if (out.size() == 0) null else String(out.toByteArray(), Charsets.ISO_8859_1)
                }
                if (value == '\n'.code) {
                    val line = out.toByteArray()
                    val length = if (line.isNotEmpty() && line.last() == '\r'.code.toByte()) line.size - 1 else line.size
                    return String(line, 0, length, Charsets.ISO_8859_1)
                }
                out.write(value)
            }
            return null
        }

        private fun readExactly(input: InputStream, count: Int): ByteArray? {
            if (count < 0) return null
            if (count == 0) return ByteArray(0)
            val out = ByteArray(count)
            var offset = 0
            while (offset < count) {
                val read = input.read(out, offset, count - offset)
                if (read < 0) return null
                offset += read
            }
            return out
        }

        private fun reason(status: Int): String = when (status) {
            200 -> "OK"
            202 -> "Accepted"
            400 -> "Bad Request"
            401 -> "Unauthorized"
            403 -> "Forbidden"
            404 -> "Not Found"
            405 -> "Method Not Allowed"
            413 -> "Payload Too Large"
            500 -> "Internal Server Error"
            else -> "Status"
        }

        private class RawSseEmitter(private val output: OutputStream) : BotMcpSseEmitter {
            override suspend fun message(json: String) {
                val compact = try {
                    com.phonedsh.agentcore.JsonValue.parse(json).toJsonString()
                } catch (invalid: Exception) {
                    json.replace("\r", " ").replace("\n", " ")
                }
                output.write(("event: message\ndata: " + compact + "\n\n").toByteArray(Charsets.UTF_8))
                output.flush()
            }

            override suspend fun keepalive() {
                output.write(": keepalive\n\n".toByteArray(Charsets.UTF_8))
                output.flush()
            }
        }
    }

    private companion object {
        const val REBIND_RETRY_MILLIS = 100L
        const val STOP_TIMEOUT_MILLIS = 2_000L
        const val NATIVE_SETTLE_MILLIS = 5_000L
        const val REQUEST_TIMEOUT_MILLIS = 30_000
        const val ACCEPT_BACKLOG = 64
        const val MAX_HEADER_BYTES = 64 * 1024
        const val MAX_CHUNK_LINE_BYTES = 1_024
    }
}
