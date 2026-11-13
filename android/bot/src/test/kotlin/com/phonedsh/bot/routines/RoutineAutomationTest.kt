// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The delivery → information-page row projection (Swift `RoutineAutomation`). */
class RoutineAutomationTest {
    private val t0 = 1_760_000_000_000L

    private fun delivery(
        resultStatus: RoutineRunStatus,
        text: String = "有新结果",
        error: String? = null,
        quiet: Boolean = false,
        delivery: RoutineDeliveryMode = RoutineDeliveryMode.HELD,
        urgent: Boolean = false,
        urgentReason: String = "",
        lateByMs: Long = 0,
        quietDeferredFrom: Long? = null,
        quietDeferredUntil: Long? = null,
        heldInbox: String? = null,
        notified: String? = null,
        notifyReason: String? = null,
        cancelOrigin: String? = null,
    ): RoutineDelivery = RoutineDelivery(
        deliveryKey = "daily:1", routineId = "daily", agentId = "main", attempt = 1,
        runId = "run-1", resultStatus = resultStatus, text = text, error = error,
        routineTitle = "晨间简报", context = "汇总重要变化", delivery = delivery,
        quiet = quiet, urgent = urgent, urgentReason = urgentReason,
        notified = notified, notifyReason = notifyReason, cancelOrigin = cancelOrigin,
        heldInbox = heldInbox, quietDeferredFrom = quietDeferredFrom,
        quietDeferredUntil = quietDeferredUntil, lateByMs = lateByMs,
        startedAt = t0, finishedAt = t0 + 1_000, durationMs = 1_000,
        createdAt = t0 + 1_000, updatedAt = t0 + 1_000,
    )

    @Test
    fun aSuccessfulRunIsSentWithItsText() {
        val automation = RoutineAutomation.from(delivery(RoutineRunStatus.SUCCEEDED))
        assertEquals("routine-run-daily-1", automation.id)
        assertEquals("routine-run", automation.kind)
        assertEquals("sent", automation.status)
        assertEquals("有新结果", automation.result)
        assertEquals("main", automation.botId)
        assertEquals("daily:1", automation.deliveryKey)
        assertEquals("汇总重要变化", automation.context)
        assertNull(automation.error)
    }

    @Test
    fun anEmptyQuietSuccessSaysThereIsNothingNew() {
        val automation = RoutineAutomation.from(
            delivery(RoutineRunStatus.SUCCEEDED, text = "", quiet = true),
        )
        assertEquals("已完成（没有新结果）", automation.result)
        assertEquals("sent", automation.status)
        assertTrue(automation.quiet)
    }

    @Test
    fun terminalFailuresRenderTheFrozenChineseText() {
        assertEquals("执行已取消", RoutineAutomation.from(delivery(RoutineRunStatus.CANCELLED)).result)
        assertEquals("idle", RoutineAutomation.from(delivery(RoutineRunStatus.CANCELLED)).status)
        assertEquals("执行超时，已取消", RoutineAutomation.from(delivery(RoutineRunStatus.TIMED_OUT)).result)
        assertEquals("failed", RoutineAutomation.from(delivery(RoutineRunStatus.TIMED_OUT)).status)
        assertEquals(
            "执行结果未知，需要确认：effect outcome unknown",
            RoutineAutomation.from(
                delivery(RoutineRunStatus.NEEDS_RECONCILIATION, text = "", error = "effect outcome unknown"),
            ).result,
        )
        assertEquals(
            "执行失败：boom",
            RoutineAutomation.from(delivery(RoutineRunStatus.FAILED, text = "", error = "boom")).result,
        )
        assertEquals(
            "执行失败：未知错误",
            RoutineAutomation.from(delivery(RoutineRunStatus.FAILED, text = "", error = null)).result,
        )
        assertEquals("boom", RoutineAutomation.from(delivery(RoutineRunStatus.FAILED, error = "boom")).error)
    }

    @Test
    fun theContextAddsTheDeferralUrgencyHeldAndNotificationClauses() {
        val deferred = RoutineAutomation.from(
            delivery(
                RoutineRunStatus.SUCCEEDED,
                quietDeferredFrom = 1_760_058_000_000L,
                quietDeferredUntil = 1_760_061_600_000L,
            ),
        )
        assertTrue(deferred.context.startsWith("汇总重要变化 · （因安静时段延后，原定 "))
        assertTrue(deferred.context.endsWith("）"))

        val late = RoutineAutomation.from(delivery(RoutineRunStatus.SUCCEEDED, lateByMs = 90_000))
        assertTrue(late.context.contains("（延迟 2 分钟触发）"))
        assertEquals(
            false,
            RoutineAutomation.from(delivery(RoutineRunStatus.SUCCEEDED, lateByMs = 60_000))
                .context.contains("延迟"),
        )

        val urgent = RoutineAutomation.from(
            delivery(RoutineRunStatus.SUCCEEDED, urgent = true, urgentReason = "生产故障"),
        )
        assertTrue(urgent.context.contains("（紧急：生产故障）"))
        assertTrue(
            RoutineAutomation.from(delivery(RoutineRunStatus.SUCCEEDED, urgent = true))
                .context.contains("（紧急：—）"),
        )

        val heldFailure = RoutineAutomation.from(
            delivery(RoutineRunStatus.SUCCEEDED, heldInbox = "failed"),
        )
        assertTrue(heldFailure.context.contains("结果未能交给主对话"))

        val notified = RoutineAutomation.from(
            delivery(
                RoutineRunStatus.SUCCEEDED, delivery = RoutineDeliveryMode.INTERRUPT,
                notified = "sent", notifyReason = null,
            ),
        )
        assertTrue(notified.context.endsWith("已通知"))
        val skipped = RoutineAutomation.from(
            delivery(
                RoutineRunStatus.SUCCEEDED, delivery = RoutineDeliveryMode.INTERRUPT,
                notified = "skipped", notifyReason = "dnd",
            ),
        )
        assertTrue(skipped.context.endsWith("未通知：dnd"))
    }

    @Test
    fun theRowIdIsSanitisedFromTheRoutineId() {
        assertEquals("routine-run-daily-1", RoutineDelivery.rowId("daily", 1))
        assertEquals("routine-run-a_b_c-2", RoutineDelivery.rowId("a/b c", 2))
        assertEquals("routine-run-routine-0", RoutineDelivery.rowId("", 0))
        assertEquals("routine-run-daily-1", RoutineAutomation.from(delivery(RoutineRunStatus.SUCCEEDED)).id)
    }
}
