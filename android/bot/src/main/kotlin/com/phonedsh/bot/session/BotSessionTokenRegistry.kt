// SPDX-License-Identifier: MIT
package com.phonedsh.bot.session

import java.security.MessageDigest
import java.security.SecureRandom
import java.text.BreakIterator
import java.util.Base64

/**
 * The host token registry model (`session-lifecycle.md` §8.2/§8.3).
 *
 * State is in memory only; [now] is injected so expiry vectors are
 * deterministic. A token is valid while `expiresAt > now`, never at equality.
 */
public class BotSessionTokenRegistry(
    private val now: () -> Long = { System.currentTimeMillis() },
    public val defaultTtlMilliseconds: Long = DEFAULT_TTL_MILLISECONDS,
    public val maximumTokens: Int = DEFAULT_MAXIMUM_TOKENS,
) {
    init {
        require(defaultTtlMilliseconds > 0) { "defaultTtlMilliseconds must be positive" }
        require(maximumTokens > 0) { "maximumTokens must be positive" }
    }

    private data class Record(
        val id: String,
        val digest: ByteArray,
        val principal: BotSessionPrincipal,
    )

    private val records: LinkedHashMap<String, Record> = LinkedHashMap()
    private val currentIncarnations: HashMap<String, String> = HashMap()
    private val random: SecureRandom = SecureRandom()

    /** Live record count after pruning expired records. */
    @Synchronized
    public fun count(): Int {
        prune()
        return records.size
    }

    /**
     * `issueSession`: revoke every existing token for the (trimmed) session id
     * first, then issue. At most one token per session is current, and every
     * re-sign or recovery rotates the incarnation.
     */
    @Synchronized
    public fun issueSession(
        botId: String,
        sessionId: String,
        kind: BotSessionKind,
        capabilities: List<String> = emptyList(),
        expiresAt: Long? = null,
        ttlMilliseconds: Long? = null,
    ): BotIssuedSessionToken {
        val validSessionId = identifier(sessionId, "sessionId")
        revokeSession(validSessionId)
        return issue(botId, validSessionId, kind, capabilities, expiresAt, ttlMilliseconds)
    }

    @Synchronized
    public fun issue(
        botId: String,
        sessionId: String,
        kind: BotSessionKind,
        capabilities: List<String> = emptyList(),
        expiresAt: Long? = null,
        ttlMilliseconds: Long? = null,
    ): BotIssuedSessionToken {
        val validBotId = identifier(botId, "botId")
        val validSessionId = identifier(sessionId, "sessionId")
        val validCapabilities = validateCapabilities(capabilities)
        val timestamp = now()
        val expiry: Long = if (expiresAt != null) {
            expiresAt
        } else {
            val ttl = ttlMilliseconds ?: defaultTtlMilliseconds
            if (ttl <= 0) throw BotSessionException("invalidInput:ttlMilliseconds", "ttlMilliseconds must be positive")
            try {
                Math.addExact(timestamp, ttl)
            } catch (_: ArithmeticException) {
                throw BotSessionException("invalidInput:expiresAt", "expiresAt overflow")
            }
        }
        if (expiry <= timestamp) {
            throw BotSessionException("invalidInput:expiresAt", "expiresAt must be greater than now")
        }
        prune()
        if (records.size >= maximumTokens) {
            throw BotSessionException("registryFull", "token registry is full")
        }
        val token = "dshg_" + randomUrlSafeString(32)
        val incarnation = randomHexString(16)
        val principal = BotSessionPrincipal(
            botId = validBotId,
            sessionId = validSessionId,
            kind = kind,
            capabilities = validCapabilities,
            expiresAt = expiry,
            incarnation = incarnation,
        )
        val id = randomHexString(16)
        records[id] = Record(id = id, digest = digest(token), principal = principal)
        currentIncarnations[validSessionId] = incarnation
        return BotIssuedSessionToken(token = token, principal = principal)
    }

    @Synchronized
    public fun lookup(token: String): BotSessionPrincipal? {
        if (token.isEmpty() || token.length > 512) return null
        val wanted = digest(token)
        var match: Record? = null
        for (record in records.values) {
            if (constantTimeEquals(record.digest, wanted)) match = record
        }
        val found = match ?: return null
        if (found.principal.expiresAt <= now()) {
            remove(found)
            return null
        }
        return found.principal
    }

    /** Accepts exactly `Bearer <token>` with an ASCII case-insensitive scheme. */
    @Synchronized
    public fun lookupBearer(header: String): BotSessionPrincipal? {
        val parts = header.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (parts.size != 2 || !parts[0].equals("Bearer", ignoreCase = true)) return null
        return lookup(parts[1])
    }

    @Synchronized
    public fun lookupSession(sessionId: String): BotSessionPrincipal? {
        val target = sessionId.trim()
        if (target.isEmpty()) return null
        val incarnation = currentIncarnations[target] ?: return null
        val match = records.values.firstOrNull {
            it.principal.sessionId == target && it.principal.incarnation == incarnation
        }
        if (match == null) {
            currentIncarnations.remove(target)
            return null
        }
        if (match.principal.expiresAt <= now()) {
            remove(match)
            return null
        }
        return match.principal
    }

    @Synchronized
    public fun revoke(token: String): Boolean {
        if (token.isEmpty() || token.length > 512) return false
        val wanted = digest(token)
        var match: Record? = null
        for (record in records.values) {
            if (constantTimeEquals(record.digest, wanted)) match = record
        }
        val found = match ?: return false
        remove(found)
        return true
    }

    @Synchronized
    public fun revokeSession(sessionId: String): Int =
        revokeWhere { it.principal.sessionId == sessionId.trim() }

    @Synchronized
    public fun revokeBot(botId: String): Int =
        revokeWhere { it.principal.botId == botId.trim() }

    /**
     * Replaces [token] when it is known and unexpired. Priority for the new
     * expiry is explicit `expiresAt`, then `ttlMilliseconds` relative to now,
     * then the old exact expiry. The old token is removed only after the
     * replacement was issued.
     */
    @Synchronized
    public fun rotate(
        token: String,
        capabilities: List<String>? = null,
        expiresAt: Long? = null,
        ttlMilliseconds: Long? = null,
    ): BotIssuedSessionToken? {
        if (token.isEmpty() || token.length > 512) return null
        val wanted = digest(token)
        var current: Record? = null
        for (record in records.values) {
            if (constantTimeEquals(record.digest, wanted)) current = record
        }
        val old = current ?: return null
        if (old.principal.expiresAt <= now()) {
            remove(old)
            return null
        }
        val replacement = issue(
            botId = old.principal.botId,
            sessionId = old.principal.sessionId,
            kind = old.principal.kind,
            capabilities = capabilities ?: old.principal.capabilities,
            expiresAt = expiresAt ?: if (ttlMilliseconds == null) old.principal.expiresAt else null,
            ttlMilliseconds = ttlMilliseconds,
        )
        records.remove(old.id)
        return replacement
    }

    /** Removes every record whose expiry is at or before now. */
    @Synchronized
    public fun prune(): Int {
        val timestamp = now()
        return revokeWhere { it.principal.expiresAt <= timestamp }
    }

    private fun remove(record: Record) {
        records.remove(record.id)
        if (currentIncarnations[record.principal.sessionId] == record.principal.incarnation) {
            currentIncarnations.remove(record.principal.sessionId)
        }
    }

    private fun revokeWhere(predicate: (Record) -> Boolean): Int {
        val removed = records.values.filter(predicate)
        for (record in removed) remove(record)
        return removed.size
    }

    private fun identifier(value: String, name: String): String {
        val text = value.trim()
        if (text.isEmpty() || characterCount(text) > 256) {
            throw BotSessionException("invalidInput:$name", "$name must be non-empty and at most 256 characters")
        }
        return text
    }

    private fun validateCapabilities(values: List<String>): List<String> {
        if (values.size > 64) {
            throw BotSessionException("invalidInput:capabilities", "at most 64 capabilities")
        }
        val seen = LinkedHashSet<String>()
        for (value in values) {
            val text = value.trim()
            if (text.isEmpty() || characterCount(text) > 128) {
                throw BotSessionException("invalidInput:capabilities", "invalid capability")
            }
            seen.add(text)
        }
        return seen.toList()
    }

    /** Extended grapheme clusters, matching Swift's `String.count`. */
    private fun characterCount(value: String): Int {
        val iterator = BreakIterator.getCharacterInstance()
        iterator.setText(value)
        var count = 0
        while (iterator.next() != BreakIterator.DONE) count++
        return count
    }

    private fun randomBytes(count: Int): ByteArray {
        val bytes = ByteArray(count)
        random.nextBytes(bytes)
        return bytes
    }

    private fun randomHexString(byteCount: Int): String {
        val out = StringBuilder(byteCount * 2)
        for (byte in randomBytes(byteCount)) {
            out.append(HEX[(byte.toInt() shr 4) and 0x0F])
            out.append(HEX[byte.toInt() and 0x0F])
        }
        return out.toString()
    }

    private fun randomUrlSafeString(byteCount: Int): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(randomBytes(byteCount))

    private fun digest(token: String): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(token.toByteArray(Charsets.UTF_8))

    private fun constantTimeEquals(lhs: ByteArray, rhs: ByteArray): Boolean {
        var difference = (lhs.size xor rhs.size).toByte()
        val size = maxOf(lhs.size, rhs.size)
        for (index in 0 until size) {
            val left = if (index < lhs.size) lhs[index] else 0
            val right = if (index < rhs.size) rhs[index] else 0
            difference = (difference.toInt() or (left.toInt() xor right.toInt())).toByte()
        }
        return difference.toInt() == 0
    }

    public companion object {
        public const val DEFAULT_TTL_MILLISECONDS: Long = 12L * 60 * 60 * 1_000
        public const val DEFAULT_MAXIMUM_TOKENS: Int = 4_096

        /** Gateway TTL for `kind == chat` (`BotGateway.swift:40-58`). */
        public const val CHAT_TTL_MILLISECONDS: Long = 30L * 24 * 60 * 60 * 1_000

        /** Gateway TTL for every non-chat kind. */
        public const val EPHEMERAL_TTL_MILLISECONDS: Long = 12L * 60 * 60 * 1_000

        private val HEX: CharArray = "0123456789abcdef".toCharArray()
    }
}
