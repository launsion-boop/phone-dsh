// SPDX-License-Identifier: MIT
package com.phonedsh.bot.wake

import com.phonedsh.bot.routines.FakeClock
import com.phonedsh.bot.routines.Routine
import com.phonedsh.bot.routines.RoutineDeliveryFlags
import com.phonedsh.bot.routines.RoutineDeliveryMode
import com.phonedsh.bot.routines.RoutineError
import com.phonedsh.bot.routines.RoutineQuietHours
import com.phonedsh.bot.routines.RoutineQuietSettings
import com.phonedsh.bot.routines.RoutineScheduleMath
import com.phonedsh.bot.routines.RoutineTestHarness
import com.phonedsh.bot.routines.V2Golden
import com.phonedsh.bot.routines.epoch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * `spec/bot/v2/golden/wake-routine.json`: the hidden wake prompt, the quiet
 * reply normalization, the held block, the automation-status block, the
 * delivery flags and the quiet-hours boundary cases.
 */
class WakeRoutineGoldenTest {
    private val firedAt = 1_760_000_000_000L
    private val taipei = "Asia/Taipei"

    private fun goldenRoutine(golden: com.phonedsh.agentcore.JsonObject): Routine =
        Routine.fromJson(V2Golden.at(golden, "valid", "quietDefer"))

    @Test
    fun theWakePromptMatchesTheGoldenText() {
        val golden = V2Golden.load("wake-routine")
        val routine = goldenRoutine(golden)
        val wake = RoutineWakeBuilder.build(
            routine = routine, firedAt = firedAt, now = firedAt,
        )
        assertEquals(V2Golden.string(golden, "valid", "wake", "text"), wake.text)
        assertEquals(V2Golden.string(golden, "valid", "wake", "cue"), wake.cue)
        assertEquals(V2Golden.string(golden, "valid", "wake", "mode"), wake.mode.rawValue)
        assertEquals("30 8 * * *", RoutineScheduleMath.expression(routine.schedule))
        assertEquals(V2Golden.string(golden, "valid", "scheduleExpr"), RoutineScheduleMath.expression(routine.schedule))
        assertTrue(wake.text.startsWith("<timestamp>"))
        assertTrue(wake.text.contains("[SAND_HIDDEN_PROMPT][SAND_TRUSTED_AUTOMATION_PROMPT]"))
        assertTrue(wake.text.endsWith("</user_query>"))
    }

    @Test
    fun onDemandModeChangesOnlyTheDeclaredRunKind() {
        val golden = V2Golden.load("wake-routine")
        val routine = goldenRoutine(golden)
        val onDemand = RoutineWakeBuilder.build(
            routine = routine, mode = RoutineWakeMode.ON_DEMAND, firedAt = firedAt, now = firedAt,
        )
        assertTrue(onDemand.text.contains("was run on demand"))
        assertTrue(onDemand.text.contains("用户在应用里按了这条例行指令的“立即运行”"))
        assertEquals("on-demand", onDemand.mode.rawValue)
    }

    @Test
    fun quietAndResultRepliesNormalizeLikeTheReference() {
        val golden = V2Golden.load("wake-routine")
        for (raw in listOf("", "   ", "\n", "[quiet]", "  [QUIET]  ", "```[quiet]```")) {
            val reply = RoutineWakeBuilder.normalizeReply(raw)
            assertEquals("quiet reply for \"$raw\"", "", reply.text)
            assertTrue("quiet reply for \"$raw\"", reply.quiet)
        }
        val quiet = V2Golden.at(golden, "valid", "quietReply")!!
        val quietReply = RoutineWakeBuilder.normalizeReply("[quiet]")
        assertEquals(V2Golden.string(quiet, "text"), quietReply.text)
        assertEquals((V2Golden.at(quiet, "quiet") as com.phonedsh.agentcore.JsonBool).value, quietReply.quiet)

        val expectedResult = V2Golden.at(golden, "valid", "resultReply")!!
        val resultReply = RoutineWakeBuilder.normalizeReply("有新结果")
        assertEquals(V2Golden.string(expectedResult, "text"), resultReply.text)
        assertFalse(resultReply.quiet)
        assertFalse(RoutineWakeBuilder.normalizeReply("```有新结果```").quiet)
        assertEquals("有新结果", RoutineWakeBuilder.normalizeReply("```有新结果```").text)
    }

    @Test
    fun theHeldBlockMatchesTheGoldenTwoBulletCase() {
        val golden = V2Golden.load("wake-routine")
        val items = listOf(
            WakeInboxItem(
                id = "held-1",
                kind = "routine-result",
                title = "晨间简报",
                text = "有三项变化",
                requestId = "daily:1",
                createdAt = firedAt,
                ranAt = firedAt,
                routineId = "daily",
                attempt = 1,
                runId = "run-daily-1",
            ),
            WakeInboxItem(
                id = "held-2",
                kind = "subagent-result",
                text = "检查完成",
                requestId = "task:1",
                createdAt = firedAt,
                taskId = "task-1",
                status = "ok",
            ),
        )
        assertEquals(
            V2Golden.string(golden, "valid", "heldBlock"),
            HeldMessages.block(items, lang = "zh", timezone = taipei),
        )
    }

