// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `RoutineScheduler` with a fake clock: exactly-once catch-up, quiet defer,
 * overlap, timeout/cancel reconciliation, crash replay, notification
 * reconciliation and the delivery chain (D9 §4–§8, v2 §3.1).
 */
class RoutineSchedulerTest {
    private val t0 = 1_760_000_000_000L
    private val taipei = "Asia/Taipei"
    private val neverQuiet = RoutineQuietSettings(
        quietStart = "00:00", quietEnd = "00:00", timeZone = taipei,
    )

    private class RecordingInterrupt : RoutineInterruptConsiderer {
        val candidates = ArrayList<RoutineInterruptCandidate>()
        var decision = RoutineInterruptDecision(mode = "on", decision = "did", reason = "delivered")

        override fun consider(candidate: RoutineInterruptCandidate): RoutineInterruptDecision {
            candidates += candidate
            return decision
        }
    }

    private fun harness(clock: FakeClock = FakeClock(t0)): RoutineTestHarness = RoutineTestHarness(clock)

    private fun scheduler(
        harness: RoutineTestHarness,
        runner: RoutineRunner,
        sink: RoutineResultSink = RecordingResultSink(),
        settings: () -> RoutineQuietSettings = { neverQuiet },
        notifications: RoutineNotificationScheduling? = null,
        proactive: RoutineInterruptConsiderer? = null,
        runTimeoutMs: Long = 600_000,
        cancelGraceMs: Long = 5_000,
        available: (String) -> Boolean = { true },
        busy: (String) -> Boolean = { false },
    ): RoutineScheduler = RoutineScheduler(
        botId = "main",
        machine = harness.machine,
        inbox = harness.inbox,
        sink = sink,
        runner = runner,
        proactive = proactive,
        notifications = notifications,
        settingsProvider = settings,
        clock = { harness.clock.now },
        runTimeoutMs = runTimeoutMs,
        cancelGraceMs = cancelGraceMs,
        available = available,
        busy = busy,
    )

    private fun dueScheduler(
        harness: RoutineTestHarness,
        runner: RoutineRunner,
        sink: RoutineResultSink = RecordingResultSink(),
        settings: () -> RoutineQuietSettings = { neverQuiet },
        proactive: RoutineInterruptConsiderer? = null,
        notifications: RoutineNotificationScheduling? = null,
    ): RoutineScheduler {
        val scheduler = scheduler(
            harness, runner, sink, settings, notifications, proactive,
        )
        harness.clock.set(t0 + 3_600_000)
        return scheduler
    }

    @Test
    fun aDueRoutineRunsExactlyOnceAndCatchesUpOnce() {
        val clock = FakeClock(t0)
        harness(clock).use { harness ->
            val runner = ScriptedRunner()
            runner.onStart = { it.finish(RoutineExecutionResult.success("有新结果")) }
            val sink = RecordingResultSink()
            harness.machine.create(
                botId = "main", title = "Digest", prompt = "Summarize",
                schedule = RoutineSchedule.interval(60, timezone = taipei),
                now = t0, id = "r",
            )
            val scheduler = scheduler(harness, runner, sink)
            clock.set(t0 + 3_600_000)
            scheduler.tick()

            assertEquals(1, runner.started.size)
            val request = runner.started[0].request
            assertEquals(1, request.attempt)
            assertEquals(1_760_000_000_000L + 3_600_000L, request.startedAt)
            assertTrue(request.wake.text.contains("[routine] \"Digest\" (folder r) is due"))
            assertEquals("routine", request.wake.cue)
            assertEquals("due", request.wake.mode)
            assertEquals(606_000L, request.timeoutMs)

            val delivery = harness.machine.delivery("r:1", "main")!!
            assertEquals(RoutineDeliveryStatus.DELIVERED, delivery.status)
            assertEquals(RoutineRunStatus.SUCCEEDED, delivery.resultStatus)
            assertEquals(1, sink.delivered.size)
            assertEquals("有新结果", sink.delivered[0].result)
            assertEquals(1, harness.inbox.items().size)
            assertEquals("routine-result", harness.inbox.items()[0].kind)
            assertEquals("r:1", harness.inbox.items()[0].requestId)

            scheduler.tick()
            assertEquals("a second tick in the same instant must not re-run", 1, runner.started.size)
            assertEquals(1, harness.inbox.items().size)

            clock.now = t0 + 3_600_000 + 3 * 3_600_000
            scheduler.tick()
            assertEquals(2, runner.started.size)
            assertEquals(2, runner.started[1].request.attempt)
            assertEquals(2, harness.inbox.items().size)
        }
    }

