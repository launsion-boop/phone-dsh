// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import com.phonedsh.agentcore.JsonBool
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.wake.BotTurnOriginKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The loosening rule and the approval assessment (v2 §2.2): create always
 * needs confirmation in a non-user turn, resume needs it only when the routine
 * was paused, and the four widening changes are classified identically by the
 * card and the store.
 */
class RoutineAuthorityTest {
    private val t0 = 1_760_000_000_000L
    private val taipei = "Asia/Taipei"

    private fun args(vararg pairs: Pair<String, com.phonedsh.agentcore.JsonValue>): JsonObject =
        JsonObject(linkedMapOf(*pairs))

    @Test
    fun createAlwaysRequiresConfirmation() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            val assessment = RoutineAuthority.assess(
                args("action" to JsonString("create"), "title" to JsonString("晨间简报")),
                harness.machine, "main", t0,
            )
            assertEquals(RoutineChangeAssessment.Action.CREATE, assessment.action)
            assertTrue(assessment.requiresConfirmation)
            assertNull(assessment.routineId)
            assertEquals("routine:create:晨间简报", assessment.resource)
            assertEquals(
                "在新的例行任务「晨间简报」创建前确认；它会在没有用户消息的回合里保存可自行触发的目标。",
                assessment.detail,
            )
            // The resource never carries path separators from the model text.
            val hostile = RoutineAuthority.assess(
                args("action" to JsonString("create"), "title" to JsonString("a/b c?d")),
                harness.machine, "main", t0,
            )
            assertEquals("routine:create:a_b_c_d", hostile.resource)
        }
    }

    @Test
    fun nonWideningUpdatesNeedNoConfirmation() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.machine.create(
                botId = "main", title = "T", prompt = "P",
                schedule = RoutineSchedule.daily("09:00", taipei), now = t0, id = "r",
            )
            val assessment = RoutineAuthority.assess(
                args("action" to JsonString("update"), "routine_id" to JsonString("r"), "title" to JsonString("New")),
                harness.machine, "main", t0,
            )
            assertEquals(RoutineChangeAssessment.Action.UPDATE, assessment.action)
            assertFalse(assessment.requiresConfirmation)
            assertEquals("r", assessment.routineId)
            assertEquals("例行任务「T」会被放宽：无。", assessment.detail)
        }
    }

    @Test
    fun eachWideningChangeRequiresConfirmation() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.machine.create(
                botId = "main", title = "T", prompt = "P",
                schedule = RoutineSchedule.daily("09:00", taipei), now = t0, id = "r",
            )
            val cases = listOf(
                args(
                    "action" to JsonString("update"), "routine_id" to JsonString("r"),
                    "schedule" to JsonString("@every 30m"),
                ) to "触发更频繁",
                args(
                    "action" to JsonString("update"), "routine_id" to JsonString("r"),
                    "delivery" to JsonString("interrupt"), "interrupt_reason" to JsonString("用户在等"),
                ) to "改为立即打断",
                args(
                    "action" to JsonString("update"), "routine_id" to JsonString("r"),
                    "urgent" to JsonBool(true), "urgent_reason" to JsonString("生产故障"),
                ) to "改为紧急",
            )
            for ((arguments, expected) in cases) {
                val assessment = RoutineAuthority.assess(arguments, harness.machine, "main", t0)
                assertTrue("$expected requires confirmation", assessment.requiresConfirmation)
                assertTrue("$expected detail", assessment.detail.contains(expected))
            }
        }
    }

    @Test
    fun resumingAPausedRoutineRequiresConfirmationButAnEnabledOneDoesNot() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.machine.create(
                botId = "main", title = "T", prompt = "P",
                schedule = RoutineSchedule.daily("09:00", taipei), now = t0, id = "r",
            )
            val enabled = RoutineAuthority.assess(
                args("action" to JsonString("resume"), "routine_id" to JsonString("r")),
                harness.machine, "main", t0,
            )
            assertFalse(enabled.requiresConfirmation)
            harness.machine.update("main", "r", RoutinePatch(enabled = false), now = t0)
            val paused = RoutineAuthority.assess(
                args("action" to JsonString("resume"), "routine_id" to JsonString("r")),
                harness.machine, "main", t0,
            )
            assertTrue(paused.requiresConfirmation)
            assertEquals(
                "重新启用暂停的例行任务「T」会恢复它的自动触发。",
                paused.detail,
            )
        }
    }

    @Test
    fun readPauseAndDeleteAreNotWidening() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            for (action in listOf("read", "list", "pause", "delete")) {
                val assessment = RoutineAuthority.assess(
                    args("action" to JsonString(action), "routine_id" to JsonString("r")),
                    harness.machine, "main", t0,
                )
                assertEquals(RoutineChangeAssessment.Action.OTHER, assessment.action)
                assertFalse(assessment.requiresConfirmation)
                assertEquals("routine:other", assessment.resource)
                assertEquals("r", assessment.routineId)
            }
        }
    }

    @Test
    fun missingArgumentsAndUnknownRoutinesFailClosed() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            try {
                RoutineAuthority.assess(JsonObject(emptyMap()), harness.machine, "main", t0)
                org.junit.Assert.fail("missing action must be rejected")
            } catch (error: RoutineError.InvalidRoutine) {
                assertEquals("UpdateRoutine requires action", error.message)
            }
            try {
                RoutineAuthority.assess(
                    args("action" to JsonString("update"), "routine_id" to JsonString("missing")),
                    harness.machine, "main", t0,
                )
                org.junit.Assert.fail("unknown routine must be rejected")
            } catch (error: RoutineError.RoutineNotFound) {
                assertEquals("routine not found: missing", error.message)
            }
            try {
                RoutineAuthority.assess(
                    args("action" to JsonString("create")), harness.machine, "main", t0,
                )
                org.junit.Assert.fail("missing title must be rejected")
            } catch (error: RoutineError.InvalidRoutine) {
                assertTrue(error.message!!.contains("title"))
            }
        }
    }

    @Test
    fun isLooseningIsThePureRuleTheStoreAndCardShare() {
        val current = Routine(
            id = "r", agentId = "main", title = "T", prompt = "P",
            schedule = RoutineSchedule.daily("09:00", taipei), createdAt = t0, enabled = true,
        )
        assertFalse(RoutineAuthority.isLoosening(current, RoutinePatch(title = "x"), now = t0))
        assertFalse(RoutineAuthority.isLoosening(current, RoutinePatch(enabled = true), now = t0))
        assertTrue(
            RoutineAuthority.isLoosening(
                current, RoutinePatch(delivery = RoutineDeliveryMode.INTERRUPT), now = t0,
            ),
        )
        assertTrue(RoutineAuthority.isLoosening(current, RoutinePatch(urgent = true), now = t0))
        assertTrue(
            RoutineAuthority.isLoosening(
                current, RoutinePatch(schedule = RoutineSchedule.interval(5, timezone = taipei)), now = t0,
            ),
        )
        assertFalse(
            RoutineAuthority.isLoosening(
                current, RoutinePatch(schedule = RoutineSchedule.daily("09:00", taipei)), now = t0,
            ),
        )
    }

    @Test
    fun theCreatorRecordingKeepsTheTurnOriginWithoutASecondField() {
        val userTurn = RoutineCreator.fromTurnAuthority(
            rpcId = "bot-abc", turnId = "turn-1", sessionId = "session-1",
            origin = BotTurnOriginKind.USER, isUserTurn = true,
        )
        assertEquals(RoutineCreator.Authorization.USER_TURN, userTurn.authorization)
        assertNull(userTurn.approvalId)
        val creator = RoutineCreator.fromTurnAuthority(
            rpcId = "routine:run-1", turnId = null, sessionId = "session-2",
            origin = BotTurnOriginKind.ROUTINE, isUserTurn = false, approvalId = "approval-1",
        )
        assertEquals(RoutineCreator.Authorization.USER_CONFIRMED, creator.authorization)
        assertEquals("approval-1", creator.approvalId)
        assertEquals(creator, RoutineCreator.fromJson(creator.toJson()))
        assertEquals("routine", (creator.toJson().members["origin"] as JsonString).value)
        assertFalse(creator.toJson().members.containsKey("turnId"))

        val routine = Routine(
            id = "r", agentId = "main", title = "T", prompt = "P",
            schedule = RoutineSchedule.daily("09:00", taipei), createdAt = t0, creator = userTurn,
        )
        assertEquals(userTurn, routine.validated().creator)
        try {
            routine.copy(creator = creator.copy(approvalId = null)).validated()
            org.junit.Assert.fail("user-confirmed without an approval id must be rejected")
        } catch (error: RoutineError.InvalidRoutine) {
            assertEquals(
                "routine creator.approvalID is required after user confirmation",
                error.message,
            )
        }
        assertTrue(routine.toJson().members.keys.contains("creator"))
    }
}
