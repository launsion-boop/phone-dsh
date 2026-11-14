// SPDX-License-Identifier: MIT
package com.phonedsh.bot.cards

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.GoldenFixture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Drives the real `BotCardPayloads` builder with the untouched upstream
 * `card-payload.json` and the phone delta `card-payload.phone.json`. Expected
 * values come from the fixtures; the only expectations in code are the
 * protocol rules (P0 tool set, `final` stripped, ids assigned).
 */
class BotCardPayloadGoldenTest {
    @Test
    fun exactNonActionLabelsAreRemovedOnlyFromSteps() {
        val fillers = listOf(
            "暂时不用", "暂不需要", "不用了", "先这样", "不需要", "暂不操作", "暂不继续",
            "没有了", "以上都不", "not now", "no thanks", "do nothing", "none of the above",
            "skip", "none", "暂时不需要", "先不用", "以后再说", "暂不处理", "无需操作", "暂停，稍后继续",
        )
        for (filler in fillers) {
            val steps = BotCardPayloads.build("show_next_steps", JsonObject(mapOf(
                "steps" to JsonArray(listOf(JsonString("继续处理"), JsonString("  ${filler.uppercase()}  "), JsonString("查看结果"))),
            ))) as JsonObject
            val card = steps.members["card"] as JsonObject
            val labels = ((card.members["steps"] as JsonArray).values).map {
                ((it as JsonObject).members["label"] as JsonString).value
            }
            assertEquals(filler, listOf("继续处理", "查看结果"), labels)

            val question = BotCardPayloads.build("ask_user", JsonObject(mapOf(
                "question" to JsonString("选择一个"),
                "options" to JsonArray(listOf(
                    JsonObject(mapOf("label" to JsonString(filler))),
                    JsonObject(mapOf("label" to JsonString("选择 A"))),
                    JsonObject(mapOf("label" to JsonString("选择 B"))),
                )),
            ))) as JsonObject
            val questionCard = question.members["card"] as JsonObject
            val questionLabels = ((questionCard.members["options"] as JsonArray).values).map {
                ((it as JsonObject).members["label"] as JsonString).value
            }
            assertTrue("ask_user must retain $filler", filler in questionLabels)
        }
    }

    @Test
    fun p0CardsMatchTheUpstreamGolden() {
        val fixture = GoldenFixture.rawObject("card-payload")
        val valid = GoldenFixture.objects(fixture, "valid")
        assertTrue("card-payload.valid must not be empty", valid.isNotEmpty())
        var built = 0
        for ((index, call) in valid.withIndex()) {
            val tool = GoldenFixture.requireString(call, "tool")
            val args = GoldenFixture.at(call, "args")
                ?: throw AssertionError("valid[$index] has no args")
            if (tool !in BotCardPayloads.P0_CARD_TOOLS) {
                assertTrue("valid[$index] $tool must be rejected as non-P0", throwsInvalid {
                    BotCardPayloads.build(tool, args)
                })
                continue
            }
            val actual = BotCardPayloads.build(tool, args)
            val expected = GoldenFixture.objectValue(call, "result")
            val comparable = if (tool == "ask_user" || tool == "show_next_steps") {
                strippingChoiceIDs(actual)
            } else {
                actual
            }
            assertEquals("valid[$index] $tool", GoldenFixture.canonical(expected),
                GoldenFixture.canonical(comparable))
            built++
        }
        assertTrue("card-payload must exercise a P0 card", built > 0)
    }

    @Test
    fun everyUpstreamInvalidCardIsRejectedWithTheGoldenMessage() {
        val fixture = GoldenFixture.rawObject("card-payload")
        for ((index, call) in GoldenFixture.objects(fixture, "invalid").withIndex()) {
            val tool = GoldenFixture.requireString(call, "tool")
            val args = GoldenFixture.at(call, "args")
                ?: throw AssertionError("invalid[$index] has no args")
            val expected = GoldenFixture.requireString(call, "result", "error")
            val message = try {
                BotCardPayloads.build(tool, args)
                throw AssertionError("invalid[$index] $tool was accepted")
            } catch (error: BotCardPayloadException) {
                error.message
            }
            assertEquals("invalid[$index] $tool", expected, message)
        }
    }