    @Test
    fun quietHoursDeferInsteadOfDroppingTheRun() {
        val clock = FakeClock(epoch(2025, 10, 9, 12, 0, 0, taipei))
        harness(clock).use { harness ->
            val runner = ScriptedRunner()
            runner.onStart = { it.finish(RoutineExecutionResult.success("有三项变化")) }
            harness.machine.create(
                botId = "main", title = "晨间简报", prompt = "汇总",
                schedule = RoutineSchedule.daily("09:00", taipei),
                now = clock.now, id = "r",
            )
            val quiet = RoutineQuietSettings(
                quietStart = "08:00", quietEnd = "10:00", timeZone = taipei,
            )
            val scheduler = scheduler(harness, runner, settings = { quiet })
            clock.now = epoch(2025, 10, 10, 9, 0, 0, taipei)
            scheduler.tick()

            assertEquals(0, runner.started.size)
            val deferred = harness.machine.get("main", "r")!!
            assertEquals(epoch(2025, 10, 10, 10, 0, 0, taipei), deferred.quietDefer!!.until)
            assertEquals(epoch(2025, 10, 10, 9, 0, 0, taipei), deferred.quietDefer!!.scheduledFor)
            assertEquals(epoch(2025, 10, 10, 9, 0, 0, taipei), deferred.quietDefer!!.at)
            assertEquals(deferred.quietDefer!!.until, deferred.nextRunAt)
            val presence = scheduler.presenceSnapshot(appActive = false, keepingAlive = false)
            assertEquals(1, presence.deferred.size)
            assertEquals(epoch(2025, 10, 10, 9, 0, 0, taipei), presence.deferred[0].scheduledFor)

            clock.now = epoch(2025, 10, 10, 9, 30, 0, taipei)
            scheduler.tick()
            assertEquals(0, runner.started.size)

            clock.now = epoch(2025, 10, 10, 10, 0, 0, taipei)
            scheduler.tick()
            assertEquals("a deferred routine still runs", 1, runner.started.size)
            val delivery = harness.machine.delivery("r:1", "main")!!
            assertEquals(epoch(2025, 10, 10, 9, 0, 0, taipei), delivery.quietDeferredFrom)
            assertEquals(epoch(2025, 10, 10, 10, 0, 0, taipei), delivery.quietDeferredUntil)
            assertEquals(3_600_000L, delivery.lateByMs)
        }
    }

    @Test
    fun urgentWithAReasonBypassesQuietHours() {
        val clock = FakeClock(epoch(2025, 10, 9, 12, 0, 0, taipei))
        harness(clock).use { harness ->
            val runner = ScriptedRunner()
            runner.onStart = { it.finish(RoutineExecutionResult.success("故障已解除")) }
            harness.machine.create(
                botId = "main", title = "发布窗口", prompt = "检查",
                schedule = RoutineSchedule.daily("09:00", taipei),
                urgent = true, urgentReason = "生产故障", now = clock.now, id = "r",
            )
            val scheduler = scheduler(
                harness, runner,
                settings = {
                    RoutineQuietSettings(quietStart = "08:00", quietEnd = "10:00", timeZone = taipei)
                },
            )
            clock.now = epoch(2025, 10, 10, 9, 0, 0, taipei)
            scheduler.tick()
            assertEquals(1, runner.started.size)
            assertNull(harness.machine.get("main", "r")!!.quietDefer)
        }
    }

