// phone-dsh — :loopback tests: fixtures, a raw HTTP/1.1 client and await helpers.
// SPDX-License-Identifier: MIT
//
// Two clients on purpose: the Ktor client for ordinary requests and the one
// WebSocket use case, a raw socket for the things a well-behaved client hides
// (dot segments in the request line, an upgrade attempt, exact status lines).

package com.phonedsh.loopback

import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.plugins.websocket.webSocket
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.statement.bodyAsBytes
import io.ktor.http.HttpHeaders
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeout
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.file.Files
import java.nio.file.Path
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

internal object Fixtures {
    const val INDEX_HTML: String =
        "<!doctype html><meta charset=\"utf-8\"><title>pdsh boot</title><script src=\"boot.js\"></script>\n"
    const val SUB_INDEX_HTML: String = "<!doctype html><meta charset=\"utf-8\"><title>sub page</title>\n"
    const val MANIFEST: String = "{\"bundle\":\"probe\",\"version\":1}\n"
    const val BUNDLE_MANIFEST: String = "{\"entries\":[]}\n"
    const val BOOT_JS: String = "console.log('boot')\n"
    const val WORKER_JS: String = "export const entry = 1\n"
    const val WORKER_MJS: String = "export const entry = 2\n"
    const val SOURCE_MAP: String = "{\"version\":3,\"sources\":[]}\n"
    const val STYLES_CSS: String = "body{color:#000}\n"
    val WASM: ByteArray = byteArrayOf(0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0xFF.toByte(), 0x00, 0x7F)
    val ARCHIVE: ByteArray = byteArrayOf(0x1F, 0x8B.toByte(), 0x08, 0x00, 0x00, 0x00, 0x00, 0x00)
    val OPAQUE: ByteArray = byteArrayOf(0x00, 0x01, 0x02, 0x7F, 0x80.toByte(), 0xFF.toByte())

    /** Writes a miniature worker bundle and returns the asset root. */
    fun write(root: Path): Path {
        Files.createDirectories(root)
        Files.write(root.resolve("index.html"), INDEX_HTML.toByteArray())
        Files.write(root.resolve("manifest.json"), MANIFEST.toByteArray())
        Files.write(root.resolve("probe-bundle.json"), BUNDLE_MANIFEST.toByteArray())
        Files.write(root.resolve("boot.js"), BOOT_JS.toByteArray())
        Files.write(root.resolve("worker-entry.js"), WORKER_JS.toByteArray())
        Files.write(root.resolve("worker-entry.mjs"), WORKER_MJS.toByteArray())
        Files.write(root.resolve("tool-worker.js.map"), SOURCE_MAP.toByteArray())
        Files.write(root.resolve("styles.css"), STYLES_CSS.toByteArray())
        Files.write(root.resolve("engine.wasm"), WASM)
        Files.write(root.resolve("plain.bin"), OPAQUE)
        Files.createDirectories(root.resolve("lazy"))
        Files.write(root.resolve("lazy/abc.tar.gz"), ARCHIVE)
        Files.createDirectories(root.resolve("sub"))
        Files.write(root.resolve("sub/index.html"), SUB_INDEX_HTML.toByteArray())
        Files.createDirectories(root.resolve("no-index"))
        Files.write(root.resolve("no-index/keep.txt"), "keep\n".toByteArray())
        return root
    }
}

/** Records everything the one channel delivers, in call order. */
internal class RecordingHandler(
    private val onFirstPayload: (suspend (LoopbackConnection) -> Unit)? = null,
) : LoopbackChannelHandler {
    val opened = AtomicInteger()
    val closed = CopyOnWriteArrayList<ChannelCloseCause>()
    val payloads = CopyOnWriteArrayList<ByteArray>()
    val connectionIds = CopyOnWriteArrayList<String>()

    override suspend fun onOpen(connection: LoopbackConnection) {
        opened.incrementAndGet()
        connectionIds.add(connection.id)
    }

    override suspend fun onBinary(connection: LoopbackConnection, payload: ByteArray) {
        val first = payloads.isEmpty()
        payloads.add(payload.copyOf())
        if (first && onFirstPayload != null) onFirstPayload.invoke(connection)
    }

    override suspend fun onClosed(connection: LoopbackConnection, cause: ChannelCloseCause) {
        closed.add(cause)
    }
}

internal suspend fun HttpClient.getAsset(
    endpoint: LoopbackEndpoint,
    path: String,
    token: String? = endpoint.token,
): io.ktor.client.statement.HttpResponse = get(endpoint.urlFor(path)) {
    if (token != null) header(HttpHeaders.Authorization, "Bearer $token")
}

internal fun newClient(): HttpClient = HttpClient(CIO) {
    install(WebSockets)
}

