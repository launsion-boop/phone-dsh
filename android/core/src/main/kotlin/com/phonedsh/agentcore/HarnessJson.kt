// Host contract 1 — schema-shaped JSON decoding and command encoding.
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

/**
 * The result of decoding one event line.
 *
 * [UnknownKindDropped] is not an event and must never be surfaced as one: the
 * host contract's `kind` set is closed, so a consumer drops the line, keeps
 * reading and treats its `seq` as consumed (host README §2.2 rule 2,
 * event-kinds.md §3). [UnknownKindDropped.seq] exists only so a transport that
 * keeps an internal resume cursor can advance past the dropped line; it does
 * **not** advance the caller's cursor, which remains the caller's own last
 * processed durable `seq`. The decoded `kind` itself is deliberately not
 * carried, because it is never passed through, renamed or guessed.
 */
public sealed interface HarnessEventDecode {
    /** A known event ready to be emitted. */
    public data class Event(public val event: HarnessEvent) : HarnessEventDecode

    /** An event of a kind this contract version does not know; drop it and consume its seq. */
    public data class UnknownKindDropped(public val seq: Long?) : HarnessEventDecode
}

/**
 * Dependency-free codec for the `spec/host/v1` harness values.
 *
 * Two rules from host README §2.2 are implemented here, not left to callers:
 *
 * 1. **Unknown members are ignored.** Every decoder reads only the members its
 *    schema defines; additive changes therefore do not break a contract-1
 *    consumer. This is the Kotlin equivalent of `ignoreUnknownKeys = true`.
 * 2. **An unknown event `kind` is dropped.** [decodeEvent] returns `null` and
 *    [decodeEventLine] returns [HarnessEventDecode.UnknownKindDropped]; the
 *    unknown value is never returned as a kind and the stream keeps running.
 *
 * A malformed known value is reported as [HarnessDecodingException]
 * (`invalid_response`) naming the JSON-path-like location; it is not silently
 * repaired. Command kinds are closed too: an unknown command kind is an error,
 * because commands are host-authored and never arrive from a newer peer.
 *
 * This codec is intentionally minimal; it validates the schema's required
 * members, enum values and integer bounds, and ignores every other member. It
 * is **the host contract's stream-format decoder, not a general-purpose JSON
 * library**: every entry point reads only the members `spec/host/v1` defines.
 * [JsonValue.parse] is the escape hatch for arbitrary tool arguments and for
 * the command encoder, not a general document API.
 */
public object HarnessJson {
    private const val MAX_LENGTH: Int = Int.MAX_VALUE

    private val REQUEST_ID_PATTERN = Regex("^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$")
    private val BASE64_PATTERN = Regex("^[A-Za-z0-9+/]*={0,2}$")

    // ------------------------------------------------------------------ values

    /** Decodes `schema/harness-capabilities.schema.json`; all seven members are required. */
    public fun decodeCapabilities(json: String): HarnessCapabilities =
        decodeCapabilities(parseObject(json, "capabilities"), "capabilities")

    /** Decodes `schema/harness-session-request.schema.json`; an empty object is a valid request. */
    public fun decodeSessionRequest(json: String): HarnessSessionRequest =
        decodeSessionRequest(parseObject(json, "session_request"), "session_request")

    /** Decodes `schema/harness-session.schema.json`; `last_seq` is optional and is not a resume cursor. */
    public fun decodeSession(json: String): HarnessSession =
        decodeSession(parseObject(json, "session"), "session")

    /** Decodes `schema/harness-goal.schema.json`. */
    public fun decodeGoal(json: String): HarnessGoal =
        decodeGoal(parseObject(json, "goal"), "goal")

    /** Decodes `schema/harness-error.schema.json`. */
    public fun decodeError(json: String): HarnessError =
        decodeError(parseObject(json, "error"), "error")

    /**
     * Decodes one event line, returning `null` when the `kind` is not one of the
     * fifteen contract kinds (drop the event, keep reading).
     */
    public fun decodeEvent(json: String): HarnessEvent? = when (val decoded = decodeEventLine(json)) {
        is HarnessEventDecode.Event -> decoded.event
        is HarnessEventDecode.UnknownKindDropped -> null
    }

