// SPDX-License-Identifier: MIT
package com.phonedsh.bot.watchdog

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import java.math.BigDecimal
import java.text.Normalizer
import kotlin.math.ceil

/** The six context-lint rules, in the frozen reporting order (`observability.md` §3). */
public enum class BotContextLintRule(public val wireValue: String) {
    SYSTEM_PROMPT_BLOAT("system-prompt-bloat"),
    TOOL_RESULT_BLOAT("tool-result-bloat"),
    DUPLICATE_CONTEXT("duplicate-context"),
    ORPHAN_TOOL_CALL("orphan-tool-call"),
    ORPHAN_TOOL_RESULT("orphan-tool-result"),
    TOOL_DEF_BLOAT("tool-def-bloat");

    public companion object {
        public fun fromWire(value: String): BotContextLintRule? =
            values().firstOrNull { it.wireValue == value }
    }
}

public enum class BotContextLintSeverity(public val wireValue: String) {
    WARN("warn"),
    ERROR("error");

    public companion object {
        public fun fromWire(value: String): BotContextLintSeverity? =
            values().firstOrNull { it.wireValue == value }
    }
}

/**
 * One diagnostic finding. [evidence] is human-readable only; [location] uses
 * the exact per-rule key set from `observability.md` §3 and writes nullable
 * values as JSON `null` rather than omitting them.
 */
public data class BotContextLintFinding(
    public val rule: BotContextLintRule,
    public val severity: BotContextLintSeverity,
    public val evidence: String,
    public val location: Map<String, JsonValue>,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "rule" to JsonString(rule.wireValue),
            "severity" to JsonString(severity.wireValue),
            "evidence" to JsonString(evidence),
            "location" to JsonObject(LinkedHashMap(location)),
        ),
    )

    public companion object {
        private val LOCATION_KEYS: Map<BotContextLintRule, List<Set<String>>> = mapOf(
            BotContextLintRule.SYSTEM_PROMPT_BLOAT to listOf(
                setOf("sessionId", "source", "chars"),
                setOf("sessionId", "source", "turn", "seq", "chars"),
            ),
            BotContextLintRule.TOOL_RESULT_BLOAT to listOf(
                setOf("sessionId", "turn", "step", "seq", "callId", "tool", "tokens"),
            ),
            BotContextLintRule.DUPLICATE_CONTEXT to listOf(
                setOf("sessionId", "turn", "seq", "occurrences"),
                setOf("sessionId", "turn", "seq", "chars"),
                setOf("sessionId", "turn", "seq", "earlierSeq", "chars"),
                setOf("sessionId", "turn", "seq", "firstSeq", "occurrences", "chars"),
            ),
            BotContextLintRule.ORPHAN_TOOL_CALL to listOf(
                setOf("sessionId", "turn", "step", "seq", "callId", "tool"),
            ),
            BotContextLintRule.ORPHAN_TOOL_RESULT to listOf(
                setOf("sessionId", "turn", "step", "seq", "callId"),
            ),
            BotContextLintRule.TOOL_DEF_BLOAT to listOf(
                setOf("sessionId", "source", "count", "tokens", "chars"),
            ),
        )

        /** Decodes and validates the closed finding shape, failing with a frozen code/path. */
        public fun fromJson(value: JsonValue): BotContextLintFinding {
            val members = (value as? JsonObject)?.members
                ?: throw BotContextLintException(
                    "context_lint.finding_type", "/finding", "finding must be an object",
                )
            val ruleText = (members["rule"] as? JsonString)?.value
                ?: throw BotContextLintException(
                    "context_lint.unknown_rule", "/finding/rule", "unknown context-lint rule",
                )
            val rule = BotContextLintRule.fromWire(ruleText)
                ?: throw BotContextLintException(
                    "context_lint.unknown_rule", "/finding/rule", "unknown context-lint rule $ruleText",
                )
            val severityText = (members["severity"] as? JsonString)?.value
            val severity = severityText?.let(BotContextLintSeverity::fromWire)
                ?: throw BotContextLintException(
                    "context_lint.unknown_severity", "/finding/severity", "unknown severity",
                )
            val evidence = (members["evidence"] as? JsonString)?.value
                ?: throw BotContextLintException(
                    "context_lint.finding_required", "/finding/evidence", "evidence is required",
                )
            if (evidence.isEmpty()) {
                throw BotContextLintException(
                    "context_lint.finding_required", "/finding/evidence", "evidence is required",
                )
            }
            val locationValue = members["location"]
            val location = (locationValue as? JsonObject)?.members
                ?: throw BotContextLintException(
                    "context_lint.location_type", "/finding/location", "location must be an object",
                )
            val variants = LOCATION_KEYS.getValue(rule)
            val keys = location.keys
            if (keys !in variants) {
                for (variant in variants) {
                    val extra = keys - variant
                    if (extra.isNotEmpty()) {
                        val key = extra.sorted().first()
                        throw BotContextLintException(
                            "context_lint.location_keys", "/finding/location/$key",
                            "location member $key is not frozen for ${rule.wireValue}",
                        )
                    }
                }
                val missing = variants.first() - keys
                val key = missing.sorted().first()
                throw BotContextLintException(
                    "context_lint.location_keys", "/finding/location/$key",
                    "location member $key is required for ${rule.wireValue}",
                )
            }
            return BotContextLintFinding(rule, severity, evidence, LinkedHashMap(location))
        }
    }
}

