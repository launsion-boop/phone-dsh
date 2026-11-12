// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.bot.gateway.BotGatewayPrincipal
import com.phonedsh.bot.session.BotSessionKind

public enum class BotExecutionPrincipalKind(public val wire: String) {
    MODEL("model"),
    USER_UI("user-ui"),
    SYSTEM("system"),
    UNKNOWN("unknown"),
    ;

    public companion object {
        public fun fromWire(value: String): BotExecutionPrincipalKind? =
            entries.firstOrNull { it.wire == value }
    }
}

public data class BotExecutionPrincipal(
    public val botId: String?,
    public val sessionId: String? = null,
    public val kind: BotExecutionPrincipalKind = BotExecutionPrincipalKind.MODEL,
    public val sessionKind: BotSessionKind? = null,
    public val certain: Boolean = true,
) {
    public companion object {
        public fun fromGateway(
            principal: BotGatewayPrincipal,
            certain: Boolean = true,
        ): BotExecutionPrincipal = BotExecutionPrincipal(
            botId = principal.botId,
            sessionId = principal.sessionId,
            kind = BotExecutionPrincipalKind.MODEL,
            sessionKind = principal.kind,
            certain = certain,
        )

        public fun userUi(botId: String, sessionId: String? = null): BotExecutionPrincipal =
            BotExecutionPrincipal(
                botId = botId,
                sessionId = sessionId,
                kind = BotExecutionPrincipalKind.USER_UI,
                certain = true,
            )
    }
}

public data class BotExecutionDecision(
    public val allowed: Boolean,
    public val reason: String,
    public val principal: BotExecutionPrincipal,
    public val effects: List<BotToolEffect>,
    public val grants: List<BotGrant> = emptyList(),
    public val denied: Boolean = false,
    public val userUi: Boolean = false,
    public val readOnly: Boolean = false,
    public val autoPolicy: Boolean = false,
)

/**
 * The tool execution gate (`BotExecutionAuthorizer.swift`).
 *
 * A recovery failure, an empty/invalid effect set, missing attribution or a
 * standing deny fails closed before any grant is consumed. A `once` grant is
 * consumed atomically only after every ask-policy effect matched, so a
 * concurrent consumer gets `once-grant-consumed` instead of executing twice.
 */
