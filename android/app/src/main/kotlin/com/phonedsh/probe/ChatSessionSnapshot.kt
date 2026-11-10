// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.agentcore.*
import com.phonedsh.dsh.turn.PendingRemoteRequest
import com.phonedsh.ui.page.ChatSubagentEntry
import com.phonedsh.ui.projection.*
import com.phonedsh.ui.state.*

/** The same authoritative session projection the iOS input dock consumes. */
internal data class ChatSessionSnapshot(
    val goal: GoalBarState = GoalBarState.Hidden,
    val todos: List<TodoDockItem> = emptyList(),
    val accessModes: List<AccessModeOption> = emptyList(),
    val currentAccessMode: AccessModeOption? = null,
    val commands: List<ComposerCommand> = emptyList(),
    val accessError: String? = null,
    /** True while the permission read is being retried automatically. */
    val accessLoading: Boolean = false,
    val commandsError: String? = null,
    val modelRoutes: List<ChatModelRoute> = emptyList(),
    val currentModel: String? = null,
    val currentProvider: String? = null,
    val currentEffort: String? = null,
    val sessionStats: SessionStats? = null,
    val tokenUsage: SessionTokenUsage? = null,
    val contextPressure: ContextPressure? = null,
    val contextBreakdown: ContextBreakdown? = null,
    /** Durable DSH inbox rows; null means the projection has not reported inbox. */
    val queueItems: List<ManagedQueueItemState>? = null,
    /** Current Worker subagent projection; null means it was not reported. */
    val subagents: List<ChatSubagentEntry>? = null,
)

/** A projection poll refreshes live facts without replacing catalogs it did not read. */
internal fun ChatSessionSnapshot.withProjectionUpdate(measured: ChatSessionSnapshot): ChatSessionSnapshot = copy(
    goal = measured.goal,
    todos = measured.todos,
    sessionStats = measured.sessionStats,
    tokenUsage = measured.tokenUsage,
    contextPressure = measured.contextPressure,
    contextBreakdown = measured.contextBreakdown,
    queueItems = mergeQueueProjection(queueItems, measured.queueItems),
    subagents = measured.subagents,
)

/**
 * The input dock is the DSH `next-turn` lane. A poll must not erase the action
 * marker of a row whose update RPC is still in flight, or the user can submit
 * the same edit/remove twice while the first transaction is unresolved.
 *
 * The measured row still owns its text/lane/capabilities; only the transient
 * action fields survive from the old row with the same durable id.
 */
internal fun mergeQueueProjection(
    current: List<ManagedQueueItemState>?,
    measured: List<ManagedQueueItemState>?,
): List<ManagedQueueItemState>? {
    if (measured == null) return null
    if (current == null) return measured
    val inFlight = current.mapNotNull { row ->
        val id = row.id as? QueueItemId.Durable ?: return@mapNotNull null
        if (!row.queueActionInFlight()) return@mapNotNull null
        id.value to row
    }.toMap()
    if (inFlight.isEmpty()) return measured
    return measured.map { row ->
        val id = (row.id as? QueueItemId.Durable)?.value ?: return@map row
        val prior = inFlight[id] ?: return@map row
        row.copy(busy = prior.busy, actionRequestId = prior.actionRequestId, receipt = prior.receipt)
    }
}

private fun ManagedQueueItemState.queueActionInFlight(): Boolean =
    busy == true || (actionRequestId != null && receipt?.requestId != actionRequestId)

/** Safe path for opening one catalog Worker id without substituting a new session. */
internal sealed interface SubagentSessionTarget {
    public data class CachedRecord(val record: ChatRecord) : SubagentSessionTarget
    public data class AdoptKnownWorker(
        val workerSessionId: String,
        val existingRecord: ChatRecord?,
    ) : SubagentSessionTarget
}

/** Returns null unless the projection/list supplied this exact resumable Worker id. */
internal fun resolveSubagentSessionTarget(
    entry: ChatSubagentEntry,
    records: List<ChatRecord>,
): SubagentSessionTarget? {
    if (!entry.canOpen || entry.workerSessionId.isBlank()) return null
    val mapped = records.firstOrNull { entry.workerSessionId in it.workerSessionIds }
    if (mapped != null && (mapped.archived || mapped.workerSessionId != entry.workerSessionId)) return null
    // An App-owned chat's stored transcript is reusable when it owns this exact
    // active Worker id. A catalog-adopted row keyed by the Worker id itself may
    // hold only a recent remote page, so it must re-read `session/page` for its
    // cursor before it can claim the transcript is complete.
    if (mapped != null && mapped.id != entry.workerSessionId && mapped.nodes.isNotEmpty()) {
        return SubagentSessionTarget.CachedRecord(mapped)
    }
    return SubagentSessionTarget.AdoptKnownWorker(entry.workerSessionId, mapped)
}

