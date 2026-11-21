// phone-dsh — :net / com.phonedsh.connectors.gmail: the Gmail REST client.
// SPDX-License-Identifier: MIT
//
// Kotlin port of the iOS baseline `examples/probe-app/ProbeKit/GmailAPI.swift`
// (PC-20261111-ios-gmail, Android mechanics in PC-20261119-android-connectors).
// Same reads (`profile`, `messages` list, `metadata` and `full` message reads),
// same 12-row pages, status mapping, message-id check and MIME body selection.
// Nothing here logs a token, an address or mail content.

package com.phonedsh.connectors.gmail

import com.phonedsh.gateway.GatewayJson
import com.phonedsh.gateway.JsonValue
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext

/** iOS `GmailError`. Kotlin enums cannot be thrown, so [GmailException] carries one. */
enum class GmailError { UNAUTHORIZED, FORBIDDEN, NOT_FOUND, INVALID_RESPONSE, SERVICE_UNAVAILABLE }

class GmailException(val error: GmailError) : Exception(error.name)

data class GmailSummary(val id: String, val sender: String, val subject: String, val dateMillis: Long?)

data class GmailPage(val messages: List<GmailSummary>, val nextPageToken: String?)

sealed interface GmailBody {
    data class Plain(val text: String) : GmailBody
    data class Html(val html: String) : GmailBody
    data object Unavailable : GmailBody
}

data class GmailMessage(val summary: GmailSummary, val body: GmailBody)

data class GmailWakeMailbox(val email: String, val historyId: String)

data class GmailWakeHistory(val historyId: String, val messages: List<GmailSummary>)

class GmailHttpResponse(val status: Int, val body: ByteArray)

/** One GET; throwing [IOException] means no answer. */
fun interface GmailHttpTransport {
    suspend fun get(url: String, headers: Map<String, String>): GmailHttpResponse
}

/** `HttpURLConnection` transport: 30 s timeout, no redirects, no caches, bounded body. */
class HttpUrlConnectionGmailTransport(
    private val timeoutMillis: Int = 30_000,
) : GmailHttpTransport {
    override suspend fun get(url: String, headers: Map<String, String>): GmailHttpResponse =
        withContext(Dispatchers.IO) {
            val connection = URI(url).toURL().openConnection() as HttpURLConnection
            try {
                connection.instanceFollowRedirects = false
                connection.useCaches = false
                connection.connectTimeout = timeoutMillis
                connection.readTimeout = timeoutMillis
                connection.requestMethod = "GET"
                for ((name, value) in headers) connection.setRequestProperty(name, value)
                val status = connection.responseCode
                val stream = if (status >= 400) connection.errorStream else connection.inputStream
                val body = stream?.use { input ->
                    val bytes = input.readNBytes(MAX_BODY_BYTES + 1)
                    if (bytes.size > MAX_BODY_BYTES) throw IOException("Gmail answer too large")
                    bytes
                } ?: ByteArray(0)
                GmailHttpResponse(status, body)
            } finally {
                connection.disconnect()
            }
        }

    private companion object {
        const val MAX_BODY_BYTES: Int = 25 * 1024 * 1024
    }
}

class GmailApi(private val transport: GmailHttpTransport = HttpUrlConnectionGmailTransport()) {

    suspend fun accountEmail(token: String): String {
        val profile = get("profile", emptyList(), token)
        val email = profile.requiredString("emailAddress")
        if (email.isEmpty()) throw GmailException(GmailError.INVALID_RESPONSE)
        return email
    }

    suspend fun search(query: String, pageToken: String? = null, token: String): GmailPage {
        val items = mutableListOf("maxResults" to "12")
        if (query.isEmpty()) items += "labelIds" to "INBOX" else items += "q" to query
        if (pageToken != null) items += "pageToken" to pageToken
        val listing = get("messages", items, token)
        val references = listing.optionalArray("messages")?.map { reference ->
            (reference as? JsonValue.Obj ?: invalid()).requiredString("id")
        } ?: emptyList()
        val nextPageToken = listing.optionalString("nextPageToken")
        val messages = coroutineScope {
            references.map { id ->
                async {
                    try {
                        summary(getMessage(id, "metadata", token))
                    } catch (failure: GmailException) {
                        if (failure.error == GmailError.NOT_FOUND) null else throw failure
                    }
                }
            }.awaitAll()
        }.filterNotNull()
        return GmailPage(messages, nextPageToken)
    }

