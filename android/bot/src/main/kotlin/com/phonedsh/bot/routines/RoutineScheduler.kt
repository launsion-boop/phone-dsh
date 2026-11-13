// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import com.phonedsh.bot.wake.RoutineReply
import com.phonedsh.bot.wake.RoutineWakeBuilder
import com.phonedsh.bot.wake.RoutineWakeMode
import com.phonedsh.bot.wake.WakeInbox
import com.phonedsh.bot.wake.WakeInboxItem

/**
 * The routine scheduler (`Sources/PhoneDSHBot/Routines/RoutineScheduler.swift`;
 * D9 §4–§8, v2 §3.1).
 *
 * The clock, the runner and the notification center are injected. One
 * [tick] decides defer/overlap/timeout and advances at most one attempt per
 * routine; the runner returns a [RoutineRunHandle] and the next poll observes
 * its result, so a fake clock can prove that a due routine fires exactly once
 * and that a run which never confirms cancellation becomes
 * `needs-reconciliation` instead of being silently re-run.
 */
class RoutineScheduler(
    val botId: String,
    val machine: RoutineMachine,
    val inbox: WakeInbox,
    private val sink: RoutineResultSink,
    private val runner: RoutineRunner,
    private val proactive: RoutineInterruptConsiderer? = null,
    private val notifications: RoutineNotificationScheduling? = null,
    private val approvalCanceller: ((String) -> Boolean)? = null,
    private val available: (String) -> Boolean = { true },
    private val busy: (String) -> Boolean = { false },
    private val settingsProvider: () -> RoutineQuietSettings = { RoutineQuietSettings() },
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val tickIntervalMs: Long = 5_000,
    private val runTimeoutMs: Long = 600_000,
    private val cancelGraceMs: Long = 5_000,
    private val leaseOwner: String = "local",
) {
    private data class ActiveRun(
        val claim: RoutineClaim,
        val state: RoutineRunState,
        val startedAt: Long,
        val deadlineAt: Long,
        val handle: RoutineRunHandle,
        var cancelRequestedAt: Long? = null,
        var cancelOutcome: RoutineCancellationResult? = null,
    )

    data class WaitingApprovalEntry(val approvalId: String, val sessionId: String, val routineId: String)

    private val active = LinkedHashMap<String, ActiveRun>()
    private val scheduledNotifications = LinkedHashMap<String, RoutineScheduledNotification>()
    private val earlyApprovalDecisions = HashMap<String, Triple<Boolean, Boolean, Boolean>>()
    private var ticking = false
    private var stopped = false
    private var timer: Thread? = null

    private val effectiveTickIntervalMs: Long = maxOf(1_000L, tickIntervalMs)
    private val effectiveRunTimeoutMs: Long = maxOf(1L, runTimeoutMs)
    private val effectiveCancelGraceMs: Long = maxOf(0L, cancelGraceMs)
    private val runLeaseTtlMs: Long = effectiveRunTimeoutMs + effectiveCancelGraceMs + 60_000L

    init {
        require(botId.isNotEmpty()) { "botId must not be empty" }
    }

    // ------------------------------------------------------------------
    // lifecycle
    // ------------------------------------------------------------------

    /** Starts a daemon loop that calls recover+tick every interval. */
    @Synchronized
    fun start() {
        if (timer != null) return
        stopped = false
        val thread = Thread {
            while (!stopped) {
                runCatching { restoreAndTick() }
                try {
                    Thread.sleep(effectiveTickIntervalMs)
                } catch (_: InterruptedException) {
                    return@Thread
                }
            }
        }
        thread.isDaemon = true
        thread.name = "routine-scheduler-$botId"
        timer = thread
        thread.start()
    }

    @Synchronized
    fun stop() {
        stopped = true
        timer?.interrupt()
        timer = null
    }

    @Synchronized
    fun queuedRoutines(now: Long = clock()): List<Routine> = machine.list(botId).filter {
        it.enabled && it.runState?.status != RoutineRunStatus.NEEDS_RECONCILIATION &&
            it.runState?.status != RoutineRunStatus.WAITING_APPROVAL &&
            (it.nextRunAt ?: Long.MAX_VALUE) <= now
    }.sortedWith(compareBy({ it.nextRunAt ?: 0L }, { it.createdAt }, { it.id }))

    private fun restoreAndTick() {
        runCatching { recover() }
        runCatching { tick() }
    }

    // ------------------------------------------------------------------
    // recovery and tick
    // ------------------------------------------------------------------

    @Synchronized
    fun recover(): List<RoutineRecoveryAction> {
        val now = clock()
        val actions = machine.recover(
            botId, now, leaseOwner = leaseOwner, excludeRunIds = active.keys.toSet(),
        )
        inbox.recover()
        for (item in machine.pendingDeliveries(botId, now, includeDelivering = true)) {
            hold(item)
            if (!item.proactiveHandled) considerInterrupt(item)
            machine.delivery(item.deliveryKey, botId)?.let { deliver(it, force = true) }
        }
        for (action in actions) {
            action.deliveryKey?.let { key ->
                machine.delivery(key, botId)?.let { publish(it) }
            }
        }
        syncNotifications()
        return actions
    }

    @Synchronized
    fun tick() {
        val now = clock()
        if (ticking) {
            for (routineId in active.keys.toList()) {
                machine.recordSkip(botId, routineId, at = now)
            }
            return
        }
        if (stopped) return
        ticking = true
        try {
            pollActive(now)
            val recovery = machine.recover(
                botId, now, leaseOwner = leaseOwner, excludeRunIds = active.keys.toSet(),
            )
            for (action in recovery) {
                action.deliveryKey?.let { key ->
                    machine.delivery(key, botId)?.let { publish(it) }
                }
            }
            for (initial in machine.list(botId)) {
                var routine = initial
                val status = routine.runState?.status
                if (!routine.enabled || status == RoutineRunStatus.NEEDS_RECONCILIATION) continue
                if (status == RoutineRunStatus.WAITING_APPROVAL) continue
                if (status == RoutineRunStatus.STARTED) {
                    if (routine.id in active) machine.recordSkip(botId, routine.id, at = now)
                    continue
                }
                if (routine.id in active) {
                    machine.recordSkip(botId, routine.id, at = now)
                    continue
                }
                if (routine.nextRunAt == null) {
                    machine.repairNextRun(botId, routine.id, now)?.let { routine = it }
                }
                val nextRunAt = routine.nextRunAt ?: continue
                if (nextRunAt > now) continue
                val settings = settingsProvider().normalized()
                val mayBypassQuiet = routine.urgent &&
                    RoutineDeliveryFlags.clean(routine.urgentReason).isNotEmpty()
                if (!mayBypassQuiet && RoutineQuietHours.contains(now, settings)) {
                    val until = RoutineQuietHours.nextEnd(now, settings)
                    if (until != null && until > now) {
                        machine.deferForQuiet(botId, routine.id, until = until, now = now)
                        continue
                    }
                }
                if (!available(botId) || busy(botId)) continue
                val startedAt = clock()
                val claim = machine.begin(
                    botId, routine.id, startedAt = startedAt, scheduledFor = nextRunAt,
                    leaseOwner = leaseOwner, leaseTtlMs = runLeaseTtlMs,
                ) ?: continue
                if (!claim.claimed) continue
                cancelScheduledNotifications(routine.id)
                launch(claim, startedAt)
            }
        } finally {
            ticking = false
        }
        syncNotifications()
    }

    /** Cancels the running attempt of one routine (the information page's stop). */
    @Synchronized
    fun cancelRunning(routineId: String): RoutineCancellationResult {
        val routine = machine.get(botId, routineId)
            ?: return RoutineCancellationResult(cancelled = false, reason = "routine is not running")
        val state = routine.runState
            ?: return RoutineCancellationResult(cancelled = false, reason = "routine is not running")
        if (state.status == RoutineRunStatus.WAITING_APPROVAL) {
            val approvalId = state.waitingApprovalId
                ?: return RoutineCancellationResult(cancelled = false, reason = "waiting approval is not recorded")
            val canceller = approvalCanceller
                ?: return RoutineCancellationResult(cancelled = false, reason = "no-approval-cancel-handler")
            val cancelled = canceller(approvalId)
            return RoutineCancellationResult(
                cancelled = cancelled,
                reason = if (cancelled) null else "approval is no longer pending",
            )
        }
        val run = active[routineId]
        if (run == null || state.status != RoutineRunStatus.STARTED) {
            return RoutineCancellationResult(cancelled = false, reason = "routine is not running")
        }
        val outcome = run.handle.cancel("user")
        pollActive(clock())
        return outcome
    }

    fun waitForIdle() {
        while (ticking || active.isNotEmpty()) Thread.yield()
    }

    // ------------------------------------------------------------------
    // durable approval suspension / resume
    // ------------------------------------------------------------------

    /** One terminal decision for a parked run; kept if the park has not landed yet. */
    @Synchronized
    fun approvalResolved(
        approvalId: String,
        sessionId: String,
        allowed: Boolean,
        expired: Boolean = false,
        cancelled: Boolean = false,
    ) {
        val routine = machine.list(botId)
            .firstOrNull { it.runState?.waitingApprovalId == approvalId }
        if (routine != null) {
            if (allowed) {
                resumeWaiting(routine, approvalId)
            } else {
                denyWaiting(routine, approvalId, expired = expired, cancelled = cancelled)
            }
            return
        }
        earlyApprovalDecisions[approvalId] = Triple(allowed, expired, cancelled)
    }

    fun waitingApprovalEntries(): List<WaitingApprovalEntry> = machine.list(botId).mapNotNull { routine ->
        val state = routine.runState ?: return@mapNotNull null
        if (state.status != RoutineRunStatus.WAITING_APPROVAL) return@mapNotNull null
        val approvalId = state.waitingApprovalId ?: return@mapNotNull null
        val sessionId = state.waitingSessionId ?: return@mapNotNull null
        WaitingApprovalEntry(approvalId, sessionId, routine.id)
    }

    private fun applyEarlyApprovalIfAny(approvalId: String) {
        val decision = earlyApprovalDecisions.remove(approvalId) ?: return
        val routine = machine.list(botId).firstOrNull { it.runState?.waitingApprovalId == approvalId }
            ?: return
        if (decision.first) {
            resumeWaiting(routine, approvalId)
        } else {
            denyWaiting(routine, approvalId, expired = decision.second, cancelled = decision.third)
        }
    }

    private fun resumeWaiting(routine: Routine, approvalId: String) {
        val state = routine.runState ?: return
        val claim = machine.resumeWaitingApproval(
            botId, routine.id, approvalId, now = clock(),
            leaseOwner = leaseOwner, leaseTtlMs = runLeaseTtlMs,
        ) ?: return
        if (!claim.claimed) return
        val resumedState = claim.routine.runState ?: return
        if (routine.id !in active) {
            launch(claim, state.startedAt, resumeApprovalId = approvalId, resumeSessionId = state.waitingSessionId)
        }
    }

    private fun denyWaiting(routine: Routine, approvalId: String, expired: Boolean, cancelled: Boolean) {
        val state = routine.runState ?: return
        if (state.waitingApprovalId != approvalId) return
        if (cancelled) {
            val finished = machine.finish(
                botId, routine.id, status = RoutineRunStatus.CANCELLED,
                text = "", error = "approval_cancelled",
                startedAt = state.startedAt, finishedAt = clock(),
                attempt = state.attempt, runId = state.runId, cancelOrigin = "user",
            ) ?: return
            if (!finished.ignored) finished.delivery?.let { publish(it) }
            return
        }
        val error = if (expired) "approval_expired" else "approval_denied"
        val finished = machine.finish(
            botId, routine.id, status = RoutineRunStatus.FAILED,
            text = "", error = error,
            startedAt = state.startedAt, finishedAt = clock(),
            attempt = state.attempt, runId = state.runId,
        ) ?: return
        if (!finished.ignored) finished.delivery?.let { publish(it) }
    }

    // ------------------------------------------------------------------
    // local notifications and presence
    // ------------------------------------------------------------------

    @Synchronized
    fun syncNotifications() {
        val notifications = notifications ?: return
        val now = clock()
        val settings = settingsProvider().normalized()
        val routines = machine.list(botId)
        val desired = ArrayList<RoutineScheduledNotification>()
        if (!settings.dnd) {
            for (routine in routines) {
                if (!routine.enabled) continue
                val nextRunAt = routine.nextRunAt ?: continue
                val mayBypassQuiet = routine.urgent &&
                    RoutineDeliveryFlags.clean(routine.urgentReason).isNotEmpty()
                var fireAt = nextRunAt
                if (!mayBypassQuiet && RoutineQuietHours.contains(nextRunAt, settings)) {
                    RoutineQuietHours.nextEnd(nextRunAt, settings)?.let { fireAt = maxOf(nextRunAt, it) }
                }
                if (fireAt <= now) continue
                desired += RoutineScheduledNotification.forRoutine(botId, routine.id, routine.title, fireAt)
            }
        }
        desired.sortWith(compareBy({ it.fireAt }, { it.identifier }))
        val trimmed = desired.take(MAX_SCHEDULED_NOTIFICATIONS)
        val desiredIds = trimmed.map { it.identifier }.toSet()
        val prefix = "routine-due:$botId:"
        val pending = notifications.pendingIdentifiers(prefix).toSet()
        val existingSignatures = LinkedHashMap(scheduledNotifications)
        val stale = (pending - desiredIds) + scheduledNotifications.keys.filter { it !in desiredIds }
        if (stale.isNotEmpty()) {
            val identifiers = stale.sorted()
            notifications.cancel(identifiers)
            for (identifier in identifiers) scheduledNotifications.remove(identifier)
        }
        for (notification in trimmed) {
            if (scheduledNotifications[notification.identifier] == notification) continue
            try {
                notifications.schedule(notification)
                scheduledNotifications[notification.identifier] = notification
            } catch (_: Exception) {
                scheduledNotifications.remove(notification.identifier)
            }
        }
        // A system purge leaves our signature but no pending request; register
        // it again on the next reconciliation.
        for (identifier in desiredIds) {
            if (identifier in pending) continue
            if (existingSignatures[identifier] == null) continue
            val notification = trimmed.firstOrNull { it.identifier == identifier } ?: continue
            try {
                notifications.schedule(notification)
            } catch (_: Exception) {
                scheduledNotifications.remove(identifier)
            }
        }
        scheduledNotifications.keys.retainAll(desiredIds)
    }

    fun scheduledNotificationsSnapshot(): List<RoutineScheduledNotification> =
        scheduledNotifications.values.sortedWith(compareBy({ it.fireAt }, { it.identifier }))

    fun presenceSnapshot(appActive: Boolean, keepingAlive: Boolean): RoutinePresence {
        val routines = machine.list(botId)
        return RoutinePresence(
            level = RoutinePresencePolicy.level(appActive, keepingAlive, scheduledNotifications.size),
            deferred = RoutinePresencePolicy.deferred(routines),
            scheduledNotificationCount = scheduledNotifications.size,
            nextNotificationAt = scheduledNotifications.values.minOfOrNull { it.fireAt },
        )
    }

    /** Applies a settings edit immediately: reconcile, then run a tick. */
    fun applySettingsChange() {
        syncNotifications()
        tick()
    }

    private fun cancelScheduledNotifications(routineId: String) {
        val notifications = notifications ?: return
        val prefix = "routine-due:$botId:$routineId:"
        val identifiers = LinkedHashSet<String>()
        identifiers += notifications.pendingIdentifiers(prefix)
        identifiers += scheduledNotifications.keys.filter { it.startsWith(prefix) }
        if (identifiers.isEmpty()) return
        val sorted = identifiers.sorted()
        notifications.cancel(sorted)
        for (identifier in sorted) scheduledNotifications.remove(identifier)
    }

    // ------------------------------------------------------------------
    // execution
    // ------------------------------------------------------------------

    private fun launch(
        claim: RoutineClaim,
        startedAt: Long,
        resumeApprovalId: String? = null,
        resumeSessionId: String? = null,
    ) {
        val routine = claim.routine
        val state = routine.runState ?: return
        val wake = try {
            RoutineWakeBuilder.build(routine, mode = RoutineWakeMode.DUE, firedAt = startedAt, now = startedAt)
        } catch (error: Exception) {
            settle(claim, state, startedAt, RoutineExecutionResult.failure(
                "wake build failed: ${error.message ?: "unknown error"}",
            ))
            return
        }
        var text = wake.text
        if (resumeApprovalId != null) {
            text += "\n\n[approval_resume] The user approved the pending $resumeApprovalId approval. " +
                "Continue this same routine run from where it stopped; " +
                "do not repeat side effects that already happened."
        }
        val request = RoutineRunRequest(
            botId = botId,
            routine = routine,
            runId = state.runId,
            attempt = state.attempt,
            startedAt = startedAt,
            timeoutMs = effectiveRunTimeoutMs + effectiveCancelGraceMs + 1_000L,
            wake = RoutineWakePrompt(text = text, cue = wake.cue, mode = wake.mode.rawValue),
            resumeApprovalId = resumeApprovalId,
            resumeSessionId = resumeSessionId,
        )
        val handle = try {
            runner.start(request)
        } catch (error: Exception) {
            settle(claim, state, startedAt, RoutineExecutionResult.failure(
                "routine run failed to start: ${error.message ?: "unknown error"}",
            ))
            return
        }
        val run = ActiveRun(
            claim = claim,
            state = state,
            startedAt = startedAt,
            deadlineAt = startedAt + effectiveRunTimeoutMs,
            handle = handle,
        )
        active[routine.id] = run
        pollActive(clock())
    }

    private fun pollActive(now: Long) {
        for (routineId in active.keys.toList()) {
            val run = active[routineId] ?: continue
            val result = run.handle.resultOrNull()
            if (run.cancelRequestedAt == null) {
                if (result != null) {
                    settleActive(routineId, run, result)
                    continue
                }
                if (now < run.deadlineAt) continue
                val outcome = run.handle.cancel("timeout")
                run.cancelOutcome = outcome
                run.cancelRequestedAt = now
                if (run.handle.resultOrNull() != null) {
                    settleActive(routineId, run, timeoutResult(run, outcome))
                }
                continue
            }
            val cancelAt = run.cancelRequestedAt ?: continue
            if (result != null) {
                settleActive(routineId, run, timeoutResult(run, run.cancelOutcome))
            } else if (now >= cancelAt + effectiveCancelGraceMs) {
                settleActive(routineId, run, timeoutResult(run, run.cancelOutcome))
            }
        }
    }

    private fun timeoutResult(run: ActiveRun, outcome: RoutineCancellationResult?): RoutineExecutionResult {
        val base = "routine run timed out after ${effectiveRunTimeoutMs}ms"
        val confirmed = outcome?.cancelled == true && !outcome.reconciliationRequired
        if (confirmed) {
            return RoutineExecutionResult(
                status = RoutineExecutionStatus.CANCELLED,
                error = base,
                cancelledBy = "timeout",
            )
        }
        val reason = outcome?.reason?.let { " ($it)" } ?: ""
        return RoutineExecutionResult(
            status = RoutineExecutionStatus.FAILED,
            error = "$base; cancellation was not confirmed$reason",
            cancelledBy = "timeout",
        )
    }

    private fun settleActive(routineId: String, run: ActiveRun, result: RoutineExecutionResult) {
        active.remove(routineId)
        settle(run.claim, run.state, run.startedAt, result)
    }

    private fun settle(
        claim: RoutineClaim,
        runState: RoutineRunState,
        startedAt: Long,
        result: RoutineExecutionResult,
    ) {
        val routine = claim.routine
        if (result.status == RoutineExecutionStatus.WAITING_APPROVAL) {
            val approvalId = result.approvalId
            val sessionId = result.sessionId
            if (approvalId == null || sessionId == null) {
                finishAndPublish(
                    claim, runState, startedAt,
                    RoutineExecutionResult.failure("approval pending but no approval or session id"),
                )
                return
            }
            machine.waitForApproval(
                botId, routine.id, approvalId = approvalId, sessionId = sessionId, now = clock(),
            )
            applyEarlyApprovalIfAny(approvalId)
            syncNotifications()
            return
        }
        finishAndPublish(claim, runState, startedAt, result)
    }

    private fun finishAndPublish(
        claim: RoutineClaim,
        runState: RoutineRunState,
        startedAt: Long,
        result: RoutineExecutionResult,
    ) {
        val routine = claim.routine
        var status: RoutineRunStatus
        var cancelOrigin = result.cancelledBy
        if (result.cancelledBy == "timeout") {
            status = if (result.status == RoutineExecutionStatus.CANCELLED) {
                RoutineRunStatus.TIMED_OUT
            } else {
                RoutineRunStatus.NEEDS_RECONCILIATION
            }
        } else {
            status = when (result.status) {
                RoutineExecutionStatus.SUCCEEDED -> RoutineRunStatus.SUCCEEDED
                RoutineExecutionStatus.FAILED -> RoutineRunStatus.FAILED
                RoutineExecutionStatus.CANCELLED -> RoutineRunStatus.CANCELLED.also {
                    cancelOrigin = cancelOrigin ?: "user"
                }
                RoutineExecutionStatus.WAITING_APPROVAL -> RoutineRunStatus.FAILED.also {
                    cancelOrigin = "approval_pending"
                }
            }
        }
        val reply: RoutineReply = if (status == RoutineRunStatus.SUCCEEDED) {
            RoutineWakeBuilder.normalizeReply(result.text)
        } else {
            RoutineReply(text = result.text, quiet = false)
        }
        var text = reply.text
        val quiet = status == RoutineRunStatus.SUCCEEDED && (result.quiet || reply.quiet)
        if (status == RoutineRunStatus.TIMED_OUT || status == RoutineRunStatus.NEEDS_RECONCILIATION) text = ""
        val finished = machine.finish(
            botId = botId, routineId = routine.id, status = status, text = text, error = result.error,
            startedAt = startedAt, finishedAt = clock(), attempt = runState.attempt,
            runId = runState.runId,
            reconcileRequired = status == RoutineRunStatus.NEEDS_RECONCILIATION,
            quiet = quiet, cancelOrigin = cancelOrigin,
        ) ?: return
        if (finished.ignored) return
        finished.delivery?.let { publish(it) }
    }

    private fun publish(delivery: RoutineDelivery) {
        hold(delivery)
        considerInterrupt(delivery)
        machine.delivery(delivery.deliveryKey, botId)?.let { deliver(it) }
        syncNotifications()
    }

    private fun hold(original: RoutineDelivery) {
        if (original.resultStatus != RoutineRunStatus.SUCCEEDED || original.quiet) return
        val text = original.text.trim()
        if (text.isEmpty()) return
        val key = original.deliveryKey
        try {
            val safe = RoutineDelivery.safeRoutineId(original.routineId)
            val item = WakeInboxItem(
                id = "routine-result-${if (safe.isEmpty()) "routine" else safe}-${original.attempt}",
                kind = "routine-result",
                title = original.routineTitle,
                text = RoutineJson.prefixCodePoints(text, 1_200),
                requestId = key,
                createdAt = original.finishedAt,
                ranAt = original.startedAt,
                routineId = original.routineId,
                attempt = original.attempt,
                runId = original.runId,
                deliveryKey = original.deliveryKey,
            )
            inbox.enqueue(item)
            machine.markHeld(key, botId, delivered = true, now = clock())
        } catch (error: Exception) {
            machine.markHeld(
                key, botId, delivered = false,
                error = error.message ?: "held inbox write failed", now = clock(),
            )
        }
    }

    private fun considerInterrupt(original: RoutineDelivery) {
        val considerer = proactive ?: return
        if (original.delivery != RoutineDeliveryMode.INTERRUPT) return
        val successful = original.resultStatus == RoutineRunStatus.SUCCEEDED && !original.quiet &&
            original.text.trim().isNotEmpty()
        val userCancelled = original.resultStatus == RoutineRunStatus.CANCELLED &&
            (original.cancelOrigin ?: "user") == "user"
        val failed = (original.resultStatus == RoutineRunStatus.FAILED ||
            original.resultStatus == RoutineRunStatus.TIMED_OUT ||
            original.resultStatus == RoutineRunStatus.CANCELLED) && !userCancelled
        if (!successful && !failed) return
        val body = if (successful) {
            RoutineScheduleMath.summarize(original.text)
        } else {
            "例行任务「${original.routineTitle}」执行失败：" +
                RoutineScheduleMath.summarize(original.error ?: "未知错误", max = 80)
        }
        val rowId = RoutineDelivery.rowId(original.routineId, original.attempt)
        val key = "routine-result:${original.routineId}:${original.runId}:${original.attempt}"
        val candidate = RoutineInterruptCandidate(
            id = key, kind = "routine-result", botId = botId, dedupeKey = key,
            trigger = "routine.run_finished", createdAt = original.finishedAt,
            title = original.routineTitle, body = body, status = original.resultStatus.rawValue,
            routineId = original.routineId, runId = original.runId, attempt = original.attempt,
            delivery = RoutineDeliveryMode.INTERRUPT, quiet = false,
            resultExcerpt = RoutineJson.prefixCodePoints(original.text, 300),
            deliveryKey = original.deliveryKey, rowId = rowId,
        )
        val decision = considerer.consider(candidate)
        val notified = if (decision.mode == "on") {
            if (decision.decision == "did") "sent" else "skipped"
        } else {
            null
        }
        machine.markNotification(
            original.deliveryKey, botId, notified = notified,
            reason = decision.reason, mode = decision.mode, now = clock(),
        )
    }

    private fun deliver(original: RoutineDelivery, force: Boolean = false) {
        try {
            val claim = machine.claimDelivery(
                original.deliveryKey, botId, leaseOwner = leaseOwner,
                now = clock(), leaseTtlMs = 60_000, force = force,
            )
            if (claim.state != RoutineDeliveryClaim.State.CLAIMED) return
            val delivery = claim.delivery ?: return
            try {
                sink.deliver(RoutineAutomation.from(delivery))
                machine.completeDelivery(delivery.deliveryKey, botId, now = clock())
            } catch (error: Exception) {
                machine.failDelivery(
                    delivery.deliveryKey, botId,
                    error = error.message ?: "delivery failed", now = clock(),
                )
            }
        } catch (_: Exception) {
            return
        }
    }

    companion object {
        /**
         * iOS keeps at most 64 pending notifications per app. Leave four slots
         * for system/other-Bot notifications and keep the earliest 60 routine
         * due times (v2 §3.1).
         */
        const val MAX_SCHEDULED_NOTIFICATIONS: Int = 60
        const val DEFAULT_TICK_INTERVAL_MS: Long = 5_000
        const val DEFAULT_RUN_TIMEOUT_MS: Long = 600_000
        const val DEFAULT_CANCEL_GRACE_MS: Long = 5_000
    }
}
