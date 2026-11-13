// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.cards.BotCardPayloadException
import kotlinx.coroutines.CancellationException
import java.util.concurrent.ConcurrentHashMap

/**
 * The `tools/call` runtime: attribution, per-caller catalog enforcement, the
 * seven card tools, the 17 P0 tools and the volatile producer. Business
 * semantics live behind the ports in `BotMCPPorts.kt`; the argument rules and
 * exact failure sentences in this file come from `tool-contracts.md`.
 */
public class BotMCPToolRuntime(
    private val catalogProvider: BotMCPToolCatalogProvider,
    private val attribution: BotAttributionPort,
    private val volatileContext: BotVolatileContextProducer? = null,
    private val memory: BotMemoryLookup = UnavailableBotMemoryLookup,
    private val routines: BotRoutineLookup = UnavailableBotRoutineLookup,
    private val tasks: BotTaskPort = UnavailableBotTaskPort,
    private val approvals: BotApprovalPort = UnavailableBotApprovalPort,
    private val userMessages: BotUserMessagePort = UnavailableBotUserMessagePort,
    private val grants: BotGrantPort = AllowAllBotGrantPort,
    private val team: BotTeamToolHandler? = null,
    private val events: BotMCPEventSink = NoopBotMCPEventSink,
    private val runtimeId: String = BotMCPProtocol.DEFAULT_RUNTIME_ID,
    private val now: () -> Long = { System.currentTimeMillis() },
) {
    public companion object {
        public const val ASK_USER_TEXT: String = BotMCPCards.ASK_USER_TEXT
        public const val SHOW_NEXT_STEPS_TEXT: String = BotMCPCards.SHOW_NEXT_STEPS_TEXT

        public const val MESSAGE_PERMISSION_DENIED: String = "这个工具不在当前 Bot 的可用工具里"
        public const val MESSAGE_UNATTRIBUTED: String = "这次工具调用无法归属到任何进行中的会话"
        public const val MESSAGE_UNKNOWN_TOOL: String = "未知工具："

        public const val MEMORY_ACTION_MESSAGE: String =
            "更新记忆需要指定动作：write、append、replace、move、delete 或 restore"
        public const val MEMORY_PATH_MESSAGE: String = "更新记忆需要提供路径"
        public const val MEMORY_VERSION_MESSAGE: String = "更新记忆需要提供不小于 0 的版本号"
        public const val MEMORY_EVIDENCE_MESSAGE: String =
            "每条依据都必须指向这个 Bot 已有的一条 record:// 记录，或者是真实用户回合里的 current-user-turn。"
        public const val MEMORY_READ_PATH_MESSAGE: String = "读取记忆需要提供路径"
        public const val RECALL_LIMIT_MESSAGE: String = "回想记忆的条数必须在 1 到 50 之间"
        public const val RECALL_UNAVAILABLE_MESSAGE: String = "记忆暂时读不出来，请稍后重试。"
        public const val ROUTINE_ACTION_MESSAGE: String = "UpdateRoutine requires action"
        public const val TASK_PROMPT_MESSAGE: String = "派发任务需要说明要做什么"
        public const val TASK_TIMEOUT_MESSAGE: String = "任务超时必须在 1000 到 300000 毫秒之间"
        public const val TASK_COMPLETION_MESSAGE: String = "任务的完成条件最多 4000 个字符"
        public const val TASK_PURPOSE_MESSAGE: String = "任务的用途说明最多 2000 个字符"
        public const val TASK_CONSTRAINTS_MESSAGE: String = "任务约束最多 8 条，每条最多 500 个字符"
        public const val TASK_BUDGET_MESSAGE: String = "任务预算只接受 max_duration_ms"
        public const val TASK_BUDGET_RANGE_MESSAGE: String =
            "任务预算的 max_duration_ms 必须在 1000 到 300000 毫秒之间"
        public const val TASK_DIRECTORIES_MESSAGE: String =
            "allowed_write_directories accepts at most 32 entries"
        public const val AWAIT_TASK_ID_MESSAGE: String = "等待任务需要提供任务编号"
        public const val AWAIT_TASK_TIMEOUT_MESSAGE: String = "等待任务的超时必须在 1000 到 600000 毫秒之间"
        public const val STOP_TASK_ID_MESSAGE: String = "停止任务需要提供任务编号"
        public const val APPROVAL_ACTION_MESSAGE: String = "请求审批需要说明要申请什么"
        public const val SEND_TO_USER_KIND_MESSAGE: String = "只有主聊天可以主动发消息"
        public const val SEND_TO_USER_SUPPRESSED_MESSAGE: String = "这一回合的正文输出已被卡片收尾"
        public const val SEND_TO_USER_CONTENT_MESSAGE: String = "主动发消息需要提供内容"
        public const val TASK_DELEGATE_CAPABILITY: String = "task.delegate"
        public const val TASK_ONLY_MESSAGE: String = "只有聊天或任务会话可以派发任务"
        public const val TASK_CHILD_DELEGATE_MESSAGE: String = "当前任务会话里不能再派发任务"

        private val TASK_TERMINAL_STATUSES: Set<String> = setOf("completed", "failed", "stopped")
        private val RECORD_REFERENCE: Regex = Regex(
            "^record://(?:event/[1-9][0-9]*|session/[A-Za-z0-9._-]{1,64}#(?:0|[1-9][0-9]*))$",
            RegexOption.IGNORE_CASE,
        )
    }

    private val suppressedSessions: MutableSet<String> = ConcurrentHashMap.newKeySet()

    /** Called by the host at the start of a turn; clears the card text suppression. */
    public fun beginTurn(sessionId: String) {
        suppressedSessions.remove(sessionId)
    }

    public fun isTextSuppressed(sessionId: String): Boolean = suppressedSessions.contains(sessionId)

    public fun isRegistered(name: String): Boolean = BotToolCatalog.isRegistered(name)

    public fun handlesTeam(name: String): Boolean = team?.handles(name) == true

    public suspend fun execute(
        name: String,
        arguments: JsonValue,
        jsonRpcId: JsonValue = JsonNull,
    ): BotMCPCallResult {
        val bare = bareToolName(name)
        if (!isRegistered(bare) && !handlesTeam(bare)) {
            return BotMCPCallResult.failure(
                "unknown_tool",
                BotMCPProtocol.unknownToolMessage(bare),
            )
        }
        val resolved = try {
            attribution.claim(runtimeId, bare, arguments)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            null
        } ?: return BotMCPCallResult.failure("unattributed", MESSAGE_UNATTRIBUTED)
        val context = BotToolCallContext(
            runtimeId = runtimeId,
            callId = resolved.callId.ifEmpty { botMcpCallId(jsonRpcId) },
            call = resolved,
        )
        try {
            val available = catalogProvider.definitions(context.principal.botId)
            if (available.none { it.name == bare }) {
                return BotMCPCallResult.failure("permission_denied", MESSAGE_PERMISSION_DENIED)
            }
            val grant = grants.authorize(context, bare, arguments)
            if (!grant.allowed) {
                return BotMCPCallResult.failure(
                    "permission_denied",
                    grant.reason ?: "这个工具在当前会话里不被允许",
                )
            }
            return dispatch(bare, arguments, context)
        } catch (error: BotCardPayloadException) {
            return BotMCPCallResult.failure("invalid_arguments", error.message ?: "invalid card arguments")
        } catch (error: BotMCPToolException) {
            return BotMCPCallResult.failure(error.code, error.message ?: error.code)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            return BotMCPCallResult.failure("execution_failed", error.toString())
        }
    }

    private suspend fun dispatch(
        name: String,
        arguments: JsonValue,
        context: BotToolCallContext,
    ): BotMCPCallResult {
        if (name == BotToolCatalog.VOLATILE_CONTEXT_NAME) {
            val producer = volatileContext
                ?: throw BotMCPToolException("unavailable", "volatile context is not attached")
            return BotMCPCallResult.success(producer.snapshot(arguments, context.principal).toJson())
        }
        if (name in BotMCPCards.TOOL_NAMES) return card(name, arguments, context)
        if (team != null && team.handles(name)) return team.execute(name, arguments, context)
        return when (name) {
            "UpdateMemory" -> updateMemory(arguments, context)
            "ReadMemory" -> readMemory(arguments, context)
            "RecallMemory" -> recallMemory(arguments, context)
            "Task" -> startTask(arguments, context)
            "AwaitTask" -> awaitTask(arguments, context)
            "StopSubagent" -> stopTask(arguments, context)
            "UpdateRoutine" -> updateRoutine(arguments, context)
            "ListRoutines" -> listRoutines(context)
            "RequestApproval" -> requestApproval(arguments, context)
            "SendToUser" -> sendToUser(arguments, context)
            else -> throw BotMCPToolException("unknown_tool", MESSAGE_UNKNOWN_TOOL + name)
        }
    }

    // ------------------------------------------------------------------
    // Cards
    // ------------------------------------------------------------------

    private suspend fun card(
        name: String,
        arguments: JsonValue,
        context: BotToolCallContext,
    ): BotMCPCallResult {
        val built = BotMCPCards.build(name, arguments)
        val final = BotMCPCards.contentCardFinal(name, arguments)
        val card = ((built as JsonObject).members["card"] as? JsonObject)
            ?: throw BotMCPToolException("invalid_arguments", "card builder returned no card")
        val cardId = randomHexId("card-")
        val eventFields = LinkedHashMap(card.members)
        eventFields["card"] = card
        eventFields["id"] = JsonString(cardId)
        eventFields["tool"] = JsonString(name)
        eventFields["callId"] = JsonString(context.callId)
        events.append(
            BotMCPEvent(
                type = "card.presented",
                principal = context.principal,
                data = JsonObject(eventFields),
            ),
        )
        if (final) suppressedSessions.add(context.sessionId)
        if (name == "ask_user" || name == "show_next_steps") {
            suppressedSessions.add(context.sessionId)
            return BotMCPCallResult.success(built, BotMCPCards.fixedText(name))
        }
        return BotMCPCallResult.success(built)
    }

    // ------------------------------------------------------------------
    // Memory
    // ------------------------------------------------------------------

    private suspend fun updateMemory(
        arguments: JsonValue,
        context: BotToolCallContext,
    ): BotMCPCallResult {
        if (context.principal.kind == BotMCPPrincipalKind.VERIFIER) {
            return BotMCPCallResult.failure("permission_denied", "验证会话不能写记忆")
        }
        val args = requireObject(arguments)
        val action = textOrNull(args["action"])
        if (action == null || action !in MEMORY_ACTIONS) {
            throw BotMCPToolException("invalid_arguments", MEMORY_ACTION_MESSAGE)
        }
        val path = textOrNull(args["path"])
        if (path.isNullOrEmpty()) {
            throw BotMCPToolException("invalid_arguments", MEMORY_PATH_MESSAGE)
        }
        val expectedVersion = optionalInt(args["expected_version"])
        if (expectedVersion == null || expectedVersion < 0) {
            throw BotMCPToolException("invalid_arguments", MEMORY_VERSION_MESSAGE)
        }
        val evidence = memoryEvidence(args, context)
        val content: String?
        when (action) {
            "write", "append" -> {
                if (!args.containsKey("content")) {
                    throw BotMCPToolException(
                        "invalid_arguments",
                        "更新记忆的 $action 动作需要提供内容",
                    )
                }
                content = textOrNull(args["content"]) ?: ""
            }
            "replace" -> {
                val find = textOrNull(args["find"])
                if (find.isNullOrEmpty()) {
                    throw BotMCPToolException(
                        "invalid_arguments",
                        "更新记忆的替换动作需要提供要查找的原文",
                    )
                }
                if (!args.containsKey("replace")) {
                    throw BotMCPToolException(
                        "invalid_arguments",
                        "更新记忆的替换动作需要提供替换后的内容",
                    )
                }
                content = null
            }
            else -> content = null
        }
        val to = if (action == "move") {
            val target = textOrNull(args["to"])
            if (target.isNullOrEmpty()) {
                throw BotMCPToolException("invalid_arguments", "更新记忆的移动动作需要提供目标路径")
            }
            target
        } else {
            null
        }
        val restoreVersion = if (action == "restore") {
            val version = optionalInt(args["restore_version"])
            if (version == null || version < 1) {
                throw BotMCPToolException("invalid_arguments", "恢复记忆需要提供不小于 1 的版本号")
            }
            version
        } else {
            null
        }
        val request = BotMemoryWriteRequest(
            action = action,
            path = path,
            content = content,
            find = if (action == "replace") textOrNull(args["find"]) else null,
            replace = if (action == "replace") (textOrNull(args["replace"]) ?: "") else null,
            to = to,
            expectedVersion = expectedVersion,
            restoreVersion = restoreVersion,
            evidence = evidence,
            markedContradiction = boolOrNull(args["marked_contradiction"]) == true,
        )
        val result = memory.update(context.principal.botId, request, context)
        if (request.markedContradiction && result is JsonObject) {
            val ok = boolOrNull(result.members["ok"]) == true
            val version = (result.members["version"] as? JsonNumber)?.asLongOrNull()
            val resolvedPath = textOrNull(result.members["path"]) ?: path
            val scope = textOrNull(result.members["scope"])
            if (ok && version != null && scope != null) {
                events.append(
                    BotMCPEvent(
                        type = "memory.review_requested",
                        principal = context.principal,
                        data = BotJson.objectOf(
                            "path" to JsonString(resolvedPath),
                            "scope" to JsonString(scope),
                            "version" to JsonNumber(version.toString()),
                            "evidence" to JsonArray(evidence.map(::JsonString)),
                            "marked_at_ms" to JsonNumber(now().toString()),
                        ),
                        eventId = "memory.review_requested:" +
                            "${context.principal.botId}:$resolvedPath:$version",
                    ),
                )
            }
        }
        return BotMCPCallResult.success(result)
    }

    private suspend fun memoryEvidence(
        args: Map<String, JsonValue>,
        context: BotToolCallContext,
    ): List<String> {
        val raw = args["evidence"] ?: return emptyList()
        val values = (raw as? JsonArray)?.values
            ?: throw BotMCPToolException("memory-evidence-invalid", MEMORY_EVIDENCE_MESSAGE)
        if (values.size > 8) {
            throw BotMCPToolException("memory-evidence-invalid", MEMORY_EVIDENCE_MESSAGE)
        }
        val refs = ArrayList<String>(values.size)
        for (value in values) {
            val text = (value as? JsonString)?.value
                ?: throw BotMCPToolException("memory-evidence-invalid", MEMORY_EVIDENCE_MESSAGE)
            if (text == "current-user-turn") {
                if (!context.isUserTurn || context.hiddenTurn) {
                    throw BotMCPToolException("memory-evidence-invalid", MEMORY_EVIDENCE_MESSAGE)
                }
                refs += text
                continue
            }
            if (text.length > 128 || !RECORD_REFERENCE.matches(text)) {
                throw BotMCPToolException("memory-evidence-invalid", MEMORY_EVIDENCE_MESSAGE)
            }
            refs += text
        }
        return refs
    }

    private suspend fun readMemory(
        arguments: JsonValue,
        context: BotToolCallContext,
    ): BotMCPCallResult {
        val args = requireObject(arguments)
        val path = textOrNull(args["path"])
        if (path.isNullOrEmpty()) {
            throw BotMCPToolException("invalid_arguments", MEMORY_READ_PATH_MESSAGE)
        }
        val rawVersion = args["version"]
        val version = if (rawVersion == null || rawVersion == JsonNull) {
            null
        } else {
            optionalInt(rawVersion)
        }
        if (version != null && version < 1) {
            throw BotMCPToolException("invalid_arguments", "读取记忆的版本必须不小于 1")
        }
        return BotMCPCallResult.success(memory.read(context.principal.botId, path, version))
    }

    private suspend fun recallMemory(
        arguments: JsonValue,
        context: BotToolCallContext,
    ): BotMCPCallResult {
        val args = requireObject(arguments)
        val limit = optionalInt(args["limit"]) ?: 40
        if (limit !in 1..50) {
            throw BotMCPToolException("invalid_arguments", RECALL_LIMIT_MESSAGE)
        }
        val scope = textOrNull(args["scope"]) ?: "all"
        if (scope !in setOf("agent", "user", "all")) {
            throw BotMCPToolException("invalid_arguments", "invalid memory scope")
        }
        val page = try {
            memory.recall(
                context.principal.botId,
                textOrNull(args["query"]) ?: "",
                limit,
                if (scope == "all") null else scope,
            )
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            return BotMCPCallResult.failure("memory_unavailable", RECALL_UNAVAILABLE_MESSAGE)
        }
        return BotMCPCallResult.success(
            BotJson.objectOf(
                "ok" to JsonBool(true),
                "hits" to JsonArray(page.hits),
                "count" to JsonNumber(page.hits.size.toString()),
                "total" to JsonNumber(page.total.toString()),
                "truncated" to JsonBool(page.total > page.hits.size),
            ),
        )
    }

    // ------------------------------------------------------------------
    // Tasks
    // ------------------------------------------------------------------

    private suspend fun startTask(
        arguments: JsonValue,
        context: BotToolCallContext,
    ): BotMCPCallResult {
        val principal = context.principal
        if (principal.kind != BotMCPPrincipalKind.CHAT && principal.kind != BotMCPPrincipalKind.TASK) {
            throw BotMCPToolException("invalid_arguments", TASK_ONLY_MESSAGE)
        }
        if (principal.kind == BotMCPPrincipalKind.TASK &&
            TASK_DELEGATE_CAPABILITY !in principal.capabilities
        ) {
            return BotMCPCallResult.failure("permission_denied", TASK_CHILD_DELEGATE_MESSAGE)
        }
        val args = requireObject(arguments)
        if (args.containsKey("task_id") || args.containsKey("resume")) {
            throw BotMCPToolException("invalid_arguments", "暂不支持从历史任务继续")
        }
        val title = firstNonEmpty(args["task_title"], args["description"]) ?: "委派的任务"
        val prompt = firstNonEmpty(args["prompt"], args["task_description"])
            ?: throw BotMCPToolException("invalid_arguments", TASK_PROMPT_MESSAGE)
        val timeout = optionalInt(args["timeout_ms"]) ?: 180_000
        if (timeout !in 1_000..300_000) {
            throw BotMCPToolException("invalid_arguments", TASK_TIMEOUT_MESSAGE)
        }
        val completion = (textOrNull(args["completion"]) ?: "").trim()
        if (completion.length > 4_000) {
            throw BotMCPToolException("invalid_arguments", TASK_COMPLETION_MESSAGE)
        }
        val purpose = textOrNull(args["purpose"])?.trim()
        if ((purpose?.length ?: 0) > 2_000) {
            throw BotMCPToolException("invalid_arguments", TASK_PURPOSE_MESSAGE)
        }
        val constraints = (arrayValues(args["constraints"]) ?: emptyList())
            .mapNotNull { (it as? JsonString)?.value?.trim() }
            .filter { it.isNotEmpty() }
        if (constraints.size > 8 || constraints.any { it.length > 500 }) {
            throw BotMCPToolException("invalid_arguments", TASK_CONSTRAINTS_MESSAGE)
        }
        var budget: BotTaskBudget? = null
        val rawBudget = args["budget"]
        if (rawBudget != null && rawBudget != JsonNull) {
            val fields = (rawBudget as? JsonObject)?.members
                ?: throw BotMCPToolException("invalid_arguments", TASK_BUDGET_MESSAGE)
            if (fields.keys.any { it != "max_duration_ms" }) {
                throw BotMCPToolException("invalid_arguments", TASK_BUDGET_MESSAGE)
            }
            val duration = optionalInt(fields["max_duration_ms"])
            if (duration != null && duration !in 1_000..300_000) {
                throw BotMCPToolException("invalid_arguments", TASK_BUDGET_RANGE_MESSAGE)
            }
            budget = BotTaskBudget(duration)
        }
        val directories = (arrayValues(args["allowed_write_directories"]) ?: emptyList())
            .mapNotNull { (it as? JsonString)?.value }
        if (directories.size > 32) {
            throw BotMCPToolException("invalid_arguments", TASK_DIRECTORIES_MESSAGE)
        }
        val request = BotTaskStartRequest(
            context = context,
            title = title,
            prompt = prompt,
            asynchronous = boolOrNull(args["async"]) == true,
            timeoutMs = timeout,
            completion = completion,
            purpose = purpose?.takeIf { it.isNotEmpty() },
            constraints = constraints,
            budget = budget,
            arguments = arguments,
        )
        val record = tasks.start(request)
        val taskId = recordString(record, "task_id")
        val status = recordString(record, "status")
        if (taskId != null) {
            events.append(
                BotMCPEvent(
                    type = "task.started",
                    principal = principal.copy(
                        sessionId = recordString(record, "sessionId") ?: principal.sessionId,
                        kind = BotMCPPrincipalKind.TASK,
                    ),
                    data = record,
                ),
            )
            if (status in TASK_TERMINAL_STATUSES) {
                events.append(
                    BotMCPEvent(
                        type = "task.settled",
                        principal = principal.copy(
                            sessionId = recordString(record, "sessionId") ?: principal.sessionId,
                            kind = BotMCPPrincipalKind.TASK,
                        ),
                        data = record,
                        eventId = "settled:$taskId",
                    ),
                )
            }
        }
        return BotMCPCallResult.success(record)
    }

    private suspend fun awaitTask(
        arguments: JsonValue,
        context: BotToolCallContext,
    ): BotMCPCallResult {
        val args = requireObject(arguments)
        val taskId = textOrNull(args["task_id"])
        if (taskId.isNullOrEmpty()) {
            throw BotMCPToolException("invalid_arguments", AWAIT_TASK_ID_MESSAGE)
        }
        val timeout = optionalInt(args["timeout_ms"]) ?: 180_000
        if (timeout !in 1_000..600_000) {
            throw BotMCPToolException("invalid_arguments", AWAIT_TASK_TIMEOUT_MESSAGE)
        }
        val record = tasks.await(taskId, timeout, context)
        if (recordString(record, "status") in TASK_TERMINAL_STATUSES) {
            events.append(
                BotMCPEvent(
                    type = "task.settled",
                    principal = context.principal.copy(
                        sessionId = recordString(record, "sessionId") ?: context.sessionId,
                        kind = BotMCPPrincipalKind.TASK,
                    ),
                    data = record,
                    eventId = "settled:$taskId",
                ),
            )
        }
        return BotMCPCallResult.success(record)
    }

    private suspend fun stopTask(
        arguments: JsonValue,
        context: BotToolCallContext,
    ): BotMCPCallResult {
        val args = requireObject(arguments)
        val taskId = firstNonEmpty(args["task_id"], args["id"])
            ?: throw BotMCPToolException("invalid_arguments", STOP_TASK_ID_MESSAGE)
        val record = tasks.stop(taskId, context)
        val sessionId = recordString(record, "sessionId") ?: context.sessionId
        val taskPrincipal = context.principal.copy(
            sessionId = sessionId,
            kind = BotMCPPrincipalKind.TASK,
        )
        val settledId = recordString(record, "task_id") ?: taskId
        events.append(
            BotMCPEvent(
                type = "task.stop_requested",
                principal = taskPrincipal,
                data = record,
                eventId = "stop:$settledId",
            ),
        )
        events.append(
            BotMCPEvent(
                type = "task.settled",
                principal = taskPrincipal,
                data = record,
                eventId = "settled:$settledId",
            ),
        )
        return BotMCPCallResult.success(record)
    }

    // ------------------------------------------------------------------
    // Routines
    // ------------------------------------------------------------------

    private suspend fun updateRoutine(
        arguments: JsonValue,
        context: BotToolCallContext,
    ): BotMCPCallResult {
        val args = requireObject(arguments)
        val action = textOrNull(args["action"])
            ?: throw BotMCPToolException("invalid_arguments", ROUTINE_ACTION_MESSAGE)
        when (action) {
            "create" -> {
                requireTrimmedString(args, "title")
                requireTrimmedString(args, "prompt")
                if (!args.containsKey("schedule")) {
                    throw BotMCPToolException("invalid_arguments", "schedule is required")
                }
                validateDelivery(args)
            }
            "update" -> requireTrimmedString(args, "routine_id")
            "delete", "get", "pause", "resume" -> requireTrimmedString(args, "routine_id")
            "list" -> Unit
            else -> throw BotMCPToolException(
                "invalid_arguments",
                "unsupported UpdateRoutine action: $action",
            )
        }
        val assessment = routines.assess(context.principal.botId, arguments)
        if (assessment.requiresConfirmation && !context.isUserTurn) {
            val outcome = approvals.requestStructuralApproval(
                context = context,
                tool = "UpdateRoutine",
                detail = assessment.detail,
                resource = assessment.resource,
                alwaysScope = "none",
            )
            if (!outcome.allowed) {
                return BotMCPCallResult.failure(
                    "permission_denied",
                    if (outcome.pending) {
                        "审批还在等待用户确认；任务已经停下，用户决定后会继续"
                    } else {
                        outcome.message ?: "routine change requires user confirmation in this turn"
                    },
                )
            }
        }
        val result = routines.update(context.principal.botId, arguments, context)
        if (action !in setOf("get", "list")) {
            val type = when (action) {
                "create" -> "routine.defined"
                "delete" -> "routine.deleted"
                else -> "routine.updated"
            }
            events.append(BotMCPEvent(type, context.principal, result))
        }
        return BotMCPCallResult.success(result)
    }

    private fun validateDelivery(args: Map<String, JsonValue>) {
        val delivery = textOrNull(args["delivery"]) ?: return
        if (delivery !in setOf("held", "interrupt")) {
            throw BotMCPToolException("invalid_arguments", "invalid delivery")
        }
    }

    private suspend fun listRoutines(context: BotToolCallContext): BotMCPCallResult =
        BotMCPCallResult.success(routines.list(context.principal.botId))

    // ------------------------------------------------------------------
    // Approval / user message
    // ------------------------------------------------------------------

    private suspend fun requestApproval(
        arguments: JsonValue,
        context: BotToolCallContext,
    ): BotMCPCallResult {
        val args = requireObject(arguments)
        val action = textOrNull(args["action"])
        if (action.isNullOrEmpty()) {
            throw BotMCPToolException("invalid_arguments", APPROVAL_ACTION_MESSAGE)
        }
        val detail = textOrNull(args["detail"]) ?: ""
        val command = textOrNull(args["command"]) ?: ""
        val outcome = approvals.requestApproval(context, action, detail, command)
        val fields = LinkedHashMap<String, JsonValue>()
        fields["allowed"] = JsonBool(outcome.allowed)
        fields["decision"] = JsonString(if (outcome.allowed) "allowed" else "denied")
        fields["approvalId"] = outcome.approvalId?.let(::JsonString) ?: JsonNull
        fields["message"] = outcome.message?.let(::JsonString) ?: JsonNull
        fields["pending"] = JsonBool(outcome.pending)
        outcome.expiresAt?.let { fields["expiresAt"] = JsonNumber(it.toString()) }
        outcome.approvalDecision?.let { fields["approvalDecision"] = JsonString(it) }
        outcome.scope?.let { fields["scope"] = JsonString(it) }
        val result = JsonObject(fields)
        val text = approvalSummary(outcome) + "\n" + BotJson.canonical(result)
        return BotMCPCallResult.success(result, text)
    }

    private fun approvalSummary(outcome: BotApprovalOutcome): String {
        if (outcome.pending) return "审批请求已经发出，正在等用户确认。"
        if (!outcome.allowed) return "这次请求没有获得允许，已经停止。"
        return when {
            outcome.approvalDecision == "always" && outcome.scope == "session" ->
                "用户已允许，本次对话内都有效。"
            outcome.approvalDecision == "always" && outcome.scope == "until" ->
                "用户已总是允许，之后同类操作不必再问。"
            outcome.approvalDecision == "allowOnce" ->
                "用户已允许这一次，可以继续。"
            else -> "用户已允许，可以继续。"
        }
    }

    private suspend fun sendToUser(
        arguments: JsonValue,
        context: BotToolCallContext,
    ): BotMCPCallResult {
        if (context.principal.kind != BotMCPPrincipalKind.CHAT) {
            throw BotMCPToolException("invalid_arguments", SEND_TO_USER_KIND_MESSAGE)
        }
        if (context.hiddenTurn || isTextSuppressed(context.sessionId)) {
            throw BotMCPToolException("invalid_arguments", SEND_TO_USER_SUPPRESSED_MESSAGE)
        }
        val args = requireObject(arguments)
        val message = textOrNull(args["message"])
        if (message.isNullOrEmpty()) {
            throw BotMCPToolException("invalid_arguments", SEND_TO_USER_CONTENT_MESSAGE)
        }
        val rowId = userMessages.sendToUser(context, message)
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
        return BotMCPCallResult.success(
            BotJson.objectOf(
                "ok" to JsonBool(true),
                "rowId" to JsonString(rowId),
            ),
        )
    }

    // ------------------------------------------------------------------
    // Argument helpers
    // ------------------------------------------------------------------

    private fun requireObject(value: JsonValue): Map<String, JsonValue> =
        (value as? JsonObject)?.members
            ?: throw BotMCPToolException("invalid_arguments", "arguments must be an object")

    private fun optionalInt(value: JsonValue?): Int? {
        if (value == null) return null
        val number = (value as? JsonNumber)?.asLongOrNull()
            ?: throw BotMCPToolException("invalid_arguments", "timeout/limit must be an integer")
        if (number < Int.MIN_VALUE || number > Int.MAX_VALUE) {
            throw BotMCPToolException("invalid_arguments", "timeout/limit must be an integer")
        }
        return number.toInt()
    }

    private fun firstNonEmpty(vararg values: JsonValue?): String? {
        for (value in values) {
            val text = textOrNull(value) ?: continue
            if (text.trim().isNotEmpty()) return text
        }
        return null
    }

    private fun requireTrimmedString(args: Map<String, JsonValue>, key: String): String {
        val text = textOrNull(args[key])
        if (text.isNullOrBlank()) {
            throw BotMCPToolException("invalid_arguments", "$key is required")
        }
        return text
    }

    private fun recordString(record: JsonValue, key: String): String? =
        textOrNull((record as? JsonObject)?.members?.get(key))

    private val MEMORY_ACTIONS = setOf("write", "append", "replace", "move", "delete", "restore")
}
