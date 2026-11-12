// SPDX-License-Identifier: MIT
package com.phonedsh.bot.watchdog

import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue

// The six rules behind BotContextLint.lint. The functions mirror
// Sources/PhoneDSHBot/Watchdog/BotContextLintRules.swift and only append to
// the caller's list; they never write an event or change the session.

internal fun lintSystemPrompt(
    events: List<BotContextLintEvent>,
    promptMount: JsonValue?,
    thresholds: BotContextLintThresholds,
    sessionId: String?,
    findings: MutableList<BotContextLintFinding>,
) {
    val warn = BotContextLint.positive(
        thresholds.personaCharsWarn,
        BotContextLintThresholds.DEFAULT.personaCharsWarn,
    )
    val error = maxOf(
        warn,
        BotContextLint.positive(thresholds.personaCharsError, warn),
    )
    val mountChars = BotContextLintSupport.promptMountChars(promptMount)
    if (mountChars != null) {
        if (mountChars < warn) return
        findings += BotContextLintFinding(
            BotContextLintRule.SYSTEM_PROMPT_BLOAT,
            if (mountChars >= error) BotContextLintSeverity.ERROR else BotContextLintSeverity.WARN,
            "persona is $mountChars chars (warn $warn, error $error) from prompt-mount.json",
            linkedMapOf(
                "sessionId" to BotContextLintSupport.nullableString(sessionId),
                "source" to JsonString("prompt-mount"),
                "chars" to BotContextLintSupport.number(mountChars),
            ),
        )
        return
    }
    var systemChars = 0L
    var firstSeq: Long? = null
    var firstTurn: Long? = null
    for (event in events) {
        if (event.type != "system/message") continue
        val text = BotContextLintSupport.systemText(event)
        if (text.isEmpty()) continue
        systemChars += BotContextLintSupport.jsLength(text)
        if (firstSeq == null) {
            firstSeq = event.seq
            firstTurn = BotContextLintSupport.turn(event)
        }
    }
    if (systemChars < warn) return
    findings += BotContextLintFinding(
        BotContextLintRule.SYSTEM_PROMPT_BLOAT,
        if (systemChars >= error) BotContextLintSeverity.ERROR else BotContextLintSeverity.WARN,
        "rendered system prompt is $systemChars chars (warn $warn, error $error) from system/message",
        linkedMapOf(
            "sessionId" to BotContextLintSupport.nullableString(sessionId),
            "source" to JsonString("system/message"),
            "turn" to BotContextLintSupport.nullableInt(firstTurn),
            "seq" to BotContextLintSupport.nullableInt(firstSeq),
            "chars" to BotContextLintSupport.number(systemChars),
        ),
    )
}

internal fun lintToolResults(
    events: List<BotContextLintEvent>,
    thresholds: BotContextLintThresholds,
    sessionId: String?,
    callsById: Map<String, BotContextLintCall>,
    findings: MutableList<BotContextLintFinding>,
) {
    val defaults = BotContextLintThresholds.DEFAULT
    val warn = BotContextLint.positive(thresholds.toolResultTokensWarn, defaults.toolResultTokensWarn)
    val error = maxOf(
        warn,
        BotContextLint.positive(thresholds.toolResultTokensError, warn),
    )
    var currentTurn: Long? = null
    for (event in events) {
        if (event.type == "turn/start") {
            BotContextLintSupport.turn(event)?.let { currentTurn = it }
            continue
        }
        if (event.type != "tool/result") continue
        val text = BotContextLintSupport.toolResultText(event)
        if (text.isEmpty()) continue
        val tokens = BotContextLint.estimateTokens(text)
        if (tokens < warn || BotContextLintSupport.hasSpillNotice(text)) continue
        val callId = BotContextLintSupport.toolResultCallId(event)
        val call = callsById[callId]
        val resultKind = if (BotContextLintSupport.toolResultIsError(event)) {
            "error result"
        } else {
            "ok result"
        }
        findings += BotContextLintFinding(
            BotContextLintRule.TOOL_RESULT_BLOAT,
            if (tokens >= error) BotContextLintSeverity.ERROR else BotContextLintSeverity.WARN,
            "$tokens estimated tokens, no spill notice (warn $warn, error $error, $resultKind)",
            linkedMapOf(
                "sessionId" to BotContextLintSupport.nullableString(sessionId),
                "turn" to BotContextLintSupport.nullableInt(
                    BotContextLintSupport.turn(event) ?: currentTurn,
                ),
                "step" to BotContextLintSupport.nullableInt(BotContextLintSupport.step(event)),
                "seq" to BotContextLintSupport.nullableInt(event.seq),
                "callId" to BotContextLintSupport.nullableString(callId.ifEmpty { null }),
                "tool" to BotContextLintSupport.nullableString(call?.name),
                "tokens" to BotContextLintSupport.number(tokens),
            ),
        )
    }
}

