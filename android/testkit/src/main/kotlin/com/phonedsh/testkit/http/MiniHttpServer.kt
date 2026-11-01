// :testkit http — a minimal HTTP/1.1 server for test surfaces (no framework, no release path).
// SPDX-License-Identifier: MIT
//
// ---- why this exists instead of Ktor --------------------------------------
// The scripted model upstream and the gateway front are TEST FIXTURES. They are
// deliberately built from `java.net.ServerSocket` and nothing else:
//
//   * `:testkit` is not published (`com.phonedsh.testkit` is a build-time
//     support module), and a fixture must not drag a server framework into the
//     dependency graph of the modules it is only there to exercise;
//   * `com.sun.net.httpserver` does not exist on Android, so a fixture that used
//     it would work in a JVM test and fail on the emulator — exactly the
//     difference this lane has to keep visible;
//   * the Swift reference mock (`Sources/PhoneDSHHarness/MockModelUpstream.swift`)
//     is a hand-written HTTP/1.1 server for the same reason.
//
// ---- what it is, honestly ------------------------------------------------
// One accept loop, one thread per connection, one request per connection
// (`Connection: close`). Body length is Content-Length; chunked request bodies
// are refused by name rather than guessed. This is enough for a model client and
// for a local gateway, and it is NOT a general-purpose server: no keep-alive, no
// TLS, no HTTP/2, no chunked requests.
//
// CORS: the Worker page lives on the loopback origin (`:engine`'s port) and the
// model endpoint is a different loopback port, so a page-context fetch is
// cross-origin. The server answers `OPTIONS` preflight and stamps
// `access-control-allow-origin: *` on every response. That header is safe here
// because the only thing it guards is a scripted fixture bound to 127.0.0.1.

package com.phonedsh.testkit.http

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/** One parsed request. Header names are lowercased; the body is complete. */
data class HttpRequest(
    val method: String,
    val path: String,
    val headers: Map<String, String>,
    val body: ByteArray,
) {
    /** The `Content-Type` the caller sent, or `""`. */
    val contentType: String get() = headers["content-type"] ?: ""

    /** Body as UTF-8 text (a model request is always JSON text here). */
    fun bodyText(): String = String(body, StandardCharsets.UTF_8)
}

/** One response the fixture writes. */
data class HttpResponse(
    val status: Int,
    val headers: Map<String, String> = emptyMap(),
    val body: ByteArray = ByteArray(0),
) {
    companion object {
        /** `application/json` with the given text body. */
        fun json(status: Int, text: String, contentType: String = "application/json") = HttpResponse(
            status = status,
            headers = mapOf("content-type" to contentType),
            body = text.toByteArray(StandardCharsets.UTF_8),
        )

        /** A JSON error document; the fixture never reflects a request body. */
        fun error(status: Int, code: String, message: String) = json(
            status,
            """{"error":{"code":"$code","message":"$message"}}""",
        )
    }
}

/** Handles one request. Must not block for longer than the client's read timeout. */
fun interface HttpHandler {
    fun handle(request: HttpRequest): HttpResponse
}

/**
 * A loopback HTTP/1.1 fixture server.
 *
 * [start] binds an ephemeral port on 127.0.0.1; [port] and [baseUrl] are valid
 * after it returns. [stop] closes the listener and every live socket.
 */
