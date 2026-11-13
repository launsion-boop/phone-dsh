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
import com.phonedsh.bot.GoldenFixture
import com.phonedsh.bot.profile.BotProfile
import com.phonedsh.bot.profile.BotRoster
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue

/**
 * Shared in-test fakes for the MCP lane. Every fake is a host port; the real
 * `BotMCPHandler`, `BotMCPToolRuntime`, `BotCardPayloads` and volatile
 * producer are exercised by the tests.
 */
internal object MCPTestSupport {
    val roster: BotRoster = BotRoster(
        bots = listOf(
            BotProfile(id = "main", name = "Main"),
            BotProfile(id = "restricted", name = "Restricted"),
            BotProfile(id = "bot-b", name = "Bee"),
            BotProfile(id = "bot-a", name = "Alpha"),
        ),
        mainBotID = "main",
    )

    fun catalog(): BotToolCatalog = BotToolCatalog.fromGolden(
        GoldenFixture.rawObject("tool-catalog"),
        GoldenFixture.rawObject("tool-catalog.phone"),
        roster,
    )

    fun principal(
        botId: String = "main",
        sessionId: String = "gb-main",
        kind: String = "chat",
        capabilities: Set<String> = emptySet(),
    ): BotMCPPrincipal = BotMCPPrincipal(
        botId = botId,
        sessionId = sessionId,
        kind = BotMCPPrincipalKind.fromWire(kind) ?: BotMCPPrincipalKind.CHAT,
        capabilities = capabilities,
    )

    fun errorCode(result: BotMCPCallResult): String? =
        ((result.structuredContent as? JsonObject)?.members?.get("error") as? JsonObject)
            ?.members?.get("code")?.let { (it as? JsonString)?.value }

    fun errorMessage(result: BotMCPCallResult): String? =
        ((result.structuredContent as? JsonObject)?.members?.get("error") as? JsonObject)
            ?.members?.get("message")?.let { (it as? JsonString)?.value }

    fun structured(result: BotMCPCallResult): Map<String, JsonValue> =
        (result.structuredContent as? JsonObject)?.members ?: emptyMap()

    fun toolNames(reply: JsonObject): List<String> {
        val tools = ((reply.members["result"] as? JsonObject)?.members?.get("tools") as? JsonArray)
            ?.values ?: emptyList()
        return tools.mapNotNull { ((it as? JsonObject)?.members?.get("name") as? JsonString)?.value }
    }

    fun assertSubset(expected: JsonValue?, actual: JsonValue?, path: String = "$") {
        if (expected == null) return
        when (expected) {
            is JsonObject -> {
                val actualObject = actual as? JsonObject
                    ?: throw AssertionError("$path: expected object, got $actual")
                for ((key, value) in expected.members) {
                    assertSubset(value, actualObject.members[key], "$path.$key")
                }
            }
            is JsonArray -> {
                val actualArray = actual as? JsonArray
                    ?: throw AssertionError("$path: expected array, got $actual")
                assertEquals("$path length", expected.values.size, actualArray.values.size)
                for ((index, value) in expected.values.withIndex()) {
                    assertSubset(value, actualArray.values[index], "$path[$index]")
                }
            }
            else -> assertEquals(path, expected, actual)
        }
    }

    fun assertToolList(reply: JsonObject, expectation: JsonValue?, label: String) {
        val expected = (expectation as? JsonObject)?.members ?: return
        val tools = ((reply.members["result"] as? JsonObject)?.members?.get("tools") as? JsonArray)
            ?.values ?: emptyList()
        val names = tools.mapNotNull { ((it as? JsonObject)?.members?.get("name") as? JsonString)?.value }
        (expected["names"] as? JsonArray)?.values?.let { expectedNames ->
            assertEquals(
                label,
                expectedNames.map { (it as JsonString).value },
                names,
            )
        }
        (expected["count"] as? JsonNumber)?.asLongOrNull()?.let { count ->
            assertEquals(label, count.toInt(), tools.size)
        }
        (expected["last"] as? JsonString)?.value?.let { last ->
            assertEquals(label, last, names.lastOrNull())
        }
        (expected["contains"] as? JsonArray)?.values?.forEach { value ->
            val name = (value as JsonString).value
            assertTrue("$label: missing $name", names.contains(name))
        }
        (expected["notContains"] as? JsonArray)?.values?.forEach { value ->
            val name = (value as JsonString).value
            assertTrue("$label: must not contain $name", !names.contains(name))
        }
        tools.firstOrNull { ((it as? JsonObject)?.members?.get("name") as? JsonString)?.value == "ask_user" }
            ?.let { ask ->
                val description = ((ask as? JsonObject)?.members?.get("description") as? JsonString)?.value
                assertTrue(label, description?.contains("COLLIDING") != true)
            }
    }
}

