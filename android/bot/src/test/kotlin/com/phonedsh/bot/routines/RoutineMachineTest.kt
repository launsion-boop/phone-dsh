// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * `RoutineMachine` over the real P25 store: create/update/begin/finish/cancel,
 * overlap and duplicate-finish handling, crash recovery, reconciliation and
 * delivery leases (D9 §3–§11).
 */
class RoutineMachineTest {
    private val t0 = 1_760_000_000_000L
    private val taipei = "Asia/Taipei"

    private fun RoutineTestHarness.newRoutine(
        id: String = "r",
        schedule: RoutineSchedule = RoutineSchedule.daily("09:00", taipei),
        idempotent: Boolean = false,
        enabled: Boolean = true,
    ): Routine = machine.create(
        botId = "main", title = "Title", prompt = "Prompt", schedule = schedule,
        idempotent = idempotent, enabled = enabled, now = t0, id = id,
    )

    private fun RoutineTestHarness.begin(
        routineId: String = "r",
        startedAt: Long = t0 + 3_600_000,
        runId: String = "run-1",
        leaseTtlMs: Long? = 660_000,
    ): RoutineClaim = machine.begin(
        botId = "main", routineId = routineId, startedAt = startedAt,
        scheduledFor = startedAt, leaseOwner = "local", leaseTtlMs = leaseTtlMs, runId = runId,
    )!!

    @Test
    fun createUpdateDeleteChooseTheSnapshotEventType() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            val created = harness.newRoutine()
            assertEquals(1_760_058_000_000L, created.nextRunAt)
            assertEquals(listOf("routine.defined"), harness.eventTypes())

            harness.clock.set(t0 + 1_000)
            val updated = harness.machine.update(
                "main", "r", RoutinePatch(title = "  New   title  "), now = t0 + 1_000,
            )
            assertEquals("New title", updated.title)
            assertEquals(listOf("routine.defined", "routine.updated"), harness.eventTypes())

            // A fresh store view replays the latest snapshot.
            assertEquals("New title", harness.reopenedRoutines().get("main", "r")?.title)

