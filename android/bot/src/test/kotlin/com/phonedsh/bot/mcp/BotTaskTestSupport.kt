// SPDX-License-Identifier: MIT
package com.phonedsh.bot.mcp

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.GoldenFixture
import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import com.phonedsh.bot.profile.BotProfile
import com.phonedsh.bot.profile.BotRoster
import com.phonedsh.bot.rows.BotAgentCommHeld
import com.phonedsh.bot.session.BotSessionKind
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventOrigin
import com.phonedsh.bot.store.BotPrincipal
import com.phonedsh.bot.store.SqliteJdbcDriver
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import java.nio.file.Files
import java.nio.file.Path
import java.util.UUID

/** Real SQLite event log for the task cases. */
internal class TaskSqliteStore private constructor(
    val path: Path,
    val store: BotDomainStore,
) : AutoCloseable {
    override fun close() {
        runCatching { store.close() }
        runCatching { Files.deleteIfExists(path) }
        runCatching { Files.deleteIfExists(Path.of("$path-wal")) }
        runCatching { Files.deleteIfExists(Path.of("$path-shm")) }
    }

    companion object {
        fun open(): TaskSqliteStore {
            val path = Files.createTempFile("pdsh-bot-task-", ".sqlite")
            return TaskSqliteStore(path, BotDomainStore(SqliteJdbcDriver(path.toString())))
        }
    }
}

internal data class TaskPromptRecord(
    val sessionId: String,
    val kind: BotSessionKind,
    val prompt: String,
    val requestId: String,
)

/**
 * Scripted DSH task transport. It pauses a session by suspending inside
 * `runTurn` until `resume`, exactly like the Swift scripted transport.
 */
internal class FakeBotTaskTransport : BotTaskTransport {
    private var created = 0
    private val scripts: MutableMap<String, ArrayDeque<BotTaskTurnResult>> = LinkedHashMap()
    private val paused: MutableSet<String> = LinkedHashSet()
    private val resumeSignals: MutableMap<String, CompletableDeferred<Unit>> = LinkedHashMap()
    private val decisions: MutableMap<String, BotTaskApprovalDecision> = LinkedHashMap()
    private var mainSession: String? = "gb-main"
    var turnError: Throwable? = null

    val prompts: MutableList<TaskPromptRecord> = ArrayList()
    val cancellations: MutableList<String> = ArrayList()
    val cancelledApprovals: MutableList<Pair<String, String>> = ArrayList()

    fun script(sessionId: String, results: List<BotTaskTurnResult>) {
        scripts[sessionId] = ArrayDeque(results)
    }

    fun scriptGroup(sessionId: String, group: List<JsonValue>) {
        scripts[sessionId] = ArrayDeque(listOf(resultFrom(group)))
    }

    fun pause(sessionId: String) {
        paused += sessionId
        resumeSignals.getOrPut(sessionId) { CompletableDeferred() }
    }

    fun resume(sessionId: String) {
        paused -= sessionId
        resumeSignals.remove(sessionId)?.complete(Unit)
    }

    fun setMainSession(sessionId: String?) {
        mainSession = sessionId
    }

    fun setDecision(approvalId: String, decision: BotTaskApprovalDecision) {
        decisions[approvalId] = decision
    }

    override suspend fun createSession(
        kind: BotSessionKind,
        capabilities: List<String>,
    ): String {
        created += 1
        return "gb-created-$created"
    }

    override suspend fun runTurn(
        sessionId: String,
        kind: BotSessionKind,
        prompt: String,
        requestId: String,
    ): BotTaskTurnResult {
        prompts += TaskPromptRecord(sessionId, kind, prompt, requestId)
        turnError?.let { throw it }
        if (sessionId in paused) {
            resumeSignals.getOrPut(sessionId) { CompletableDeferred() }.await()
        }
        val queue = scripts[sessionId]
        val result = if (queue != null && queue.isNotEmpty()) {
            queue.removeFirst()
        } else {
            BotTaskTurnResult(sessionId = sessionId, status = "completed", text = "done")
        }
        return result.copy(sessionId = sessionId)
    }

    override suspend fun cancelTurn(sessionId: String, includeQueued: Boolean): Boolean {
        cancellations += sessionId
        resume(sessionId)
        return true
    }

    override suspend fun ensureSession(sessionId: String, kind: BotSessionKind): Boolean = true

    override suspend fun currentMainSession(): String? = mainSession

    override suspend fun cancelApproval(approvalId: String, reason: String): Boolean {
        cancelledApprovals += approvalId to reason
        return true
    }

    override suspend fun durableApprovalDecision(
        approvalId: String,
    ): BotTaskApprovalDecision? = decisions[approvalId]

    private fun resultFrom(events: List<JsonValue>): BotTaskTurnResult {
        var text = ""
        var reason = "completed"
        for (event in events) {
            val members = (event as? JsonObject)?.members ?: continue
            when ((members["type"] as? JsonString)?.value) {
                "assistant" -> text = (members["text"] as? JsonString)?.value ?: ""
                "end" -> reason = (members["reason"] as? JsonString)?.value ?: "completed"
                else -> Unit
            }
        }
        return BotTaskTurnResult(sessionId = "", status = reason, text = text)
    }
}

