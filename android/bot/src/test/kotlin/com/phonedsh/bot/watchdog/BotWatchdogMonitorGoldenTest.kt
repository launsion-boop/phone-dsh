// SPDX-License-Identifier: MIT
package com.phonedsh.bot.watchdog

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.bot.store.BotDomainStore
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventOrigin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Runs the C9 monitor scenarios and flag payloads through the real store. */
class BotWatchdogMonitorGoldenTest {
    @Test
    fun monitorVectorsAndFlagPayloadsDriveRealMonitorAndStore() {
        val vector = fixture("watchdog.phone")
        val scenarios = vector.requireArray("monitorCases").map { it.asUnitsJson() }
        val eventsById = LinkedHashMap<String, BotEvent>()

        for (scenario in scenarios) {
            val name = scenario.members.getValue("name").requiredString()
            val config = BotWatchdogConfig.decode(scenario.members.getValue("config"))
            withTempStore { store, _ ->
                val monitor = BotWatchdogMonitor(store, config, clock = { 0 })
                val steps = scenario.requireArray("steps").map { it.asUnitsJson() }
                for ((stepIndex, step) in steps.withIndex()) {
                    val context = "$name.steps[$stepIndex]"
                    val op = step.members.getValue("op").requiredString()
                    val kind = step.members["kind"].stringOrNull()?.let {
                        BotWatchdogUnitKind.fromWire(it) ?: error("$context: unknown kind")
                    }
                    val at = step.members["at"].longOrNull()
                    val flags = when (op) {
                        "start" -> monitor.startUnit(
                            kind = kind!!,
                            id = step.members.getValue("id").requiredString(),
                            botId = step.members["botId"].stringOrNull(),
                            sessionId = step.members["sessionId"].stringOrNull(),
                            startedAt = step.members["startedAt"].longOrNull(),
                            deadlineOverrideMs = step.members["deadlineOverrideMs"].longOrNull(),
                            at = at,
                        )
                        "tick" -> monitor.tick(at)
                        "finish" -> {
                            monitor.finishUnit(
                                kind!!,
                                step.members.getValue("id").requiredString(),
                            )
                            emptyList()
                        }
                        "mobile" -> monitor.observeMobile(
                            event = BotMobileWatchdogEvent.fromWire(
                                step.members.getValue("event").requiredString(),
                            ) ?: error("$context: unknown mobile event"),
                            kind = kind!!,
                            id = step.members.getValue("id").requiredString(),
                            botId = step.members["botId"].stringOrNull(),
                            sessionId = step.members["sessionId"].stringOrNull(),
                            evidence = step.members["evidence"].evidenceObject(),
                            at = at,
                        )
                        "toolCall" -> monitor.observeToolCall(
                            kind = kind!!,
                            id = step.members.getValue("id").requiredString(),
                            name = step.members.getValue("name").requiredString(),
                            argumentsDigest = step.members["digest"].stringOrNull(),
                            callId = step.members["callId"].stringOrNull(),
                            at = at,
                        )
                        "toolResult" -> monitor.observeToolResult(
                            kind = kind!!,
                            id = step.members.getValue("id").requiredString(),
                            name = step.members["name"].stringOrNull(),
                            status = step.members.getValue("status").requiredString(),
                            error = step.members["error"].stringOrNull(),
                            resultDigest = step.members["resultDigest"].stringOrNull(),
                            callId = step.members["callId"].stringOrNull(),
                            at = at,
                        )
                        "usage" -> monitor.observeUsage(
                            kind = kind!!,
                            id = step.members.getValue("id").requiredString(),
                            tokens = step.members["tokens"].longOrNull() ?: 0,
                            costUsd = step.members["costUsd"].doubleOrNull() ?: 0.0,
                            at = at,
                        )
                        else -> error("$context: unknown op $op")
                    }
                    val expectedChecks = step.requireArray("expectChecks")
                        .map { it.requiredString() }
                    assertEquals(context, expectedChecks, flags.map { it.check.wireValue })

                    val expectedUnit = step.members["expectUnit"]
                    if (expectedUnit != null) {
                        val unit = monitor.unit(
                            kind!!,
                            step.members.getValue("id").requiredString(),
                        )
                        if (expectedUnit is com.phonedsh.agentcore.JsonNull) {
                            assertNull(context, unit)
                        } else {
                            val expected = expectedUnit.asUnitsJson()
                            assertTrue("$context: unit missing", unit != null)
                            assertEquals(
                                context,
                                BotWatchdogUnitKind.fromWire(
                                    expected.members.getValue("kind").requiredString(),
                                ),
                                unit!!.kind,
                            )
                            assertEquals(
                                context,
                                expected.members.getValue("id").requiredString(),
                                unit.id,
                            )
                            assertEquals(
                                context,
                                expected.members["botId"].stringOrNull(),
                                unit.botId,
                            )
                            assertEquals(
                                context,
                                expected.members["sessionId"].stringOrNull(),
                                unit.sessionId,
                            )
                            assertEquals(
                                context,
                                expected.members.getValue("startedAt").longOrNull(),
                                unit.startedAt,
                            )
                            assertEquals(
                                context,
                                expected.members.getValue("lastEventAt").longOrNull(),
                                unit.lastEventAt,
                            )
                            assertEquals(
                                context,
                                expected.members.getValue("deadlineAt").longOrNull(),
                                unit.deadlineAt,
                            )
                        }
                    }
                }
                for (event in store.events(0, 1_000)) eventsById[event.eventId] = event
            }
        }

        val payloadCases = vector.requireArray("flagPayloadCases").map { it.asUnitsJson() }
        val covered = HashSet<String>()
        for (case in payloadCases) {
            val name = case.members.getValue("name").requiredString()
            val eventId = case.members.getValue("eventId").requiredString()
            val expected = case.members.getValue("expect").asUnitsJson()
            val event = eventsById[eventId] ?: error("$name: missing durable event $eventId")
            assertEquals(name, "watchdog.flagged", event.type)
            assertEquals(name, BotEventOrigin.Local("watchdog"), event.origin)
            assertEquals(name, "watchdog", event.principal.kind)
            assertEquals(
                name,
                expected.members["botId"].stringOrNull(),
                event.principal.botId,
            )
            assertEquals(
                name,
                expected.members["sessionId"].stringOrNull(),
                event.principal.sessionId,
            )
            assertEquals(name, expected.members.getValue("unitId").requiredString(), event.correlationId)
            assertEquals(name, "trace:watchdog:$eventId", event.traceId)
            assertEquals(
                name,
                expected.members.getValue("at").longOrNull(),
                event.time,
            )
            assertCanonicalEquals(expected, event.data, "$name payload")
            covered += eventId
        }
        assertEquals(covered, eventsById.keys)
    }

