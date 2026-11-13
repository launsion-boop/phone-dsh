// SPDX-License-Identifier: MIT
package com.phonedsh.bot.watchdog

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Drives the C9 config/unit fixtures through the real Kotlin reader and monitor. */
class BotWatchdogConfigGoldenTest {
    @Test
    fun configVectorsSupplyDefaultsAndRejectFrozenErrors() {
        val vector = fixture("watchdog.phone")
        val configCases = vector.requireObject("configCases")
        val valid = configCases.getValue("valid").arrayOrNull()!!.map { it.asUnitsJson() }
        assertTrue(valid.isNotEmpty())
        for (value in valid) {
            val name = value.members.getValue("name").requiredString()
            val input = value.members.getValue("input").asUnitsJson()
            val expected = value.members.getValue("expect").asUnitsJson()
            assertEquals(name, BotWatchdogConfig.decode(expected), BotWatchdogConfig.decode(input))
        }

        val invalid = configCases.getValue("invalid").arrayOrNull()!!.map { it.asUnitsJson() }
        assertTrue(invalid.isNotEmpty())
        for (value in invalid) {
            val name = value.members.getValue("name").requiredString()
            val input = value.members.getValue("input").asUnitsJson()
            val expected = value.members.getValue("error").asUnitsJson()
            try {
                BotWatchdogConfig.decode(input)
                fail("$name: invalid config unexpectedly decoded")
            } catch (error: BotWatchdogConfigException) {
                assertEquals(name, expected.members.getValue("code").requiredString(), error.code)
                assertEquals(name, expected.members.getValue("path").requiredString(), error.path)
            }
        }
    }

    @Test
    fun upstreamDefaultsAndMobileDescriptorsAreTheFrozenValues() {
        val upstream = fixture("watchdog")
        val valid = upstream.requireObject("valid")
        val config = valid.getValue("config").asUnitsJson()
        assertEquals(BotWatchdogConfig.DEFAULT, BotWatchdogConfig.decode(config))
        assertEquals(
            BotWatchdogConfig.DEFAULT.toJson().members.keys,
            config.members.keys,
        )

        val flagged = valid.getValue("flagged").arrayOrNull()!!.map { it.asUnitsJson() }
        val checks = flagged.map {
            BotWatchdogCheck.fromWire(it.members.getValue("check").requiredString())
                ?: error("unknown frozen check")
        }
        assertEquals(
            BotWatchdogChecks.run(
                BotWatchdogUnit(
                    kind = BotWatchdogUnitKind.TURN,
                    id = "unit",
                    startedAt = 1,
                    lastEventAt = 1,
                    deadlineAt = 1,
                    repeatedToolSignatureCount = 5,
                    lastToolSignature = "tool:digest",
                    repeatedToolErrorCount = 3,
                    lastToolErrorSignature = "tool:error",
                    tokens = 200_001,
                ),
                now = 1_760_000_000_000,
                config = BotWatchdogConfig.DEFAULT,
            ).map { it.check },
            checks,
        )

        val mobile = valid.getValue("mobile").arrayOrNull()!!.map { it.asUnitsJson() }
        assertEquals(BotWatchdogMobileDescriptor.FROZEN.size, mobile.size)
        for ((index, descriptor) in BotWatchdogMobileDescriptor.FROZEN.withIndex()) {
            val expected = mobile[index]
            assertEquals(
                BotWatchdogCheck.fromWire(expected.members.getValue("check").requiredString()),
                descriptor.check,
            )
            assertEquals(
                expected.members.getValue("eventType").requiredString(),
                descriptor.eventType,
            )
            assertTrue(descriptor.observeOnly)
            assertTrue(descriptor.oncePerUnit)
        }

        val invalid = upstream.requireArray("invalid")
        for (value in invalid) {
            val check = value.asUnitsJson().members.getValue("check").requiredString()
            assertNull("$check must not become a watchdog check", BotWatchdogCheck.fromWire(check))
        }
    }

    @Test
    fun unitVectorsDriveRealStartUnitDeadlineAndIdentityRules() {
        val vector = fixture("watchdog.phone")
        val cases = vector.requireObject("unitCases").getValue("valid").arrayOrNull()!!
            .map { it.asUnitsJson() }
        assertTrue(cases.isNotEmpty())
        withTempStore { store, _ ->
            val monitor = BotWatchdogMonitor(store, BotWatchdogConfig.DEFAULT, clock = { 0 })
            for (case in cases) {
                val name = case.members.getValue("name").requiredString()
                val kind = BotWatchdogUnitKind.fromWire(
                    case.members.getValue("kind").requiredString(),
                ) ?: error("unknown kind")
                val id = case.members.getValue("id").requiredString()
                val expected = case.members.getValue("expect").asUnitsJson()
                val flags = monitor.startUnit(
                    kind = kind,
                    id = id,
                    botId = case.members["botId"].stringOrNull(),
                    sessionId = case.members["sessionId"].stringOrNull(),
                    startedAt = case.members["startedAt"].longOrNull(),
                    deadlineOverrideMs = case.members["deadlineOverrideMs"].longOrNull(),
                    at = case.members["at"].longOrNull(),
                )
                assertEquals(name, emptyList<BotWatchdogFlag>(), flags)
                val unit = monitor.unit(kind, id) ?: error("$name: unit missing")
                assertEquals(name, kind, unit.kind)
                assertEquals(name, id, unit.id)
                assertEquals(name, expected.members["botId"].stringOrNull(), unit.botId)
                assertEquals(name, expected.members["sessionId"].stringOrNull(), unit.sessionId)
                assertEquals(
                    name,
                    expected.members.getValue("startedAt").longOrNull(),
                    unit.startedAt,
                )
                assertEquals(
                    name,
                    expected.members.getValue("lastEventAt").longOrNull(),
                    unit.lastEventAt,
                )
                assertEquals(
                    name,
                    expected.members.getValue("deadlineAt").longOrNull(),
                    unit.deadlineAt,
                )
            }
        }
    }
}