internal fun lintDuplicateContext(
    messages: List<BotContextLintMessage>,
    thresholds: BotContextLintThresholds,
    sessionId: String?,
    seenSignatures: MutableSet<String>,
    findings: MutableList<BotContextLintFinding>,
) {
    val defaults = BotContextLintThresholds.DEFAULT
    val minChars = maxOf(
        1,
        BotContextLint.positive(thresholds.repeatedTextChars, defaults.repeatedTextChars),
    )
    val maxRuntime = maxOf(
        1,
        BotContextLint.positive(
            thresholds.maxRuntimeContextsPerTurn,
            defaults.maxRuntimeContextsPerTurn,
        ),
    )
    val runtime = messages.filter { it.sourceKind == "runtime-context" }
    val groups = LinkedHashMap<String, Pair<Long?, MutableList<BotContextLintMessage>>>()
    for (message in runtime) {
        val key = message.turn?.toString() ?: "unknown"
        val group = groups[key]
        if (group != null) {
            group.second += message
        } else {
            groups[key] = message.turn to mutableListOf(message)
        }
    }
    for ((turn, groupMessages) in groups.values) {
        if (groupMessages.size.toLong() > maxRuntime) {
            findings += BotContextLintFinding(
                BotContextLintRule.DUPLICATE_CONTEXT,
                BotContextLintSeverity.WARN,
                "${groupMessages.size} runtime-context snapshots in one turn " +
                    "(max $maxRuntime); older snapshots accumulate",
                linkedMapOf(
                    "sessionId" to BotContextLintSupport.nullableString(sessionId),
                    "turn" to BotContextLintSupport.nullableInt(turn),
                    "seq" to BotContextLintSupport.nullableInt(groupMessages.lastOrNull()?.seq),
                    "occurrences" to BotContextLintSupport.number(groupMessages.size),
                ),
            )
        }
        val seen = LinkedHashMap<String, Long>()
        for (message in groupMessages) {
            val text = BotContextLintSupport.normalizeText(message.text)
            if (text.isEmpty()) continue
            val firstSeq = seen[text]
            if (firstSeq != null) {
                val signature = "duplicate-context\u0000runtime:$text"
                if (seenSignatures.add(signature)) {
                    findings += BotContextLintFinding(
                        BotContextLintRule.DUPLICATE_CONTEXT,
                        BotContextLintSeverity.WARN,
                        "runtime-context snapshot repeated " +
                            "(${BotContextLintSupport.jsLength(text)} chars, first seq $firstSeq, " +
                            "again seq ${message.seq ?: "null"})",
                        linkedMapOf(
                            "sessionId" to BotContextLintSupport.nullableString(sessionId),
                            "turn" to BotContextLintSupport.nullableInt(turn),
                            "seq" to BotContextLintSupport.nullableInt(message.seq),
                            "chars" to BotContextLintSupport.number(
                                BotContextLintSupport.jsLength(text),
                            ),
                        ),
                    )
                }
            } else {
                seen[text] = message.seq ?: -1
            }
        }
        for (earlierIndex in groupMessages.indices) {
            val earlier = BotContextLintSupport.normalizeText(groupMessages[earlierIndex].text)
            if (earlier.isEmpty()) continue
            for (laterIndex in earlierIndex + 1 until groupMessages.size) {
                val later = BotContextLintSupport.normalizeText(groupMessages[laterIndex].text)
                if (BotContextLintSupport.jsLength(later) - BotContextLintSupport.jsLength(earlier) < 200) {
                    continue
                }
                if (!later.contains(earlier)) continue
                val signature = "duplicate-context\u0000accumulated:$earlier:" +
                    BotContextLintSupport.jsLength(later)
                if (!seenSignatures.add(signature)) continue
                findings += BotContextLintFinding(
                    BotContextLintRule.DUPLICATE_CONTEXT,
                    BotContextLintSeverity.WARN,
                    "runtime-context snapshot seq ${groupMessages[laterIndex].seq ?: "null"} " +
                        "embeds the earlier snapshot seq " +
                        "${groupMessages[earlierIndex].seq ?: "null"} " +
                        "(${BotContextLintSupport.jsLength(earlier)}→" +
                        "${BotContextLintSupport.jsLength(later)} chars)",
                    linkedMapOf(
                        "sessionId" to BotContextLintSupport.nullableString(sessionId),
                        "turn" to BotContextLintSupport.nullableInt(turn),
                        "seq" to BotContextLintSupport.nullableInt(groupMessages[laterIndex].seq),
                        "earlierSeq" to BotContextLintSupport.nullableInt(
                            groupMessages[earlierIndex].seq,
                        ),
                        "chars" to BotContextLintSupport.number(
                            BotContextLintSupport.jsLength(later),
                        ),
                    ),
                )
                break
            }
        }
    }

    val byText = LinkedHashMap<String, MutableList<BotContextLintMessage>>()
    for (message in messages) {
        if (message.sourceKind == "runtime-context") continue
        val text = BotContextLintSupport.normalizeText(message.text)
        if (BotContextLintSupport.jsLength(text) < minChars) continue
        byText.getOrPut(text) { ArrayList() } += message
    }
    var reported = 0L
    val limit = maxOf(
        1,
        BotContextLint.positive(thresholds.repeatedTextMaxFindings, defaults.repeatedTextMaxFindings),
    )
    for ((text, occurrences) in byText) {
        if (occurrences.size < 2 || reported >= limit) continue
        val signature = "duplicate-context\u0000repeat:$text"
        if (!seenSignatures.add(signature)) continue
        reported += 1
        val sequences = occurrences.joinToString(", ") { it.seq?.toString() ?: "null" }
        val second = occurrences[1]
        findings += BotContextLintFinding(
            BotContextLintRule.DUPLICATE_CONTEXT,
            BotContextLintSeverity.WARN,
            "the same ${BotContextLintSupport.jsLength(text)}-char block appears in " +
                "${occurrences.size} messages (seq $sequences)",
            linkedMapOf(
                "sessionId" to BotContextLintSupport.nullableString(sessionId),
                "turn" to BotContextLintSupport.nullableInt(second.turn),
                "seq" to BotContextLintSupport.nullableInt(second.seq),
                "firstSeq" to BotContextLintSupport.nullableInt(occurrences[0].seq),
                "occurrences" to BotContextLintSupport.number(occurrences.size),
                "chars" to BotContextLintSupport.number(BotContextLintSupport.jsLength(text)),
            ),
        )
    }
}

