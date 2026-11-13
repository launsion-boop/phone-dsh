// SPDX-License-Identifier: MIT
package com.phonedsh.bot.gateway

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.attachments.BotWorkspaceLayout
import com.phonedsh.bot.authz.BotApprovalCoordinator
import com.phonedsh.bot.authz.BotArgumentsDigest
import java.security.SecureRandom

/** One `/identity/register` attribution (`BotAttribution.swift`). */
public data class BotAttribution(
    public val id: String,
    public val sessionId: String,
    public val incarnation: String,
    public val callId: String,
    public val name: String,
    public val argsDigest: String,
    public val runtimeId: String?,
    public val createdAt: Long,
    public val expiresAt: Long,
) {
    public fun toJson(): JsonObject {
        val members = linkedMapOf<String, JsonValue>(
            "id" to JsonString(id),
            "sessionId" to JsonString(sessionId),
            "incarnation" to JsonString(incarnation),
            "callId" to JsonString(callId),
            "name" to JsonString(name),
            "argsDigest" to JsonString(argsDigest),
            "createdAt" to BotJson.number(createdAt),
            "expiresAt" to BotJson.number(expiresAt),
        )
        runtimeId?.let { members["runtimeId"] = JsonString(it) }
        return JsonObject(members)
    }
}

public class BotAttributionException(
    public val code: String,
    message: String,
) : Exception(message)

/**
 * The D13 attribution registry.
 *
 * TTL is the 300 s approval timeout plus 30 s transport slack, so an approval
 * approved near the deadline can still be claimed. Entries bind
 * `(sessionId, incarnation, callId, name, argsDigest, scopedRuntimeId)`;
 * `workerRestarted()` in the runtime advances the generation and removes the
 * previous scoped runtime's entries.
 */
