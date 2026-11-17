// SPDX-License-Identifier: MIT
// phone-dsh — :net / com.phonedsh.cloudtasks: the phone-side HTTP calls.
//
// cloud-tasks.md §2 (register, list, delete) and §5 (pull, ack) against the
// cloud origin of tono-account.md §1 and nothing else. The credential is the
// tono access token only (`Authorization: Bearer`); an API key is never sent.
// A 401 `credential_expired` and a 503 `identity_unavailable` are judged by the
// existing `TonoCloudResponsePolicy` (tono-account.md §5–§6): at most one
// re-send with a changed token, at most two after the stated wait.
//
// The API is blocking, like `TonoAccountSession`: callers are on an IO thread.
// The transport is a seam so the shared cases and every failure path run with
// no network.

package com.phonedsh.cloudtasks

import com.phonedsh.account.TonoAccessTokenSource
import com.phonedsh.account.TonoAccountException
import com.phonedsh.gateway.TonoCloudResponsePolicy
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI

/** One request to the cloud. `toString` prints neither the token nor the body. */
class CloudTaskHttpRequest(
    val method: String,
    val url: String,
    val headers: Map<String, String>,
    /** `null` for a request without a body (GET, DELETE). */
    val body: ByteArray?,
) {
    override fun toString(): String = "CloudTaskHttpRequest($method ${url.substringBefore('?')})"
}

/** One answer; header names are lowercase. */
class CloudTaskHttpAnswer(
    val status: Int,
    val headers: Map<String, String> = emptyMap(),
    val body: ByteArray = ByteArray(0),
) {
    override fun toString(): String = "CloudTaskHttpAnswer($status)"
}

/** One exchange with the cloud; throwing means "no answer". */
fun interface CloudTaskTransport {
    @Throws(IOException::class)
    fun send(request: CloudTaskHttpRequest): CloudTaskHttpAnswer
}

/** `HttpURLConnection` transport: no redirects, no caches, bounded body. */
class HttpUrlConnectionCloudTaskTransport(
    private val connectTimeoutMillis: Int = 10_000,
    private val readTimeoutMillis: Int = 30_000,
) : CloudTaskTransport {
    override fun send(request: CloudTaskHttpRequest): CloudTaskHttpAnswer {
        val connection = URI(request.url).toURL().openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.connectTimeout = connectTimeoutMillis
            connection.readTimeout = readTimeoutMillis
            connection.requestMethod = request.method
            for ((name, value) in request.headers) connection.setRequestProperty(name, value)
            val body = request.body
            if (body != null) {
                connection.doOutput = true
                // Buffered on purpose: the JDK connection drops a 401 body in streaming mode.
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            val headers = LinkedHashMap<String, String>()
            for ((name, values) in connection.headerFields) {
                if (name != null) headers[name.lowercase()] = values.filterNotNull().joinToString(", ")
            }
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            val answer = stream?.use { input ->
                val bytes = input.readNBytes(MAX_BODY_BYTES + 1)
                if (bytes.size > MAX_BODY_BYTES) throw IOException("cloud task answer too large")
                bytes
            } ?: ByteArray(0)
            return CloudTaskHttpAnswer(status, headers, answer)
        } finally {
            connection.disconnect()
        }
    }

    private companion object {
        // 16 tasks of at most 16400 sealed bytes in base64url, plus members.
        const val MAX_BODY_BYTES: Int = 1024 * 1024
    }
}

/** What one call came to. */
sealed interface CloudTaskReply<out T> {
    data class Ok<T>(val value: T) : CloudTaskReply<T>

    /** The cloud answered an error; [code] is the contract's code, `null` when the body is not an error body. */
    data class Refused(val status: Int, val code: String?) : CloudTaskReply<Nothing>

    /** 404 without the contract's error body: this cloud has no phone task routes. */
    data object RouteMissing : CloudTaskReply<Nothing>

    /** No usable access token: signed out, or the session cannot produce one now. */
    data object NoCredential : CloudTaskReply<Nothing>

    /** No answer, or a 5xx without a contract body. */
    data object Unreachable : CloudTaskReply<Nothing>

    /** A success status whose body is not the contract's answer, or a body this end refuses to send. */
    data object ProtocolError : CloudTaskReply<Nothing>
}

