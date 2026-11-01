// phone-dsh — :loopback / com.phonedsh.loopback: Ktor CIO wiring of the origin.
// SPDX-License-Identifier: MIT
//
// One origin, four jobs:
//   1. the launch page (`/`, `/index.html`) and the worker's static assets,
//      served from the directory the caller passed to start();
//   2. exactly one WebSocket endpoint (`/channel`) carrying whole binary
//      payloads in order, with backpressure and a single active channel;
//   3. a per-start token gate in front of both, evaluated before routing so a
//      rejected upgrade never reaches the frame layer (channel.md §7.1);
//   4. the M1 model edge (`LoopbackModelProxy`), mounted only when the host
//      supplies one, which forwards the Worker's `/v1/...` model requests and
//      injects the host credential at the upstream origin.
//
// The token never enters a log line: this package installs no call-logging
// plugin, 401 bodies are constant and do not echo the request, and the URL is
// never formatted into an exception message.

package com.phonedsh.loopback

import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.withCharset
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.ApplicationCallPipeline
import io.ktor.server.application.call
import io.ktor.server.application.install
import io.ktor.server.http.content.LocalFileContent
import io.ktor.server.request.httpMethod
import io.ktor.server.request.path
import io.ktor.server.request.receiveChannel
import io.ktor.server.response.respond
import io.ktor.server.response.respondBytes
import io.ktor.server.routing.get
import io.ktor.server.routing.route
import io.ktor.server.routing.routing
import io.ktor.server.websocket.DefaultWebSocketServerSession
import io.ktor.server.websocket.WebSockets
import io.ktor.server.websocket.pingPeriod
import io.ktor.server.websocket.timeout
import io.ktor.server.websocket.webSocket
import io.ktor.websocket.CloseReason
import io.ktor.websocket.DefaultWebSocketSession
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.send
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import io.ktor.utils.io.readAvailable
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.time.Duration.Companion.seconds

