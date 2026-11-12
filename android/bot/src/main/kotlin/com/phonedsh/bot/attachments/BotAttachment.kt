// SPDX-License-Identifier: MIT
package com.phonedsh.bot.attachments

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJsonException
import com.phonedsh.bot.requiredLong
import com.phonedsh.bot.requiredString

/**
 * One file the user attached to a `chat` action. The field names and the
 * string values in `kind` follow dsh-bot `src/main/attachments.cjs`; the
 * phoneDSH prompt block is assembled from the same shape.
 */
public data class BotAttachment(
    public val name: String,
    public val path: String,
    public val size: Long,
    public val mimeType: String,
    public val kind: String,
) {
    public fun toJson(): JsonObject {
        val members = LinkedHashMap<String, JsonValue>()
        members["name"] = JsonString(name)
        members["path"] = JsonString(path)
        members["size"] = JsonNumber(size.toString())
        members["mimeType"] = JsonString(mimeType)
        members["kind"] = JsonString(kind)
        return JsonObject(members)
    }

    public companion object {
        public fun fromJson(value: JsonValue): BotAttachment {
            val members = (value as? JsonObject)?.members
                ?: throw BotJsonException("attachment must be an object")
            return BotAttachment(
                name = members.requiredString("name", "attachment.name"),
                path = members.requiredString("path", "attachment.path"),
                size = members.requiredLong("size", "attachment.size"),
                mimeType = members.requiredString("mimeType", "attachment.mimeType"),
                kind = members.requiredString("kind", "attachment.kind"),
            )
        }
    }
}

/** The frozen attachment policy (`golden/bot-attachments.json` `limits`). */
public object BotAttachmentPolicy {
    /** dsh-bot `MAX_ATTACHMENTS`. */
    public const val MAX_COUNT: Int = 10

    /** dsh-bot `MAX_ATTACHMENT_BYTES` (25 MiB). */
    public const val MAX_BYTES: Long = 25L * 1024L * 1024L

    /**
     * Mirrors dsh-bot `kindFor(name, mimeType)` exactly, including the
     * case-sensitive MIME prefix check and the extension fallback.
     */
    public fun kind(name: String, mimeType: String): String {
        val lower = name.lowercase()
        fun hasExtension(extensions: List<String>): Boolean =
            extensions.any { lower.endsWith(".$it") }
        if (mimeType.startsWith("image/") || hasExtension(listOf("png", "jpg", "jpeg", "gif", "webp", "heic"))) {
            return "image"
        }
        if (mimeType.startsWith("audio/") || hasExtension(listOf("mp3", "wav", "m4a", "aac", "ogg"))) {
            return "audio"
        }
        if (mimeType.startsWith("video/") || hasExtension(listOf("mp4", "mov", "webm", "mkv"))) {
            return "video"
        }
        if (mimeType == "application/pdf" || hasExtension(listOf("pdf"))) {
            return "pdf"
        }
        if (hasExtension(listOf("md", "markdown"))) {
            return "markdown"
        }
        if (hasExtension(listOf("csv", "xls", "xlsx", "numbers"))) {
            return "table"
        }
        if (hasExtension(listOf("json", "jsonl", "yml", "yaml"))) {
            return "json"
        }
        if (hasExtension(listOf("doc", "docx", "pages", "rtf"))) {
            return "document"
        }
        if (hasExtension(listOf("zip", "tar", "gz", "tgz", "rar", "7z"))) {
            return "archive"
        }
        return "file"
    }

    /**
     * Mirrors dsh-bot `safeName`: take the basename, replace every UTF-16 unit
     * outside `[\w.\- ()一-鿿]` with `_`, remove leading dots, cap at 120
     * characters and fall back to `file`.
     */
    public fun safeName(name: String): String {
        val raw = if (name.isEmpty()) "file" else name
        val base = raw.split('/', '\\').filter { it.isNotEmpty() }.lastOrNull() ?: "file"
        val cleaned = StringBuilder(base.length)
        for (unit in base) {
            val allowed = unit == '.' || unit == '-' || unit == '_' || unit == ' ' ||
                unit == '(' || unit == ')' ||
                unit in '0'..'9' || unit in 'A'..'Z' || unit in 'a'..'z' ||
                unit in '\u4E00'..'\u9FFF'
            cleaned.append(if (allowed) unit else '_')
        }
        var output = cleaned.toString()
        while (output.startsWith(".")) output = output.removePrefix(".")
        if (output.length > 120) output = output.substring(0, 120)
        return if (output.isEmpty()) "file" else output
    }
}