class CloudTaskClient(
    private val transport: CloudTaskTransport,
    private val tokens: TonoAccessTokenSource,
    /** Waits the given seconds before a 503 `identity_unavailable` re-send. */
    private val sleepSeconds: (Long) -> Unit = { seconds -> Thread.sleep(seconds * 1000) },
) {
    private val policy = TonoCloudResponsePolicy.PRODUCTION

    /** `PUT /v1/phone/devices/{device_id}` with `platform: "android"` and `push: null`. */
    fun registerDevice(deviceId: String, appVersion: String, key: CloudTaskPublicKey): CloudTaskReply<CloudTaskDeviceAck> {
        if (!CloudTaskWire.isDeviceId(deviceId)) return CloudTaskReply.ProtocolError
        val body = try {
            CloudTaskWire.deviceBody(appVersion, key)
        } catch (_: CloudTaskWireException) {
            return CloudTaskReply.ProtocolError
        }
        return exchange("PUT", "/v1/phone/devices/$deviceId", body) { answer ->
            if (answer.status != 200) return@exchange null
            CloudTaskWire.decodeDeviceAck(answer.body).takeIf { it.deviceId == deviceId && it.keyId == key.keyId }
        }
    }

    /** `GET /v1/phone/devices`. */
    fun listDevices(): CloudTaskReply<CloudTaskDeviceList> =
        exchange("GET", "/v1/phone/devices", null) { answer ->
            if (answer.status == 200) CloudTaskWire.decodeDeviceList(answer.body) else null
        }

    /** `DELETE /v1/phone/devices/{device_id}`; `204` is the only success. */
    fun deleteDevice(deviceId: String): CloudTaskReply<Unit> {
        if (!CloudTaskWire.isDeviceId(deviceId)) return CloudTaskReply.ProtocolError
        return exchange("DELETE", "/v1/phone/devices/$deviceId", null) { answer ->
            if (answer.status == 204) Unit else null
        }
    }

    /** `GET /v1/phone/tasks/pull`; out-of-range values are clamped here as the cloud would. */
    fun pull(deviceId: String, limit: Int = 16, leaseSeconds: Int = 300, waitSeconds: Int = 0): CloudTaskReply<CloudTaskPullResponse> {
        if (!CloudTaskWire.isDeviceId(deviceId)) return CloudTaskReply.ProtocolError
        val query = "device_id=$deviceId" +
            "&limit=${limit.coerceIn(1, CloudTaskWire.MAX_PULL)}" +
            "&lease_s=${leaseSeconds.coerceIn(5, 900)}" +
            "&wait_s=${waitSeconds.coerceIn(0, 60)}"
        return exchange("GET", "/v1/phone/tasks/pull?$query", null) { answer ->
            if (answer.status == 200) CloudTaskWire.decodePull(answer.body) else null
        }
    }

    /** `POST /v1/phone/tasks/ack` with 1–16 acks; results come back in request order. */
    fun ack(deviceId: String, acks: List<CloudTaskAck>): CloudTaskReply<CloudTaskAckResponse> {
        val body = try {
            CloudTaskWire.ackBody(deviceId, acks)
        } catch (_: CloudTaskWireException) {
            return CloudTaskReply.ProtocolError
        }
        val sent = acks.map { it.taskId }
        return exchange("POST", "/v1/phone/tasks/ack", body) { answer ->
            if (answer.status == 200) CloudTaskWire.decodeAckResponse(answer.body, sent) else null
        }
    }

    private fun currentToken(): String? {
        val token = try {
            tokens.accessToken()
        } catch (_: TonoAccountException) {
            null
        }
        // §1: an API key is never a credential here.
        return token?.takeIf { it.isNotEmpty() && !it.startsWith("pdsk_") }
    }

    private fun <T> exchange(
        method: String,
        pathAndQuery: String,
        body: ByteArray?,
        decode: (CloudTaskHttpAnswer) -> T?,
    ): CloudTaskReply<T> {
        var token = currentToken() ?: return CloudTaskReply.NoCredential
        val url = ORIGIN + pathAndQuery
        var credentialRetries = 0
        var identityRetries = 0
        while (true) {
            val headers = LinkedHashMap<String, String>()
            headers["authorization"] = "Bearer $token"
            headers["accept"] = "application/json"
            if (body != null) headers["content-type"] = "application/json"
            val answer = try {
                transport.send(CloudTaskHttpRequest(method, url, headers, body))
            } catch (_: Exception) {
                return CloudTaskReply.Unreachable
            }
            when (val decision = policy.decide(url, answer.status, answer.headers, answer.body)) {
                TonoCloudResponsePolicy.Decision.RefreshRetry ->
                    if (credentialRetries < TonoCloudResponsePolicy.CREDENTIAL_RETRY_MAX) {
                        tokens.invalidate(token)
                        val fresh = currentToken()
                        if (fresh != null && fresh != token) {
                            token = fresh
                            credentialRetries++
                            continue
                        }
                    }
                is TonoCloudResponsePolicy.Decision.RetryAfter ->
                    if (identityRetries < TonoCloudResponsePolicy.IDENTITY_RETRY_MAX) {
                        try {
                            sleepSeconds(decision.seconds)
                        } catch (_: InterruptedException) {
                            Thread.currentThread().interrupt()
                            return CloudTaskReply.Unreachable
                        }
                        identityRetries++
                        continue
                    }
                TonoCloudResponsePolicy.Decision.Forward -> Unit
            }
            return classify(answer, decode)
        }
    }

    private fun <T> classify(answer: CloudTaskHttpAnswer, decode: (CloudTaskHttpAnswer) -> T?): CloudTaskReply<T> {
        if (answer.status in 200..299) {
            val value = try {
                decode(answer)
            } catch (_: CloudTaskWireException) {
                null
            }
            return if (value != null) CloudTaskReply.Ok(value) else CloudTaskReply.ProtocolError
        }
        val error = CloudTaskWire.decodeError(answer.body)
        return when {
            error != null -> CloudTaskReply.Refused(answer.status, error.code)
            answer.status == 404 -> CloudTaskReply.RouteMissing
            answer.status >= 500 -> CloudTaskReply.Unreachable
            else -> CloudTaskReply.Refused(answer.status, null)
        }
    }

    companion object {
        /** tono-account.md §1 cloud origin; this client talks to nothing else. */
        const val ORIGIN: String = TonoCloudResponsePolicy.CLOUD_ORIGIN
    }
}
