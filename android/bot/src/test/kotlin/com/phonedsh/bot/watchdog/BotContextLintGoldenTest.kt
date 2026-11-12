// SPDX-License-Identifier: MIT
package com.phonedsh.bot.watchdog

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Drives the C9 lint cases, findings and threshold vectors through the real code. */
class BotContextLintGoldenTest {
    @Test
    fun defaultAndInvalidThresholdsComeFromTheSharedFixture() {
        val vector = fixture("context-lint.phone")
        val thresholds = vector.requireObject("thresholds")
        val expected = thresholds.getValue("default").asUnitsJson()
        assertEquals(BotContextLintThresholds.DEFAULT, BotContextLintThresholds.decode(expected))
        assertCanonicalEquals(
            expected,
            BotContextLintThresholds.DEFAULT.toJson(),
            "default thresholds",
        )

        val invalid = thresholds.getValue("invalid").arrayOrNull()!!.map { it.asUnitsJson() }
        assertTrue(invalid.isNotEmpty())
        for (case in invalid) {
            val name = case.members.getValue("name").requiredString()
            val input = case.members.getValue("input").asUnitsJson()
            val error = case.members.getValue("error").asUnitsJson()
            try {
                BotContextLintThresholds.decode(input)
                fail("$name: invalid thresholds unexpectedly decoded")
            } catch (failure: BotContextLintException) {
                assertEquals(name, error.members.getValue("code").requiredString(), failure.code)
                assertEquals(name, error.members.getValue("path").requiredString(), failure.path)
            }
        }
    }

    @Test
    fun validFindingsDecodeAndFrozenInvalidShapesFailClosed() {
        val vector = fixture("context-lint.phone")
        val valid = vector.requireArray("valid")
        assertTrue(valid.isNotEmpty())
        for (value in valid) {
            val finding = BotContextLintFinding.fromJson(value)
            assertCanonicalEquals(value, finding.toJson(), "valid finding")
        }

        val invalid = vector.requireArray("invalid").map { it.asUnitsJson() }
        assertTrue(invalid.isNotEmpty())
        for (case in invalid) {
            val name = case.members.getValue("name").requiredString()
            val finding = case.members.getValue("finding")
            val error = case.members.getValue("error").asUnitsJson()
            try {
                BotContextLintFinding.fromJson(finding)
                fail("$name: invalid finding unexpectedly decoded")
            } catch (failure: BotContextLintException) {
                assertEquals(name, error.members.getValue("code").requiredString(), failure.code)
                assertEquals(name, error.members.getValue("path").requiredString(), failure.path)
            }
        }

        val upstream = fixture("context-lint").requireArray("valid")
        for (value in upstream) BotContextLintFinding.fromJson(value)

        val mixedVariants = JsonObject(
            linkedMapOf(
                "rule" to com.phonedsh.agentcore.JsonString("system-prompt-bloat"),
                "severity" to com.phonedsh.agentcore.JsonString("warn"),
                "evidence" to com.phonedsh.agentcore.JsonString("x"),
                "location" to JsonObject(
                    linkedMapOf(
                        "sessionId" to com.phonedsh.agentcore.JsonNull,
                        "source" to com.phonedsh.agentcore.JsonString("prompt-mount"),
                        "chars" to com.phonedsh.agentcore.JsonNumber("1"),
                        "turn" to com.phonedsh.agentcore.JsonNumber("1"),
                    ),
                ),
            ),
        )
        try {
            BotContextLintFinding.fromJson(mixedVariants)
            fail("mixed location variants unexpectedly decoded")
        } catch (failure: BotContextLintException) {
            assertEquals("context_lint.location_keys", failure.code)
            assertEquals("/finding/location/turn", failure.path)
        }
    }

    @Test
    fun allSixRulesAndBoundariesDriveRealContextLint() {
        val vector = fixture("context-lint.phone")
        val cases = vector.requireArray("cases").map { it.asUnitsJson() }
        assertTrue(cases.isNotEmpty())
        val coveredRules = LinkedHashSet<BotContextLintRule>()
        for (case in cases) {
            val name = case.members.getValue("name").requiredString()
            val events = case.optionalArray("events").map { BotContextLintEvent.fromJson(it) }
            val thresholds = case.members["thresholds"]?.let {
                BotContextLintThresholds.decode(it)
            } ?: BotContextLintThresholds.DEFAULT
            val actual = BotContextLint.lint(
                events = events,
                promptMount = case.members["promptMount"],
                tools = case.members["tools"],
                thresholds = thresholds,
                sessionId = case.members["sessionId"].stringOrNull(),
            )
            val expected = case.requireArray("expect")
            assertCanonicalEquals(
                JsonArray(expected),
                JsonArray(actual.map { it.toJson() }),
                "context-lint case $name",
            )
            for (finding in actual) coveredRules += finding.rule
        }
        assertEquals(BotContextLintRule.values().toSet(), coveredRules)
    }
}
