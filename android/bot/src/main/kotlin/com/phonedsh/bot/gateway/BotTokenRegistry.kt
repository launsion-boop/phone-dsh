// SPDX-License-Identifier: MIT
package com.phonedsh.bot.gateway

import com.phonedsh.bot.attachments.BotWorkspaceLayout
import com.phonedsh.bot.session.BotSessionKind
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/**
 * One principal issued by [BotTokenRegistry] (`BotTokenRegistry.swift`).
 * Tokens and incarnations are opaque; consumers never parse them.
 */
public data class BotGatewayPrincipal(
    public val botId: String,
    public val sessionId: String,
    public val kind: BotSessionKind,
    public val capabilities: List<String> = emptyList(),
    public val expiresAt: Long,
    public val incarnation: String,
)

public data class BotIssuedToken(
    public val token: String,
    public val principal: BotGatewayPrincipal,
)

public class BotTokenRegistryException(
    public val code: String,
    message: String,
) : Exception(message)

/** The token-principal surface B5a1 consumes through its own adapter. */
public interface BotTokenPrincipalPort {
    public fun lookup(token: String): BotGatewayPrincipal?

    public fun lookupBearer(header: String): BotGatewayPrincipal?

    public fun lookupSession(sessionId: String): BotGatewayPrincipal?

    public fun revoke(token: String): Boolean

    public fun revokeSession(sessionId: String): Int

    public fun revokeBot(botId: String): Int
}

/**
 * The D13 session credential registry.
 *
 * Tokens are `dshg_` + unpadded URL-safe Base64 of 32 random bytes (43
 * characters, 48 total); only SHA-256 digests are stored and compared in
 * constant time. The incarnation is 16 random bytes as 32 lower-case hex. TTL
 * is 12 h and at most 4,096 live records survive pruning. `issueSession`
 * revokes the session's previous token first; `issue` alone does not.
 */