internal class LoopbackService(
    private val configuration: LoopbackConfiguration,
    private val token: String,
    private val assets: StaticAssetStore,
    private val handler: LoopbackChannelHandler,
    /**
     * The `/v1/http` policy, or `null` when this start has no outbound path.
     *
     * Null is the honest default: a build without a gateway must answer 503
     * rather than pretend the Worker can reach a model or an MCP server.
     */
    private val httpEgress: LoopbackHttpEgress? = null,
    /**
     * The model-protocol edge (M1), or `null` when this start has no model proxy.
     *
     * Null keeps the pre-M1 behavior honest: without a configured upstream and a
     * credential provider the origin must not pretend the Worker can reach a
     * model through it.
     */
    private val modelProxy: LoopbackModelProxy? = null,
    /**
     * `host:port` this origin was actually bound to (`127.0.0.1:<port>`).
     *
     * A lambda, not a value: the service is installed during `start()`, before
     * the OS-assigned port is known. Requests only arrive after the port was
     * resolved and recorded by [LoopbackServer].
     */
    private val authority: () -> String,
) {
    private val unauthorizedRequests = AtomicLong()
    private val channelsAccepted = AtomicLong()
    private val channelsRejected = AtomicLong()
    private val activeChannels = AtomicInteger()
    private val framesIn = AtomicLong()
    private val framesOut = AtomicLong()
    private val bytesIn = AtomicLong()
    private val bytesOut = AtomicLong()
    private val inFlightFrames = AtomicInteger()
    private val maxInFlightFrames = AtomicInteger()
    private val connectionIds = AtomicInteger()
    private val channelSlot = AtomicReference<KtorConnection?>(null)
    private val liveSessions = ConcurrentHashMap.newKeySet<DefaultWebSocketSession>()
    private val stopping = AtomicBoolean(false)

    fun metrics(): LoopbackMetrics = LoopbackMetrics(
        activeChannels = activeChannels.get(),
        channelsAccepted = channelsAccepted.get(),
        channelsRejected = channelsRejected.get(),
        framesIn = framesIn.get(),
        framesOut = framesOut.get(),
        bytesIn = bytesIn.get(),
        bytesOut = bytesOut.get(),
        maxInFlightFrames = maxInFlightFrames.get(),
        unauthorizedRequests = unauthorizedRequests.get(),
    )

    /** Ends every live channel; called before the engine stops. */
    fun shutdown() {
        stopping.set(true)
        for (session in liveSessions) {
            runCatching { session.cancel() }
        }
        liveSessions.clear()
    }

    fun install(app: Application) {
        app.install(WebSockets) {
            pingPeriod = PING_PERIOD
            timeout = PING_TIMEOUT
            // Bounds the payload before it is buffered; a bigger frame closes 1009.
            maxFrameSize = configuration.maxChannelFrameBytes.toLong()
            masking = false
        }
        // Runs before routing, i.e. before the WebSocket upgrade is attempted.
        app.intercept(ApplicationCallPipeline.Plugins) {
            val call = call
            // The origin only answers requests addressed to its own authority.
            // This is the server half of the D22 launch-cookie binding: a request
            // whose Host names another authority (a DNS-rebinding style request)
            // could otherwise be handed a Set-Cookie a user agent stores for that
            // other authority. Refuse it before any credential is considered.
            if (!isOwnAuthority(call)) {
                unauthorizedRequests.incrementAndGet()
                respondJson(call, HttpStatusCode.Forbidden, FORBIDDEN_AUTHORITY_BODY)
                finish()
                return@intercept
            }
            if (!isAuthorized(call)) {
                unauthorizedRequests.incrementAndGet()
                respondUnauthorized(call)
                finish()
                return@intercept
            }
            if (isChannelUpgrade(call) && channelSlot.get() != null) {
                channelsRejected.incrementAndGet()
                respondJson(call, HttpStatusCode.Conflict, """{"error":"channel_in_use"}""")
                finish()
            }
        }
        app.routing {
            webSocket(LoopbackConfiguration.CHANNEL_PATH) { serveChannel(this) }
            // `/v1/http` is the Worker's only egress path. It is a proxy route,
            // not an asset route: the upstream URL comes from the request header
            // and the decision from the injected egress policy.
            route(EGRESS_PATH) { handle { serveHttpEgress(call) } }
            route("$EGRESS_PATH/{tail...}") { handle { serveHttpEgress(call) } }
            // M1: the model edge. The Worker's `DEEPSEEK_BASE_URL` points at this
            // origin, so these are proxy routes, not assets: the target comes from
            // the configured endpoint and the credential from the host provider.
            // The route table is the endpoint's own ModelProtocolPaths set.
            modelProxy?.let { proxy ->
                for (protocolRoute in proxy.routes()) {
                    route(protocolRoute.loopbackPath) { handle { proxy.serve(call, protocolRoute) } }
                    if (protocolRoute.includesDescendants) {
                        route("${protocolRoute.loopbackPath}/{tail...}") {
                            handle { proxy.serve(call, protocolRoute) }
                        }
                    }
                }
            }
            // D22: a page request authenticated by `?token=` is answered with the
            // cookie exchange instead of the page, so the token does not stay in
            // the address bar. A page request authenticated by the cookie (or a
            // Bearer header) is served normally.
            get("/") {
                if (!serveLaunchExchange(call)) serveAsset(call, launchPage = true)
            }
            get("/index.html") {
                if (!serveLaunchExchange(call)) serveAsset(call, launchPage = true)
            }
            get("/{tail...}") { serveAsset(call, launchPage = false) }
            route("{tail...}") {
                handle {
                    if (call.request.httpMethod == HttpMethod.Get) {
                        respondNotFound(call)
                    } else {
                        respondJson(call, HttpStatusCode.MethodNotAllowed, """{"error":"method_not_allowed"}""")
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- gate

    /**
     * The token gate.
     *
     * Three credential spellings of the same per-start token, each one only
     * where its carrier can exist:
     *
     *  * `Authorization: Bearer <token>` — every path, the pre-D22 rule;
     *  * `?token=` — the launch page, because `boot.js` reads its launch token
     *    from its own query string; `allowQueryTokenOnChannel` widens that to the
     *    `/channel` upgrade, which a browser `WebSocket` cannot give a header;
     *  * the D22 launch cookie ([LaunchCookie]) — page-relative requests of a
     *    browser that went through the launch exchange. The cookie is only
     *    honored when the request's `Host` is this origin's own authority (see
     *    the interceptor), and it is `HttpOnly; SameSite=Strict` so page script
     *    cannot read it and another site cannot send it.
     */
    private fun isAuthorized(call: ApplicationCall): Boolean {
        val candidates = ArrayList<String>(3)
        bearerToken(call.request.headers[HttpHeaders.Authorization])?.let(candidates::add)
        if (isLaunchPage(call) || (configuration.allowQueryTokenOnChannel && isChannelUpgrade(call))) {
            call.request.queryParameters["token"]?.let(candidates::add)
        }
        LaunchCookie.value(call.request.headers[HttpHeaders.Cookie])?.let(candidates::add)
        return candidates.any { candidate -> LoopbackToken.matches(candidate, token) }
    }

    /**
     * True when the request is addressed to this origin's own `host:port`.
     *
     * Compared against the port `start()` actually bound, not against the
     * configured one (which is 0 in production). A request with no `Host` is
     * refused: HTTP/1.1 requires it, and the loopback origin has exactly one
     * authority.
     */
    private fun isOwnAuthority(call: ApplicationCall): Boolean {
        val host = call.request.headers[HttpHeaders.Host]?.trim() ?: return false
        return host.equals(authority(), ignoreCase = true)
    }

    private fun isLaunchPage(call: ApplicationCall): Boolean {
        if (call.request.httpMethod != HttpMethod.Get) return false
        val path = call.request.path()
        return path == "/" || path == "/index.html"
    }

    private fun isChannelUpgrade(call: ApplicationCall): Boolean {
        if (call.request.path() != LoopbackConfiguration.CHANNEL_PATH) return false
        return call.request.headers[HttpHeaders.Upgrade]?.equals("websocket", ignoreCase = true) == true
    }

    private fun bearerToken(header: String?): String? {
        if (header == null) return null
        val trimmed = header.trim()
        if (trimmed.length <= BEARER_PREFIX.length) return null
        if (!trimmed.regionMatches(0, BEARER_PREFIX, 0, BEARER_PREFIX.length, ignoreCase = true)) return null
        return trimmed.substring(BEARER_PREFIX.length).trim().ifEmpty { null }
    }

    // ------------------------------------------------------------ D22 launch

    /**
     * Answers the D22 launch exchange, or returns false so the page is served.
     *
     * Trigger: a launch-page `GET` whose `?token=` is the per-start token (the
     * gate already proved that). The reply is `303 Location: /` plus the
     * [LaunchCookie] `Set-Cookie`, so a browser reaches the page with the token
     * only in its cookie jar. The 303 is deliberately token-free: the token is
     * not repeated in a header a page could read, and no request line is logged.
     *
     * A pinned token that cannot be a cookie value ([LaunchCookie.isSafeValue])
     * keeps the pre-D22 200 response instead of emitting a corrupt header; the
     * App's tokens are hex, so this only protects an exotic test deployment.
     */
    private suspend fun serveLaunchExchange(call: ApplicationCall): Boolean {
        val queryToken = call.request.queryParameters["token"] ?: return false
        if (!LoopbackToken.matches(queryToken, token)) return false
        if (!LaunchCookie.isSafeValue(token)) return false
        call.response.headers.append(HttpHeaders.CacheControl, NO_STORE)
        call.response.headers.append(HttpHeaders.Location, "/")
        call.response.headers.append(HttpHeaders.SetCookie, LaunchCookie.headerValue(token))
        call.respond(HttpStatusCode.SeeOther)
        return true
    }

    // ------------------------------------------------------------- statics

    /**
     * Serves one `/v1/http` exchange.
     *
     * The route is a proxy: the loopback request supplies the loopback method and
     * body, the two `X-PDSH-*` headers supply the upstream target and method, and
     * [httpEgress] decides whether the request may leave. A missing target header
     * is a transport-level 400; a policy refusal is the egress's response (403,
     * `X-PDSH-Proxy-Error`) and never reaches this class as an exception.
     */
    private suspend fun serveHttpEgress(call: ApplicationCall) {
        val egress = httpEgress
        if (egress == null) {
            respondJson(
                call,
                HttpStatusCode.ServiceUnavailable,
                """{"error":{"code":"unavailable","message":"host HTTP egress is disabled"}}""",
            )
            return
        }
        val method = call.request.httpMethod.value.uppercase()
        if (method !in EGRESS_METHODS) {
            respondJson(
                call,
                HttpStatusCode.MethodNotAllowed,
                """{"error":{"code":"method_not_allowed","message":"/v1/http accepts GET, HEAD and POST"}}""",
            )
            return
        }
        val target = call.request.headers[TARGET_URL_HEADER]?.trim()
        if (target.isNullOrEmpty()) {
            respondJson(
                call,
                HttpStatusCode.BadRequest,
                """{"error":{"code":"bad_request","message":"missing or invalid X-PDSH-Target-URL"}}""",
            )
            return
        }
        val body = if (method == HttpMethod.Head.value) ByteArray(0) else readEgressBody(call)
        if (body == null) {
            respondJson(
                call,
                HttpStatusCode.PayloadTooLarge,
                """{"error":{"code":"payload_too_large","message":"the egress request body is too large"}}""",
            )
            return
        }
        val headers = LinkedHashMap<String, String>()
        for ((name, values) in call.request.headers.entries()) {
            headers[name.lowercase()] = values.joinToString(", ")
        }
        val targetMethod = call.request.headers[TARGET_METHOD_HEADER]?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: method
        val response = try {
            egress.handle(
                LoopbackHttpRequest(
                    method = method,
                    targetUrl = target,
                    targetMethod = targetMethod,
                    headers = headers,
                    body = body,
                ),
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // The exception text can name a host, a path or a credential; the
            // Worker gets a stable code and this origin logs nothing here.
            respondJson(
                call,
                HttpStatusCode.BadGateway,
                """{"error":{"code":"egress_failed","message":"the host egress failed"}}""",
            )
            return
        }
        val status = HttpStatusCode.fromValue(response.status)
        for ((name, value) in response.headers) {
            if (name.lowercase() in EGRESS_DROPPED_RESPONSE_HEADERS) continue
            call.response.headers.append(name, value)
        }
        call.response.headers.append(HttpHeaders.CacheControl, NO_STORE)
        val contentType = response.headers.entries
            .firstOrNull { it.key.equals(HttpHeaders.ContentType, ignoreCase = true) }
            ?.value
            ?: EGRESS_DEFAULT_CONTENT_TYPE
        val parsed = runCatching { ContentType.parse(contentType) }.getOrNull()
            ?: ContentType.Application.OctetStream
        call.respondBytes(response.body, parsed, status)
    }

    /**
     * Reads at most [MAX_EGRESS_BODY_BYTES] of the loopback request body.
     *
     * Returns `null` past the bound instead of buffering an unbounded body: a
     * loopback caller that streams forever must get a 413, not the App's heap.
     */
    private suspend fun readEgressBody(call: ApplicationCall): ByteArray? {
        val channel = call.receiveChannel()
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(EGRESS_READ_CHUNK)
        while (true) {
            val read = channel.readAvailable(buffer, 0, buffer.size)
            if (read < 0) break
            if (read == 0) continue
            if (out.size().toLong() + read > MAX_EGRESS_BODY_BYTES) return null
            out.write(buffer, 0, read)
        }
        return out.toByteArray()
    }

    private suspend fun serveAsset(call: ApplicationCall, launchPage: Boolean) {
        val file = assets.resolve(call.request.path())
        if (file == null) {
            respondNotFound(call)
            return
        }
        call.response.headers.append(HttpHeaders.CacheControl, NO_STORE)
        if (launchPage && configuration.crossOriginIsolation) {
            call.response.headers.append(COOP, "same-origin")
            call.response.headers.append(COEP, "require-corp")
        }
        // D22 parity with the iOS page response
        // (`Sources/PhoneDSHLoopback/LoopbackServer.swift:439-445`): an HTML page
        // seeds the launch cookie too, so a Bearer/cookie-authenticated page load
        // leaves its subresources a credential. The value is the same per-start
        // token; `HttpOnly` keeps it out of page script.
        if (launchPage && LaunchCookie.isSafeValue(token) && isHtml(file)) {
            call.response.headers.append(HttpHeaders.SetCookie, LaunchCookie.headerValue(token))
        }
        // Explicit content type: Ktor's defaultForFile does not know .wasm/.mjs/
        // .map, and a wrong type breaks WebAssembly streaming compilation.
        call.respond(LocalFileContent(file.toFile(), ContentType.parse(assets.contentType(file))))
    }

    private fun isHtml(file: java.nio.file.Path): Boolean =
        assets.contentType(file).startsWith(HTML_CONTENT_TYPE_PREFIX)

    // ------------------------------------------------------------- channel

    /**
     * Runs one accepted channel.
     *
     * One active channel at a time: a second upgrade is answered with 409 by
     * the gate (or, on the losing side of a race, closed 1013 here).
     */
    private suspend fun serveChannel(session: DefaultWebSocketServerSession) {
        val connection = KtorConnection(this, session, "channel-${connectionIds.incrementAndGet()}")
        if (!channelSlot.compareAndSet(null, connection)) {
            channelsRejected.incrementAndGet()
            session.close(CloseReason(CloseReason.Codes.TRY_AGAIN_LATER, CHANNEL_BUSY_REASON))
            return
        }
        channelsAccepted.incrementAndGet()
        activeChannels.incrementAndGet()
        liveSessions.add(session)
        var cause = ChannelCloseCause.TRANSPORT_LOST
        try {
            if (!callHandler(connection) { handler.onOpen(connection) }) {
                cause = ChannelCloseCause.HANDLER_FAILED
            } else {
                cause = pumpInbound(connection)
            }
        } catch (cancelled: CancellationException) {
            cause = if (stopping.get()) ChannelCloseCause.SERVER_STOPPED else ChannelCloseCause.TRANSPORT_LOST
            throw cancelled
        } catch (failure: Throwable) {
            // A failure outside the handler is the transport dying under us.
            cause = if (stopping.get()) ChannelCloseCause.SERVER_STOPPED else ChannelCloseCause.TRANSPORT_LOST
        } finally {
            liveSessions.remove(session)
            activeChannels.decrementAndGet()
            channelSlot.compareAndSet(connection, null)
            withContext(NonCancellable) {
                runCatching { handler.onClosed(connection, cause) }
            }
        }
    }

    /**
     * Reads frames one at a time and hands each payload to the handler.
     *
     * The loop does not read frame N+1 before the handler returned for frame N.
     * That is the whole backpressure mechanism on this direction: a slow
     * consumer stops reading the socket, the TCP window closes and the peer's
     * `send` suspends. No queue of payloads exists anywhere in this class.
     */
    private suspend fun pumpInbound(connection: KtorConnection): ChannelCloseCause {
        for (frame in connection.session.incoming) {
            when (frame) {
                is Frame.Binary -> {
                    framesIn.incrementAndGet()
                    bytesIn.addAndGet(frame.data.size.toLong())
                    val inFlight = inFlightFrames.incrementAndGet()
                    maxInFlightFrames.accumulateAndGet(inFlight) { current, next -> maxOf(current, next) }
                    val delivered = try {
                        callHandler(connection) { handler.onBinary(connection, frame.data) }
                    } finally {
                        inFlightFrames.decrementAndGet()
                    }
                    if (!delivered) return ChannelCloseCause.HANDLER_FAILED
                }
                is Frame.Text -> {
                    connection.session.close(CloseReason(CloseReason.Codes.CANNOT_ACCEPT, BINARY_ONLY_REASON))
                    return ChannelCloseCause.UNSUPPORTED_FRAME
                }
                // Control frames are answered in place and never reach the handler.
                is Frame.Ping -> connection.session.send(Frame.Pong(frame.data))
                else -> Unit
            }
        }
        return classifyEnding(connection.session)
    }

    /**
     * Runs one handler callback and reports whether it returned normally.
     *
     * A cancellation is not a handler failure and is rethrown so `stop()` can
     * unwind; anything else closes the channel with 1011 and is reported as
     * [ChannelCloseCause.HANDLER_FAILED].
     */
    private suspend fun callHandler(connection: KtorConnection, block: suspend () -> Unit): Boolean = try {
        block()
        true
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (failure: Throwable) {
        runCatching {
            connection.session.close(CloseReason(CloseReason.Codes.INTERNAL_ERROR, HANDLER_FAILED_REASON))
        }
        false
    }

    /**
     * Distinguishes a peer close frame from a dead transport.
     *
     * The close frame is the "half-close" this transport offers: the peer stops
     * sending data and says so, and the handler is told exactly once.
     */
    private suspend fun classifyEnding(session: DefaultWebSocketSession): ChannelCloseCause {
        if (stopping.get()) return ChannelCloseCause.SERVER_STOPPED
        val reason = withTimeoutOrNull(CLOSE_REASON_WAIT_MILLIS) { session.closeReason.await() }
            ?: return ChannelCloseCause.TRANSPORT_LOST
        return when (reason.knownReason) {
            null, CloseReason.Codes.CLOSED_ABNORMALLY -> ChannelCloseCause.TRANSPORT_LOST
            else -> ChannelCloseCause.CLIENT_CLOSED
        }
    }

    fun recordOutbound(size: Int) {
        framesOut.incrementAndGet()
        bytesOut.addAndGet(size.toLong())
    }

    // ----------------------------------------------------------- responses

    private suspend fun respondUnauthorized(call: ApplicationCall) {
        call.response.headers.append(HttpHeaders.CacheControl, NO_STORE)
        call.response.headers.append(HttpHeaders.WWWAuthenticate, WWW_AUTHENTICATE)
        call.respondBytes(UNAUTHORIZED_BODY, JSON, HttpStatusCode.Unauthorized)
    }

    private suspend fun respondNotFound(call: ApplicationCall) {
        respondJson(call, HttpStatusCode.NotFound, """{"error":"not_found"}""")
    }

    private suspend fun respondJson(call: ApplicationCall, status: HttpStatusCode, body: String) {
        call.response.headers.append(HttpHeaders.CacheControl, NO_STORE)
        call.respondBytes(body.toByteArray(Charsets.UTF_8), JSON, status)
    }

    companion object {
        private const val NO_STORE = "no-store"
        private const val COOP = "Cross-Origin-Opener-Policy"
        private const val COEP = "Cross-Origin-Embedder-Policy"
        private const val BEARER_PREFIX = "Bearer "
        private const val WWW_AUTHENTICATE = """Bearer realm="pdsh-loopback""""
        private const val FORBIDDEN_AUTHORITY_BODY = """{"error":"authority_mismatch"}"""
        private const val HTML_CONTENT_TYPE_PREFIX = "text/html"
        private const val CHANNEL_BUSY_REASON = "the loopback channel is already open"
        private const val BINARY_ONLY_REASON = "the ordered channel is binary only"
        private const val HANDLER_FAILED_REASON = "the channel handler failed"
        private const val CLOSE_REASON_WAIT_MILLIS = 1_000L

        /** The one egress route of `spec/v1/README.md` §1. */
        const val EGRESS_PATH: String = "/v1/http"

        /** The absolute upstream URL of one proxy request. */
        const val TARGET_URL_HEADER: String = "x-pdsh-target-url"

        /** The upstream method of one proxy request. */
        const val TARGET_METHOD_HEADER: String = "x-pdsh-target-method"

        /** Methods the Worker's curl/git egress may ask this route to carry. */
        val EGRESS_METHODS: Set<String> = setOf("GET", "HEAD", "POST")

        /** Bound on one buffered request body (the Worker's own limit is 4 MiB). */
        const val MAX_EGRESS_BODY_BYTES: Long = 16L * 1024 * 1024
        private const val EGRESS_READ_CHUNK = 8192

        /** Headers the gateway already filtered; a second copy must not leak. */
        val EGRESS_DROPPED_RESPONSE_HEADERS: Set<String> = setOf(
            "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
            "te", "trailer", "transfer-encoding", "upgrade", "content-length",
        )
        private const val EGRESS_DEFAULT_CONTENT_TYPE = "application/octet-stream"

        private val PING_PERIOD = 15.seconds
        private val PING_TIMEOUT = 30.seconds
        private val JSON: ContentType = ContentType.Application.Json.withCharset(Charsets.UTF_8)
        private val UNAUTHORIZED_BODY = """{"error":"unauthorized"}""".toByteArray(Charsets.UTF_8)
    }
}

/**
 * One connection as the handler sees it.
 *
 * `sendBinary` sends one whole message and then flushes. The flush is not
 * cosmetic: Ktor 3.2.3's `DefaultWebSocketSession.send` only queues the frame
 * and returned immediately for a peer that reads nothing (measured: 64 MiB in
 * 5 ms, i.e. no write backpressure at all), while `flush` suspends until the
 * engine's write channel reached the socket. With it, a peer that stops
 * reading stalls the producer at the kernel buffer (~2 MiB on the dev host)
 * instead of growing the heap.
 */
private class KtorConnection(
    private val service: LoopbackService,
    val session: DefaultWebSocketServerSession,
    override val id: String,
) : LoopbackConnection {
    override suspend fun sendBinary(payload: ByteArray) {
        service.recordOutbound(payload.size)
        session.send(Frame.Binary(true, payload))
        session.flush()
    }

    override suspend fun close(code: Short, reason: String) {
        session.close(CloseReason(code, reason))
    }
}
