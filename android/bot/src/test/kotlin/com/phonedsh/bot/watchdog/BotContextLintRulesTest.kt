// SPDX-License-Identifier: MIT
package com.phonedsh.bot.watchdog

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Rule semantics that the shared cases do not exercise end to end. */
class BotContextLintRulesTest {
    @Test
    fun promptMountSuppressesTheSystemMessageFallback() {
        val events = listOf(
            event("system/message", 1, mapOf("turn" to JsonNumber("1"), "message" to messages("x".repeat(20)))),
        )
        val thresholds = BotContextLintThresholds(personaCharsWarn = 10, personaCharsError = 15)
        val fallback = BotContextLint.lint(events = events, thresholds = thresholds, sessionId = "s")
        assertEquals(1, fallback.size)
        assertEquals(BotContextLintRule.SYSTEM_PROMPT_BLOAT, fallback.single().rule)
        assertEquals(BotContextLintSeverity.ERROR, fallback.single().severity)
        assertEquals("system/message", (fallback.single().location["source"] as JsonString).value)
        assertEquals(1L, (fallback.single().location["turn"] as JsonNumber).asLongOrNull())
        assertEquals(20L, (fallback.single().location["chars"] as JsonNumber).asLongOrNull())

        val mounted = BotContextLint.lint(
            events = events,
            promptMount = objectOf("chars" to JsonNumber("10")),
            thresholds = thresholds,
            sessionId = "s",
        )
        assertEquals(1, mounted.size)
        assertEquals("prompt-mount", (mounted.single().location["source"] as JsonString).value)
        assertEquals(10L, (mounted.single().location["chars"] as JsonNumber).asLongOrNull())
    }

    @Test
    fun spillNoticesSuppressOnlyTheBloatFinding() {
        val thresholds = BotContextLintThresholds(toolResultTokensWarn = 1, toolResultTokensError = 2)
        for (notice in listOf(
            " [spilled]",
            " Omitted 12,345 bytes.",
            " More bytes were omitted.",
            " Full formatted result stored at: /tmp/x",
            " spill to file",
        )) {
            val events = listOf(
                event(
                    "tool/call", 1,
                    mapOf("turn" to JsonNumber("1"), "callId" to JsonString("c1"), "name" to JsonString("read")),
                ),
                event(
                    "tool/result", 2,
                    mapOf(
                        "turn" to JsonNumber("1"),
                        "callId" to JsonString("c1"),
                        "message" to messages("x".repeat(50) + notice),
                    ),
                ),
            )
            assertEquals(notice, emptyList<BotContextLintFinding>(), BotContextLint.lint(events, thresholds = thresholds))
        }
        val visible = listOf(
            event(
                "tool/call", 1,
                mapOf("turn" to JsonNumber("1"), "callId" to JsonString("c1"), "name" to JsonString("read")),
            ),
            event(
                "tool/result", 2,
                mapOf(
                    "turn" to JsonNumber("1"),
                    "callId" to JsonString("c1"),
                    "message" to messages("x".repeat(50)),
                ),
            ),
        )
        assertEquals(1, BotContextLint.lint(visible, thresholds = thresholds).size)
    }