internal class FakeTokenPrincipalPort : BotTokenPrincipalPort {
    val sessions = LinkedHashMap<String, BotMCPPrincipal>()
    val tokens = LinkedHashMap<String, BotMCPPrincipal>()

    override suspend fun principalForSessionToken(token: String): BotMCPPrincipal? = tokens[token]

    override suspend fun principalForSessionId(sessionId: String): BotMCPPrincipal? = sessions[sessionId]
}

internal class FakeAttribution : BotAttributionPort {
    data class Entry(
        val callId: String,
        val tool: String,
        val arguments: JsonValue,
        val principal: BotMCPPrincipal,
        val isUserTurn: Boolean = true,
        val hiddenTurn: Boolean = false,
        val attributionId: String = "attribution-1",
    )

    val entries = ArrayList<Entry>()

    fun register(
        callId: String,
        tool: String,
        arguments: JsonValue,
        principal: BotMCPPrincipal,
        isUserTurn: Boolean = true,
        hiddenTurn: Boolean = false,
    ) {
        entries += Entry(callId, tool, arguments, principal, isUserTurn, hiddenTurn)
    }

    override suspend fun claim(
        runtimeId: String,
        name: String,
        arguments: JsonValue,
    ): BotResolvedToolCall? {
        val canonical = BotJson.canonical(arguments)
        val index = entries.indexOfLast {
            it.tool == name && BotJson.canonical(it.arguments) == canonical
        }
        if (index < 0) return null
        val entry = entries.removeAt(index)
        return BotResolvedToolCall(
            principal = entry.principal,
            callId = entry.callId,
            attributionId = entry.attributionId,
            isUserTurn = entry.isUserTurn,
            hiddenTurn = entry.hiddenTurn,
        )
    }
}

internal class FixtureNativeForwarder(native: JsonObject) : BotNativeMCPForwarder {
    private val instructions = (native.members["instructions"] as? JsonString)?.value
    private val tools = (native.members["tools"] as? JsonArray)?.values ?: emptyList()
    val seenMethods = ArrayList<String>()

    override suspend fun handle(request: JsonValue, headers: Map<String, String>): JsonValue? {
        val members = (request as? JsonObject)?.members ?: return null
        val method = (members["method"] as? JsonString)?.value ?: return null
        seenMethods += method
        val id = members["id"] ?: JsonNull
        val params = (members["params"] as? JsonObject)?.members ?: emptyMap()
        return when (method) {
            "initialize" -> result(
                id,
                BotJson.objectOf(
                    "protocolVersion" to JsonString(
                        (params["protocolVersion"] as? JsonString)?.value ?: "",
                    ),
                    "instructions" to JsonString(instructions ?: ""),
                ),
            )
            "tools/list" -> result(id, BotJson.objectOf("tools" to JsonArray(tools)))
            "tools/call" -> {
                val name = (params["name"] as? JsonString)?.value
                if (name != "native_echo") {
                    null
                } else {
                    val extra = LinkedHashMap<String, JsonValue>()
                    extra["nativeEcho"] = params["arguments"] ?: JsonObject(emptyMap())
                    val key = headers.entries.firstOrNull {
                        it.key.equals("x-pdsh-idempotency-key", ignoreCase = true)
                    }?.value
                    extra["nativeSawIdempotencyKey"] = key?.let(::JsonString) ?: JsonNull
                    result(id, JsonObject(extra))
                }
            }
            "native/ping" -> result(id, BotJson.objectOf("native" to JsonBool(true)))
            else -> null
        }
    }

    private fun result(id: JsonValue, result: JsonValue): JsonObject =
        BotJson.objectOf(
            "jsonrpc" to JsonString("2.0"),
            "id" to id,
            "result" to result,
        )
}

internal class FakeMemoryLookup : BotMemoryLookup {
    data class Doc(val path: String, var content: String, var version: Int = 1, val scope: String)

    val documents = LinkedHashMap<String, Doc>()

    fun seed(path: String, content: String) {
        documents[path] = Doc(path, content, 1, scopeOf(path))
    }

