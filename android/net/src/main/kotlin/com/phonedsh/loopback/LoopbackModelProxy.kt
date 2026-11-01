// phone-dsh — :loopback / com.phonedsh.loopback: the host-edge model proxy.
// SPDX-License-Identifier: MIT
//
// The Worker points DEEPSEEK_BASE_URL at this origin, so its model client sends
// `POST <origin>/v1/messages` to the host instead of contacting the real
// provider. This file forwards that request to the configured upstream origin
// and injects the host credential there, so the Worker never holds the key
// (`spec/v1/gateway-security.md` §2).
//
// The security rules it ports from `GatewaySession`:
//   * every caller credential header is dropped before the host credential is
//     applied last, so a Worker placeholder or forged value cannot reach the
//     upstream;
//   * the upstream is contacted only after the credential resolved: a provider
//     failure is a 502 `credential_unavailable` with no socket opened;
//   * redirects are never followed; the 3xx status is handed back without a
//     `Location`, so a Worker cannot re-issue the hop outside this edge;
//   * a non-2xx upstream body is replaced by a stable JSON code, and response
//     headers go through the gateway sanitizer with the injected values as the
//     redaction set;
//   * a 2xx body is streamed (SSE must arrive as it is produced), and a chunk
//     that would echo an injected credential aborts the stream instead of
//     forwarding it;
//   * nothing here logs: no line can name a URL, a header or a key.

package com.phonedsh.loopback

import com.phonedsh.gateway.CredentialScope
import com.phonedsh.gateway.DenylistRequestHeaderSanitizer
import com.phonedsh.gateway.DenylistResponseHeaderSanitizer
import com.phonedsh.gateway.GatewayCredential
import com.phonedsh.gateway.GatewayCredentialProvider
import com.phonedsh.gateway.GatewayPaths
import com.phonedsh.gateway.GatewayUrls
import com.phonedsh.gateway.ModelEndpoint
import com.phonedsh.gateway.ModelProtocolRoute
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.withCharset
import io.ktor.server.application.ApplicationCall
import io.ktor.server.request.httpMethod
import io.ktor.server.request.path
import io.ktor.server.request.queryString
import io.ktor.server.request.receiveChannel
import io.ktor.server.response.respondBytes
import io.ktor.server.response.respondBytesWriter
import io.ktor.utils.io.readAvailable
import io.ktor.utils.io.writeFully
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The host's model-protocol edge: forwards the Worker's model requests to
 * [endpoint] and injects the credential resolved for the upstream URL scope.
 *
 * Construct one per start and hand it to [LoopbackServer]. [endpoint] is parsed
 * from the same base URL the App keeps for the real provider, so the injected
 * key can only go to that exact scheme, host, port and protocol path.
 *
 * Timeouts exist so one upstream cannot pin a loopback handler forever:
 * [connectTimeoutMillis] bounds connection setup, [readTimeoutMillis] bounds one
 * read of the response stream, and [maxDurationMillis] bounds the whole stream.
 */