    @Test
    fun overlapRecordsASkipAndDoesNotAdvanceTheSchedule() {
        harness().use { harness ->
            val runner = ScriptedRunner()
            harness.machine.create(
                botId = "main", title = "T", prompt = "P",
                schedule = RoutineSchedule.interval(60, timezone = taipei),
                now = t0, id = "r",
            )
            val scheduler = dueScheduler(harness, runner)
            scheduler.tick()
            assertEquals(1, runner.started.size)
            val firstNextRun = harness.machine.get("main", "r")!!.nextRunAt

            harness.clock.advance(1_000)
            scheduler.tick()
            assertEquals(1, runner.started.size)
            val routine = harness.machine.get("main", "r")!!
            assertEquals(1, routine.attempt)
            assertEquals(1, routine.skipCount)
            assertEquals("overlap", routine.lastSkip!!.reason)
            assertEquals(firstNextRun, routine.nextRunAt)
        }
    }

    @Test
    fun aConfirmedTimeoutBecomesTimedOut() {
        val clock = FakeClock(t0)
        harness(clock).use { harness ->
            val runner = ScriptedRunner()
            harness.machine.create(
                botId = "main", title = "T", prompt = "P",
                schedule = RoutineSchedule.interval(60, timezone = taipei),
                now = t0, id = "r",
            )
            val scheduler = scheduler(
                harness, runner, runTimeoutMs = 1_000, cancelGraceMs = 100,
            )
            clock.set(t0 + 3_600_000)
            scheduler.tick()
            assertEquals(1, runner.started.size)

            clock.advance(1_001)
            scheduler.tick()
            assertEquals(1, runner.started[0].cancelCalls)

            clock.advance(100)
            scheduler.tick()
            val delivery = harness.machine.delivery("r:1", "main")!!
            assertEquals(RoutineRunStatus.TIMED_OUT, delivery.resultStatus)
            assertEquals("", delivery.text)
            assertTrue(delivery.error!!.contains("timed out after 1000ms"))
            assertEquals(RoutineRunStatus.TIMED_OUT, harness.machine.get("main", "r")!!.runState!!.status)
        }
    }

    @Test
    fun anUnconfirmedCancellationBecomesNeedsReconciliation() {
        val clock = FakeClock(t0)
        harness(clock).use { harness ->
            val runner = ScriptedRunner()
            runner.onStart = { handle ->
                handle.cancelResult = RoutineCancellationResult(cancelled = false, reason = "no-cancel-handler")
            }
            harness.machine.create(
                botId = "main", title = "T", prompt = "P",
                schedule = RoutineSchedule.interval(60, timezone = taipei),
                now = t0, id = "r",
            )
            val scheduler = scheduler(harness, runner, runTimeoutMs = 1_000, cancelGraceMs = 100)
            clock.set(t0 + 3_600_000)
            scheduler.tick()
            clock.advance(1_001)
            scheduler.tick()
            clock.advance(100)
            scheduler.tick()

            val delivery = harness.machine.delivery("r:1", "main")!!
            assertEquals(RoutineRunStatus.NEEDS_RECONCILIATION, delivery.resultStatus)
            assertTrue(delivery.error!!.contains("cancellation was not confirmed (no-cancel-handler)"))
            val routine = harness.machine.get("main", "r")!!
            assertEquals(RoutineRunStatus.NEEDS_RECONCILIATION, routine.runState!!.status)
            assertTrue(routine.runState!!.reconciliationRequired)

            clock.advance(24 * 3_600_000)
            scheduler.tick()
            assertEquals("needs-reconciliation blocks new runs", 1, runner.started.size)
        }
    }