internal data class ChatModelRoute(val provider: String, val model: String,
    val efforts: List<EffortOption>, val defaultEffort: String?)

internal fun sessionSnapshotOf(
    projections: JsonValue,
    catalog: JsonValue?,
    commandCatalog: JsonValue?,
    modelCatalog: JsonValue? = null,
    sessionId: String? = null,
    sessionList: JsonValue? = null,
): ChatSessionSnapshot {
    val values = (projections as? JsonObject)?.get("values") as? JsonObject
    val sessionStats = values?.get("sessionStats").asSessionStats()
    val tokenUsage = values?.get("tokenUsage").asSessionTokenUsage()
    val contextPressure = values?.get("contextPressure").asContextPressure()
    val contextBreakdown = values?.get("contextBreakdown").asContextBreakdown()
    val goal = ((values?.get("goal") as? JsonObject)?.get("goal") as? JsonObject)
    val objective = goal?.string("objective")?.takeIf { it.isNotBlank() }
    val modes = ((catalog as? JsonObject)?.get("options") as? JsonArray)?.values.orEmpty()
        .mapNotNull { raw ->
            val row = raw as? JsonObject ?: return@mapNotNull null
            val id = row.string("value") ?: return@mapNotNull null
            val name = accessModeTitle(id) ?: return@mapNotNull null
            AccessModeOption(id = id, title = name)
        }
    val current = (values?.get("permissions") as? JsonObject)?.string("currentValue")
    val selection = values?.get("modelSelection") as? JsonObject
    val selected = ((selection?.get("next") as? JsonObject) ?: (selection?.get("lastUsed") as? JsonObject))
    val sessionRows = ((sessionList as? JsonObject)?.get("items") as? JsonArray)?.values
    val sessionFacts = sessionRows.orEmpty().mapNotNull { raw ->
        val row = raw as? JsonObject ?: return@mapNotNull null
        val id = row.string("sessionId") ?: return@mapNotNull null
        id to row
    }.toMap()
    val subagents = (values?.get("subagentCatalog") as? JsonArray)?.values?.mapNotNull { raw ->
        val row = raw as? JsonObject ?: return@mapNotNull null
        val id = row.string("id")?.takeIf(String::isNotBlank) ?: return@mapNotNull null
        val session = sessionFacts[id]
        val sessionTitle = ((session?.get("projections") as? JsonObject)?.get("values") as? JsonObject)
            ?.string("title")?.takeIf(String::isNotBlank)
        ChatSubagentEntry(
            workerSessionId = id,
            label = row.string("label"),
            mode = row.string("mode"),
            parentSessionId = row.string("parentSessionId"),
            running = (session?.get("running") as? JsonBool)?.value,
            workerSessionKnown = if (sessionRows == null) null else session != null,
            sessionTitle = sessionTitle,
            updatedAtMs = (session?.get("updatedAt") as? JsonNumber)?.asLongOrNull(),
        )
    }
    val routes = ((modelCatalog as? JsonObject)?.get("groups") as? JsonArray)?.values.orEmpty().flatMap { raw ->
        val group = raw as? JsonObject ?: return@flatMap emptyList()
        val provider = group.string("id") ?: return@flatMap emptyList()
        (group["models"] as? JsonArray)?.values.orEmpty().mapNotNull { modelRaw ->
            val model = modelRaw as? JsonObject ?: return@mapNotNull null
            val id = model.string("id") ?: return@mapNotNull null
            val reasoning = model["reasoning"] as? JsonObject
            ChatModelRoute(provider, id, (reasoning?.get("efforts") as? JsonArray)?.values.orEmpty().mapNotNull { effortRaw ->
                val effort = effortRaw as? JsonObject ?: return@mapNotNull null
                val effortId = effort.string("id") ?: return@mapNotNull null
                EffortOption(effortId, effortTitle(effortId, effort.string("name") ?: effortId))
            }, reasoning?.string("defaultEffort"))
        }
    }
    val inbox = values?.get("inbox") as? JsonObject
    val queueItems = inbox?.let { queue ->
        // DSH's QueueDock renders only next-turn. A next-step row is the running
        // turn's steered message and is already represented in the transcript.
        (queue["next-turn"] as? JsonArray)?.values.orEmpty().mapNotNull { raw ->
            val item = raw as? JsonObject ?: return@mapNotNull null
            val id = item.string("id")?.takeIf(String::isNotBlank) ?: return@mapNotNull null
            val content = (item["content"] as? JsonArray)?.values.orEmpty()
            val parts = content.mapNotNull { part ->
                val value = part as? JsonObject ?: return@mapNotNull null
                if (value.string("type") != "text") return@mapNotNull null
                value.string("text")
            }
            val text = parts.joinToString("\n")
            val sourceRpcId = (item["source"] as? JsonObject)
                ?.string("rpcId")?.takeIf(String::isNotBlank)
            ManagedQueueItemState(
                id = QueueItemId.Durable(id),
                text = text,
                sessionId = sessionId,
                lane = "next-turn",
                state = QueueItemStatus.QUEUED,
                canEdit = text.isNotBlank() && parts.size == content.size,
                canRemove = true,
                canSteer = false,
                promptRequestId = sourceRpcId?.let(::StateRequestId),
            )
        }
    }
    val commands = when (commandCatalog) {
        is JsonArray -> commandCatalog
        is JsonObject -> (commandCatalog["commands"] ?: commandCatalog["value"]) as? JsonArray
        else -> null
    }?.values.orEmpty().mapNotNull { raw ->
        val row = raw as? JsonObject ?: return@mapNotNull null
        val name = row.string("name")?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
        val description = row.string("description") ?: return@mapNotNull null
        ComposerCommand(name, description, hasInput = row["input"] != null && row["input"] != JsonNull)
    }
    return ChatSessionSnapshot(
        goal = if (objective == null) GoalBarState.Hidden else GoalBarState.Visible(
            phase = goal.string("phase") ?: "active", objective = objective,
        ),
        todos = (values?.get("todos") as? JsonArray)?.values.orEmpty().mapIndexedNotNull { index, raw ->
            val row = raw as? JsonObject ?: return@mapIndexedNotNull null
            val content = row.string("content") ?: return@mapIndexedNotNull null
            val status = row.string("status")?.takeIf {
                it in setOf("pending", "in_progress", "completed", "cancelled")
            } ?: return@mapIndexedNotNull null
            TodoDockItem(row.string("id") ?: "todo-$index", content, status)
        },
        accessModes = modes,
        currentAccessMode = modes.firstOrNull { it.id == current },
        commands = commands,
        accessError = if (catalog == null || current == null) "没读到权限,再试一次。" else null,
        commandsError = if (commandCatalog == null) "没读到命令,再试一次。" else null,
        modelRoutes = routes,
        currentModel = selected?.string("model"),
        currentProvider = selected?.string("provider"),
        currentEffort = selected?.string("reasoningEffort"),
        sessionStats = sessionStats,
        tokenUsage = tokenUsage,
        contextPressure = contextPressure,
        contextBreakdown = contextBreakdown,
        queueItems = queueItems,
        subagents = subagents,
    )
}

