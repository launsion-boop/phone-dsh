// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.routines.RoutineJson.objectOf
import com.phonedsh.bot.routines.RoutineJson.prefixCodePoints
import com.phonedsh.bot.store.BotEvent
import com.phonedsh.bot.store.BotEventCodec
import com.phonedsh.bot.store.BotEventOrigin
import com.phonedsh.bot.store.BotPrincipal
import java.util.UUID

data class RoutineClaim(
    val routine: Routine,
    val claimed: Boolean,
    val skipReason: String? = null,
    val deliveryKey: String? = null,
)

data class RoutineFinish(
    val routine: Routine,
    val delivery: RoutineDelivery?,
    val ignored: Boolean = false,
)

data class RoutineRecoveryAction(
    val action: String,
    val reason: String,
    val routineId: String,
    val attempt: Int,
    val runId: String,
    val deliveryKey: String? = null,
)

data class RoutineDeliveryClaim(val state: State, val delivery: RoutineDelivery? = null) {
    enum class State { CLAIMED, MISSING, DELIVERED, FAILED, BUSY }
}

/**
 * The pure routine state machine over a [RoutineStore]
 * (`Sources/PhoneDSHBot/Routines/RoutineMachine.swift`; D9 §3–§11).
 *
 * Every method is a single store mutation: the P25 batch either holds the new
 * snapshot plus its lifecycle events or nothing. The clock is always supplied
 * by the caller so the scheduler tests can advance a fake clock.
 */
class RoutineMachine(private val store: RoutineStore) {
    fun list(botId: String): List<Routine> =
        store.read(botId).routines.sortedWith(compareBy({ it.createdAt }, { it.id }))

    fun get(botId: String, routineId: String): Routine? =
        store.read(botId).routines.firstOrNull { it.id == routineId }

    fun create(
        botId: String,
        title: String,
        prompt: String,
        schedule: RoutineSchedule,
        enabled: Boolean = true,
        idempotent: Boolean = false,
        urgent: Boolean = false,
        urgentReason: String = "",
        delivery: RoutineDeliveryMode = RoutineDeliveryMode.HELD,
        interruptReason: String = "",
        creator: RoutineCreator? = null,
        completionCriteria: String = "",
        constraints: String = "",
        now: Long,
        id: String? = null,
    ): Routine {
        val routineId = id ?: "routine-${UUID.randomUUID().toString().replace("-", "").take(12)}"
        val next = if (enabled) {
            RoutineScheduleMath.nextRunAt(schedule, now = now, createdAt = now)
        } else {
            null
        }
        val routine = Routine(
            id = routineId,
            agentId = botId,
            title = title,
            prompt = prompt,
            schedule = schedule,
            enabled = enabled,
            idempotent = idempotent,
            urgent = urgent,
            urgentReason = urgentReason,
            delivery = delivery,
            interruptReason = interruptReason,
            createdAt = now,
            creator = creator,
            completionCriteria = completionCriteria,
            constraints = constraints,
            nextRunAt = next,
        ).validated()
        return store.mutate(botId) { document ->
            if (document.routines.any { it.id == routineId }) {
                throw RoutineError.InvalidRoutine("routine already exists: $routineId")
            }
            RoutineMutation(
                value = routine,
                document = document.copy(routines = document.routines + routine),
                botId = botId,
            )
        }
    }

    fun update(botId: String, routineId: String, patch: RoutinePatch, now: Long): Routine =
        store.mutate(botId) { document ->
            val index = document.routines.indexOfFirst { it.id == routineId }
            if (index < 0) throw RoutineError.RoutineNotFound(routineId)
            val current = document.routines[index]
            var next = patch.applyTo(current).validated()

            val scheduleChanged = patch.schedule != null
            val reenabled = patch.enabled == true && !current.enabled
            if (patch.enabled == false || scheduleChanged || reenabled) {
                next = next.copy(quietDefer = null)
            } else if (patch.urgent == true) {
                next.quietDefer?.let { deferred ->
                    next = next.copy(quietDefer = null, nextRunAt = deferred.scheduledFor)
                }
            }
            if (!next.enabled) {
                next = next.copy(nextRunAt = null)
            } else if (scheduleChanged || reenabled || next.nextRunAt == null) {
                next = next.copy(
                    nextRunAt = RoutineScheduleMath.nextRunAt(
                        next.schedule, now = now,
                        createdAt = next.createdAt, lastRunAt = next.lastRunAt,
                    ),
                )
            }
            val routines = document.routines.toMutableList()
            routines[index] = next
            RoutineMutation(value = next, document = document.copy(routines = routines), botId = botId)
        }

