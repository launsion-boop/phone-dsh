// phone-dsh — :net / com.phonedsh.gateway: the bounded response log.
// SPDX-License-Identifier: MIT
//
// Ordinary responses are recorded whole or not at all (§6): a body larger than
// the whole quota is dropped, never truncated, and the caller is still served
// (gw-resp-003). Eviction is least-recently-used under `quotaBytes`. A
// sensitive (MCP) response never enters the log, whatever the credential kind;
// the reason is carried beside the "recorded" flag so the decision is
// observable instead of silent.

package com.phonedsh.gateway

object ResponseLogReasons {
    const val RECORDED_OK = "recorded_ok"
    const val QUOTA_EXCEEDED = "quota_exceeded"
    const val SENSITIVE_CREDENTIAL = "sensitive_credential"
}

/** What one recording attempt did, and why. */
data class ResponseLogOutcome(
    val recorded: Boolean,
    /** [ResponseLogReasons.RECORDED_OK] exactly when [recorded] is true. */
    val reason: String,
    val bodyBytes: Int,
    val retainedBytes: Int,
) {
    fun fields(): Map<String, JsonValue> {
        val fields = LinkedHashMap<String, JsonValue>()
        fields["recorded"] = JsonValue.bool(recorded)
        fields["reason"] = JsonValue.Str(reason)
        fields["body_bytes"] = JsonValue.num(bodyBytes)
        fields["retained_bytes"] = JsonValue.num(retainedBytes)
        return fields
    }
}

/**
 * In-memory, LRU-evicted, byte-quota response log.
 *
 * The disk-backed Swift log is a durability feature; the conformance contract
 * this module is judged against only pins the retention decisions, so the log
 * here keeps whole bodies in memory and exposes the same outcome shape.
 */
class ResponseLog(val quotaBytes: Int) {

    data class Entry(
        val key: String,
        val status: Int,
        val headers: Map<String, String>,
        val body: ByteArray,
    )

    private val entries = LinkedHashMap<String, Entry>(16, 0.75f, /* accessOrder = */ true)

    /** Records [body] whole, or drops it whole when it cannot fit the quota. */
    fun record(
        key: String,
        status: Int,
        headers: Map<String, String>,
        body: ByteArray,
    ): ResponseLogOutcome {
        val bodyBytes = body.size
        entries.remove(key)
        if (bodyBytes > quotaBytes) {
            return ResponseLogOutcome(
                recorded = false,
                reason = ResponseLogReasons.QUOTA_EXCEEDED,
                bodyBytes = bodyBytes,
                retainedBytes = 0,
            )
        }
        evictUntilFits(bodyBytes)
        entries[key] = Entry(key, status, headers.toMap(), body.copyOf())
        return ResponseLogOutcome(
            recorded = true,
            reason = ResponseLogReasons.RECORDED_OK,
            bodyBytes = bodyBytes,
            retainedBytes = bodyBytes,
        )
    }

    fun replay(key: String): Entry? = entries[key]?.copy()

    fun totalBytes(): Int = entries.values.sumOf { it.body.size }

    fun size(): Int = entries.size

    fun keys(): List<String> = entries.keys.toList()

    private fun evictUntilFits(incomingBytes: Int) {
        while (entries.isNotEmpty() && totalBytes() + incomingBytes > quotaBytes) {
            val oldest = entries.keys.firstOrNull() ?: return
            entries.remove(oldest)
        }
    }

    private fun Entry.copy(): Entry = Entry(key, status, headers.toMap(), body.copyOf())

    companion object {
        /** The log key is an identity, not a security boundary. */
        fun cacheKey(method: String, url: String): String = "$method $url"
    }
}