public class BotContextLintException(
    public val code: String,
    public val path: String,
    message: String,
) : Exception("$code $path: $message")

/**
 * The ten frozen threshold values (`observability.md` §4). Non-positive values
 * are accepted by the reader and coerced by the lint rules, matching Swift.
 */
public data class BotContextLintThresholds(
    public val personaCharsWarn: Long = 20_000,
    public val personaCharsError: Long = 32_000,
    public val toolResultTokensWarn: Long = 4_096,
    public val toolResultTokensError: Long = 12_000,
    public val toolDefTokensWarn: Long = 8_000,
    public val toolDefTokensError: Long = 16_000,
    public val toolCountWarn: Long = 40,
    public val maxRuntimeContextsPerTurn: Long = 2,
    public val repeatedTextChars: Long = 500,
    public val repeatedTextMaxFindings: Long = 20,
) {
    public fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "personaCharsWarn" to number(personaCharsWarn),
            "personaCharsError" to number(personaCharsError),
            "toolResultTokensWarn" to number(toolResultTokensWarn),
            "toolResultTokensError" to number(toolResultTokensError),
            "toolDefTokensWarn" to number(toolDefTokensWarn),
            "toolDefTokensError" to number(toolDefTokensError),
            "toolCountWarn" to number(toolCountWarn),
            "maxRuntimeContextsPerTurn" to number(maxRuntimeContextsPerTurn),
            "repeatedTextChars" to number(repeatedTextChars),
            "repeatedTextMaxFindings" to number(repeatedTextMaxFindings),
        ),
    )

    public companion object {
        public val DEFAULT: BotContextLintThresholds = BotContextLintThresholds()
        public val default: BotContextLintThresholds get() = DEFAULT

        /** Swift-style alias for [decode]. */
        public fun fromJson(value: JsonValue): BotContextLintThresholds = decode(value)

        /** Decodes partial thresholds; absent members take [DEFAULT]. */
        public fun decode(value: JsonValue): BotContextLintThresholds {
            val members = (value as? JsonObject)?.members
                ?: throw BotContextLintException(
                    "context_lint.thresholds.type", "/thresholds",
                    "thresholds must be an object",
                )
            fun read(name: String, fallback: Long): Long {
                if (!members.containsKey(name)) return fallback
                val number = members[name] as? JsonNumber
                    ?: throw BotContextLintException(
                        "context_lint.thresholds.type", "/thresholds/$name",
                        "threshold $name must be an integer",
                    )
                return number.asLongOrNull()
                    ?: throw BotContextLintException(
                        "context_lint.thresholds.type", "/thresholds/$name",
                        "threshold $name must be an integer",
                    )
            }
            return BotContextLintThresholds(
                personaCharsWarn = read("personaCharsWarn", DEFAULT.personaCharsWarn),
                personaCharsError = read("personaCharsError", DEFAULT.personaCharsError),
                toolResultTokensWarn = read("toolResultTokensWarn", DEFAULT.toolResultTokensWarn),
                toolResultTokensError = read("toolResultTokensError", DEFAULT.toolResultTokensError),
                toolDefTokensWarn = read("toolDefTokensWarn", DEFAULT.toolDefTokensWarn),
                toolDefTokensError = read("toolDefTokensError", DEFAULT.toolDefTokensError),
                toolCountWarn = read("toolCountWarn", DEFAULT.toolCountWarn),
                maxRuntimeContextsPerTurn = read(
                    "maxRuntimeContextsPerTurn", DEFAULT.maxRuntimeContextsPerTurn,
                ),
                repeatedTextChars = read("repeatedTextChars", DEFAULT.repeatedTextChars),
                repeatedTextMaxFindings = read(
                    "repeatedTextMaxFindings", DEFAULT.repeatedTextMaxFindings,
                ),
            )
        }

    }
}