public class BotExecutionAuthorizer(
    public val grants: BotGrantPort,
    private val audit: BotAuditRecorder? = (grants as? BotGrantStore)?.auditRecorder,
    private val now: () -> Long = { System.currentTimeMillis() },
) {
    public fun authorizeExecution(
        principal: BotExecutionPrincipal?,
        effects: List<BotToolEffect>,
        source: String = "execution",
        argsDigest: String? = null,
        consumeOnce: Boolean = true,
    ): BotExecutionDecision {
        val resolved = principal ?: BotExecutionPrincipal(
            botId = null,
            kind = BotExecutionPrincipalKind.UNKNOWN,
            certain = false,
        )
        try {
            grants.recover()
        } catch (_: Exception) {
            return decision(
                false, "grant-recovery-failed", resolved, effects, source = source, argsDigest = null,
            )
        }
        var normalizedDigest: String? = null
        if (argsDigest != null) {
            normalizedDigest = BotArgumentsDigest.validatedOrNull(argsDigest)
                ?: return decision(
                    false, "invalid-arguments-digest", resolved, effects,
                    source = source, argsDigest = null,
                )
        }
        if (effects.isEmpty()) {
            return decision(
                false, "empty-effects", resolved, emptyList(),
                source = source, argsDigest = normalizedDigest,
            )
        }
        val normalizedEffects = ArrayList<BotToolEffect>(effects.size)
        for (effect in effects) {
            val tool = effect.tool.trim()
            val resource = BotResourceNormalizer.normalize(effect.resource)
            if (tool.isEmpty() || resource.isEmpty()) {
                return decision(
                    false, "invalid-effect", resolved, effects,
                    source = source, argsDigest = normalizedDigest,
                )
            }
            normalizedEffects += effect.copy(
                tool = tool,
                operation = effect.operation.trim().ifEmpty { "unknown" },
                resource = resource,
            )
        }
        val botId = resolved.botId?.trim()
        if (botId.isNullOrEmpty()) {
            return decision(
                false, "unattributed", resolved, normalizedEffects,
                source = source, argsDigest = normalizedDigest,
            )
        }
        if (!resolved.certain || resolved.kind == BotExecutionPrincipalKind.UNKNOWN) {
            return decision(
                false, "uncertain-attribution", resolved, normalizedEffects,
                source = source, argsDigest = normalizedDigest,
            )
        }
        for (effect in normalizedEffects) {
            val grant = grants.find(botId, resolved.sessionId, effect)
            if (grant != null && grant.decision == BotGrantDecision.DENY) {
                return decision(
                    false, "standing-deny", resolved, normalizedEffects, grants = listOf(grant),
                    denied = true, source = source, argsDigest = normalizedDigest,
                )
            }
        }
        if (resolved.kind == BotExecutionPrincipalKind.USER_UI) {
            return decision(
                true, "user-initiated UI action", resolved, normalizedEffects, userUi = true,
                readOnly = normalizedEffects.none { it.mutability != BotToolMutability.READ },
                source = source, argsDigest = normalizedDigest,
            )
        }
        val writes = normalizedEffects.filter { it.mutability != BotToolMutability.READ }
        val hits = ArrayList<BotGrant>()
        val hitIds = HashSet<String>()
        for (effect in normalizedEffects) {
            if (effect.policy != BotToolPolicy.ASK) continue
            val grant = grants.find(botId, resolved.sessionId, effect)
                ?: return decision(
                    false, "missing-grant", resolved, normalizedEffects,
                    source = source, argsDigest = normalizedDigest,
                )
            if (hitIds.add(grant.id)) hits += grant
        }
        if (consumeOnce) {
            val onceIds = hits.filter { it.scope == BotGrantScope.ONCE }.map { it.id }
            val consumed = try {
                grants.consumeOnceAtomically(onceIds)
            } catch (_: Exception) {
                return decision(
                    false, "grant-persistence-failed", resolved, normalizedEffects,
                    source = source, argsDigest = normalizedDigest,
                )
            }
            if (!consumed) {
                return decision(
                    false, "once-grant-consumed", resolved, normalizedEffects,
                    source = source, argsDigest = normalizedDigest,
                )
            }
        }
        val auto = writes.any { it.policy == BotToolPolicy.AUTO }
        val reason = if (auto) {
            if (hits.isEmpty()) "auto-policy" else "auto-policy; grant matched"
        } else {
            "grant matched"
        }
        return decision(
            true, reason, resolved, normalizedEffects, grants = hits,
            readOnly = writes.isEmpty(), autoPolicy = auto,
            source = source, argsDigest = normalizedDigest,
        )
    }

    private fun decision(
        allowed: Boolean,
        reason: String,
        principal: BotExecutionPrincipal,
        effects: List<BotToolEffect>,
        grants: List<BotGrant> = emptyList(),
        denied: Boolean = false,
        userUi: Boolean = false,
        readOnly: Boolean = false,
        autoPolicy: Boolean = false,
        source: String,
        argsDigest: String?,
    ): BotExecutionDecision {
        val result = BotExecutionDecision(
            allowed = allowed,
            reason = reason,
            principal = principal,
            effects = effects,
            grants = grants,
            denied = denied,
            userUi = userUi,
            readOnly = readOnly,
            autoPolicy = autoPolicy,
        )
        val recorder = audit ?: return result
        recorder.append(
            BotAuditRecord(
                at = now(),
                source = source,
                decision = if (allowed) BotGrantDecision.ALLOW else BotGrantDecision.DENY,
                principal = BotAuditPrincipal(
                    botId = principal.botId,
                    sessionId = principal.sessionId,
                    kind = principal.kind.wire,
                    sessionKind = principal.sessionKind,
                    certain = principal.certain,
                ),
                effects = effects.map { BotExecutionAuditing.effect(it, argsDigest) },
                grants = grants.map(BotExecutionAuditing::grant),
                reason = reason,
            ),
        )
        return result
    }
}