    /** Decodes one event line without losing the consumed `seq` of a dropped unknown kind. */
    public fun decodeEventLine(json: String): HarnessEventDecode {
        val obj = parseObject(json, "event")
        val kindWire = obj.requiredString("kind", "event", 1, 128)
        val name = HarnessKindName.fromWire(kindWire)
            ?: return HarnessEventDecode.UnknownKindDropped(obj.droppedSeq())

        val sessionId = obj.requiredString("session_id", "event", 1, 256)
        val timeMs = obj.requiredLong("time_ms", "event", 0)
        val seq = obj.optionalLong("seq", "event", 0)
        if (name.durable && seq == null) {
            fail("event", "durable kind '${name.wire}' requires 'seq'")
        }
        if (!name.durable && seq != null) {
            fail("event", "best-effort kind '${name.wire}' must not carry 'seq'")
        }

        val kind = decodeKind(obj, name, "event")
        val detail = if (name == HarnessKindName.TOOL_RESULT) {
            obj.optionalObject("tool_result_detail", "event")
                ?.let { decodeToolResultDetail(it, "event.tool_result_detail") }
        } else {
            null
        }
        val rawKind = if (name == HarnessKindName.TURN_ENDED) {
            obj.optionalString("raw_turn_end_kind", "event", 1, 128)
        } else {
            null
        }
        val rawCause = if (name == HarnessKindName.TURN_ENDED) {
            obj.optionalString("raw_turn_end_cause", "event", 0, 65536)
        } else {
            null
        }
        return HarnessEventDecode.Event(
            HarnessEvent(
                sessionId = sessionId,
                timeMs = timeMs,
                seq = seq,
                kind = kind,
                toolResultDetail = detail,
                rawTurnEndKind = rawKind,
                rawTurnEndCause = rawCause,
            ),
        )
    }

    // ---------------------------------------------------------------- commands

    /** Decodes one `schema/harness-command.schema.json` variant. */
    public fun decodeCommand(json: String): HarnessCommand =
        decodeCommand(parseObject(json, "command"), "command")

    /**
     * Encodes one command as compact JSON with `lower_snake_case` members.
     *
     * `cancel`, `cancel_with_cause` and `shutdown` carry no `request_id`, and a
     * prompt omits `attachments` when it has none; no member outside the schema
     * is ever emitted.
     */
    public fun encodeCommand(command: HarnessCommand): String = encodeCommandValue(command).toJsonString()

    // ------------------------------------------------------------- capabilities

    private fun decodeCapabilities(obj: JsonObject, path: String): HarnessCapabilities {
        val resumeWire = obj.requiredString("resume", path, 1, 16)
        val resume = HarnessCapabilities.Resume.fromWire(resumeWire)
            ?: fail(path, "'resume' must be one of native, replay, none; got '$resumeWire'")
        val permissionWire = obj.requiredString("permission", path, 1, 16)
        val permission = HarnessCapabilities.Permission.fromWire(permissionWire)
            ?: fail(path, "'permission' must be one of native, relay, none; got '$permissionWire'")
        val clientToolsWire = obj.requiredString("client_tools", path, 1, 16)
        val clientTools = HarnessCapabilities.ClientTools.fromWire(clientToolsWire)
            ?: fail(path, "'client_tools' must be one of native, bridge, none; got '$clientToolsWire'")
        return HarnessCapabilities(
            cancel = obj.requiredBool("cancel", path),
            steer = obj.requiredBool("steer", path),
            resume = resume,
            permission = permission,
            clientTools = clientTools,
            toolVisibility = obj.requiredBool("tool_visibility", path),
            runsWhileAppSuspended = obj.requiredBool("runs_while_app_suspended", path),
        )
    }

    // ------------------------------------------------------------ session request

    private fun decodeSessionRequest(obj: JsonObject, path: String): HarnessSessionRequest {
        val sessionId = obj.optionalString("session_id", path, 1, 256)
        val preset = obj.optionalString("preset", path, 1, 256)
        val workspace = obj.optionalString("workspace", path, 1, 4096)
        val instructions = obj.optionalString("instructions", path, 1, 65536)
        val clientTools = obj.optionalArray("client_tools", path)?.values?.mapIndexed { index, value ->
            decodeMcpServer(value, "$path.client_tools[$index]")
        } ?: emptyList()
        val metadata = obj.optionalObject("metadata", path)?.let { decodeMetadata(it, "$path.metadata") } ?: emptyMap()
        return HarnessSessionRequest(
            sessionId = sessionId,
            preset = preset,
            workspace = workspace,
            instructions = instructions,
            clientTools = clientTools,
            metadata = metadata,
        )
    }