internal fun lintOrphans(
    callsById: Map<String, BotContextLintCall>,
    resultsById: Map<String, BotContextLintResult>,
    sessionId: String?,
    findings: MutableList<BotContextLintFinding>,
) {
    val results = resultsById.entries
        .sortedWith(compareBy({ it.value.seq ?: -1 }, { it.key }))
        .map { it.value }
    for (result in results) {
        val callId = result.callId
        if (callId != null && callId in callsById) continue
        findings += BotContextLintFinding(
            BotContextLintRule.ORPHAN_TOOL_RESULT,
            BotContextLintSeverity.ERROR,
            if (callId != null) {
                "tool result callId $callId has no matching tool/call"
            } else {
                "tool result has no callId"
            },
            linkedMapOf(
                "sessionId" to BotContextLintSupport.nullableString(sessionId),
                "turn" to BotContextLintSupport.nullableInt(result.turn),
                "step" to BotContextLintSupport.nullableInt(result.step),
                "seq" to BotContextLintSupport.nullableInt(result.seq),
                "callId" to BotContextLintSupport.nullableString(callId),
            ),
        )
    }
    val calls = callsById.entries
        .sortedWith(compareBy({ it.value.seq ?: -1 }, { it.key }))
        .map { it.value }
    for (call in calls) {
        if (call.callId in resultsById) continue
        if (results.any { it.callId == call.callId }) continue
        findings += BotContextLintFinding(
            BotContextLintRule.ORPHAN_TOOL_CALL,
            BotContextLintSeverity.ERROR,
            "tool/call ${call.callId}${if (call.name.isEmpty()) "" else " (${call.name})"} " +
                "has no matching tool/result",
            linkedMapOf(
                "sessionId" to BotContextLintSupport.nullableString(sessionId),
                "turn" to BotContextLintSupport.nullableInt(call.turn),
                "step" to BotContextLintSupport.nullableInt(call.step),
                "seq" to BotContextLintSupport.nullableInt(call.seq),
                "callId" to JsonString(call.callId),
                "tool" to BotContextLintSupport.nullableString(call.name.ifEmpty { null }),
            ),
        )
    }
}

internal fun lintToolDefinitions(
    events: List<BotContextLintEvent>,
    tools: JsonValue?,
    thresholds: BotContextLintThresholds,
    sessionId: String?,
    findings: MutableList<BotContextLintFinding>,
) {
    val list = BotContextLintSupport.tools(tools, events) ?: return
    if (list.isEmpty()) return
    val defaults = BotContextLintThresholds.DEFAULT
    val warn = BotContextLint.positive(thresholds.toolDefTokensWarn, defaults.toolDefTokensWarn)
    val error = maxOf(
        warn,
        BotContextLint.positive(thresholds.toolDefTokensError, warn),
    )
    val countWarn = maxOf(
        1,
        BotContextLint.positive(thresholds.toolCountWarn, defaults.toolCountWarn),
    )
    var tokens = 0L
    var chars = 0L
    for (tool in list) {
        val json = BotContextLintSupport.jsonString(tool)
        chars += BotContextLintSupport.jsLength(json)
        tokens += BotContextLint.estimateTokens(json)
    }
    if (list.size.toLong() < countWarn && tokens < warn) return
    findings += BotContextLintFinding(
        BotContextLintRule.TOOL_DEF_BLOAT,
        if (tokens >= error) BotContextLintSeverity.ERROR else BotContextLintSeverity.WARN,
        "${list.size} tool definitions, ~$tokens tokens / $chars chars " +
            "(token warn $warn, error $error; count warn $countWarn)",
        linkedMapOf(
            "sessionId" to BotContextLintSupport.nullableString(sessionId),
            "source" to JsonString(
                if (BotContextLintSupport.explicitTools(tools)) "tools/list" else "request/header",
            ),
            "count" to BotContextLintSupport.number(list.size),
            "tokens" to BotContextLintSupport.number(tokens),
            "chars" to BotContextLintSupport.number(chars),
        ),
    )
}