    fun delete(botId: String, routineId: String): Routine? =
        store.mutate(botId) { document ->
            val index = document.routines.indexOfFirst { it.id == routineId }
            if (index < 0) {
                RoutineMutation(value = null, document = document, persistSnapshot = false, botId = botId)
            } else {
                val routines = document.routines.toMutableList()
                val removed = routines.removeAt(index)
                RoutineMutation(
                    value = removed,
                    document = document.copy(routines = routines),
                    botId = botId,
                )
            }
        }

    fun repairNextRun(botId: String, routineId: String, now: Long): Routine? =
        store.mutate(botId) { document ->
            val index = document.routines.indexOfFirst { it.id == routineId }
            if (index < 0) {
                RoutineMutation(value = null, document = document, persistSnapshot = false, botId = botId)
            } else {
                val routine = document.routines[index]
                if (routine.nextRunAt != null) {
                    RoutineMutation(value = routine, document = document, persistSnapshot = false, botId = botId)
                } else {
                    val repaired = routine.copy(
                        nextRunAt = if (routine.enabled) {
                            RoutineScheduleMath.nextRunAt(
                                routine.schedule, now = now,
                                createdAt = routine.createdAt, lastRunAt = routine.lastRunAt,
                            )
                        } else {
                            null
                        },
                    )
                    val routines = document.routines.toMutableList()
                    routines[index] = repaired
                    RoutineMutation(
                        value = repaired,
                        document = document.copy(routines = routines),
                        botId = botId,
                    )
                }
            }
        }

    /** Returns `(routine, deferred)`; null when the routine does not exist. */
    fun deferForQuiet(botId: String, routineId: String, until: Long?, now: Long): Pair<Routine, Boolean>? =
        store.mutate(botId) { document ->
            val index = document.routines.indexOfFirst { it.id == routineId }
            if (index < 0) {
                RoutineMutation(value = null, document = document, persistSnapshot = false, botId = botId)
            } else {
                var routine = document.routines[index]
                if (until == null || until <= now || !routine.enabled) {
                    RoutineMutation(
                        value = routine to false,
                        document = document,
                        persistSnapshot = false,
                        botId = botId,
                    )
                } else {
                    val scheduledFor = routine.nextRunAt ?: now
                    routine = routine.copy(
                        quietDefer = RoutineQuietDefer(until = until, scheduledFor = scheduledFor, at = now),
                        nextRunAt = until,
                    )
                    val routines = document.routines.toMutableList()
                    routines[index] = routine
                    RoutineMutation(
                        value = routine to true,
                        document = document.copy(routines = routines),
                        botId = botId,
                    )
                }
            }
        }

    fun begin(
        botId: String,
        routineId: String,
        startedAt: Long,
        scheduledFor: Long? = null,
        leaseOwner: String = "local",
        leaseTtlMs: Long? = null,
        runId: String? = null,
    ): RoutineClaim? = store.mutate(botId) { document ->
        val index = document.routines.indexOfFirst { it.id == routineId }
        if (index < 0) {
            return@mutate RoutineMutation(value = null, document = document, persistSnapshot = false, botId = botId)
        }
        var routine = document.routines[index]
        val current = routine.runState
        if (current?.status == RoutineRunStatus.STARTED) {
            routine = routine.copy(
                lastSkip = RoutineSkip(
                    reason = "overlap", at = startedAt, triggerAt = routine.nextRunAt,
                    runningAttempt = current.attempt, runningRunId = current.runId,
                ),
                skipCount = routine.skipCount + 1,
            )
            val routines = document.routines.toMutableList()
            routines[index] = routine
            return@mutate RoutineMutation(
                value = RoutineClaim(routine, claimed = false, skipReason = "overlap"),
                document = document.copy(routines = routines),
                botId = botId,
            )
        }
        if (current?.status == RoutineRunStatus.NEEDS_RECONCILIATION) {
            return@mutate RoutineMutation(
                value = RoutineClaim(routine, claimed = false, skipReason = "needs-reconciliation"),
                document = document,
                persistSnapshot = false,
                botId = botId,
            )
        }
        if (current?.status == RoutineRunStatus.WAITING_APPROVAL) {
            return@mutate RoutineMutation(
                value = RoutineClaim(routine, claimed = false, skipReason = "waiting-approval"),
                document = document,
                persistSnapshot = false,
                botId = botId,
            )
        }
        val attempt = routine.attempt + 1
        val resolvedRunId = runId ?: "run-${UUID.randomUUID().toString().replace("-", "").take(16)}"
        val deferred = routine.quietDefer
        val resolvedScheduledFor = deferred?.scheduledFor ?: scheduledFor ?: routine.nextRunAt ?: startedAt
        val state = RoutineRunState(
            runId = resolvedRunId,
            attempt = attempt,
            status = RoutineRunStatus.STARTED,
            scheduledFor = resolvedScheduledFor,
            startedAt = startedAt,
            leaseOwner = leaseOwner,
            leaseExpiresAt = leaseTtlMs?.let { startedAt + it },
            quietDeferred = deferred,
        )
        routine = routine.copy(
            attempt = attempt,
            quietDefer = null,
            runState = state,
            lastRunAt = startedAt,
            lastResult = RoutineResult(
                status = RoutineRunStatus.STARTED,
                startedAt = startedAt,
                scheduledFor = resolvedScheduledFor,
                attempt = attempt,
                runId = resolvedRunId,
            ),
        )
        val routines = document.routines.toMutableList()
        routines[index] = routine
        val key = RoutineDelivery.key(routineId, attempt)
        RoutineMutation(
            value = RoutineClaim(routine, claimed = true, deliveryKey = key),
            document = document.copy(routines = routines),
            events = listOf(RoutineLifecycle.started(routine, state)),
            botId = botId,
            snapshotEventId = "routine-snapshot:$resolvedRunId:$attempt:started",
        )
    }