    @Test
    fun crashReplayDoesNotDuplicateDeliveries() {
        val clock = FakeClock(t0)
        harness(clock).use { harness ->
            val crashed = ScriptedRunner()
            harness.machine.create(
                botId = "main", title = "T", prompt = "P",
                schedule = RoutineSchedule.interval(60, timezone = taipei),
                now = t0, id = "r",
            )
            val first = scheduler(harness, crashed)
            clock.set(t0 + 3_600_000)
            first.tick()
            assertEquals(1, crashed.started.size)

            // The process dies; a new instance sees the expired lease.
            clock.advance(700_000)
            val recoveredRunner = ScriptedRunner()
            recoveredRunner.onStart = { it.finish(RoutineExecutionResult.success("late")) }
            val recoveredSink = RecordingResultSink()
            val second = scheduler(harness, recoveredRunner, recoveredSink)
            val actions = second.recover()
            assertEquals(1, actions.size)
            assertEquals("needs-reconciliation", actions[0].action)
            assertEquals(1, recoveredSink.delivered.size)
            assertEquals(0, harness.machine.pendingDeliveries("main", clock.now).size)
            assertEquals(
                RoutineRunStatus.NEEDS_RECONCILIATION,
                harness.machine.delivery("r:1", "main")!!.resultStatus,
            )
            assertEquals(RoutineDeliveryStatus.DELIVERED, harness.machine.delivery("r:1", "main")!!.status)

            assertTrue(second.recover().isEmpty())
            assertEquals(1, recoveredSink.delivered.size)
            second.tick()
            assertTrue("a needs-reconciliation run is not replayed", recoveredRunner.started.isEmpty())
        }
    }

    @Test
    fun anIdempotentCrashRetriesOnceAndThenSucceeds() {
        val clock = FakeClock(t0)
        harness(clock).use { harness ->
            val crashed = ScriptedRunner()
            harness.machine.create(
                botId = "main", title = "T", prompt = "P",
                schedule = RoutineSchedule.interval(60, timezone = taipei),
                idempotent = true, now = t0, id = "r",
            )
            val first = scheduler(harness, crashed)
            clock.set(t0 + 3_600_000)
            first.tick()

            clock.advance(700_000)
            val retryRunner = ScriptedRunner()
            retryRunner.onStart = { it.finish(RoutineExecutionResult.success("recovered")) }
            val second = scheduler(harness, retryRunner)
            val actions = second.recover()
            assertEquals("retry", actions[0].action)
            assertNull(actions[0].deliveryKey)
            second.tick()
            assertEquals(1, retryRunner.started.size)
            assertEquals(2, retryRunner.started[0].request.attempt)
            val delivery = harness.machine.delivery("r:2", "main")!!
            assertEquals(RoutineRunStatus.SUCCEEDED, delivery.resultStatus)
            assertNull("the crashed attempt has no delivery", harness.machine.delivery("r:1", "main"))
            assertTrue(second.recover().isEmpty())
        }
    }

    @Test
    fun heldAndInterruptResultsFollowTheirDeliveryMode() {
        val clock = FakeClock(t0)
        harness(clock).use { harness ->
            val runner = ScriptedRunner()
            runner.onStart = { it.finish(RoutineExecutionResult.success("有三项变化")) }
            harness.machine.create(
                botId = "main", title = "Held", prompt = "P",
                schedule = RoutineSchedule.interval(60, timezone = taipei),
                now = t0, id = "held",
            )
            harness.machine.create(
                botId = "main", title = "Interrupt", prompt = "P",
                schedule = RoutineSchedule.interval(60, timezone = taipei),
                delivery = RoutineDeliveryMode.INTERRUPT, interruptReason = "用户在等",
                now = t0, id = "interrupt",
            )
            val considerer = RecordingInterrupt()
            val scheduler = scheduler(harness, runner, proactive = considerer)
            clock.set(t0 + 3_600_000)
            scheduler.tick()

            assertEquals(2, runner.started.size)
            assertEquals(2, harness.inbox.items().size)
            val heldDelivery = harness.machine.delivery("held:1", "main")!!
            assertEquals("delivered", heldDelivery.heldInbox)
            assertNull(heldDelivery.notified)
            val interruptDelivery = harness.machine.delivery("interrupt:1", "main")!!
            assertEquals("sent", interruptDelivery.notified)
            assertEquals("on", interruptDelivery.proactiveMode)
            assertTrue(interruptDelivery.proactiveHandled)
            assertEquals(1, considerer.candidates.size)
            assertEquals("routine-result", considerer.candidates[0].kind)
            assertEquals("routine.run_finished", considerer.candidates[0].trigger)
        }
    }