    private fun decodeMcpServer(value: JsonValue, path: String): McpServerReference {
        val obj = value.asObject(path)
        val name = obj.requiredString("name", path, 1, 128)
        val transportObj = obj.requiredObject("transport", path)
        val transportPath = "$path.transport"
        val type = transportObj.requiredString("type", transportPath, 1, 64)
        val transport = when (type) {
            "streamable_http" -> McpTransport.StreamableHttp(
                url = transportObj.requiredString("url", transportPath, 1, 2048),
                headers = transportObj.optionalObject("headers", transportPath)
                    ?.let { decodeStringMap(it, "$transportPath.headers") }
                    ?: emptyMap(),
            )
            "relay" -> McpTransport.Relay(transportObj.requiredString("relay_id", transportPath, 1, 128))
            "in_process" -> McpTransport.InProcess(transportObj.requiredString("name", transportPath, 1, 128))
            else -> fail(transportPath, "'type' must be one of streamable_http, relay, in_process; got '$type'")
        }
        val allowedTools = obj.optionalArray("allowed_tools", path)?.values?.mapIndexed { index, element ->
            stringValue(element, "$path.allowed_tools[$index]", "allowed_tools", 1, 128)
        } ?: emptyList()
        return McpServerReference(name = name, transport = transport, allowedTools = allowedTools)
    }

    private fun decodeMetadata(obj: JsonObject, path: String): Map<String, String> {
        val result = LinkedHashMap<String, String>()
        for ((key, value) in obj.members) {
            val text = (value as? JsonString)?.value
                ?: fail(path, "metadata value for '$key' must be a string")
            checkLength(text, "metadata['$key']", path, 0, 1024)
            result[key] = text
        }
        return result
    }

    private fun decodeStringMap(obj: JsonObject, path: String): Map<String, String> {
        val result = LinkedHashMap<String, String>()
        for ((key, value) in obj.members) {
            result[key] = (value as? JsonString)?.value
                ?: fail(path, "header value for '$key' must be a string")
        }
        return result
    }

    // ---------------------------------------------------------------- session

    private fun decodeSession(obj: JsonObject, path: String): HarnessSession {
        val id = obj.requiredString("id", path, 1, 256)
        val capabilities = decodeCapabilities(obj.requiredObject("capabilities", path), "$path.capabilities")
        val lastSeq = obj.optionalLong("last_seq", path, 0)
        return HarnessSession(id = id, capabilities = capabilities, lastSeq = lastSeq)
    }

    // ------------------------------------------------------------------- goal

    private fun decodeGoal(obj: JsonObject, path: String): HarnessGoal {
        val objective = obj.requiredString("objective", path, 1, 65536)
        val phaseWire = obj.requiredString("phase", path, 1, 16)
        val phase = HarnessGoal.Phase.fromWire(phaseWire)
            ?: fail(path, "'phase' must be one of active, paused, blocked, complete; got '$phaseWire'")
        val blockedReason = obj.optionalString("blocked_reason", path, 1, 65536)
        if (phase == HarnessGoal.Phase.BLOCKED && blockedReason == null) {
            fail(path, "phase 'blocked' requires 'blocked_reason'")
        }
        if (phase != HarnessGoal.Phase.BLOCKED && blockedReason != null) {
            fail(path, "'blocked_reason' is only allowed when phase is 'blocked'")
        }
        return HarnessGoal(
            objective = objective,
            phase = phase,
            roundsStarted = obj.requiredLong("rounds_started", path, 0),
            maxGoalRounds = obj.requiredLong("max_goal_rounds", path, 0),
            blockedReason = blockedReason,
        )
    }

    // ------------------------------------------------------------------ error

    private fun decodeError(obj: JsonObject, path: String): HarnessError {
        val codeWire = obj.requiredString("code", path, 1, 32)
        val code = HarnessErrorCode.fromWire(codeWire)
            ?: fail(path, "'code' is not one of the eight harness error classes; got '$codeWire'")
        return HarnessError(
            code = code,
            message = obj.optionalString("message", path, 0, 65536),
            retryAfterMs = obj.optionalLong("retry_after_ms", path, 0),
        )
    }