/** One complete in-test task composition: real tools, real runtime, real SQLite. */
internal class TaskToolHarness(
    val sqlite: TaskSqliteStore,
    val transport: FakeBotTaskTransport,
    val remote: BotDSHRemoteRuntime,
    val scope: CoroutineScope,
    val attribution: FakeAttribution = FakeAttribution(),
) : AutoCloseable {
    val catalog: BotToolCatalog = MCPTestSupport.catalog()
    val runtime: BotMCPToolRuntime = BotMCPToolRuntime(
        catalogProvider = catalog,
        attribution = attribution,
        tasks = remote,
        events = remote,
    )

    override fun close() {
        scope.cancel()
        sqlite.close()
    }

    suspend fun execute(
        name: String,
        arguments: JsonValue,
        principal: BotMCPPrincipal,
    ): BotMCPCallResult {
        val callId = "task-case-${UUID.randomUUID()}"
        attribution.register(callId, name, arguments, principal)
        return runtime.execute(name, arguments, JsonString(callId))
    }

    companion object {
        fun open(
            now: () -> Long = { 1_000 },
            botRoot: String = "/tmp/bot/main",
        ): TaskToolHarness {
            val sqlite = TaskSqliteStore.open()
            val transport = FakeBotTaskTransport()
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val remote = BotDSHRemoteRuntime(
                store = sqlite.store,
                transport = transport,
                botId = "main",
                botRoot = botRoot,
                now = now,
                scope = scope,
                incarnationOf = { "inc-${it.sessionId}" },
            )
            return TaskToolHarness(sqlite, transport, remote, scope)
        }
    }
}

internal fun taskPrincipal(
    sessionId: String = "gb-main",
    kind: BotSessionKind = BotSessionKind.CHAT,
    capabilities: Set<String> = emptySet(),
): BotMCPPrincipal = BotMCPPrincipal(
    botId = "main",
    sessionId = sessionId,
    kind = when (kind) {
        BotSessionKind.CHAT -> BotMCPPrincipalKind.CHAT
        BotSessionKind.TASK -> BotMCPPrincipalKind.TASK
        BotSessionKind.ROUTINE -> BotMCPPrincipalKind.ROUTINE
        BotSessionKind.VERIFIER -> BotMCPPrincipalKind.VERIFIER
        BotSessionKind.TEAM -> BotMCPPrincipalKind.TEAM
        BotSessionKind.PROACTIVE -> BotMCPPrincipalKind.PROACTIVE
        BotSessionKind.WATCHDOG -> BotMCPPrincipalKind.WATCHDOG
        BotSessionKind.MAINTAINER -> BotMCPPrincipalKind.MAINTAINER
    },
    capabilities = capabilities,
)

internal fun taskCaller(
    sessionId: String = "gb-main",
    kind: BotSessionKind = BotSessionKind.CHAT,
    incarnation: String = "inc-$sessionId",
): BotTaskCaller = BotTaskCaller(
    botId = "main",
    sessionId = sessionId,
    kind = kind,
    incarnation = incarnation,
)

/** Seed one durable event; the restore cases use exactly the fixture bytes. */
internal fun seedTaskEvent(
    store: BotDomainStore,
    type: String,
    eventId: String,
    principalSessionId: String,
    principalKind: String,
    data: JsonValue,
    at: Long = 1_000,
) {
    store.append(
        BotEvent(
            schemaVersion = 1,
            type = type,
            eventId = eventId,
            commitSeq = null,
            time = at,
            origin = BotEventOrigin.Local("task-manager"),
            traceId = "task:seed:$eventId",
            principal = BotPrincipal(
                botId = "main",
                sessionId = principalSessionId,
                kind = principalKind,
                capabilities = emptyList(),
            ),
            causationId = null,
            correlationId = null,
            data = data,
        ),
    )
}

internal fun taskJsonString(value: JsonValue?, key: String): String? =
    ((value as? JsonObject)?.members?.get(key) as? JsonString)?.value

internal fun taskJsonLong(value: JsonValue?, key: String): Long? =
    ((value as? JsonObject)?.members?.get(key) as? JsonNumber)?.asLongOrNull()

internal fun taskJsonBool(value: JsonValue?, key: String): Boolean? =
    ((value as? JsonObject)?.members?.get(key) as? JsonBool)?.value

internal fun taskJsonArray(value: JsonValue?, key: String): List<JsonValue> =
    ((value as? JsonObject)?.members?.get(key) as? JsonArray)?.values ?: emptyList()

internal fun substituteTask(
    value: JsonValue,
    taskId: String,
    sessionId: String,
): JsonValue = when (value) {
    is JsonString -> JsonString(
        value.value.replace("<taskId>", taskId).replace("<sessionId>", sessionId),
    )
    is JsonArray -> JsonArray(value.values.map { substituteTask(it, taskId, sessionId) })
    is JsonObject -> JsonObject(
        value.members.mapValues { (_, item) -> substituteTask(item, taskId, sessionId) },
    )
    else -> value
}

internal fun taskHarnessScripts(
    transport: FakeBotTaskTransport,
    setup: JsonObject?,
) {
    if (setup == null) return
    val scripts = setup.members["scripts"] as? JsonObject ?: return
    for ((sessionId, groupsValue) in scripts.members) {
        val groups = (groupsValue as? JsonArray)?.values ?: continue
        val first = (groups.firstOrNull() as? JsonArray)?.values ?: continue
        transport.scriptGroup(sessionId, first)
    }
}