/** One recent session event; [seq] and [time] are optional in the fixture. */
public data class BotContextLintEvent(
    public val type: String,
    public val seq: Long? = null,
    public val time: Double? = null,
    public val data: Map<String, JsonValue> = emptyMap(),
) {
    public companion object {
        public fun fromJson(value: JsonValue): BotContextLintEvent {
            val members = (value as? JsonObject)?.members
                ?: throw BotContextLintException(
                    "context_lint.event_type", "/event", "event must be an object",
                )
            val type = (members["type"] as? JsonString)?.value
                ?: throw BotContextLintException(
                    "context_lint.event_type", "/event/type", "event type is required",
                )
            val seq = (members["seq"] as? JsonNumber)?.asLongOrNull()
            val time = (members["time"] as? JsonNumber)?.raw?.toDoubleOrNull()
            val data = (members["data"] as? JsonObject)?.members ?: emptyMap()
            return BotContextLintEvent(type, seq, time, LinkedHashMap(data))
        }
    }
}

/**
 * Context lint (`spec/bot/v1/observability.md`). P0 has no production caller:
 * this is an explicit on-demand diagnostic and never writes an event.
 */
public object BotContextLint {
    public fun estimateTokens(text: String): Long {
        var ascii = 0L
        var nonAscii = 0L
        for (unit in text) {
            if (unit.code < 0x80) ascii += 1 else nonAscii += 1
        }
        return ceil(ascii / 3.5).toLong() + nonAscii
    }

    public fun lint(
        events: List<BotContextLintEvent> = emptyList(),
        promptMount: JsonValue? = null,
        tools: JsonValue? = null,
        thresholds: BotContextLintThresholds = BotContextLintThresholds.DEFAULT,
        sessionId: String? = null,
    ): List<BotContextLintFinding> {
        val findings = ArrayList<BotContextLintFinding>()
        val seenSignatures = HashSet<String>()
        val messages = BotContextLintSupport.collectMessages(events)
        val calls = BotContextLintSupport.collectCalls(events)
        val results = BotContextLintSupport.collectResults(events)
        lintSystemPrompt(events, promptMount, thresholds, sessionId, findings)
        lintToolResults(events, thresholds, sessionId, calls, findings)
        lintDuplicateContext(messages, thresholds, sessionId, seenSignatures, findings)
        lintOrphans(calls, results, sessionId, findings)
        lintToolDefinitions(events, tools, thresholds, sessionId, findings)
        val indexed = findings.withIndex().toList()
        return indexed.sortedWith { left, right ->
            val severityLeft = if (left.value.severity == BotContextLintSeverity.ERROR) 0 else 1
            val severityRight = if (right.value.severity == BotContextLintSeverity.ERROR) 0 else 1
            if (severityLeft != severityRight) return@sortedWith severityLeft.compareTo(severityRight)
            val ruleLeft = left.value.rule.ordinal
            val ruleRight = right.value.rule.ordinal
            if (ruleLeft != ruleRight) return@sortedWith ruleLeft.compareTo(ruleRight)
            val seqLeft = BotContextLintSupport.int(left.value.location["seq"]) ?: -1
            val seqRight = BotContextLintSupport.int(right.value.location["seq"]) ?: -1
            if (seqLeft != seqRight) return@sortedWith seqLeft.compareTo(seqRight)
            left.index.compareTo(right.index)
        }.map { it.value }
    }

    internal fun positive(value: Long, fallback: Long): Long = if (value > 0) value else fallback
}

internal data class BotContextLintMessage(
    val role: String,
    val text: String,
    val sourceKind: String,
    val turn: Long?,
    val step: Long?,
    val seq: Long?,
    val time: Double?,
    val eventType: String,
    val callId: String?,
)

internal data class BotContextLintCall(
    val callId: String,
    val name: String,
    val turn: Long?,
    val step: Long?,
    val seq: Long?,
)

internal data class BotContextLintResult(
    val callId: String?,
    val turn: Long?,
    val step: Long?,
    val seq: Long?,
)

internal object BotContextLintSupport {
    fun objectOf(value: JsonValue?): Map<String, JsonValue>? =
        (value as? JsonObject)?.members

    fun arrayOf(value: JsonValue?): List<JsonValue>? =
        (value as? JsonArray)?.values