    @Test
    fun phoneDeltaCardsAssignHostOptionIdsAndRecommendationOrder() {
        val fixture = GoldenFixture.rawObject("card-payload.phone")
        val valid = GoldenFixture.objects(fixture, "valid")
        assertTrue("card-payload.phone.valid must not be empty", valid.isNotEmpty())
        for ((index, call) in valid.withIndex()) {
            val tool = GoldenFixture.requireString(call, "tool")
            val args = GoldenFixture.at(call, "args")
                ?: throw AssertionError("phone valid[$index] has no args")
            val actual = BotCardPayloads.build(tool, args)
            val expected = GoldenFixture.objectValue(call, "result")
            assertEquals("phone valid[$index] $tool", GoldenFixture.canonical(expected),
                GoldenFixture.canonical(actual))
            assertNull("$tool must strip final from the card", GoldenFixture.at(actual, "card", "final"))
        }
    }

    @Test
    fun everyPhoneInvalidCardIsRejectedWithTheGoldenMessage() {
        val fixture = GoldenFixture.rawObject("card-payload.phone")
        for ((index, call) in GoldenFixture.objects(fixture, "invalid").withIndex()) {
            val tool = GoldenFixture.requireString(call, "tool")
            val args = GoldenFixture.at(call, "args")
                ?: throw AssertionError("phone invalid[$index] has no args")
            val expected = GoldenFixture.requireString(call, "result", "error")
            val message = try {
                BotCardPayloads.build(tool, args)
                throw AssertionError("phone invalid[$index] $tool was accepted")
            } catch (error: BotCardPayloadException) {
                error.message
            }
            assertEquals("phone invalid[$index] $tool", expected, message)
        }
    }

    @Test
    fun everyGoldenFinalArgumentIsValidatedAndStripped() {
        val fixture = GoldenFixture.rawObject("card-payload.phone")
        var seen = 0
        for (call in GoldenFixture.objects(fixture, "valid")) {
            val tool = GoldenFixture.requireString(call, "tool")
            val args = GoldenFixture.at(call, "args") ?: continue
            if (GoldenFixture.at(args, "final") == null) continue
            seen++
            val expected = GoldenFixture.requireBool(args, "final")
            assertEquals("$tool final", expected, BotCardPayloads.contentCardFinal(tool, args))
            val built = BotCardPayloads.build(tool, args)
            assertNull("$tool must strip final", GoldenFixture.at(built, "card", "final"))
            assertFalse("$tool final is not a required card field",
                GoldenFixture.at(built, "card", "final") != null)
        }
        assertTrue("phone golden must carry final cases", seen > 0)
    }

    /** Mirrors the Swift test helper: upstream has no host-assigned option ids. */
    private fun strippingChoiceIDs(value: JsonValue): JsonValue {
        val result = (value as? JsonObject)?.members ?: return value
        val card = (result["card"] as? JsonObject)?.members ?: return value
        val copy = LinkedHashMap(result)
        val cardCopy = LinkedHashMap(card)
        for (key in listOf("options", "steps")) {
            val items = (cardCopy[key] as? JsonArray)?.values ?: continue
            cardCopy[key] = JsonArray(items.map { item ->
                val fields = (item as? JsonObject)?.members ?: return@map item
                JsonObject(LinkedHashMap(fields).apply { remove("id") })
            })
        }
        copy["card"] = JsonObject(cardCopy)
        return JsonObject(copy)
    }

    private fun throwsInvalid(block: () -> Unit): Boolean = try {
        block()
        false
    } catch (_: BotCardPayloadException) {
        true
    }
}