/** Runs [block] on the client's channel, authenticated by header. */
internal suspend fun HttpClient.withChannel(
    endpoint: LoopbackEndpoint,
    block: suspend io.ktor.client.plugins.websocket.DefaultClientWebSocketSession.() -> Unit,
) {
    webSocket(urlString = endpoint.channelUrl(), request = {
        header(HttpHeaders.Authorization, "Bearer ${endpoint.token}")
    }) {
        block()
    }
}

internal data class RawResponse(val status: Int, val headers: Map<String, String>, val body: ByteArray) {
    val bodyText: String get() = body.toString(Charsets.UTF_8)
    fun header(name: String): String? = headers.entries.firstOrNull { it.key.equals(name, true) }?.value
}

/**
 * One hand-written HTTP/1.1 request.
 *
 * [target] is sent verbatim, so `/../secret.txt` and `/%2e%2e/secret.txt`
 * really leave the client as traversal attempts instead of being normalised.
 * [host] overrides the `Host` header, which is the authority the D22 launch
 * cookie is bound to; the default is the address the socket actually reached.
 */
internal fun rawRequest(
    port: Int,
    method: String,
    target: String,
    headers: Map<String, String> = emptyMap(),
    host: String = "${LoopbackConfiguration.LOOPBACK_HOST}:$port",
): RawResponse {
    Socket().use { socket ->
        socket.soTimeout = RAW_TIMEOUT_MILLIS.toInt()
        socket.connect(InetSocketAddress(LoopbackConfiguration.LOOPBACK_HOST, port), RAW_TIMEOUT_MILLIS.toInt())
        val request = buildString {
            append(method).append(' ').append(target).append(" HTTP/1.1\r\n")
            append("Host: ").append(host).append("\r\n")
            for ((name, value) in headers) append(name).append(": ").append(value).append("\r\n")
            append("Connection: close\r\n\r\n")
        }
        socket.getOutputStream().apply {
            write(request.toByteArray(Charsets.ISO_8859_1))
            flush()
        }
        val input = socket.getInputStream()
        val head = readHeaderBlock(input)
        if (head.isEmpty()) return RawResponse(0, emptyMap(), ByteArray(0))
        val headText = head.toString(Charsets.ISO_8859_1)
        val separator = headText.indexOf("\r\n\r\n")
        if (separator < 0) return RawResponse(0, emptyMap(), head)
        val headerText = headText.substring(0, separator)
        val rest = head.copyOfRange(separator + 4, head.size)
        val lines = headerText.split("\r\n")
        val status = lines.first().split(' ').getOrNull(1)?.toIntOrNull() ?: 0
        val parsed = LinkedHashMap<String, String>()
        for (line in lines.drop(1)) {
            val colon = line.indexOf(':')
            if (colon <= 0) continue
            parsed[line.substring(0, colon).trim()] = line.substring(colon + 1).trim()
        }
        if (status == 101) return RawResponse(status, parsed, ByteArray(0))
        val declared = parsed.entries
            .firstOrNull { it.key.equals("Content-Length", true) }
            ?.value?.toIntOrNull()
        val body = if (declared != null) {
            val padding = declared - rest.size
            if (padding <= 0) rest.copyOfRange(0, declared) else rest + readFully(input, padding)
        } else {
            rest + readToEnd(input)
        }
        return RawResponse(status, parsed, body)
    }
}

/**
 * A WebSocket client that speaks bytes, not conveniences.
 *
 * The Ktor client buffers incoming frames without a visible bound, so it is
 * useless as a backpressure probe: it will happily absorb 32 MiB without the
 * test ever reading. This client never reads unless the test asks it to, which
 * closes the TCP window and makes the origin's send suspend for real.
 */
internal class RawWebSocketClient private constructor(
    private val socket: Socket,
    private val input: InputStream,
) : AutoCloseable {
    /** Reads exactly one server frame: binary, unfragmented, unmasked. */
    fun readBinaryFrame(): ByteArray {
        val header = readFully(input, 2)
        check(header.size == 2) { "the connection closed before a frame header" }
        val opcode = header[0].toInt() and 0x0F
        check(opcode == 0x02) { "expected a binary frame, got opcode $opcode" }
        check(header[1].toInt() and 0x80 == 0) { "server frames must not be masked" }
        val length = when (val short = header[1].toInt() and 0x7F) {
            126 -> {
                val extended = readFully(input, 2)
                ((extended[0].toInt() and 0xFF) shl 8) or (extended[1].toInt() and 0xFF)
            }
            127 -> {
                val extended = readFully(input, 8)
                var value = 0L
                for (byte in extended) value = (value shl 8) or (byte.toLong() and 0xFF)
                value
            }
            else -> short.toLong()
        }
        return readFully(input, length.toInt())
    }

    override fun close() {
        runCatching { socket.close() }
    }

    companion object {
        /** Performs the RFC 6455 handshake and returns a client that reads nothing yet. */
        fun connect(port: Int, target: String, token: String?): RawWebSocketClient {
            val socket = Socket()
            socket.soTimeout = RAW_TIMEOUT_MILLIS.toInt()
            socket.connect(InetSocketAddress(LoopbackConfiguration.LOOPBACK_HOST, port), RAW_TIMEOUT_MILLIS.toInt())
            val request = buildString {
                append("GET ").append(target).append(" HTTP/1.1\r\n")
                append("Host: ").append(LoopbackConfiguration.LOOPBACK_HOST).append(':').append(port).append("\r\n")
                for ((name, value) in upgradeHeaders(token)) append(name).append(": ").append(value).append("\r\n")
                append("\r\n")
            }
            socket.getOutputStream().apply {
                write(request.toByteArray(Charsets.ISO_8859_1))
                flush()
            }
            val head = readHeaderBlock(socket.getInputStream()).toString(Charsets.ISO_8859_1)
            check(head.startsWith("HTTP/1.1 101")) { "the upgrade failed: ${head.substringBefore("\r\n")}" }
            return RawWebSocketClient(socket, socket.getInputStream())
        }
    }
}

