// SPDX-License-Identifier: MIT
// Kotlin end of `Sources/PhoneDSHMail/MIME.swift`: minimal RFC 5322 / MIME
// reading (folded headers, RFC 2047 words in UTF-8/GBK/GB18030/Big5,
// multipart, base64, quoted-printable, HTML fallback) and UTF-8 text/plain
// writing.
package com.phonedsh.mail

import java.nio.charset.Charset
import java.text.SimpleDateFormat
import java.util.Base64
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

public class MimeHeaders(raw: ByteArray = ByteArray(0)) {
    /** Lower-cased name and raw value, in order. */
    public val fields: List<Pair<String, String>>

    init {
        val out = ArrayList<Pair<String, String>>()
        var name: String? = null
        var value = StringBuilder()
        for (rawLine in String(raw, Charsets.ISO_8859_1).split("\n")) {
            val line = rawLine.removeSuffix("\r")
            if (line.isEmpty()) continue
            if (line[0] == ' ' || line[0] == '\t') {
                if (name != null) value.append(' ').append(line.trim())
                continue
            }
            if (name != null) out.add(name to value.toString())
            val colon = line.indexOf(':')
            if (colon < 0) { name = null; continue }
            name = line.substring(0, colon).trim().lowercase()
            value = StringBuilder(line.substring(colon + 1).trim())
        }
        if (name != null) out.add(name to value.toString())
        fields = out
    }

    /** The first raw value (RFC 2047 still encoded). */
    public fun raw(name: String): String? = fields.firstOrNull { it.first == name.lowercase() }?.second

    /** The first value with encoded words decoded. */
    public operator fun get(name: String): String? = raw(name)?.let(Mime::decodeEncodedWords)
}

public data class MimeAttachment(val filename: String, val contentType: String, val size: Int)

public class MimeMessage(
    public val headers: MimeHeaders,
    public val text: String,
    public val isHtmlFallback: Boolean,
    public val attachments: List<MimeAttachment>,
)

public object Mime {
    private val gb18030: Charset = Charset.forName("GB18030")

    public fun parse(data: ByteArray): MimeMessage {
        val (headerData, body) = splitHeaderBody(data)
        val headers = MimeHeaders(headerData)
        val state = WalkState()
        walk(headers, body, state, 0)
        val plain = state.plain
        if (plain != null && plain.isNotBlank()) return MimeMessage(headers, plain, false, state.attachments)
        val html = state.html
        return MimeMessage(headers, html?.let(::htmlToText) ?: plain.orEmpty(), html != null, state.attachments)
    }

    private class WalkState {
        var plain: String? = null
        var html: String? = null
        val attachments = ArrayList<MimeAttachment>()
    }

    private fun walk(headers: MimeHeaders, body: ByteArray, state: WalkState, depth: Int) {
        if (depth >= 12) return
        val (type, params) = contentType(headers.raw("content-type") ?: "text/plain")
        val disposition = headers.raw("content-disposition")
        val filename = dispositionFilename(disposition) ?: params["name"]?.let(::decodeEncodedWords)
        val boundary = params["boundary"]
        if (type.startsWith("multipart/") && boundary != null) {
            for (part in splitMultipart(body, boundary)) {
                val (partHeaders, partBody) = splitHeaderBody(part)
                walk(MimeHeaders(partHeaders), partBody, state, depth + 1)
            }
            return
        }
        if (type == "message/rfc822") {
            val (innerHeaders, innerBody) = splitHeaderBody(body)
            walk(MimeHeaders(innerHeaders), innerBody, state, depth + 1)
            return
        }
        val decoded = decodeTransfer(body, headers.raw("content-transfer-encoding"))
        val isAttachment = disposition?.lowercase()?.startsWith("attachment") == true ||
            (filename != null && !type.startsWith("text/"))
        when {
            isAttachment -> state.attachments.add(MimeAttachment(filename ?: "attachment", type, decoded.size))
            type == "text/plain" && state.plain == null -> state.plain = decodeText(decoded, params["charset"])
            type == "text/html" && state.html == null -> state.html = decodeText(decoded, params["charset"])
            !type.startsWith("text/") -> state.attachments.add(MimeAttachment(filename ?: "part", type, decoded.size))
        }
    }

    internal fun splitHeaderBody(data: ByteArray): Pair<ByteArray, ByteArray> {
        var index = 0
        while (index < data.size) {
            if (data[index] == '\n'.code.toByte()) {
                if (index + 1 < data.size && data[index + 1] == '\n'.code.toByte()) {
                    return data.copyOfRange(0, index) to data.copyOfRange(index + 2, data.size)
                }
                if (index + 2 < data.size && data[index + 1] == '\r'.code.toByte() && data[index + 2] == '\n'.code.toByte()) {
                    return data.copyOfRange(0, index) to data.copyOfRange(index + 3, data.size)
                }
            }
            index++
        }
        return data to ByteArray(0)
    }

