// SPDX-License-Identifier: MIT
package com.phonedsh.domain.connector.lan

import java.nio.CharBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Locale

/** A validated advertisement is still untrusted discovery data, not a grant. */
public data class LanDeviceCandidate(
    val id: String,
    val name: String,
    val url: String,
)

/**
 * Decodes the existing P07 LAN profile without opening a socket or authorizing a device.
 *
 * [txt] is the original DNS-SD length-prefixed byte sequence, not a dictionary:
 * converting it to key/value pairs first would erase duplicate profile entries.
 * [host] is the SRV hostname, not a service instance name or resolved address.
 * [LanMdnsBrowser] is the transport-side caller that supplies those values intact.
 */
internal object LanDiscoveryDecoder {
    private val profileKey = "profile".toByteArray(StandardCharsets.US_ASCII)
    private val profileValue = "pdsh-mcp-1".toByteArray(StandardCharsets.US_ASCII)

    fun decode(service: String, host: String, port: Int, txt: ByteArray): LanDeviceCandidate? {
        if (service.isEmpty() || service.length > 63 || serviceUtf8Length(service) !in 1..63) return null
        if (port !in 1..65535 || !validProfile(txt)) return null
        val hostname = hostname(host) ?: return null
        val portPart = if (port == 443) "" else ":$port"
        return LanDeviceCandidate(
            id = "$service@$hostname:$port",
            name = service,
            url = "https://$hostname$portPart/mcp",
        )
    }

    private fun serviceUtf8Length(value: String): Int = try {
        StandardCharsets.UTF_8.newEncoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .encode(CharBuffer.wrap(value))
            .remaining()
    } catch (_: CharacterCodingException) {
        -1
    }

    /** lan-mcp.md `canon`: the one hostname used for URL, SNI and certificate name. */
    fun hostname(value: String): String? {
        if (value.length > 254 || value.any { it.code >= 128 }) return null
        val host = (if (value.endsWith('.')) value.dropLast(1) else value).lowercase(Locale.ROOT)
        if (host.isEmpty() || host.length > 253) return null
        val labels = host.split('.')
        for (label in labels) {
            if (label.length !in 1..63 || !isAsciiAlphaNumeric(label.first()) ||
                !isAsciiAlphaNumeric(label.last()) ||
                label.any { !isAsciiAlphaNumeric(it) && it != '-' }
            ) return null
        }
        // lan-mcp.md canon step 4: A-labels are excluded because URL/IDNA
        // runtimes disagree on their validity; no IDNA mapping is attempted.
        if (labels.any { it.startsWith("xn--") }) return null
        // Numeric final labels may be reinterpreted as IPv4 by URL/resolver
        // stacks; reject them even if they are syntactically valid DNS labels.
        val last = labels.last()
        if (last.all { it in '0'..'9' } ||
            (last.startsWith("0x") && last.drop(2).all { it in '0'..'9' || it in 'a'..'f' })
        ) return null
        return host
    }

    private fun isAsciiAlphaNumeric(value: Char): Boolean = value in 'a'..'z' || value in '0'..'9'

    private fun validProfile(txt: ByteArray): Boolean {
        var offset = 0
        var found = false
        var valid = false
        while (offset < txt.size) {
            val length = txt[offset].toInt() and 0xff
            offset++
            if (length > txt.size - offset) return false
            val end = offset + length
            var separator = offset
            while (separator < end && txt[separator] != '='.code.toByte()) separator++
            if (asciiKeyEquals(txt, offset, separator, profileKey)) {
                if (found || separator == end) return false
                found = true
                val valueStart = separator + 1
                valid = end - valueStart == profileValue.size &&
                    profileValue.indices.all { txt[valueStart + it] == profileValue[it] }
            }
            offset = end
        }
        return found && valid
    }

    private fun asciiKeyEquals(bytes: ByteArray, start: Int, end: Int, expected: ByteArray): Boolean {
        if (end - start != expected.size) return false
        for (index in expected.indices) {
            val value = bytes[start + index].toInt() and 0xff
            val lowercase = if (value in 'A'.code..'Z'.code) value + 32 else value
            if (lowercase != expected[index].toInt()) return false
        }
        return true
    }
}