    fun string(value: JsonValue?): String = when (value) {
        is JsonString -> value.value
        is JsonNumber -> {
            val integral = value.asLongOrNull()
            if (integral != null) {
                integral.toString()
            } else {
                val number = value.raw.toDoubleOrNull()
                if (number == null || !number.isFinite()) {
                    ""
                } else if (number == Math.rint(number)) {
                    BigDecimal(number).toBigInteger().toString()
                } else {
                    number.toString()
                }
            }
        }
        is JsonBool -> value.value.toString()
        else -> ""
    }

    fun int(value: JsonValue?): Long? = (value as? JsonNumber)?.asLongOrNull()

    fun double(value: JsonValue?): Double? =
        (value as? JsonNumber)?.raw?.toDoubleOrNull()?.takeIf { it.isFinite() }

    fun jsonString(value: JsonValue): String = BotJson.canonical(value)

    fun number(value: Long): JsonNumber = JsonNumber(value.toString())

    fun number(value: Int): JsonNumber = JsonNumber(value.toString())

    fun nullableString(value: String?): JsonValue = value?.let(::JsonString) ?: JsonNull

    fun nullableInt(value: Long?): JsonValue = value?.let(::number) ?: JsonNull

    fun jsLength(text: String): Long = text.length.toLong()

    fun message(event: BotContextLintEvent): Map<String, JsonValue> =
        objectOf(event.data["message"]) ?: emptyMap()

    fun turn(event: BotContextLintEvent): Long? = int(event.data["turn"])

    fun step(event: BotContextLintEvent): Long? = int(event.data["step"])

    fun blockText(value: JsonValue?): String {
        (value as? JsonString)?.let { return it.value }
        val block = objectOf(value) ?: return ""
        (block["text"] as? JsonString)?.let { return it.value }
        (block["content"] as? JsonString)?.let { return it.value }
        arrayOf(block["content"])?.let { content ->
            return content.map(::blockText).filter { it.isNotEmpty() }.joinToString("\n")
        }
        return ""
    }

    fun contentText(value: JsonValue?): String {
        (value as? JsonString)?.let { return it.value }
        val content = arrayOf(value) ?: return ""
        return content.map(::blockText).filter { it.isNotEmpty() }.joinToString("\n")
    }

    fun userText(event: BotContextLintEvent): String {
        val message = message(event)
        return contentText(event.data["content"] ?: message["content"])
    }

    fun systemText(event: BotContextLintEvent): String =
        contentText(message(event)["content"])

    fun assistantText(event: BotContextLintEvent): String =
        contentText(message(event)["content"])

    fun toolResultText(event: BotContextLintEvent): String {
        val fromMessage = contentText(message(event)["content"])
        if (fromMessage.isNotEmpty()) return fromMessage
        for (key in listOf("result", "output")) {
            (event.data[key] as? JsonString)?.let { return it.value }
        }
        return ""
    }

    fun toolResultCallId(event: BotContextLintEvent): String {
        val message = message(event)
        val candidates = listOf(
            message["toolCallId"],
            event.data["callId"],
            objectOf(message["source"])?.get("callId"),
        )
        for (value in candidates) {
            val text = string(value)
            if (text.isNotEmpty()) return text
        }
        return ""
    }

    fun toolResultIsError(event: BotContextLintEvent): Boolean =
        (message(event)["isError"] as? JsonBool)?.value == true ||
            (event.data["isError"] as? JsonBool)?.value == true

    fun collectMessages(events: List<BotContextLintEvent>): List<BotContextLintMessage> {
        val messages = ArrayList<BotContextLintMessage>()
        var currentTurn: Long? = null
        for (event in events) {
            if (event.type == "turn/start") {
                turn(event)?.let { currentTurn = it }
                continue
            }
            val turn = turn(event) ?: currentTurn
            when (event.type) {
                "user/message" -> {
                    val kind = objectOf(event.data["source"])?.get("kind")
                        ?: objectOf(message(event)["source"])?.get("kind")
                    messages += BotContextLintMessage(
                        "user", userText(event), string(kind), turn, step(event), event.seq,
                        event.time, event.type, null,
                    )
                }
                "assistant/message" -> messages += BotContextLintMessage(
                    "assistant", assistantText(event), "assistant", turn, step(event), event.seq,
                    event.time, event.type, null,
                )
                "system/message" -> messages += BotContextLintMessage(
                    "system", systemText(event), "system", turn, step(event), event.seq,
                    event.time, event.type, null,
                )
                "tool/result" -> messages += BotContextLintMessage(
                    "tool", toolResultText(event), "tool", turn, step(event), event.seq,
                    event.time, event.type, toolResultCallId(event),
                )
            }
        }
        return messages
    }

