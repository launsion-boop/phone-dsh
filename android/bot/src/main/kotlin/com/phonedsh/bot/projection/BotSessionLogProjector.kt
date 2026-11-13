// SPDX-License-Identifier: MIT
package com.phonedsh.bot.projection

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.attachments.BotAttachmentPrompt
import com.phonedsh.bot.rows.BotRow
import com.phonedsh.bot.rows.BotRowBody
import com.phonedsh.bot.rows.BotRowBodyType
import com.phonedsh.bot.rows.BotRowKind
import com.phonedsh.bot.rows.BotRowProvenance
import com.phonedsh.bot.rows.BotWidgetCardType
import com.phonedsh.bot.session.BotTurnOrigin
import com.phonedsh.bot.session.BotTurnOriginKind

/** One main-chat session epoch, oldest first (`projection.md` §1/§7). */
public data class BotSessionEpochProjection(
    public val sessionID: String,
    public val records: List<BotSessionLogRecord>,
)

/** One applied row change (`projection.md` §1/§9). */
public sealed interface BotRowChange {
    public val id: String
    public val updatedSeq: Long
    public val isDelete: Boolean

    public data class Upsert(public val row: BotRow) : BotRowChange {
        override val id: String get() = row.id
        override val updatedSeq: Long get() = row.updatedSeq
        override val isDelete: Boolean get() = false
    }

    public data class Delete(
        override val id: String,
        override val updatedSeq: Long,
    ) : BotRowChange {
        override val isDelete: Boolean get() = true
    }
}

/** `BotRowProjectionSnapshot` (`projection.md` §1). */
public data class BotRowProjectionSnapshot(
    public val rows: List<BotRow>,
    public val tombstones: List<BotRow>,
    public val cursor: Long,
    public val changes: List<BotRowChange>,
) {
    public companion object {
        public val EMPTY: BotRowProjectionSnapshot =
            BotRowProjectionSnapshot(emptyList(), emptyList(), 0L, emptyList())
    }
}

private data class BotRowDraft(
    val id: String,
    val seq: Long,
    val kind: BotRowKind,
    val role: String?,
    val body: BotRowBody,
    val provenance: BotRowProvenance,
    val createdAt: Long,
    val chatActionNonce: String? = null,
)

private data class BotRowOrder(
    val time: Long,
    val source: Int,
    val sourceSeq: Long,
    val index: Int,
) : Comparable<BotRowOrder> {
    override fun compareTo(other: BotRowOrder): Int {
        if (source != other.source) return source.compareTo(other.source)
        if (sourceSeq != other.sourceSeq) return sourceSeq.compareTo(other.sourceSeq)
        if (time != other.time) return time.compareTo(other.time)
        return index.compareTo(other.index)
    }
}

private sealed interface BotRowMutation {
    val order: BotRowOrder

    data class Upsert(
        val draft: BotRowDraft,
        override val order: BotRowOrder,
    ) : BotRowMutation

    data class Delete(
        val id: String,
        val placeholder: BotRowDraft,
        override val order: BotRowOrder,
    ) : BotRowMutation
}

private data class ApprovalCall(
    val name: String,
    val rowID: String,
    val body: BotRowBody,
)

/**
 * DSH session log + durable Bot events → `BotRow` (`projection.md` §§3–8).
 *
 * The projector is pure and order-stable: it never reads the clock, network or
 * disk, and the same inputs always yield the same snapshot.
 */
public class BotSessionLogProjector {
    public fun project(
        botID: String,
        sessionID: String,
        sessionEvents: List<BotSessionLogRecord>,
        uiEvents: List<BotProjectionEvent> = emptyList(),
        heldRequestNonces: Map<String, String> = emptyMap(),
    ): BotRowProjectionSnapshot = project(
        botID = botID,
        epochs = listOf(BotSessionEpochProjection(sessionID, sessionEvents)),
        uiEvents = uiEvents,
        heldRequestNonces = heldRequestNonces,
    )

    public fun project(
        botID: String,
        epochs: List<BotSessionEpochProjection>,
        uiEvents: List<BotProjectionEvent> = emptyList(),
        heldRequestNonces: Map<String, String> = emptyMap(),
    ): BotRowProjectionSnapshot {
        val mutations = ArrayList<BotRowMutation>()
        for ((index, epoch) in epochs.withIndex()) {
            val heldActionNonces = heldActionNonces(
                botID, epoch.sessionID, epoch.records, uiEvents)
            mutations.addAll(projectDsh(
                botID = botID,
                sessionID = epoch.sessionID,
                records = epoch.records,
                heldActionNonces = heldActionNonces,
                heldRequestNonces = heldRequestNonces,
                source = index,
            ))
        }
        mutations.addAll(projectUi(botID, uiEvents, maxOf(1, epochs.size)))
        mutations.sortWith(compareBy { it.order })
        return apply(botID, mutations)
    }

    // MARK: - DSH records

