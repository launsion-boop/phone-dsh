// SPDX-License-Identifier: MIT
package com.phonedsh.bot.fish

import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.GoldenFixture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Drives the real `BotFishDirector` reducer with the `fish-director.json`
 * sequence read from disk: one test input per recorded step, no copied state.
 */
class BotFishDirectorGoldenTest {
    @Test
    fun everyGoldenDirectorStepMatchesTheReducer() {
        val fixture = GoldenFixture.rawObject("fish-director")
        val valid = GoldenFixture.objectValue(fixture, "valid")
        var state = BotFishDirectorState.fromInitialJson(GoldenFixture.objectValue(valid, "initial"))
        val steps = GoldenFixture.objects(valid, "steps")
        assertTrue("fish-director.valid.steps must not be empty", steps.isNotEmpty())
        for ((index, step) in steps.withIndex()) {
            val action = GoldenFixture.requireString(step, "action")
            val event = GoldenFixture.objectValue(step, "event")
            val time = GoldenFixture.requireLong(event, "time")
            val result = when (action) {
                "reduce" -> {
                    val type = GoldenFixture.requireString(event, "type")
                    val data = (GoldenFixture.at(event, "data") as? JsonObject)?.members ?: emptyMap()
                    BotFishDirector.reduce(state, BotFishEvent(type, time, data))
                }
                "expire" -> BotFishDirector.expireOneShot(state, time)
                "lifecycle" -> {
                    val lifecycle = BotFishLifecycle.fromWire(
                        GoldenFixture.requireString(event, "lifecycle"))
                        ?: throw AssertionError("step $index has an unknown lifecycle")
                    BotFishDirector.setLifecycle(state, lifecycle, time)
                }
                else -> throw AssertionError("step $index has unknown action $action")
            }
            state = result.directorState
            val expected = GoldenFixture.objectValue(step, "expected")
            assertEquals("step $index directorState", GoldenFixture.canonical(
                GoldenFixture.objectValue(expected, "directorState")),
                GoldenFixture.canonical(state.toJson()))
            val expectedCommand = GoldenFixture.at(expected, "command")
            if (expectedCommand is JsonNull) {
                assertNull("step $index command", result.command)
            } else {
                assertNotNull("step $index command", result.command)
                assertEquals("step $index command",
                    GoldenFixture.canonical(expectedCommand!!),
                    GoldenFixture.canonical(result.command!!.toJson()))
            }
        }
    }

    @Test
    fun everyGoldenInvalidDirectorCaseIsIgnoredWithoutStateChange() {
        val fixture = GoldenFixture.rawObject("fish-director")
        val invalid = GoldenFixture.objects(fixture, "invalid")
        assertTrue("fish-director.invalid must not be empty", invalid.isNotEmpty())
        val initial = BotFishDirectorState.fromInitialJson(
            GoldenFixture.objectValue(GoldenFixture.objectValue(fixture, "valid"), "initial"))
        for ((index, vector) in invalid.withIndex()) {
            val event = GoldenFixture.objectValue(vector, "event")
            val time = GoldenFixture.requireLong(event, "time")
            val type = GoldenFixture.requireString(event, "type")
            val data = (GoldenFixture.at(event, "data") as? JsonObject)?.members ?: emptyMap()
            val result = BotFishDirector.reduce(initial, BotFishEvent(type, time, data))
            assertEquals("invalid[$index] state was ignored",
                GoldenFixture.canonical(initial.toJson()),
                GoldenFixture.canonical(result.directorState.toJson()))
            assertNull("invalid[$index] no command", result.command)
            assertEquals("ignored_without_state_change",
                GoldenFixture.requireString(vector, "expected"))
        }
    }

    @Test
    fun lifecycleVocabularyRoundTripsThroughItsWireNames() {
        var seen = 0
        for (lifecycle in BotFishLifecycle.entries) {
            assertTrue("${lifecycle.name} wire name", lifecycle.wire.isNotEmpty())
            assertEquals(lifecycle, BotFishLifecycle.fromWire(lifecycle.wire))
            assertTrue("${lifecycle.name} priority", BotFishDirector.priority(lifecycle) >= 0)
            seen++
        }
        assertEquals(BotFishLifecycle.entries.size, seen)
    }
}