    fun collectCalls(events: List<BotContextLintEvent>): Map<String, BotContextLintCall> {
        val calls = LinkedHashMap<String, BotContextLintCall>()
        var currentTurn: Long? = null
        for (event in events) {
            if (event.type == "turn/start") {
                turn(event)?.let { currentTurn = it }
                continue
            }
            if (event.type == "tool/call") {
                val id = string(event.data["callId"])
                if (id.isNotEmpty() && id !in calls) {
                    calls[id] = BotContextLintCall(
                        id, string(event.data["name"]), turn(event) ?: currentTurn,
                        step(event), event.seq,
                    )
                }
            }
            if (event.type == "assistant/message") {
                for (block in arrayOf(message(event)["content"]) ?: emptyList()) {
                    val blockObject = objectOf(block) ?: continue
                    if (string(blockObject["type"]) != "tool-call") continue
                    val id = string(blockObject["id"]).ifEmpty {
                        string(blockObject["toolCallId"])
                    }
                    if (id.isNotEmpty() && id !in calls) {
                        calls[id] = BotContextLintCall(
                            id, string(blockObject["name"]), turn(event) ?: currentTurn,
                            step(event), event.seq,
                        )
                    }
                }
            }
        }
        return calls
    }

    fun collectResults(events: List<BotContextLintEvent>): Map<String, BotContextLintResult> {
        val results = LinkedHashMap<String, BotContextLintResult>()
        var currentTurn: Long? = null
        for (event in events) {
            if (event.type == "turn/start") {
                turn(event)?.let { currentTurn = it }
                continue
            }
            if (event.type != "tool/result") continue
            val callId = toolResultCallId(event)
            val result = BotContextLintResult(
                callId.ifEmpty { null }, turn(event) ?: currentTurn, step(event), event.seq,
            )
            val key = if (callId.isNotEmpty()) callId else "missing:${event.seq ?: "null"}"
            if (key !in results) results[key] = result
        }
        return results
    }

    fun normalizeText(text: String): String {
        val normalized = Normalizer.normalize(text, Normalizer.Form.NFKC)
        val out = StringBuilder(normalized.length)
        var pendingSpace = false
        var index = 0
        while (index < normalized.length) {
            val codePoint = normalized.codePointAt(index)
            index += Character.charCount(codePoint)
            if (Character.isWhitespace(codePoint) || Character.isSpaceChar(codePoint)) {
                pendingSpace = out.isNotEmpty()
            } else {
                if (pendingSpace) out.append(' ')
                pendingSpace = false
                out.appendCodePoint(codePoint)
            }
        }
        return out.toString()
    }

    private val spillPatterns: List<Regex> = listOf(
        Regex(Regex.escape("Full formatted result stored at:"), RegexOption.IGNORE_CASE),
        Regex("Omitted [0-9][0-9,]* bytes\\.", RegexOption.IGNORE_CASE),
        Regex(Regex.escape("More bytes were omitted."), RegexOption.IGNORE_CASE),
        Regex("\\[spilled?\\]", RegexOption.IGNORE_CASE),
        Regex("\\bspill(?:ed)?\\s+(?:to|file|at)\\b", RegexOption.IGNORE_CASE),
    )

    fun hasSpillNotice(text: String): Boolean = spillPatterns.any { it.containsMatchIn(text) }

    fun promptMountChars(promptMount: JsonValue?): Long? {
        val mount = objectOf(promptMount) ?: return null
        double(mount["chars"])?.let { chars ->
            if (chars > 0) return chars.toLong()
        }
        val mounted = arrayOf(mount["mounted"]) ?: return null
        var total = 0L
        for (entry in mounted) {
            val entryObject = objectOf(entry) ?: emptyMap()
            total += int(entryObject["chars"]) ?: jsLength(string(entryObject["text"]))
        }
        return total.takeIf { it > 0 }
    }

    fun tools(input: JsonValue?, events: List<BotContextLintEvent>): List<JsonValue>? {
        arrayOf(input)?.let { return it }
        val inputObject = objectOf(input)
        if (inputObject != null) {
            arrayOf(inputObject["tools"])?.let { return it }
        }
        var latest: List<JsonValue>? = null
        for (event in events) {
            if (event.type != "request/header") continue
            val header = objectOf(event.data["header"]) ?: continue
            arrayOf(header["tools"])?.let { latest = it }
        }
        return latest
    }

    fun explicitTools(input: JsonValue?): Boolean =
        arrayOf(input) != null || arrayOf(objectOf(input)?.get("tools")) != null
}