private fun JsonValue?.objectValue(): JsonObject? = this as? JsonObject
private fun JsonObject.long(key: String): Long? = (this[key] as? JsonNumber)?.asLongOrNull()
private fun JsonObject.finiteDouble(key: String): Double? =
    (this[key] as? JsonNumber)?.raw?.toDoubleOrNull()?.takeIf(Double::isFinite)

private fun JsonValue?.asSessionStats(): SessionStats? {
    val value = objectValue() ?: return null
    val fields = listOf("turns", "steps", "ttftSteps", "decodeTokens").map { value.long(it) ?: return null }
    val times = listOf("llmMs", "toolMs", "ttftMs", "decodeMs").map { value.finiteDouble(it) ?: return null }
    if (fields.any { it < 0 } || times.any { it < 0 }) return null
    return SessionStats(fields[0], fields[1], times[0], times[1], times[2], fields[2], times[3], fields[3])
}

private fun JsonValue?.asSessionTokenUsage(): SessionTokenUsage? {
    val value = objectValue() ?: return null
    val counts = listOf("uncachedInputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens")
        .map { value.long(it) ?: return null }
    if (counts.any { it < 0 }) return null
    if (safeNonnegativeSum(counts[0], counts[2], counts[3], counts[1]) == null) return null
    return SessionTokenUsage(counts[0], counts[1], counts[2], counts[3])
}

private fun safeNonnegativeSum(vararg values: Long): Long? {
    var sum = 0L
    for (value in values) {
        if (value < 0 || Long.MAX_VALUE - sum < value) return null
        sum += value
    }
    return sum
}

private fun JsonValue?.asContextPressure(): ContextPressure? {
    val value = objectValue() ?: return null
    val window = value.long("contextWindow")?.takeIf { it > 0 } ?: return null
    val pressure = value.long("pressureTokens") ?: if (value["pressureTokens"] == null || value["pressureTokens"] == JsonNull) null else return null
    val projected = value.long("projectedTokens") ?: if (value["projectedTokens"] == null || value["projectedTokens"] == JsonNull) null else return null
    if ((pressure != null && pressure < 0) || (projected != null && projected < 0)) return null
    return ContextPressure(pressure, projected, window)
}

