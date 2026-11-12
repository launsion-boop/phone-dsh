// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson

/**
 * The host side of the Bot MCP lane. B5a1 deliberately owns only these
 * interfaces; B2 (memory), B3 (routines), B5a2 (authz/approval) and B5b
 * (listener) provide adapters. No port exposes a store, a token or an
 * approval coordinator internal type.
 */

/** The catalog a caller may see (`toolDefinitions(callerBotID:)`, §7.3). */
public fun interface BotMCPToolCatalogProvider {
    public fun definitions(callerBotId: String?): List<BotMCPToolDefinition>
}

/**
 * Session credential lookup (§9.1). Both methods are read-only; issue/rotate/
 * revoke are B5a2. A null result is the static catalog / `unauthorized`.
 */
public interface BotTokenPrincipalPort {
    /** Resolve an App-issued `dshg_` token for `/identity/register` and `/approval`. */
    public suspend fun principalForSessionToken(token: String): BotMCPPrincipal?

    /** Resolve the MCP session id header for `tools/list` only (§7.3). */
    public suspend fun principalForSessionId(sessionId: String): BotMCPPrincipal?
}

public object EmptyBotTokenPrincipalPort : BotTokenPrincipalPort {
    override suspend fun principalForSessionToken(token: String): BotMCPPrincipal? = null
    override suspend fun principalForSessionId(sessionId: String): BotMCPPrincipal? = null
}

/**
 * The attribution registry's claim step (§9.2). A successful claim atomically
 * removes the registration and its argument copy; a second call with the same
 * arguments must therefore fail with `unattributed`.
 */
public interface BotAttributionPort {
    public suspend fun claim(
        runtimeId: String,
        name: String,
        arguments: JsonValue,
    ): BotResolvedToolCall?
}

public object EmptyBotAttributionPort : BotAttributionPort {
    override suspend fun claim(runtimeId: String, name: String, arguments: JsonValue): BotResolvedToolCall? = null
}

public data class BotGrantDecision(
    public val allowed: Boolean,
    public val reason: String? = null,
)

/** B5a2's standing-grant/authorization seam; the default allows (no grants attached). */
public interface BotGrantPort {
    public suspend fun authorize(
        context: BotToolCallContext,
        name: String,
        arguments: JsonValue,
    ): BotGrantDecision
}

public object AllowAllBotGrantPort : BotGrantPort {
    override suspend fun authorize(
        context: BotToolCallContext,
        name: String,
        arguments: JsonValue,
    ): BotGrantDecision = BotGrantDecision(true)
}

/** The approval outcome shared by `/approval` and `RequestApproval`. */
public data class BotApprovalOutcome(
    public val allowed: Boolean,
    public val pending: Boolean = false,
    public val approvalId: String? = null,
    public val message: String? = null,
    public val expiresAt: Long? = null,
    public val approvalDecision: String? = null,
    public val scope: String? = null,
) {
    public val decision: String get() = if (allowed) "allowed" else "denied"
}

/**
 * B5a2's approval seam. `requestApproval` is the `RequestApproval` tool;
 * `requestStructuralApproval` is the update-routine/create-teammate card.
 * `approve` is the body-validated `/approval` call; B5a1 does not route it.
 */
public interface BotApprovalPort {
    public suspend fun requestApproval(
        context: BotToolCallContext,
        action: String,
        detail: String,
        command: String,
    ): BotApprovalOutcome

    public suspend fun requestStructuralApproval(
        context: BotToolCallContext,
        tool: String,
        detail: String,
        resource: String,
        alwaysScope: String = "none",
    ): BotApprovalOutcome

    public suspend fun approve(request: BotApprovalRequest): BotApprovalOutcome
}

public object UnavailableBotApprovalPort : BotApprovalPort {
    override suspend fun requestApproval(
        context: BotToolCallContext,
        action: String,
        detail: String,
        command: String,
    ): BotApprovalOutcome = throw BotMCPToolException("unavailable", "审批服务尚未接入")

    override suspend fun requestStructuralApproval(
        context: BotToolCallContext,
        tool: String,
        detail: String,
        resource: String,
        alwaysScope: String,
    ): BotApprovalOutcome = throw BotMCPToolException("unavailable", "审批服务尚未接入")

    override suspend fun approve(request: BotApprovalRequest): BotApprovalOutcome =
        throw BotMCPToolException("unavailable", "审批服务尚未接入")
}

// ---------------------------------------------------------------------------
// Memory ports (B2 adapter)
// ---------------------------------------------------------------------------

public data class BotMemoryWriteRequest(
    public val action: String,
    public val path: String,
    public val content: String? = null,
    public val find: String? = null,
    public val replace: String? = null,
    public val to: String? = null,
    public val expectedVersion: Int,
    public val restoreVersion: Int? = null,
    public val evidence: List<String> = emptyList(),
    public val markedContradiction: Boolean = false,
)

public data class BotMemoryRecallPage(
    public val hits: List<JsonValue>,
    public val total: Int,
)

