// phone-dsh — :net / com.phonedsh.gateway: sensitive MCP response bodies.
// SPDX-License-Identifier: MIT
//
// Sensitivity is a property of the call, not of the credential kind (§6): the
// exact-URL MCP grant, the Worker placeholder and a host-managed `.headers` map
// all mark an MCP call, so a scalar bearer MCP call is redacted and excluded
// from the disk log exactly like a header map (gw-resp-004). The injected exact
// values are the redaction set; JSON is rewritten structurally so the JSON-RPC
// `id` survives and re-encoded with sorted keys so the bytes are reproducible
// (gw-resp-002, gw-resp-005). A non-2xx body is replaced by one controlled
// diagnostic and the status stays the diagnostic (gw-resp-001). Invalid UTF-8
// falls back to exact byte replacement; a 2xx body beyond the buffered bound
// fails closed.

package com.phonedsh.gateway

import java.nio.charset.StandardCharsets

/** Decides whether one exchange takes the sensitive response path. */
interface SensitiveCallClassifier {
    fun isSensitive(
        workerHeaders: Map<String, String>,
        credential: GatewayCredential,
        mcpAdmitted: Boolean,
    ): Boolean
}

/** The real rule: grant, placeholder, or a non-empty host-managed map. */
class McpCallClassifier : SensitiveCallClassifier {
    override fun isSensitive(
        workerHeaders: Map<String, String>,
        credential: GatewayCredential,
        mcpAdmitted: Boolean,
    ): Boolean {
        if (mcpAdmitted) return true
        if (workerHeaders.values.any { it == GatewayRequestHeaders.HOST_MANAGED_PLACEHOLDER }) return true
        return credential is GatewayCredential.Headers && credential.headers.isNotEmpty()
    }
}

/** Encodes a redacted JSON value; production pins sorted keys. */
fun interface JsonCanonicalizer {
    fun encode(value: JsonValue): ByteArray
}

/** Sorted-key canonical encoding: the same input always yields the same bytes. */
object SortedKeyCanonicalizer : JsonCanonicalizer {
    override fun encode(value: JsonValue): ByteArray = GatewayJson.canonicalBytes(value)
}

/**
 * The response-body half of the sensitive path: structural rewrite, sorted-key
 * re-encode, fail closed. [JsonCanonicalizer] is the substitutable seam (the
 * sorted-key encoder is the only production one); this class is the one rule.
 */