class MiniHttpServer(
    private val handler: HttpHandler,
    private val name: String = "testkit-http",
) {
    private val running = AtomicBoolean(false)
    private var serverSocket: ServerSocket? = null
    private val sockets = ConcurrentHashMap.newKeySet<Socket>()
    private val workers = CopyOnWriteArrayList<Thread>()
    private val served = AtomicInteger()

    /** The port the listener bound, or 0 before [start]. */
    @Volatile
    var port: Int = 0
        private set

    /** `http://127.0.0.1:<port>`; valid after [start]. */
    val baseUrl: String get() = "http://127.0.0.1:$port"

    /** Requests actually answered, in completion order (diagnostics). */
    val servedCount: Int get() = served.get()

    /** Binds `127.0.0.1:0` and starts accepting. Blocks until the port is known. */
    fun start(): MiniHttpServer {
        check(!running.get()) { "$name is already started" }
        val socket = ServerSocket()
        socket.reuseAddress = true
        socket.bind(InetSocketAddress(InetAddress.getByName(LOOPBACK), 0), 16)
        serverSocket = socket
        port = socket.localPort
        running.set(true)
        val acceptor = thread(name = "$name-acceptor", isDaemon = true) {
            acceptLoop(socket)
        }
        workers += acceptor
        return this
    }

    /** Stops accepting and closes every live socket. Idempotent. */
    fun stop() {
        if (!running.compareAndSet(true, false)) return
        runCatching { serverSocket?.close() }
        serverSocket = null
        for (socket in sockets) runCatching { socket.close() }
        sockets.clear()
    }

    private fun acceptLoop(socket: ServerSocket) {
        while (running.get()) {
            val accepted = try {
                socket.accept()
            } catch (_: IOException) {
                return
            }
            sockets += accepted
            val worker = thread(name = "$name-conn-${accepted.port}", isDaemon = true) {
                try {
                    serve(accepted)
                } catch (_: IOException) {
                    // A fixture connection dying is not a test failure by itself;
                    // the assertions are made against the recorded requests.
                } finally {
                    sockets.remove(accepted)
                    runCatching { accepted.close() }
                }
            }
            workers += worker
        }
    }

    private fun serve(socket: Socket) {
        socket.soTimeout = READ_TIMEOUT_MILLIS
        val input = BufferedInputStream(socket.getInputStream())
        val output = BufferedOutputStream(socket.getOutputStream())
        val request = parse(input) ?: return
        val response = if (request.method == "OPTIONS") preflight() else runCatching {
            handler.handle(request)
        }.getOrElse { failure ->
            HttpResponse.error(500, "fixture_failed", failure.javaClass.simpleName)
        }
        served.incrementAndGet()
        write(output, request.method == "HEAD", response)
        output.flush()
    }

    private fun preflight(): HttpResponse = HttpResponse(
        status = 204,
        headers = mapOf(
            "access-control-allow-methods" to "GET, POST, OPTIONS",
            "access-control-allow-headers" to "*",
            "access-control-max-age" to "600",
        ),
    )

    private fun write(output: BufferedOutputStream, head: Boolean, response: HttpResponse) {
        val headers = LinkedHashMap<String, String>()
        headers["access-control-allow-origin"] = "*"
        headers["cache-control"] = "no-store"
        headers["connection"] = "close"
        headers.putAll(response.headers)
        val body = if (head) ByteArray(0) else response.body
        headers["content-length"] = body.size.toString()
        val head_text = buildString {
            append("HTTP/1.1 ").append(response.status).append(' ').append(reason(response.status)).append("\r\n")
            for ((key, value) in headers) append(key).append(": ").append(value).append("\r\n")
            append("\r\n")
        }
        output.write(head_text.toByteArray(StandardCharsets.US_ASCII))
        if (body.isNotEmpty()) output.write(body)
    }

    /** Parses one complete request; `null` when the peer sent nothing or a bad head. */
    private fun parse(input: InputStream): HttpRequest? {
        val head = readHead(input) ?: return null
        val lines = head.split("\r\n")
        val requestLine = lines.firstOrNull() ?: return null
        val parts = requestLine.split(' ').filter { it.isNotEmpty() }
        if (parts.size < 2) return null
        val headers = LinkedHashMap<String, String>()
        for (line in lines.drop(1)) {
            val colon = line.indexOf(':')
            if (colon <= 0) continue
            val name = line.substring(0, colon).trim().lowercase()
            val value = line.substring(colon + 1).trim()
            if (name.isNotEmpty()) headers[name] = value
        }
        if (headers["transfer-encoding"]?.lowercase()?.contains("chunked") == true) {
            return HttpRequest(parts[0].uppercase(), parts[1], headers, ByteArray(0))
        }
        val length = headers["content-length"]?.toIntOrNull() ?: 0
        val body = if (length > 0) readExactly(input, length) else ByteArray(0)
        return HttpRequest(parts[0].uppercase(), parts[1], headers, body)
    }

    private fun readHead(input: InputStream): String? {
        val buffer = StringBuilder()
        var matched = 0
        while (true) {
            val next = input.read()
            if (next < 0) return if (buffer.isEmpty()) null else buffer.toString()
            buffer.append(next.toChar())
            matched = when {
                matched == 0 && next == '\r'.code -> 1
                matched == 1 && next == '\n'.code -> 2
                matched == 2 && next == '\r'.code -> 3
                matched == 3 && next == '\n'.code -> return buffer.substring(0, buffer.length - 4)
                else -> 0
            }
            if (buffer.length > MAX_HEAD_BYTES) return null
        }
    }

    private fun readExactly(input: InputStream, length: Int): ByteArray {
        val bytes = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val read = input.read(bytes, offset, length - offset)
            if (read < 0) break
            offset += read
        }
        return if (offset == length) bytes else bytes.copyOf(offset)
    }

    private fun reason(status: Int): String = when (status) {
        200 -> "OK"
        204 -> "No Content"
        400 -> "Bad Request"
        401 -> "Unauthorized"
        403 -> "Forbidden"
        404 -> "Not Found"
        405 -> "Method Not Allowed"
        500 -> "Internal Server Error"
        502 -> "Bad Gateway"
        else -> "Status"
    }

    private companion object {
        const val LOOPBACK = "127.0.0.1"
        const val MAX_HEAD_BYTES = 64 * 1024
        const val READ_TIMEOUT_MILLIS = 30_000
    }
}