    @Test
    fun unavailableMobileReadingsDoNotFabricateAFlag() {
        withTempStore { store, _ ->
            val monitor = BotWatchdogMonitor(
                store,
                BotWatchdogConfig.DEFAULT.copy(heartbeatTimeoutMs = 0, turnDeadlineMs = 0),
                clock = { 1 },
            )
            assertEquals(
                emptyList<BotWatchdogFlag>(),
                monitor.observeMobile(
                    BotMobileWatchdogEvent.THERMAL_PRESSURE,
                    BotWatchdogUnitKind.TURN,
                    "unit-unavailable",
                    evidence = emptyMap(),
                    at = 1,
                ),
            )
            assertEquals(
                emptyList<BotWatchdogFlag>(),
                monitor.observeMobile(
                    BotMobileWatchdogEvent.BATTERY_PRESSURE,
                    BotWatchdogUnitKind.TURN,
                    "unit-unavailable",
                    evidence = emptyMap(),
                    at = 2,
                ),
            )
            val unavailablePort = BotMobileWatchdogSignalPort { null }
            assertEquals(
                emptyList<BotWatchdogFlag>(),
                monitor.observeMobile(
                    unavailablePort,
                    BotMobileWatchdogEvent.THERMAL_PRESSURE,
                    BotWatchdogUnitKind.TURN,
                    "unit-unavailable",
                    at = 3,
                ),
            )
            assertEquals(0L, store.headCommitSeq())

            val terminated = monitor.observeMobile(
                BotMobileWatchdogEvent.WEBCONTENT_TERMINATED,
                BotWatchdogUnitKind.TURN,
                "unit-unavailable",
                evidence = emptyMap(),
                at = 4,
            )
            assertEquals(
                listOf(BotWatchdogCheck.WEBCONTENT_TERMINATED),
                terminated.map { it.check },
            )
        }
    }

