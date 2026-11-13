// SPDX-License-Identifier: MIT
package com.phonedsh.bot.profile

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.GoldenFixture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Drives the real colour/hairstyle order, FNV seed, normalizer and pure roster
 * rules with `bot-profile.json` read from disk.
 */
class BotProfileGoldenTest {
    @Test
    fun colourOrderHexAndNamesMatchTheGolden() {
        val fixture = GoldenFixture.rawObject("bot-profile")
        val colors = GoldenFixture.objects(fixture, "colors")
        assertTrue("bot-profile.colors must not be empty", colors.isNotEmpty())
        assertEquals("declaration order is the seed order",
            colors.map { GoldenFixture.requireString(it, "id") }.toSet(),
            BotFishColor.entries.map { it.wire }.toSet())
        for (entry in colors) {
            val id = GoldenFixture.requireString(entry, "id")
            val color = BotFishColor.entries.first { it.wire == id }
            assertEquals("$id hex", GoldenFixture.requireString(entry, "hex"), color.hex)
            assertTrue("$id display name", color.displayName.isNotEmpty())
        }
        assertEquals(
            colors.map { GoldenFixture.requireString(it, "id") },
            GoldenFixture.objects(fixture, "colorOrderMain").map { (it as JsonString).value },
        )
    }

    @Test
    fun hairstyleOrderAndNamesMatchTheGolden() {
        val fixture = GoldenFixture.rawObject("bot-profile")
        val expected = GoldenFixture.objects(fixture, "hairstyles").map { (it as JsonString).value }
        assertEquals(expected, BotFishHairstyle.entries.map { it.wire })
        for (hairstyle in BotFishHairstyle.entries) {
            assertTrue(hairstyle.displayName.isNotEmpty())
            assertTrue(hairstyle.accessibilityHint.isNotEmpty())
        }
    }

    @Test
    fun everyGoldenColorNormalizationCaseUsesTheRealNormalizer() {
        val cases = GoldenFixture.objects(GoldenFixture.rawObject("bot-profile"), "normalizeFishColor")
        assertTrue("normalizeFishColor must not be empty", cases.isNotEmpty())
        for ((index, entry) in cases.withIndex()) {
            val input = GoldenFixture.string(entry, "input")
            val expected = GoldenFixture.string(entry, "output")
            assertEquals("normalizeFishColor[$index] $input", expected,
                BotProfileNormalizer.fishColor(input)?.wire)
        }
    }

    @Test
    fun everyGoldenHairstyleNormalizationCaseUsesTheRealNormalizer() {
        val cases = GoldenFixture.objects(GoldenFixture.rawObject("bot-profile"), "normalizeFishHairstyle")
        assertTrue("normalizeFishHairstyle must not be empty", cases.isNotEmpty())
        for ((index, entry) in cases.withIndex()) {
            val input = GoldenFixture.string(entry, "input")
            val expected = GoldenFixture.string(entry, "output")
            assertEquals("normalizeFishHairstyle[$index] $input", expected,
                BotProfileNormalizer.fishHairstyle(input)?.wire)
        }
    }

    @Test
    fun everyGoldenSeedCaseUsesTheRealFnvSeed() {
        val cases = GoldenFixture.objects(GoldenFixture.rawObject("bot-profile"), "seed")
        assertTrue("seed must not be empty", cases.isNotEmpty())
        for ((index, entry) in cases.withIndex()) {
            val seed = GoldenFixture.requireString(entry, "seed")
            val seeded = BotFishAppearance.seed(seed)
            assertEquals("seed[$index] $seed color", GoldenFixture.requireString(entry, "color"),
                seeded.color.wire)
            assertEquals("seed[$index] $seed hex", GoldenFixture.requireString(entry, "hex"),
                seeded.color.hex)
            assertEquals("seed[$index] $seed hairstyle", GoldenFixture.requireString(entry, "hairstyle"),
                seeded.hairstyle.wire)
        }
    }