    internal fun splitMultipart(body: ByteArray, boundary: String): List<ByteArray> {
        val segments = String(body, Charsets.ISO_8859_1).split("--$boundary")
        if (segments.size < 2) return emptyList()
        val parts = ArrayList<ByteArray>()
        for (segment in segments.drop(1)) {
            if (segment.startsWith("--")) break
            var part = segment
            part = part.removePrefix("\r\n").removePrefix("\n")
            part = if (part.endsWith("\r\n")) part.dropLast(2) else part.removeSuffix("\n")
            parts.add(part.toByteArray(Charsets.ISO_8859_1))
        }
        return parts
    }

    /** `type/subtype` lower-cased plus parameters (names lower-cased, quotes removed, RFC 2231 decoded). */
    public fun contentType(value: String): Pair<String, Map<String, String>> {
        val pieces = splitParameters(value)
        val type = (pieces.firstOrNull() ?: "text/plain").trim().lowercase()
        val params = LinkedHashMap<String, String>()
        for (piece in pieces.drop(1)) {
            val equals = piece.indexOf('=')
            if (equals < 0) continue
            var name = piece.substring(0, equals).trim().lowercase()
            var raw = piece.substring(equals + 1).trim()
            if (raw.length >= 2 && raw.startsWith("\"") && raw.endsWith("\"")) raw = raw.substring(1, raw.length - 1)
            if (name.endsWith("*")) {
                name = name.dropLast(1)
                val parts = raw.split("'", limit = 3)
                if (parts.size == 3) raw = decodeText(percentDecode(parts[2]), parts[0])
            }
            params.putIfAbsent(name, raw)
        }
        return type to params
    }

    private fun dispositionFilename(value: String?): String? =
        value?.let { contentType(it).second["filename"]?.let(::decodeEncodedWords) }

    private fun splitParameters(value: String): List<String> {
        val result = ArrayList<String>()
        val current = StringBuilder()
        var quoted = false
        for (c in value) {
            if (c == '"') quoted = !quoted
            if (c == ';' && !quoted) { result.add(current.toString()); current.setLength(0); continue }
            current.append(c)
        }
        result.add(current.toString())
        return result.map { it.trim() }.filter { it.isNotEmpty() }
    }

    public fun decodeTransfer(data: ByteArray, encoding: String?): ByteArray = when (encoding?.trim()?.lowercase()) {
        "base64" -> try {
            Base64.getMimeDecoder().decode(String(data, Charsets.ISO_8859_1).filterNot { it.isWhitespace() })
        } catch (_: IllegalArgumentException) {
            ByteArray(0)
        }
        "quoted-printable" -> quotedPrintable(data, underscoreIsSpace = false)
        else -> data
    }

    internal fun quotedPrintable(data: ByteArray, underscoreIsSpace: Boolean): ByteArray {
        val out = java.io.ByteArrayOutputStream(data.size)
        var i = 0
        while (i < data.size) {
            val b = data[i]
            if (b == '='.code.toByte()) {
                if (i + 1 < data.size && data[i + 1] == '\n'.code.toByte()) { i += 2; continue }
                if (i + 2 < data.size && data[i + 1] == '\r'.code.toByte() && data[i + 2] == '\n'.code.toByte()) { i += 3; continue }
                if (i + 2 < data.size) {
                    val hex = String(data, i + 1, 2, Charsets.ISO_8859_1).toIntOrNull(16)
                    if (hex != null) { out.write(hex); i += 3; continue }
                }
            }
            out.write(if (underscoreIsSpace && b == '_'.code.toByte()) 0x20 else b.toInt() and 0xFF)
            i++
        }
        return out.toByteArray()
    }

    /** Decode bytes in a declared charset, falling back to UTF-8 then GB18030. */
    public fun decodeText(data: ByteArray, charset: String?): String {
        charsetFor(charset)?.let { return String(data, it) }
        val utf8 = Charsets.UTF_8.newDecoder()
        return try {
            utf8.decode(java.nio.ByteBuffer.wrap(data)).toString()
        } catch (_: java.nio.charset.CharacterCodingException) {
            String(data, gb18030)
        }
    }

    internal fun charsetFor(raw: String?): Charset? {
        val name = raw?.trim('"', ' ')?.lowercase() ?: return null
        return when (name) {
            "utf-8", "utf8", "us-ascii", "ascii" -> Charsets.UTF_8
            // GBK and GB2312 are subsets of GB18030; senders mislabel them often.
            "gb2312", "gbk", "gb18030", "x-gbk", "cp936" -> gb18030
            else -> try { Charset.forName(name) } catch (_: Exception) { null }
        }
    }

    private val encodedWord = Regex("=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?=")

