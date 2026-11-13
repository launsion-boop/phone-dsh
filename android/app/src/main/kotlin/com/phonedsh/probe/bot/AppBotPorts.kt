// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.authz.BotArgumentsDigest
import com.phonedsh.bot.authz.BotAuditLog
import com.phonedsh.bot.authz.BotAuthzEvent
import com.phonedsh.bot.authz.BotAuthzEventLog
import com.phonedsh.bot.authz.BotAuthzPrincipal
import com.phonedsh.bot.authz.BotExecutionAuthorizer
import com.phonedsh.bot.authz.BotExecutionPrincipal
import com.phonedsh.bot.authz.BotGrantStore
import com.phonedsh.bot.authz.BotToolEffects
import com.phonedsh.bot.authz.BotToolMutability
import com.phonedsh.bot.authz.BotToolPolicy
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.gateway.BotAttribution
import com.phonedsh.bot.gateway.BotGatewayPrincipal
import com.phonedsh.bot.gateway.BotTokenRegistry
import com.phonedsh.bot.mcp.BotGrantDecision
import com.phonedsh.bot.mcp.BotMCPEvent
import com.phonedsh.bot.mcp.BotMCPEventSink
import com.phonedsh.bot.mcp.BotMCPPrincipalKind
import com.phonedsh.bot.mcp.BotMCPToolException
import com.phonedsh.bot.mcp.BotMemoryLookup
import com.phonedsh.bot.mcp.BotMemoryRecallPage as McpMemoryRecallPage
import com.phonedsh.bot.mcp.BotMemoryWriteRequest as McpMemoryWriteRequest
import com.phonedsh.bot.mcp.BotRoutineAssessment
import com.phonedsh.bot.mcp.BotRoutineLookup
import com.phonedsh.bot.mcp.BotTaskPort
import com.phonedsh.bot.mcp.BotTaskStartRequest
import com.phonedsh.bot.mcp.BotTeamToolHandler
import com.phonedsh.bot.mcp.BotToolCallContext
import com.phonedsh.bot.mcp.BotUserMessagePort
import com.phonedsh.bot.mcp.BotMCPCallResult
import com.phonedsh.bot.memory.BotMemory
import com.phonedsh.bot.memory.BotMemoryAction
import com.phonedsh.bot.memory.BotMemoryAuthorKind
import com.phonedsh.bot.memory.BotMemorySource
import com.phonedsh.bot.memory.BotMemorySourceKind
import com.phonedsh.bot.memory.BotMemoryTrust
import com.phonedsh.bot.memory.BotMemoryWriteContext
import com.phonedsh.bot.memory.BotMemoryWriteRequest as DomainMemoryWriteRequest
import com.phonedsh.bot.wake.AutomationStatus
import com.phonedsh.bot.routines.RoutineDeliveryMode
import com.phonedsh.bot.routines.RoutineError
import com.phonedsh.bot.routines.RoutineMachine
import com.phonedsh.bot.routines.RoutinePatch
import com.phonedsh.bot.routines.RoutineSchedule
import com.phonedsh.bot.session.BotSessionKind
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventCodec
import com.phonedsh.bot.store.BotEventOrigin
import com.phonedsh.bot.store.BotPrincipal
import java.util.UUID