class LoopbackModelProxy(
    val endpoint: ModelEndpoint,
    private val credentialProvider: GatewayCredentialProvider,
    private val connectTimeoutMillis: Int = DEFAULT_CONNECT_TIMEOUT_MILLIS,
    private val readTimeoutMillis: Int = DEFAULT_READ_TIMEOUT_MILLIS,
    private val maxDurationMillis: Long = DEFAULT_MAX_DURATION_MILLIS,
    private val maxRequestBodyBytes: Long = DEFAULT_MAX_REQUEST_BODY_BYTES,
) {
    /** Convenience form for a host that only has the configured base URL string. */
    constructor(
        baseUrl: String,
        credentialProvider: GatewayCredentialProvider,
        connectTimeoutMillis: Int = DEFAULT_CONNECT_TIMEOUT_MILLIS,
        readTimeoutMillis: Int = DEFAULT_READ_TIMEOUT_MILLIS,
        maxDurationMillis: Long = DEFAULT_MAX_DURATION_MILLIS,
        maxRequestBodyBytes: Long = DEFAULT_MAX_REQUEST_BODY_BYTES,
    ) : this(
        endpoint = ModelEndpoint.parse(baseUrl)
            ?: throw IllegalArgumentException("model base URL must be an absolute http(s) URL with a host"),
        credentialProvider = credentialProvider,
        connectTimeoutMillis = connectTimeoutMillis,
        readTimeoutMillis = readTimeoutMillis,
        maxDurationMillis = maxDurationMillis,
        maxRequestBodyBytes = maxRequestBodyBytes,
    )

    init {
        require(connectTimeoutMillis > 0) { "connectTimeoutMillis must be positive" }
        require(readTimeoutMillis > 0) { "readTimeoutMillis must be positive" }
        require(maxDurationMillis > 0) { "maxDurationMillis must be positive" }
        require(maxRequestBodyBytes > 0) { "maxRequestBodyBytes must be positive" }
    }

    private val requestHeaders = DenylistRequestHeaderSanitizer()
    private val responseHeaders = DenylistResponseHeaderSanitizer()

    /**
     * The routes this proxy mounts on the loopback origin.
     *
     * The list is the configured endpoint's own protocol-path set (see
     * [ModelEndpoint.protocolRoutes]), not a second table, so a mounted route is
     * always one the credential provider admits.
     */
    internal fun routes(): List<ModelProtocolRoute> = endpoint.protocolRoutes()

    /**
     * Serves one model-protocol exchange.
     *
     * [route] is the mounted route the request matched; the exact and descendant
     * forms both arrive here. The caller header map is sanitized by the gateway
     * request rule, then the host credential is applied last. The upstream
     * connection is opened only after that, so a denial has no upstream contact.
     */
    internal suspend fun serve(call: ApplicationCall, route: ModelProtocolRoute) {
        val method = call.request.httpMethod.value.uppercase()
        if (method !in METHODS) {
            call.response.headers.append(HttpHeaders.Allow, ALLOWED_METHODS)
            respondFailure(call, 405, "method_not_allowed", "bad_request", "the model edge accepts GET and POST")
            return
        }
        val upstreamPath = upstreamPathFor(call, route)
        if (upstreamPath == null) {
            respondFailure(call, 400, "invalid_request", "bad_request", "the model path is not a protocol route")
            return
        }
        val body = if (method == POST_METHOD) readRequestBody(call) else ByteArray(0)
        if (body == null) {
            respondFailure(call, 413, "payload_too_large", "payload_too_large", "the model request body is too large")
            return
        }
        val targetText = endpoint.origin + upstreamPath
        val target = GatewayUrls.parse(targetText)
        if (target == null) {
            respondFailure(call, 400, "invalid_request", "bad_request", "the model path is not an http(s) URL")
            return
        }
        val scope = CredentialScope.of(target)
        val credential = try {
            credentialProvider.resolve(scope)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // The provider text is not forwarded: it can name the store or the key.
            respondFailure(
                call,
                502,
                "credential_unavailable",
                "credential_unavailable",
                "no credential is configured for the upstream host",
            )
            return
        }
        val outbound = LinkedHashMap(requestHeaders.sanitize(callerHeaders(call)).headers)
        // A Worker credential, whatever its spelling, never reaches the origin.
        for (name in WORKER_CREDENTIAL_HEADERS) outbound.remove(name)
        credential.applyTo(outbound)
        // The body is streamed back verbatim, so the upstream must not compress it.
        outbound["accept-encoding"] = "identity"

        val exchange = try {
            withContext(Dispatchers.IO) { openUpstream(method, targetText + querySuffix(call), outbound, body) }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            respondFailure(call, 502, "transport_failure", "upstream", "the upstream request failed")
            return
        }
        try {
            when {
                exchange.status in REDIRECT_STATUSES -> respondFailure(
                    call,
                    exchange.status,
                    "upstream_redirect_refused",
                    "upstream",
                    "the upstream redirect was refused",
                )
                exchange.status !in 200..299 -> respondFailure(
                    call,
                    exchange.status,
                    "upstream_status",
                    "upstream",
                    "the upstream answered with an error",
                )
                else -> stream(call, exchange, credential)
            }
        } finally {
            exchange.close()
        }
    }

    // --------------------------------------------------------------- upstream

    /**
     * Issues exactly one hop. Redirects and the platform's judgement are off;
     * [serve] owns what happens to a 3xx.
     */
    private fun openUpstream(
        method: String,
        url: String,
        headers: Map<String, String>,
        body: ByteArray,
    ): Exchange {
        val connection = try {
            URI(url).toURL().openConnection() as HttpURLConnection
        } catch (failure: Exception) {
            throw IOException("the upstream URL could not be opened")
        }
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = connectTimeoutMillis
            connection.readTimeout = readTimeoutMillis
            connection.requestMethod = method
            for ((name, value) in headers) {
                if (name.equals(HttpHeaders.Host, ignoreCase = true)) continue
                runCatching { connection.setRequestProperty(name, value) }
            }
            if (method == POST_METHOD) {
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(body.size)
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            val headersSeen = LinkedHashMap<String, String>()
            for ((rawName, values) in connection.headerFields) {
                if (rawName == null) continue
                val joined = values.filterNotNull().joinToString(", ")
                if (joined.isNotEmpty()) headersSeen[rawName.lowercase()] = joined
            }
            return Exchange(connection, status, headersSeen)
        } catch (failure: Throwable) {
            runCatching { connection.disconnect() }
            throw failure
        }
    }

    /**
     * Streams a 2xx body to the Worker as it arrives.
     *
     * Every read is flushed, which is what makes SSE usable: the first event
     * leaves the phone when the upstream produced it, not when the last one did.
     * The read happens on [Dispatchers.IO] so a blocking socket read never pins
     * a Ktor engine thread; the write and flush stay on the call's context so
     * Ktor's own backpressure applies. [SecretStreamGuard] refuses a chunk that
     * would echo an injected value.
     */
    private suspend fun stream(call: ApplicationCall, exchange: Exchange, credential: GatewayCredential) {
        val input = try {
            withContext(Dispatchers.IO) { exchange.connection.inputStream }
        } catch (_: Exception) {
            respondFailure(call, 502, "transport_failure", "upstream", "the upstream response could not be read")
            return
        }
        val secrets = credential.secretValues()
        val filtered = LinkedHashMap<String, String>()
        for ((name, value) in responseHeaders.sanitize(exchange.headers, secrets)) {
            // The value rule redacts values; a header *name* could also echo a key
            // (a key is a valid HTTP token), so names are refused the same way.
            if (carriesSecret(name, secrets) || carriesSecret(value, secrets)) continue
            filtered[name] = value
        }
        // A redirect body is never followed; the same holds for a 2xx Location.
        filtered.remove(HttpHeaders.Location.lowercase())
        val contentType = filtered.remove(HttpHeaders.ContentType.lowercase())
            ?.let { runCatching { ContentType.parse(it) }.getOrNull() }
            ?: ContentType.Application.OctetStream
        for ((name, value) in filtered) call.response.headers.append(name, value)
        val guard = SecretStreamGuard(secrets)
        call.respondBytesWriter(
            contentType = contentType,
            status = HttpStatusCode.fromValue(exchange.status),
        ) {
            val output = this
            input.use { stream ->
                val buffer = ByteArray(STREAM_CHUNK_BYTES)
                val deadline = System.nanoTime() + maxDurationMillis * 1_000_000L
                while (true) {
                    if (System.nanoTime() > deadline) {
                        throw IOException("the model stream exceeded its duration bound")
                    }
                    val read = withContext(Dispatchers.IO) { stream.read(buffer) }
                    if (read < 0) break
                    if (read == 0) continue
                    guard.check(buffer, read)
                    output.writeFully(buffer, 0, read)
                    output.flush()
                }
            }
        }
    }

    // ---------------------------------------------------------------- request

    /**
     * Reads at most [maxRequestBodyBytes] of the Worker's request body.
     *
     * Returns `null` past the bound instead of buffering an unbounded body: the
     * upstream call needs its length before it starts, and the App's heap is not
     * the place to discover that the Worker streamed forever.
     */
    private suspend fun readRequestBody(call: ApplicationCall): ByteArray? {
        val channel = call.receiveChannel()
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(REQUEST_CHUNK_BYTES)
        while (true) {
            val read = channel.readAvailable(buffer, 0, buffer.size)
            if (read < 0) break
            if (read == 0) continue
            if (out.size().toLong() + read > maxRequestBodyBytes) return null
            out.write(buffer, 0, read)
        }
        return out.toByteArray()
    }

    /** Every caller header, lowercased and joined; the gateway rule decides what survives. */
    private fun callerHeaders(call: ApplicationCall): Map<String, String> {
        val headers = LinkedHashMap<String, String>()
        for ((name, values) in call.request.headers.entries()) {
            headers[name.lowercase()] = values.joinToString(", ")
        }
        return headers
    }

    /**
     * The upstream path of [call], or null when the request tried to leave its
     * route (`..`, encoded separators, another sibling).
     */
    private fun upstreamPathFor(call: ApplicationCall, route: ModelProtocolRoute): String? {
        val loopbackPath = call.request.path()
        val descendant = route.includesDescendants && loopbackPath.startsWith(route.loopbackPath + "/")
        if (loopbackPath != route.loopbackPath && !descendant) return null
        val suffix = loopbackPath.removePrefix(route.loopbackPath)
        if (suffix.contains('\\')) return null
        val lowered = suffix.lowercase()
        if (lowered.contains("%2e") || lowered.contains("%2f") || lowered.contains("%5c")) return null
        val base = GatewayPaths.normalize(route.upstreamPath)
        val upstream = GatewayPaths.normalize(base + suffix)
        if (upstream != base && !upstream.startsWith("$base/")) return null
        return upstream
    }

    private fun querySuffix(call: ApplicationCall): String {
        val query = call.request.queryString()
        return if (query.isEmpty()) "" else "?$query"
    }

    // --------------------------------------------------------------- responses

    /**
     * One stable error surface for the model edge: a lower-snake code in the body
     * and `x-pdsh-proxy-error`, never an upstream byte or exception text.
     */
    private suspend fun respondFailure(
        call: ApplicationCall,
        status: Int,
        code: String,
        proxyError: String,
        message: String,
    ) {
        call.response.headers.append(HttpHeaders.CacheControl, NO_STORE)
        call.response.headers.append(PROXY_ERROR_HEADER, proxyError)
        call.response.headers.append(DENY_REASON_HEADER, code)
        val body = """{"error":{"code":"$code","message":"$message"}}"""
        call.respondBytes(body.toByteArray(Charsets.UTF_8), JSON, HttpStatusCode.fromValue(status))
    }

    private class Exchange(
        val connection: HttpURLConnection,
        val status: Int,
        val headers: Map<String, String>,
    ) : AutoCloseable {
        override fun close() {
            runCatching { connection.disconnect() }
        }
    }

    /**
     * Refuses a stream that would echo an injected value.
     *
     * The tail of the previous chunk is kept for `max(secret).size - 1` bytes, so
     * a key split across two socket reads is still found. Aborting is the only
     * safe answer: the bytes have not been written yet, and a redaction pass over
     * an SSE body would corrupt the event framing.
     */
    private class SecretStreamGuard(secrets: List<String>) {
        private val needles = secrets.map { it.toByteArray(Charsets.UTF_8) }.filter { it.isNotEmpty() }
        private val window = (needles.maxOfOrNull { it.size } ?: 0) - 1
        private var tail: ByteArray = ByteArray(0)

        fun check(chunk: ByteArray, length: Int) {
            if (needles.isEmpty()) return
            val piece = chunk.copyOf(length)
            val combined = if (tail.isEmpty()) piece else tail + piece
            for (needle in needles) {
                if (indexOf(combined, needle) >= 0) {
                    throw IOException("the upstream response would echo an injected credential")
                }
            }
            tail = when {
                window <= 0 -> ByteArray(0)
                combined.size <= window -> combined
                else -> combined.copyOfRange(combined.size - window, combined.size)
            }
        }

        private fun indexOf(haystack: ByteArray, needle: ByteArray): Int {
            if (needle.isEmpty() || haystack.size < needle.size) return -1
            outer@ for (start in 0..haystack.size - needle.size) {
                for (offset in needle.indices) {
                    if (haystack[start + offset] != needle[offset]) continue@outer
                }
                return start
            }
            return -1
        }
    }

    private fun carriesSecret(text: String, secrets: List<String>): Boolean =
        secrets.any { it.isNotEmpty() && text.contains(it) }

    companion object {
        const val DEFAULT_CONNECT_TIMEOUT_MILLIS: Int = 10_000
        const val DEFAULT_READ_TIMEOUT_MILLIS: Int = 120_000
        const val DEFAULT_MAX_DURATION_MILLIS: Long = 10L * 60L * 1_000L

        /** The model request body may carry inline image data; the Worker's own cap is larger. */
        const val DEFAULT_MAX_REQUEST_BODY_BYTES: Long = 64L * 1024L * 1024L

        /** Methods a model-protocol client uses; both are proxied. */
        val METHODS: Set<String> = setOf("GET", "POST")
        private const val ALLOWED_METHODS = "GET, POST"
        private const val POST_METHOD = "POST"

        /** Statuses that mean "look somewhere else": never followed here. */
        val REDIRECT_STATUSES: Set<Int> = setOf(301, 302, 303, 307, 308)

        /** Credential spelling a Worker might supply; all are dropped before injection. */
        val WORKER_CREDENTIAL_HEADERS: Set<String> = setOf(
            "authorization",
            "proxy-authorization",
            "x-pdsh-upstream-authorization",
            "x-api-key",
            "api-key",
            "x-dsh-auth-token",
        )

        const val PROXY_ERROR_HEADER: String = "x-pdsh-proxy-error"
        const val DENY_REASON_HEADER: String = "x-pdsh-deny-reason"
        private const val NO_STORE = "no-store"
        private val JSON: ContentType = ContentType.Application.Json.withCharset(Charsets.UTF_8)
        private const val STREAM_CHUNK_BYTES = 16 * 1024
        private const val REQUEST_CHUNK_BYTES = 8192
    }
}