    // ----------------------------------------------------------------- command

    private fun decodeCommand(obj: JsonObject, path: String): HarnessCommand {
        val kindWire = obj.requiredString("kind", path, 1, 64)
        val kind = HarnessCommand.Kind.fromWire(kindWire)
            ?: fail(path, "unknown command kind '$kindWire'")
        return when (kind) {
            HarnessCommand.Kind.PROMPT -> HarnessCommand.Prompt(
                text = obj.requiredString("text", path, 1, 1048576),
                requestId = obj.requiredRequestId(path),
                attachments = obj.optionalArray("attachments", path)?.values?.mapIndexed { index, value ->
                    decodeAttachment(value, "$path.attachments[$index]")
                } ?: emptyList(),
            )
            HarnessCommand.Kind.STEER -> HarnessCommand.Steer(
                text = obj.requiredString("text", path, 1, 1048576),
                requestId = obj.requiredRequestId(path),
            )
            HarnessCommand.Kind.CANCEL -> HarnessCommand.Cancel
            HarnessCommand.Kind.CANCEL_WITH_CAUSE -> HarnessCommand.CancelWithCause(
                cause = decodeCancelCause(obj.requiredObject("cause", path), "$path.cause"),
            )
            HarnessCommand.Kind.PERMISSION_RESPONSE -> HarnessCommand.PermissionResponse(
                requestId = obj.requiredRequestId(path),
                decision = decodePermissionDecision(
                    obj.requiredString("decision", path, 1, 16),
                    path,
                ),
            )
            HarnessCommand.Kind.QUESTION_RESPONSE -> HarnessCommand.QuestionResponse(
                requestId = obj.requiredRequestId(path),
                answer = obj.requiredString("answer", path, 0, 65536),
            )
            HarnessCommand.Kind.SHUTDOWN -> HarnessCommand.Shutdown
        }
    }

    private fun decodeCancelCause(obj: JsonObject, path: String): AgentCancelCause {
        val kind = obj.requiredString("kind", path, 1, 16)
        return when (kind) {
            "user" -> AgentCancelCause.User
            "hook" -> AgentCancelCause.Hook
            "budget" -> AgentCancelCause.Budget(obj.requiredString("detail", path, 1, 4096))
            "timeout" -> AgentCancelCause.Timeout(obj.requiredString("detail", path, 1, 4096))
            else -> fail(path, "unknown cancel cause '$kind'")
        }
    }

    private fun decodePermissionDecision(wire: String, path: String): PermissionDecision =
        PermissionDecision.fromWire(wire)
            ?: fail(path, "'decision' must be one of allow_once, allow_always, deny; got '$wire'")

    private fun decodeAttachment(value: JsonValue, path: String): HarnessAttachment {
        val obj = value.asObject(path)
        val name = obj.requiredString("name", path, 1, 255)
        val mimeType = obj.requiredString("mime_type", path, 1, 255)
        val dataBase64 = obj.requiredString("data_base64", path, 0, MAX_LENGTH)
        if (!BASE64_PATTERN.matches(dataBase64)) {
            fail(path, "'data_base64' is not base64 text")
        }
        return HarnessAttachment(name = name, mimeType = mimeType, dataBase64 = dataBase64)
    }