    /** Parks one started attempt on a durable approval; it produces no delivery. */
    fun waitForApproval(botId: String, routineId: String, approvalId: String, sessionId: String, now: Long): Routine? =
        store.mutate(botId) { document ->
            val index = document.routines.indexOfFirst { it.id == routineId }
            if (index < 0) {
                return@mutate RoutineMutation(value = null, document = document, persistSnapshot = false, botId = botId)
            }
            var routine = document.routines[index]
            var state = routine.runState
            if (state == null || state.status != RoutineRunStatus.STARTED) {
                return@mutate RoutineMutation(
                    value = routine, document = document, persistSnapshot = false, botId = botId,
                )
            }
            state = state.copy(
                status = RoutineRunStatus.WAITING_APPROVAL,
                waitingApprovalId = approvalId,
                waitingSessionId = sessionId,
                error = "approval_pending",
                leaseOwner = null,
                leaseExpiresAt = null,
            )
            routine = routine.copy(runState = state)
            val routines = document.routines.toMutableList()
            routines[index] = routine
            RoutineMutation(
                value = routine,
                document = document.copy(routines = routines),
                botId = botId,
                snapshotEventId = "routine-snapshot:${state.runId}:${state.attempt}:waiting-approval",
            )
        }

    /** Reopens the same attempt after the user approved. */
    fun resumeWaitingApproval(
        botId: String,
        routineId: String,
        approvalId: String,
        now: Long,
        leaseOwner: String? = null,
        leaseTtlMs: Long? = null,
    ): RoutineClaim? = store.mutate(botId) { document ->
        val index = document.routines.indexOfFirst { it.id == routineId }
        if (index < 0) {
            return@mutate RoutineMutation(value = null, document = document, persistSnapshot = false, botId = botId)
        }
        var routine = document.routines[index]
        var state = routine.runState ?: return@mutate RoutineMutation(
            value = null, document = document, persistSnapshot = false, botId = botId,
        )
        if (state.status != RoutineRunStatus.WAITING_APPROVAL || state.waitingApprovalId != approvalId) {
            return@mutate RoutineMutation(value = null, document = document, persistSnapshot = false, botId = botId)
        }
        state = state.copy(
            status = RoutineRunStatus.STARTED,
            error = null,
            waitingApprovalId = null,
            waitingSessionId = null,
            leaseOwner = leaseOwner,
            leaseExpiresAt = leaseTtlMs?.let { now + it },
        )
        routine = routine.copy(runState = state)
        routine.lastResult?.let { result ->
            routine = routine.copy(lastResult = result.copy(status = RoutineRunStatus.STARTED, error = null))
        }
        val routines = document.routines.toMutableList()
        routines[index] = routine
        RoutineMutation(
            value = RoutineClaim(routine, claimed = true),
            document = document.copy(routines = routines),
            botId = botId,
            snapshotEventId = "routine-snapshot:${state.runId}:${state.attempt}:resumed",
        )
    }

