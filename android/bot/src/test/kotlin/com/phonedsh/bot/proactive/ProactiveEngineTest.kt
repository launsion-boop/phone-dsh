// SPDX-License-Identifier: MIT
package com.phonedsh.bot.proactive

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.routines.RoutineDelivery
import com.phonedsh.bot.routines.RoutineDeliveryMode
import com.phonedsh.bot.routines.RoutineInterruptCandidate
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventOrigin
import com.phonedsh.bot.store.BotPrincipal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Behaviour outside the shared vector: CCR-4, CCR-5, fuse boundaries and P18 recovery. */
class ProactiveEngineTest {
    @Test
    fun defaultsKeepTheEngineAndProductionShapesDistinct() {
        val engineDefault = ProactiveSettings()
        assertEquals(ProactiveMode.WOULD, engineDefault.mode)
        assertEquals(900_000L, engineDefault.fuseWindowMs)
        assertEquals(4, engineDefault.fuseMaxWakeups)
        assertEquals(
            listOf(ProactiveKind.TASK_DONE, ProactiveKind.ROUTINE_RESULT),
            engineDefault.deliveryKinds,
        )

        val production = ProactiveSettings.productionDefault()
        assertEquals(ProactiveMode.ON, production.mode)
        assertFalse(production.dnd)
        assertEquals("23:00", production.quietStart)
        assertEquals("08:00", production.quietEnd)
        assertEquals(listOf(ProactiveKind.ROUTINE_RESULT), production.deliveryKinds)
    }

    @Test
    fun persistenceUsesTheExistingKeyAndTheSixMemberBlob() {
        assertEquals(
            "phone-dsh.bot.proactive-settings.v1",
            ProactiveSettingsPersistence.KEY,
        )
        val encoded = ProactiveSettingsPersistence.encode(ProactiveSettings.productionDefault())
        assertEquals(
            setOf("mode", "dnd", "quietStart", "quietEnd", "routineQuietWeekends", "timeZone"),
            encoded.members.keys,
        )

        val decoded = ProactiveSettingsPersistence.decode(encoded)
        assertNotNull(decoded)
        assertEquals(
            ProactiveSettings.productionDefault().mode,
            decoded!!.normalized().toEffective().mode,
        )

        val withUnknown = JsonObject(
            encoded.members + ("cooldown" to JsonNumber("60000")),
        )
        assertNotNull("unknown persisted member is ignored", ProactiveSettingsPersistence.decode(withUnknown))
        assertNull(
            "a missing required member fails decode",
            ProactiveSettingsPersistence.decode(JsonObject(encoded.members - "mode")),
        )

        val recovered = ProactiveSettingsPersistence.decodeOrProductionDefault(
            JsonObject(emptyMap()),
            deliveryKinds = listOf(ProactiveKind.ROUTINE_RESULT),
        )
        assertEquals(ProactiveMode.ON, recovered.mode)
        assertEquals(listOf(ProactiveKind.ROUTINE_RESULT), recovered.deliveryKinds)

        val store = InMemoryProactiveSettingsStore("host.injected.key")
        assertEquals("host.injected.key", store.key)
        assertEquals(ProactiveMode.ON, store.load().mode)
        store.save(ProactiveSettings(mode = ProactiveMode.OFF))
        assertEquals(ProactiveMode.OFF, store.load().mode)
    }

    @Test
    fun fuseWindowIsStrictAndPerBot() {
        val settings = ProactiveSettings(fuseWindowMs = 1_000L, fuseMaxWakeups = 1)
        val candidate = ProactiveCandidate(
            kind = ProactiveKind.TASK_DONE,
            botId = "bot-a",
            createdAt = 0,
            taskId = "task-1",
        )
        val policy = ProactivePolicy()
        policy.record(candidate, now = 0, fuseRecorded = true)

        assertTrue("999 ms is inside the window", policy.fuseTripped("bot-a", 999, settings))
        assertFalse("1000 ms is not strictly inside", policy.fuseTripped("bot-a", 1_000, settings))
        assertFalse("the fuse is per Bot", policy.fuseTripped("bot-b", 999, settings))
    }

