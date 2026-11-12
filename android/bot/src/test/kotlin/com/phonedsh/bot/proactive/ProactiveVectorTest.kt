// SPDX-License-Identifier: MIT
package com.phonedsh.bot.proactive

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import com.phonedsh.bot.GoldenFixture
import com.phonedsh.bot.routines.RoutineScheduledNotification
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.file.Files

/**
 * Drives `spec/bot/v2/golden/proactive.json` through the real settings codec,
 * candidate validator, engine and routine-due builder. Every expected value is
 * read from the shared fixture; this test contains no copied vector.
 */
class ProactiveVectorTest {
    private val fixture: JsonObject = JsonValue.parse(
        Files.readString(GoldenFixture.repoRoot.resolve("spec/bot/v2/golden/proactive.json")),
    ) as JsonObject

    @Test
    fun settingsVectorsCoverEveryValidAndInvalidDocument() {
        val valid = objectValue(fixture, "settings", "valid").members
        assertEquals("valid settings", 4, valid.size)
        for ((name, value) in valid) {
            val settings = ProactiveSettings.fromJson(value)
            assertEquals(
                "$name canonical round-trip",
                canonical(value),
                canonical(settings.toJson()),
            )
            assertEquals("$name normalization is a no-op", settings, settings.normalized())
        }

        val invalid = arrayValue(fixture, "settings", "invalid")
        assertEquals("invalid settings", 11, invalid.size)
        for ((index, entry) in invalid.withIndex()) {
            val case = entry as JsonObject
            val document = case.members.getValue("settings")
            val error = try {
                ProactiveSettings.fromJson(document)
                fail("invalid settings[$index] was accepted")
                error("unreachable")
            } catch (failure: ProactiveSettingsException) {
                failure
            }
            assertEquals("invalid settings[$index] code", string(case, "error"), error.code)
            assertEquals("invalid settings[$index] path", string(case, "path"), error.path)

            when (string(case, "recovery")) {
                "decode-fails" -> assertNull(
                    "invalid settings[$index] must fail persistence decode",
                    ProactivePersistedSettings.fromJson(document),
                )
                "decode-ignores" -> assertNotNull(
                    "invalid settings[$index] unknown member must be ignored by persistence",
                    ProactivePersistedSettings.fromJson(document),
                )
                "normalize" -> {
                    val persisted = ProactivePersistedSettings.fromJson(document)
                        ?: throw AssertionError("invalid settings[$index] must decode")
                    assertNormalizedFields(
                        case.members.getValue("normalized") as JsonObject,
                        persisted.normalized(),
                        case.members.getValue("settings") as JsonObject,
                    )
                }
                "contract-only" -> Unit
                else -> throw AssertionError("invalid settings[$index] unknown recovery")
            }
        }

        val normalization = arrayValue(fixture, "settings", "normalization")
        assertEquals("normalization cases", 2, normalization.size)
        for ((index, entry) in normalization.withIndex()) {
            val case = entry as JsonObject
            val input = case.members.getValue("input") as JsonObject
            val persisted = ProactivePersistedSettings.fromJson(input)
                ?: throw AssertionError("normalization[$index] must decode")
            assertNormalizedFields(
                case.members.getValue("expect") as JsonObject,
                persisted.normalized(),
                input,
            )
        }
    }

    @Test
    fun everyDecisionStepMatchesTheReferenceChain() {
        val cases = arrayValue(fixture, "decisions", "valid")
        assertEquals("valid decision cases", 15, cases.size)
        var steps = 0
        for ((caseIndex, entry) in cases.withIndex()) {
            val case = entry as JsonObject
            val settings = ProactiveSettings.fromJson(case.members.getValue("settings"))
            val stepValues = arrayValue(case, "steps")
            val configs = stepValues.map { resolveDeliverer(case, it as JsonObject) }
            if (configs.any(::isNone) && !configs.all(::isNone)) {
                throw AssertionError("case $caseIndex mixes unavailable and active deliverers")
            }
            val noDeliverer = configs.all(::isNone)

            var now = 0L
            val fake = VectorDeliverer()
            val engine = ProactiveEngine(
                settingsProvider = { settings },
                nowProvider = { now },
                deliverer = if (noDeliverer) null else fake,
            )
            for ((stepIndex, stepValue) in stepValues.withIndex()) {
                val step = stepValue as JsonObject
                now = long(step, "at")
                fake.config = configs[stepIndex]
                val candidate = ProactiveCandidate.fromJson(step.members.getValue("candidate"))
                val decision = engine.consider(candidate)
                assertEquals(
                    "case ${string(case, "name")} step ${stepIndex + 1}",
                    canonical(step.members.getValue("expect")),
                    canonical(decision.toJson()),
                )
                steps += 1
            }
        }
        assertEquals("decision steps", 38, steps)
    }

    @Test
    fun everyInvalidCandidateIsRejectedWithTheGoldenCodeAndPath() {
        val cases = arrayValue(fixture, "decisions", "invalid")
        assertEquals("invalid candidate cases", 5, cases.size)
        for ((index, entry) in cases.withIndex()) {
            val case = entry as JsonObject
            ProactiveSettings.fromJson(case.members.getValue("settings"))
            val error = try {
                ProactiveCandidate.fromJson(case.members.getValue("candidate"))
                fail("invalid candidate[$index] was accepted")
                error("unreachable")
            } catch (failure: ProactiveCandidateException) {
                failure
            }
            assertEquals("invalid candidate[$index] code", string(case, "error"), error.code)
            assertEquals("invalid candidate[$index] path", string(case, "path"), error.path)
        }
    }