    /** Explicit user stop of a parked run: terminal cancelled, no delivery. */
    fun cancelWaitingApproval(
        botId: String,
        routineId: String,
        approvalId: String,
        now: Long,
        error: String = "approval_cancelled",
    ): Routine? = store.mutate(botId) { document ->
        val index = document.routines.indexOfFirst { it.id == routineId }
        if (index < 0) {
            return@mutate RoutineMutation(value = null, document = document, persistSnapshot = false, botId = botId)
        }
        var routine = document.routines[index]
        var state = routine.runState
        if (state == null || state.status != RoutineRunStatus.WAITING_APPROVAL ||
            state.waitingApprovalId != approvalId
        ) {
            return@mutate RoutineMutation(value = null, document = document, persistSnapshot = false, botId = botId)
        }
        val truncated = prefixCodePoints(error, 1_000)
        state = state.copy(
            status = RoutineRunStatus.CANCELLED,
            waitingApprovalId = null,
            waitingSessionId = null,
            finishedAt = now,
            error = truncated,
        )
        routine = routine.copy(runState = state)
        routine.lastResult?.let { result ->
            routine = routine.copy(
                lastResult = result.copy(
                    status = RoutineRunStatus.CANCELLED, error = truncated, finishedAt = now,
                ),
            )
        }
        routine = routine.copy(
            nextRunAt = if (routine.enabled) {
                RoutineScheduleMath.nextAfterAttempt(
                    routine,
                    startedAt = state.startedAt,
                    finishedAt = now,
                    scheduledFor = state.scheduledFor ?: state.startedAt,
                )
            } else {
                null
            },
        )
        val routines = document.routines.toMutableList()
        routines[index] = routine
        RoutineMutation(
            value = routine,
            document = document.copy(routines = routines),
            botId = botId,
            snapshotEventId = "routine-snapshot:${state.runId}:${state.attempt}:approval-cancelled",
        )
    }

    fun recordSkip(
        botId: String,
        routineId: String,
        reason: String = "overlap",
        at: Long,
        triggerAt: Long? = null,
    ): RoutineSkip? = store.mutate(botId) { document ->
        val index = document.routines.indexOfFirst { it.id == routineId }
        if (index < 0) {
            return@mutate RoutineMutation(value = null, document = document, persistSnapshot = false, botId = botId)
        }
        var routine = document.routines[index]
        val skip = RoutineSkip(
            reason = reason,
            at = at,
            triggerAt = triggerAt ?: routine.nextRunAt,
            runningAttempt = routine.runState?.attempt,
            runningRunId = routine.runState?.runId,
        )
        routine = routine.copy(lastSkip = skip, skipCount = routine.skipCount + 1)
        val routines = document.routines.toMutableList()
        routines[index] = routine
        RoutineMutation(value = skip, document = document.copy(routines = routines), botId = botId)
    }

