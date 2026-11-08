// phone-dsh — :loopback / com.phonedsh.loopback: the one loopback origin.
// SPDX-License-Identifier: MIT
//
// Lifecycle of the single origin: bind 127.0.0.1 on a random port, generate a
// per-start token, serve the caller's asset directory, carry the one ordered
// WebSocket. start()/stop() are symmetric and repeatable; every thread and
// coroutine belongs to the Ktor engine, so stop() joins them before it returns.
//
// A start is proven, not assumed: the accept loop answers one authenticated
// launch-page request before the endpoint is handed back, and a failure of that
// proof throws synchronously (LoopbackStartException). An unexpected death of
// the engine's coroutines after a successful start is recorded on the instance
// instead of escaping into an unobserved scope.

package com.phonedsh.loopback

import io.ktor.server.cio.CIO
import io.ktor.server.engine.EmbeddedServer
import io.ktor.server.engine.embeddedServer
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.URLEncoder
import java.nio.file.Path
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * The one loopback HTTP origin of an App process.
 *
 * ```kotlin
 * val server = LoopbackServer(handler = engineChannelHandler)
 * val endpoint = server.start(assetsDir)   // 127.0.0.1:<random>, <fresh token>
 * // WebView loads endpoint.launchUrl(mapOf("channel" to endpoint.channelUrl(true), ...))
 * server.stop()
 * ```
 *
 * Repeatable: after [stop] the same instance can [start] again with a new port
 * (and, when the token is not pinned, a new token). `start` while already
 * started throws instead of silently leaking the first engine.
 *
 * [start] is a **confirmed** start: the OS port is bound, the engine reported
 * its connector and the origin answered one authenticated launch-page request
 * before the endpoint is returned. A bind failure, a missing `INTERNET`
 * permission or an accept loop that died on arrival therefore throws
 * [LoopbackStartException] on the caller's thread, with the engine's own failure
 * as `cause`; nothing is left half-started and [endpoint] stays null.
 *
 * An **unexpected death after a successful start** (the engine's accept
 * coroutine exiting for any reason the transport did not expect) is caught by
 * the [CoroutineExceptionHandler] installed in the engine's parent coroutine
 * context. It is recorded in [lastFailure] and [LoopbackMetrics.engineFailures]
 * and is never rethrown into an unobserved scope, so it cannot crash the
 * process. A recorded failure means the origin may no longer accept; the caller
 * observes it and calls [stop].
 */