    @Test
    fun aQuietResultIsNotHeldButIsStillDelivered() {
        val clock = FakeClock(t0)
        harness(clock).use { harness ->
            val runner = ScriptedRunner()
            runner.onStart = { it.finish(RoutineExecutionResult.success("[quiet]")) }
            harness.machine.create(
                botId = "main", title = "T", prompt = "P",
                schedule = RoutineSchedule.interval(60, timezone = taipei),
                now = t0, id = "r",
            )
            val sink = RecordingResultSink()
            val scheduler = scheduler(harness, runner, sink)
            clock.set(t0 + 3_600_000)
            scheduler.tick()
            val delivery = harness.machine.delivery("r:1", "main")!!
            assertTrue(delivery.quiet)
            assertEquals("", delivery.text)
            assertEquals(0, harness.inbox.items().size)
            assertEquals(1, sink.delivered.size)
            assertEquals("已完成（没有新结果）", sink.delivered[0].result)
        }
    }

    @Test
    fun anInterruptFailureIsConsideredForNotification() {
        val clock = FakeClock(t0)
        harness(clock).use { harness ->
            val runner = ScriptedRunner()
            runner.onStart = { it.finish(RoutineExecutionResult.failure("boom")) }
            harness.machine.create(
                botId = "main", title = "发布窗口检查", prompt = "P",
                schedule = RoutineSchedule.interval(60, timezone = taipei),
                delivery = RoutineDeliveryMode.INTERRUPT, interruptReason = "用户在等",
                now = t0, id = "r",
            )
            val considerer = RecordingInterrupt()
            val scheduler = scheduler(harness, runner, proactive = considerer)
            clock.set(t0 + 3_600_000)
            scheduler.tick()
            assertEquals(1, considerer.candidates.size)
            assertTrue(considerer.candidates[0].body.contains("执行失败"))
            assertEquals("failed", considerer.candidates[0].status)
        }
    }

    @Test
    fun aUserCancelKeepsCancelOrigin() {
        val clock = FakeClock(t0)
        harness(clock).use { harness ->
            val runner = ScriptedRunner()
            harness.machine.create(
                botId = "main", title = "T", prompt = "P",
                schedule = RoutineSchedule.interval(60, timezone = taipei),
                now = t0, id = "r",
            )
            val considerer = RecordingInterrupt()
            val scheduler = scheduler(harness, runner, proactive = considerer)
            clock.set(t0 + 3_600_000)
            scheduler.tick()
            val handle = runner.started[0]
            assertEquals(RoutineDeliveryMode.HELD, harness.machine.get("main", "r")!!.delivery)

            val cancelled = scheduler.cancelRunning("r")
            assertTrue(cancelled.cancelled)
            assertEquals(1, handle.cancelCalls)
            handle.finish(RoutineExecutionResult(status = RoutineExecutionStatus.CANCELLED, cancelledBy = "user"))
            scheduler.tick()
            val delivery = harness.machine.delivery("r:1", "main")!!
            assertEquals(RoutineRunStatus.CANCELLED, delivery.resultStatus)
            assertEquals("user", delivery.cancelOrigin)
            assertTrue(considerer.candidates.isEmpty())
            assertFalse(scheduler.cancelRunning("r").cancelled)
        }
    }