    private fun projectDsh(
        botID: String,
        sessionID: String,
        records: List<BotSessionLogRecord>,
        heldActionNonces: Map<Long, String>,
        heldRequestNonces: Map<String, String>,
        source: Int,
    ): List<BotRowMutation> {
        val result = ArrayList<BotRowMutation>()
        var turn = 0L
        val hiddenTurns = HashSet<Long>()
        var hiddenFallback = false
        var awaitingCard = false
        val toolNames = HashMap<String, String>()
        val calls = HashMap<String, ApprovalCall>()
        val seenEventIDs = HashSet<String>()

        for ((index, record) in records.withIndex()) {
            val eventId = record.eventId
            if (eventId != null && !seenEventIDs.add(eventId)) continue
            val order = BotRowOrder(record.time, source, record.seq, index)
            if (record.type == "turn/start") {
                turn = jsonLong(record.data["turn"]) ?: turn
                continue
            }
            if (record.type in IGNORED_TYPES) continue
            when (record.type) {
                "user/message" -> {
                    val message = objectValue(record.data["message"]) ?: emptyMap()
                    val role = stringValue(record.data["role"]) ?: stringValue(message["role"])
                    val surfaceOp = record.surfaceOp
                        ?: BotSurfaceOp.decode(record.data["surfaceOp"])
                    val userSource = objectValue(record.data["source"])
                        ?: objectValue(message["source"])
                    val sourceKind = userSource?.let { stringValue(it["kind"]) }
                    val rawText = contentText(
                        record.data["content"] ?: message["content"])
                    val visibleRawText = stripContinuation(rawText)
                    val origin = BotTurnOrigin.fromSource(userSource)
                    if (origin.hidden) {
                        if (turn > 0) hiddenTurns.add(turn) else hiddenFallback = true
                        awaitingCard = false
                        continue
                    }
                    awaitingCard = false
                    val injected = userSource == null && isInjected(rawText)
                    val eligible = role == "user" && surfaceOp == BotSurfaceOp.Append &&
                        visibleRawText.isNotEmpty() && !injected &&
                        (sourceKind == null || sourceKind == "user")
                    if (!eligible) continue
                    if (origin.kind == BotTurnOriginKind.AGENT) continue
                    val visibleText = if (origin.held) {
                        stripHeldMessages(visibleRawText)
                    } else {
                        visibleRawText
                    }
                    val parsed = BotAttachmentPrompt.parse(visibleText)
                    val fields = fieldsFrom(message)
                    fields["text"] = JsonString(parsed.text)
                    if (visibleText.contains(BotAttachmentPrompt.OPEN_MARKER)) {
                        if (parsed.attachments.isNotEmpty()) {
                            fields["attachments"] = JsonArray(
                                parsed.attachments.map { it.toJson() })
                        }
                        fields["content"] = JsonArray(listOf(JsonObject(linkedMapOf(
                            "type" to JsonString("text"),
                            "text" to JsonString(parsed.text),
                        ))))
                    }
                    var draft = draft(
                        id = rowID(sessionID, record.seq),
                        record = record,
                        kind = BotRowKind.MESSAGE,
                        role = "user",
                        body = BotRowBody(
                            type = BotRowBodyType.TEXT,
                            additionalProperties = fields,
                        ),
                        trust = BotRowProvenance.OWNER_DIRECT,
                    )
                    draft = draft.copy(chatActionNonce = BotTurnOrigin.chatActionNonce(userSource))
                    if (origin.held) {
                        draft = draft.copy(chatActionNonce = heldActionNonces[turn]
                            ?: userSource?.let { stringValue(it["rpcId"]) }
                                ?.let { heldRequestNonces[it] })
                    }
                    result.add(BotRowMutation.Upsert(draft, order))
                }

                "assistant/message" -> {
                    val message = objectValue(record.data["message"]) ?: emptyMap()
                    val messageTurn = jsonLong(record.data["turn"]) ?: turn
                    if (hiddenFallback || hiddenTurns.contains(messageTurn) || awaitingCard) continue
                    val blocks = jsonArray(message["content"])
                    val text = contentText(JsonArray(blocks.filter {
                        stringValue(objectValue(it)?.get("type")) == "text"
                    }))
                    if (text.isEmpty()) continue
                    val reasoning = contentText(JsonArray(blocks.filter {
                        stringValue(objectValue(it)?.get("type")) == "reasoning"
                    }))
                    val fields = linkedMapOf<String, JsonValue>("text" to JsonString(text))
                    if (reasoning.isNotEmpty()) fields["reasoning"] = JsonString(reasoning)
                    for (key in listOf("step", "turn")) {
                        record.data[key]?.let { fields[key] = it }
                    }
                    result.add(BotRowMutation.Upsert(
                        draft(
                            id = rowID(sessionID, record.seq),
                            record = record,
                            kind = BotRowKind.SEND_MESSAGE,
                            role = "assistant",
                            body = BotRowBody(
                                type = BotRowBodyType.TEXT,
                                additionalProperties = fields,
                            ),
                            trust = BotRowProvenance.MODEL,
                        ),
                        order,
                    ))
                }

                "tool/call" -> {
                    val name = stringValue(record.data["name"]) ?: ""
                    val callID = stringValue(record.data["callId"])
                        ?: rowID(sessionID, record.seq)
                    toolNames[callID] = name
                    if (!isApprovalTool(name)) continue
                    val arguments = parseArguments(stringValue(record.data["arguments"]))
                    val action = nonEmpty(arguments, "action") ?: "未知操作"
                    val command = stringValue(arguments["command"]) ?: ""
                    val requestID = stringValue(arguments["requestId"])
                        ?: stringValue(record.data["requestId"])
                        ?: "$sessionID:${record.seq}:$callID"
                    val id = rowID(sessionID, record.seq, suffix = "-approval")
                    val fields = fieldsFrom(arguments)
                    fields["action"] = JsonString(action)
                    fields["command"] = JsonString(command)
                    fields["status"] = JsonString("pending")
                    fields["requestId"] = JsonString(requestID)
                    fields["approvalID"] = JsonString(requestID)
                    fields["callId"] = JsonString(callID)
                    fields["title"] = JsonString("允许执行「$action」吗？")
                    fields["text"] = JsonString("待审批：$action")
                    fields["ask"] = JsonObject(linkedMapOf(
                        "requestId" to JsonString(requestID),
                        "action" to JsonString(
                            if (command.isEmpty()) "other" else "command-execution"),
                        "target" to JsonString(if (command.isEmpty()) action else command),
                        "status" to JsonString("pending"),
                    ))
                    val body = BotRowBody(
                        type = BotRowBodyType.APPROVAL,
                        additionalProperties = fields,
                    )
                    calls[callID] = ApprovalCall(name, id, body)
                    result.add(BotRowMutation.Upsert(
                        draft(
                            id = id,
                            record = record,
                            kind = BotRowKind.SEND_MESSAGE,
                            role = null,
                            body = body,
                            trust = BotRowProvenance.MODEL,
                        ),
                        order,
                    ))
                }

                "tool/result" -> {
                    val message = objectValue(record.data["message"]) ?: emptyMap()
                    val callID = stringValue(message["toolCallId"])
                        ?: stringValue(record.data["callId"]) ?: ""
                    val text = contentText(message["content"])
                    val call = calls[callID]
                    if (call != null) {
                        val status = approvalStatus(text)
                        val action = stringValue(call.body["action"]) ?: "未知操作"
                        var body = call.body
                            .with("status", JsonString(status))
                            .with("resultText", JsonString(text))
                            .with("text", JsonString("${approvalLabel(status)}：$action"))
                        val ask = objectValue(call.body["ask"])
                        if (ask != null) {
                            val updated = LinkedHashMap(ask)
                            updated["status"] = JsonString(approvalAskStatus(status))
                            body = body.with("ask", JsonObject(updated))
                        }
                        calls[callID] = call.copy(body = body)
                        result.add(BotRowMutation.Upsert(
                            draft(
                                id = call.rowID,
                                record = record,
                                kind = BotRowKind.SEND_MESSAGE,
                                role = null,
                                body = body,
                                trust = BotRowProvenance.MODEL,
                            ),
                            order,
                        ))
                    }
                    val displayed = text.startsWith("已顯示") ||
                        text.startsWith("已显示") || text.startsWith("Displayed")
                    val toolName = toolNames[callID]
                        ?: stringValue(record.data["name"]) ?: ""
                    if (displayed &&
                        (toolName.endsWith("ask_user") || toolName.endsWith("show_next_steps"))
                    ) {
                        awaitingCard = true
                    }
                }

                "turn/end" -> {
                    awaitingCard = false
                    hiddenTurns.remove(turn)
                    hiddenFallback = false
                    val reason = objectValue(record.data["reason"])
                    val reasonKind = reason?.let { stringValue(it["kind"]) }
                    if (reasonKind == null || reasonKind == "completed" || reasonKind == "aborted") {
                        continue
                    }
                    val error = reason?.get("error")?.let { objectValue(it) } ?: emptyMap()
                    val message = stringValue(error["message"])
                    val detail = message?.let { "：${it.take(200)}" } ?: ""
                    val hint = if (jsonLong(error["status"]) == 401L) {
                        "（API Key 无效或已被覆盖，请到设置重新粘贴）"
                    } else {
                        ""
                    }
                    val text = "回合失败$detail$hint".take(400)
                    result.add(BotRowMutation.Upsert(
                        draft(
                            id = rowID(sessionID, record.seq),
                            record = record,
                            kind = BotRowKind.EVENT,
                            role = null,
                            body = BotRowBody(
                                type = BotRowBodyType.NOTICE,
                                additionalProperties = linkedMapOf(
                                    "tone" to JsonString("error"),
                                    "text" to JsonString(text),
                                ),
                            ),
                            trust = BotRowProvenance.MODEL,
                        ),
                        order,
                    ))
                }

                else -> {
                    if (!record.type.startsWith("automation/") &&
                        !record.type.startsWith("routine/")
                    ) {
                        continue
                    }
                    val run = objectValue(record.data["automation"])
                        ?: objectValue(record.data["routine"])
                        ?: objectValue(record.data["run"])
                        ?: emptyMap()
                    val automationID = nonEmpty(run, "automationId") ?: nonEmpty(run, "id")
                    val name = nonEmpty(run, "name") ?: nonEmpty(run, "title")
                    if (automationID == null && name == null) continue
                    val status = automationStatus(run, record)
                    val fields = fieldsFrom(run)
                    fields["title"] = JsonString(name ?: "例行任务")
                    fields["status"] = JsonString(status)
                    val automation = LinkedHashMap(run)
                    automation["automationId"] = automationID?.let(::JsonString) ?: JsonNull
                    automation["name"] = JsonString(name ?: "例行任务")
                    automation["status"] = JsonString(status)
                    fields["automation"] = JsonObject(automation)
                    result.add(BotRowMutation.Upsert(
                        draft(
                            id = rowID(sessionID, record.seq),
                            record = record,
                            kind = BotRowKind.MESSAGE,
                            role = null,
                            body = BotRowBody(
                                type = BotRowBodyType.AUTOMATION,
                                additionalProperties = fields,
                            ),
                            trust = BotRowProvenance.MODEL,
                        ),
                        order,
                    ))
                }
            }
        }
        return result
    }