    @Test
    fun everyDuplicateContextLocationVariantIsReachable() {
        val duplicateRuntime = BotContextLint.lint(
            events = listOf(
                runtime(1, 1, "same snapshot"),
                runtime(2, 1, "same   snapshot"),
            ),
            sessionId = "s",
        ).single()
        assertEquals(setOf("sessionId", "turn", "seq", "chars"), duplicateRuntime.location.keys)

        val tooManyRuntime = BotContextLint.lint(
            events = listOf(
                runtime(1, 1, "a"),
                runtime(2, 1, "b"),
                runtime(3, 1, "c"),
            ),
            sessionId = "s",
        ).single()
        assertEquals(setOf("sessionId", "turn", "seq", "occurrences"), tooManyRuntime.location.keys)
        assertEquals(3L, (tooManyRuntime.location["occurrences"] as JsonNumber).asLongOrNull())

        val earlier = "a".repeat(100)
        val accumulated = BotContextLint.lint(
            events = listOf(runtime(1, 1, earlier), runtime(2, 1, earlier + "b".repeat(200))),
            sessionId = "s",
        ).single()
        assertEquals(
            setOf("sessionId", "turn", "seq", "earlierSeq", "chars"),
            accumulated.location.keys,
        )
        assertEquals(300L, (accumulated.location["chars"] as JsonNumber).asLongOrNull())

        val repeated = BotContextLint.lint(
            events = listOf(
                event("assistant/message", 1, mapOf("turn" to JsonNumber("1"), "message" to messages("same text!"))),
                event("assistant/message", 2, mapOf("turn" to JsonNumber("1"), "message" to messages("same text!"))),
            ),
            thresholds = BotContextLintThresholds(repeatedTextChars = 10),
            sessionId = "s",
        ).single()
        assertEquals(
            setOf("sessionId", "turn", "seq", "firstSeq", "occurrences", "chars"),
            repeated.location.keys,
        )
    }

    @Test
    fun assistantToolCallBlocksPairWithResultsAndExposeOrphans() {
        val paired = listOf(
            event(
                "assistant/message", 1,
                mapOf(
                    "turn" to JsonNumber("1"),
                    "message" to objectOf(
                        "content" to JsonArray(
                            listOf(
                                objectOf(
                                    "type" to JsonString("tool-call"),
                                    "id" to JsonString("call-paired"),
                                    "name" to JsonString("read"),
                                ),
                            ),
                        ),
                    ),
                ),
            ),
            event(
                "tool/result", 2,
                mapOf(
                    "turn" to JsonNumber("1"),
                    "callId" to JsonString("call-paired"),
                    "result" to JsonString("ok"),
                ),
            ),
        )
        assertEquals(emptyList<BotContextLintFinding>(), BotContextLint.lint(paired, sessionId = "s"))

        val orphanCall = BotContextLint.lint(
            listOf(
                event(
                    "assistant/message", 1,
                    mapOf(
                        "turn" to JsonNumber("1"),
                        "message" to objectOf(
                            "content" to JsonArray(
                                listOf(
                                    objectOf(
                                        "type" to JsonString("tool-call"),
                                        "toolCallId" to JsonString("call-orphan"),
                                        "name" to JsonString("read"),
                                    ),
                                ),
                            ),
                        ),
                    ),
                ),
            ),
            sessionId = "s",
        ).single()
        assertEquals(BotContextLintRule.ORPHAN_TOOL_CALL, orphanCall.rule)
        assertEquals("call-orphan", (orphanCall.location["callId"] as JsonString).value)

        val orphanResult = BotContextLint.lint(
            listOf(
                event(
                    "tool/result", 1,
                    mapOf("turn" to JsonNumber("1"), "result" to JsonString("x")),
                ),
            ),
            sessionId = "s",
        ).single()
        assertEquals(BotContextLintRule.ORPHAN_TOOL_RESULT, orphanResult.rule)
        assertTrue(orphanResult.location["callId"] is com.phonedsh.agentcore.JsonNull)
    }

