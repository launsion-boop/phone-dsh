// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.gateway.BotAttribution
import com.phonedsh.bot.gateway.BotGatewayPrincipal

/** The actual user decision (`BotApprovalDecision.swift`). */
public enum class BotApprovalDecision(public val wire: String) {
    ALLOW_ONCE("allowOnce"),
    ALWAYS("always"),
    DENY("deny"),
    ;

    public companion object {
        public fun fromWire(value: String): BotApprovalDecision? =
            entries.firstOrNull { it.wire == value }
    }
}

/** Whether a card waits in place or becomes a durable todo. */
public enum class BotApprovalPersistence {
    INTERACTIVE,
    DURABLE,
}

/** Terminal/durable status of one approval. */
public enum class BotApprovalDurableStatus(public val wire: String) {
    PENDING("pending"),
    ALLOWED("allowed"),
    DENIED("denied"),
    EXPIRED("expired"),
    CANCELLED("cancelled"),
    UNKNOWN("unknown"),
}

/**
 * One `/approval` response. `pending` is required on every outcome; the other
 * members are additive and omitted when undefined (PC-20261113-bot-mcp-d13
 * ruling 1). The raw token is never part of this object.
 */
public data class BotApprovalOutcome(
    public val ok: Boolean,
    public val allowed: Boolean,
    public val approvalId: String? = null,
    public val message: String? = null,
    public val pending: Boolean = false,
    public val expiresAt: Long? = null,
    public val decision: BotApprovalDecision? = null,
    public val scope: String? = null,
    public val onceGrantIDs: List<String> = emptyList(),
) {
    public fun toJson(): JsonObject {
        val members = linkedMapOf<String, JsonValue>(
            "ok" to JsonBool(ok),
            "allowed" to JsonBool(allowed),
            "pending" to JsonBool(pending),
        )
        approvalId?.let { members["approvalId"] = JsonString(it) }
        message?.let { members["message"] = JsonString(it) }
        expiresAt?.let { members["expiresAt"] = JsonNumber(it.toString()) }
        decision?.let { members["approvalDecision"] = JsonString(it.wire) }
        scope?.let { members["scope"] = JsonString(it) }
        return JsonObject(members)
    }

    public val jsonValue: JsonObject
        get() = toJson()

    public companion object {
        public fun stale(reason: String): BotApprovalOutcome = BotApprovalOutcome(
            ok = false,
            allowed = false,
            pending = false,
            message = reason,
        )

        public fun invalidRequest(): BotApprovalOutcome = BotApprovalOutcome(
            ok = false,
            allowed = false,
            pending = false,
            message = "invalid approval request",
        )
    }
}

/** Result of a `resolve` call. */
public sealed interface BotApprovalResolution {
    public data object Resolved : BotApprovalResolution

    public data class Stale(public val reason: String) : BotApprovalResolution
}

/** The stable view of a durable todo. */
public data class BotDurableApprovalState(
    public val approvalID: String,
    public val principal: BotGatewayPrincipal,
    public val status: BotApprovalDurableStatus,
    public val requestedAt: Long,
    public val expiresAt: Long,
    public val action: String,
    public val detail: String,
    public val command: String,
)

/** One terminal durable decision delivered to a task/routine resumer. */
public data class BotApprovalResolutionNotice(
    public val approvalID: String,
    public val principal: BotGatewayPrincipal,
    public val allowed: Boolean,
    public val expired: Boolean = false,
    public val cancelled: Boolean = false,
    public val decision: BotApprovalDecision? = null,
    public val decidedAt: Long = 0,
)

/**
 * One live registration resolved for `/approval`. [arguments] is the stored
 * registration argument object, not the body's copy; the digest is recomputed
 * from it during validation.
 */
public data class BotResolvedToolCall(
    public val sessionId: String,
    public val callId: String,
    public val botId: String,
    public val principal: BotGatewayPrincipal,
    public val attribution: BotAttribution,
    public val arguments: JsonValue,
)

/** The registration lookup seam the approval coordinator validates against. */
public interface BotApprovalRegistrationResolver {
    public fun resolve(
        runtimeId: String,
        sessionId: String?,
        callId: String,
    ): BotResolvedToolCall?
}

/** Cancel seam used by `/identity/cancel` and Worker restart. */
public interface BotInteractiveApprovalCanceller {
    public fun cancelInteractive(sessionId: String, callId: String): Int

    public fun cancelInteractive(reason: String): Int
}

/** One parsed `/approval` body. */
public data class BotApprovalRequest(
    public val sessionId: String,
    public val callId: String,
    public val tool: String,
    public val argsDigest: String,
    public val alwaysScope: String,
    public val action: String,
    public val detail: String,
    public val command: String,
    public val effects: List<BotToolEffect>?,
    public val askAction: String,
) {
    public companion object {
        /** Null when a required member is absent or has the wrong type. */
        public fun parse(body: JsonObject): BotApprovalRequest? {
            val members = body.members
            val sessionId = BotJson.string(members["sessionId"])
                ?: return null
            if (sessionId.isEmpty()) return null
            val callId = BotJson.string(members["callId"]) ?: return null
            val tool = BotJson.string(members["tool"]) ?: return null
            val argsDigest = BotJson.string(members["argsDigest"]) ?: return null
            val alwaysScope = BotJson.string(members["alwaysScope"]) ?: return null
            val effects = when (val raw = members["effects"]) {
                null -> null
                is JsonArray -> raw.values.mapNotNull(BotToolEffect::fromJson)
                else -> return null
            }
            return BotApprovalRequest(
                sessionId = sessionId,
                callId = callId,
                tool = tool,
                argsDigest = argsDigest,
                alwaysScope = alwaysScope,
                action = BotJson.string(members["action"]) ?: tool,
                detail = BotJson.string(members["detail"]) ?: "",
                command = BotJson.string(members["command"]) ?: "",
                effects = effects,
                askAction = BotJson.string(members["askAction"]) ?: "tool-call",
            )
        }
    }
}

/** The approval surface B5a1 consumes through its own adapter. */
public interface BotApprovalPort {
    public fun approve(
        body: JsonObject,
        runtimeId: String,
        resolver: BotApprovalRegistrationResolver,
    ): BotApprovalOutcome

    public fun request(
        call: BotResolvedToolCall,
        effects: List<BotToolEffect>,
        action: String,
        detail: String,
        command: String,
        alwaysScope: String,
        persistence: BotApprovalPersistence = BotApprovalPersistence.INTERACTIVE,
        origin: String = "structural",
        onPending: ((String) -> Unit)? = null,
        interactiveWaitMilliseconds: Long = 0,
    ): BotApprovalOutcome

    public fun resolve(
        approvalId: String,
        decision: BotApprovalDecision,
        digest: String,
    ): BotApprovalResolution

    public fun cancel(approvalId: String): Boolean

    public fun cancelInteractive(sessionId: String, callId: String): Int

    public fun pendingIDs(): List<String>

    public fun pendingDigest(approvalId: String): String?

    public fun durableStatus(approvalId: String): BotApprovalDurableStatus
}

/** Schedules a timeout without making the coordinator own a clock thread. */
public fun interface BotApprovalScheduler {
    public fun schedule(delayMilliseconds: Long, action: () -> Unit): BotApprovalCancellation
}

public fun interface BotApprovalCancellation {
    public fun cancel()
}