class CanonicalSensitiveBodyRedactor(
    private val canonicalizer: JsonCanonicalizer = SortedKeyCanonicalizer,
    val maxBufferedBodyBytes: Int = DEFAULT_MAX_BUFFERED_BODY_BYTES,
) {

    /** HEAD and 1xx/204/205/304 carry no body at all. */
    fun statusForbidsBody(status: Int, method: String): Boolean {
        if (method.equals("HEAD", ignoreCase = true)) return true
        return status in 100..199 || status == 204 || status == 205 || status == 304
    }

    fun controlledDiagnostic(status: Int): ByteArray = diagnostic(
        "MCP upstream returned HTTP $status; response body withheld",
    )

    fun controlledOversizeDiagnostic(): ByteArray = diagnostic(
        "MCP upstream response exceeded the host-managed body limit; response body withheld",
    )

    private fun diagnostic(message: String): ByteArray {
        val value = JsonValue.obj(
            "jsonrpc" to JsonValue.Str("2.0"),
            "id" to JsonValue.Null,
            "error" to JsonValue.obj(
                "code" to JsonValue.Num(CONTROLLED_ERROR_CODE.toString()),
                "message" to JsonValue.Str(message),
            ),
        )
        return canonicalizer.encode(value)
    }

    fun sanitizeBufferedBody(body: ByteArray, secrets: List<String>): ByteArray {
        val normalized = GatewayCredential.sortSecrets(secrets)
        if (body.isEmpty() || normalized.isEmpty()) return body
        val text = GatewayJson.decodeUtf8(body)
        if (text == null) {
            // Not UTF-8: replace the exact injected byte sequences; there is no
            // JSON framing left to keep valid.
            return redactBytes(body, normalized)
        }
        val parsed = GatewayJson.parseOrNull(text)
            ?: return redactText(text, normalized).toByteArray(StandardCharsets.UTF_8)
        val (redacted, changed) = redactJson(parsed, normalized)
        if (!changed) return body
        return try {
            canonicalizer.encode(redacted)
        } catch (exception: RuntimeException) {
            controlledDiagnostic(200)
        }
    }

    /** Rewrites string values and keys; returns the value plus "anything changed". */
    fun redactJson(value: JsonValue, secrets: List<String>): Pair<JsonValue, Boolean> {
        when (value) {
            JsonValue.Null -> return value to false
            is JsonValue.Bool -> return value to false
            is JsonValue.Str -> {
                val redacted = redactText(value.value, secrets)
                return (if (redacted == value.value) value else JsonValue.Str(redacted)) to
                    (redacted != value.value)
            }
            is JsonValue.Num -> {
                // A numeric credential can be echoed as a JSON number; compare
                // the exact token, and emit a string when it is rewritten.
                val redacted = redactText(value.literal, secrets)
                return if (redacted == value.literal) {
                    value to false
                } else {
                    JsonValue.Str(redacted) to true
                }
            }
            is JsonValue.Arr -> {
                var changed = false
                val items = ArrayList<JsonValue>(value.items.size)
                for (item in value.items) {
                    val (redacted, itemChanged) = redactJson(item, secrets)
                    items.add(redacted)
                    changed = changed || itemChanged
                }
                return JsonValue.Arr(items) to changed
            }
            is JsonValue.Obj -> {
                var changed = false
                // Keyed by the redacted output name: two different input names
                // that redact to the same text collapse, like Swift's dictionary.
                val members = LinkedHashMap<String, JsonValue>()
                for (member in value.members) {
                    var outputName = member.name
                    if (member.name !in PROTECTED_JSON_KEYS) {
                        outputName = redactText(member.name, secrets)
                        changed = changed || outputName != member.name
                    }
                    val (redacted, memberChanged) = redactJson(member.value, secrets)
                    members[outputName] = redacted
                    changed = changed || memberChanged
                }
                return JsonValue.obj(members.map { JsonValue.Member(it.key, it.value) }) to changed
            }
        }
    }

    private fun redactText(text: String, secrets: List<String>): String {
        var result = text
        for (secret in secrets) {
            if (secret.isEmpty()) continue
            result = result.replace(secret, "[redacted]")
        }
        return result
    }

    /**
     * Exact byte replacement for a non-UTF-8 body.
     *
     * The scan resumes after each inserted replacement: restarting from the
     * beginning after a short injected value (for example `a`) would loop
     * forever inside `[redacted]`.
     */
    fun redactBytes(body: ByteArray, secrets: List<String>): ByteArray {
        val replacement = "[redacted]".toByteArray(StandardCharsets.UTF_8)
        var result = body
        for (secret in secrets) {
            if (secret.isEmpty()) continue
            result = replaceBytes(result, secret.toByteArray(StandardCharsets.UTF_8), replacement)
        }
        return result
    }

    private fun replaceBytes(body: ByteArray, needle: ByteArray, replacement: ByteArray): ByteArray {
        if (needle.isEmpty()) return body
        val out = java.io.ByteArrayOutputStream(body.size)
        var cursor = 0
        while (cursor < body.size) {
            val match = indexOf(body, needle, cursor)
            if (match < 0) {
                out.write(body, cursor, body.size - cursor)
                return out.toByteArray()
            }
            out.write(body, cursor, match - cursor)
            out.write(replacement)
            cursor = match + needle.size
        }
        return out.toByteArray()
    }

    private fun indexOf(body: ByteArray, needle: ByteArray, start: Int): Int {
        if (needle.isEmpty()) return -1
        val last = body.size - needle.size
        var index = start
        while (index <= last) {
            var offset = 0
            while (offset < needle.size && body[index + offset] == needle[offset]) offset++
            if (offset == needle.size) return index
            index++
        }
        return -1
    }

    companion object {
        const val CONTROLLED_ERROR_CODE = -32000
        const val DEFAULT_MAX_BUFFERED_BODY_BYTES = 4 * 1024 * 1024

        /** JSON-RPC/MCP field names that carry protocol meaning and survive. */
        val PROTECTED_JSON_KEYS: Set<String> = setOf(
            "jsonrpc", "id", "result", "error", "code", "message", "data", "content",
            "type", "text", "isError", "name", "description", "title", "uri",
            "mimeType", "blob", "resource", "structuredContent", "tools",
            "inputSchema", "outputSchema", "arguments", "params", "method", "_meta",
            "annotations", "audience", "priority", "lastModified", "nextCursor",
        )
    }
}
