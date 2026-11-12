// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import com.phonedsh.agentcore.JsonNull
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.routines.RoutineJson.number
import com.phonedsh.bot.routines.RoutineJson.string
import com.phonedsh.bot.store.BotEventCodec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * `spec/bot/v2/golden/routine-document.json` (D9 §11, CCR-7).
 *
 * The five positive documents are the Swift encoder's bytes for the frozen
 * fixture values; the test reproduces those values with the real Kotlin models,
 * encodes with the real `DurableSnapshot`, and decodes the golden bytes back.
 * The `new` case is additionally produced by the real `RoutineMachine.create`,
 * so the snapshot shape is not just a re-encoded fixture.
 */
class RoutineDocumentGoldenTest {
    private val botId = "main"
    private val created = 1_760_000_000_000L
    private val firstRun = 1_760_028_000_000L
    private val finished = 1_760_034_000_000L

    private fun runState(
        status: RoutineRunStatus,
        attempt: Int,
        runId: String,
        startedAt: Long,
        finishedAt: Long? = null,
        error: String? = null,
        reconciliation: Boolean = false,
    ): RoutineRunState = RoutineRunState(
        runId = runId,
        attempt = attempt,
        status = status,
        scheduledFor = startedAt,
        startedAt = startedAt,
        finishedAt = finishedAt,
        leaseOwner = if (status == RoutineRunStatus.STARTED) "local" else null,
        leaseExpiresAt = if (status == RoutineRunStatus.STARTED) startedAt + 660_000 else null,
        error = error,
        reconciliationRequired = reconciliation,
    )

    private val newRoutine = Routine(
        id = "daily-digest",
        agentId = "main",
        title = "Daily digest",
        prompt = "Summarize the day.",
        schedule = RoutineSchedule.daily("09:00", "Asia/Shanghai"),
        createdAt = created,
        nextRunAt = 1_760_032_800_000L,
    )

    private val deferredRoutine = newRoutine.copy(
        quietDefer = RoutineQuietDefer(
            until = 1_760_030_000_000L,
            scheduledFor = 1_760_028_000_000L,
            at = 1_760_027_000_000L,
        ),
        nextRunAt = 1_760_030_000_000L,
    )

    private val startedRoutine = newRoutine.copy(
        attempt = 1,
        lastRunAt = firstRun,
        runState = runState(
            RoutineRunStatus.STARTED, attempt = 1, runId = "run-daily-1", startedAt = firstRun,
        ),
    )

    private val needsReconciliationRoutine = startedRoutine.copy(
        runState = runState(
            RoutineRunStatus.NEEDS_RECONCILIATION, attempt = 1, runId = "run-daily-1",
            startedAt = firstRun, finishedAt = finished,
            error = "effect outcome unknown", reconciliation = true,
        ),
        lastResult = RoutineResult(
            status = RoutineRunStatus.NEEDS_RECONCILIATION, text = "",
            error = "effect outcome unknown", startedAt = firstRun, finishedAt = finished,
            durationMs = 6_000_000, scheduledFor = firstRun, lateByMs = 0,
            quiet = false, attempt = 1, runId = "run-daily-1",
        ),
        nextRunAt = null,
    )

    private val delivery = RoutineDelivery(
        deliveryKey = "daily-digest:1", routineId = "daily-digest", agentId = "main",
        attempt = 1, runId = "run-daily-1", status = RoutineDeliveryStatus.PENDING,
        resultStatus = RoutineRunStatus.NEEDS_RECONCILIATION, text = "",
        error = "effect outcome unknown", routineTitle = "Daily digest", context = "routine",
        delivery = RoutineDeliveryMode.HELD, urgent = false, urgentReason = "",
        lateByMs = 0, startedAt = firstRun, finishedAt = finished,
        durationMs = 6_000_000, createdAt = finished, updatedAt = finished, attempts = 0,
    )

    private fun fixture(name: String): Pair<String, RoutineDocument> = when (name) {
        "new" -> "routine.defined" to RoutineDocument(version = 1, routines = listOf(newRoutine))
        "deferred" -> "routine.updated" to RoutineDocument(version = 1, routines = listOf(deferredRoutine))
        "started" -> "routine.updated" to RoutineDocument(version = 1, routines = listOf(startedRoutine))
        "needs-reconciliation" -> "routine.updated" to RoutineDocument(
            version = 1,
            routines = listOf(needsReconciliationRoutine),
            deliveries = mapOf("daily-digest:1" to delivery),
        )
        "deleted" -> "routine.deleted" to RoutineDocument(
            version = 1, routines = emptyList(), deliveries = mapOf("daily-digest:1" to delivery),
        )
        else -> throw AssertionError("missing fixture $name")
    }

