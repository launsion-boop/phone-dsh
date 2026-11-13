// phone-dsh — :loopback tests: Bot MCP raw-socket client and fake handler.
// SPDX-License-Identifier: MIT
//
// The Bot MCP acceptance must drive a real `127.0.0.1` socket. This helper
// writes HTTP/1.1 by hand (including a raw target, a missing header, a chunked
// request and a declared oversize body) and decodes both `Content-Length` and
// `Transfer-Encoding: chunked` responses. `Ktor` would hide exactly the bytes
// the contract freezes.

package com.phonedsh.loopback

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

internal data class BotMcpRawResponse(
    val status: Int,
    val headers: Map<String, String>,
    val body: ByteArray,
) {
    val bodyText: String get() = body.toString(Charsets.UTF_8)

    fun header(name: String): String? =
        headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value

    fun headerNames(): Set<String> = headers.keys
}

/**
 * One hand-written Bot MCP request.
 *
 * [target] is sent verbatim; [chunked] switches the body to
 * `Transfer-Encoding: chunked` so the read-headroom 413 can be exercised. A
 * caller that wants no `Content-Length` but a zero-length body must pass
 * [chunked] = false and an empty [body], which still sends `Content-Length: 0`.
 */
internal fun botMcpRawRequest(
    port: Int,
    target: String,
    headers: Map<String, String> = emptyMap(),
    body: ByteArray = ByteArray(0),
    method: String = "POST",
    chunked: Boolean = false,
    declaredLength: Int? = null,
    expectClose: Boolean = false,
): BotMcpRawResponse {
    Socket().use { socket ->
        socket.soTimeout = RAW_TIMEOUT_MILLIS
        socket.connect(
            InetSocketAddress(LoopbackConfiguration.LOOPBACK_HOST, port),
            RAW_CONNECT_TIMEOUT_MILLIS,
        )
        val head = buildString {
            append(method).append(' ').append(target).append(" HTTP/1.1\r\n")
            append("Host: ").append(LoopbackConfiguration.LOOPBACK_HOST).append(':').append(port).append("\r\n")
            for ((name, value) in headers) append(name).append(": ").append(value).append("\r\n")
            if (chunked) {
                append("Transfer-Encoding: chunked\r\n")
            } else {
                append("Content-Length: ").append(declaredLength ?: body.size).append("\r\n")
            }
            append("\r\n")
        }
        val output = socket.getOutputStream()
        try {
            output.write(head.toByteArray(Charsets.ISO_8859_1))
            if (body.isNotEmpty()) {
                if (chunked) {
                    var offset = 0
                    while (offset < body.size) {
                        val length = minOf(CHUNK_BYTES, body.size - offset)
                        output.write(("%x\r\n".format(length)).toByteArray(Charsets.ISO_8859_1))
                        output.write(body, offset, length)
                        output.write("\r\n".toByteArray(Charsets.ISO_8859_1))
                        offset += length
                    }
                    output.write("0\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
                } else if (declaredLength == null || declaredLength == body.size) {
                    output.write(body)
                }
            }
            output.flush()
        } catch (closed: java.io.IOException) {
            // A 413/401 can be written before the client finished; the response
            // is still readable and is what the test asserts.
        }

        val input = socket.getInputStream()
        val headerBytes = readHeaderBlock(input)
        val headerText = headerBytes.toString(Charsets.ISO_8859_1)
        val separator = headerText.indexOf("\r\n\r\n")
        val lines = if (separator >= 0) {
            headerText.substring(0, separator).split("\r\n")
        } else {
            headerText.split("\r\n")
        }
        val status = lines.firstOrNull()?.split(' ')?.getOrNull(1)?.toIntOrNull() ?: 0
        val parsed = LinkedHashMap<String, String>()
        for (line in lines.drop(1)) {
            val colon = line.indexOf(':')
            if (colon <= 0) continue
            parsed[line.substring(0, colon).trim()] = line.substring(colon + 1).trim()
        }
        val rest = if (separator >= 0) {
            headerBytes.copyOfRange(separator + 4, headerBytes.size)
        } else {
            ByteArray(0)
        }
        val chunkedResponse = parsed.entries
            .firstOrNull { it.key.equals("Transfer-Encoding", true) }
            ?.value?.contains("chunked", ignoreCase = true) == true
        val bodyBytes = if (chunkedResponse) {
            decodeChunked(rest, input)
        } else {
            val declared = parsed.entries
                .firstOrNull { it.key.equals("Content-Length", true) }
                ?.value?.toIntOrNull()
            if (declared != null) {
                if (rest.size >= declared) rest.copyOfRange(0, declared) else rest + readExactly(input, declared - rest.size)
            } else {
                rest + readToEnd(input)
            }
        }
        if (expectClose) {
            val eof = input.read()
            check(eof < 0) { "the listener kept the connection open after its response (read $eof)" }
        }
        return BotMcpRawResponse(status, parsed, bodyBytes)
    }
}

private fun readHeaderBlock(input: InputStream): ByteArray {
    val out = ByteArrayOutputStream()
    var matched = 0
    while (true) {
        val value = input.read()
        if (value < 0) break
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
        if (matched == 4) break
    }
    return out.toByteArray()
}

private fun decodeChunked(head: ByteArray, input: InputStream): ByteArray {
    val out = ByteArrayOutputStream()
    var buffer = head
    while (true) {
        val lineEnd = indexOfCrlf(buffer)
        if (lineEnd < 0) {
            val more = readSome(input)
            if (more.isEmpty()) return out.toByteArray()
            buffer += more
            continue
        }
        val sizeText = buffer.copyOfRange(0, lineEnd).toString(Charsets.ISO_8859_1).substringBefore(';').trim()
        val size = sizeText.toIntOrNull(16) ?: return out.toByteArray()
        var cursor = lineEnd + 2
        if (size == 0) {
            // Consume the trailing CRLF/headers if present; the body is done.
            return out.toByteArray()
        }
        while (buffer.size < cursor + size + 2) {
            val more = readSome(input)
            if (more.isEmpty()) return out.toByteArray()
            buffer += more
        }
        out.write(buffer, cursor, size)
        cursor += size + 2
        buffer = buffer.copyOfRange(cursor, buffer.size)
    }
}

private fun indexOfCrlf(bytes: ByteArray): Int {
    for (index in 0 until bytes.size - 1) {
        if (bytes[index] == '\r'.code.toByte() && bytes[index + 1] == '\n'.code.toByte()) return index
    }
    return -1
}

private fun readSome(input: InputStream, max: Int = 8192): ByteArray {
    val buffer = ByteArray(max)
    val read = try {
        input.read(buffer)
    } catch (timeout: java.net.SocketTimeoutException) {
        return ByteArray(0)
    }
    return if (read <= 0) ByteArray(0) else buffer.copyOf(read)
}

private fun readExactly(input: InputStream, count: Int): ByteArray {
    val out = ByteArrayOutputStream()
    var remaining = count
    val buffer = ByteArray(8192)
    while (remaining > 0) {
        val read = input.read(buffer, 0, minOf(buffer.size, remaining))
        if (read < 0) break
        out.write(buffer, 0, read)
        remaining -= read
    }
    return out.toByteArray()
}

private fun readToEnd(input: InputStream): ByteArray {
    val out = ByteArrayOutputStream()
    val buffer = ByteArray(8192)
    while (true) {
        val read = try {
            input.read(buffer)
        } catch (timeout: java.net.SocketTimeoutException) {
            break
        }
        if (read < 0) break
        out.write(buffer, 0, read)
    }
    return out.toByteArray()
}

private const val RAW_CONNECT_TIMEOUT_MILLIS = 2_000
private const val RAW_TIMEOUT_MILLIS = 10_000
private const val CHUNK_BYTES = 8_192

/**
 * The App-side seam under test: records every call and lets a test replace the
 * response (a deferred long call, an echo, a failure).
 */
internal class BotMcpTestHandler(
    private val respond: (BotMcpRequest) -> BotMcpResponse = { BotMcpResponse.Json(200, "{}".toByteArray()) },
) : BotMcpRequestHandler {
    val requests = CopyOnWriteArrayList<BotMcpRequest>()

    override val mcpSessionId: String = "test-session"

    override suspend fun handle(request: BotMcpRequest): BotMcpResponse {
        requests.add(request)
        return respond(request)
    }

}

internal fun BotMcpRawResponse.bodyLines(): List<String> =
    bodyText.split(Regex("\r?\n")).filter { it.isNotEmpty() }