    // MARK: - Durable Bot events

    private fun projectUi(
        botID: String,
        events: List<BotProjectionEvent>,
        source: Int,
    ): List<BotRowMutation> {
        val result = ArrayList<BotRowMutation>()
        val seenEventIDs = HashSet<String>()
        val (answeredCards, dismissedCards) = cardOutcomes(botID, events)
        val ordered = events.sortedWith(
            compareBy<BotProjectionEvent>(
                { it.commitSeq ?: Long.MAX_VALUE },
                { it.time },
                { it.eventId },
            ),
        )
        for ((index, event) in ordered.withIndex()) {
            if (event.isErasedPayload) continue
            if (event.principalBotId != null && event.principalBotId != botID) continue
            val data = objectValue(event.data) ?: continue
            if (!seenEventIDs.add(event.eventId)) continue
            val order = BotRowOrder(event.time, source, event.commitSeq ?: 0L, index)
            if (event.type == "transcript.row_deleted") {
                val nested = objectValue(data["row"]) ?: emptyMap()
                val id = nonEmpty(data, "rowID")
                    ?: nonEmpty(data, "id")
                    ?: nonEmpty(nested, "id")
                    ?: continue
                val body = BotRowBody(
                    type = BotRowBodyType.DELETED,
                    additionalProperties = linkedMapOf("deletedAt" to JsonNumber(event.time.toString())),
                )
                val placeholder = BotRowDraft(
                    id = id,
                    seq = entrySeq(event.time, event.commitSeq ?: 0L),
                    kind = BotRowKind.EVENT,
                    role = null,
                    body = body,
                    provenance = BotRowProvenance(
                        eventIDs = listOf(event.eventId),
                        trust = BotRowProvenance.PROJECTOR,
                        tainted = false,
                    ),
                    createdAt = event.time,
                )
                result.add(BotRowMutation.Delete(id, placeholder, order))
                continue
            }
            if (event.type !in SUPPORTED_UI_TYPES) continue
            val payload = LinkedHashMap(data)
            for (key in FLATTEN_KEYS) {
                val nested = objectValue(data[key]) ?: continue
                payload.putAll(nested)
            }
            val trust = if (event.origin.isDirectUser) {
                BotRowProvenance.OWNER_DIRECT
            } else {
                BotRowProvenance.MODEL
            }
            val provenance = BotRowProvenance(
                eventIDs = listOf(event.eventId),
                trust = trust,
                tainted = false,
            )
            val fallbackID = "e-ui-${event.eventId}"
            var id = nonEmpty(payload, "id") ?: nonEmpty(payload, "rowID") ?: fallbackID
            if (event.type == "card.presented") {
                if (dismissedCards.contains(id)) continue
                answeredCards[id]?.let { optionID ->
                    payload["status"] = JsonString("answered")
                    payload["answeredOptionID"] = JsonString(optionID)
                }
            }
            var kind = BotRowKind.SEND_MESSAGE
            var role: String? = null
            var body: BotRowBody? = null
            when {
                event.type == "ui.notice" || event.type == "ui.system_event" -> {
                    kind = BotRowKind.EVENT
                    body = BotRowBody(
                        type = BotRowBodyType.NOTICE,
                        additionalProperties = fieldsFrom(payload),
                    )
                }

                event.type == "approval.requested" || event.type == "approval.decided" -> {
                    val approvalID = nonEmpty(payload, "approvalID")
                        ?: nonEmpty(payload, "approvalId")
                        ?: nonEmpty(payload, "requestId")
                        ?: nonEmpty(payload, "requestID")
                    if (approvalID != null) {
                        id = nonEmpty(payload, "id") ?: "e-$botID-approval-$approvalID"
                    }
                    val fields = fieldsFrom(payload)
                    if (fields["status"] == null) {
                        val status = if (event.type == "approval.requested") {
                            "pending"
                        } else {
                            when (nonEmpty(payload, "decision")) {
                                "deny" -> "denied"
                                "always" -> "always"
                                else -> "allowed"
                            }
                        }
                        fields["status"] = JsonString(status)
                    }
                    if (approvalID != null) fields["approvalID"] = JsonString(approvalID)
                    body = BotRowBody(
                        type = BotRowBodyType.APPROVAL,
                        additionalProperties = fields,
                    )
                }

                event.type == "verification.reported" -> {
                    if (stringValue(payload["subjectKind"]) != "task") continue
                    val taskID = nonEmpty(payload, "task_id")
                        ?: nonEmpty(payload, "subjectId")
                        ?: nonEmpty(payload, "subjectID")
                    if (taskID != null) id = "e-$botID-task-$taskID"
                    body = BotRowBody(
                        type = BotRowBodyType.WIDGET,
                        cardType = BotWidgetCardType.TASK,
                        cardKey = taskID?.let { "task:$it" },
                        additionalProperties = fieldsFrom(payload),
                    )
                }

                event.type.startsWith("task.") -> {
                    val nativeTaskID = nonEmpty(payload, "task_id")
                    val taskID = nativeTaskID
                        ?: nonEmpty(payload, "taskID")
                        ?: nonEmpty(payload, "taskId")
                        ?: nonEmpty(payload, "threadID")
                    if (taskID != null) {
                        val stableID = "e-$botID-task-$taskID"
                        id = if (nativeTaskID != null) {
                            stableID
                        } else {
                            nonEmpty(payload, "id") ?: stableID
                        }
                    }
                    body = BotRowBody(
                        type = BotRowBodyType.WIDGET,
                        cardType = BotWidgetCardType.TASK,
                        cardKey = nonEmpty(payload, "cardKey") ?: taskID?.let { "task:$it" },
                        additionalProperties = fieldsFrom(payload),
                    )
                }

                event.type == "conversation.automation_run" ||
                    event.type.startsWith("routine.run_") -> {
                    kind = BotRowKind.MESSAGE
                    val runID = nonEmpty(payload, "runID")
                        ?: nonEmpty(payload, "runId")
                        ?: event.runId
                    if (runID != null) {
                        id = nonEmpty(payload, "id") ?: "e-$botID-automation-$runID"
                    }
                    body = BotRowBody(
                        type = BotRowBodyType.AUTOMATION,
                        additionalProperties = fieldsFrom(payload),
                    )
                }

                event.type == "agent.comm" -> {
                    val comm = objectValue(payload["agentComm"]) ?: emptyMap()
                    val direction = nonEmpty(comm, "direction") ?: nonEmpty(payload, "direction")
                    role = nonEmpty(payload, "role")
                        ?: if (direction == "inbound" || direction == "incoming") {
                            "user"
                        } else {
                            "assistant"
                        }
                    kind = if (role == "user") BotRowKind.MESSAGE else BotRowKind.SEND_MESSAGE
                    val fields = fieldsFrom(payload)
                    if (fields["agentComm"] == null && comm.isNotEmpty()) {
                        fields["agentComm"] = JsonObject(comm)
                    }
                    if (fields["text"] == null) {
                        val text = nonEmpty(comm, "message")
                            ?: nonEmpty(comm, "replyText")
                            ?: nonEmpty(payload, "message")
                            ?: nonEmpty(payload, "replyText")
                        if (text != null) fields["text"] = JsonString(text)
                    }
                    body = BotRowBody(
                        type = BotRowBodyType.TEXT,
                        additionalProperties = fields,
                    )
                }

                event.type == "bot.greeting_seeded" -> {
                    role = "assistant"
                    val fields = fieldsFrom(payload)
                    if (fields["text"] == null) {
                        fields["content"]?.let { fields["text"] = it }
                    }
                    body = BotRowBody(
                        type = BotRowBodyType.TEXT,
                        additionalProperties = fields,
                    )
                }

                else -> {
                    body = uiBody(payload, event.type)
                }
            }
            val resolvedBody = body ?: continue
            if (resolvedBody.type == BotRowBodyType.TEXT) {
                role = role ?: nonEmpty(payload, "role") ?: "assistant"
                kind = if (role == "user") BotRowKind.MESSAGE else BotRowKind.SEND_MESSAGE
                val hasText = nonEmpty(resolvedBody.additionalProperties, "text") != null ||
                    nonEmpty(resolvedBody.additionalProperties, "content") != null ||
                    nonEmpty(resolvedBody.additionalProperties, "replyText") != null
                if (!hasText) continue
            }
            result.add(BotRowMutation.Upsert(
                BotRowDraft(
                    id = id,
                    seq = entrySeq(event.time, event.commitSeq ?: 0L),
                    kind = kind,
                    role = role,
                    body = resolvedBody,
                    provenance = provenance,
                    createdAt = event.time,
                ),
                order,
            ))
        }
        return result
    }