    fun finish(
        botId: String,
        routineId: String,
        status: RoutineRunStatus,
        text: String = "",
        error: String? = null,
        startedAt: Long? = null,
        finishedAt: Long,
        attempt: Int? = null,
        runId: String? = null,
        reconcileRequired: Boolean = false,
        quiet: Boolean = false,
        cancelOrigin: String? = null,
    ): RoutineFinish? = store.mutate(botId) { document ->
        val index = document.routines.indexOfFirst { it.id == routineId }
        if (index < 0) {
            return@mutate RoutineMutation(value = null, document = document, persistSnapshot = false, botId = botId)
        }
        var routine = document.routines[index]
        val current = routine.runState
        fun existingDelivery(): RoutineDelivery? =
            document.deliveries[RoutineDelivery.key(routineId, current?.attempt ?: routine.attempt)]

        if (attempt != null && current != null && current.attempt != attempt) {
            return@mutate RoutineMutation(
                value = RoutineFinish(routine, existingDelivery(), ignored = true),
                document = document, persistSnapshot = false, botId = botId,
            )
        }
        if (runId != null && current != null && current.runId != runId) {
            return@mutate RoutineMutation(
                value = RoutineFinish(routine, existingDelivery(), ignored = true),
                document = document, persistSnapshot = false, botId = botId,
            )
        }
        if (current != null && current.status != RoutineRunStatus.STARTED) {
            val existing = existingDelivery()
            if (existing != null) {
                return@mutate RoutineMutation(
                    value = RoutineFinish(routine, existing, ignored = true),
                    document = document, persistSnapshot = false, botId = botId,
                )
            }
        }

        val terminal = if (status.isTerminal) status else RoutineRunStatus.FAILED
        val resolvedAttempt = current?.attempt ?: attempt ?: routine.attempt
        val resolvedRunId = current?.runId ?: runId
            ?: "run-${UUID.randomUUID().toString().replace("-", "").take(16)}"
        val started = startedAt ?: current?.startedAt ?: routine.lastResult?.startedAt ?: finishedAt
        val scheduledFor = current?.scheduledFor ?: routine.nextRunAt ?: started
        val deferred = current?.quietDeferred
        val late = maxOf(0L, started - scheduledFor)
        val isQuiet = quiet ||
            (terminal == RoutineRunStatus.SUCCEEDED && text.trim().isEmpty())
        val truncatedError = error?.let { prefixCodePoints(it, 1_000) }
        val state = RoutineRunState(
            runId = resolvedRunId,
            attempt = resolvedAttempt,
            status = terminal,
            scheduledFor = scheduledFor,
            startedAt = started,
            finishedAt = finishedAt,
            error = truncatedError,
            reconciliationRequired = terminal == RoutineRunStatus.NEEDS_RECONCILIATION || reconcileRequired,
            quietDeferred = deferred,
        )
        val cappedText = prefixCodePoints(text, 4_000)
        routine = routine.copy(
            runState = state,
            lastResult = RoutineResult(
                status = terminal, text = cappedText, error = truncatedError,
                startedAt = started, finishedAt = finishedAt,
                durationMs = maxOf(0L, finishedAt - started), scheduledFor = scheduledFor,
                lateByMs = late, quiet = isQuiet,
                quietDeferredFrom = deferred?.scheduledFor,
                quietDeferredUntil = deferred?.until,
                attempt = resolvedAttempt, runId = resolvedRunId,
            ),
            lastRunAt = started,
            crashRetry = false,
            quietDefer = null,
        )
        routine = routine.copy(
            nextRunAt = if (terminal == RoutineRunStatus.NEEDS_RECONCILIATION) {
                routine.nextRunAt
            } else {
                RoutineScheduleMath.nextAfterAttempt(
                    routine, startedAt = started,
                    finishedAt = finishedAt, scheduledFor = scheduledFor,
                )
            },
        )
        val key = RoutineDelivery.key(routine.id, resolvedAttempt)
        val delivery = document.deliveries[key] ?: RoutineDelivery(
            deliveryKey = key, routineId = routine.id, agentId = botId, attempt = resolvedAttempt,
            runId = resolvedRunId, resultStatus = terminal, text = cappedText, error = error,
            routineTitle = routine.title, context = routine.prompt, delivery = routine.delivery,
            quiet = isQuiet, urgent = routine.urgent, urgentReason = routine.urgentReason,
            cancelOrigin = cancelOrigin, quietDeferredFrom = deferred?.scheduledFor,
            quietDeferredUntil = deferred?.until, scheduledFor = scheduledFor, lateByMs = late,
            startedAt = started, finishedAt = finishedAt, durationMs = maxOf(0L, finishedAt - started),
            nextRunAt = routine.nextRunAt, createdAt = finishedAt, updatedAt = finishedAt,
        )
        val deliveries = LinkedHashMap(document.deliveries)
        deliveries[key] = delivery
        val routines = document.routines.toMutableList()
        routines[index] = routine
        RoutineMutation(
            value = RoutineFinish(routine, delivery),
            document = document.copy(routines = routines, deliveries = deliveries),
            events = listOf(RoutineLifecycle.finished(routine, state, delivery)),
            botId = botId,
            snapshotEventId = "routine-snapshot:$resolvedRunId:$resolvedAttempt:finished",
        )
    }