    @Test
    fun appendFailureReleasesPendingForTheNextTick() {
        val failing = FailingEventLog(failures = mutableMapOf(
            "watchdog.flagged:turn:unit-failure:deadline" to 1,
        ))
        val config = BotWatchdogConfig(
            heartbeatTimeoutMs = 1,
            turnDeadlineMs = 1,
            maxUnitTokens = 0,
            maxUnitCostUsd = 0.0,
        )
        val monitor = BotWatchdogMonitor(failing, config, clock = { 0 })
        assertEquals(
            emptyList<BotWatchdogFlag>(),
            monitor.startUnit(BotWatchdogUnitKind.TURN, "unit-failure", at = 0),
        )

        assertEquals(
            listOf(BotWatchdogCheck.HEARTBEAT),
            monitor.tick(at = 2).map { it.check },
        )
        assertTrue(!monitor.hasFlagged(BotWatchdogUnitKind.TURN, "unit-failure", BotWatchdogCheck.DEADLINE))
        assertTrue(monitor.hasFlagged(BotWatchdogUnitKind.TURN, "unit-failure", BotWatchdogCheck.HEARTBEAT))
        assertEquals(
            1,
            failing.attempts["watchdog.flagged:turn:unit-failure:deadline"],
        )
        assertEquals(
            listOf(BotWatchdogCheck.DEADLINE),
            monitor.tick(at = 3).map { it.check },
        )
        assertEquals(
            2,
            failing.attempts["watchdog.flagged:turn:unit-failure:deadline"],
        )
        assertEquals(emptyList<BotWatchdogFlag>(), monitor.tick(at = 4))
        assertEquals(
            listOf(
                "watchdog.flagged:turn:unit-failure:heartbeat",
                "watchdog.flagged:turn:unit-failure:deadline",
            ),
            failing.stored.map { it.eventId },
        )
    }

    @Test
    fun sameCheckIsSingleFlightAcrossThreads() {
        withTempStore { store, _ ->
            val monitor = BotWatchdogMonitor(store, BotWatchdogConfig.DEFAULT, clock = { 1 })
            val start = java.util.concurrent.CountDownLatch(1)
            val results = java.util.Collections.synchronizedList(ArrayList<BotWatchdogFlag>())
            val threads = (0 until 16).map {
                Thread {
                    start.await()
                    results += monitor.observeMobile(
                        BotMobileWatchdogEvent.THERMAL_PRESSURE,
                        BotWatchdogUnitKind.TURN,
                        "unit-concurrent",
                        evidence = mapOf("status" to com.phonedsh.agentcore.JsonString("severe")),
                        at = 1,
                    )
                }
            }
            threads.forEach(Thread::start)
            start.countDown()
            threads.forEach(Thread::join)
            assertEquals(1, results.size)
            assertEquals(1L, store.headCommitSeq())
            assertEquals(
                "watchdog.flagged:turn:unit-concurrent:thermal_pressure",
                results.single().eventId,
            )
        }
    }