    private fun cardOutcomes(
        botID: String,
        events: List<BotProjectionEvent>,
    ): Pair<Map<String, String>, Set<String>> {
        val answered = HashMap<String, String>()
        val dismissed = HashSet<String>()
        val ordered = events.sortedWith(
            compareBy<BotProjectionEvent>(
                { it.commitSeq ?: Long.MAX_VALUE },
                { it.time },
                { it.eventId },
            ),
        )
        for (event in ordered) {
            if (event.principalBotId != null && event.principalBotId != botID) continue
            val data = objectValue(event.data) ?: continue
            val cardID = nonEmpty(data, "cardID") ?: continue
            when (event.type) {
                "card.answered" -> {
                    answered[cardID] = nonEmpty(data, "optionID") ?: answered[cardID] ?: ""
                }
                "card.dismissed" -> dismissed.add(cardID)
            }
        }
        return answered to dismissed
    }

    private fun uiBody(payload: Map<String, JsonValue>, eventType: String): BotRowBody? {
        if (eventType == "card.presented" || payload["cardType"] != null) {
            val raw = nonEmpty(payload, "cardType") ?: return null
            if (raw == "attachment" || raw == "file") {
                return BotRowBody(
                    type = BotRowBodyType.ATTACHMENT,
                    cardKey = nonEmpty(payload, "cardKey"),
                    additionalProperties = fieldsFrom(payload),
                )
            }
            val cardType = BotWidgetCardType.entries.firstOrNull { it.wire == raw }
                ?: return null
            return BotRowBody(
                type = BotRowBodyType.WIDGET,
                cardType = cardType,
                cardKey = nonEmpty(payload, "cardKey"),
                additionalProperties = fieldsFrom(payload),
            )
        }
        return when (nonEmpty(payload, "type") ?: "text") {
            "text" -> BotRowBody(
                type = BotRowBodyType.TEXT,
                additionalProperties = fieldsFrom(payload),
            )
            "attachment" -> BotRowBody(
                type = BotRowBodyType.ATTACHMENT,
                cardKey = nonEmpty(payload, "cardKey"),
                additionalProperties = fieldsFrom(payload),
            )
            "widget" -> null
            "local-tool-permission", "approval" -> BotRowBody(
                type = BotRowBodyType.APPROVAL,
                additionalProperties = fieldsFrom(payload),
            )
            "automation" -> BotRowBody(
                type = BotRowBodyType.AUTOMATION,
                additionalProperties = fieldsFrom(payload),
            )
            "notice" -> BotRowBody(
                type = BotRowBodyType.NOTICE,
                additionalProperties = fieldsFrom(payload),
            )
            else -> null
        }
    }