    /**
     * Finds `started` runs whose lease expired. An idempotent attempt that has
     * not already been retried is marked `failed` and retried once now;
     * everything else becomes `needs-reconciliation` with a delivery. Both
     * paths write the `routine.run_finished` audit event, and a second call
     * finds no started run, so recovery is idempotent.
     */
    fun recover(
        botId: String,
        now: Long,
        leaseOwner: String? = null,
        maxAutoRetries: Int = 1,
        excludeRunIds: Set<String> = emptySet(),
    ): List<RoutineRecoveryAction> = store.mutate(botId) { document ->
        val actions = ArrayList<RoutineRecoveryAction>()
        val events = ArrayList<BotEvent>()
        val routines = document.routines.toMutableList()
        val deliveries = LinkedHashMap(document.deliveries)
        for (index in routines.indices) {
            var routine = routines[index]
            val current = routine.runState ?: continue
            if (current.status != RoutineRunStatus.STARTED) continue
            if (current.runId in excludeRunIds) continue
            if (leaseOwner != null && current.leaseOwner == leaseOwner) {
                val expires = current.leaseExpiresAt
                if (expires != null && expires > now) continue
            }
            val attempt = current.attempt
            val runId = current.runId
            val scheduledFor = current.scheduledFor ?: routine.nextRunAt ?: current.startedAt
            val canRetry = routine.idempotent && !routine.crashRetry && maxAutoRetries > 0
            val terminal = if (canRetry) RoutineRunStatus.FAILED else RoutineRunStatus.NEEDS_RECONCILIATION
            val error = if (canRetry) {
                "routine attempt $attempt did not finish (crash); " +
                    "retrying because the routine is idempotent"
            } else {
                "routine crashed before finishing; the result is unknown and was not replayed automatically"
            }
            val state = RoutineRunState(
                runId = runId, attempt = attempt, status = terminal,
                scheduledFor = scheduledFor, startedAt = current.startedAt,
                finishedAt = now, error = error,
                reconciliationRequired = !canRetry, recovered = true,
                quietDeferred = current.quietDeferred,
            )
            routine = routine.copy(
                runState = state,
                lastResult = RoutineResult(
                    status = terminal, error = error,
                    startedAt = current.startedAt, finishedAt = now,
                    durationMs = maxOf(0L, now - current.startedAt),
                    scheduledFor = scheduledFor, attempt = attempt, runId = runId,
                ),
                crashRetry = canRetry,
                quietDefer = if (canRetry) current.quietDeferred else null,
            )
            if (canRetry) {
                routine = routine.copy(nextRunAt = if (routine.enabled) now else null)
            }
            val key = RoutineDelivery.key(routine.id, attempt)
            var delivery = deliveries[key]
            if (!canRetry && delivery == null) {
                delivery = RoutineDelivery(
                    deliveryKey = key, routineId = routine.id, agentId = botId, attempt = attempt,
                    runId = runId, resultStatus = terminal, error = error,
                    routineTitle = routine.title, context = routine.prompt, delivery = routine.delivery,
                    urgent = routine.urgent, urgentReason = routine.urgentReason,
                    quietDeferredFrom = current.quietDeferred?.scheduledFor,
                    quietDeferredUntil = current.quietDeferred?.until, scheduledFor = scheduledFor,
                    startedAt = current.startedAt, finishedAt = now,
                    durationMs = maxOf(0L, now - current.startedAt), nextRunAt = routine.nextRunAt,
                    createdAt = now, updatedAt = now,
                )
                deliveries[key] = delivery
            }
            val eventDelivery = delivery ?: RoutineDelivery(
                deliveryKey = key, routineId = routine.id, agentId = botId, attempt = attempt,
                runId = runId, resultStatus = terminal, error = error,
                routineTitle = routine.title, context = routine.prompt, delivery = routine.delivery,
                scheduledFor = scheduledFor, startedAt = current.startedAt, finishedAt = now,
                createdAt = now, updatedAt = now,
            )
            events += RoutineLifecycle.finished(routine, state, eventDelivery)
            actions += RoutineRecoveryAction(
                action = if (canRetry) "retry" else "needs-reconciliation",
                reason = "routine-crash", routineId = routine.id,
                attempt = attempt, runId = runId,
                deliveryKey = if (canRetry) null else key,
            )
            routines[index] = routine
        }
        if (actions.isEmpty()) {
            RoutineMutation(value = actions, document = document, persistSnapshot = false, botId = botId)
        } else {
            RoutineMutation(
                value = actions,
                document = document.copy(routines = routines, deliveries = deliveries),
                events = events,
                botId = botId,
            )
        }
    }

    fun resolveReconciliation(botId: String, routineId: String, decision: String, now: Long): Routine? {
        if (decision != "retry" && decision != "acknowledge") {
            throw RoutineError.UnsupportedDecision(decision)
        }
        return store.mutate(botId) { document ->
            val index = document.routines.indexOfFirst { it.id == routineId }
            if (index < 0) {
                return@mutate RoutineMutation(value = null, document = document, persistSnapshot = false, botId = botId)
            }
            var routine = document.routines[index]
            val state = routine.runState
            if (state == null || state.status != RoutineRunStatus.NEEDS_RECONCILIATION) {
                return@mutate RoutineMutation(
                    value = routine, document = document, persistSnapshot = false, botId = botId,
                )
            }
            val finished = state.finishedAt ?: now
            routine = routine.copy(
                runState = state.copy(
                    status = RoutineRunStatus.FAILED,
                    finishedAt = finished,
                    reconciliationRequired = false,
                    recovered = true,
                ),
            )
            routine.lastResult?.let { result ->
                routine = routine.copy(
                    lastResult = result.copy(
                        status = RoutineRunStatus.FAILED,
                        error = "needs-reconciliation resolved by user: $decision",
                        finishedAt = now,
                    ),
                )
            }
            routine = routine.copy(
                nextRunAt = if (routine.enabled) {
                    if (decision == "retry") {
                        now
                    } else {
                        RoutineScheduleMath.nextAfterAttempt(
                            routine, startedAt = state.startedAt,
                            finishedAt = now, scheduledFor = state.scheduledFor,
                        )
                    }
                } else {
                    null
                },
            )
            val routines = document.routines.toMutableList()
            routines[index] = routine
            RoutineMutation(value = routine, document = document.copy(routines = routines), botId = botId)
        }
    }

    fun delivery(key: String, botId: String): RoutineDelivery? = store.read(botId).deliveries[key]