/**
 * The three memory primitives plus the injection block. The adapter owns the
 * document tree, scopes, trust and record references; B5a1 owns only the MCP
 * argument rules and result envelope.
 */
public interface BotMemoryLookup {
    public suspend fun promptBlock(botId: String, language: String): String

    public suspend fun update(
        botId: String,
        request: BotMemoryWriteRequest,
        context: BotToolCallContext,
    ): JsonValue

    public suspend fun read(botId: String, path: String, version: Int?): JsonValue

    public suspend fun recall(
        botId: String,
        query: String,
        limit: Int,
        scope: String?,
    ): BotMemoryRecallPage
}

public object UnavailableBotMemoryLookup : BotMemoryLookup {
    override suspend fun promptBlock(botId: String, language: String): String =
        throw BotMemoryUnavailableException("memory is not attached")

    override suspend fun update(
        botId: String,
        request: BotMemoryWriteRequest,
        context: BotToolCallContext,
    ): JsonValue = throw BotMemoryUnavailableException("memory is not attached")

    override suspend fun read(botId: String, path: String, version: Int?): JsonValue =
        throw BotMemoryUnavailableException("memory is not attached")

    override suspend fun recall(
        botId: String,
        query: String,
        limit: Int,
        scope: String?,
    ): BotMemoryRecallPage = throw BotMemoryUnavailableException("memory is not attached")
}

// ---------------------------------------------------------------------------
// Routine ports (B3 adapter)
// ---------------------------------------------------------------------------

public data class BotRoutineAssessment(
    public val action: String?,
    public val requiresConfirmation: Boolean,
    public val detail: String,
    public val resource: String,
)

/**
 * Routines are owned by B3. This lane only asks whether a change needs the
 * structural approval card, then delegates the actual create/update/delete/
 * list/get/pause/resume and the `<automation_status>` rendering.
 */
public interface BotRoutineLookup {
    public suspend fun automationStatus(botId: String, now: Long, language: String): String

    public suspend fun assess(botId: String, arguments: JsonValue): BotRoutineAssessment

    public suspend fun update(
        botId: String,
        arguments: JsonValue,
        context: BotToolCallContext,
    ): JsonValue

    public suspend fun list(botId: String): JsonValue
}

public object UnavailableBotRoutineLookup : BotRoutineLookup {
    override suspend fun automationStatus(botId: String, now: Long, language: String): String =
        throw BotMCPToolException("unavailable", "routine status is not attached")

    override suspend fun assess(botId: String, arguments: JsonValue): BotRoutineAssessment =
        throw BotMCPToolException("unavailable", "routines are not attached")

    override suspend fun update(
        botId: String,
        arguments: JsonValue,
        context: BotToolCallContext,
    ): JsonValue = throw BotMCPToolException("unavailable", "routines are not attached")

    override suspend fun list(botId: String): JsonValue =
        throw BotMCPToolException("unavailable", "routines are not attached")
}

// ---------------------------------------------------------------------------
// Task / UI / team / event ports
// ---------------------------------------------------------------------------

public data class BotTaskBudget(public val maxDurationMs: Int? = null)

public data class BotTaskStartRequest(
    public val context: BotToolCallContext,
    public val title: String,
    public val prompt: String,
    public val asynchronous: Boolean,
    public val timeoutMs: Int,
    public val completion: String,
    public val purpose: String?,
    public val constraints: List<String>,
    public val budget: BotTaskBudget?,
    public val arguments: JsonValue,
)

/** B4/B5b task executor; it returns the frozen task record (plus authorization). */
public interface BotTaskPort {
    public suspend fun start(request: BotTaskStartRequest): JsonValue

    public suspend fun await(taskId: String, timeoutMs: Int, context: BotToolCallContext): JsonValue

    public suspend fun stop(taskId: String, context: BotToolCallContext): JsonValue
}

public object UnavailableBotTaskPort : BotTaskPort {
    override suspend fun start(request: BotTaskStartRequest): JsonValue =
        throw BotMCPToolException("unavailable", "Task execution is not configured")

    override suspend fun await(taskId: String, timeoutMs: Int, context: BotToolCallContext): JsonValue =
        throw BotMCPToolException("unavailable", "Task execution is not configured")

    override suspend fun stop(taskId: String, context: BotToolCallContext): JsonValue =
        throw BotMCPToolException("unavailable", "Task execution is not configured")
}

/** The `ui.send_to_user` row writer. */
public interface BotUserMessagePort {
    public suspend fun sendToUser(context: BotToolCallContext, message: String): String
}

public object UnavailableBotUserMessagePort : BotUserMessagePort {
    override suspend fun sendToUser(context: BotToolCallContext, message: String): String =
        throw BotMCPToolException("unavailable", "the chat UI is not attached")
}

/** Host-registered team/fish tools (`SendToAgent`, `CreateTeammate`, `FishAction`). */
public interface BotTeamToolHandler {
    public fun handles(name: String): Boolean

    public suspend fun execute(
        name: String,
        arguments: JsonValue,
        context: BotToolCallContext,
    ): BotMCPCallResult
}