    @Test
    fun aSecondMonitorReplaysDurableIdentityWithoutAppending() {
        val directory = Files.createTempDirectory("bot-watchdog-replay").toFile()
        val file = File(directory, "domain.sqlite")
        try {
            val first = BotDomainStore(
                com.phonedsh.bot.store.SqliteJdbcDriver(file.absolutePath),
                clock = { 1 },
            )
            try {
                val monitor = BotWatchdogMonitor(first, BotWatchdogConfig.DEFAULT, clock = { 1 })
                assertEquals(
                    listOf(BotWatchdogCheck.WEBCONTENT_TERMINATED),
                    monitor.observeMobile(
                        BotMobileWatchdogEvent.WEBCONTENT_TERMINATED,
                        BotWatchdogUnitKind.TURN,
                        "unit-shared",
                        at = 1,
                    ).map { it.check },
                )
            } finally {
                first.close()
            }
            val second = BotDomainStore(
                com.phonedsh.bot.store.SqliteJdbcDriver(file.absolutePath),
                clock = { 2 },
            )
            try {
                val monitor = BotWatchdogMonitor(second, BotWatchdogConfig.DEFAULT, clock = { 2 })
                assertEquals(
                    emptyList<BotWatchdogFlag>(),
                    monitor.observeMobile(
                        BotMobileWatchdogEvent.WEBCONTENT_TERMINATED,
                        BotWatchdogUnitKind.TURN,
                        "unit-shared",
                        at = 2,
                    ),
                )
                assertTrue(
                    monitor.hasFlagged(
                        BotWatchdogUnitKind.TURN,
                        "unit-shared",
                        BotWatchdogCheck.WEBCONTENT_TERMINATED,
                    ),
                )
                assertEquals(1L, second.headCommitSeq())
                assertEquals(emptyList<BotWatchdogFlag>(), monitor.flags())
            } finally {
                second.close()
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun historyAndUnitLimitsFollowTheFrozenConfig() {
        withTempStore { store, _ ->
            val config = BotWatchdogConfig(
                heartbeatTimeoutMs = 0,
                turnDeadlineMs = 0,
                taskDeadlineMs = 0,
                routineDeadlineMs = 0,
                historyLimit = 2,
                maxUnits = 1,
            )
            val monitor = BotWatchdogMonitor(store, config, clock = { 1 })
            monitor.startUnit(BotWatchdogUnitKind.TURN, "old", at = 100)
            monitor.startUnit(BotWatchdogUnitKind.TURN, "new", at = 200)
            assertNull(monitor.unit(BotWatchdogUnitKind.TURN, "old"))
            assertTrue(monitor.unit(BotWatchdogUnitKind.TURN, "new") != null)

            for ((index, event) in listOf(
                BotMobileWatchdogEvent.WEBCONTENT_TERMINATED,
                BotMobileWatchdogEvent.THERMAL_PRESSURE,
                BotMobileWatchdogEvent.BATTERY_PRESSURE,
            ).withIndex()) {
                monitor.observeMobile(
                    event,
                    BotWatchdogUnitKind.TURN,
                    "history",
                    evidence = if (event == BotMobileWatchdogEvent.WEBCONTENT_TERMINATED) {
                        emptyMap()
                    } else {
                        mapOf("reading" to com.phonedsh.agentcore.JsonNumber("$index"))
                    },
                    at = 300L + index,
                )
            }
            assertEquals(2, monitor.flags().size)
            assertEquals(BotWatchdogCheck.BATTERY_PRESSURE, monitor.flags().first().check)
            assertEquals(1, monitor.flags(1).size)
            assertEquals(emptyList<BotWatchdogFlag>(), monitor.flags(0))
        }
        withTempStore { store, _ ->
            val monitor = BotWatchdogMonitor(
                store,
                BotWatchdogConfig(heartbeatTimeoutMs = 0, turnDeadlineMs = 0, historyLimit = 0),
                clock = { 1 },
            )
            monitor.observeMobile(
                BotMobileWatchdogEvent.WEBCONTENT_TERMINATED,
                BotWatchdogUnitKind.TURN,
                "history-zero",
                at = 1,
            )
            assertEquals(emptyList<BotWatchdogFlag>(), monitor.flags())
        }
    }

    @Test
    fun longEventIdsUseTheFrozenDigestForm() {
        withTempStore { store, _ ->
            val monitor = BotWatchdogMonitor(store, BotWatchdogConfig.DEFAULT, clock = { 1 })
            val id = "x".repeat(500)
            val flag = monitor.observeMobile(
                BotMobileWatchdogEvent.WEBCONTENT_TERMINATED,
                BotWatchdogUnitKind.TURN,
                id,
                at = 1,
            ).single()
            assertTrue(flag.eventId.length < 400)
            val parts = flag.eventId.split(":")
            assertEquals(listOf("watchdog.flagged", "turn"), parts.take(2))
            assertEquals("webcontent_terminated", parts.last())
            assertEquals(32, parts[2].length)
            assertTrue(parts[2].all { it in "0123456789abcdef" })
            val raw = "watchdog.flagged:turn:$id:webcontent_terminated"
            val digest = java.security.MessageDigest.getInstance("SHA-256")
                .digest(raw.toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }
            assertEquals(
                "watchdog.flagged:turn:${digest.take(32)}:webcontent_terminated",
                flag.eventId,
            )
        }
    }

    private class FailingEventLog(
        val failures: MutableMap<String, Int>,
    ) : BotWatchdogEventLog {
        val stored = ArrayList<BotEvent>()
        val attempts = HashMap<String, Int>()

        override fun append(event: BotEvent): Long {
            attempts[event.eventId] = (attempts[event.eventId] ?: 0) + 1
            val remaining = failures[event.eventId] ?: 0
            if (remaining > 0) {
                failures[event.eventId] = remaining - 1
                throw IllegalStateException("injected append failure")
            }
            val existing = stored.firstOrNull { it.eventId == event.eventId }
            if (existing != null) return existing.commitSeq ?: 0
            val sequence = stored.size + 1L
            stored += event.copy(commitSeq = sequence)
            return sequence
        }

        override fun event(eventId: String): BotEvent? = stored.firstOrNull { it.eventId == eventId }
    }
}