    @Test
    fun considerationSinkAndRestoreCarryTheFuseState() {
        val settings = ProactiveSettings(
            mode = ProactiveMode.ON,
            quietStart = "00:00",
            quietEnd = "00:00",
            fuseWindowMs = 1_000L,
            fuseMaxWakeups = 1,
            deliveryKinds = listOf(ProactiveKind.TASK_DONE),
        )
        val now = 5_000L
        val records = ArrayList<Pair<ProactiveDecision, Boolean>>()
        val sink = ProactiveConsiderationSink { _, decision, fuseRecorded ->
            records += decision to fuseRecorded
        }
        val engine = ProactiveEngine(
            settingsProvider = { settings },
            nowProvider = { now },
            deliverer = ProactiveDelivering { ProactiveDeliveryResult(true, it.channel) },
            considerationSink = sink,
        )
        val first = ProactiveCandidate(
            kind = ProactiveKind.TASK_DONE,
            botId = "bot-a",
            createdAt = now,
            taskId = "task-1",
        )
        assertEquals(ProactiveReason.DELIVERED, engine.consider(first).reason)
        assertEquals(1, records.size)
        assertEquals(ProactiveDecisionKind.DID, records.single().first.decision)
        assertTrue("a delivered decision fills the fuse", records.single().second)

        val restarted = ProactiveEngine(
            settingsProvider = { settings },
            nowProvider = { now },
            deliverer = ProactiveDelivering { ProactiveDeliveryResult(true, it.channel) },
        )
        assertEquals(
            1,
            restarted.restoreAccounting(
                listOf(
                    ProactiveConsideration(
                        at = now,
                        kind = ProactiveKind.TASK_DONE,
                        botId = "bot-a",
                        fuseRecorded = true,
                    ),
                ),
            ),
        )
        assertEquals(
            ProactiveReason.FUSE,
            restarted.consider(first.copy(taskId = "task-2")).reason,
        )
    }

    @Test
    fun reminderWithoutRowIdFailsDeliveryAndConsumesNoFuse() {
        val settings = ProactiveSettings(
            mode = ProactiveMode.ON,
            quietStart = "00:00",
            quietEnd = "00:00",
            fuseMaxWakeups = 1,
            deliveryKinds = listOf(ProactiveKind.REMINDER),
        )
        val strictDeliverer = ProactiveDelivering { notification ->
            val rejection = ProactiveDeliveryRequirements.rejection(notification)
            if (rejection != null) throw ProactiveDeliveryException(rejection)
            ProactiveDeliveryResult(true, notification.channel)
        }
        val engine = ProactiveEngine(
            settingsProvider = { settings },
            nowProvider = { 1_000L },
            deliverer = strictDeliverer,
        )

        val missingRow = ProactiveCandidate(
            kind = ProactiveKind.REMINDER,
            botId = "bot-a",
            createdAt = 1_000L,
            reminderId = "rem-1",
            allowDuringDnd = true,
        )
        val failed = engine.consider(missingRow)
        assertEquals(ProactiveDecisionKind.SKIP, failed.decision)
        assertEquals(ProactiveReason.DELIVERY_FAILED, failed.reason)
        assertNull("CCR-5: no row means no deep link", failed.notification.deepLink)
        assertEquals(
            ProactiveDeliveryException.MISSING_DEEP_LINK,
            failed.delivery?.error,
        )
        assertFalse("a failed delivery consumes no fuse", failed.fuseRecorded)

        val withRow = missingRow.copy(reminderId = "rem-2", rowId = "reminder-rem-2")
        val delivered = engine.consider(withRow)
        assertEquals(ProactiveDecisionKind.DID, delivered.decision)
        assertEquals(ProactiveReason.DELIVERED, delivered.reason)
        assertEquals(
            "phonedsh://bot/bot-a/row/reminder-rem-2",
            delivered.notification.deepLink,
        )

        val third = missingRow.copy(reminderId = "rem-3", rowId = "reminder-rem-3")
        assertEquals(
            "the successful delivery, not the failure, fills the fuse",
            ProactiveReason.FUSE,
            engine.consider(third).reason,
        )
    }