public class BotTokenRegistry(
    private val now: () -> Long = { System.currentTimeMillis() },
    public val defaultTtlMilliseconds: Long = DEFAULT_TTL_MILLISECONDS,
    public val maximumTokens: Int = DEFAULT_MAXIMUM_TOKENS,
    private val random: SecureRandom = SecureRandom(),
) : BotTokenPrincipalPort {
    init {
        require(defaultTtlMilliseconds > 0) { "defaultTtlMilliseconds must be positive" }
        require(maximumTokens > 0) { "maximumTokens must be positive" }
    }

    private data class Record(
        val id: String,
        val digest: ByteArray,
        val principal: BotGatewayPrincipal,
    )

    private val records: LinkedHashMap<String, Record> = LinkedHashMap()
    private val currentIncarnations: HashMap<String, String> = HashMap()

    @Synchronized
    public fun count(): Int {
        prune()
        return records.size
    }

    @Synchronized
    public fun issueSession(
        botId: String,
        sessionId: String,
        kind: BotSessionKind,
        capabilities: List<String> = emptyList(),
        expiresAt: Long? = null,
        ttlMilliseconds: Long? = null,
    ): BotIssuedToken {
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
    ): BotIssuedToken {
        val validBotId = identifier(botId, "botId")
        val validSessionId = identifier(sessionId, "sessionId")
        val validCapabilities = capabilities(capabilities)
        val timestamp = now()
        val expiry = if (expiresAt != null) {
            expiresAt
        } else {
            val ttl = ttlMilliseconds ?: defaultTtlMilliseconds
            if (ttl <= 0) {
                throw BotTokenRegistryException("invalidInput:ttlMilliseconds", "ttlMilliseconds must be positive")
            }
            try {
                Math.addExact(timestamp, ttl)
            } catch (_: ArithmeticException) {
                throw BotTokenRegistryException("invalidInput:expiresAt", "expiresAt overflow")
            }
        }
        if (expiry <= timestamp) {
            throw BotTokenRegistryException("invalidInput:expiresAt", "expiresAt must be greater than now")
        }
        prune()
        if (records.size >= maximumTokens) {
            throw BotTokenRegistryException("registryFull", "token registry is full")
        }
        val token = "dshg_" + randomUrlSafeString(32)
        val incarnation = randomHexString(16)
        val principal = BotGatewayPrincipal(
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
        return BotIssuedToken(token = token, principal = principal)
    }

    @Synchronized
    override fun lookup(token: String): BotGatewayPrincipal? {
        if (token.isEmpty() || token.toByteArray(Charsets.UTF_8).size > 512) return null
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

    /**
     * Accepts exactly two whitespace-separated fields and a scheme matching
     * `Bearer` case-insensitively. The MCP listener's own `Authorization`
     * check is a separate, stricter entry point (mcp-endpoint.md §11).
     */
    @Synchronized
    override fun lookupBearer(header: String): BotGatewayPrincipal? {
        val parts = header.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (parts.size != 2 || !parts[0].equals("Bearer", ignoreCase = true)) return null
        return lookup(parts[1])
    }

    @Synchronized
    override fun lookupSession(sessionId: String): BotGatewayPrincipal? {
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

    /** Every current session incarnation, sorted by Bot then session. */
    @Synchronized
    public fun activePrincipals(): List<BotGatewayPrincipal> {
        prune()
        val timestamp = now()
        return records.values.mapNotNull { record ->
            val principal = record.principal
            if (currentIncarnations[principal.sessionId] != principal.incarnation ||
                principal.expiresAt <= timestamp
            ) {
                null
            } else {
                principal
            }
        }.sortedWith(compareBy<BotGatewayPrincipal> { it.botId }.thenBy { it.sessionId })
    }

    @Synchronized
    public fun activeSessionIds(): Set<String> = activePrincipals().map { it.sessionId }.toSet()

    @Synchronized
    override fun revoke(token: String): Boolean {
        if (token.isEmpty() || token.toByteArray(Charsets.UTF_8).size > 512) return false
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
    override fun revokeSession(sessionId: String): Int =
        revokeWhere { it.principal.sessionId == sessionId.trim() }

    @Synchronized
    override fun revokeBot(botId: String): Int =
        revokeWhere { it.principal.botId == botId.trim() }

    /**
     * Replaces [token] with a new token and incarnation, keeps the old exact
     * expiry unless `expiresAt`/`ttlMilliseconds` is supplied, then removes the
     * old record. An unknown or expired token returns null.
     */
    @Synchronized
    public fun rotate(
        token: String,
        capabilities: List<String>? = null,
        expiresAt: Long? = null,
        ttlMilliseconds: Long? = null,
    ): BotIssuedToken? {
        if (token.isEmpty() || token.toByteArray(Charsets.UTF_8).size > 512) return null
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

    /**
     * Test/fixture seeding for a token minted elsewhere. Production callers
     * must use [issue]/[issueSession]; this exists because the shared identity
     * vectors carry fixed credential strings.
     */
    internal fun seedForFixture(
        token: String,
        botId: String,
        sessionId: String,
        kind: BotSessionKind,
        capabilities: List<String> = emptyList(),
        expiresAt: Long,
        incarnation: String = randomHexString(16),
    ) {
        require(token.isNotEmpty())
        val id = randomHexString(16)
        val principal = BotGatewayPrincipal(
            botId = botId,
            sessionId = sessionId,
            kind = kind,
            capabilities = capabilities,
            expiresAt = expiresAt,
            incarnation = incarnation,
        )
        records[id] = Record(id = id, digest = digest(token), principal = principal)
        currentIncarnations[sessionId] = incarnation
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
        if (text.isEmpty() || BotWorkspaceLayout.graphemeClusterCount(text) > 256) {
            throw BotTokenRegistryException("invalidInput:$name", "$name must be non-empty and at most 256 characters")
        }
        return text
    }

    private fun capabilities(values: List<String>): List<String> {
        if (values.size > 64) {
            throw BotTokenRegistryException("invalidInput:capabilities", "at most 64 capabilities")
        }
        val seen = LinkedHashSet<String>()
        for (value in values) {
            val text = value.trim()
            if (text.isEmpty() || BotWorkspaceLayout.graphemeClusterCount(text) > 128) {
                throw BotTokenRegistryException("invalidInput:capabilities", "invalid capability")
            }
            seen += text
        }
        return seen.toList()
    }

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

    public companion object {
        public const val DEFAULT_TTL_MILLISECONDS: Long = 12L * 60 * 60 * 1_000
        public const val DEFAULT_MAXIMUM_TOKENS: Int = 4_096
        private val HEX: CharArray = "0123456789abcdef".toCharArray()
    }
}