            harness.clock.set(t0 + 2_000)
            assertEquals("r", harness.machine.delete("main", "r")?.id)
            assertEquals(listOf("routine.defined", "routine.updated", "routine.deleted"), harness.eventTypes())
            assertEquals(emptyList<Routine>(), harness.machine.list("main"))
            assertNull(harness.machine.delete("main", "r"))
            assertEquals(3, harness.eventTypes().size)
        }
    }

    @Test
    fun rejectedMutationsWriteNoSnapshot() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine()
            val before = harness.eventCount()
            try {
                harness.machine.create(
                    botId = "main", title = "Other", prompt = "P",
                    schedule = RoutineSchedule.daily("09:00", taipei), now = t0, id = "r",
                )
                fail("duplicate id must be rejected")
            } catch (error: RoutineError.InvalidRoutine) {
                assertEquals("routine already exists: r", error.message)
            }
            try {
                harness.machine.update("main", "missing", RoutinePatch(title = "x"), now = t0)
                fail("missing routine must be rejected")
            } catch (error: RoutineError.RoutineNotFound) {
                assertEquals("routine not found: missing", error.message)
            }
            try {
                harness.machine.create(
                    botId = "main", title = "", prompt = "P",
                    schedule = RoutineSchedule.daily("09:00", taipei), now = t0,
                )
                fail("empty title must be rejected")
            } catch (error: RoutineError.InvalidRoutine) {
                assertEquals("routine title must be a non-empty string", error.message)
            }
            assertEquals(before, harness.eventCount())
        }
    }

    @Test
    fun updateRecomputesTheScheduleOnlyWhenItChanged() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine(schedule = RoutineSchedule.daily("09:00", taipei))
            harness.clock.set(t0 + 1_000)
            val sameSchedule = harness.machine.update(
                "main", "r", RoutinePatch(title = "T2"), now = t0 + 1_000,
            )
            assertEquals(1_760_058_000_000L, sameSchedule.nextRunAt)
            harness.clock.set(t0 + 2_000)
            val moved = harness.machine.update(
                "main", "r", RoutinePatch(schedule = RoutineSchedule.daily("10:00", taipei)),
                now = t0 + 2_000,
            )
            assertEquals(1_760_061_600_000L, moved.nextRunAt)
            val paused = harness.machine.update("main", "r", RoutinePatch(enabled = false), now = t0 + 2_000)
            assertNull(paused.nextRunAt)
            val resumed = harness.machine.update("main", "r", RoutinePatch(enabled = true), now = t0 + 2_000)
            assertEquals(1_760_061_600_000L, resumed.nextRunAt)
        }
    }

    @Test
    fun updateClearsQuietDeferWhenItResumesOrUrgentIsTurnedOn() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine()
            harness.clock.set(t0 + 1_000)
            harness.machine.deferForQuiet("main", "r", until = 1_760_058_000_000L, now = t0 + 1_000)
            assertNotNull(harness.machine.get("main", "r")!!.quietDefer)
            val urgent = harness.machine.update(
                "main", "r",
                RoutinePatch(urgent = true, urgentReason = "生产故障"),
                now = t0 + 2_000,
            )
            assertNull(urgent.quietDefer)
            assertEquals(1_760_058_000_000L, urgent.nextRunAt)
        }
    }

    @Test
    fun beginStartsTheAttemptAndWritesTheLifecycleEvent() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine()
            harness.clock.set(1_760_058_000_000L)
            val claim = harness.begin(startedAt = 1_760_058_000_000L)
            assertTrue(claim.claimed)
            assertEquals("r:1", claim.deliveryKey)
            val routine = claim.routine
            assertEquals(1, routine.attempt)
            assertEquals("run-1", routine.runState?.runId)
            assertEquals(RoutineRunStatus.STARTED, routine.runState?.status)
            assertEquals(1_760_058_660_000L, routine.runState?.leaseExpiresAt)
            assertEquals("local", routine.runState?.leaseOwner)
            assertEquals(RoutineRunStatus.STARTED, routine.lastResult?.status)
            assertEquals(listOf("routine.defined", "routine.updated", "routine.run_started"), harness.eventTypes())
            assertEquals("routine-run-started:run-1:1", harness.domain.events(0, 10).last().eventId)
            assertEquals(1, harness.domain.events(0, 10).last().attempt)
        }
    }

    @Test
    fun aSecondBeginIsAnOverlapSkipNotACrash() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine()
            harness.clock.set(1_760_058_000_000L)
            harness.begin(startedAt = 1_760_058_000_000L)
            val second = harness.begin(startedAt = 1_760_058_001_000L, runId = "run-2")
            assertEquals(false, second.claimed)
            assertEquals("overlap", second.skipReason)
            assertEquals(1, second.routine.skipCount)
            assertEquals("overlap", second.routine.lastSkip?.reason)
            assertEquals(1, second.routine.lastSkip?.runningAttempt)
            assertEquals("run-1", second.routine.lastSkip?.runningRunId)
            assertEquals(1, second.routine.attempt)
        }
    }

    @Test
    fun finishWritesTheDeliveryAndAdvancesTheSchedule() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine()
            harness.clock.set(1_760_058_000_000L)
            harness.begin(startedAt = 1_760_058_000_000L)
            harness.clock.set(1_760_058_005_000L)
            val finish = harness.machine.finish(
                "main", "r", status = RoutineRunStatus.SUCCEEDED, text = "有新结果",
                startedAt = 1_760_058_000_000L, finishedAt = 1_760_058_005_000L,
                attempt = 1, runId = "run-1",
            )!!
            assertEquals(false, finish.ignored)
            val delivery = finish.delivery!!
            assertEquals(RoutineDeliveryStatus.PENDING, delivery.status)
            assertEquals(RoutineRunStatus.SUCCEEDED, delivery.resultStatus)
            assertEquals("有新结果", delivery.text)
            assertEquals("Prompt", delivery.context)
            assertEquals("r:1", delivery.deliveryKey)
            assertEquals(5_000L, delivery.durationMs)
            assertEquals(0L, delivery.lateByMs)
            assertEquals(false, delivery.quiet)
            assertEquals(finish.delivery, harness.machine.delivery("r:1", "main"))
            assertEquals(RoutineRunStatus.SUCCEEDED, finish.routine.runState?.status)
            assertEquals(1_760_144_400_000L, finish.routine.nextRunAt) // 2025-10-11 09:00 +08
            assertEquals(1_760_144_400_000L, delivery.nextRunAt)
            assertEquals("routine-run-finished:run-1:1", harness.domain.events(0, 10).last().eventId)
            assertEquals(
                listOf(
                    "routine.defined", "routine.updated", "routine.run_started",
                    "routine.updated", "routine.run_finished",
                ),
                harness.eventTypes(),
            )
            assertEquals(listOf("r:1"), harness.machine.pendingDeliveries("main", 1_760_058_005_000L).map { it.deliveryKey })
        }
    }

    @Test
    fun duplicateAndStaleFinishAreIgnoredWithoutAnEvent() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine()
            harness.clock.set(1_760_058_000_000L)
            harness.begin(startedAt = 1_760_058_000_000L)
            val first = harness.machine.finish(
                "main", "r", status = RoutineRunStatus.SUCCEEDED, text = "ok",
                startedAt = 1_760_058_000_000L, finishedAt = 1_760_058_001_000L,
                attempt = 1, runId = "run-1",
            )!!
            val before = harness.eventCount()
            val duplicate = harness.machine.finish(
                "main", "r", status = RoutineRunStatus.SUCCEEDED, text = "again",
                startedAt = 1_760_058_000_000L, finishedAt = 1_760_058_002_000L,
                attempt = 1, runId = "run-1",
            )!!
            assertTrue(duplicate.ignored)
            assertEquals(first.delivery, duplicate.delivery)
            val staleAttempt = harness.machine.finish(
                "main", "r", status = RoutineRunStatus.FAILED, text = "",
                finishedAt = 1_760_058_003_000L, attempt = 2, runId = "run-1",
            )!!
            assertTrue(staleAttempt.ignored)
            val staleRun = harness.machine.finish(
                "main", "r", status = RoutineRunStatus.FAILED, text = "",
                finishedAt = 1_760_058_004_000L, attempt = 1, runId = "other-run",
            )!!
            assertTrue(staleRun.ignored)
            assertEquals(before, harness.eventCount())
        }
    }

    @Test
    fun anEmptySuccessfulReplyIsQuietAndNeedsNoHeldItem() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine()
            harness.clock.set(1_760_058_000_000L)
            harness.begin(startedAt = 1_760_058_000_000L)
            val finish = harness.machine.finish(
                "main", "r", status = RoutineRunStatus.SUCCEEDED, text = "   ",
                startedAt = 1_760_058_000_000L, finishedAt = 1_760_058_001_000L,
                attempt = 1, runId = "run-1",
            )!!
            assertTrue(finish.delivery!!.quiet)
            assertEquals("   ", finish.delivery!!.text)
            assertTrue(finish.routine.lastResult!!.quiet)
        }
    }

    @Test
    fun aFailedRunKeepsItsErrorAndDelivers() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine()
            harness.clock.set(1_760_058_000_000L)
            harness.begin(startedAt = 1_760_058_000_000L)
            val finish = harness.machine.finish(
                "main", "r", status = RoutineRunStatus.FAILED, text = "partial",
                error = "boom", startedAt = 1_760_058_000_000L,
                finishedAt = 1_760_058_001_000L, attempt = 1, runId = "run-1",
            )!!
            assertEquals("boom", finish.delivery!!.error)
            assertEquals("boom", finish.routine.lastResult!!.error)
            assertEquals(RoutineRunStatus.FAILED, finish.routine.runState!!.status)
            assertNotNull(finish.routine.nextRunAt)
        }
    }

    @Test
    fun crashRecoveryRetriesAnIdempotentRunExactlyOnce() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine(idempotent = true, schedule = RoutineSchedule.interval(60, timezone = taipei))
            harness.clock.set(t0 + 3_600_000)
            harness.begin(startedAt = t0 + 3_600_000, leaseTtlMs = 10_000)
            harness.clock.set(t0 + 3_700_000)
            val actions = harness.machine.recover("main", now = t0 + 3_700_000, leaseOwner = "local")
            assertEquals(1, actions.size)
            assertEquals("retry", actions[0].action)
            assertNull("a retry attempt has no delivery", actions[0].deliveryKey)
            val routine = harness.machine.get("main", "r")!!
            assertEquals(RoutineRunStatus.FAILED, routine.runState!!.status)
            assertTrue(routine.crashRetry)
            assertTrue(routine.runState!!.recovered)
            assertEquals(t0 + 3_700_000, routine.nextRunAt)
            assertEquals(emptyList<RoutineDelivery>(), harness.machine.pendingDeliveries("main", t0 + 3_700_000))
            assertTrue(harness.machine.recover("main", now = t0 + 3_700_000, leaseOwner = "local").isEmpty())

            val retried = harness.begin(startedAt = t0 + 3_700_000, runId = "run-2")
            assertTrue(retried.claimed)
            assertEquals(2, retried.routine.attempt)
            assertEquals(true, retried.routine.crashRetry)
            val recovered = harness.machine.finish(
                "main", "r", status = RoutineRunStatus.SUCCEEDED, text = "ok",
                startedAt = t0 + 3_700_000, finishedAt = t0 + 3_700_001,
                attempt = 2, runId = "run-2",
            )!!
            assertEquals(false, recovered.routine.crashRetry)
        }
    }

    @Test
    fun crashRecoveryRequiresReconciliationForANonIdempotentRun() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine(schedule = RoutineSchedule.interval(60, timezone = taipei))
            harness.clock.set(t0 + 3_600_000)
            harness.begin(startedAt = t0 + 3_600_000, leaseTtlMs = 10_000)
            harness.clock.set(t0 + 3_700_000)
            val actions = harness.machine.recover("main", now = t0 + 3_700_000, leaseOwner = "local")
            assertEquals("needs-reconciliation", actions[0].action)
            assertEquals("r:1", actions[0].deliveryKey)
            val routine = harness.machine.get("main", "r")!!
            assertEquals(RoutineRunStatus.NEEDS_RECONCILIATION, routine.runState!!.status)
            assertTrue(routine.runState!!.reconciliationRequired)
            assertEquals(RoutineRunStatus.NEEDS_RECONCILIATION, routine.lastResult!!.status)
            val delivery = harness.machine.delivery("r:1", "main")!!
            assertEquals(RoutineRunStatus.NEEDS_RECONCILIATION, delivery.resultStatus)
            assertEquals(RoutineDeliveryStatus.PENDING, delivery.status)
            assertTrue(delivery.error!!.contains("result is unknown"))
            assertTrue(harness.machine.recover("main", now = t0 + 3_700_000, leaseOwner = "local").isEmpty())

            val blocked = harness.begin(startedAt = t0 + 3_800_000)
            assertEquals(false, blocked.claimed)
            assertEquals("needs-reconciliation", blocked.skipReason)
        }
    }

    @Test
    fun recoveryNeverStealsALiveLease() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine()
            harness.clock.set(1_760_058_000_000L)
            harness.begin(startedAt = 1_760_058_000_000L, leaseTtlMs = 600_000)
            assertTrue(
                harness.machine.recover("main", now = 1_760_058_100_000L, leaseOwner = "local").isEmpty(),
            )
        }
    }

    @Test
    fun reconciliationDecisionsAreExplicitAndValidated() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine(schedule = RoutineSchedule.interval(60, timezone = taipei))
            harness.clock.set(t0 + 3_600_000)
            harness.begin(startedAt = t0 + 3_600_000, leaseTtlMs = 10_000)
            harness.clock.set(t0 + 3_700_000)
            harness.machine.recover("main", now = t0 + 3_700_000, leaseOwner = "local")
            try {
                harness.machine.resolveReconciliation("main", "r", "ignore", now = t0 + 3_700_000)
                fail("unknown decision must be rejected")
            } catch (error: RoutineError.UnsupportedDecision) {
                assertEquals("decision must be \"retry\" or \"acknowledge\", got ignore", error.message)
            }
            val acknowledged = harness.machine.resolveReconciliation(
                "main", "r", "acknowledge", now = t0 + 3_700_000,
            )!!
            assertEquals(RoutineRunStatus.FAILED, acknowledged.runState!!.status)
            assertEquals(false, acknowledged.runState!!.reconciliationRequired)
            assertEquals("needs-reconciliation resolved by user: acknowledge", acknowledged.lastResult!!.error)
            assertEquals(t0 + 3_600_000, acknowledged.runState!!.startedAt)
            // A second decision is a no-op (no longer needs reconciliation).
            val before = harness.eventCount()
            harness.machine.resolveReconciliation("main", "r", "retry", now = t0 + 3_800_000)
            assertEquals(before, harness.eventCount())
        }
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine(schedule = RoutineSchedule.interval(60, timezone = taipei))
            harness.clock.set(t0 + 3_600_000)
            harness.begin(startedAt = t0 + 3_600_000, leaseTtlMs = 10_000)
            harness.clock.set(t0 + 3_700_000)
            harness.machine.recover("main", now = t0 + 3_700_000, leaseOwner = "local")
            val retried = harness.machine.resolveReconciliation("main", "r", "retry", now = t0 + 3_700_000)!!
            assertEquals(t0 + 3_700_000, retried.nextRunAt)
        }
    }

    @Test
    fun deliveryLeasesSerialiseClaimants() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine()
            harness.clock.set(1_760_058_000_000L)
            harness.begin(startedAt = 1_760_058_000_000L)
            harness.machine.finish(
                "main", "r", status = RoutineRunStatus.SUCCEEDED, text = "ok",
                startedAt = 1_760_058_000_000L, finishedAt = 1_760_058_001_000L,
                attempt = 1, runId = "run-1",
            )
            val claimed = harness.machine.claimDelivery(
                "r:1", "main", leaseOwner = "owner-a", now = 1_760_058_002_000L, leaseTtlMs = 60_000,
            )
            assertEquals(RoutineDeliveryClaim.State.CLAIMED, claimed.state)
            assertEquals(1, claimed.delivery!!.attempts)
            assertEquals("owner-a", claimed.delivery!!.leaseOwner)
            val busy = harness.machine.claimDelivery(
                "r:1", "main", leaseOwner = "owner-b", now = 1_760_058_003_000L,
            )
            assertEquals(RoutineDeliveryClaim.State.BUSY, busy.state)
            val completed = harness.machine.completeDelivery("r:1", "main", now = 1_760_058_004_000L)!!
            assertEquals(RoutineDeliveryStatus.DELIVERED, completed.status)
            assertEquals(1_760_058_004_000L, completed.deliveredAt)
            assertNull(completed.leaseOwner)
            assertEquals(
                RoutineDeliveryClaim.State.DELIVERED,
                harness.machine.claimDelivery("r:1", "main", now = 1_760_058_005_000L).state,
            )
            assertEquals(
                RoutineDeliveryClaim.State.MISSING,
                harness.machine.claimDelivery("nope:1", "main", now = 1_760_058_005_000L).state,
            )
        }
    }

    @Test
    fun deliveryFailuresRetryThenBecomePermanent() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine()
            harness.clock.set(1_760_058_000_000L)
            harness.begin(startedAt = 1_760_058_000_000L)
            harness.machine.finish(
                "main", "r", status = RoutineRunStatus.SUCCEEDED, text = "ok",
                startedAt = 1_760_058_000_000L, finishedAt = 1_760_058_001_000L,
                attempt = 1, runId = "run-1",
            )
            harness.machine.claimDelivery("r:1", "main", now = 1_760_058_002_000L)
            val pending = harness.machine.failDelivery(
                "r:1", "main", error = "network", now = 1_760_058_003_000L, maxAttempts = 2,
            )!!
            assertEquals(RoutineDeliveryStatus.PENDING, pending.status)
            assertEquals("network", pending.lastError)
            assertNull(pending.leaseOwner)
            harness.machine.claimDelivery("r:1", "main", now = 1_760_058_004_000L)
            val failed = harness.machine.failDelivery(
                "r:1", "main", error = "network", now = 1_760_058_005_000L, maxAttempts = 2,
            )!!
            assertEquals(RoutineDeliveryStatus.FAILED, failed.status)
            assertEquals(1_760_058_005_000L, failed.failedAt)
            assertEquals(
                RoutineDeliveryClaim.State.FAILED,
                harness.machine.claimDelivery("r:1", "main", now = 1_760_058_006_000L).state,
            )
        }
    }

    @Test
    fun notificationAndHeldBookkeepingArePersisted() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine()
            harness.clock.set(1_760_058_000_000L)
            harness.begin(startedAt = 1_760_058_000_000L)
            harness.machine.finish(
                "main", "r", status = RoutineRunStatus.CANCELLED, text = "",
                startedAt = 1_760_058_000_000L, finishedAt = 1_760_058_001_000L,
                attempt = 1, runId = "run-1", cancelOrigin = "user",
            )
            val notified = harness.machine.markNotification(
                "r:1", "main", notified = "sent", reason = "delivered",
                mode = "on", now = 1_760_058_002_000L,
            )!!
            assertEquals("sent", notified.notified)
            assertEquals("delivered", notified.notifyReason)
            assertEquals(1_760_058_002_000L, notified.notifiedAt)
            assertTrue(notified.proactiveHandled)
            val marked = harness.machine.markHeld(
                "r:1", "main", delivered = false, error = "full", now = 1_760_058_003_000L,
            )!!
            assertEquals("failed", marked.heldInbox)
            assertEquals("full", marked.heldInboxError)
            val cleared = harness.machine.markNotification(
                "r:1", "main", notified = "bogus", reason = null,
                mode = null, handled = false, now = 1_760_058_004_000L,
            )!!
            assertNull(cleared.notified)
            assertNull(cleared.notifiedAt)
            assertEquals(false, cleared.proactiveHandled)
        }
    }

    @Test
    fun aWaitingApprovalAttemptParksAndResumes() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine()
            harness.clock.set(1_760_058_000_000L)
            harness.begin(startedAt = 1_760_058_000_000L)
            val parked = harness.machine.waitForApproval(
                "main", "r", approvalId = "approval-1", sessionId = "session-1",
                now = 1_760_058_001_000L,
            )!!
            assertEquals(RoutineRunStatus.WAITING_APPROVAL, parked.runState!!.status)
            assertEquals("approval-1", parked.runState!!.waitingApprovalId)
            assertEquals("session-1", parked.runState!!.waitingSessionId)
            assertNull(parked.runState!!.leaseOwner)
            assertTrue(harness.machine.pendingDeliveries("main", 1_760_058_002_000L).isEmpty())
            val blocked = harness.begin(startedAt = 1_760_058_002_000L)
            assertEquals(false, blocked.claimed)
            assertEquals("waiting-approval", blocked.skipReason)

            val resumed = harness.machine.resumeWaitingApproval(
                "main", "r", approvalId = "approval-1", now = 1_760_058_003_000L,
                leaseOwner = "local", leaseTtlMs = 660_000,
            )!!
            assertTrue(resumed.claimed)
            assertEquals(RoutineRunStatus.STARTED, resumed.routine.runState!!.status)
            assertNull(resumed.routine.runState!!.waitingApprovalId)
            assertEquals(RoutineRunStatus.STARTED, resumed.routine.lastResult!!.status)
            assertEquals(1, resumed.routine.attempt)

            val finish = harness.machine.finish(
                "main", "r", status = RoutineRunStatus.SUCCEEDED, text = "ok",
                startedAt = 1_760_058_000_000L, finishedAt = 1_760_058_004_000L,
                attempt = 1, runId = "run-1",
            )!!
            assertEquals(RoutineRunStatus.SUCCEEDED, finish.delivery!!.resultStatus)
        }
    }

    @Test
    fun cancelWaitingApprovalIsTerminalAndAllowsTheNextAttempt() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine()
            harness.clock.set(1_760_058_000_000L)
            harness.begin(startedAt = 1_760_058_000_000L)
            harness.machine.waitForApproval(
                "main", "r", approvalId = "approval-1", sessionId = "session-1",
                now = 1_760_058_001_000L,
            )
            val cancelled = harness.machine.cancelWaitingApproval(
                "main", "r", approvalId = "approval-1", now = 1_760_058_002_000L,
            )!!
            assertEquals(RoutineRunStatus.CANCELLED, cancelled.runState!!.status)
            assertEquals("approval_cancelled", cancelled.runState!!.error)
            assertEquals(RoutineRunStatus.CANCELLED, cancelled.lastResult!!.status)
            assertEquals(1_760_058_002_000L, cancelled.lastResult!!.finishedAt)
            assertNotNull(cancelled.nextRunAt)
            val next = harness.begin(startedAt = 1_760_058_010_000L, runId = "run-2")
            assertTrue(next.claimed)
            assertEquals(2, next.routine.attempt)
        }
    }

    @Test
    fun botSnapshotsAreIsolated() {
        RoutineTestHarness(FakeClock(t0)).use { harness ->
            harness.newRoutine(id = "main-routine")
            harness.routines.mutate("other") { document ->
                RoutineMutation(
                    value = Unit,
                    document = document.copy(
                        routines = listOf(
                            Routine(
                                id = "other-routine", agentId = "other", title = "T", prompt = "P",
                                schedule = RoutineSchedule.daily("09:00", taipei), createdAt = t0,
                                nextRunAt = 1_760_058_000_000L,
                            ),
                        ),
                    ),
                    botId = "other",
                )
            }
            assertEquals(listOf("main-routine"), harness.machine.list("main").map { it.id })
            assertEquals(listOf("other-routine"), harness.machine.list("other").map { it.id })
        }
    }
}