    @Test
    fun sourcesOnlyAdaptSuccessfulRoutinesWhileTheSchedulerAdapterCarriesFailure() {
        val settings = ProactiveSettings(
            mode = ProactiveMode.ON,
            quietStart = "00:00",
            quietEnd = "00:00",
            deliveryKinds = listOf(ProactiveKind.ROUTINE_RESULT),
        )
        val sources = ProactiveSources(nowProvider = { 2_000L })
        val failedEvent = routineEvent(
            status = "failed",
            excerpt = "boom",
            deliveryMode = "interrupt",
        )
        assertTrue(
            "CCR-4: ProactiveSources only accepts successful routines",
            sources.candidates(failedEvent).isEmpty(),
        )

        val succeededEvent = routineEvent(
            status = "succeeded",
            excerpt = "第一句。第二句。",
            deliveryMode = "interrupt",
        )
        val adapted = sources.candidates(succeededEvent)
        assertEquals(1, adapted.size)
        assertEquals(ProactiveKind.ROUTINE_RESULT, adapted.single().kind)
        assertEquals("routine-result:daily:run-s:1", adapted.single().dedupeKey)
        assertEquals("第一句。", adapted.single().body)
        assertEquals("routine-run-daily-1", adapted.single().rowId)

        val engine = ProactiveEngine(
            settingsProvider = { settings },
            nowProvider = { 2_000L },
            deliverer = ProactiveDelivering { ProactiveDeliveryResult(true, it.channel) },
        )
        val adapter = ProactiveRoutineInterruptAdapter(engine)
        val schedulerCandidate = RoutineInterruptCandidate(
            id = "routine-result:daily:run-f:1",
            kind = "routine-result",
            botId = "bot-a",
            dedupeKey = "routine-result:daily:run-f:1",
            trigger = "routine.run_finished",
            createdAt = 2_000L,
            title = "晨间简报",
            body = "例行任务「晨间简报」执行失败：boom",
            status = "failed",
            routineId = "daily",
            runId = "run-f",
            attempt = 1,
            delivery = RoutineDeliveryMode.INTERRUPT,
            quiet = false,
            resultExcerpt = "",
            deliveryKey = "daily:1",
            rowId = RoutineDelivery.rowId("daily", 1),
        )
        val decision = adapter.consider(schedulerCandidate)
        assertEquals("on", decision.mode)
        assertEquals("did", decision.decision)
        assertEquals("delivered", decision.reason)
    }

    @Test
    fun proactiveDeepLinksEncodePathSegments() {
        val link = ProactiveDeepLink.make("bot/一", "row 二")
        assertEquals(
            "phonedsh://bot/bot%2F%E4%B8%80/row/row%20%E4%BA%8C",
            link,
        )
        assertEquals("bot/一" to "row 二", ProactiveDeepLink.parse(link))
        assertNull(ProactiveDeepLink.parse("phonedsh://bot/a/routine/b"))
    }

    private fun routineEvent(
        status: String,
        excerpt: String,
        deliveryMode: String,
    ): BotEvent = BotEvent(
        schemaVersion = 1,
        type = "routine.run_finished",
        eventId = "event-$status",
        commitSeq = null,
        time = 2_000L,
        origin = BotEventOrigin.Local("scheduler"),
        traceId = "trace:routine:$status",
        principal = BotPrincipal("bot-a", null, "routine", emptyList()),
        causationId = null,
        correlationId = "daily",
        data = JsonObject(
            linkedMapOf(
                "routineId" to JsonString("daily"),
                "runId" to JsonString(if (status == "failed") "run-f" else "run-s"),
                "attempt" to JsonNumber("1"),
                "status" to JsonString(status),
                "text" to JsonString(excerpt),
                "resultExcerpt" to JsonString(excerpt),
                "quiet" to JsonBool(false),
                "delivery" to JsonString(deliveryMode),
                "deliveryKey" to JsonString("daily:1"),
                "proactiveHandled" to JsonBool(false),
            ),
        ),
    )
}