    @Test
    fun aDeniedOrExpiredApprovalDeliversTheTerminalFailure() {
        for (case in listOf(Triple(false, false, false), Triple(false, true, false), Triple(false, false, true))) {
            val clock = FakeClock(t0)
            harness(clock).use { harness ->
                val runner = ScriptedRunner()
                runner.onStart = { handle ->
                    handle.finish(RoutineExecutionResult.waiting("approval-1", "session-1"))
                }
                harness.machine.create(
                    botId = "main", title = "T", prompt = "P",
                    schedule = RoutineSchedule.interval(60, timezone = taipei),
                    now = t0, id = "r",
                )
                val scheduler = scheduler(harness, runner)
                clock.set(t0 + 3_600_000)
                scheduler.tick()
                assertEquals(
                    RoutineRunStatus.WAITING_APPROVAL,
                    harness.machine.get("main", "r")!!.runState!!.status,
                )
                assertEquals(1, scheduler.waitingApprovalEntries().size)
                assertEquals("approval-1", scheduler.waitingApprovalEntries()[0].approvalId)
                assertEquals(0, harness.machine.pendingDeliveries("main", clock.now).size)

                scheduler.approvalResolved(
                    approvalId = "approval-1", sessionId = "session-1",
                    allowed = case.first, expired = case.second, cancelled = case.third,
                )
                val delivery = harness.machine.delivery("r:1", "main")!!
                if (case.third) {
                    assertEquals(RoutineRunStatus.CANCELLED, delivery.resultStatus)
                    assertEquals("approval_cancelled", delivery.error)
                    assertEquals("user", delivery.cancelOrigin)
                } else {
                    assertEquals(RoutineRunStatus.FAILED, delivery.resultStatus)
                    assertEquals(if (case.second) "approval_expired" else "approval_denied", delivery.error)
                }
            }
        }
    }

    @Test
    fun anApprovalThatWinsTheRaceResumesImmediately() {
        val clock = FakeClock(t0)
        harness(clock).use { harness ->
            val runner = ScriptedRunner()
            runner.onStart = { handle ->
                if (runner.started.size == 1) {
                    handle.finish(RoutineExecutionResult.waiting("approval-1", "session-1"))
                } else {
                    handle.finish(RoutineExecutionResult.success("resumed"))
                }
            }
            harness.machine.create(
                botId = "main", title = "T", prompt = "P",
                schedule = RoutineSchedule.interval(60, timezone = taipei),
                now = t0, id = "r",
            )
            val scheduler = scheduler(harness, runner)
            // The decision arrives before the run has persisted waiting-approval.
            scheduler.approvalResolved(
                approvalId = "approval-1", sessionId = "session-1", allowed = true,
            )
            clock.set(t0 + 3_600_000)
            scheduler.tick()
            assertEquals(2, runner.started.size)
            assertEquals("approval-1", runner.started[1].request.resumeApprovalId)
            assertTrue(runner.started[1].request.wake.text.contains("[approval_resume]"))
            assertEquals(1, runner.started[1].request.attempt)
            val delivery = harness.machine.delivery("r:1", "main")!!
            assertEquals(RoutineRunStatus.SUCCEEDED, delivery.resultStatus)
            assertEquals("resumed", delivery.text)
        }
    }