    suspend fun wakeMailbox(token: String): GmailWakeMailbox {
        val profile = get("profile", emptyList(), token)
        val email = profile.requiredString("emailAddress")
        if (email.isBlank()) invalid()
        return GmailWakeMailbox(email, historyId(profile.requiredString("historyId")))
    }

    /** One bounded inbox history page. Reads message metadata only. */
    suspend fun wakeHistory(startHistoryId: String, token: String): GmailWakeHistory {
        var latest = historyId(startHistoryId)
        val listing = get("history", listOf(
            "startHistoryId" to latest, "historyTypes" to "messageAdded",
            "labelId" to "INBOX", "maxResults" to "20",
        ), token)
        val ids = linkedSetOf<String>()
        for (raw in listing.optionalArray("history").orEmpty()) {
            val entry = raw as? JsonValue.Obj ?: invalid()
            val entryId = historyId(entry.requiredString("id"))
            val additions = entry.optionalArray("messagesAdded").orEmpty().mapNotNull { added ->
                val message = (added as? JsonValue.Obj)?.optionalObject("message") ?: invalid()
                val labels = message.optionalArray("labelIds")
                if (labels != null && labels.none { (it as? JsonValue.Str)?.value == "INBOX" }) null
                else message.requiredString("id")
            }
            if ((ids + additions).size > 20) {
                // Advance only through whole history entries. A partial entry
                // cannot safely share a cursor with its unread messages.
                if (ids.isEmpty()) invalid()
                break
            }
            ids += additions
            if (entryId.toBigInteger() > latest.toBigInteger()) latest = entryId
        }
        val summaries = coroutineScope {
            ids.map { id ->
                async {
                    try {
                        summary(getMessage(id, "metadata", token))
                    } catch (failure: GmailException) {
                        if (failure.error == GmailError.NOT_FOUND) null else throw failure
                    }
                }
            }.awaitAll().filterNotNull()
        }
        return GmailWakeHistory(latest, summaries)
    }

    private fun historyId(value: String): String {
        if (value.length !in 1..20 || value.any { it !in '0'..'9' }) invalid()
        return value
    }

    suspend fun message(id: String, token: String): GmailMessage {
        val raw = getMessage(id, "full", token)
        val payload = raw.optionalObject("payload")?.let(::part)
        return GmailMessage(summary(raw, payload), payload?.messageBody() ?: GmailBody.Unavailable)
    }

    private suspend fun getMessage(id: String, format: String, token: String): JsonValue.Obj {
        if (!isMessageId(id)) throw GmailException(GmailError.INVALID_RESPONSE)
        val query = buildList {
            add("format" to format)
            if (format == "metadata") {
                add("metadataHeaders" to "From")
                add("metadataHeaders" to "Subject")
            }
        }
        return get("messages/$id", query, token)
    }

    private suspend fun get(path: String, query: List<Pair<String, String>>, token: String): JsonValue.Obj {
        val url = buildUrl(path, query)
        // iOS lets a transport error propagate; Android maps it to
        // serviceUnavailable so the page shows the generic retry notice.
        val response = try {
            transport.get(url, mapOf("Authorization" to "Bearer $token"))
        } catch (_: IOException) {
            throw GmailException(GmailError.SERVICE_UNAVAILABLE)
        }
        when (response.status) {
            200 -> Unit
            401 -> throw GmailException(GmailError.UNAUTHORIZED)
            403 -> throw GmailException(GmailError.FORBIDDEN)
            404 -> throw GmailException(GmailError.NOT_FOUND)
            else -> throw GmailException(GmailError.SERVICE_UNAVAILABLE)
        }
        return GatewayJson.parseOrNull(response.body) as? JsonValue.Obj ?: invalid()
    }

    // ---- decoding (mirrors the Swift Decodable structs: required fields must
    // be strings, optional ones absent, null or of the right type)

    private class Header(val name: String, val value: String)

