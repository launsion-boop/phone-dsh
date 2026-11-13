// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * `spec/bot/v2/golden/routine-notification.json` (PC-20261111-bot-v2-presence,
 * v2 §3.1): the fixed title, body, identifier and deep link, plus the four
 * rejected shapes.
 */
class RoutineNotificationGoldenTest {
    private fun titleFromBody(body: String): String {
        val open = body.indexOf("「")
        val close = body.indexOf("」")
        assertTrue("body must quote the routine title", open >= 0 && close > open)
        return body.substring(open + 1, close)
    }

    @Test
    fun everyGoldenNotificationIsBuiltFromTheFrozenFields() {
        val golden = V2Golden.load("routine-notification")
        val valid = (V2Golden.at(golden, "valid") as JsonObject).members
        assertEquals(setOf("normal", "quietDeferred", "urgentBypass"), valid.keys)
        for ((name, value) in valid) {
            val expected = value as JsonObject
            val notification = RoutineScheduledNotification.forRoutine(
                botId = V2Golden.string(expected, "botId"),
                routineId = V2Golden.string(expected, "routineId"),
                routineTitle = titleFromBody(V2Golden.string(expected, "body")),
                fireAt = V2Golden.long(expected, "fireAt"),
            )
            assertEquals(
                name,
                V2Golden.canonical(expected),
                V2Golden.canonical(notification.toJson()),
            )
            val roundTrip = RoutineScheduledNotification.fromJson(expected)
            assertEquals(notification, roundTrip)
            val parsed = BotRoutineDeepLink.parse(notification.deepLink)
            assertEquals(notification.botId to notification.routineId, parsed)
        }
    }

    @Test
    fun theIdentifierIsTheStableRescheduleKey() {
        assertEquals(
            "routine-due:bot-a:routine-1:1760056200000",
            RoutineScheduledNotification.identifier("bot-a", "routine-1", 1_760_056_200_000L),
        )
        val first = RoutineScheduledNotification.forRoutine("bot-a", "routine-1", "晨间简报", 100)
        val moved = RoutineScheduledNotification.forRoutine("bot-a", "routine-1", "晨间简报", 200)
        assertFalse(first.identifier == moved.identifier)
        assertEquals("例行任务到期", first.title)
        assertEquals("phonedsh://bot/bot-a/routine/routine-1", first.deepLink)
        // A title longer than 120 scalars is capped before it enters the body.
        val long = RoutineScheduledNotification.forRoutine("bot-a", "r", "长".repeat(200), 100)
        assertTrue(RoutineJson.codePointLength(long.body) <= 200)
        assertTrue(long.body.endsWith("」到点，点开运行。"))
    }

    @Test
    fun theFourInvalidShapesAreRejectedWithTheGoldenReason() {
        val golden = V2Golden.load("routine-notification")
        val invalid = V2Golden.objects(golden, "invalid")
        assertEquals(4, invalid.size)
        for (case in invalid) {
            val expectedReason = V2Golden.string(case, "reason")
            try {
                RoutineScheduledNotification.fromJson(case)
                fail("$expectedReason must be rejected")
            } catch (error: InvalidRoutineNotification) {
                assertEquals(expectedReason, error.reason)
            }
        }
    }

    @Test
    fun percentEncodedDeepLinksRoundTripNonAsciiIds() {
        val link = BotRoutineDeepLink.make("bot/一", "routine 二")
        assertEquals("phonedsh://bot/bot%2F%E4%B8%80/routine/routine%20%E4%BA%8C", link)
        assertEquals("bot/一" to "routine 二", BotRoutineDeepLink.parse(link))
        assertNull(BotRoutineDeepLink.parse("https://example.invalid/bot/a/routine/b"))
        assertNull(BotRoutineDeepLink.parse("phonedsh://bot/a/row/b"))
    }

    @Test
    fun validationRejectsAnEmptyBodyAndAWrongBot() {
        val notification = RoutineScheduledNotification(
            identifier = "routine-due:bot-a:r:1", botId = "bot-a", routineId = "r",
            title = "例行任务到期", body = "", fireAt = 1, deepLink = "phonedsh://bot/bot-a/routine/r",
        )
        try {
            notification.validate()
            fail("empty body must be rejected")
        } catch (error: InvalidRoutineNotification) {
            assertEquals("empty_body", error.reason)
        }
        val wrongBot = notification.copy(
            body = "「x」到点，点开运行。", deepLink = "phonedsh://bot/bot-b/routine/r",
        )
        try {
            wrongBot.validate()
            fail("a deep link for another bot must be rejected")
        } catch (error: InvalidRoutineNotification) {
            assertEquals("wrong_deep_link", error.reason)
        }
        assertEquals(
            JsonString("例行任务到期"),
            notification.toJson().members["title"],
        )
    }
}