    override suspend fun promptBlock(botId: String, language: String): String =
        documents.values.joinToString("\n\n") { it.content }

    override suspend fun update(
        botId: String,
        request: BotMemoryWriteRequest,
        context: BotToolCallContext,
    ): JsonValue {
        val scope = scopeOf(request.path)
        when (request.action) {
            "write" -> {
                val current = documents[request.path]
                if ((current?.version ?: 0) != request.expectedVersion) {
                    val fields = LinkedHashMap<String, JsonValue>()
                    fields["ok"] = JsonBool(false)
                    fields["code"] = JsonString("memory-version-conflict")
                    fields["path"] = JsonString(request.path)
                    fields["error"] = JsonString("memory version conflict")
                    if (current != null) fields["current_version"] = JsonNumber(current.version.toString())
                    return JsonObject(fields)
                }
                documents[request.path] = Doc(request.path, request.content ?: "", 1, scope)
                return BotJson.objectOf(
                    "ok" to JsonBool(true),
                    "action" to JsonString("write"),
                    "path" to JsonString(request.path),
                    "scope" to JsonString(scope),
                    "version" to JsonNumber("1"),
                    "previous_version" to JsonNumber(request.expectedVersion.toString()),
                )
            }
            "append" -> {
                val current = documents[request.path]
                    ?: return BotJson.objectOf(
                        "ok" to JsonBool(false),
                        "code" to JsonString("memory-not-found"),
                        "path" to JsonString(request.path),
                        "error" to JsonString("memory not found"),
                    )
                current.content = current.content + (request.content ?: "")
                current.version += 1
                return BotJson.objectOf(
                    "ok" to JsonBool(true),
                    "action" to JsonString("append"),
                    "path" to JsonString(request.path),
                    "scope" to JsonString(scope),
                    "version" to JsonNumber(current.version.toString()),
                    "previous_version" to JsonNumber((current.version - 1).toString()),
                )
            }
            else -> return BotJson.objectOf(
                "ok" to JsonBool(false),
                "action" to JsonString(request.action),
                "path" to JsonString(request.path),
                "code" to JsonString("memory-not-found"),
                "error" to JsonString("memory not found"),
            )
        }
    }

    override suspend fun read(botId: String, path: String, version: Int?): JsonValue {
        val doc = documents[path]
            ?: return BotJson.objectOf(
                "ok" to JsonBool(false),
                "code" to JsonString("memory-not-found"),
                "error" to JsonString("memory not found"),
            )
        return BotJson.objectOf(
            "ok" to JsonBool(true),
            "kind" to JsonString("document"),
            "path" to JsonString(doc.path),
            "scope" to JsonString(doc.scope),
            "version" to JsonNumber(doc.version.toString()),
            "content" to JsonString(doc.content),
            "updated_at_ms" to JsonNumber("1000"),
            "author" to JsonString("chat"),
            "evidence" to JsonArray(emptyList()),
        )
    }

    override suspend fun recall(
        botId: String,
        query: String,
        limit: Int,
        scope: String?,
    ): BotMemoryRecallPage {
        val hits = documents.values
            .filter { scope == null || it.scope == scope }
            .filter { query.isEmpty() || it.content.contains(query, ignoreCase = true) }
            .take(limit)
            .map { doc ->
                BotJson.objectOf(
                    "path" to JsonString(doc.path),
                    "scope" to JsonString(doc.scope),
                    "snippet" to JsonString(doc.content),
                    "score" to JsonNumber("1"),
                    "relevance" to JsonNumber("1"),
                    "recency" to JsonNumber("1"),
                    "matched" to JsonArray(listOf(JsonString(query))),
                    "updated_at_ms" to JsonNumber("1000"),
                    "version" to JsonNumber(doc.version.toString()),
                    "evidence" to JsonArray(emptyList()),
                )
            }
        return BotMemoryRecallPage(hits, hits.size)
    }

    private fun scopeOf(path: String): String =
        if (path.startsWith("user/")) "user" else "agent"
}

internal class FakeRoutineLookup : BotRoutineLookup {
    data class Routine(
        val id: String,
        val title: String,
        val prompt: String,
        val schedule: String,
        var enabled: Boolean = true,
    )

    val routines = ArrayList<Routine>()

    fun seed(title: String, prompt: String, schedule: String) {
        routines += Routine("routine-${routines.size + 1}", title, prompt, schedule)
    }

