// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.GoldenFixture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The upstream approval-pattern batch plus the phone downgrade overlay: the
 * destructive hints keep their exact match objects, while every network
 * command spelling in the overlay produces no effect. Workspace is the shared
 * vector root, not a test-local copy.
 */
class BotApprovalPatternsGoldenTest {
    @Test
    fun destructiveMatchesAndNetworkDowngradesFollowTheGolden() {
        val upstream = GoldenFixture.rawObject("approval-patterns")
        val overlay = GoldenFixture.rawObject("approval-patterns.phone")
        val downgraded = GoldenFixture.objects(overlay, "downgraded").mapNotNull {
            GoldenFixture.string(it, "args", "command")
        }.toSet()
        assertTrue("approval-patterns.phone.downgraded must not be empty", downgraded.isNotEmpty())
        val calls = GoldenFixture.objects(upstream, "valid") +
            GoldenFixture.objects(upstream, "invalid")
        assertTrue("approval-patterns must carry cases", calls.isNotEmpty())
        for (call in calls) {
            val tool = GoldenFixture.requireString(call, "tool")
            val args = GoldenFixture.at(call, "args")!!
            val command = GoldenFixture.string(args, "command") ?: ""
            val actual = BotApprovalPatternAnalyzer.analyze(
                tool = tool,
                arguments = args,
                workspace = "/tmp/phonedsh-bot-work",
                language = BotToolLanguage.EN,
            )
            if (command in downgraded) {
                assertEquals("network command must be downgraded: $command", emptyList<Any>(), actual)
            } else {
                val expected = GoldenFixture.at(call, "matches") as JsonArray
                assertJsonEquals(
                    "approval pattern $command",
                    JsonArray(expected.values),
                    JsonArray(actual.map { it.toJson() }),
                )
            }
        }
    }

    @Test
    fun everyDowngradedCaseIsSilentAndLeavesNoEffect() {
        val overlay = GoldenFixture.rawObject("approval-patterns.phone")
        for (call in GoldenFixture.objects(overlay, "downgraded")) {
            val tool = GoldenFixture.requireString(call, "tool")
            val args = GoldenFixture.at(call, "args")!!
            assertTrue(
                "downgraded $tool must not match",
                BotApprovalPatternAnalyzer.analyze(tool, args, "/tmp/phonedsh-bot-work").isEmpty(),
            )
            assertTrue(
                "downgraded $tool must not produce an effect",
                BotApprovalPatternAnalyzer.effects(tool, args, "/tmp/phonedsh-bot-work").isEmpty(),
            )
        }
    }
}
