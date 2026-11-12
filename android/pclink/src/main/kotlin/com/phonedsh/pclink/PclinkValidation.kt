// SPDX-License-Identifier: MIT
// Normative PCLink value validation (§2.1, §2.2, §3.1, §5.6, §6).
package com.phonedsh.pclink

import java.text.Normalizer
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

object PclinkValidation {
    // ---- Names -----------------------------------------------------------

    /**
     * 1–64 UTF-8 bytes, NFC, no C0/C1/`Cf` character. A non-NFC value is
     * rejected rather than silently normalized (§2.1).
     */
    fun name(value: String) {
        val bytes = value.toByteArray(Charsets.UTF_8).size
        if (bytes < 1 || bytes > 64) {
            throw PclinkError.BadFrame("name must be 1-64 UTF-8 bytes (got $bytes)")
        }
        // Compare exact UTF-8 bytes: Kotlin String equality would also treat a
        // canonical re-composition as equal, and the contract requires rejecting
        // a decomposed value rather than accepting it.
        val normalized = Normalizer.normalize(value, Normalizer.Form.NFC)
        if (!normalized.toByteArray(Charsets.UTF_8).contentEquals(value.toByteArray(Charsets.UTF_8))) {
            throw PclinkError.BadFrame("name is not NFC")
        }
        var index = 0
        while (index < value.length) {
            val codePoint = value.codePointAt(index)
            index += Character.charCount(codePoint)
            // A wire value cannot carry a lone surrogate (the JSON parser
            // rejects it); reject a programmatically-built one too.
            if (codePoint in 0xD800..0xDFFF) {
                throw PclinkError.BadFrame("name contains an unpaired surrogate")
            }
            if (codePoint < 0x20 || codePoint in 0x7F..0x9F) {
                throw PclinkError.BadFrame("name contains a C0/C1 control character")
            }
            if (Character.getType(codePoint) == Character.FORMAT.toInt()) {
                throw PclinkError.BadFrame("name contains a Unicode format character")
            }
        }
    }

    // ---- Display text / error messages ---------------------------------

    /**
     * PCLink-owned display text (`message` in relay/rpc/session errors and
     * closes) keeps its byte cap and rejects a decoded U+0000. It is not a DSH
     * passthrough value (§2.3).
     */
    fun displayText(
        value: String,
        field: String,
        maximumBytes: Int,
        minimumBytes: Int = 0,
    ) {
        val bytes = value.toByteArray(Charsets.UTF_8).size
        if (bytes < minimumBytes || bytes > maximumBytes) {
            throw PclinkError.BadFrame("$field byte length")
        }
        if (value.indexOf('\u0000') >= 0) {
            throw PclinkError.BadFrame("$field contains U+0000")
        }
    }

    // ---- Machine ids / fingerprints ------------------------------------

    fun isMachineId(value: String): Boolean {
        if (value.length != 26) return false
        return value.all { character ->
            (character in 'a'..'z') || (character in '2'..'7')
        }
    }

    fun requireMachineId(value: String, field: String = "machineId") {
        if (!isMachineId(value)) throw PclinkError.BadFrame("$field is not a machineId")
    }

    /** `machineId[0:12]` as `xxxx-xxxx-xxxx` (§2.2). */
    fun fingerprint(machineId: String): String {
        if (!isMachineId(machineId)) throw PclinkError.BadFrame("bad machineId")
        return machineId.substring(0, 4) + "-" + machineId.substring(4, 8) + "-" +
            machineId.substring(8, 12)
    }

    /**
     * Normalizes an operator-typed fingerprint: ignore `-`, whitespace and case.
     * Returns the 12-character canonical lowercase value.
     */
    fun normalizeFingerprint(input: String): String {
        val out = StringBuilder()
        var index = 0
        while (index < input.length) {
            val codePoint = input.codePointAt(index)
            index += Character.charCount(codePoint)
            if (codePoint == '-'.code || Character.isWhitespace(codePoint) ||
                Character.isSpaceChar(codePoint)
            ) {
                continue
            }
            val lower = Character.toLowerCase(codePoint)
            val allowed = lower in 'a'.code..'z'.code || lower in '2'.code..'7'.code
            if (!allowed || lower > 0x7F) {
                throw PclinkError.BadFrame("invalid fingerprint character")
            }
            out.append(lower.toChar())
        }
        if (out.length != 12) throw PclinkError.BadFrame("fingerprint must be 12 characters")
        return out.toString()
    }