    @Test
    fun routineDueUsesTheFrozenLocalNotificationShapeAndConsumesNoFuse() {
        val cases = arrayValue(fixture, "routineDue", "cases")
        assertEquals("routine-due cases", 1, cases.size)
        for ((index, entry) in cases.withIndex()) {
            val case = entry as JsonObject
            val input = case.members.getValue("input") as JsonObject
            val expected = case.members.getValue("expect") as JsonObject
            val notification = ProactiveRoutineDue.notification(
                botId = string(input, "botId"),
                routineId = string(input, "routineId"),
                routineTitle = string(input, "routineTitle"),
                fireAt = long(input, "fireAt"),
            )
            assertEquals(
                "routineDue[$index]",
                canonical(expected),
                canonical(notification.toJson()),
            )
            assertFalse("routineDue[$index] is not proactive", bool(case, "proactive"))
            assertFalse("routineDue[$index] consumes no fuse", bool(case, "consumesFuse"))

            val scheduling = RecordingLocalScheduling()
            val scheduled = ProactiveRoutineDue.schedule(
                scheduling,
                botId = string(input, "botId"),
                routineId = string(input, "routineId"),
                routineTitle = string(input, "routineTitle"),
                fireAt = long(input, "fireAt"),
            )
            assertEquals(notification, scheduled)
            assertEquals(listOf(notification), scheduling.scheduled)
        }
    }

    private fun assertNormalizedFields(
        expected: JsonObject,
        actual: ProactivePersistedSettings,
        input: JsonObject,
    ) {
        for ((field, wanted) in expected.members) {
            val text = (wanted as JsonString).value
            val actualValue = when (field) {
                "quietStart" -> actual.quietStart
                "quietEnd" -> actual.quietEnd
                "timeZone" -> actual.timeZone
                else -> throw AssertionError("unexpected normalized field $field")
            }
            if (text == "<current>") {
                assertNotEquals("$field must fall back", string(input, field), actualValue)
                assertTrue("$field fallback must be non-empty", actualValue.isNotBlank())
            } else {
                assertEquals(field, text, actualValue)
            }
        }
    }

    private fun resolveDeliverer(case: JsonObject, step: JsonObject): JsonValue? =
        step.members["deliverer"] ?: case.members["deliverer"]

    private fun isNone(config: JsonValue?): Boolean =
        config is JsonString && config.value == "none"

    private class VectorDeliverer : ProactiveDelivering {
        var config: JsonValue? = null
        val delivered: MutableList<ProactiveNotification> = ArrayList()

        override fun deliver(notification: ProactiveNotification): ProactiveDeliveryResult {
            delivered += notification
            val value = config
            if (value is JsonObject) {
                val throwText = (value.members["throw"] as? JsonString)?.value
                if (throwText != null) throw ProactiveDeliveryException(throwText)
                return ProactiveDeliveryResult(
                    delivered = (value.members["delivered"] as? JsonBool)?.value ?: true,
                    channel = (value.members["channel"] as? JsonString)?.value
                        ?: "system-notification",
                    error = (value.members["error"] as? JsonString)?.value,
                )
            }
            return ProactiveDeliveryResult(true, notification.channel)
        }
    }

    private class RecordingLocalScheduling : LocalNotificationScheduling {
        val scheduled: MutableList<RoutineScheduledNotification> = ArrayList()

        override fun schedule(notification: RoutineScheduledNotification) {
            scheduled += notification
        }

        override fun pendingIdentifiers(prefix: String): List<String> =
            scheduled.map { it.identifier }.filter { it.startsWith(prefix) }

        override fun cancel(identifiers: List<String>) {
            scheduled.removeAll { it.identifier in identifiers }
        }
    }

    private fun objectValue(value: JsonValue, vararg path: String): JsonObject =
        at(value, *path) as? JsonObject
            ?: throw AssertionError("missing object at ${path.joinToString(".")}")

    private fun arrayValue(value: JsonValue, vararg path: String): List<JsonValue> =
        (at(value, *path) as? JsonArray)?.values
            ?: throw AssertionError("missing array at ${path.joinToString(".")}")

    private fun at(value: JsonValue, vararg path: String): JsonValue? {
        var current: JsonValue? = value
        for (key in path) {
            current = (current as? JsonObject)?.members?.get(key) ?: return null
        }
        return current
    }

    private fun string(value: JsonValue, vararg path: String): String {
        val found = at(value, *path) as? JsonString
            ?: throw AssertionError("missing string at ${path.joinToString(".")}")
        return found.value
    }

    private fun long(value: JsonValue, vararg path: String): Long {
        val found = at(value, *path) as? JsonNumber
            ?: throw AssertionError("missing number at ${path.joinToString(".")}")
        return found.asLongOrNull()
            ?: throw AssertionError("not an integer at ${path.joinToString(".")}")
    }

    private fun bool(value: JsonValue, vararg path: String): Boolean {
        val found = at(value, *path) as? JsonBool
            ?: throw AssertionError("missing boolean at ${path.joinToString(".")}")
        return found.value
    }

    private fun canonical(value: JsonValue): String = BotJson.canonical(value)
}