/** The P25 store behind the B5a2 authz port; one envelope, no second log. */
class AppBotAuthzEventLog(
    private val store: BotDomainStore,
    private val types: Set<String>? = null,
    private val clock: () -> Long = { System.currentTimeMillis() },
) : BotAuthzEventLog {
    override fun append(event: BotAuthzEvent): Long {
        val principal = event.principal
        return store.append(
            BotEvent(
                schemaVersion = BotEventCodec.CURRENT_SCHEMA_VERSION,
                type = event.type,
                eventId = event.eventId.ifEmpty {
                    "authz-${UUID.randomUUID().toString().lowercase()}"
                },
                commitSeq = null,
                time = if (event.time == 0L) clock() else event.time,
                origin = BotEventOrigin.Local("runtime"),
                traceId = "trace:${event.eventId}",
                principal = BotPrincipal(
                    botId = principal?.botId,
                    sessionId = principal?.sessionId,
                    kind = principalKind(principal?.kind),
                    capabilities = principal?.capabilities ?: emptyList(),
                ),
                causationId = null,
                correlationId = null,
                data = event.data,
            ),
        )
    }

    override fun events(after: Long, limit: Int): List<BotAuthzEvent> =
        store.events(after.toInt(), limit).mapNotNull { event ->
            if (types != null && event.type !in types) return@mapNotNull null
            val sequence = event.commitSeq ?: return@mapNotNull null
            BotAuthzEvent(
                sequence = sequence,
                type = event.type,
                eventId = event.eventId,
                time = event.time,
                principal = BotAuthzPrincipal(
                    botId = event.principal.botId,
                    sessionId = event.principal.sessionId,
                    kind = event.principal.kind,
                    capabilities = event.principal.capabilities,
                ),
                data = (event.data as? JsonObject) ?: JsonObject(emptyMap()),
            )
        }

    companion object {
        val GRANT_TYPES: Set<String> = setOf(
            "authz.grant_snapshot", "grant.added", "grant.consumed", "grant.revoked",
            "grant.migrated", "effect.attempted",
        )
        val APPROVAL_TYPES: Set<String> = setOf(
            "approval.requested", "approval.decided",
        )
    }

    private fun principalKind(kind: String?): String = when (kind) {
        "chat", "task", "routine", "verifier", "team", "proactive", "watchdog",
        "maintainer", "ipc",
        -> kind
        else -> "ipc"
    }
}

/** Writes the MCP tool runtime's durable rows through the same P25 store. */
class AppBotMCPEventSink(
    private val store: BotDomainStore,
    private val clock: () -> Long = { System.currentTimeMillis() },
) : BotMCPEventSink {
    override suspend fun append(event: BotMCPEvent) {
        val eventId = event.eventId
            ?: "mcp-${event.type}-${UUID.randomUUID().toString().lowercase()}"
        store.append(
            BotEvent(
                schemaVersion = BotEventCodec.CURRENT_SCHEMA_VERSION,
                type = event.type,
                eventId = eventId,
                commitSeq = null,
                time = clock(),
                origin = BotEventOrigin.Local("mcp"),
                traceId = "trace:$eventId",
                principal = BotPrincipal(
                    botId = event.principal.botId,
                    sessionId = event.principal.sessionId,
                    kind = event.principal.kind.wire,
                    capabilities = event.principal.capabilities.toList(),
                ),
                causationId = null,
                correlationId = null,
                data = event.data,
            ),
        )
    }
}