    private class Part(
        val mimeType: String?,
        val filename: String?,
        val headers: List<Header>?,
        val data: String?,
        val parts: List<Part>?,
    ) {
        fun header(name: String): String? = headers?.firstOrNull { it.name.equals(name, ignoreCase = true) }?.value

        fun messageBody(): GmailBody {
            text("text/plain")?.let { return GmailBody.Plain(it) }
            text("text/html")?.let { return GmailBody.Html(it) }
            return GmailBody.Unavailable
        }

        private fun text(mime: String): String? {
            if (!filename.isNullOrEmpty()) return null
            if (header("Content-Disposition")?.lowercase()?.startsWith("attachment") == true) return null
            val encoded = data
            if (mimeType?.lowercase() == mime && encoded != null) {
                val bytes = decodeBase64Url(encoded) ?: return null
                if (bytes.isEmpty() || bytes.size > MAX_BODY_BYTES) return null
                return String(bytes, Charsets.UTF_8)
            }
            if (mimeType?.lowercase()?.startsWith("multipart/") != true) return null
            return parts?.firstNotNullOfOrNull { it.text(mime) }
        }
    }

    private fun summary(raw: JsonValue.Obj): GmailSummary =
        summary(raw, raw.optionalObject("payload")?.let(::part))

    private fun summary(raw: JsonValue.Obj, payload: Part?): GmailSummary {
        val id = raw.requiredString("id")
        val date = raw.optionalString("internalDate")?.let { it.toLongOrNull() ?: it.toDoubleOrNull()?.toLong() }
        return GmailSummary(
            id = id,
            sender = payload?.header("From") ?: "",
            subject = payload?.header("Subject") ?: "",
            dateMillis = date,
        )
    }

    private fun part(value: JsonValue.Obj): Part = Part(
        mimeType = value.optionalString("mimeType"),
        filename = value.optionalString("filename"),
        headers = value.optionalArray("headers")?.map { header ->
            val obj = header as? JsonValue.Obj ?: invalid()
            Header(obj.requiredString("name"), obj.requiredString("value"))
        },
        data = value.optionalObject("body")?.optionalString("data"),
        parts = value.optionalArray("parts")?.map { part(it as? JsonValue.Obj ?: invalid()) },
    )

    companion object {
        private const val MAX_BODY_BYTES = 2_000_000

        internal fun isMessageId(id: String): Boolean =
            id.isNotEmpty() && id.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' || it == '_' }

        internal fun buildUrl(path: String, query: List<Pair<String, String>>): String {
            val out = StringBuilder("https://gmail.googleapis.com/gmail/v1/users/me/").append(path)
            query.forEachIndexed { index, (name, value) ->
                out.append(if (index == 0) '?' else '&')
                out.append(encodeQueryComponent(name)).append('=').append(encodeQueryComponent(value))
            }
            return out.toString()
        }

        /** RFC 3986: every byte outside the unreserved set is percent-encoded, so `+` → `%2B` and space → `%20`. */
        internal fun encodeQueryComponent(value: String): String {
            val out = StringBuilder()
            for (byte in value.toByteArray(Charsets.UTF_8)) {
                val c = byte.toInt() and 0xFF
                val ch = c.toChar()
                if (ch in 'a'..'z' || ch in 'A'..'Z' || ch in '0'..'9' || ch == '-' || ch == '.' || ch == '_' || ch == '~') {
                    out.append(ch)
                } else {
                    out.append('%').append(HEX[c shr 4]).append(HEX[c and 0x0F])
                }
            }
            return out.toString()
        }

        internal fun decodeBase64Url(encoded: String): ByteArray? {
            val base64 = StringBuilder(encoded.replace('-', '+').replace('_', '/'))
            repeat((4 - base64.length % 4) % 4) { base64.append('=') }
            return try {
                Base64.getDecoder().decode(base64.toString())
            } catch (_: IllegalArgumentException) {
                null
            }
        }

        private val HEX = "0123456789ABCDEF".toCharArray()

        private fun invalid(): Nothing = throw GmailException(GmailError.INVALID_RESPONSE)

        private fun JsonValue.Obj.requiredString(name: String): String = string(name) ?: invalid()

        private fun JsonValue.Obj.optionalString(name: String): String? = when (val value = get(name)) {
            null, JsonValue.Null -> null
            is JsonValue.Str -> value.value
            else -> invalid()
        }

        private fun JsonValue.Obj.optionalObject(name: String): JsonValue.Obj? = when (val value = get(name)) {
            null, JsonValue.Null -> null
            is JsonValue.Obj -> value
            else -> invalid()
        }

        private fun JsonValue.Obj.optionalArray(name: String): List<JsonValue>? = when (val value = get(name)) {
            null, JsonValue.Null -> null
            is JsonValue.Arr -> value.items
            else -> invalid()
        }
    }
}