    fun pendingDeliveries(botId: String, now: Long, includeDelivering: Boolean = false): List<RoutineDelivery> =
        store.read(botId).deliveries.values.filter { delivery ->
            if (delivery.agentId != botId) return@filter false
            if (delivery.status == RoutineDeliveryStatus.PENDING) return@filter true
            if (delivery.status != RoutineDeliveryStatus.DELIVERING) return@filter false
            includeDelivering || delivery.leaseExpiresAt == null || delivery.leaseExpiresAt!! <= now
        }.sortedWith(compareBy({ it.createdAt }, { it.deliveryKey }))

    fun claimDelivery(
        key: String,
        botId: String,
        leaseOwner: String = "local",
        now: Long,
        leaseTtlMs: Long = 60_000,
        force: Boolean = false,
    ): RoutineDeliveryClaim = store.mutate(botId) { document ->
        val delivery = document.deliveries[key]
        if (delivery == null) {
            return@mutate RoutineMutation(
                value = RoutineDeliveryClaim(RoutineDeliveryClaim.State.MISSING),
                document = document, persistSnapshot = false, botId = botId,
            )
        }
        when (delivery.status) {
            RoutineDeliveryStatus.DELIVERED -> return@mutate RoutineMutation(
                value = RoutineDeliveryClaim(RoutineDeliveryClaim.State.DELIVERED, delivery),
                document = document, persistSnapshot = false, botId = botId,
            )
            RoutineDeliveryStatus.FAILED -> return@mutate RoutineMutation(
                value = RoutineDeliveryClaim(RoutineDeliveryClaim.State.FAILED, delivery),
                document = document, persistSnapshot = false, botId = botId,
            )
            RoutineDeliveryStatus.DELIVERING -> {
                val expires = delivery.leaseExpiresAt
                if (!force && delivery.leaseOwner != leaseOwner && expires != null && expires > now) {
                    return@mutate RoutineMutation(
                        value = RoutineDeliveryClaim(RoutineDeliveryClaim.State.BUSY, delivery),
                        document = document, persistSnapshot = false, botId = botId,
                    )
                }
            }
            RoutineDeliveryStatus.PENDING -> Unit
        }
        val claimed = delivery.copy(
            status = RoutineDeliveryStatus.DELIVERING,
            leaseOwner = leaseOwner,
            leaseExpiresAt = now + maxOf(1L, leaseTtlMs),
            attempts = delivery.attempts + 1,
            updatedAt = now,
        )
        val deliveries = LinkedHashMap(document.deliveries)
        deliveries[key] = claimed
        RoutineMutation(
            value = RoutineDeliveryClaim(RoutineDeliveryClaim.State.CLAIMED, claimed),
            document = document.copy(deliveries = deliveries),
            botId = botId,
        )
    }

    fun completeDelivery(key: String, botId: String, now: Long): RoutineDelivery? =
        store.mutate(botId) { document ->
            val delivery = document.deliveries[key]
            if (delivery == null) {
                RoutineMutation(value = null, document = document, persistSnapshot = false, botId = botId)
            } else {
                val completed = delivery.copy(
                    status = RoutineDeliveryStatus.DELIVERED,
                    deliveredAt = now,
                    updatedAt = now,
                    leaseOwner = null,
                    leaseExpiresAt = null,
                    lastError = null,
                )
                val deliveries = LinkedHashMap(document.deliveries)
                deliveries[key] = completed
                RoutineMutation(
                    value = completed,
                    document = document.copy(deliveries = deliveries),
                    botId = botId,
                )
            }
        }

    fun failDelivery(
        key: String,
        botId: String,
        error: String,
        now: Long,
        retryable: Boolean = true,
        maxAttempts: Int = 3,
    ): RoutineDelivery? = store.mutate(botId) { document ->
        val delivery = document.deliveries[key]
        if (delivery == null) {
            RoutineMutation(value = null, document = document, persistSnapshot = false, botId = botId)
        } else {
            val finalFailure = !retryable || delivery.attempts >= maxOf(1, maxAttempts)
            val failed = delivery.copy(
                status = if (finalFailure) RoutineDeliveryStatus.FAILED else RoutineDeliveryStatus.PENDING,
                lastError = prefixCodePoints(error, 1_000),
                updatedAt = now,
                leaseOwner = null,
                leaseExpiresAt = null,
                failedAt = if (finalFailure) now else delivery.failedAt,
            )
            val deliveries = LinkedHashMap(document.deliveries)
            deliveries[key] = failed
            RoutineMutation(
                value = failed,
                document = document.copy(deliveries = deliveries),
                botId = botId,
            )
        }
    }

