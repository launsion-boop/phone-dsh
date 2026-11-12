// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Proves the compiled string/phrase data is byte-identical to the normative
 * JSON. This is the test that makes the `UiStrings.kt` pattern acceptable:
 * no value is retyped without the spec file agreeing.
 */
class BotUiStringsGoldenTest {
    @Test
    fun stringsMatchStringsJson() {
        val entries = (BotUiStateFixtures.strings()["strings"] as JsonArray).values
            .map { it as JsonObject }
        val expected = LinkedHashMap<String, String>()
        for (entry in entries) {
            val id = (entry["id"] as JsonString).value
            val value = (entry["value"] as JsonString).value
            expected[id] = value
        }
        assertEquals("BotUiStrings.BY_ID must have exactly the spec entries",
            expected.keys, BotUiStrings.BY_ID.keys)
        assertEquals(expected, BotUiStrings.BY_ID)
        for ((id, value) in expected) {
            assertEquals("string id '$id'", value, BotUiStrings.get(id))
        }
    }

    @Test
    fun activityPhraseDataMatchesJson() {
        val json = BotUiStateFixtures.activityPhrases()

        val ruleValues = (json["toolRules"] as JsonArray).values.map { it as JsonObject }
        assertEquals(70, ruleValues.size)
        assertEquals(
            "generated table must have exactly the spec tools",
            ruleValues.map { (it["tool"] as JsonString).value }.toSet(),
            BotActivityPhraseData.RULES.keys,
        )
        for (raw in ruleValues) {
            val rule = raw as JsonObject
            val tool = (rule["tool"] as JsonString).value
            val generated = BotActivityPhraseData.RULES.getValue(tool)
            assertEquals(
                "category of $tool",
                BotActivityCategory.fromWire((rule["category"] as JsonString).value),
                generated.category,
            )
            assertEquals("phrase of $tool", (rule["phrase"] as JsonString).value, generated.phrase)
            assertEquals(
                "targetKeys of $tool",
                (rule["targetKeys"] as JsonArray).values.map { (it as JsonString).value },
                generated.targetKeys,
            )
            assertEquals(
                "targetIsURL of $tool",
                (rule["targetIsURL"] as com.phonedsh.agentcore.JsonBool).value,
                generated.targetIsUrl,
            )
            assertEquals(
                "targetArray of $tool",
                (rule["targetArray"] as com.phonedsh.agentcore.JsonBool).value,
                generated.targetArray,
            )
        }

        for (raw in (json["categories"] as JsonArray).values) {
            val category = raw as JsonObject
            val parsed = BotActivityCategory.fromWire((category["category"] as JsonString).value)
            val primary = category["primary"] as JsonObject
            assertEquals(
                "primary phrase of ${parsed.wire}",
                (primary["value"] as JsonString).value,
                BotActivityPhraseData.PRIMARY.getValue(parsed),
            )
            val rotation = (category["rotation"] as JsonArray).values
                .map { ((it as JsonObject)["value"] as JsonString).value }
            assertEquals(
                "rotation of ${parsed.wire}",
                rotation,
                BotActivityPhraseData.ROTATION.getValue(parsed),
            )
            val style = (json["workStyle"] as JsonObject)[parsed.wire] as JsonObject
            assertEquals(
                "workStyle of ${parsed.wire}",
                (style["value"] as JsonString).value,
                BotActivityPhraseData.WORK_STYLE.getValue(parsed).wire,
            )
        }

        val policy = json["textPolicy"] as JsonObject
        assertEquals(
            (policy["modelTextKeys"] as JsonArray).values.map { (it as JsonString).value },
            BotActivityPhraseData.MODEL_TEXT_KEYS,
        )
        assertEquals(
            (policy["stripTrailingPunctuation"] as JsonString).value,
            BotActivityPhraseData.STRIP_TRAILING_PUNCTUATION,
        )
        assertEquals(BotActivityPhraseData.MAX_CHARACTERS.toLong(),
            (policy["maxCharacters"] as com.phonedsh.agentcore.JsonNumber).asLongOrNull())
        assertEquals(BotActivityPhraseData.ELLIPSIS, (policy["ellipsis"] as JsonString).value)
        assertEquals(BotActivityPhraseData.TRUNCATE_AT.toLong(),
            (policy["truncateAt"] as com.phonedsh.agentcore.JsonNumber).asLongOrNull())
        assertEquals(BotActivityPhraseData.TARGET_MAX_CHARACTERS.toLong(),
            (policy["targetMaxCharacters"] as com.phonedsh.agentcore.JsonNumber).asLongOrNull())
        assertEquals(BotActivityPhraseData.TARGET_TRUNCATE_AT.toLong(),
            (policy["targetTruncateAt"] as com.phonedsh.agentcore.JsonNumber).asLongOrNull())

        val timing = json["timing"] as JsonObject
        for ((key, generated) in listOf(
            "minimumVisibleMillis" to BotActivityPhraseData.MINIMUM_VISIBLE_MILLIS,
            "rotationIntervalMillis" to BotActivityPhraseData.ROTATION_INTERVAL_MILLIS,
            "minuteMillis" to BotActivityPhraseData.MINUTE_MILLIS,
        )) {
            assertEquals(
                "timing.$key",
                generated,
                ((timing[key] as JsonObject)["value"] as com.phonedsh.agentcore.JsonNumber)
                    .asLongOrNull(),
            )
        }
        assertEquals(
            (timing["minuteSuffixTemplate"] as JsonObject)["value"]?.let {
                (it as JsonString).value
            },
            BotActivityPhraseData.MINUTE_SUFFIX_TEMPLATE,
        )

        val generic = json["genericFallback"] as JsonObject
        assertEquals(BotActivityPhraseData.GENERIC_CATEGORY,
            (generic["category"] as JsonString).value)
        assertEquals(BotActivityPhraseData.GENERIC_PHRASE,
            (generic["phrase"] as JsonString).value)
        assertEquals(
            BotActivityPhraseData.BARE_TOOL_PREFIX,
            ((json["bareToolName"] as JsonObject)["prefix"] as JsonString).value,
        )

        // Cross-data invariant: the strings file and the phrase file agree.
        assertTrue(BotUiStrings.BY_ID.containsKey("activity.thinking.primary"))
        assertEquals(
            BotActivityPhraseData.PRIMARY[BotActivityCategory.THINKING],
            BotUiStrings.ACTIVITY_THINKING_PRIMARY,
        )
        assertEquals(
            BotActivityPhraseData.ROTATION[BotActivityCategory.REPLYING],
            listOf(
                BotUiStrings.ACTIVITY_REPLYING_ROTATION_0,
                BotUiStrings.ACTIVITY_REPLYING_ROTATION_1,
                BotUiStrings.ACTIVITY_REPLYING_ROTATION_2,
            ),
        )
    }
}