/** Headers for a real RFC 6455 upgrade attempt. */
internal fun upgradeHeaders(token: String?): Map<String, String> {
    val headers = LinkedHashMap<String, String>()
    headers["Connection"] = "Upgrade"
    headers["Upgrade"] = "websocket"
    headers["Sec-WebSocket-Version"] = "13"
    headers["Sec-WebSocket-Key"] = Base64.getEncoder().encodeToString(ByteArray(16) { 0x07.toByte() })
    if (token != null) headers["Authorization"] = "Bearer $token"
    return headers
}

/** One channel frame, built only to prove the origin does not touch the bytes. */
internal fun channelFrame(type: Byte, seq: Long, payload: ByteArray): ByteArray {
    val frame = ByteArray(16 + payload.size)
    frame[0] = 0x5A
    frame[1] = 0x4C.toByte()
    frame[2] = type
    frame[3] = 0
    for (shift in 0 until 8) {
        frame[4 + shift] = ((seq ushr (56 - 8 * shift)) and 0xFF).toByte()
    }
    for (shift in 0 until 4) {
        frame[12 + shift] = ((payload.size ushr (24 - 8 * shift)) and 0xFF).toByte()
    }
    payload.copyInto(frame, 16)
    return frame
}

internal fun aliveThreads(): Int = Thread.getAllStackTraces().keys.count { it.isAlive }

internal fun aliveThreadNames(): List<String> =
    Thread.getAllStackTraces().keys.filter { it.isAlive }.map { it.name }

internal fun awaitTrue(timeoutMillis: Long = 5_000, what: String = "condition", condition: () -> Boolean) {
    val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
    while (System.nanoTime() < deadline) {
        if (condition()) return
        Thread.sleep(10)
    }
    throw AssertionError("timed out after ${timeoutMillis}ms waiting for $what")
}

internal suspend fun awaitUntil(
    timeoutMillis: Long = 5_000,
    what: String = "condition",
    condition: () -> Boolean,
) {
    try {
        withTimeout(timeoutMillis) {
            while (!condition()) delay(5)
        }
    } catch (timeout: Exception) {
        throw AssertionError("timed out after ${timeoutMillis}ms waiting for $what", timeout)
    }
}

private const val RAW_TIMEOUT_MILLIS = 5_000L

private fun readHeaderBlock(input: InputStream): ByteArray {
    val buffer = ByteArrayOutputStream()
    val single = ByteArray(1)
    while (true) {
        val read = try {
            input.read(single)
        } catch (timeout: SocketTimeoutException) {
            break
        }
        if (read < 0) break
        buffer.write(single, 0, read)
        if (buffer.size() >= 4) {
            val bytes = buffer.toByteArray()
            if (bytes[bytes.size - 4] == 13.toByte() && bytes[bytes.size - 3] == 10.toByte() &&
                bytes[bytes.size - 2] == 13.toByte() && bytes[bytes.size - 1] == 10.toByte()
            ) {
                return bytes
            }
        }
    }
    return buffer.toByteArray()
}

internal fun readFully(input: InputStream, count: Int): ByteArray {
    val buffer = ByteArrayOutputStream()
    val chunk = ByteArray(8192)
    var remaining = count
    while (remaining > 0) {
        val read = try {
            input.read(chunk, 0, minOf(remaining, chunk.size))
        } catch (timeout: SocketTimeoutException) {
            break
        }
        if (read < 0) break
        buffer.write(chunk, 0, read)
        remaining -= read
    }
    return buffer.toByteArray()
}

private fun readToEnd(input: InputStream): ByteArray {
    val buffer = ByteArrayOutputStream()
    val chunk = ByteArray(8192)
    while (true) {
        val read = try {
            input.read(chunk)
        } catch (timeout: SocketTimeoutException) {
            break
        }
        if (read < 0) break
        buffer.write(chunk, 0, read)
    }
    return buffer.toByteArray()
}