/** B2's memory facade behind B5a1's three memory tools. */
class AppBotMemoryLookup(
    private val memory: BotMemory,
    private val now: () -> Long = { System.currentTimeMillis() },
) : BotMemoryLookup {
    override suspend fun promptBlock(botId: String, language: String): String =
        memory.promptBlock()

    override suspend fun update(
        botId: String,
        request: McpMemoryWriteRequest,
        context: BotToolCallContext,
    ): JsonValue {
        val action = BotMemoryAction.parse(request.action)
            ?: throw BotMCPToolException(
                "invalid_arguments",
                "unsupported memory action: ${request.action}",
            )
        val result = memory.write(
            DomainMemoryWriteRequest(
                action = action,
                path = request.path,
                content = request.content,
                find = request.find,
                replace = request.replace,
                to = request.to,
                expectedVersion = request.expectedVersion,
                restoreVersion = request.restoreVersion,
                evidence = request.evidence,
                markedContradiction = request.markedContradiction,
            ),
            BotMemoryWriteContext(
                botId = botId,
                sessionId = context.sessionId,
                authorKind = BotMemoryAuthorKind.CHAT,
                source = BotMemorySource(
                    kind = if (context.isUserTurn) {
                        BotMemorySourceKind.USER_TURN
                    } else {
                        BotMemorySourceKind.AGENT_MESSAGE
                    },
                    sessionId = context.sessionId,
                    role = "assistant",
                ),
                trust = BotMemoryTrust.ASSISTANT,
                isMainBot = context.principal.botId == botId,
            ),
        )
        return result.toJson()
    }

    override suspend fun read(botId: String, path: String, version: Int?): JsonValue =
        when (val result = memory.read(path, version)) {
            is com.phonedsh.bot.memory.BotMemoryReadResult.Document -> result.toJson()
            is com.phonedsh.bot.memory.BotMemoryReadResult.Directory -> result.toJson()
            is com.phonedsh.bot.memory.BotMemoryReadResult.Failure -> result.toJson()
        }

    override suspend fun recall(
        botId: String,
        query: String,
        limit: Int,
        scope: String?,
    ): McpMemoryRecallPage {
        val parsedScope = scope?.let {
            com.phonedsh.bot.memory.BotMemoryScope.parse(it)
                ?: throw BotMCPToolException("invalid_arguments", "unknown memory scope: $it")
        }
        val page = memory.recallPage(query = query, limit = limit, scope = parsedScope)
        return McpMemoryRecallPage(
            hits = page.hits.map { it.toJson() },
            total = page.total,
        )
    }
}