public class BotAttributionRegistry(
    private val now: () -> Long = { System.currentTimeMillis() },
    public val ttlMilliseconds: Long = DEFAULT_TTL_MILLISECONDS,
    public val maximumEntries: Int = DEFAULT_MAXIMUM_ENTRIES,
    private val random: SecureRandom = SecureRandom(),
) {
    init {
        require(ttlMilliseconds > 0) { "ttlMilliseconds must be positive" }
        require(maximumEntries > 0) { "maximumEntries must be positive" }
    }

    private val entries: LinkedHashMap<String, BotAttribution> = LinkedHashMap()

    @Synchronized
    public fun count(): Int {
        prune()
        return entries.size
    }

    @Synchronized
    public fun register(
        sessionId: String,
        incarnation: String,
        callId: String,
        name: String,
        arguments: JsonValue = JsonObject(emptyMap()),
        argsDigest: String? = null,
        runtimeId: String? = null,
        expiresAt: Long? = null,
        ttlMilliseconds: Long? = null,
    ): BotAttribution {
        val session = identifier(sessionId, "sessionId")
        val generation = identifier(incarnation, "incarnation")
        val call = identifier(callId, "callId")
        val toolName = identifier(name, "name")
        val runtime = optionalIdentifier(runtimeId, "runtimeId")
        val digest = argsDigest?.let(BotArgumentsDigest::validated)
            ?: BotArgumentsDigest.string(arguments)
        val timestamp = now()
        val expiry = if (expiresAt != null) {
            expiresAt
        } else {
            val ttl = ttlMilliseconds ?: this.ttlMilliseconds
            if (ttl <= 0) {
                throw BotAttributionException("invalidInput:ttlMilliseconds", "ttlMilliseconds must be positive")
            }
            try {
                Math.addExact(timestamp, ttl)
            } catch (_: ArithmeticException) {
                throw BotAttributionException("invalidInput:expiresAt", "expiresAt overflow")
            }
        }
        if (expiry <= timestamp) {
            throw BotAttributionException("invalidInput:expiresAt", "expiresAt must be greater than now")
        }
        prune()
        if (entries.values.any {
                it.sessionId == session && it.incarnation == generation &&
                    it.argsDigest == digest && it.name == toolName && it.runtimeId == runtime
            }
        ) {
            throw BotAttributionException("duplicate", "duplicate attribution")
        }
        if (entries.size >= maximumEntries) {
            throw BotAttributionException("full", "attribution registry is full")
        }
        val entry = BotAttribution(
            id = randomHexString(16),
            sessionId = session,
            incarnation = generation,
            callId = call,
            name = toolName,
            argsDigest = digest,
            runtimeId = runtime,
            createdAt = timestamp,
            expiresAt = expiry,
        )
        entries[entry.id] = entry
        return entry
    }

    @Synchronized
    public fun claim(
        sessionId: String,
        name: String,
        arguments: JsonValue = JsonObject(emptyMap()),
        argsDigest: String? = null,
        runtimeId: String? = null,
    ): BotAttribution? {
        val session = identifier(sessionId, "sessionId")
        val toolName = identifier(name, "name")
        val digest = argsDigest?.let(BotArgumentsDigest::validated)
            ?: BotArgumentsDigest.string(arguments)
        val runtime = optionalIdentifier(runtimeId, "runtimeId")
        prune()
        val matches = entries.values.filter {
            it.sessionId == session && it.name == toolName && it.argsDigest == digest &&
                (runtime == null || it.runtimeId == runtime)
        }
        if (matches.size != 1) return null
        val match = matches.first()
        entries.remove(match.id)
        return match
    }

    @Synchronized
    public fun claimByDigest(
        name: String? = null,
        arguments: JsonValue = JsonObject(emptyMap()),
        argsDigest: String? = null,
        runtimeId: String? = null,
    ): BotAttribution? {
        val toolName = name?.let { identifier(it, "name") }
        val digest = argsDigest?.let(BotArgumentsDigest::validated)
            ?: BotArgumentsDigest.string(arguments)
        val runtime = optionalIdentifier(runtimeId, "runtimeId")
        prune()
        val matches = entries.values.filter {
            (toolName == null || it.name == toolName) && it.argsDigest == digest &&
                (runtime == null || it.runtimeId == runtime)
        }
        if (matches.size != 1) return null
        val match = matches.first()
        entries.remove(match.id)
        return match
    }

    @Synchronized
    public fun get(id: String): BotAttribution? {
        prune()
        return entries[id]
    }

    /** Extends one live entry without publishing a duplicate id. */
    @Synchronized
    public fun refresh(
        id: String,
        ttlMilliseconds: Long? = null,
        maximumExpiry: Long? = null,
    ): BotAttribution? {
        prune()
        val entry = entries[id] ?: return null
        val timestamp = now()
        val ttl = ttlMilliseconds ?: this.ttlMilliseconds
        if (ttl <= 0) return entry
        val sum = try {
            Math.addExact(timestamp, ttl)
        } catch (_: ArithmeticException) {
            return entry
        }
        var expiry = sum
        if (maximumExpiry != null) expiry = minOf(expiry, maximumExpiry)
        if (expiry <= entry.expiresAt) return entry
        val refreshed = entry.copy(expiresAt = expiry)
        entries[id] = refreshed
        return refreshed
    }

    @Synchronized
    public fun cancel(id: String): Boolean = entries.remove(id) != null

    /** Removes registrations of one session whose incarnation is stale. */
    @Synchronized
    public fun revokeStale(sessionId: String, currentIncarnation: String): Int {
        val ids = entries.values.filter {
            it.sessionId == sessionId && it.incarnation != currentIncarnation
        }.map { it.id }
        for (id in ids) entries.remove(id)
        return ids.size
    }

    @Synchronized
    public fun revokeSession(sessionId: String): Int {
        val ids = entries.values.filter { it.sessionId == sessionId }.map { it.id }
        for (id in ids) entries.remove(id)
        return ids.size
    }

    @Synchronized
    public fun cancelRuntime(runtimeId: String): Int {
        val ids = entries.values.filter { it.runtimeId == runtimeId }.map { it.id }
        for (id in ids) entries.remove(id)
        return ids.size
    }

    @Synchronized
    public fun pendingCount(runtimeId: String? = null): Int {
        prune()
        return if (runtimeId == null) {
            entries.size
        } else {
            entries.values.count { it.runtimeId == runtimeId }
        }
    }

    @Synchronized
    public fun entriesFor(
        runtimeId: String,
        callId: String,
        sessionId: String? = null,
    ): List<BotAttribution> {
        prune()
        return entries.values.filter {
            it.runtimeId == runtimeId && it.callId == callId &&
                (sessionId == null || it.sessionId == sessionId)
        }
    }

    @Synchronized
    public fun prune(): Int {
        val timestamp = now()
        val ids = entries.values.filter { it.expiresAt <= timestamp }.map { it.id }
        for (id in ids) entries.remove(id)
        return ids.size
    }

    private fun identifier(value: String, name: String): String {
        val text = value.trim()
        if (text.isEmpty() || BotWorkspaceLayout.graphemeClusterCount(text) > 256) {
            throw BotAttributionException("invalidInput:$name", "$name must be non-empty and at most 256 characters")
        }
        return text
    }

    private fun optionalIdentifier(value: String?, name: String): String? {
        if (value == null) return null
        return identifier(value, name)
    }

    private fun randomHexString(byteCount: Int): String {
        val bytes = ByteArray(byteCount)
        random.nextBytes(bytes)
        val out = StringBuilder(byteCount * 2)
        for (byte in bytes) {
            out.append(HEX[(byte.toInt() shr 4) and 0x0F])
            out.append(HEX[byte.toInt() and 0x0F])
        }
        return out.toString()
    }

    public companion object {
        /** approval timeout (300,000 ms) + 30 s transport slack. */
        public const val DEFAULT_TTL_MILLISECONDS: Long =
            BotApprovalCoordinator.DEFAULT_TIMEOUT_MILLISECONDS + 30_000L
        public const val DEFAULT_MAXIMUM_ENTRIES: Int = 4_096
        private val HEX: CharArray = "0123456789abcdef".toCharArray()
    }
}