class LoopbackServer(
    private val configuration: LoopbackConfiguration = LoopbackConfiguration(),
    private val handler: LoopbackChannelHandler = LoopbackChannelHandler.Unhandled,
    /**
     * The `/v1/http` policy for this origin, or `null` when this start has no
     * outbound path. The engine passes the gateway adapter here; a test that
     * only exercises statics leaves it null and gets the documented 503.
     */
    private val httpEgress: LoopbackHttpEgress? = null,
    /**
     * The model-protocol edge for this origin, or `null` when this start has no
     * model upstream. The engine passes the host's configured endpoint and
     * credential provider here; without it the model routes are not mounted.
     */
    private val modelProxy: LoopbackModelProxy? = null,
    /**
     * The `/mcp/native` server, or `null` when this origin serves no native
     * phone tools. [stop] cancels and settles its pending work.
     */
    private val nativeMcp: NativeMcpServing? = null,
    /** D14 admission for native `tools/call` (503 while it returns false). */
    private val nativeMcpAdmission: () -> Boolean = { true },
) : AutoCloseable {
    private val lock = ReentrantLock()
    private var running: Running? = null
    private var retired: LoopbackService? = null
    private var failureLog: EngineFailureLog? = null

    /**
     * `host:port` of the live listener, read by the token gate on Ktor threads.
     *
     * Zero until the OS-assigned port is known. `@Volatile` publishes the value
     * to the engine threads that answer requests; the gate rejects a request
     * whose `Host` does not match it (the D22 authority binding).
     */
    @Volatile
    private var boundPort: Int = 0

    /**
     * Starts the origin on [assetsDir] with the configured handler.
     *
     * Returns only after the origin is proven to be serving (see the class KDoc).
     * On failure the engine has already been stopped, [endpoint] is null and the
     * instance can be started again.
     *
     * [launchToken] pins the per-start secret for this one start: the host
     * generates it, hands the same value to the page's `env` page parameter and
     * to this origin, so the worker's `PDSH_DSH_LAUNCH_TOKEN` and the loopback
     * gate/cookie are the same token. Null keeps the documented fallback
     * ([LoopbackConfiguration.token] when pinned, otherwise a fresh 128-bit
     * value). An explicitly supplied token wins over a pinned configuration.
     *
     * @throws LoopbackStartException when the port cannot be bound, the engine
     *   cannot be started or the origin does not answer its own probe; the
     *   underlying failure is the exception's cause.
     * @throws IllegalArgumentException when [launchToken] is shorter than
     *   [LoopbackConfiguration.MIN_PINNED_TOKEN_LENGTH] or contains whitespace
     *   or a control character.
     */
    fun start(assetsDir: Path, launchToken: String? = null): LoopbackEndpoint {
        if (launchToken != null) LoopbackToken.requireUsable(launchToken)
        return lock.withLock {
            check(running == null) { "the loopback server is already started; call stop() first" }
            val store = StaticAssetStore(assetsDir)
            val liveToken = launchToken
                ?: configuration.token.ifEmpty { LoopbackToken.generate() }
            val service = LoopbackService(
                configuration = configuration,
                token = liveToken,
                assets = store,
                handler = handler,
                httpEgress = httpEgress,
                modelProxy = modelProxy,
                nativeMcp = nativeMcp,
                nativeMcpAdmission = nativeMcpAdmission,
                authority = { "${LoopbackConfiguration.LOOPBACK_HOST}:$boundPort" },
            )
            val failures = EngineFailureLog()
            failureLog = failures
            // The handler must sit in the parent coroutine context: Ktor's engine
            // launches its accept coroutine from there, and an uncaught failure in
            // that scope is delivered to this handler instead of the thread's
            // uncaught-exception handler (which is what killed the process).
            val scope = CoroutineScope(SupervisorJob() + failures.handler)
            var engine: EmbeddedServer<*, *>? = null
            try {
                val created = scope.embeddedServer(
                    factory = CIO,
                    port = configuration.port,
                    host = LoopbackConfiguration.LOOPBACK_HOST,
                    parentCoroutineContext = failures.handler,
                    module = { service.install(this) },
                )
                engine = created
                created.start(wait = false)
                val connector = runBlocking { created.engine.resolvedConnectors() }.firstOrNull()
                    ?: throw IllegalStateException("the loopback engine reported no connector after start")
                // Publish the authority before the probe: the probe's Host is
                // checked by the same gate every later request goes through.
                boundPort = connector.port
                val endpoint = LoopbackEndpoint(
                    port = connector.port,
                    token = liveToken,
                    origin = "http://${LoopbackConfiguration.LOOPBACK_HOST}:${connector.port}",
                )
                // The connector only says the socket was bound; this proves the
                // accept loop is actually reading and answering on it.
                confirmAccepting(endpoint.port, liveToken)
                // Belt and braces: if the engine already reported a failure while
                // the probe ran, the answer may have come from a stale listener
                // and this start must not be reported as successful.
                failures.lastFailure()?.let { reported ->
                    throw IllegalStateException("the loopback engine reported a failure while starting", reported)
                }
                running = Running(created, service, endpoint, scope, failures)
                retired = null
                endpoint
            } catch (failure: Throwable) {
                // Ktor reports a bind/start failure both as the cancellation of
                // its startup coroutine and through the handler. Prefer the
                // engine's own failure so the caller sees the real SocketException
                // rather than a JobCancellationException.
                val engineFailure = awaitEngineFailure(failures, ENGINE_FAILURE_WAIT_MILLIS)
                val cause = engineFailure ?: failure
                if (engineFailure == null) failures.record(failure)
                failures.close()
                runCatching { engine?.stop(STOP_GRACE_MILLIS, STOP_TIMEOUT_MILLIS) }
                scope.cancel()
                throw LoopbackStartException(configuration.port, cause)
            }
        }
    }

    /**
     * Stops accepting, ends the live channel and joins the engine.
     *
     * Idempotent: a second call is a no-op, so `use { }` and an explicit stop
     * can coexist. After it returns the port is closed and no engine thread or
     * coroutine remains.
     */
    fun stop() {
        val current = lock.withLock {
            val snapshot = running
            running = null
            if (snapshot != null) {
                retired = snapshot.service
            } else {
                failureLog?.close()
            }
            snapshot
        } ?: return
        // native-mcp.md: host shutdown cancels and settles pending native work
        // (its receipt records the outcome) before the origin goes away.
        nativeMcp?.let { server ->
            runCatching { runBlocking { withTimeoutOrNull(NATIVE_SETTLE_MILLIS) { server.cancelPendingOperations() } } }
        }
        try {
            current.service.shutdown()
            current.engine.stop(STOP_GRACE_MILLIS, STOP_TIMEOUT_MILLIS)
        } finally {
            current.scope.cancel()
            current.failures.close()
        }
    }

    /** The endpoint of the current start, or null before start and after stop. */
    fun endpoint(): LoopbackEndpoint? = lock.withLock { running?.endpoint }

    /**
     * Counters of the current start, or of the most recent one after [stop].
     *
     * The channel counters are what the conformance tests assert on; nothing in
     * [LoopbackMetrics] contains the token. [LoopbackMetrics.engineFailures] also
     * reports the failures of a start that never returned an endpoint.
     */
    fun metrics(): LoopbackMetrics = lock.withLock {
        val base = (running?.service ?: retired)?.metrics() ?: LoopbackMetrics.Idle
        val failures = failureLog
        if (failures == null) base else base.copy(engineFailures = failures.count())
    }

    /**
     * The most recent unexpected engine failure of the current (or most recent)
     * start, or null while the origin is healthy.
     *
     * A non-null value after a successful start means the engine's coroutine
     * scope died unexpectedly: the origin may have stopped accepting. It is
     * recorded, never thrown, so the process keeps running; [endpoint] is left
     * unchanged so the caller can still correlate it, and [stop] remains safe.
     */
    fun lastFailure(): Throwable? = lock.withLock { failureLog?.lastFailure() }

    /**
     * The coroutine scope the engine was started in.
     *
     * Production code never needs it. It exists so the runtime-death policy can
     * be tested by launching a failing child in the very scope Ktor's engine
     * inherits; a test cannot reach Ktor's internal accept job otherwise.
     */
    internal fun engineScope(): CoroutineScope? = lock.withLock { running?.scope }

    /** Same as [stop]; makes `LoopbackServer` usable with `use { }`. */
    override fun close() {
        stop()
    }

    // ------------------------------------------------------------ start proof

    /**
     * Proves the accept loop is serving before `start` returns the endpoint.
     *
     * `engine.start(wait = false)` only guarantees that the listening socket was
     * bound; the accept coroutine can still die right after. One request to the
     * launch page — with the token in its query string, the one URL this design
     * allows a token in, loopback only and never logged — has to come back from
     * *this* origin. Each failed attempt is retried until [START_PROBE_TIMEOUT_MILLIS]
     * so a slow scheduler is not mistaken for a dead origin.
     */
    private fun confirmAccepting(port: Int, token: String) {
        val deadline = System.nanoTime() + START_PROBE_TIMEOUT_MILLIS * 1_000_000L
        var lastFailure: IOException? = null
        while (true) {
            val answer = try {
                probeLaunchPage(port, token).takeIf { it.isLoopbackAnswer() }
            } catch (failure: IOException) {
                lastFailure = failure
                null
            }
            if (answer != null) return
            if (System.nanoTime() >= deadline) {
                throw IOException(
                    "the loopback origin did not confirm that it is accepting on " +
                        "${LoopbackConfiguration.LOOPBACK_HOST}:$port",
                    lastFailure,
                )
            }
            try {
                Thread.sleep(PROBE_RETRY_MILLIS)
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
                throw IOException("the loopback start probe was interrupted", interrupted)
            }
        }
    }

    /** One launch-page request; returns the raw HTTP response (headers and body). */
    private fun probeLaunchPage(port: Int, token: String): String {
        Socket().use { socket ->
            socket.soTimeout = PROBE_READ_TIMEOUT_MILLIS
            socket.connect(
                InetSocketAddress(LoopbackConfiguration.LOOPBACK_HOST, port),
                PROBE_CONNECT_TIMEOUT_MILLIS,
            )
            // The launch page is the one path that accepts `?token=`; encoding it
            // keeps every pinable token valid regardless of its characters.
            val target = "/?token=" + URLEncoder.encode(token, Charsets.UTF_8.name())
            val request = buildString {
                append("GET ").append(target).append(" HTTP/1.1\r\n")
                append("Host: ").append(LoopbackConfiguration.LOOPBACK_HOST).append(':').append(port).append("\r\n")
                append("Connection: close\r\n\r\n")
            }
            socket.getOutputStream().apply {
                write(request.toByteArray(Charsets.ISO_8859_1))
                flush()
            }
            return readResponse(socket.getInputStream())
        }
    }

    /**
     * Reads the response the origin sent for the probe.
     *
     * Only the first [PROBE_MAX_RESPONSE_BYTES] are kept (the identity check only
     * needs the status line and the `Cache-Control: no-store` header this origin
     * stamps on every response it produces), but the rest is drained so the
     * origin is never left writing into a socket the probe just closed.
     */
    private fun readResponse(input: InputStream): String {
        val head = ByteArrayOutputStream()
        val chunk = ByteArray(4096)
        var drained = 0L
        while (drained < PROBE_MAX_DRAIN_BYTES) {
            val read = try {
                input.read(chunk)
            } catch (timeout: SocketTimeoutException) {
                break
            } catch (failure: IOException) {
                break
            }
            if (read < 0) break
            drained += read
            if (head.size() < PROBE_MAX_RESPONSE_BYTES) {
                head.write(chunk, 0, minOf(read, PROBE_MAX_RESPONSE_BYTES - head.size()))
            }
        }
        return head.toByteArray().toString(Charsets.ISO_8859_1)
    }

    /** True when [this] raw response came from a PhoneDSH loopback origin. */
    private fun String.isLoopbackAnswer(): Boolean {
        if (!startsWith("HTTP/1.1 ")) return false
        val status = removePrefix("HTTP/1.1 ").substringBefore(' ').toIntOrNull() ?: return false
        if (status !in 200..499) return false
        return contains(PROBE_NO_STORE_HEADER, ignoreCase = true)
    }

    /**
     * Waits briefly for the engine to report why its start failed.
     *
     * The failure is delivered on the engine's dispatcher, usually a few
     * milliseconds after the startup coroutine is cancelled; without this wait
     * `start` would wrap the cancellation instead of the real socket error.
     */
    private fun awaitEngineFailure(failures: EngineFailureLog, timeoutMillis: Long): Throwable? {
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
        while (true) {
            failures.lastFailure()?.let { return it }
            if (System.nanoTime() >= deadline) return null
            try {
                Thread.sleep(FAILURE_POLL_MILLIS)
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
                return failures.lastFailure()
            }
        }
    }

    private class Running(
        val engine: EmbeddedServer<*, *>,
        val service: LoopbackService,
        val endpoint: LoopbackEndpoint,
        val scope: CoroutineScope,
        val failures: EngineFailureLog,
    )

    /**
     * Records what the engine's own coroutine scope reports.
     *
     * Deliberately not a lifecycle state: the handler runs on an engine thread
     * and must not stop the engine from there. It records, [LoopbackServer.lastFailure]
     * and [LoopbackMetrics.engineFailures] expose it, and the caller decides.
     */
    private class EngineFailureLog {
        private val last = AtomicReference<Throwable?>(null)
        private val count = AtomicLong()
        @Volatile
        private var recording = true

        val handler = CoroutineExceptionHandler { _, cause -> record(cause) }

        fun record(cause: Throwable) {
            if (!recording) return
            count.incrementAndGet()
            last.set(cause)
        }

        fun count(): Long = count.get()

        fun lastFailure(): Throwable? = last.get()

        /** The engine is stopped; late reports must not touch the next start's log. */
        fun close() {
            recording = false
        }
    }

    private companion object {
        const val STOP_GRACE_MILLIS = 50L
        const val STOP_TIMEOUT_MILLIS = 2_000L
        const val NATIVE_SETTLE_MILLIS = 5_000L

        /** How long a failed `start` waits for the engine's own reason for dying. */
        const val ENGINE_FAILURE_WAIT_MILLIS = 1_500L
        const val FAILURE_POLL_MILLIS = 5L

        /** Total budget for proving the accept loop answers; only spent on failure. */
        const val START_PROBE_TIMEOUT_MILLIS = 3_000L
        const val PROBE_RETRY_MILLIS = 25L
        const val PROBE_CONNECT_TIMEOUT_MILLIS = 500
        const val PROBE_READ_TIMEOUT_MILLIS = 750

        const val PROBE_MAX_RESPONSE_BYTES = 1 shl 20
        const val PROBE_MAX_DRAIN_BYTES = 16L shl 20
        const val PROBE_NO_STORE_HEADER = "cache-control: no-store"
    }
}