    fun markNotification(
        key: String,
        botId: String,
        notified: String?,
        reason: String?,
        mode: String?,
        handled: Boolean = true,
        now: Long,
    ): RoutineDelivery? = store.mutate(botId) { document ->
        val delivery = document.deliveries[key]
        if (delivery == null) {
            RoutineMutation(value = null, document = document, persistSnapshot = false, botId = botId)
        } else {
            val normalized = if (notified == "sent" || notified == "skipped") notified else null
            val marked = delivery.copy(
                notified = normalized,
                notifyReason = reason?.let { prefixCodePoints(it, 200) },
                notifiedAt = if (normalized == null) null else now,
                proactiveHandled = handled,
                proactiveMode = mode,
                updatedAt = now,
            )
            val deliveries = LinkedHashMap(document.deliveries)
            deliveries[key] = marked
            RoutineMutation(
                value = marked,
                document = document.copy(deliveries = deliveries),
                botId = botId,
            )
        }
    }

    fun markHeld(
        key: String,
        botId: String,
        delivered: Boolean,
        error: String? = null,
        now: Long,
    ): RoutineDelivery? = store.mutate(botId) { document ->
        val delivery = document.deliveries[key]
        if (delivery == null) {
            RoutineMutation(value = null, document = document, persistSnapshot = false, botId = botId)
        } else {
            val marked = delivery.copy(
                heldInbox = if (delivered) "delivered" else "failed",
                heldInboxError = if (delivered) {
                    null
                } else {
                    prefixCodePoints(error ?: "held inbox write failed", 500)
                },
                updatedAt = now,
            )
            val deliveries = LinkedHashMap(document.deliveries)
            deliveries[key] = marked
            RoutineMutation(
                value = marked,
                document = document.copy(deliveries = deliveries),
                botId = botId,
            )
        }
    }
}

/** The two lifecycle events, frozen field-for-field (D9 §7). */
internal object RoutineLifecycle {
    fun started(routine: Routine, state: RoutineRunState): BotEvent {
        val data = objectOf(
            listOf(
                "routineId" to JsonString(routine.id),
                "runId" to JsonString(state.runId),
                "attempt" to RoutineJson.number(state.attempt.toLong()),
                "startedAt" to RoutineJson.number(state.startedAt),
                "scheduledFor" to state.scheduledFor?.let(RoutineJson::number),
            ),
        )
        return BotEvent(
            schemaVersion = BotEventCodec.CURRENT_SCHEMA_VERSION,
            type = "routine.run_started",
            eventId = "routine-run-started:${state.runId}:${state.attempt}",
            commitSeq = null,
            time = state.startedAt,
            origin = BotEventOrigin.Local("scheduler"),
            traceId = "trace:routine:${state.runId}:${state.attempt}:started",
            principal = principal(routine),
            causationId = null,
            correlationId = routine.id,
            runId = state.runId,
            attempt = maxOf(1, state.attempt),
            data = data,
        )
    }

    fun finished(routine: Routine, state: RoutineRunState, delivery: RoutineDelivery): BotEvent {
        val data = objectOf(
            listOf(
                "routineId" to JsonString(routine.id),
                "runId" to JsonString(state.runId),
                "attempt" to RoutineJson.number(state.attempt.toLong()),
                "status" to JsonString(state.status.rawValue),
                "text" to JsonString(delivery.text),
                "resultExcerpt" to JsonString(prefixCodePoints(delivery.text, 300)),
                "quiet" to RoutineJson.bool(delivery.quiet),
                "delivery" to JsonString(delivery.delivery.rawValue),
                "deliveryKey" to JsonString(delivery.deliveryKey),
                "proactiveHandled" to RoutineJson.bool(delivery.proactiveHandled),
                "startedAt" to RoutineJson.number(state.startedAt),
                "finishedAt" to RoutineJson.number(state.finishedAt ?: delivery.finishedAt),
                "scheduledFor" to state.scheduledFor?.let(RoutineJson::number),
                "error" to delivery.error?.let(RoutineJson::string),
            ),
        )
        return BotEvent(
            schemaVersion = BotEventCodec.CURRENT_SCHEMA_VERSION,
            type = "routine.run_finished",
            eventId = "routine-run-finished:${state.runId}:${state.attempt}",
            commitSeq = null,
            time = state.finishedAt ?: delivery.finishedAt,
            origin = BotEventOrigin.Local("scheduler"),
            traceId = "trace:routine:${state.runId}:${state.attempt}:finished",
            principal = principal(routine),
            causationId = null,
            correlationId = routine.id,
            runId = state.runId,
            attempt = maxOf(1, state.attempt),
            data = data,
        )
    }

    private fun principal(routine: Routine): BotPrincipal = BotPrincipal(
        botId = routine.agentId,
        sessionId = "gb-${routine.agentId}--routine-${routine.id}",
        kind = "routine",
        capabilities = emptyList(),
    )
}