    private fun encodeCommandValue(command: HarnessCommand): JsonObject = when (command) {
        is HarnessCommand.Prompt -> {
            val members = linkedMapOf<String, JsonValue>(
                "kind" to JsonString(HarnessCommand.Kind.PROMPT.wire),
                "text" to JsonString(command.text),
                "request_id" to JsonString(command.requestId),
            )
            if (command.attachments.isNotEmpty()) {
                members["attachments"] = JsonArray(command.attachments.map { encodeAttachment(it) })
            }
            JsonObject(members)
        }
        is HarnessCommand.Steer -> jsonObject(
            "kind" to JsonString(HarnessCommand.Kind.STEER.wire),
            "text" to JsonString(command.text),
            "request_id" to JsonString(command.requestId),
        )
        is HarnessCommand.Cancel -> jsonObject("kind" to JsonString(HarnessCommand.Kind.CANCEL.wire))
        is HarnessCommand.CancelWithCause -> jsonObject(
            "kind" to JsonString(HarnessCommand.Kind.CANCEL_WITH_CAUSE.wire),
            "cause" to encodeCancelCause(command.cause),
        )
        is HarnessCommand.PermissionResponse -> jsonObject(
            "kind" to JsonString(HarnessCommand.Kind.PERMISSION_RESPONSE.wire),
            "request_id" to JsonString(command.requestId),
            "decision" to JsonString(command.decision.wire),
        )
        is HarnessCommand.QuestionResponse -> jsonObject(
            "kind" to JsonString(HarnessCommand.Kind.QUESTION_RESPONSE.wire),
            "request_id" to JsonString(command.requestId),
            "answer" to JsonString(command.answer),
        )
        is HarnessCommand.Shutdown -> jsonObject("kind" to JsonString(HarnessCommand.Kind.SHUTDOWN.wire))
    }

    private fun encodeAttachment(attachment: HarnessAttachment): JsonObject = jsonObject(
        "name" to JsonString(attachment.name),
        "mime_type" to JsonString(attachment.mimeType),
        "data_base64" to JsonString(attachment.dataBase64),
    )

    private fun encodeCancelCause(cause: AgentCancelCause): JsonObject = when (cause) {
        is AgentCancelCause.User -> jsonObject("kind" to JsonString("user"))
        is AgentCancelCause.Hook -> jsonObject("kind" to JsonString("hook"))
        is AgentCancelCause.Budget -> jsonObject(
            "kind" to JsonString("budget"),
            "detail" to JsonString(cause.detail),
        )
        is AgentCancelCause.Timeout -> jsonObject(
            "kind" to JsonString("timeout"),
            "detail" to JsonString(cause.detail),
        )
    }

    // ------------------------------------------------------------------- event

    private fun decodeKind(obj: JsonObject, name: HarnessKindName, path: String): HarnessKind = when (name) {
        HarnessKindName.ASSISTANT_DELTA -> HarnessKind.AssistantDelta(
            obj.requiredString("text", path, 0, MAX_LENGTH),
        )
        HarnessKindName.REASONING_DELTA -> HarnessKind.ReasoningDelta(
            obj.requiredString("text", path, 0, MAX_LENGTH),
        )
        HarnessKindName.ASSISTANT_MESSAGE -> HarnessKind.AssistantMessage(
            obj.requiredString("text", path, 1, MAX_LENGTH),
        )
        HarnessKindName.TOOL_CALL -> HarnessKind.ToolCall(
            callId = obj.requiredString("call_id", path, 0, 256),
            name = obj.requiredString("name", path, 0, 256),
            arguments = obj.requiredValue("arguments", path),
        )
        HarnessKindName.TOOL_RESULT -> HarnessKind.ToolResult(
            callId = obj.requiredString("call_id", path, 0, 256),
            isError = obj.requiredBool("is_error", path),
            summary = obj.requiredString("summary", path, 0, 300),
        )
        HarnessKindName.PERMISSION_REQUESTED -> HarnessKind.PermissionRequested(
            decodePermissionRequest(obj.requiredObject("request", path), "$path.request"),
        )
        HarnessKindName.QUESTION_REQUESTED -> HarnessKind.QuestionRequested(
            decodeQuestion(obj.requiredObject("request", path), "$path.request"),
        )
        HarnessKindName.USER_MESSAGE -> HarnessKind.UserMessage(
            text = obj.requiredString("text", path, 1, MAX_LENGTH),
            source = obj.requiredString("source", path, 1, 128),
        )
        HarnessKindName.INBOX_SPLICED -> HarnessKind.InboxSpliced(
            messages = obj.requiredArray("messages", path).values.let { values ->
                if (values.isEmpty()) {
                    fail(path, "'messages' must have at least one item")
                }
                values.mapIndexed { index, value ->
                    decodeUserInput(value, "$path.messages[$index]")
                }
            },
        )
        HarnessKindName.TURN_STARTED -> HarnessKind.TurnStarted(
            turnId = obj.requiredString("turn_id", path, 1, 256),
        )
        HarnessKindName.TURN_ENDED -> HarnessKind.TurnEnded(
            turnId = obj.requiredString("turn_id", path, 1, 256),
            reason = decodeTurnEnd(obj.requiredObject("reason", path), "$path.reason"),
        )
        HarnessKindName.PROGRESS -> HarnessKind.Progress(
            phase = obj.requiredString("phase", path, 1, 128),
            step = obj.requiredLong("step", path, 0),
            of = obj.optionalLong("of", path, 0),
        )
        HarnessKindName.SESSION_STATUS -> HarnessKind.SessionStatus(
            obj.requiredString("status", path, 1, 4096),
        )
        HarnessKindName.USAGE -> HarnessKind.Usage(
            inputTokens = obj.requiredLong("input_tokens", path, 0),
            outputTokens = obj.requiredLong("output_tokens", path, 0),
        )
        HarnessKindName.EXITED -> HarnessKind.Exited(
            obj.requiredString("reason", path, 0, 65536),
        )
    }

