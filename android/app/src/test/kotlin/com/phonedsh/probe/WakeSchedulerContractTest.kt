// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import com.phonedsh.agentcore.JsonArray
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.probe.outbox.HostSpec
import com.phonedsh.probe.outbox.bool
import com.phonedsh.probe.outbox.child
import com.phonedsh.probe.outbox.long
import com.phonedsh.probe.outbox.objects
import com.phonedsh.probe.outbox.string
import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class WakeSchedulerContractTest {
    @get:Rule val temporary = TemporaryFolder()
    private val fixture = HostSpec.goldenInstance("engine-launch.json")

    @Test
    fun projectionsMatchSharedVectors() {
        assertEquals(
            fixture.child("constants").long("minBackgroundDelayMs"),
            WakeProjection.MIN_BACKGROUND_DELAY_MS,
        )
        for (vector in fixture.objects("projectionVectors")) {
            val input = vector.child("input")
            val expected = vector.child("expected")
            val result = plan(input)
            assertEquals(vector.string("id"), expected.numberOrNull("residentTimerAtMs"), result.residentTimerAtMs)
            assertEquals(vector.string("id"), expected.numberOrNull("backgroundEarliestMs"), result.backgroundEarliestMs)
            val due = expected.objects("dueNow").map {
                WakeDemandKey(WakeDemandSource.valueOf(it.string("source")), it.string("key"))
            }
            assertEquals(vector.string("id"), due, result.dueNow)
        }
    }

    @Test
    fun rejectsInvalidSharedProjections() {
        for (vector in fixture.objects("invalidProjectionVectors")) {
            assertThrows(vector.string("id"), RuntimeException::class.java) {
                plan(vector.child("input"))
            }
        }
    }

    @Test
    fun stepBudgetMatchesSharedVectors() {
        val constants = fixture.child("constants")
        assertEquals(constants.long("parkMarginMs"), ReadySweepStep.PARK_MARGIN_MS)
        assertEquals(
            (fixture["steps"] as JsonArray).values.map { (it as JsonString).value },
            ReadySweepStep.entries.map { it.name },
        )
        for (vector in fixture.objects("sweepVectors")) {
            val step = ReadySweepStep.valueOf(vector.string("step"))
            assertEquals(constants.child("stepBudgetMs").long(step.name), step.budgetMs)
            assertEquals(vector.string("id"), vector.string("expected") == "run", step.canRun(vector.long("remainingMs")))
        }
    }

    @Test
    fun sweepStopsStartingStepsWhenItsWindowCloses() = runBlocking {
        val steps = mutableListOf<ReadySweepStep>()
        val sweep = ReadySweep(ReadySweepStep.entries.associateWith { step ->
            suspend { steps.add(step); Unit }
        }) { _, failure -> throw failure }
        sweep.run { if (steps.isEmpty()) Long.MAX_VALUE else 0L }
        assertEquals(listOf(ReadySweepStep.userOutbox), steps)
    }

    @Test
    fun mutationsSurviveReopenAndUnreadableStorageCannotBeReset() {
        val file = temporary.root.resolve("wake.json")
        val demand = WakeDemand(WakeDemandKey(WakeDemandSource.botRoutine, "bot-a"), 100, WakeDemandKind.recurring, true)
        WakeDemandLedger(file).update(demand.identity, demand)
        val next = demand.copy(dueAtMs = 300)
        WakeDemandLedger(file).update(next.identity, next)
        assertEquals(listOf(next), WakeDemandLedger(file).read())

        val inaccessible = temporary.newFolder("not-a-file")
        assertThrows(IOException::class.java) {
            WakeDemandLedger(inaccessible).update(demand.identity, demand)
        }
        assertEquals(true, inaccessible.isDirectory)
    }

    private fun plan(input: JsonObject): WakeProjection = WakeProjection.plan(
        input.long("nowMs"), input.bool("resident"),
        (input["demands"] as JsonArray).values.map(WakeDemand::fromJson),
    )

    private fun JsonObject.numberOrNull(key: String): Long? = (this[key] as? JsonNumber)?.asLongOrNull()
}