    /** RFC 2047 encoded words; whitespace between adjacent encoded words is dropped. */
    public fun decodeEncodedWords(value: String): String {
        val matches = encodedWord.findAll(value).toList()
        if (matches.isEmpty()) return value
        val out = StringBuilder()
        var cursor = 0
        for (match in matches) {
            val gap = value.substring(cursor, match.range.first)
            if (cursor == 0 || !gap.all { it.isWhitespace() }) out.append(gap)
            val charset = match.groupValues[1].substringBefore('*')
            val payload = match.groupValues[3]
            val bytes = if (match.groupValues[2].uppercase() == "B") {
                try { Base64.getDecoder().decode(payload) } catch (_: IllegalArgumentException) { ByteArray(0) }
            } else {
                quotedPrintable(payload.toByteArray(Charsets.ISO_8859_1), underscoreIsSpace = true)
            }
            out.append(decodeText(bytes, charset))
            cursor = match.range.last + 1
        }
        out.append(value.substring(cursor))
        return out.toString()
    }

    /** Readable text from HTML: drops head/script/style, keeps line breaks. */
    public fun htmlToText(html: String): String {
        var text = html
        text = Regex("(?is)<(script|style|head)[^>]*>.*?</\\1>").replace(text, "")
        text = Regex("(?s)<!--.*?-->").replace(text, "")
        text = Regex("(?i)<br\\s*/?>|</p>|</div>|</tr>|</li>|</h[1-6]>").replace(text, "\n")
        text = Regex("<[^>]+>").replace(text, "")
        for ((entity, replacement) in listOf("&nbsp;" to " ", "&lt;" to "<", "&gt;" to ">", "&quot;" to "\"",
            "&#39;" to "'", "&apos;" to "'", "&amp;" to "&")) {
            text = text.replace(entity, replacement)
        }
        text = Regex("[ \\t]+").replace(text, " ")
        text = Regex("\\n\\s*\\n\\s*\\n+").replace(text, "\n\n")
        return text.trim()
    }

    internal fun percentDecode(value: String): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        var i = 0
        while (i < value.length) {
            val c = value[i]
            if (c == '%' && i + 2 < value.length) {
                val hex = value.substring(i + 1, i + 3).toIntOrNull(16)
                if (hex != null) { out.write(hex); i += 3; continue }
            }
            out.write(c.toString().toByteArray(Charsets.UTF_8))
            i++
        }
        return out.toByteArray()
    }

    /** One UTF-8 text/plain message. `bcc` is never written to the headers. */
    public fun compose(
        from: String,
        to: List<String>,
        cc: List<String>,
        subject: String,
        body: String,
        inReplyTo: String?,
        date: Date = Date(),
        messageId: String? = null,
    ): ByteArray {
        val domain = from.substringAfterLast('@', "localhost")
        val lines = ArrayList<String>()
        lines.add("From: $from")
        lines.add("To: ${to.joinToString(", ")}")
        if (cc.isNotEmpty()) lines.add("Cc: ${cc.joinToString(", ")}")
        lines.add("Subject: ${encodeWord(subject)}")
        lines.add("Date: ${rfc2822(date)}")
        lines.add("Message-ID: ${messageId ?: "<${UUID.randomUUID()}@$domain>"}")
        if (!inReplyTo.isNullOrEmpty()) {
            lines.add("In-Reply-To: $inReplyTo")
            lines.add("References: $inReplyTo")
        }
        lines.add("MIME-Version: 1.0")
        lines.add("Content-Type: text/plain; charset=UTF-8")
        lines.add("Content-Transfer-Encoding: base64")
        lines.add("")
        val encoded = Base64.getMimeEncoder(76, "\r\n".toByteArray()).encodeToString(body.toByteArray(Charsets.UTF_8))
        return (lines.joinToString("\r\n") + "\r\n" + encoded + "\r\n").toByteArray(Charsets.UTF_8)
    }

    /** RFC 2047 B-encoding when the value is not plain printable ASCII. */
    public fun encodeWord(value: String): String {
        if (value.all { it.code in 0x20..0x7E }) return value
        val words = ArrayList<String>()
        val chunk = StringBuilder()
        var index = 0
        while (index < value.length) {
            val next = value.offsetByCodePoints(index, 1)
            val piece = value.substring(index, next)
            if ((chunk.toString() + piece).toByteArray(Charsets.UTF_8).size > 45) { words.add(chunk.toString()); chunk.setLength(0) }
            chunk.append(piece)
            index = next
        }
        if (chunk.isNotEmpty()) words.add(chunk.toString())
        return words.joinToString("\r\n ") { "=?UTF-8?B?${Base64.getEncoder().encodeToString(it.toByteArray(Charsets.UTF_8))}?=" }
    }

    internal fun rfc2822(date: Date): String = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss Z", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }.format(date)

    private val addressPattern = Regex("[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}")

    /** Bare addresses from a header value such as `"张三" <a@b.com>, c@d.com`. */
    public fun addresses(value: String): List<String> = addressPattern.findAll(value).map { it.value }.toList()
}
