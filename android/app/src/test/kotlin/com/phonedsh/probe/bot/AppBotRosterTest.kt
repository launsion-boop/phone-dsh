// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.bot.profile.BotFishColor
import com.phonedsh.bot.profile.BotFishHairstyle
import com.phonedsh.bot.profile.BotProfile
import com.phonedsh.ui.bot.state.BotRosterRuntimeState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** K6a: profile roster -> the drawer's plain `BotRosterEntry` values. */
class AppBotRosterTest {
    @Test
    fun emptyProfilesStillProduceOneHonestMainRow() {
        val roster = AppBotRoster.roster()
        assertEquals("main", roster.mainBotID)
        val entries = AppBotRoster.entries(roster)
        assertEquals(1, entries.size)
        assertTrue(entries.single().isMainBot)
        assertEquals("main", entries.single().id)
    }

    @Test
    fun mainPointerIsRepairedToTheFirstRecordAndOrderedFirst() {
        val roster = AppBotRoster.roster(
            profiles = listOf(
                BotProfile(id = "beta", name = "Beta"),
                BotProfile(id = "alpha", name = "Alpha"),
            ),
            storedMainBotId = "removed",
        )
        assertEquals("beta", roster.mainBotID)
        val entries = AppBotRoster.entries(roster)
        assertEquals(listOf("beta", "alpha"), entries.map { it.id })
        assertEquals(listOf(true, false), entries.map { it.isMainBot })
    }

    @Test
    fun explicitFishFieldsWinAndMissingFieldsUseTheSeed() {
        val explicit = BotProfile(
            id = "custom",
            name = "Custom",
            fishColor = BotFishColor.RED,
            fishHairstyle = BotFishHairstyle.BOB,
        )
        val seeded = BotProfile(id = "seeded", name = "Seeded")
        val entries = AppBotRoster.entries(
            AppBotRoster.roster(listOf(explicit, seeded), storedMainBotId = "custom"),
        )
        val explicitEntry = entries.first { it.id == "custom" }
        assertEquals(BotFishColor.RED, explicitEntry.appearance.color)
        assertEquals(BotFishHairstyle.BOB, explicitEntry.appearance.hairstyle)
        assertFalse(explicitEntry.appearance.autoColor)
        assertFalse(explicitEntry.appearance.autoHairstyle)

        val seededEntry = entries.first { it.id == "seeded" }
        assertTrue(seededEntry.appearance.autoColor)
        assertTrue(seededEntry.appearance.autoHairstyle)
    }

    @Test
    fun hiddenRowsRemainInTheValueAndRuntimeStateIsPassedThrough() {
        val roster = AppBotRoster.roster(
            profiles = listOf(
                BotProfile(id = "main", name = "Main"),
                BotProfile(id = "hidden", name = "Hidden", hiddenByUser = true),
            ),
            storedMainBotId = "main",
        )
        val entries = AppBotRoster.entries(
            roster,
            runtime = mapOf("main" to BotRosterRuntimeState(isRunning = true)),
        )
        assertEquals(2, entries.size)
        assertTrue(entries.first { it.id == "hidden" }.isHidden)
        assertTrue(entries.first { it.id == "main" }.isRunning)
    }

    @Test
    fun contextFallsBackToTheRepairedMainPointer() {
        val roster = AppBotRoster.roster(
            profiles = listOf(
                BotProfile(id = "one", name = "One"),
                BotProfile(id = "two", name = "Two"),
            ),
            storedMainBotId = "two",
        )
        assertEquals("two", AppBotRoster.context(roster).botID)
        assertEquals("one", AppBotRoster.context(roster, selectedBotId = "one").botID)
        assertEquals("two", AppBotRoster.context(roster, selectedBotId = "gone").botID)
    }
}
