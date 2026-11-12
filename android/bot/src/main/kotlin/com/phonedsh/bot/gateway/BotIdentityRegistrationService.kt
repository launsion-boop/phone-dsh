// SPDX-License-Identifier: MIT
package com.phonedsh.bot.gateway

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.authz.BotApprovalRegistrationResolver
import com.phonedsh.bot.authz.BotArgumentsDigest
import com.phonedsh.bot.authz.BotInteractiveApprovalCanceller
import com.phonedsh.bot.authz.BotResolvedToolCall

/** The frozen bare-name set accepted by `/identity/register` (§8.1). */
public object BotToolNames {
    public val P0: List<String> = listOf(
        "ask_user", "show_next_steps", "show_attachment", "show_document", "show_progress",
        "show_checklist", "show_link", "UpdateMemory", "ReadMemory", "RecallMemory", "Task", "AwaitTask",
        "StopSubagent", "UpdateRoutine", "ListRoutines", "RequestApproval", "SendToUser",
    )
    public const val VOLATILE_CONTEXT: String = "BotVolatileContext"
    public val HOST_BUILTINS: Set<String> = setOf("bash", "write", "edit", "phone")
    public val DEVICE_TOOLS: Set<String> = setOf(
        "bluetooth.scan", "network.browse",
        "ble_devices", "ble_read", "ble_alert", "ble_link_tools", "ble_link_call", "ble_link_result",
    )
    public val TEAM_TOOLS: Set<String> = setOf("SendToAgent", "CreateTeammate")
    public val BOT_TOOLS: Set<String> = setOf("FishAction")

    public val DEFAULT_KNOWN: Set<String> =
        (P0 + listOf(VOLATILE_CONTEXT) + HOST_BUILTINS + DEVICE_TOOLS + TEAM_TOOLS + BOT_TOOLS).toSet()

    /** `mcp__<server>__Name` -> `Name`, otherwise unchanged. */
    public fun bare(name: String): String =
        if (name.startsWith("mcp__")) name.substringAfterLast("__") else name
}

public data class BotIdentityRegistrationRequest(
    public val runtimeId: String,
    public val sessionId: String,
    public val callId: String,
    public val name: String,
    public val arguments: JsonValue = JsonObject(emptyMap()),
    public val argsDigest: String? = null,
    public val sessionToken: String? = null,
    public val argumentsProvided: Boolean = true,
    public val nameProvided: Boolean = true,
) {
    public companion object {
        /**
         * Parses an `/identity/register` body. The required members are the
         * handler's guard: a missing or wrong-typed one returns null so the
         * caller can answer `invalid identity registration`.
         */
        public fun fromJson(body: JsonObject): BotIdentityRegistrationRequest? {
            val members = body.members
            val runtimeId = BotJson.string(members["runtimeId"]) ?: return null
            val sessionId = BotJson.string(members["sessionId"]) ?: return null
            val callId = BotJson.string(members["callId"]) ?: return null
            val name = BotJson.string(members["name"]) ?: return null
            return BotIdentityRegistrationRequest(
                runtimeId = runtimeId,
                sessionId = sessionId,
                callId = callId,
                name = name,
                arguments = members["arguments"] ?: JsonObject(emptyMap()),
                argsDigest = BotJson.string(members["argsDigest"]),
                sessionToken = BotJson.string(members["sessionToken"]),
                argumentsProvided = members.containsKey("arguments"),
                nameProvided = true,
            )
        }
    }
}

public data class BotIdentityRegisterResult(
    public val ok: Boolean,
    public val id: String? = null,
    public val error: String? = null,
) {
    public fun toJson(): JsonObject {
        val members = linkedMapOf<String, JsonValue>("ok" to com.phonedsh.agentcore.JsonBool(ok))
        id?.let { members["id"] = JsonString(it) }
        error?.let { members["error"] = JsonString(it) }
        return JsonObject(members)
    }

    public val jsonValue: JsonObject
        get() = toJson()
}

/**
 * `/identity/register` and `/identity/cancel` state
 * (`BotMCPRuntime.swift: registerIdentityOnce/cancelIdentity`).
 *
 * The body `sessionId` is never identity evidence: the token resolves the
 * principal and the body is only a consistency check. Registration binds the
 * token incarnation and is re-checked after publishing, so a revoke/rotate in
 * the window fails closed.
 */