/** B3's routine machine behind B5a1's routine tools. */
class AppBotRoutineLookup(
    private val machine: RoutineMachine,
    private val now: () -> Long = { System.currentTimeMillis() },
) : BotRoutineLookup {
    override suspend fun automationStatus(botId: String, now: Long, language: String): String =
        AutomationStatus.block(machine.list(botId), now, language)

    override suspend fun assess(botId: String, arguments: JsonValue): BotRoutineAssessment {
        val args = (arguments as? JsonObject)?.members ?: emptyMap()
        val action = (args["action"] as? JsonString)?.value
            ?: throw BotMCPToolException("invalid_arguments", "UpdateRoutine requires action")
        val requires = when (action) {
            "create", "delete", "pause" -> true
            "update" -> args.keys.any { it in setOf("enabled", "urgent", "delivery", "schedule") }
            "resume" -> machine.list(botId).any { !it.enabled }
            else -> false
        }
        val routineId = (args["routine_id"] as? JsonString)?.value.orEmpty()
        return BotRoutineAssessment(
            action = action,
            requiresConfirmation = requires,
            detail = if (routineId.isEmpty()) "routine $action" else "routine $action: $routineId",
            resource = "routine:${routineId.ifEmpty { "*" }}",
        )
    }

    override suspend fun update(
        botId: String,
        arguments: JsonValue,
        context: BotToolCallContext,
    ): JsonValue {
        val args = (arguments as? JsonObject)?.members ?: emptyMap()
        val action = (args["action"] as? JsonString)?.value
            ?: throw BotMCPToolException("invalid_arguments", "UpdateRoutine requires action")
        val timestamp = now()
        return try {
            when (action) {
                "create" -> {
                    val schedule = RoutineSchedule.fromJson(args["schedule"])
                    val routine = machine.create(
                        botId = botId,
                        title = string(args, "title"),
                        prompt = string(args, "prompt"),
                        schedule = schedule,
                        enabled = bool(args, "enabled") ?: true,
                        idempotent = bool(args, "idempotent") ?: false,
                        urgent = bool(args, "urgent") ?: false,
                        urgentReason = string(args, "urgent_reason", required = false),
                        delivery = delivery(args),
                        interruptReason = string(args, "interrupt_reason", required = false),
                        completionCriteria = string(args, "completion_criteria", required = false),
                        constraints = string(args, "constraints", required = false),
                        now = timestamp,
                    )
                    routineResult("created", routine.toJson())
                }
                "update" -> {
                    val id = requiredId(args)
                    val patch = RoutinePatch(
                        title = optionalString(args, "title"),
                        prompt = optionalString(args, "prompt"),
                        schedule = args["schedule"]?.let { RoutineSchedule.fromJson(it) },
                        enabled = bool(args, "enabled"),
                        idempotent = bool(args, "idempotent"),
                        urgent = bool(args, "urgent"),
                        urgentReason = optionalString(args, "urgent_reason"),
                        delivery = if (args.containsKey("delivery")) delivery(args) else null,
                        interruptReason = optionalString(args, "interrupt_reason"),
                        completionCriteria = optionalString(args, "completion_criteria"),
                        constraints = optionalString(args, "constraints"),
                    )
                    routineResult("updated", machine.update(botId, id, patch, timestamp).toJson())
                }
                "delete" -> {
                    val id = requiredId(args)
                    val removed = machine.delete(botId, id)
                    JsonObject(
                        linkedMapOf(
                            "ok" to JsonBool(removed != null),
                            "action" to JsonString("delete"),
                            "routine_id" to JsonString(id),
                        ),
                    )
                }
                "get" -> {
                    val id = requiredId(args)
                    val routine = machine.get(botId, id)
                        ?: throw RoutineError.RoutineNotFound(id)
                    routineResult("got", routine.toJson())
                }
                "list" -> JsonObject(
                    linkedMapOf(
                        "ok" to JsonBool(true),
                        "action" to JsonString("list"),
                        "routines" to JsonArray(machine.list(botId).map { it.toJson() }),
                    ),
                )
                "pause", "resume" -> {
                    val id = requiredId(args)
                    val enabled = action == "resume"
                    val routine = machine.update(
                        botId,
                        id,
                        RoutinePatch(enabled = enabled),
                        timestamp,
                    )
                    routineResult(if (enabled) "resumed" else "paused", routine.toJson())
                }
                else -> throw BotMCPToolException(
                    "invalid_arguments",
                    "unsupported UpdateRoutine action: $action",
                )
            }
        } catch (error: RoutineError) {
            throw BotMCPToolException(error.code, error.message ?: error.code)
        }
    }

    override suspend fun list(botId: String): JsonValue = JsonObject(
        linkedMapOf(
            "ok" to JsonBool(true),
            "routines" to JsonArray(machine.list(botId).map { it.toJson() }),
        ),
    )

    private fun routineResult(action: String, routine: JsonObject): JsonObject =
        JsonObject(
            linkedMapOf(
                "ok" to JsonBool(true),
                "action" to JsonString(action),
                "routine" to routine,
            ),
        )

    private fun requiredId(args: Map<String, JsonValue>): String =
        (args["routine_id"] as? JsonString)?.value?.takeIf { it.isNotBlank() }
            ?: throw BotMCPToolException("invalid_arguments", "routine_id is required")

    private fun string(
        args: Map<String, JsonValue>,
        name: String,
        required: Boolean = true,
    ): String {
        val value = (args[name] as? JsonString)?.value.orEmpty()
        if (required && value.isBlank()) {
            throw BotMCPToolException("invalid_arguments", "$name is required")
        }
        return value
    }

    private fun optionalString(args: Map<String, JsonValue>, name: String): String? =
        (args[name] as? JsonString)?.value

    private fun bool(args: Map<String, JsonValue>, name: String): Boolean? =
        (args[name] as? JsonBool)?.value

    private fun delivery(args: Map<String, JsonValue>): RoutineDeliveryMode =
        RoutineDeliveryMode.from(optionalString(args, "delivery"))
}