    private fun decodePermissionRequest(obj: JsonObject, path: String): HarnessPermissionRequest {
        val riskWire = obj.requiredString("risk", path, 1, 32)
        val risk = HarnessToolRisk.fromWire(riskWire)
            ?: fail(path, "'risk' must be one of read_only, side_effect, ui; got '$riskWire'")
        return HarnessPermissionRequest(
            requestId = obj.requiredRequestId(path),
            tool = obj.requiredString("tool", path, 1, 256),
            summary = obj.requiredString("summary", path, 0, 4096),
            risk = risk,
            expiresAtMs = obj.optionalLong("expires_at_ms", path, 0),
        )
    }

    private fun decodeQuestion(obj: JsonObject, path: String): HarnessQuestion {
        val requestId = obj.requiredRequestId(path)
        val prompt = obj.requiredString("prompt", path, 0, 65536)
        val options = obj.requiredArray("options", path).values.mapIndexed { index, value ->
            stringValue(value, "$path.options[$index]", "options", 0, 4096)
        }
        val questions = obj.optionalArray("questions", path)?.values?.let { values ->
            if (values.isEmpty()) {
                fail(path, "'questions' must have at least one item when present")
            }
            values.mapIndexed { index, value ->
                decodeQuestionItem(value, "$path.questions[$index]")
            }
        }
        return HarnessQuestion(
            requestId = requestId,
            prompt = prompt,
            options = options,
            questions = questions,
        )
    }

    private fun decodeQuestionItem(value: JsonValue, path: String): HarnessQuestionItem {
        val obj = value.asObject(path)
        return HarnessQuestionItem(
            id = obj.requiredString("id", path, 0, 256),
            prompt = obj.requiredString("prompt", path, 0, 65536),
            options = obj.requiredArray("options", path).values.mapIndexed { index, element ->
                stringValue(element, "$path.options[$index]", "options", 0, 4096)
            },
            multiple = obj.requiredBool("multiple", path),
        )
    }

    private fun decodeUserInput(value: JsonValue, path: String): HarnessUserInput {
        val obj = value.asObject(path)
        return HarnessUserInput(
            text = obj.requiredString("text", path, 1, MAX_LENGTH),
            source = obj.requiredString("source", path, 1, 128),
        )
    }

    private fun decodeTurnEnd(obj: JsonObject, path: String): HarnessTurnEnd {
        val kind = obj.requiredString("kind", path, 1, 32)
        return when (kind) {
            "completed" -> HarnessTurnEnd.Completed
            "cancelled" -> HarnessTurnEnd.Cancelled
            "failed" -> HarnessTurnEnd.Failed(obj.requiredString("message", path, 0, 65536))
            "budget_exhausted" -> HarnessTurnEnd.BudgetExhausted(obj.requiredString("detail", path, 1, 4096))
            else -> fail(path, "unknown turn-end reason '$kind'")
        }
    }

    private fun decodeToolResultDetail(obj: JsonObject, path: String): HarnessToolResultDetail =
        HarnessToolResultDetail(
            text = obj.requiredString("text", path, 0, MAX_LENGTH),
            truncated = obj.requiredBool("truncated", path),
            eventSeq = obj.requiredLong("event_seq", path, 0),
            sessionLogPath = obj.requiredString("session_log_path", path, 1, 4096),
        )