    override suspend fun automationStatus(botId: String, now: Long, language: String): String {
        val lines = ArrayList<String>()
        lines += "<automation_status>"
        lines += if (language == "en") {
            "Your routines are listed below. This reminder is authoritative: with none listed, you have none."
        } else {
            "下面列出你的例行任务。这条提醒是权威来源：没有列出时，你没有任何例行任务。"
        }
        if (routines.isEmpty()) {
            lines += if (language == "en") {
                "No enabled routines. No routine will fire."
            } else {
                "没有已启用的例行任务。不会有例行任务触发。"
            }
        } else {
            for (routine in routines) {
                lines += "- ${routine.id} | folder ${routine.id} | ${routine.title} | " +
                    "${routine.schedule} | ${routine.prompt} | enabled"
            }
        }
        lines += "</automation_status>"
        return lines.joinToString("\n")
    }

    override suspend fun assess(botId: String, arguments: JsonValue): BotRoutineAssessment {
        val args = (arguments as? JsonObject)?.members ?: emptyMap()
        val action = (args["action"] as? JsonString)?.value
        if (action == null) {
            throw BotMCPToolException("invalid_arguments", "UpdateRoutine requires action")
        }
        val requires = when (action) {
            "create" -> true
            "update" -> args.keys.any {
                it in setOf("enabled", "urgent", "delivery", "schedule")
            }
            "resume" -> routines.any { !it.enabled }
            else -> false
        }
        return BotRoutineAssessment(
            action = action,
            requiresConfirmation = requires,
            detail = "routine $action",
            resource = "routine:$action",
        )
    }

    override suspend fun update(
        botId: String,
        arguments: JsonValue,
        context: BotToolCallContext,
    ): JsonValue {
        val args = (arguments as? JsonObject)?.members ?: emptyMap()
        val action = (args["action"] as? JsonString)?.value
        return when (action) {
            "create" -> {
                val schedule = args["schedule"]
                val scheduleText = (schedule as? JsonString)?.value
                if (scheduleText != null && !scheduleText.startsWith("@every ")) {
                    throw BotMCPToolException("invalid_arguments", "invalid routine schedule")
                }
                val routine = Routine(
                    id = "routine-${routines.size + 1}",
                    title = (args["title"] as? JsonString)?.value ?: "",
                    prompt = (args["prompt"] as? JsonString)?.value ?: "",
                    schedule = scheduleText ?: "interval",
                )
                routines += routine
                encode(routine)
            }
            "list" -> listRoutines()
            "get" -> routines.firstOrNull { it.id == (args["routine_id"] as? JsonString)?.value }
                ?.let(::encode) ?: JsonObject(emptyMap())
            "delete" -> {
                val id = (args["routine_id"] as? JsonString)?.value
                routines.removeAll { it.id == id }
                JsonObject(emptyMap())
            }
            "pause", "resume" -> {
                val id = (args["routine_id"] as? JsonString)?.value
                val routine = routines.firstOrNull { it.id == id } ?: return JsonObject(emptyMap())
                routine.enabled = action == "resume"
                encode(routine)
            }
            "update" -> {
                val id = (args["routine_id"] as? JsonString)?.value
                val routine = routines.firstOrNull { it.id == id } ?: return JsonObject(emptyMap())
                (args["title"] as? JsonString)?.value?.let { routine.copy(title = it) }
                encode(routine)
            }
            else -> throw BotMCPToolException(
                "invalid_arguments",
                "unsupported UpdateRoutine action: $action",
            )
        }
    }

    override suspend fun list(botId: String): JsonValue = listRoutines()

    private fun listRoutines(): JsonValue = BotJson.objectOf(
        "routines" to JsonArray(routines.map(::encode)),
        "count" to JsonNumber(routines.size.toString()),
    )

    private fun encode(routine: Routine): JsonValue = BotJson.objectOf(
        "id" to JsonString(routine.id),
        "title" to JsonString(routine.title),
        "prompt" to JsonString(routine.prompt),
        "schedule" to JsonString(routine.schedule),
        "enabled" to JsonBool(routine.enabled),
        "created_at" to JsonNumber("1000"),
    )
}

internal class FakeTaskPort : BotTaskPort {
    val records = LinkedHashMap<String, JsonValue>()
    private var nextId = 1