/** B5a2's standing grants behind B5a1's execution gate. */
class AppBotGrantPort(
    private val grants: BotGrantStore,
    private val now: () -> Long = { System.currentTimeMillis() },
) : com.phonedsh.bot.mcp.BotGrantPort {
    private val authorizer = BotExecutionAuthorizer(grants, now = now)

    override suspend fun authorize(
        context: BotToolCallContext,
        name: String,
        arguments: JsonValue,
    ): BotGrantDecision {
        val effect = BotToolEffects.effect(name, arguments)
        if (effect.mutability == BotToolMutability.READ ||
            effect.policy == BotToolPolicy.AUTO || effect.ui
        ) {
            return BotGrantDecision(true, "read-only")
        }
        val principal = BotExecutionPrincipal.fromGateway(context.principal.toGateway(now()))
        val decision = authorizer.authorizeExecution(
            principal = principal,
            effects = listOf(effect),
            argsDigest = BotArgumentsDigest.string(arguments),
        )
        return BotGrantDecision(decision.allowed, decision.reason)
    }
}

/** The `/identity/register` token lookup (B5a2 registry -> B5a1 port). */
class AppBotTokenPrincipalPort(
    private val tokens: BotTokenRegistry,
) : com.phonedsh.bot.mcp.BotTokenPrincipalPort {
    override suspend fun principalForSessionToken(token: String) =
        tokens.lookup(token)?.toMcp()

    override suspend fun principalForSessionId(sessionId: String) =
        tokens.lookupSession(sessionId)?.toMcp()
}

/** `SendToUser` through the same durable event/row projection. */
class AppBotUserMessagePort(
    private val store: BotDomainStore,
    private val events: BotMCPEventSink,
    private val clock: () -> Long = { System.currentTimeMillis() },
) : BotUserMessagePort {
    override suspend fun sendToUser(context: BotToolCallContext, message: String): String {
        val rowId = "e-${context.principal.botId}-send-${UUID.randomUUID().toString().lowercase()}"
        events.append(
            BotMCPEvent(
                type = "ui.send_to_user",
                principal = context.principal,
                data = BotJson.objectOf(
                    "id" to JsonString(rowId),
                    "type" to JsonString("text"),
                    "role" to JsonString("assistant"),
                    "text" to JsonString(message),
                    "content" to JsonString(message),
                ),
            ),
        )
        return rowId
    }
}

/** Team tools are not part of this lane; the names are answered honestly. */
class AppBotTeamStub : BotTeamToolHandler {
    override fun handles(name: String): Boolean =
        name == "SendToAgent" || name == "CreateTeammate"

    override suspend fun execute(
        name: String,
        arguments: JsonValue,
        context: BotToolCallContext,
    ): BotMCPCallResult = BotMCPCallResult.failure(
        "unavailable",
        "团队工具尚未接入 App Bot runtime",
    )
}

/** Tasks have no child-session runner in this lane; the port fails closed. */
object AppBotTaskPort : BotTaskPort {
    override suspend fun start(request: BotTaskStartRequest): JsonValue =
        throw BotMCPToolException("unavailable", "Task execution is not configured")

    override suspend fun await(
        taskId: String,
        timeoutMs: Int,
        context: BotToolCallContext,
    ): JsonValue = throw BotMCPToolException("unavailable", "Task execution is not configured")

    override suspend fun stop(taskId: String, context: BotToolCallContext): JsonValue =
        throw BotMCPToolException("unavailable", "Task execution is not configured")
}

internal fun BotGatewayPrincipal.toMcp(): com.phonedsh.bot.mcp.BotMCPPrincipal =
    com.phonedsh.bot.mcp.BotMCPPrincipal(
        botId = botId,
        sessionId = sessionId,
        kind = BotMCPPrincipalKind.fromWire(kind.wire) ?: BotMCPPrincipalKind.CHAT,
        capabilities = capabilities.toSet(),
        expiresAt = expiresAt,
    )

internal fun com.phonedsh.bot.mcp.BotMCPPrincipal.toGateway(now: Long): BotGatewayPrincipal =
    BotGatewayPrincipal(
        botId = botId,
        sessionId = sessionId,
        kind = BotSessionKind.fromWire(kind.wire),
        capabilities = capabilities.toList(),
        expiresAt = if (expiresAt > 0) expiresAt else now + 60_000,
        incarnation = "",
    )