    // ----------------------------------------------------------------- helpers

    private fun parseObject(json: String, path: String): JsonObject {
        val value = try {
            JsonValue.parse(json)
        } catch (failure: HarnessDecodingException) {
            throw HarnessDecodingException(path, failure.message ?: "invalid JSON", failure)
        }
        return value as? JsonObject ?: fail(path, "expected a JSON object")
    }

    private fun JsonObject.requiredValue(name: String, path: String): JsonValue =
        members[name] ?: fail(path, "missing required member '$name'")

    private fun JsonObject.requiredString(
        name: String,
        path: String,
        min: Int = 0,
        max: Int = MAX_LENGTH,
    ): String = optionalString(name, path, min, max) ?: fail(path, "missing required member '$name'")

    private fun JsonObject.optionalString(
        name: String,
        path: String,
        min: Int = 0,
        max: Int = MAX_LENGTH,
    ): String? {
        val value = members[name] ?: return null
        val text = (value as? JsonString)?.value ?: fail(path, "member '$name' must be a string")
        return checkLength(text, name, path, min, max)
    }

    private fun JsonObject.requiredLong(name: String, path: String, min: Long = 0): Long =
        optionalLong(name, path, min) ?: fail(path, "missing required member '$name'")

    private fun JsonObject.optionalLong(name: String, path: String, min: Long = 0): Long? {
        val value = members[name] ?: return null
        val number = value as? JsonNumber ?: fail(path, "member '$name' must be an integer")
        val result = number.asLongOrNull()
            ?: fail(path, "member '$name' must be an integer that fits in a signed 64-bit value")
        if (result < min) {
            fail(path, "member '$name' must be >= $min")
        }
        return result
    }

    private fun JsonObject.requiredBool(name: String, path: String): Boolean {
        val value = members[name] ?: fail(path, "missing required member '$name'")
        return (value as? JsonBool)?.value ?: fail(path, "member '$name' must be a boolean")
    }

    private fun JsonObject.requiredObject(name: String, path: String): JsonObject {
        val value = members[name] ?: fail(path, "missing required member '$name'")
        return value.asObject(path)
    }

    private fun JsonObject.optionalObject(name: String, path: String): JsonObject? {
        val value = members[name] ?: return null
        return value.asObject(path)
    }

    private fun JsonObject.requiredArray(name: String, path: String): JsonArray {
        val value = members[name] ?: fail(path, "missing required member '$name'")
        return value as? JsonArray ?: fail(path, "member '$name' must be an array")
    }

    private fun JsonObject.optionalArray(name: String, path: String): JsonArray? {
        val value = members[name] ?: return null
        return value as? JsonArray ?: fail(path, "member '$name' must be an array")
    }

    private fun JsonValue.asObject(path: String): JsonObject =
        this as? JsonObject ?: fail(path, "expected a JSON object")

    private fun stringValue(
        value: JsonValue,
        path: String,
        name: String,
        min: Int = 0,
        max: Int = MAX_LENGTH,
    ): String {
        val text = (value as? JsonString)?.value ?: fail(path, "element of '$name' must be a string")
        return checkLength(text, name, path, min, max)
    }

    private fun JsonObject.requiredRequestId(path: String): String {
        val requestId = requiredString("request_id", path, 1, 128)
        if (!REQUEST_ID_PATTERN.matches(requestId)) {
            fail(path, "member 'request_id' does not match $REQUEST_ID_PATTERN")
        }
        return requestId
    }

    private fun checkLength(text: String, name: String, path: String, min: Int, max: Int): String {
        val length = text.codePointCount(0, text.length)
        if (length < min || length > max) {
            fail(path, "member '$name' has $length characters, outside [$min, $max]")
        }
        return text
    }

    private fun JsonObject.droppedSeq(): Long? = (members["seq"] as? JsonNumber)
        ?.asLongOrNull()
        ?.takeIf { it >= 0 }

    private fun jsonObject(vararg members: Pair<String, JsonValue>): JsonObject {
        val map = LinkedHashMap<String, JsonValue>(members.size)
        for ((key, value) in members) {
            map[key] = value
        }
        return JsonObject(map)
    }

    private fun fail(path: String, detail: String): Nothing = throw HarnessDecodingException(path, detail)
}
