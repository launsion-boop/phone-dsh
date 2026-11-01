// phone-dsh — :net / com.phonedsh.gateway: the production HTTP hop.
// SPDX-License-Identifier: MIT
//
// `GatewaySession` owns policy and redirect following; this class only issues
// the one hop it was told to issue. It therefore disables the platform's own
// redirect handling, surfaces every transport failure as
// [GatewayTransportException] (the gateway bounds its text), and never logs a
// URL or a header value.
//
// `HttpURLConnection` is the JVM/Android client available on API 26 without a
// new dependency; the demo's egress is small JSON over loopback or a public
// endpoint, so a full client engine would be another dependency and another
// policy surface.

package com.phonedsh.gateway

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI

/** One blocking request per gateway hop, through `HttpURLConnection`. */
class HttpUrlConnectionGatewayTransport(
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
            for ((rawName, values) in connection.headerFields) {
                if (rawName == null) continue
                val joined = values.filterNotNull().joinToString(", ")
                if (joined.isNotEmpty()) headers[rawName.lowercase()] = joined
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