    @Test
    fun latestRequestHeaderToolsAndExplicitToolsUseDifferentSources() {
        val first = objectOf("name" to JsonString("first"))
        val latest = objectOf("name" to JsonString("latest"))
        val events = listOf(
            event("request/header", 1, mapOf("header" to objectOf("tools" to JsonArray(listOf(first))))),
            event("request/header", 2, mapOf("header" to objectOf("tools" to JsonArray(listOf(latest))))),
        )
        val thresholds = BotContextLintThresholds(
            toolDefTokensWarn = 1,
            toolDefTokensError = 1000,
        )
        val fromHeader = BotContextLint.lint(events = events, thresholds = thresholds, sessionId = "s")
            .single()
        assertEquals("request/header", (fromHeader.location["source"] as JsonString).value)
        assertEquals(1L, (fromHeader.location["count"] as JsonNumber).asLongOrNull())
        assertEquals(
            com.phonedsh.bot.BotJson.canonical(latest).length.toLong(),
            (fromHeader.location["chars"] as JsonNumber).asLongOrNull(),
        )

        val explicit = BotContextLint.lint(
            events = events,
            tools = JsonArray(listOf(first, latest)),
            thresholds = thresholds,
            sessionId = "s",
        ).single()
        assertEquals("tools/list", (explicit.location["source"] as JsonString).value)
        assertEquals(2L, (explicit.location["count"] as JsonNumber).asLongOrNull())
    }

    @Test
    fun thresholdCoercionUsesWarnThenErrorThenMax() {
        val events = listOf(
            event("system/message", 1, mapOf("message" to messages("x".repeat(20_000)))),
        )
        val bothZero = BotContextLint.lint(
            events = events,
            thresholds = BotContextLintThresholds(personaCharsWarn = 0, personaCharsError = 0),
        ).single()
        assertEquals(BotContextLintSeverity.ERROR, bothZero.severity)
        assertTrue(bothZero.evidence.contains("warn 20000, error 20000"))

        val errorBelowWarn = BotContextLint.lint(
            events = listOf(event("system/message", 1, mapOf("message" to messages("x".repeat(1_000))))),
            thresholds = BotContextLintThresholds(personaCharsWarn = 1_000, personaCharsError = 10),
        ).single()
        assertEquals(BotContextLintSeverity.ERROR, errorBelowWarn.severity)
        assertTrue(errorBelowWarn.evidence.contains("warn 1000, error 1000"))
    }

    @Test
    fun repeatedTextFindingsRespectTheFrozenLimit() {
        val texts = listOf("alpha-text!", "beta-text!!", "gamma-text?")
        val events = ArrayList<BotContextLintEvent>()
        var seq = 1L
        for (text in texts) {
            repeat(2) {
                events += event(
                    "assistant/message", seq++,
                    mapOf("turn" to JsonNumber("1"), "message" to messages(text)),
                )
            }
        }
        val findings = BotContextLint.lint(
            events,
            thresholds = BotContextLintThresholds(
                repeatedTextChars = 5,
                repeatedTextMaxFindings = 2,
            ),
            sessionId = "s",
        )
        assertEquals(2, findings.size)
        assertTrue(findings.all { it.rule == BotContextLintRule.DUPLICATE_CONTEXT })
    }

    @Test
    fun tokenEstimateCountsAsciiAndEveryNonAsciiUtf16Unit() {
        assertEquals(1L, BotContextLint.estimateTokens("abc"))
        assertEquals(2L, BotContextLint.estimateTokens("aaaaaaa"))
        assertEquals(1L, BotContextLint.estimateTokens("é"))
        assertEquals(2L, BotContextLint.estimateTokens("aé"))
        assertEquals(2L, BotContextLint.estimateTokens("😀"))
    }

    private fun runtime(seq: Long, turn: Long, text: String): BotContextLintEvent =
        event(
            "user/message", seq,
            mapOf(
                "turn" to JsonNumber(turn.toString()),
                "source" to objectOf("kind" to JsonString("runtime-context")),
                "content" to JsonString(text),
            ),
        )

    private fun event(
        type: String,
        seq: Long,
        data: Map<String, JsonValue>,
    ): BotContextLintEvent = BotContextLintEvent(type, seq, null, data)

    private fun messages(content: String): JsonObject =
        objectOf("content" to JsonString(content))

    private fun objectOf(vararg members: Pair<String, JsonValue>): JsonObject =
        JsonObject(linkedMapOf(*members))
}