    @Test
    fun theAutomationStatusMatchesTheGoldenText() {
        val golden = V2Golden.load("wake-routine")
        val routine = goldenRoutine(golden)
        assertEquals(
            V2Golden.string(golden, "valid", "automationStatus"),
            AutomationStatus.block(listOf(routine), now = firedAt),
        )
        // A routine whose next run is absent is repaired by the same schedule math.
        val repaired = routine.copy(nextRunAt = null)
        val block = AutomationStatus.block(listOf(repaired), now = firedAt)
        assertTrue(block.contains("next run 2025-10-10 08:30"))
        assertTrue(block.contains("last never"))
    }

    @Test
    fun automationStatusCarriesNeedsReconciliationDeferredAndPausedStates() {
        val golden = V2Golden.load("wake-routine")
        val routine = goldenRoutine(golden)
        val deferred = routine.copy(
            quietDefer = com.phonedsh.bot.routines.RoutineQuietDefer(
                until = 1_760_059_800_000L, scheduledFor = 1_760_056_200_000L, at = firedAt,
            ),
            nextRunAt = 1_760_059_800_000L,
        )
        val deferredBlock = AutomationStatus.block(listOf(deferred), now = firedAt)
        assertTrue(deferredBlock.contains("quiet-deferred until 2025-10-10 09:30"))
        val paused = routine.copy(enabled = false, nextRunAt = null)
        assertTrue(AutomationStatus.block(listOf(paused), now = firedAt).contains("paused"))
        val blocked = routine.copy(
            runState = com.phonedsh.bot.routines.RoutineRunState(
                runId = "run-1", attempt = 1,
                status = com.phonedsh.bot.routines.RoutineRunStatus.NEEDS_RECONCILIATION,
                startedAt = firedAt,
            ),
        )
        assertTrue(AutomationStatus.block(listOf(blocked), now = firedAt).contains("needs-reconciliation"))
        val empty = AutomationStatus.block(emptyList(), now = firedAt)
        assertTrue(empty.contains("没有已启用的例行任务"))
        val unreadable = AutomationStatus.unreadable(RoutineError.InvalidRoutine("snapshot unreadable"))
        assertTrue(unreadable.contains("例行任务状态暂时无法读取"))
        assertTrue(unreadable.contains("snapshot unreadable"))
    }

    @Test
    fun deliveryFlagsRoundTripAndMatchTheGolden() {
        val golden = V2Golden.load("wake-routine")
        val flags = V2Golden.at(golden, "valid", "deliveryFlags")!!
        val built = RoutineDeliveryFlags.of(
            urgent = (V2Golden.at(flags, "urgent") as com.phonedsh.agentcore.JsonBool).value,
            urgentReason = V2Golden.string(flags, "urgent_reason"),
            delivery = RoutineDeliveryMode.from(V2Golden.string(flags, "delivery")),
            interruptReason = V2Golden.string(flags, "interrupt_reason"),
        )
        assertEquals(V2Golden.canonical(flags), V2Golden.canonical(built.toJson()))
        assertEquals("生产故障", built.urgentReason)
        assertEquals("用户正在等待", built.interruptReason)
    }

    @Test
    fun invalidDeliveryAndQuietCasesMatchTheGolden() {
        val golden = V2Golden.load("wake-routine")
        val invalid = V2Golden.objects(golden, "invalid")
        assertEquals(listOf("interrupt_without_reason", "quiet_at_23_30", "quiet_at_noon"), invalid.map {
            V2Golden.string(it, "kind")
        })
        try {
            RoutineDeliveryFlags.of(delivery = RoutineDeliveryMode.INTERRUPT, interruptReason = "   ")
            fail("interrupt without a reason must be rejected")
        } catch (error: RoutineError.InterruptReasonRequired) {
            assertEquals(V2Golden.string(invalid[0], "error"), error.message)
        }
        val settings = RoutineQuietSettings(timeZone = taipei)
        assertEquals(
            (V2Golden.at(invalid[1], "value") as com.phonedsh.agentcore.JsonBool).value,
            RoutineQuietHours.contains(epoch(2025, 10, 9, 23, 30, 0, taipei), settings),
        )
        assertEquals(
            (V2Golden.at(invalid[2], "value") as com.phonedsh.agentcore.JsonBool).value,
            RoutineQuietHours.contains(epoch(2025, 10, 9, 12, 0, 0, taipei), settings),
        )
    }

    @Test
    fun quietDeferWithNoFutureInstantIsRejectedWithoutWriting() {
        val golden = V2Golden.load("wake-routine")
        // The vector's `reason` is "invalid-target": deferForQuiet must not move
        // the schedule for a nil/past target, and it must not append an event.
        assertEquals("invalid-target", V2Golden.string(golden, "valid", "quietDefer", "reason"))
        assertFalse((V2Golden.at(golden, "valid", "quietDefer", "deferred") as com.phonedsh.agentcore.JsonBool).value)
        RoutineTestHarness(FakeClock(firedAt)).use { harness ->
            val routine = harness.machine.create(
                botId = "main", title = "晨间简报", prompt = "汇总重要变化；没有变化就保持安静。",
                schedule = com.phonedsh.bot.routines.RoutineSchedule.daily("08:30", taipei),
                now = firedAt, id = "daily",
            )
            val before = harness.eventCount()
            for (target in listOf(null, firedAt, firedAt - 1)) {
                val result = harness.machine.deferForQuiet("main", routine.id, until = target, now = firedAt)
                assertEquals(false, result!!.second)
                assertNull(harness.machine.get("main", routine.id)!!.quietDefer)
            }
            assertEquals(before, harness.eventCount())
        }
    }
}
