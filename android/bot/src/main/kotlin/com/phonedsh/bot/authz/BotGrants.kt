// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.BotJson
import java.nio.file.Path
import java.util.UUID

/** `BotGrantScope` (`BotGrants.swift`). */
public enum class BotGrantScope(public val wire: String) {
    ONCE("once"),
    SESSION("session"),
    UNTIL("until"),
    ;

    public companion object {
        public fun fromWire(value: String): BotGrantScope? =
            entries.firstOrNull { it.wire == value }
    }
}

/** `BotGrantDecision`. */
public enum class BotGrantDecision(public val wire: String) {
    ALLOW("allow"),
    DENY("deny"),
    ;

    public companion object {
        public fun fromWire(value: String): BotGrantDecision? =
            entries.firstOrNull { it.wire == value }
    }
}

/** One standing or one-shot grant. */
public data class BotGrant(
    public val id: String = "",
    public val botId: String,
    public val tool: String,
    public val operation: String,
    public val resource: String,
    public val scope: BotGrantScope,
    public val sessionId: String? = null,
    public val expiresAt: Long? = null,
    public val createdAt: Long = 0,
    public val source: String = "approval",
    public val decision: BotGrantDecision,
) {
    /** The frozen eleven-member snapshot shape. */
    public fun toSnapshotJson(): JsonObject = BotJson.objectOf(
        "grantId" to JsonString(id),
        "botId" to JsonString(botId),
        "tool" to JsonString(tool),
        "operation" to JsonString(operation),
        "canonicalResource" to JsonString(resource),
        "scope" to JsonString(scope.wire),
        "sessionId" to (sessionId?.let(::JsonString) ?: com.phonedsh.agentcore.JsonNull),
        "expiresAt" to (expiresAt?.let(BotJson::number) ?: com.phonedsh.agentcore.JsonNull),
        "createdAt" to BotJson.number(createdAt),
        "source" to JsonString(source),
        "decision" to JsonString(decision.wire),
    )
}

/** Grant input/lookup failures; [code] is stable for callers. */
public class BotGrantException(
    public val code: String,
    message: String,
) : Exception(message)

/** The grant surface B5a1 consumes through its own adapter. */
public interface BotGrantPort {
    public fun recover()

    public fun add(grant: BotGrant): BotGrant

    public fun find(botId: String, sessionId: String?, effect: BotToolEffect): BotGrant?

    public fun consumeOnceAtomically(ids: List<String>): Boolean

    public fun revoke(id: String): Boolean

    public fun revokeBot(botId: String): Int

    public fun revokeSession(sessionId: String, botId: String? = null): Int

    public fun prune(): Int

    public fun list(botId: String? = null): List<BotGrant>
}

/** Resource canonicalization shared by grants, effects and snapshots. */
public object BotResourceNormalizer {
    public fun normalize(value: String): String {
        val text = value.trim()
        if (text.isEmpty()) return ""
        if (text.endsWith("/**")) {
            val base = normalize(text.dropLast(3))
            return if (base.isEmpty()) "" else "$base/**"
        }
        val expanded = if (text == "~") {
            System.getProperty("user.home")
        } else if (text.startsWith("~/")) {
            System.getProperty("user.home") + text.drop(1)
        } else {
            text
        }
        if (Path.of(expanded).isAbsolute) return Path.of(expanded).normalize().toString()
        return text.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
    }
}

/**
 * The in-memory grant store with the frozen durable `authz.grant_snapshot`
 * recovery rule (`BotGrantStore.swift`). State is host memory; [eventLog] may
 * be null for a pure in-memory test, matching the no-store Swift initializer.
 */