    @Test
    fun everyGoldenMainPointerRepairCaseUsesTheRealRule() {
        val rules = GoldenFixture.objectValue(GoldenFixture.rawObject("bot-profile"), "rosterRules")
        val cases = GoldenFixture.objects(rules, "mainPointerRepair")
        assertTrue("mainPointerRepair must not be empty", cases.isNotEmpty())
        for ((index, entry) in cases.withIndex()) {
            val records = GoldenFixture.objects(entry, "records").map { (it as JsonString).value }
            val stored = GoldenFixture.string(entry, "mainAgentId")
            val expected = GoldenFixture.string(entry, "expectedMainAgentId")
            assertEquals("mainPointerRepair[$index] ${GoldenFixture.string(entry, "name")}",
                expected, BotRosterRules.repairMainBotID(records, stored))
        }
    }

    @Test
    fun everyGoldenDeleteMigrationCaseUsesTheRealRule() {
        val rules = GoldenFixture.objectValue(GoldenFixture.rawObject("bot-profile"), "rosterRules")
        val cases = GoldenFixture.objects(rules, "deleteMainMigration")
        assertTrue("deleteMainMigration must not be empty", cases.isNotEmpty())
        for ((index, entry) in cases.withIndex()) {
            val records = GoldenFixture.objects(entry, "records").map { (it as JsonString).value }
            val stored = GoldenFixture.string(entry, "mainAgentId")
            val deleteID = GoldenFixture.requireString(entry, "deleteId")
            val expectedRemaining = GoldenFixture.objects(entry, "expectedRemaining")
                .map { (it as JsonString).value }
            val expectedMain = GoldenFixture.string(entry, "expectedMainAgentId")
            val outcome = BotRosterRules.delete(records, stored, deleteID)
            assertTrue("deleteMainMigration[$index] must delete",
                outcome is BotRosterDeleteOutcome.Deleted)
            outcome as BotRosterDeleteOutcome.Deleted
            assertEquals("deleteMainMigration[$index] remaining", expectedRemaining, outcome.remaining)
            assertEquals("deleteMainMigration[$index] main", expectedMain, outcome.mainBotID)
        }
    }

    @Test
    fun everyGoldenNormalizePatchCaseUsesTheRealRule() {
        val rules = GoldenFixture.objectValue(GoldenFixture.rawObject("bot-profile"), "rosterRules")
        val cases = GoldenFixture.objects(rules, "normalizePatch")
        assertTrue("normalizePatch must not be empty", cases.isNotEmpty())
        for ((index, entry) in cases.withIndex()) {
            val input = (GoldenFixture.at(entry, "input") as JsonObject).members
            val expected = GoldenFixture.objectValue(entry, "expected")
            val actual = BotRosterRules.normalizePatch(input)
            assertEquals("normalizePatch[$index] ${GoldenFixture.string(entry, "name")}",
                GoldenFixture.canonical(expected), GoldenFixture.canonical(JsonObject(actual)))
            for (dropped in GoldenFixture.objects(entry, "droppedKeys")) {
                val key = (dropped as JsonString).value
                assertFalse("normalizePatch[$index] must drop $key", actual.containsKey(key))
            }
        }
    }

    @Test
    fun resolveUsesIDThenNameThenTheLiteralFishSeed() {
        val auto = BotProfile(id = "main", name = "ignored")
        val resolved = BotFishAppearance.resolve(auto)
        val seeded = BotFishAppearance.seed("main")
        assertEquals(seeded.color, resolved.color)
        assertEquals(seeded.hairstyle, resolved.hairstyle)
        assertTrue(resolved.autoColor)
        assertTrue(resolved.autoHairstyle)

        val fallback = BotFishAppearance.resolve(BotProfile(id = "", name = ""))
        val fish = BotFishAppearance.seed("fish")
        assertEquals(fish.color, fallback.color)
        assertEquals(fish.hairstyle, fallback.hairstyle)
    }

    @Test
    fun resolvePrefersExplicitFieldsIndividually() {
        val profile = BotProfile(id = "🐟bot", name = "ignored",
            fishColor = BotFishColor.RED, fishHairstyle = null)
        val resolved = BotFishAppearance.resolve(profile)
        assertEquals(BotFishColor.RED, resolved.color)
        assertFalse(resolved.autoColor)
        assertEquals(BotFishAppearance.seed("🐟bot").hairstyle, resolved.hairstyle)
        assertTrue(resolved.autoHairstyle)
        assertNull(profile.fishHairstyle)
    }
}