private fun JsonValue?.asContextBreakdown(): ContextBreakdown? {
    val value = objectValue() ?: return null
    val counts = listOf("systemTokens", "toolsTokens", "messageTokens").map { value.long(it) ?: return null }
    if (counts.any { it < 0 }) return null
    return ContextBreakdown(counts[0], counts[1], counts[2])
}

/** A live waterfall request is transient; it must never be restored as actionable history. */
internal fun pendingRequestNode(chatId: String, request: PendingRemoteRequest): UiStateNode {
    val body = request.request as? JsonObject ?: JsonObject(emptyMap())
    val isQuestion = request.eventKind == "user-questions/request"
    val questions = (body["questions"] as? JsonArray)?.values.orEmpty().mapNotNull { raw ->
        val item = raw as? JsonObject ?: return@mapNotNull null
        val intent = item["intent"] as? JsonObject
        JsonObject(linkedMapOf<String, JsonValue>(
            "id" to (item["id"] ?: JsonString("")),
            "prompt" to (item["question"] ?: JsonString("")),
            "options" to (item["options"] ?: JsonArray(emptyList())),
            "multiple" to (item["multiSelect"] ?: JsonBool(false)),
        ).apply {
            for (name in listOf("header", "detail")) item[name]?.let { put(name, it) }
            intent?.get("kind")?.let { put("intentKind", it) }
            intent?.get("approve")?.let { put("approveWireLabel", it) }
        })
    }
    return UiStateNode(
        kind = UiStateKind.APPROVAL_CARD,
        nodeID = "session/$chatId/pending/${request.eventID}",
        parentID = "session/$chatId", sessionID = chatId, turnID = "-", seq = 0,
        surface = UiStateSurface.APPROVAL_CARD,
        text = if (isQuestion) "" else body.string("reason") ?: body.string("toolName").orEmpty(),
        props = JsonObject(linkedMapOf(
            "requestId" to JsonString(request.eventID),
            "kind" to JsonString(if (isQuestion) "question" else "permission"),
            "questionItems" to JsonArray(questions),
            "channelAvailable" to JsonBool(true),
            "submitting" to JsonBool(false),
        )),
    )
}

/** DSH's answer envelope: selections are option labels; custom text stays separate. */
internal fun questionOutcome(request: PendingRemoteRequest, answer: String): JsonObject {
    val body = request.request as? JsonObject
    val questions = (body?.get("questions") as? JsonArray)?.values.orEmpty()
    val perQuestion = runCatching { JsonValue.parse(answer) as? JsonObject }.getOrNull()
    return JsonObject(mapOf("kind" to JsonString("result"), "value" to JsonObject(mapOf(
        "answers" to JsonArray(questions.map { raw ->
            val item = raw as? JsonObject ?: JsonObject(emptyMap())
            val id = item.string("id").orEmpty()
            val labels = (item["options"] as? JsonArray)?.values.orEmpty().mapNotNull {
                (it as? JsonObject)?.string("label")
            }
            val value = perQuestion?.get(id)
            val answers = when (value) {
                is JsonArray -> value.values.mapNotNull { (it as? JsonString)?.value }
                is JsonString -> listOf(value.value)
                else -> if (perQuestion == null) listOf(answer) else emptyList()
            }
            JsonObject(linkedMapOf<String, JsonValue>(
                "id" to JsonString(id),
                "selected" to JsonArray(answers.filter { it in labels }.map(::JsonString)),
            ).apply {
                answers.filter { it !in labels }.joinToString("\n").takeIf { it.isNotEmpty() }
                    ?.let { put("custom", JsonString(it)) }
            })
        }),
    ))))
}

internal fun effortTitle(id: String, fallback: String = id): String = when (id.lowercase()) {
    "off", "none", "disabled" -> "关"
    "low", "minimal" -> "低"
    "medium", "mid" -> "中"
    "high" -> "高"
    "max", "maximum", "xhigh" -> "最高"
    else -> fallback
}

private fun accessModeTitle(id: String): String? = when (id) {
    "read-only", "phone-read-only" -> "仅可查看"
    "workspace-write", "phone" -> "工作区内修改"
    "danger-full-access", "bypassPermissions" -> "完全权限"
    "auto" -> "自动判断"
    "plan" -> "只出方案"
    "acceptEdits" -> "改前不问"
    else -> null
}

private fun JsonObject.string(key: String): String? = (this[key] as? JsonString)?.value