    @Test
    fun everyGoldenDocumentIsProducedByTheRealEncoderAndDecodesBack() {
        val golden = V2Golden.load("routine-document")
        val valid = V2Golden.objects(golden, "valid")
        assertEquals(
            listOf("new", "deferred", "started", "needs-reconciliation", "deleted"),
            valid.map { V2Golden.string(it, "name") },
        )
        val seenTypes = ArrayList<String>()
        for (case in valid) {
            val name = V2Golden.string(case, "name")
            val expectedType = V2Golden.string(case, "eventType")
            val (fixtureType, document) = fixture(name)
            assertEquals("$name event type", fixtureType, expectedType)
            seenTypes += expectedType

            val expected = V2Golden.at(case, "data")!!
            val encoded = DurableSnapshot.envelope(document.toJson(), botId)
            assertEquals(
                "$name bytes",
                V2Golden.canonical(expected),
                V2Golden.canonical(encoded),
            )

            val decoded = RoutineDocument.fromJson(V2Golden.at(expected, "document"))
            assertEquals("$name round trip", document, decoded)
        }
        assertEquals(
            listOf("routine.defined", "routine.updated", "routine.updated", "routine.updated", "routine.deleted"),
            seenTypes,
        )
    }

    @Test
    fun liveCreateWritesTheGoldenNewDocument() {
        val golden = V2Golden.load("routine-document")
        val newCase = V2Golden.objects(golden, "valid").first { V2Golden.string(it, "name") == "new" }
        RoutineTestHarness(FakeClock(created)).use { harness ->
            val routine = harness.machine.create(
                botId = botId,
                title = "Daily digest",
                prompt = "Summarize the day.",
                schedule = RoutineSchedule.daily("09:00", "Asia/Shanghai"),
                now = created,
                id = "daily-digest",
            )
            // The golden fixture hard-codes `next_run_at`; the real scheduler
            // derives 2025-10-10 09:00 Asia/Shanghai from the daily rule.
            assertEquals(1_760_058_000_000L, routine.nextRunAt)
            val goldenData = V2Golden.at(newCase, "data") as JsonObject
            val goldenDocument = V2Golden.at(goldenData, "document") as JsonObject
            val goldenRoutine = V2Golden.objects(goldenData, "document", "routines").first() as JsonObject
            val patchedRoutine = JsonObject(
                goldenRoutine.members.toMutableMap().apply {
                    put("next_run_at", number(routine.nextRunAt!!))
                },
            )
            val patchedData = JsonObject(
                goldenData.members.toMutableMap().apply {
                    put(
                        "document",
                        JsonObject(
                            goldenDocument.members.toMutableMap().apply {
                                put("routines", com.phonedsh.agentcore.JsonArray(listOf(patchedRoutine)))
                            },
                        ),
                    )
                },
            )
            val document = harness.routines.read(botId)
            assertEquals(
                "live create snapshot bytes",
                V2Golden.canonical(patchedData),
                V2Golden.canonical(DurableSnapshot.envelope(document.toJson(), botId)),
            )
            val events = harness.domain.events(0, 100)
            assertEquals(listOf("routine.defined"), events.map { it.type })
            assertEquals(botId, V2Golden.string(events.first().data, "botId"))
        }
    }

    @Test
    fun liveBeginWritesTheGoldenRunStateAndItsLifecycleEvents() {
        val golden = V2Golden.load("routine-document")
        val startedCase = V2Golden.objects(golden, "valid")
            .first { V2Golden.string(it, "name") == "started" }
        RoutineTestHarness(FakeClock(created)).use { harness ->
            harness.machine.create(
                botId = botId, title = "Daily digest", prompt = "Summarize the day.",
                schedule = RoutineSchedule.daily("09:00", "Asia/Shanghai"),
                now = created, id = "daily-digest",
            )
            harness.clock.set(firstRun)
            val claim = harness.machine.begin(
                botId = botId, routineId = "daily-digest", startedAt = firstRun,
                scheduledFor = firstRun, leaseOwner = "local", leaseTtlMs = 660_000,
                runId = "run-daily-1",
            )!!
            assertTrue(claim.claimed)

            val goldenRoutine = V2Golden.objects(startedCase, "data", "document", "routines").first()
            val goldenState = V2Golden.at(goldenRoutine, "run_state")!!
            assertEquals(
                "run_state bytes",
                V2Golden.canonical(goldenState),
                V2Golden.canonical(claim.routine.runState!!.toJson()),
            )
            assertEquals(V2Golden.long(goldenRoutine, "attempt"), claim.routine.attempt.toLong())
            assertEquals(V2Golden.long(goldenRoutine, "last_run_at"), claim.routine.lastRunAt)
            assertEquals(1_760_058_000_000L, claim.routine.nextRunAt)
            val events = harness.domain.events(0, 100)
            assertEquals(
                listOf(
                    "routine-snapshot:run-daily-1:1:started",
                    "routine-run-started:run-daily-1:1",
                ),
                events.drop(1).map { it.eventId },
            )
            // The live machine also persists `last_result = started`; the golden
            // fixture (like the Swift encoder test) predates that field.
            assertEquals(RoutineRunStatus.STARTED, claim.routine.lastResult?.status)
        }
    }

