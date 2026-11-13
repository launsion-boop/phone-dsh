// SPDX-License-Identifier: MIT
package com.phonedsh.bot.authz

import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.GoldenFixture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Drives the real classifier with the merged `tool-effects` fixture. The
 * `.phone.json` overlay replaces upstream display strings, so this is the
 * phone consumer's view; no expected effect is copied into the test.
 */
class BotToolEffectsGoldenTest {
    @Test
    fun validInvalidAndNativeMcpEffectsMatchTheMergedGolden() {
        val fixture = GoldenFixture.mergedObject("tool-effects")
        val calls = GoldenFixture.objects(fixture, "valid") +
            GoldenFixture.objects(fixture, "invalid") +
            GoldenFixture.objects(fixture, "nativeMcp")
        assertTrue("tool-effects must carry cases", calls.isNotEmpty())
        for (call in calls) {
            val name = GoldenFixture.requireString(call, "name")
            val args = GoldenFixture.at(call, "args")!!
            val expectedPolicy = GoldenFixture.requireString(call, "policy")
            val expected = GoldenFixture.objectValue(call, "effect")
            val actual = BotToolEffectClassifier.effect(name, args)
            assertEquals("$name policy", expectedPolicy, actual.policy.wire)
            assertJsonEquals("$name effect", expected, actual.toJson())
        }
    }

    @Test
    fun unknownToolsAreWriteClassAskAndNotKnown() {
        val effect = BotToolEffectClassifier.effect("GenerateImage", JsonObject(emptyMap()))
        assertFalse(effect.known)
        assertEquals("tool.unclassified", effect.operation)
        assertEquals(BotToolPolicy.ASK, effect.policy)
        assertEquals(BotToolMutability.WRITE, effect.mutability)
    }

    @Test
    fun int64BoundaryNumbersDoNotThrow() {
        val effect = BotToolEffectClassifier.effect(
            "RecallMemory",
            jsonObject("limit" to JsonNumber("9223372036854775808")),
        )
        assertTrue(effect.detail.contains("limit="))
    }
}
