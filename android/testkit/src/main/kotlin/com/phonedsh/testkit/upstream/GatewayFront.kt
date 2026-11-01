// :testkit upstream — a real-socket transport and the `/v1/http` gateway front.
// SPDX-License-Identifier: MIT
//
// ---- what is real here ------------------------------------------------------
// [UrlConnectionGatewayTransport] issues the actual HTTP request the gateway
// decided to issue: it is the missing production transport, written in the test
// surface because no module in this lane owns one yet. The gateway itself
// (`com.phonedsh.gateway.GatewaySession`) is the REAL `:net` implementation —
// allow-list, credential injection, header strip, redirect scope, response
// redaction and the response log all run.
//
// [GatewayFrontServer] is the fixture that stands in for the app's `/v1/http`
// route (`spec/v1/README.md` §1: the Worker reaches upstreams only through the
// host origin). That route lives in `src/main` and is not implemented in this
// Android lane, so the front exists here, in the test surface, and is reported
// as such: a worker request arrives on loopback, is turned into a
// [GatewayRequest], and the real gateway decides whether and where it goes.
//
// ---- the grant ----------------------------------------------------------
// The upstream is admitted by one exact origin entry
// (`GatewayHostRule.parse("http://127.0.0.1:<port>")`), never by `*`. A
// different port is denied by the same policy, and the tests assert that.

package com.phonedsh.testkit.upstream

import com.phonedsh.gateway.GatewayDispatch
import com.phonedsh.gateway.GatewayFailureCode
import com.phonedsh.gateway.GatewayOutcome
import com.phonedsh.gateway.GatewayRequest
import com.phonedsh.gateway.GatewaySession
import com.phonedsh.gateway.GatewayTransport
import com.phonedsh.gateway.GatewayTransportException
import com.phonedsh.gateway.GatewayTransportRequest
import com.phonedsh.gateway.GatewayTransportResponse
import com.phonedsh.testkit.http.HttpRequest
import com.phonedsh.testkit.http.HttpResponse
import com.phonedsh.testkit.http.MiniHttpServer
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.nio.charset.StandardCharsets

/**
 * The real HTTP hop, over `HttpURLConnection`.
 *
 * It follows no redirects (the gateway owns redirect policy, `gateway-security.md`
 * §4) and it surfaces a transport failure as [GatewayTransportException] so the
 * gateway's `transport_failure` mapping is the one under test.
 */
class UrlConnectionGatewayTransport(
    private val connectTimeoutMillis: Int = 5_000,
    private val readTimeoutMillis: Int = 30_000,
) : GatewayTransport {
    override fun execute(request: GatewayTransportRequest): GatewayTransportResponse {
        val connection = try {
            URI(request.url).toURL().openConnection() as HttpURLConnection
        } catch (failure: Exception) {
            throw GatewayTransportException(failure.javaClass.simpleName)
        }
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = connectTimeoutMillis
            connection.readTimeout = readTimeoutMillis
            connection.requestMethod = request.method
            for ((name, value) in request.headers) {
                runCatching { connection.setRequestProperty(name, value) }
            }
            if (request.body.isNotEmpty()) {
                connection.doOutput = true
                connection.outputStream.use { it.write(request.body) }
            }
            val status = connection.responseCode
            val headers = LinkedHashMap<String, String>()
            for ((name, values) in connection.headerFields) {
                if (name == null) continue
                val joined = values.filterNotNull().joinToString(", ")
                if (joined.isNotEmpty()) headers[name.lowercase()] = joined
            }
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val body = stream?.use { it.readBytes() } ?: ByteArray(0)
            return GatewayTransportResponse(status = status, headers = headers, body = body)
        } catch (failure: IOException) {
            throw GatewayTransportException(failure.javaClass.simpleName)
        } finally {
            runCatching { connection.disconnect() }
        }
    }
}

/**
 * The `/v1/http` front: loopback HTTP in, the real gateway out.
 *
 * Every request is forwarded to `upstreamBaseUrl + path` (query included), so the
 * allow-list entry that admits it is the exact origin the upstream binds — the
 * front cannot widen or rewrite the grant.
 *
 * @param gateway the real `:net` session (allow-list + credential policy).
 * @param upstreamBaseUrl e.g. `http://127.0.0.1:41234`; must be allow-listed or
 *   every request is denied (which is the point of the negative test).
 */
class GatewayFrontServer(
    private val gateway: GatewaySession,
    private val upstreamBaseUrl: String,
) {
    private val server = MiniHttpServer(::forward, name = "gateway-front")
    private val lock = Any()
    private val outcomes = mutableListOf<GatewayOutcome>()

    /** The bound port; valid after [start]. */
    val port: Int get() = server.port

    /** `http://127.0.0.1:<port>`: the value a worker's `DEEPSEEK_BASE_URL` gets. */
    val baseUrl: String get() = server.baseUrl

    /** Every gateway outcome the front produced, in order. */
    val exchanges: List<GatewayOutcome> get() = synchronized(lock) { outcomes.toList() }

    fun start(): GatewayFrontServer {
        server.start()
        return this
    }

    fun stop() = server.stop()

    private fun forward(request: HttpRequest): HttpResponse {
        val target = upstreamBaseUrl + request.path
        val headers = LinkedHashMap<String, String>()
        for ((name, value) in request.headers) {
            // The front passes caller headers through; the gateway's own header
            // denylist decides what reaches the upstream (gateway-security.md §3).
            headers[name] = value
        }
        val outcome = gateway.exchange(
            GatewayRequest(
                method = request.method,
                url = target,
                headers = headers,
                body = request.body,
            ),
        )
        synchronized(lock) { outcomes += outcome }
        val failure = outcome.failure
        val status = outcome.responseStatus
        if (outcome.dispatch == GatewayDispatch.DENY || status == null) {
            // A pre-flight denial: no upstream contact, a stable structured cause.
            val code = failure?.code?.wire ?: GatewayFailureCode.HOST_NOT_ALLOWED.wire
            return HttpResponse.json(
                status = failure?.code?.proxyStatus ?: GatewayFailureCode.HOST_NOT_ALLOWED.proxyStatus,
                text = """{"error":{"code":${quote(code)},""" +
                    """"message":"the gateway refused this egress"}}""",
            )
        }
        val contentType = outcome.responseHeaders["content-type"] ?: "application/octet-stream"
        return HttpResponse(
            status = status,
            headers = mapOf("content-type" to contentType),
            body = outcome.responseBody,
        )
    }

    private fun quote(text: String): String = buildString {
        append('"')
        for (character in text) {
            when (character) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                else -> append(character)
            }
        }
        append('"')
    }
}

/** UTF-8 bytes of [text], for request bodies built in tests. */
fun requestBody(text: String): ByteArray = text.toByteArray(StandardCharsets.UTF_8)