public data class BotMCPEvent(
    public val type: String,
    public val principal: BotMCPPrincipal,
    public val data: JsonValue,
    public val eventId: String? = null,
)

/** Durable event sink (card.presented, ui.send_to_user, task.*, routine.*). */
public interface BotMCPEventSink {
    public suspend fun append(event: BotMCPEvent)
}

public object NoopBotMCPEventSink : BotMCPEventSink {
    override suspend fun append(event: BotMCPEvent) = Unit
}

// ---------------------------------------------------------------------------
// Identity / approval handler-side bodies (§8). B5a2 owns their validation.
// ---------------------------------------------------------------------------

public data class BotIdentityRegistration(
    public val runtimeId: String,
    public val sessionId: String,
    public val callId: String,
    public val name: String,
    public val arguments: JsonValue,
    public val argsDigest: String? = null,
    public val sessionToken: String? = null,
) {
    public companion object {
        /** Shape-only parse; B5a2 owns the runtime-id/token/digest refusals. */
        public fun fromJson(value: JsonValue): BotIdentityRegistration? {
            val members = (value as? com.phonedsh.agentcore.JsonObject)?.members ?: return null
            val runtimeId = (members["runtimeId"] as? com.phonedsh.agentcore.JsonString)?.value
                ?: return null
            val sessionId = (members["sessionId"] as? com.phonedsh.agentcore.JsonString)?.value
                ?: return null
            val callId = (members["callId"] as? com.phonedsh.agentcore.JsonString)?.value
                ?: return null
            val name = (members["name"] as? com.phonedsh.agentcore.JsonString)?.value
                ?: return null
            return BotIdentityRegistration(
                runtimeId = runtimeId,
                sessionId = sessionId,
                callId = callId,
                name = name,
                arguments = members["arguments"] ?: com.phonedsh.agentcore.JsonObject(emptyMap()),
                argsDigest = (members["argsDigest"] as? com.phonedsh.agentcore.JsonString)?.value,
                sessionToken = (members["sessionToken"] as? com.phonedsh.agentcore.JsonString)?.value,
            )
        }
    }
}

public data class BotApprovalRequest(
    public val sessionId: String,
    public val callId: String,
    public val tool: String,
    public val argsDigest: String,
    public val alwaysScope: String,
    public val action: String = tool,
    public val detail: String = "",
    public val command: String = "",
    public val effects: List<JsonValue> = emptyList(),
    public val askAction: String = "tool-call",
) {
    public companion object {
        /** Shape-only parse; B5a2 owns the exact refusal and validation order. */
        public fun fromJson(value: JsonValue): BotApprovalRequest? {
            val members = (value as? com.phonedsh.agentcore.JsonObject)?.members ?: return null
            val sessionId = (members["sessionId"] as? com.phonedsh.agentcore.JsonString)?.value
                ?: return null
            val callId = (members["callId"] as? com.phonedsh.agentcore.JsonString)?.value
                ?: return null
            val tool = (members["tool"] as? com.phonedsh.agentcore.JsonString)?.value
                ?: return null
            val argsDigest = (members["argsDigest"] as? com.phonedsh.agentcore.JsonString)?.value
                ?: return null
            val alwaysScope = (members["alwaysScope"] as? com.phonedsh.agentcore.JsonString)?.value
                ?: return null
            val effects = (members["effects"] as? com.phonedsh.agentcore.JsonArray)?.values
                ?: emptyList()
            return BotApprovalRequest(
                sessionId = sessionId,
                callId = callId,
                tool = tool,
                argsDigest = argsDigest,
                alwaysScope = alwaysScope,
                action = (members["action"] as? com.phonedsh.agentcore.JsonString)?.value ?: tool,
                detail = (members["detail"] as? com.phonedsh.agentcore.JsonString)?.value ?: "",
                command = (members["command"] as? com.phonedsh.agentcore.JsonString)?.value ?: "",
                effects = effects,
                askAction = (members["askAction"] as? com.phonedsh.agentcore.JsonString)?.value
                    ?: "tool-call",
            )
        }
    }
}

/** B5a2's `/identity/register` and `/identity/cancel` seam. */
public interface BotIdentityPort {
    public suspend fun register(request: BotIdentityRegistration): JsonValue

    public suspend fun cancel(id: String): Boolean
}

public object UnavailableBotIdentityPort : BotIdentityPort {
    override suspend fun register(request: BotIdentityRegistration): JsonValue =
        BotMCPTypesJson.identityError("identity registration refused")

    override suspend fun cancel(id: String): Boolean = false
}

/** The exact `/identity/register` response objects (§8.1). */
public object BotMCPTypesJson {
    public fun identityOk(id: String): JsonValue = BotJson.objectOf(
        "ok" to com.phonedsh.agentcore.JsonBool(true),
        "id" to com.phonedsh.agentcore.JsonString(id),
    )

    public fun identityError(error: String): JsonValue = BotJson.objectOf(
        "ok" to com.phonedsh.agentcore.JsonBool(false),
        "error" to com.phonedsh.agentcore.JsonString(error),
    )
}