    // MARK: - Apply

    private fun apply(
        botID: String,
        mutations: List<BotRowMutation>,
    ): BotRowProjectionSnapshot {
        val rows = LinkedHashMap<String, BotRow>()
        val tombstones = LinkedHashMap<String, BotRow>()
        var progressRows = HashMap<String, String>()
        val changes = ArrayList<BotRowChange>()
        var cursor = 0L

        for (mutation in mutations) {
            when (mutation) {
                is BotRowMutation.Upsert -> {
                    val input = mutation.draft
                    var id = input.id
                    var progressKey: String? = null
                    if (input.body.type == BotRowBodyType.WIDGET &&
                        input.body.cardType == BotWidgetCardType.PROGRESS &&
                        input.body.cardKey != null
                    ) {
                        progressKey = "$botID:${input.body.cardKey}"
                        progressRows[progressKey]?.let { id = it }
                    }
                    if (tombstones[id] != null) continue
                    val old = rows[id]
                    val eventIDs = ArrayList(old?.provenance?.eventIDs ?: emptyList())
                    for (eventID in input.provenance.eventIDs) {
                        if (!eventIDs.contains(eventID)) eventIDs.add(eventID)
                    }
                    val provenance = BotRowProvenance(
                        eventIDs = eventIDs,
                        trust = input.provenance.trust,
                        tainted = (old?.provenance?.tainted ?: false) ||
                            input.provenance.tainted,
                    )
                    var row = BotRow(
                        id = id,
                        botID = botID,
                        seq = old?.seq ?: input.seq,
                        updatedSeq = old?.updatedSeq ?: 0L,
                        kind = input.kind,
                        role = input.role,
                        body = input.body,
                        provenance = provenance,
                        streaming = false,
                        createdAt = old?.createdAt ?: input.createdAt,
                        chatActionNonce = input.chatActionNonce,
                    )
                    if (old != null && old.body.cardType == BotWidgetCardType.TASK &&
                        row.body.cardType == BotWidgetCardType.TASK
                    ) {
                        val merged = LinkedHashMap(old.body.additionalProperties)
                        merged.putAll(row.body.additionalProperties)
                        row = row.copy(body = row.body.copy(additionalProperties = merged))
                    }
                    if (old != null && sameContent(old, row)) {
                        if (progressKey != null) progressRows[progressKey] = id
                        continue
                    }
                    cursor += 1
                    row = row.copy(updatedSeq = cursor)
                    rows[id] = row
                    if (progressKey != null) progressRows[progressKey] = id
                    changes.add(BotRowChange.Upsert(row))
                }

                is BotRowMutation.Delete -> {
                    val id = mutation.id
                    if (tombstones[id] != null) continue
                    cursor += 1
                    val old = rows[id]
                    val placeholder = mutation.placeholder
                    var body = BotRowBody(
                        type = BotRowBodyType.DELETED,
                        additionalProperties = LinkedHashMap(placeholder.body.additionalProperties),
                    )
                    if (old != null) body = body.with("deletedKind", JsonString(old.kind.wire))
                    val eventIDs = ArrayList(old?.provenance?.eventIDs ?: emptyList())
                    for (eventID in placeholder.provenance.eventIDs) {
                        if (!eventIDs.contains(eventID)) eventIDs.add(eventID)
                    }
                    val tombstone = BotRow(
                        id = id,
                        botID = botID,
                        seq = old?.seq ?: placeholder.seq,
                        updatedSeq = cursor,
                        kind = BotRowKind.EVENT,
                        role = null,
                        body = body,
                        provenance = BotRowProvenance(
                            eventIDs = eventIDs,
                            trust = BotRowProvenance.PROJECTOR,
                            tainted = false,
                        ),
                        streaming = false,
                        createdAt = old?.createdAt ?: placeholder.createdAt,
                    )
                    rows.remove(id)
                    tombstones[id] = tombstone
                    progressRows = HashMap(progressRows.filterValues { it != id })
                    changes.add(BotRowChange.Delete(id, cursor))
                }
            }
        }
        return BotRowProjectionSnapshot(
            rows = rows.values.sortedWith { lhs, rhs -> rowComparator(lhs, rhs) },
            tombstones = tombstones.values.sortedWith { lhs, rhs -> rowComparator(lhs, rhs) },
            cursor = cursor,
            changes = changes,
        )
    }

