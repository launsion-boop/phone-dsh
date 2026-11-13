// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Every `golden/activity-phrase-vectors.json` case, section by section, driven
 * through [BotActivityPhrases] and [BotActivityLineState]'s frozen timing.
 */
class BotActivityPhraseVectorTest {
    private val vectors: JsonObject = BotUiStateFixtures.golden("activity-phrase-vectors.json")

    @Test
    fun toolCases() {
        for (raw in vectors.array("toolCases")) {
            val case = raw as JsonObject
            val input = case.objectAt("input")
            val actual = BotActivityPhrases.toolActivity(
                input.stringAt("tool"),
                input.objectAt("arguments").members,
            )
            BotUiStateFixtures.assertJsonEquals(
                "tool case ${case.stringAt("id")}",
                case["expected"]!!,
                BotJson.objectOf(
                    "category" to JsonString(actual.category.wire),
                    "text" to JsonString(actual.text),
                ),
            )
        }
    }

    @Test
    fun textCases() {
        for (raw in vectors.array("textCases")) {
            val case = raw as JsonObject
            val rawText = case.objectAt("input").stringAt("raw")
            val expected = case["expected"]!!
            val actual = BotActivityPhrases.cleanedModelText(rawText)
            if (expected is JsonNull) {
                assertNull("text case ${case.stringAt("id")}", actual)
            } else {
                assertEquals("text case ${case.stringAt("id")}", (expected as JsonString).value, actual)
            }
        }
    }

    @Test
    fun targetCases() {
        for (raw in vectors.array("targetCases")) {
            val case = raw as JsonObject
            val actual = BotActivityPhrases.shortTarget(case.objectAt("input").stringAt("raw"))
            assertEquals(
                "target case ${case.stringAt("id")}",
                (case["expected"] as JsonString).value,
                actual,
            )
        }
    }

    @Test
    fun reviewingCases() {
        for (raw in vectors.array("reviewingCases")) {
            val case = raw as JsonObject
            val input = case.objectAt("input")
            val actual = BotActivityPhrases.reviewingText(
                input.stringAt("tool"),
                input.objectAt("arguments").members,
            )
            assertEquals(
                "reviewing case ${case.stringAt("id")}",
                (case["expected"] as JsonString).value,
                actual,
            )
        }
    }

    @Test
    fun rotationCases() {
        for (raw in vectors.array("rotationCases")) {
            val case = raw as JsonObject
            val category = BotActivityCategory.fromWire(case.stringAt("category"))
            val activity = BotActivity(
                status = BotActivityStatus.THINKING,
                detail = case.stringAt("detail"),
                category = category,
                startedAt = 0,
            )
            val actual = BotActivityPhrases.rotationPhrases(activity)
            val expected = (case["expected"] as JsonArray).values.map { (it as JsonString).value }
            assertEquals("rotation case ${case.stringAt("id")}", expected, actual)
        }
    }

    @Test
    fun minuteCases() {
        for (raw in vectors.array("minuteCases")) {
            val case = raw as JsonObject
            val activity = BotActivity(
                status = BotActivityStatus.THINKING,
                detail = "",
                category = BotActivityCategory.GENERIC,
                startedAt = (case["startedAt"] as JsonNumber).asLongOrNull()!!,
            )
            val now = (case["now"] as JsonNumber).asLongOrNull()!!
            assertEquals(
                "minute case ${case.stringAt("id")}",
                (case["expected"] as JsonNumber).asLongOrNull(),
                BotActivityPhrases.sustainedMinutes(activity, now).toLong(),
            )
        }
    }

    @Test
    fun constants() {
        val constants = vectors.objectAt("constants")
        assertEquals(800L, constants.longAt("minimumVisibleMillis"))
        assertEquals(2_400L, constants.longAt("rotationIntervalMillis"))
        assertEquals(60_000L, constants.longAt("minuteMillis"))
        assertEquals(20L, constants.longAt("cleanedMax"))
        assertEquals(42L, constants.longAt("targetMax"))
        assertEquals(BotTimers.ACTIVITY_MIN_VISIBLE, constants.longAt("minimumVisibleMillis"))
        assertEquals(BotTimers.ACTIVITY_ROTATION, constants.longAt("rotationIntervalMillis"))
        assertEquals(BotTimers.MINUTE, constants.longAt("minuteMillis"))
    }

    private fun JsonObject.array(key: String): List<JsonValue> =
        (this[key] as JsonArray).values

    private fun JsonObject.objectAt(key: String): JsonObject =
        this[key] as JsonObject

    private fun JsonObject.stringAt(key: String): String =
        (this[key] as JsonString).value

    private fun JsonObject.longAt(key: String): Long =
        (this[key] as JsonNumber).asLongOrNull()!!
}
