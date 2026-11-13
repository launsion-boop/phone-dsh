// SPDX-License-Identifier: MIT
package com.phonedsh.bot.watchdog

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Context profiles stay read-only golden data; the Bot runtime does not compact. */
class BotContextProfilesGoldenTest {
    @Test
    fun frozenProfilesAndRenderedYamlMatchTheGoldenExactly() {
        val vector = fixture("context-profiles")
        val valid = vector.requireObject("valid")
        val document = BotContextProfileDocument.fromJson(
            com.phonedsh.agentcore.JsonObject(
                linkedMapOf(
                    "profiles" to valid.getValue("profiles"),
                    "yaml" to valid.getValue("yaml"),
                ),
            ),
        )
        assertEquals(BotContextProfileDocument.FROZEN, document)
        assertCanonicalEquals(valid.getValue("yaml"), document.yaml.toJson(), "profile yaml")
        assertCanonicalEquals(valid.getValue("profiles"), document.profiles.toJson(), "profiles")

        val watchdog = fixture("watchdog.phone").requireObject("contextProfiles")
        assertTrue((watchdog.getValue("readOnly") as com.phonedsh.agentcore.JsonBool).value)
        assertFalse((watchdog.getValue("botRuntimeCompaction") as com.phonedsh.agentcore.JsonBool).value)
        assertEquals("default", watchdog.getValue("unknownResolution").requiredString())
        assertEquals(
            listOf("default", "conservative"),
            watchdog.getValue("profiles").arrayOrNull()!!.map { it.requiredString() },
        )
    }

    @Test
    fun unknownProfileResolvesToDefault() {
        assertEquals(
            BotContextProfileName.DEFAULT,
            BotContextProfileName.resolve("unknown"),
        )
        assertEquals(
            BotContextProfileName.DEFAULT,
            BotContextProfileName.resolve("  DEFAULT "),
        )
        assertEquals(
            BotContextProfileName.CONSERVATIVE,
            BotContextProfileName.resolve(" conservative\n"),
        )
        assertEquals(BotContextProfile.DEFAULT, BotContextProfile.named(BotContextProfileName.DEFAULT))
    }
}