    override suspend fun start(request: BotTaskStartRequest): JsonValue {
        val id = "task-${nextId++}"
        val record = BotJson.objectOf(
            "task_id" to JsonString(id),
            "sessionId" to JsonString("gb-task-$id"),
            "status" to JsonString(if (request.asynchronous) "running" else "completed"),
            "title" to JsonString(request.title),
            "completion" to JsonString(request.completion),
            "purpose" to JsonString(request.purpose ?: ""),
            "constraints" to JsonArray(request.constraints.map(::JsonString)),
            "authorization" to BotJson.objectOf(
                "workspaceRoot" to JsonString("/tmp"),
                "allowedWriteDirectories" to JsonArray(emptyList()),
                "canWriteOutsideWorkspace" to JsonBool(false),
                "canNetworkWrite" to JsonBool(false),
                "canDelegateTasks" to JsonBool(false),
            ),
        )
        records[id] = record
        return record
    }

    override suspend fun await(taskId: String, timeoutMs: Int, context: BotToolCallContext): JsonValue =
        BotJson.objectOf(
            "task_id" to JsonString(taskId),
            "sessionId" to JsonString("gb-task-seed"),
            "status" to JsonString("completed"),
            "title" to JsonString("Seed"),
            "result" to JsonString("completed async"),
        )

    override suspend fun stop(taskId: String, context: BotToolCallContext): JsonValue =
        BotJson.objectOf(
            "task_id" to JsonString(taskId),
            "sessionId" to JsonString("gb-task-seed"),
            "status" to JsonString("stopped"),
            "title" to JsonString("Seed"),
            "partial" to JsonString("partial"),
        )
}

internal class FakeApprovalPort(
    private val decision: String = "allowOnce",
) : BotApprovalPort {
    override suspend fun requestApproval(
        context: BotToolCallContext,
        action: String,
        detail: String,
        command: String,
    ): BotApprovalOutcome = BotApprovalOutcome(
        allowed = true,
        pending = false,
        approvalId = "approval-1",
        approvalDecision = decision,
        scope = when (decision) {
            "always" -> "session"
            "deny" -> null
            else -> "once"
        },
    )

    override suspend fun requestStructuralApproval(
        context: BotToolCallContext,
        tool: String,
        detail: String,
        resource: String,
        alwaysScope: String,
    ): BotApprovalOutcome = BotApprovalOutcome(allowed = true, pending = false)

    override suspend fun approve(request: BotApprovalRequest): BotApprovalOutcome =
        BotApprovalOutcome(allowed = true, approvalDecision = "allowOnce", scope = "once")
}

internal class FakeUserMessagePort : BotUserMessagePort {
    override suspend fun sendToUser(context: BotToolCallContext, message: String): String =
        "message-test"
}

internal class RecordingEventSink : BotMCPEventSink {
    val events = ArrayList<BotMCPEvent>()
    override suspend fun append(event: BotMCPEvent) {
        events += event
    }
}

/** One complete in-test host composition. */
internal class MCPHarness(
    val catalog: BotToolCatalog = MCPTestSupport.catalog(),
    val catalogProvider: BotMCPToolCatalogProvider = catalog,
    val tokenPort: FakeTokenPrincipalPort = FakeTokenPrincipalPort(),
    val attribution: FakeAttribution = FakeAttribution(),
    val memory: FakeMemoryLookup = FakeMemoryLookup(),
    val routines: FakeRoutineLookup = FakeRoutineLookup(),
    val tasks: FakeTaskPort = FakeTaskPort(),
    val approvals: FakeApprovalPort = FakeApprovalPort(),
    val userMessages: FakeUserMessagePort = FakeUserMessagePort(),
    val events: RecordingEventSink = RecordingEventSink(),
    native: BotNativeMCPForwarder? = null,
    resultEncoder: (BotMCPCallResult) -> JsonValue = { it.toJson() },
) {
    val volatile: BotVolatileContextProducer = BotVolatileContextProducer(
        BotDomainVolatileContextProvider(memory, routines),
    )
    val runtime: BotMCPToolRuntime = BotMCPToolRuntime(
        catalogProvider = catalogProvider,
        attribution = attribution,
        volatileContext = volatile,
        memory = memory,
        routines = routines,
        tasks = tasks,
        approvals = approvals,
        userMessages = userMessages,
        events = events,
    )
    val handler: BotMCPHandler = BotMCPHandler(
        catalog = catalogProvider,
        tools = runtime,
        tokens = tokenPort,
        native = native,
        resultEncoder = resultEncoder,
    )
}