    @Test
    fun notificationsAreReconciledWithTheSystemAndDnd() {
        val clock = FakeClock(epoch(2025, 10, 9, 12, 0, 0, taipei))
        harness(clock).use { harness ->
            for ((index, time) in listOf("09:00", "10:00", "11:00").withIndex()) {
                harness.machine.create(
                    botId = "main", title = "R$index", prompt = "P",
                    schedule = RoutineSchedule.daily(time, taipei),
                    now = clock.now, id = "r$index",
                )
            }
            val notifications = InMemoryRoutineNotificationScheduling()
            var settings = RoutineQuietSettings(quietStart = "00:00", quietEnd = "00:00", timeZone = taipei)
            val scheduler = scheduler(
                harness,
                ImmediateRoutineRunner { RoutineExecutionResult.success("ok") },
                notifications = notifications,
                settings = { settings },
            )
            scheduler.syncNotifications()
            assertEquals(3, notifications.pending().size)
            assertEquals(3, scheduler.presenceSnapshot(false, false).scheduledNotificationCount)
            assertEquals(
                notifications.pending().minOf { it.fireAt },
                scheduler.presenceSnapshot(false, false).nextNotificationAt,
            )
            val firstIdentifier = notifications.pending().first().identifier
            assertTrue(firstIdentifier.startsWith("routine-due:main:r0:"))

            settings = settings.copy(dnd = true)
            scheduler.syncNotifications()
            assertEquals(0, notifications.pending().size)
            assertEquals(0, scheduler.presenceSnapshot(false, false).scheduledNotificationCount)

            settings = settings.copy(dnd = false)
            scheduler.syncNotifications()
            assertEquals(3, notifications.pending().size)

            // A system purge must be repaired on the next reconciliation.
            val callsBefore = notifications.scheduleCalls
            notifications.purgeSystemPending("routine-due:main:")
            scheduler.syncNotifications()
            assertEquals(3, notifications.pending().size)
            assertTrue(notifications.scheduleCalls > callsBefore)

            // A reschedule cancels the old identifier and registers the new one.
            harness.clock.advance(1_000)
            harness.machine.update(
                "main", "r0", RoutinePatch(schedule = RoutineSchedule.daily("12:00", taipei)),
                now = harness.clock.now,
            )
            scheduler.syncNotifications()
            val pending = notifications.pending()
            assertEquals(3, pending.size)
            assertFalse(pending.any { it.identifier.startsWith("routine-due:main:r0:") && it.identifier.endsWith(":${epoch(2025, 10, 10, 9, 0, 0, taipei)}") })
            assertTrue(pending.any { it.identifier.endsWith(":${epoch(2025, 10, 10, 12, 0, 0, taipei)}") })
        }
    }

    @Test
    fun quietRoutineNotificationsFireAtTheQuietEnd() {
        val clock = FakeClock(epoch(2025, 10, 9, 20, 0, 0, taipei))
        harness(clock).use { harness ->
            harness.machine.create(
                botId = "main", title = "夜间摘要", prompt = "P",
                schedule = RoutineSchedule.daily("09:00", taipei),
                now = clock.now, id = "quiet",
            )
            harness.machine.create(
                botId = "main", title = "发布窗口检查", prompt = "P",
                schedule = RoutineSchedule.daily("09:00", taipei),
                urgent = true, urgentReason = "生产故障", now = clock.now, id = "urgent",
            )
            val notifications = InMemoryRoutineNotificationScheduling()
            val scheduler = scheduler(
                harness,
                ImmediateRoutineRunner { RoutineExecutionResult.success("ok") },
                notifications = notifications,
                settings = {
                    RoutineQuietSettings(quietStart = "08:00", quietEnd = "10:00", timeZone = taipei)
                },
            )
            scheduler.syncNotifications()
            val quiet = notifications.pending().first { it.routineId == "quiet" }
            val urgent = notifications.pending().first { it.routineId == "urgent" }
            assertEquals(epoch(2025, 10, 10, 10, 0, 0, taipei), quiet.fireAt)
            assertEquals(epoch(2025, 10, 10, 9, 0, 0, taipei), urgent.fireAt)
            assertEquals(
                "routine-due:main:quiet:${quiet.fireAt}",
                quiet.identifier,
            )
        }
    }

    @Test
    fun atMostSixtyRoutineNotificationsAreKept() {
        val clock = FakeClock(epoch(2025, 10, 9, 12, 0, 0, taipei))
        harness(clock).use { harness ->
            for (index in 0..60) {
                val minutes = index % 60
                harness.machine.create(
                    botId = "main", title = "R$index", prompt = "P",
                    schedule = RoutineSchedule.daily("00:%02d".format(minutes), taipei),
                    now = clock.now, id = "r$index",
                )
            }
            val notifications = InMemoryRoutineNotificationScheduling()
            val scheduler = scheduler(
                harness,
                ImmediateRoutineRunner { RoutineExecutionResult.success("ok") },
                notifications = notifications,
            )
            scheduler.syncNotifications()
            assertEquals(RoutineScheduler.MAX_SCHEDULED_NOTIFICATIONS, notifications.pending().size)
            assertEquals(
                "the earliest 60 are kept",
                epoch(2025, 10, 10, 0, 0, 0, taipei),
                notifications.pending().minOf { it.fireAt },
            )
            assertFalse(
                notifications.pending().any {
                    it.fireAt == epoch(2025, 10, 10, 1, 0, 0, taipei)
                },
            )
        }
    }