    // MARK: - Helpers

    private fun draft(
        id: String,
        record: BotSessionLogRecord,
        kind: BotRowKind,
        role: String?,
        body: BotRowBody,
        trust: String,
    ): BotRowDraft = BotRowDraft(
        id = id,
        seq = entrySeq(record.time, record.seq),
        kind = kind,
        role = role,
        body = body,
        provenance = BotRowProvenance(
            eventIDs = record.eventId?.let { listOf(it) } ?: emptyList(),
            trust = trust,
            tainted = false,
        ),
        createdAt = record.time,
    )

    private fun heldActionNonces(
        botID: String,
        sessionID: String,
        records: List<BotSessionLogRecord>,
        uiEvents: List<BotProjectionEvent>,
    ): Map<Long, String> {
        val directNonces = HashSet<String>()
        for (record in records) {
            if (record.type != "user/message") continue
            val source = objectValue(record.data["source"])
                ?: objectValue(objectValue(record.data["message"])?.get("source"))
            BotTurnOrigin.chatActionNonce(source)?.let { directNonces.add(it) }
        }
        val byTurn = HashMap<Long, LinkedHashSet<String>>()
        for (event in uiEvents) {
            if (event.type != "conversation.turn_started") continue
            if (!event.origin.isDirectUser) continue
            if (event.principalBotId != botID) continue
            if (event.principalSessionId != sessionID) continue
            val turn = event.turnId?.toLongOrNull() ?: continue
            if (turn <= 0) continue
            val data = objectValue(event.data) ?: continue
            if (stringValue(data["action"]) != "chat") continue
            val nonce = nonEmpty(data, "nonce") ?: continue
            if (event.eventId != "action:$nonce") continue
            if (directNonces.contains(nonce)) continue
            byTurn.getOrPut(turn) { LinkedHashSet() }.add(nonce)
        }
        val result = HashMap<Long, String>()
        for ((turn, nonces) in byTurn) {
            if (nonces.size == 1) result[turn] = nonces.first()
        }
        return result
    }

