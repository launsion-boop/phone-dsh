// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import java.security.MessageDigest

/** One invalid authz input; [code] is the stable lower-snake reason. */
public class BotAuthzException(
    public val code: String,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)

/**
 * `SHA-256(canonical JSON(arguments))` (`BotArgumentsDigest.swift`).
 *
 * The digest is over the Bot canonical encoder, not the platform JSON writer:
 * sorted object keys, `/` unescaped, no insignificant whitespace. The token is
 * lower-case hex and the resource suffix uses its first 16 characters.
 */
public object BotArgumentsDigest {
    public fun string(arguments: JsonValue = JsonObject(emptyMap())): String =
        digestOfUtf8(BotJson.canonical(arguments))

    public fun resourceSuffix(arguments: JsonValue = JsonObject(emptyMap())): String =
        "args=" + string(arguments).take(16)

    public fun digestOfUtf8(text: String): String {
        val bytes = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
        val out = StringBuilder(bytes.size * 2)
        for (byte in bytes) {
            out.append(HEX[(byte.toInt() shr 4) and 0x0F])
            out.append(HEX[byte.toInt() and 0x0F])
        }
        return out.toString()
    }

    /**
     * Accepts 64 hex characters case-insensitively and returns the lower-case
     * form. Anything else is `invalidInput:argsDigest`.
     */
    public fun validated(value: String): String {
        if (value.length != 64 || value.any { it !in '0'..'9' && it !in 'a'..'f' && it !in 'A'..'F' }) {
            throw BotAuthzException("invalidInput:argsDigest", "argsDigest must be 64 hex characters")
        }
        return value.lowercase()
    }

    public fun validatedOrNull(value: String): String? =
        try {
            validated(value)
        } catch (_: BotAuthzException) {
            null
        }

    private val HEX: CharArray = "0123456789abcdef".toCharArray()
}