public class BotGrantStore(
    private val eventLog: BotAuthzEventLog? = null,
    private val now: () -> Long = { System.currentTimeMillis() },
    private val audit: BotAuditRecorder? = null,
) : BotGrantPort {
    private enum class RecoveryState { PENDING, READY, FAILED }

    private var grants: MutableList<BotGrant> = ArrayList()
    private var recoveryState: RecoveryState =
        if (eventLog == null) RecoveryState.READY else RecoveryState.PENDING
    private var recoveryError: BotGrantRecoveryException? = null

    public val auditRecorder: BotAuditRecorder?
        get() = audit

    @Synchronized
    override fun recover() {
        val log = eventLog ?: return
        when (recoveryState) {
            RecoveryState.READY -> return
            RecoveryState.FAILED -> throw recoveryError
                ?: BotGrantRecoveryException(BotGrantRecoveryReason.REPLAY_FAILED, "grant recovery failed")
            RecoveryState.PENDING -> Unit
        }
        try {
            var after = 0L
            var sawEvents = false
            var snapshot: BotAuthzEvent? = null
            while (true) {
                val page = log.events(after, 500)
                if (page.isEmpty()) break
                sawEvents = true
                for (event in page) {
                    if (event.type == BotGrantSnapshot.EVENT_TYPE) snapshot = event
                }
                val next = page.last().sequence
                if (next <= after) {
                    throw BotGrantRecoveryException(
                        BotGrantRecoveryReason.INVALID_SNAPSHOT,
                        "event replay returned an invalid cursor",
                    )
                }
                after = next
                if (page.size < 500) break
            }
            val restored = if (sawEvents) {
                val last = snapshot ?: throw BotGrantRecoveryException(
                    BotGrantRecoveryReason.MISSING_SNAPSHOT,
                    "authz events exist without a grant snapshot",
                )
                BotGrantSnapshot.decode(last, now())
            } else {
                val empty = BotGrantSnapshot.event(emptyList(), now())
                log.append(empty)
                emptyList()
            }
            grants = restored.toMutableList()
            recoveryState = RecoveryState.READY
            recoveryError = null
        } catch (error: BotGrantRecoveryException) {
            recoveryState = RecoveryState.FAILED
            recoveryError = error
            throw error
        } catch (error: Exception) {
            val wrapped = BotGrantRecoveryException(
                BotGrantRecoveryReason.REPLAY_FAILED,
                error.message ?: error.javaClass.simpleName,
            )
            recoveryState = RecoveryState.FAILED
            recoveryError = wrapped
            throw wrapped
        }
    }

    @Synchronized
    override fun add(raw: BotGrant): BotGrant {
        recover()
        val timestamp = now()
        val botId = raw.botId.trim()
        val tool = raw.tool.trim()
        val resource = BotResourceNormalizer.normalize(raw.resource)
        if (botId.isEmpty() || tool.isEmpty() || resource.isEmpty()) {
            throw BotGrantException("invalidGrant", "grant requires botId, tool and resource")
        }
        val createdAt = if (raw.createdAt == 0L) timestamp else raw.createdAt
        val expiry = raw.expiresAt ?: defaultExpiry(raw.scope, createdAt)
        if (expiry <= timestamp) {
            throw BotGrantException("invalidExpiry", "grant expiry must be in the future")
        }
        val sessionId = raw.sessionId?.trim()
        val source = raw.source.trim()
        val grant = BotGrant(
            id = raw.id.ifEmpty { newId() },
            botId = botId,
            tool = tool,
            operation = raw.operation.trim().ifEmpty { "unknown" },
            resource = resource,
            scope = raw.scope,
            sessionId = sessionId?.takeIf { it.isNotEmpty() },
            expiresAt = expiry,
            createdAt = createdAt,
            source = source.ifEmpty { "approval" },
            decision = raw.decision,
        )
        val duplicate = grants.indexOfFirst {
            it.botId == grant.botId && it.tool == grant.tool &&
                it.operation == grant.operation && it.resource == grant.resource &&
                it.decision == grant.decision && it.scope == grant.scope &&
                (grant.scope != BotGrantScope.SESSION || it.sessionId == grant.sessionId)
        }
        if (duplicate >= 0) {
            val existing = grants[duplicate]
            val extendedExpiry = maxOf(existing.expiresAt ?: Long.MAX_VALUE, grant.expiresAt ?: Long.MAX_VALUE)
            val extended = existing.copy(
                expiresAt = if (extendedExpiry == Long.MAX_VALUE) null else extendedExpiry,
            )
            grants[duplicate] = extended
            persist(grants)
            recordGrant("grant.added", extended, "extended")
            return extended
        }
        if (grants.any { it.id == grant.id }) {
            throw BotGrantException("invalidGrant", "duplicate grant id")
        }
        grants += grant
        if (grants.size > MAXIMUM_GRANTS) {
            grants = grants.takeLast(MAXIMUM_GRANTS).toMutableList()
        }
        persist(grants)
        recordGrant("grant.added", grant, "created")
        return grant
    }

    @Synchronized
    override fun find(botId: String, sessionId: String?, effect: BotToolEffect): BotGrant? {
        if (recoveryState != RecoveryState.READY) return null
        val wantedBot = botId.trim()
        val wantedResource = BotResourceNormalizer.normalize(effect.resource)
        if (wantedBot.isEmpty() || effect.tool.trim().isEmpty() || wantedResource.isEmpty()) return null
        val timestamp = now()
        return activeGrants().filter {
            it.expiresAt == null || it.expiresAt > timestamp
        }.filter {
            it.botId == wantedBot || (it.botId == "*" && it.decision == BotGrantDecision.DENY)
        }.filter {
            it.scope != BotGrantScope.SESSION || (it.sessionId != null && it.sessionId == sessionId)
        }.filter {
            (it.tool == "*" || it.tool == effect.tool) &&
                (it.operation == "*" || it.operation == effect.operation) &&
                it.resource == wantedResource
        }.sortedWith(
            compareByDescending<BotGrant> { it.decision == BotGrantDecision.DENY }
                .thenByDescending { specificity(it) },
        ).firstOrNull()
    }

    @Synchronized
    override fun consumeOnceAtomically(ids: List<String>): Boolean {
        recover()
        val unique = ids.toSet()
        if (unique.isEmpty()) return true
        val current = activeGrants()
        if (!unique.all { id -> current.any { it.id == id && it.scope == BotGrantScope.ONCE } }) {
            return false
        }
        val removed = current.filter { it.id in unique }
        val updated = current.filter { it.id !in unique }
        grants = updated.toMutableList()
        persist(grants)
        for (grant in removed) recordGrant("grant.consumed", grant, "used-once")
        return true
    }

    @Synchronized
    override fun revoke(id: String): Boolean {
        recover()
        val index = grants.indexOfFirst { it.id == id }
        if (index < 0) return false
        val removed = grants.removeAt(index)
        persist(grants)
        recordGrant("grant.revoked", removed, "user-revoked")
        return true
    }

    @Synchronized
    override fun revokeBot(botId: String): Int {
        recover()
        val removed = grants.filter { it.botId == botId }
        if (removed.isEmpty()) return 0
        grants = grants.filter { it.botId != botId }.toMutableList()
        persist(grants)
        for (grant in removed) recordGrant("grant.revoked", grant, "bot-deleted")
        return removed.size
    }

    @Synchronized
    override fun revokeSession(sessionId: String, botId: String?): Int {
        recover()
        val removed = grants.filter {
            it.scope == BotGrantScope.SESSION && it.sessionId == sessionId &&
                (botId == null || it.botId == botId)
        }
        if (removed.isEmpty()) return 0
        grants = grants.filter {
            !(it.scope == BotGrantScope.SESSION && it.sessionId == sessionId &&
                (botId == null || it.botId == botId))
        }.toMutableList()
        persist(grants)
        for (grant in removed) recordGrant("grant.revoked", grant, "session-ended")
        return removed.size
    }

    @Synchronized
    override fun prune(): Int {
        if (recoveryState != RecoveryState.READY) return 0
        val timestamp = now()
        val before = grants.size
        grants = activeGrants().toMutableList()
        return before - grants.size
    }

    @Synchronized
    override fun list(botId: String?): List<BotGrant> {
        if (recoveryState != RecoveryState.READY) return emptyList()
        return activeGrants()
            .filter { botId == null || it.botId == botId }
            .sortedByDescending { it.createdAt }
    }

    private fun activeGrants(): List<BotGrant> {
        val timestamp = now()
        return grants.filter { it.expiresAt == null || it.expiresAt > timestamp }
    }

    private fun persist(updated: List<BotGrant>) {
        val log = eventLog ?: return
        log.append(BotGrantSnapshot.event(updated, now()))
    }

    private fun recordGrant(event: String, grant: BotGrant, reason: String) {
        val recorder = audit ?: return
        val effect = BotToolEffect(
            tool = grant.tool,
            operation = grant.operation,
            resource = grant.resource,
            mutability = BotToolMutability.WRITE,
            policy = BotToolPolicy.ASK,
        )
        recorder.append(
            BotAuditRecord(
                at = now(),
                event = event,
                source = grant.source,
                decision = grant.decision,
                principal = BotAuditPrincipal(
                    botId = grant.botId,
                    sessionId = grant.sessionId,
                    kind = "ipc",
                    sessionKind = null,
                    certain = true,
                ),
                effects = listOf(BotExecutionAuditing.effect(effect, argsDigest = null)),
                grants = listOf(BotExecutionAuditing.grant(grant)),
                reason = reason,
            ),
        )
    }

    private fun defaultExpiry(scope: BotGrantScope, createdAt: Long): Long {
        val ttl = when (scope) {
            BotGrantScope.ONCE -> ONCE_TTL_MILLISECONDS
            BotGrantScope.SESSION -> SESSION_TTL_MILLISECONDS
            BotGrantScope.UNTIL -> UNTIL_TTL_MILLISECONDS
        }
        return try {
            Math.addExact(createdAt, ttl)
        } catch (_: ArithmeticException) {
            throw BotGrantException("invalidExpiry", "grant expiry overflow")
        }
    }

    private fun specificity(grant: BotGrant): Int =
        (if (grant.botId == "*") 0 else 100) +
            (if (grant.tool == "*") 0 else 10) +
            (if (grant.operation == "*") 0 else 5) + 1

    private fun newId(): String =
        "grant-" + UUID.randomUUID().toString().replace("-", "").lowercase().take(16)

    public companion object {
        public const val ONCE_TTL_MILLISECONDS: Long = 2 * 60 * 1_000
        public const val SESSION_TTL_MILLISECONDS: Long = 24 * 60 * 60 * 1_000
        public const val UNTIL_TTL_MILLISECONDS: Long = 30L * 24 * 60 * 60 * 1_000
        public const val MAXIMUM_GRANTS: Int = 500
    }
}

/** Audit helpers shared by the authorizer and grant store. */
public object BotExecutionAuditing {
    public fun effect(effect: BotToolEffect, argsDigest: String?): BotAuditEffect =
        BotAuditEffect(
            tool = effect.tool,
            operation = effect.operation,
            resourceDigest = BotArgumentsDigest.digestOfUtf8(effect.resource),
            argsDigest = argsDigest,
            mutability = effect.mutability,
            policy = effect.policy,
        )

    public fun grant(grant: BotGrant): BotAuditGrant =
        BotAuditGrant(
            id = grant.id,
            scope = grant.scope,
            decision = grant.decision,
            resourceDigest = BotArgumentsDigest.digestOfUtf8(grant.resource),
        )
}

/** Task-facing alias for the grant store (`BotGrants` in the lane brief). */
public typealias BotGrants = BotGrantStore
