// SPDX-License-Identifier: MIT
package com.phonedsh.bot.attachments

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.GoldenFixture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Drives the shared `safePathComponent` with the frozen
 * `session-lifecycle.phone.json` workspace vectors, read from disk.
 *
 * The focused test below covers the UAX #29 rules that the contract-level
 * `safePathComponent` vectors cannot reach directly: §2.1 replaces every
 * non-`L*`/`M*`/`N*` scalar with `_` before truncating, so emoji ZWJ
 * sequences, flags and modifiers are all `_` in the contract output. The
 * shared truncation helper still has to count them correctly for its own
 * callers, and JDK 17's `BreakIterator` does not (it splits the family emoji
 * into five clusters and a flag into two).
 */
class BotWorkspaceLayoutTest {
    private val fixture: JsonObject by lazy {
        GoldenFixture.rawObject("session-lifecycle.phone")
    }

    @Test
    fun workspaceVectorsUseTheSharedLayout() {
        val valid = GoldenFixture.objects(fixture, "valid", "workspace")
            .map { it as JsonObject }
        assertTrue("session-lifecycle.valid.workspace must not be empty", valid.isNotEmpty())
        for (vector in valid) {
            val botId = GoldenFixture.requireString(vector, "botId")
            val dataDirectory = GoldenFixture.string(vector, "dataDirectory")
                ?: BotWorkspaceLayout.DEFAULT_BOT_DATA_DIRECTORY
            assertEquals("safePathComponent(${botId.length} scalars)",
                GoldenFixture.requireString(vector, "safe"),
                BotWorkspaceLayout.safePathComponent(botId))
            assertEquals("botRoot(${botId.length} scalars)",
                GoldenFixture.requireString(vector, "root"),
                BotWorkspaceLayout.botRoot(botId, dataDirectory))
        }
        val invalid = GoldenFixture.objects(fixture, "invalid", "workspace")
            .map { it as JsonObject }
        assertTrue("session-lifecycle.invalid.workspace must not be empty", invalid.isNotEmpty())
        for (vector in invalid) {
            val botId = GoldenFixture.requireString(vector, "botId")
            assertEquals("${GoldenFixture.string(vector, "name")}: safe",
                GoldenFixture.requireString(vector, "safe"),
                BotWorkspaceLayout.safePathComponent(botId))
        }
        println("session-lifecycle.workspace layout: ${valid.size} valid / ${invalid.size} invalid")
    }

    @Test
    fun graphemeTruncationHandlesExtendedClusters() {
        val family = "\uD83D\uDC68\u200D\uD83D\uDC69\u200D\uD83D\uDC67"
        val flagUS = "\uD83C\uDDFA\uD83C\uDDF8"
        val flagJP = "\uD83C\uDDEF\uD83C\uDDF5"
        val waveTone = "\uD83D\uDC4B\uD83C\uDFFD"
        val rainbow = "\uD83C\uDFF3\uFE0F\u200D\uD83C\uDF08"
        val keycap = "1\uFE0F\u20E3"
        val hangul = "\u1100\u1161\u11A8"
        val eAcute = "e\u0301"

        assertEquals(family, BotWorkspaceLayout.truncateGraphemeClusters(family + "x", 1))
        assertEquals(family + "x", BotWorkspaceLayout.truncateGraphemeClusters(family + "x", 2))
        assertEquals(flagUS, BotWorkspaceLayout.truncateGraphemeClusters(flagUS + flagJP, 1))
        assertEquals(flagUS + flagJP,
            BotWorkspaceLayout.truncateGraphemeClusters(flagUS + flagJP, 2))
        assertEquals(waveTone, BotWorkspaceLayout.truncateGraphemeClusters(waveTone + "x", 1))
        assertEquals(rainbow, BotWorkspaceLayout.truncateGraphemeClusters(rainbow + "x", 1))
        assertEquals(keycap, BotWorkspaceLayout.truncateGraphemeClusters(keycap + "x", 1))
        assertEquals(hangul, BotWorkspaceLayout.truncateGraphemeClusters(hangul + "x", 1))
        assertEquals(eAcute, BotWorkspaceLayout.truncateGraphemeClusters(eAcute + "x", 1))

        assertEquals(1, BotWorkspaceLayout.graphemeClusterCount(family))
        assertEquals(1, BotWorkspaceLayout.graphemeClusterCount(flagUS))
        assertEquals(2, BotWorkspaceLayout.graphemeClusterCount(flagUS + flagJP))
        assertEquals(1, BotWorkspaceLayout.graphemeClusterCount(rainbow))
        assertEquals(1, BotWorkspaceLayout.graphemeClusterCount(waveTone))

        val decomposed = eAcute.repeat(65)
        assertEquals(eAcute.repeat(64),
            BotWorkspaceLayout.truncateGraphemeClusters(decomposed, 64))
        assertEquals("", BotWorkspaceLayout.truncateGraphemeClusters(decomposed, 0))
        assertEquals(decomposed, BotWorkspaceLayout.truncateGraphemeClusters(decomposed, 65))
    }
}