    fun fingerprintMatches(input: String, machineId: String): Boolean {
        val normalized = try {
            normalizeFingerprint(input)
        } catch (_: PclinkError) {
            return false
        }
        val expected = try {
            fingerprint(machineId)
        } catch (_: PclinkError) {
            return false
        }
        return expected.replace("-", "") == normalized
    }

    // ---- Origins ---------------------------------------------------------

    /**
     * Lowercase ASCII http(s) origin: no userinfo, path, query, fragment,
     * uppercase character, default port, trailing slash or more than 128
     * characters (§3.1).
     */
    fun origin(value: String) {
        if (value.toByteArray(Charsets.UTF_8).size > 128) {
            throw PclinkError.BadFrame("origin exceeds 128 characters")
        }
        if (value.any { it.code >= 0x80 }) {
            throw PclinkError.BadFrame("origin must be ASCII")
        }
        if (value != value.lowercase()) {
            throw PclinkError.BadFrame("origin must be lowercase")
        }
        val scheme = when {
            value.startsWith("https://") -> "https"
            value.startsWith("http://") -> "http"
            else -> throw PclinkError.BadFrame("origin is not http(s)")
        }
        val authority = value.substring(scheme.length + 3)
        if (authority.isEmpty()) throw PclinkError.BadFrame("origin has no host")
        if (authority.any { it == '/' || it == '?' || it == '#' || it == '@' || it == '\\' }) {
            throw PclinkError.BadFrame("origin has a path, query, fragment or userinfo")
        }
        val colon = authority.lastIndexOf(':')
        val host: String
        val portText: String?
        if (colon >= 0) {
            host = authority.substring(0, colon)
            portText = authority.substring(colon + 1)
        } else {
            host = authority
            portText = null
        }
        if (host.isEmpty()) throw PclinkError.BadFrame("origin has no host")
        if (!host.all { (it in 'a'..'z') || (it in '0'..'9') || it == '.' || it == '-' }) {
            throw PclinkError.BadFrame("origin host has an invalid character")
        }
        if (host.startsWith(".") || host.endsWith(".") || host.contains("..")) {
            throw PclinkError.BadFrame("origin host is malformed")
        }
        // The schema host pattern starts with [a-z0-9].
        if (host.first() !in 'a'..'z' && host.first() !in '0'..'9') {
            throw PclinkError.BadFrame("origin host is malformed")
        }
        if (portText != null) {
            if (portText.isEmpty() || portText.length > 5 || !portText.all { it in '0'..'9' }) {
                throw PclinkError.BadFrame("origin port is invalid")
            }
            val port = portText.toInt()
            if (port < 1 || port > 65_535) throw PclinkError.BadFrame("origin port is invalid")
            if ((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
                throw PclinkError.BadFrame("origin must omit the default port")
            }
        }
        // Production is wss/https. A plain `http` origin is only the explicit
        // loopback test carrier; anything else is not dialable.
        if (scheme == "http" && host != "127.0.0.1" && host != "localhost") {
            throw PclinkError.BadFrame("http origin is only allowed for loopback tests")
        }
    }

    /** `https` -> `wss`, `http` -> `ws`, with the `/` path (§3.1). */
    fun websocketUrl(origin: String): String {
        origin(origin)
        return if (origin.startsWith("https://")) {
            "wss://" + origin.removePrefix("https://") + "/"
        } else {
            "ws://" + origin.removePrefix("http://") + "/"
        }
    }

    // ---- Protocol ids and endpoints -------------------------------------

    fun isSessionId(value: String): Boolean {
        if (value.length != 22) return false
        return value.all { character ->
            (character in 'A'..'Z') || (character in 'a'..'z') ||
                (character in '0'..'9') || character == '-' || character == '_'
        }
    }

    fun isCorrelationId(value: String): Boolean {
        val bytes = value.toByteArray(Charsets.UTF_8)
        if (bytes.size !in 1..64) return false
        return value.all { character ->
            (character in 'A'..'Z') || (character in 'a'..'z') ||
                (character in '0'..'9') || character == '.' || character == '_' ||
                character == ':' || character == '-'
        }
    }

    private val ENDPOINT_PATTERN = Regex("^\\\$?[A-Za-z][A-Za-z0-9.]*(/[A-Za-z][A-Za-z0-9.]*)?$")

    /** `$?ns[/method]`, exact strings, no case folding (§6.1). */
    fun isEndpoint(value: String): Boolean = ENDPOINT_PATTERN.matches(value)

    // ---- SemVer (§5.6) --------------------------------------------------

    data class SemVer(
        val major: Int,
        val minor: Int,
        val patch: Int,
        val prerelease: List<String> = emptyList(),
    ) : Comparable<SemVer> {
        override fun toString(): String {
            val base = "$major.$minor.$patch"
            return if (prerelease.isEmpty()) base else base + "-" + prerelease.joinToString(".")
        }

        override fun compareTo(other: SemVer): Int {
            if (major != other.major) return major.compareTo(other.major)
            if (minor != other.minor) return minor.compareTo(other.minor)
            if (patch != other.patch) return patch.compareTo(other.patch)
            if (prerelease.isEmpty()) return if (other.prerelease.isEmpty()) 0 else 1
            if (other.prerelease.isEmpty()) return -1
            for ((left, right) in prerelease.zip(other.prerelease)) {
                if (left == right) continue
                val leftNumeric = left.all { it in '0'..'9' }
                val rightNumeric = right.all { it in '0'..'9' }
                if (leftNumeric && rightNumeric) {
                    // Numeric identifiers have no leading zeroes, so length then
                    // lexicographic order is the numeric order and does not
                    // overflow for an identifier above Int.MAX_VALUE.
                    if (left.length != right.length) return left.length.compareTo(right.length)
                    return left.compareTo(right)
                }
                if (leftNumeric) return -1
                if (rightNumeric) return 1
                return left.compareTo(right)
            }
            return prerelease.size.compareTo(other.prerelease.size)
        }

        companion object {
            private val PATTERN = Regex("^([0-9]+)\\.([0-9]+)\\.([0-9]+)(?:-([0-9A-Za-z.-]+))?$")

            fun parse(text: String): SemVer? {
                val match = PATTERN.matchEntire(text) ?: return null
                val majorText = match.groupValues[1]
                val minorText = match.groupValues[2]
                val patchText = match.groupValues[3]
                val major = majorText.toIntOrNull() ?: return null
                val minor = minorText.toIntOrNull() ?: return null
                val patch = patchText.toIntOrNull() ?: return null
                // Leading zeroes are not SemVer.
                if (major.toString() != majorText || minor.toString() != minorText ||
                    patch.toString() != patchText
                ) {
                    return null
                }
                val prerelease = ArrayList<String>()
                if (match.groupValues[4].isNotEmpty()) {
                    for (identifier in match.groupValues[4].split('.')) {
                        if (identifier.isEmpty()) return null
                        if (identifier.all { it in '0'..'9' } &&
                            identifier != "0" && identifier.startsWith("0")
                        ) {
                            return null
                        }
                        prerelease.add(identifier)
                    }
                }
                return SemVer(major, minor, patch, prerelease)
            }
        }
    }

    const val TESTED_DSH_RANGE = ">=0.2.2-rc.1 <0.3.0"
    val TESTED_DSH_MINIMUM = SemVer(0, 2, 2, listOf("rc", "1"))
    val TESTED_DSH_MAXIMUM_EXCLUSIVE = SemVer(0, 3, 0)

    fun dshVersionInTestedRange(version: SemVer): Boolean =
        version >= TESTED_DSH_MINIMUM && version < TESTED_DSH_MAXIMUM_EXCLUSIVE

    // ---- Timestamps ------------------------------------------------------

    private val TIMESTAMP_PATTERN = Regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
    private val TIMESTAMP_FORMAT = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'")
        .withZone(ZoneOffset.UTC)

    /** RFC 3339 UTC with second precision and a trailing `Z`. */
    fun isTimestamp(value: String): Boolean {
        if (!TIMESTAMP_PATTERN.matches(value)) return false
        val datePart = value.substring(0, 10)
        val timePart = value.substring(11, 19)
        val date = datePart.split('-').mapNotNull { it.toIntOrNull() }
        val time = timePart.split(':').mapNotNull { it.toIntOrNull() }
        if (date.size != 3 || time.size != 3) return false
        val year = date[0]
        val month = date[1]
        val day = date[2]
        if (year < 1 || month !in 1..12 || day !in 1..31) return false
        if (time[0] !in 0..23 || time[1] !in 0..59 || time[2] !in 0..59) return false
        return try {
            val local = LocalDate.of(year, month, day)
            local.year == year && local.monthValue == month && local.dayOfMonth == day
        } catch (_: RuntimeException) {
            false
        }
    }

    fun nowTimestamp(): String = TIMESTAMP_FORMAT.format(Instant.now().truncatedTo(ChronoUnit.SECONDS))
}