public class BotIdentityRegistrationService(
    private val tokens: BotTokenPrincipalPort,
    private val attributions: BotAttributionRegistry,
    private val approvals: BotInteractiveApprovalCanceller? = null,
    private val now: () -> Long = { System.currentTimeMillis() },
    public val runtimeId: String = DEFAULT_RUNTIME_ID,
    private val knownTools: Set<String> = BotToolNames.DEFAULT_KNOWN,
) : BotApprovalRegistrationResolver {
    private data class Key(
        val scopedRuntimeId: String,
        val sessionId: String,
        val callId: String,
    )

    private val lock = Any()
    private val registrations = LinkedHashMap<Key, BotAttribution>()
    private val registrationArguments = HashMap<String, JsonValue>()
    private var generation: Long = 0

    public fun scopedRuntimeId(runtimeId: String = this.runtimeId): String =
        "$runtimeId@$generation"

    public fun register(request: BotIdentityRegistrationRequest): BotIdentityRegisterResult {
        if (request.runtimeId != runtimeId || !request.nameProvided) {
            return BotIdentityRegisterResult(false, error = "invalid identity registration")
        }
        val token = request.sessionToken
        if (token.isNullOrEmpty()) {
            return BotIdentityRegisterResult(false, error = "unauthorized")
        }
        val principal = tokens.lookup(token)
            ?: return BotIdentityRegisterResult(false, error = "unauthorized")
        if (principal.sessionId != request.sessionId) {
            return BotIdentityRegisterResult(false, error = "unauthorized")
        }
        val bareName = BotToolNames.bare(request.name)
        if (bareName !in knownTools) {
            return BotIdentityRegisterResult(false, error = "unknown_tool")
        }
        val computedDigest = BotArgumentsDigest.string(request.arguments)
        val supplied = request.argsDigest
        val digest: String
        if (supplied != null) {
            if (request.argumentsProvided) {
                // The handler compares the supplied string byte-for-byte with
                // the canonical digest before the runtime validators run, so a
                // malformed or upper-cased value with arguments present is the
                // same `argument digest mismatch` answer.
                if (supplied != computedDigest) {
                    return BotIdentityRegisterResult(false, error = "argument digest mismatch")
                }
                digest = BotArgumentsDigest.validated(supplied)
            } else {
                digest = BotArgumentsDigest.validatedOrNull(supplied)
                    ?: return BotIdentityRegisterResult(false, error = "identity registration refused")
            }
        } else {
            digest = computedDigest
        }
        val scope = scopedRuntimeId()
        val key = Key(scope, principal.sessionId, request.callId)
        synchronized(lock) {
            val existing = registrations[key]
            if (existing != null &&
                existing.sessionId == principal.sessionId &&
                existing.name == bareName &&
                existing.argsDigest == digest &&
                existing.incarnation == principal.incarnation
            ) {
                val refreshed = attributions.refresh(existing.id)
                if (refreshed != null) {
                    registrations[key] = refreshed
                    registrationArguments[refreshed.id] = request.arguments
                    return BotIdentityRegisterResult(true, id = refreshed.id)
                }
            }
        }
        val attribution = try {
            attributions.register(
                sessionId = principal.sessionId,
                incarnation = principal.incarnation,
                callId = request.callId,
                name = bareName,
                arguments = request.arguments,
                argsDigest = digest,
                runtimeId = scope,
            )
        } catch (error: BotAttributionException) {
            if (error.code == "duplicate") {
                val existing = attributions.entriesFor(scope, request.callId, principal.sessionId)
                    .firstOrNull {
                        it.incarnation == principal.incarnation && it.name == bareName &&
                            it.argsDigest == digest
                    }
                if (existing != null) {
                    synchronized(lock) {
                        registrations[key] = existing
                        registrationArguments[existing.id] = request.arguments
                    }
                    return BotIdentityRegisterResult(true, id = existing.id)
                }
            }
            return BotIdentityRegisterResult(false, error = "identity registration refused")
        }
        // Rotation/revoke between resolution and publish fails closed.
        val current = tokens.lookup(token)
        if (current == null || current.sessionId != request.sessionId ||
            current.incarnation != principal.incarnation
        ) {
            attributions.cancel(attribution.id)
            return BotIdentityRegisterResult(false, error = "unauthorized")
        }
        synchronized(lock) {
            registrations[key] = attribution
            registrationArguments[attribution.id] = request.arguments
        }
        return BotIdentityRegisterResult(true, id = attribution.id)
    }

    /** Cancels a registration and its interactive approvals; unknown id -> false. */
    public fun cancel(id: String): Boolean {
        val local = synchronized(lock) {
            val match = registrations.entries.firstOrNull { it.value.id == id }
            if (match != null) {
                registrations.remove(match.key)
                registrationArguments.remove(match.value.id)
                match.value
            } else {
                null
            }
        }
        val attribution = local ?: attributions.get(id) ?: return false
        approvals?.cancelInteractive(attribution.sessionId, attribution.callId)
        return attributions.cancel(id)
    }

    override fun resolve(
        runtimeId: String,
        sessionId: String?,
        callId: String,
    ): BotResolvedToolCall? {
        pruneExpired()
        val scope = scopedRuntimeId(runtimeId)
        val matches = attributions.entriesFor(scope, callId, sessionId)
            .filter { it.expiresAt > now() }
        if (matches.size != 1) return null
        val attribution = matches.first()
        val principal = tokens.lookupSession(attribution.sessionId) ?: return null
        if (principal.incarnation != attribution.incarnation) return null
        val arguments = synchronized(lock) {
            registrationArguments[attribution.id]
        } ?: JsonObject(emptyMap())
        return BotResolvedToolCall(
            sessionId = attribution.sessionId,
            callId = attribution.callId,
            botId = principal.botId,
            principal = principal,
            attribution = attribution,
            arguments = arguments,
        )
    }

    /** Clears the previous generation and its interactive approvals. */
    public fun workerRestarted(): Int {
        val previous = scopedRuntimeId()
        generation += 1
        synchronized(lock) {
            registrations.clear()
            registrationArguments.clear()
        }
        attributions.cancelRuntime(previous)
        return approvals?.cancelInteractive("worker_restarted") ?: 0
    }

    /** Removes expired local entries and registry rows. */
    public fun pruneExpired(): Int {
        val timestamp = now()
        val expired = synchronized(lock) {
            val matches = registrations.filter { it.value.expiresAt <= timestamp }
            for ((key, attribution) in matches) {
                registrations.remove(key)
                registrationArguments.remove(attribution.id)
                attributions.cancel(attribution.id)
            }
            matches.size
        }
        attributions.prune()
        return expired
    }

    public fun registrationCount(): Int = synchronized(lock) { registrations.size }

    public companion object {
        public const val DEFAULT_RUNTIME_ID: String = "phone-worker"
    }
}