    @Test
    fun absentAndExplicitNullAreTheSameRoutineFields() {
        val members = linkedMapOf<String, JsonValue>(
            "id" to string("r"),
            "agentId" to string("main"),
            "title" to string("T"),
            "prompt" to string("P"),
            "schedule" to RoutineSchedule.daily("09:00", "Asia/Shanghai").validated().toJson(),
            "enabled" to com.phonedsh.agentcore.JsonBool(true),
            "idempotent" to com.phonedsh.agentcore.JsonBool(false),
            "urgent" to com.phonedsh.agentcore.JsonBool(false),
            "urgent_reason" to string(""),
            "delivery" to string("held"),
            "interrupt_reason" to string(""),
            "created_at" to number(created),
            "attempt" to number(0),
            "skip_count" to number(0),
            "crash_retry" to com.phonedsh.agentcore.JsonBool(false),
            "run_state" to JsonNull,
            "quiet_defer" to JsonNull,
            "last_skip" to JsonNull,
            "last_run_at" to JsonNull,
            "next_run_at" to JsonNull,
            "last_result" to JsonNull,
        )
        val withNulls = Routine.fromJson(JsonObject(members))
        val without = Routine.fromJson(
            JsonObject(members.filterValues { it !is JsonNull }),
        )
        assertEquals(withNulls, without)
        val encoded = without.toJson().members
        for (key in listOf("run_state", "quiet_defer", "last_skip", "last_run_at", "next_run_at", "last_result")) {
            assertFalse("writer must omit nil $key", encoded.containsKey(key))
        }
        assertNull(without.nextRunAt)
        assertNull(without.runState)
    }

    @Test
    fun theGoldenShapesValidateAgainstTheSchemaFields() {
        val golden = V2Golden.load("routine-document")
        for (case in V2Golden.objects(golden, "valid")) {
            val document = RoutineDocument.fromJson(V2Golden.at(case, "data", "document"))
            // Every routine validates; 1760000000000 is a fixed non-negative time.
            for (routine in document.routines) {
                assertEquals(routine.id.trim(), routine.id)
                assertTrue(routine.attempt >= 0)
                assertTrue(routine.skipCount >= 0)
                assertTrue(routine.createdAt >= 0)
                routine.nextRunAt?.let { assertTrue(it >= 0) }
                assertNotNull(routine.schedule.timezone)
            }
            for ((key, value) in document.deliveries) {
                assertEquals(key, RoutineDelivery.key(value.routineId, value.attempt))
                assertTrue(value.lateByMs >= 0)
                assertTrue(value.durationMs >= 0)
            }
        }
    }

    @Test
    fun anUnsupportedDocumentVersionFailsClosed() {
        val golden = V2Golden.load("routine-document")
        val invalid = V2Golden.objects(golden, "invalid").first()
        try {
            RoutineDocument.fromJson(V2Golden.at(invalid, "data", "document"))
            fail("version 2 must fail closed")
        } catch (error: RoutineError.InvalidRoutine) {
            assertEquals("invalidRoutine", error.code)
            assertTrue(error.message!!.contains("version must be 1"))
        }
        // The same check runs on replay through the P25 store.
        RoutineTestHarness(FakeClock(created)).use { harness ->
            val routine = harness.machine.create(
                botId = botId, title = "T", prompt = "P",
                schedule = RoutineSchedule.daily("09:00", "Asia/Shanghai"),
                now = created, id = "r-1",
            )
            harness.domain.append(harness.snapshot(routine, version = 2, eventId = "routine-snapshot:future"))
            try {
                harness.routines.read(botId)
                fail("stored version 2 must fail closed")
            } catch (error: RoutineError.InvalidRoutine) {
                assertTrue(error.message!!.contains("version must be 1"))
            }
        }
    }

    private fun RoutineTestHarness.snapshot(routine: Routine, version: Int, eventId: String) =
        com.phonedsh.bot.store.BotEvent(
            schemaVersion = BotEventCodec.CURRENT_SCHEMA_VERSION,
            type = "routine.updated",
            eventId = eventId,
            commitSeq = null,
            time = clock.now,
            origin = com.phonedsh.bot.store.BotEventOrigin.Local("scheduler"),
            traceId = "trace:$eventId",
            principal = com.phonedsh.bot.store.BotPrincipal("main", null, "routine", emptyList()),
            causationId = null,
            correlationId = "main",
            data = DurableSnapshot.envelope(
                RoutineDocument(version = version, routines = listOf(routine)).toJson(), "main",
            ),
        )
}