    private fun approvalStatus(text: String): String {
        val fields = parseArguments(text)
        if ((fields["allowed"] as? com.phonedsh.agentcore.JsonBool)?.value == false ||
            stringValue(fields["decision"]) == "denied"
        ) {
            return "denied"
        }
        if ((fields["allowed"] as? com.phonedsh.agentcore.JsonBool)?.value == true) {
            return "allowed"
        }
        val lower = text.lowercase()
        if (text.contains("永不允许") || text.contains("永不允許") || lower.contains("never allow")) {
            return "never"
        }
        if (text.contains("总是允许") || text.contains("總是允許") || lower.contains("always allow")) {
            return "always"
        }
        if (text.contains("超时") || text.contains("逾時") ||
            lower.contains("timed out") || lower.contains("timeout")
        ) {
            return "timed-out"
        }
        if (text.contains("拒绝") || text.contains("拒絕") || lower.contains("denied") ||
            lower.contains("rejected") || lower.contains("not allowed")
        ) {
            return "denied"
        }
        if (text.contains("允许") || text.contains("允許") || lower.contains("allowed")) {
            return "allowed"
        }
        return "unknown"
    }

    private fun approvalLabel(status: String): String = when (status) {
        "allowed" -> "已允许一次"
        "always" -> "已总是允许"
        "denied" -> "已拒绝"
        "never" -> "已设为永不允许"
        "timed-out" -> "超时未回应（视为拒绝）"
        else -> "已处理"
    }

    private fun approvalAskStatus(status: String): String = when (status) {
        "allowed", "always" -> "allowed"
        "timed-out" -> "timed-out"
        "unknown" -> "pending"
        else -> status
    }