    @Test
    fun availabilityAndBusySeamsGateTheRun() {
        harness().use { harness ->
            val runner = ScriptedRunner()
            harness.machine.create(
                botId = "main", title = "T", prompt = "P",
                schedule = RoutineSchedule.interval(60, timezone = taipei),
                now = t0, id = "r",
            )
            var available = false
            var busy = false
            val scheduler = scheduler(
                harness, runner,
                available = { available },
                busy = { busy },
            )
            harness.clock.set(t0 + 3_600_000)
            scheduler.tick()
            assertEquals(0, runner.started.size)
            available = true
            busy = true
            scheduler.tick()
            assertEquals(0, runner.started.size)
            busy = false
            scheduler.tick()
            assertEquals(1, runner.started.size)
        }
    }

    @Test
    fun aFailedDeliveryIsRetriedByRecovery() {
        val clock = FakeClock(t0)
        harness(clock).use { harness ->
            val runner = ScriptedRunner()
            runner.onStart = { it.finish(RoutineExecutionResult.success("ok")) }
            harness.machine.create(
                botId = "main", title = "T", prompt = "P",
                schedule = RoutineSchedule.interval(60, timezone = taipei),
                now = t0, id = "r",
            )
            val sink = RecordingResultSink()
            val scheduler = scheduler(harness, runner, sink)
            sink.failNext = true
            clock.set(t0 + 3_600_000)
            scheduler.tick()
            assertEquals(0, sink.delivered.size)
            val pending = harness.machine.delivery("r:1", "main")!!
            assertEquals(RoutineDeliveryStatus.PENDING, pending.status)
            assertEquals(1, pending.attempts)
            assertEquals("sink exploded", pending.lastError)

            scheduler.recover()
            assertEquals(1, sink.delivered.size)
            assertEquals(RoutineDeliveryStatus.DELIVERED, harness.machine.delivery("r:1", "main")!!.status)
        }
    }

    @Test
    fun aStoppedSchedulerDoesNotTickAndStartIsIdempotent() {
        harness().use { harness ->
            val runner = ScriptedRunner()
            harness.machine.create(
                botId = "main", title = "T", prompt = "P",
                schedule = RoutineSchedule.interval(1, timezone = taipei),
                now = t0, id = "r",
            )
            val scheduler = scheduler(harness, runner)
            scheduler.stop()
            harness.clock.set(t0 + 60_000)
            scheduler.tick()
            assertEquals(0, runner.started.size)
            scheduler.start()
            scheduler.start()
            scheduler.stop()
        }
    }

    @Test
    fun queuedRoutinesListsOnlyEnabledDueRuns() {
        harness().use { harness ->
            harness.machine.create(
                botId = "main", title = "A", prompt = "P",
                schedule = RoutineSchedule.daily("09:00", taipei), now = t0, id = "a",
            )
            harness.machine.create(
                botId = "main", title = "B", prompt = "P",
                schedule = RoutineSchedule.daily("10:00", taipei), now = t0, id = "b",
            )
            harness.machine.create(
                botId = "main", title = "C", prompt = "P",
                schedule = RoutineSchedule.daily("11:00", taipei), enabled = false, now = t0, id = "c",
            )
            val scheduler = scheduler(harness, ImmediateRoutineRunner { RoutineExecutionResult.success("ok") })
            assertTrue(scheduler.queuedRoutines(now = t0).isEmpty())
            val queued = scheduler.queuedRoutines(now = 1_760_058_000_000L)
            assertEquals(listOf("a"), queued.map { it.id })
        }
    }
}
