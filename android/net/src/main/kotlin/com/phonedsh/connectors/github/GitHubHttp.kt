// phone-dsh — :net / com.phonedsh.connectors.github: HTTP seam.
// SPDX-License-Identifier: MIT
//
// The one transport the GitHub broker client and the GitHub REST client share
// (PC-20261119-android-connectors). Mirrors the iOS ephemeral URLSession used
// by `GitHubOAuthFlow.swift` and `GitHubConnectorAPI.swift`: no redirects, no
// caches, no cookies, bounded body, fixed timeout. Never logs URLs or bodies.

package com.phonedsh.connectors.github

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runInterruptible

class ConnectorHttpRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String>,
    val body: ByteArray?,
)

/** [headers] names are lower-case. */
class ConnectorHttpResponse(
    val status: Int,
    val headers: Map<String, String>,
    val body: ByteArray,
)

/** One HTTP exchange; throwing (other than cancellation) means "no answer". */
fun interface GitHubHttpTransport {
    suspend fun send(request: ConnectorHttpRequest): ConnectorHttpResponse
}

/** `HttpURLConnection` transport run on [Dispatchers.IO]. */
class HttpUrlConnectionGitHubTransport(
    private val timeoutMillis: Int,
    private val maxBodyBytes: Int = DEFAULT_MAX_BODY_BYTES,
) : GitHubHttpTransport {
    override suspend fun send(request: ConnectorHttpRequest): ConnectorHttpResponse =
        runInterruptible(Dispatchers.IO) { sendBlocking(request) }

    private fun sendBlocking(request: ConnectorHttpRequest): ConnectorHttpResponse {
        val connection = URI(request.url).toURL().openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.connectTimeout = timeoutMillis
            connection.readTimeout = timeoutMillis
            connection.requestMethod = request.method
            for ((name, value) in request.headers) connection.setRequestProperty(name, value)
            val body = request.body
            if (body != null) {
                connection.doOutput = true
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            val headers = LinkedHashMap<String, String>()
            for ((name, values) in connection.headerFields) {
                if (name != null) headers[name.lowercase()] = values.filterNotNull().joinToString(", ")
            }
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            val bytes = stream?.use { input ->
                val read = input.readNBytes(maxBodyBytes + 1)
                if (read.size > maxBodyBytes) throw IOException("GitHub answer too large")
                read
            } ?: ByteArray(0)
            return ConnectorHttpResponse(status, headers, bytes)
        } finally {
            connection.disconnect()
        }
    }

    companion object {
        const val DEFAULT_MAX_BODY_BYTES: Int = 4 * 1024 * 1024
    }
}