    public companion object {
        private val IGNORED_TYPES: Set<String> = setOf(
            "session", "permission/preset", "sandbox/mode", "approval/policy",
            "system/message", "developer/message", "agent/inbox/spliced",
            "request/header", "request/context", "session/title", "session/end-seed",
            "phone-dsh/session-erasure", "session-log-deepseek/delivery-accepted",
            "job/registered", "job/settled", "step/start", "step/end",
            "turn/start", "assistant/stream",
        )

        private val SUPPORTED_UI_TYPES: Set<String> = setOf(
            "card.presented", "ui.send_to_user", "ui.notice", "ui.system_event",
            "agent.comm", "approval.requested", "approval.decided",
            "task.created", "task.started", "task.updated", "task.stop_requested",
            "task.settled", "task.resumed", "conversation.automation_run",
            "routine.run_started", "routine.run_finished", "verification.reported",
            "bot.greeting_seeded",
        )

        private val FLATTEN_KEYS: List<String> = listOf(
            "row", "entry", "message", "body", "card", "task",
            "automation", "routine", "run", "notice",
        )

        private val FIELD_EXCLUDES: Set<String> = setOf(
            "id", "rowID", "type", "cardType", "cardKey", "trust", "tainted",
        )

        /** `entrySeq(time, sourceSeq)` (`projection.md` §3.2). */
        public fun entrySeq(time: Long, sourceSeq: Long): Long {
            val positiveSource = maxOf(0L, sourceSeq) % 1000L
            val milliseconds = try {
                Math.multiplyExact(time, 1000L)
            } catch (_: ArithmeticException) {
                return if (time < 0) Long.MIN_VALUE else Long.MAX_VALUE
            }
            return try {
                Math.addExact(milliseconds, positiveSource)
            } catch (_: ArithmeticException) {
                Long.MAX_VALUE
            }
        }

        public fun rowID(sessionID: String, seq: Long, suffix: String = ""): String =
            "e-$sessionID-$seq$suffix"

        internal fun sameContent(lhs: BotRow, rhs: BotRow): Boolean =
            lhs.id == rhs.id && lhs.botID == rhs.botID && lhs.seq == rhs.seq &&
                lhs.kind == rhs.kind && lhs.role == rhs.role && lhs.body == rhs.body &&
                lhs.provenance == rhs.provenance && lhs.streaming == rhs.streaming &&
                lhs.createdAt == rhs.createdAt && lhs.chatActionNonce == rhs.chatActionNonce

        internal fun rowComparator(lhs: BotRow, rhs: BotRow): Int {
            if (lhs.seq != rhs.seq) return lhs.seq.compareTo(rhs.seq)
            return lhs.id.compareTo(rhs.id)
        }

        private fun fieldsFrom(objectValue: Map<String, JsonValue>): LinkedHashMap<String, JsonValue> {
            val fields = LinkedHashMap<String, JsonValue>()
            for ((key, value) in objectValue) {
                if (key in FIELD_EXCLUDES) continue
                fields[key] = value
            }
            return fields
        }

        private fun nonEmpty(objectValue: Map<String, JsonValue>, key: String): String? {
            val value = (objectValue[key] as? JsonString)?.value ?: return null
            return if (value.isEmpty()) null else value
        }

        private fun objectValue(value: JsonValue?): Map<String, JsonValue>? =
            (value as? JsonObject)?.members

        private fun stringValue(value: JsonValue?): String? = (value as? JsonString)?.value

        private fun jsonLong(value: JsonValue?): Long? {
            val number = value as? JsonNumber ?: return null
            return number.asLongOrNull()
        }

        private fun contentText(value: JsonValue?): String {
            val blocks = jsonArray(value)
            val out = StringBuilder()
            for (block in blocks) {
                val members = objectValue(block) ?: continue
                if (stringValue(members["type"]) != "text") continue
                out.append(stringValue(members["text"]) ?: "")
            }
            return out.toString()
        }

        private fun parseArguments(text: String?): Map<String, JsonValue> {
            if (text == null) return emptyMap()
            return try {
                objectValue(JsonValue.parse(text)) ?: emptyMap()
            } catch (_: Exception) {
                emptyMap()
            }
        }

        private fun isApprovalTool(name: String): Boolean {
            val last = name.split("__").lastOrNull() ?: ""
            return last.split(".").lastOrNull() == "RequestApproval"
        }

        private fun automationStatus(
            run: Map<String, JsonValue>,
            record: BotSessionLogRecord,
        ): String {
            val raw = (stringValue(run["status"])
                ?: stringValue(record.data["status"]) ?: "").lowercase()
            if (raw in AUTOMATION_STATUSES) return raw
            val tail = record.type.split("/").lastOrNull() ?: ""
            if (tail in AUTOMATION_RUNNING) return "running"
            if (tail in AUTOMATION_SENT) return "sent"
            if (tail in AUTOMATION_FAILED) return "failed"
            return "idle"
        }

        private fun isInjected(text: String): Boolean =
            text.isEmpty() || text.startsWith("Current runtime context.") ||
                text.startsWith("<system-reminder>") ||
                text.startsWith("Check the [exit code: N] marker")

        private fun stripHeldMessages(text: String): String {
            val open = "<held_agent_messages>"
            val close = "</held_agent_messages>"
            val start = text.indexOf(open)
            if (start < 0) return text
            val end = text.indexOf(close, start + open.length)
            if (end < 0) return text
            val before = text.substring(0, start)
            var after = text.substring(end + close.length)
            after = after.dropWhile { it == '\n' || it == '\r' }
            return (before + after)
                .replace(Regex("[ \\t]+\\n"), "\n")
                .trim()
        }

        private fun stripContinuation(text: String): String {
            val open = "<session_continuation>"
            if (!text.startsWith(open)) return text
            val close = "</session_continuation>"
            val end = text.indexOf(close, open.length)
            if (end < 0) return ""
            return text.substring(end + close.length).trim()
        }

        private val AUTOMATION_STATUSES = setOf("confirming", "running", "sent", "failed", "idle")
        private val AUTOMATION_RUNNING = setOf("start", "started", "run", "running")
        private val AUTOMATION_SENT = setOf("end", "ended", "done", "completed", "sent")
        private val AUTOMATION_FAILED = setOf("fail", "failed", "error")
    }
}
