// SPDX-License-Identifier: MIT
package com.phonedsh.bot.routines

/**
 * One due routine handed to the host runner. `timeoutMs` already includes the
 * cancel grace; `wake` is the full hidden prompt and `resumeApprovalId` marks a
 * run resumed after a durable approval (its prompt id must differ from the
 * first attempt so DSH opens a new turn).
 */
data class RoutineRunRequest(
    val botId: String,
    val routine: Routine,
    val runId: String,
    val attempt: Int,
    val startedAt: Long,
    val timeoutMs: Long,
    val wake: RoutineWakePrompt,
    val resumeApprovalId: String? = null,
    val resumeSessionId: String? = null,
)

/** A minimal prompt value object so the runner seam does not depend on wake internals. */
data class RoutineWakePrompt(val text: String, val cue: String = "routine", val mode: String = "due")

enum class RoutineExecutionStatus(val rawValue: String) {
    SUCCEEDED("succeeded"),
    FAILED("failed"),
    CANCELLED("cancelled"),
    WAITING_APPROVAL("waiting-approval"),
}

data class RoutineExecutionResult(
    val status: RoutineExecutionStatus,
    val text: String = "",
    val error: String? = null,
    val quiet: Boolean = false,
    val cancelledBy: String? = null,
    val approvalId: String? = null,
    val sessionId: String? = null,
) {
    companion object {
        fun success(text: String, quiet: Boolean = false): RoutineExecutionResult =
            RoutineExecutionResult(status = RoutineExecutionStatus.SUCCEEDED, text = text, quiet = quiet)

        fun failure(error: String): RoutineExecutionResult =
            RoutineExecutionResult(status = RoutineExecutionStatus.FAILED, error = error)

        fun waiting(approvalId: String, sessionId: String, error: String? = null): RoutineExecutionResult =
            RoutineExecutionResult(
                status = RoutineExecutionStatus.WAITING_APPROVAL,
                error = error, approvalId = approvalId, sessionId = sessionId,
            )
    }
}

data class RoutineCancellation(
    val botId: String,
    val routineId: String,
    val runId: String,
    val timeoutMs: Long,
    val reason: String = "timeout",
)

data class RoutineCancellationResult(
    val cancelled: Boolean,
    val reconciliationRequired: Boolean = false,
    val reason: String? = null,
)

/**
 * The host execution seam. `start` returns immediately; the scheduler polls
 * [RoutineRunHandle.resultOrNull] on its next tick, so a timeout is decided by
 * the injectable clock instead of a wall-clock timer and a fake clock can drive
 * the whole lifecycle deterministically.
 */
interface RoutineRunner {
    fun start(request: RoutineRunRequest): RoutineRunHandle
}

interface RoutineRunHandle {
    /** The terminal result, or null while the run is still in flight. */
    fun resultOrNull(): RoutineExecutionResult?

    fun cancel(reason: String): RoutineCancellationResult
}

/** A runner that finishes synchronously; the handle already holds the result. */
class ImmediateRoutineRun(private val result: RoutineExecutionResult) : RoutineRunHandle {
    override fun resultOrNull(): RoutineExecutionResult = result

    override fun cancel(reason: String): RoutineCancellationResult =
        RoutineCancellationResult(cancelled = false, reason = "already-finished")
}

/** Convenience adapter for a synchronous runner. */
class ImmediateRoutineRunner(private val body: (RoutineRunRequest) -> RoutineExecutionResult) : RoutineRunner {
    override fun start(request: RoutineRunRequest): RoutineRunHandle = ImmediateRoutineRun(body(request))
}

/** `RoutineAutomation` (Swift `RoutineSchedulerTypes.swift`): one delivery row. */
data class RoutineAutomation(
    val id: String,
    val botId: String,
    val kind: String,
    val status: String,
    val result: String,
    val error: String?,
    val routineId: String,
    val routineTitle: String,
    val deliveryKey: String,
    val attempt: Int,
    val runId: String,
    val delivery: RoutineDeliveryMode,
    val quiet: Boolean,
    val urgent: Boolean,
    val urgentReason: String,
    val context: String,
    val scheduledFor: Long?,
    val lateByMs: Long,
    val startedAt: Long,
    val finishedAt: Long,
    val nextRunAt: Long?,
    val notified: String?,
    val notifyReason: String?,
    val proactiveMode: String?,
    val heldInbox: String?,
    val heldInboxError: String?,
) {
    companion object {
        fun from(delivery: RoutineDelivery): RoutineAutomation {
            val status = when (delivery.resultStatus) {
                RoutineRunStatus.SUCCEEDED -> "sent"
                RoutineRunStatus.CANCELLED -> "idle"
                else -> "failed"
            }
            var result = when (delivery.resultStatus) {
                RoutineRunStatus.SUCCEEDED -> delivery.text
                RoutineRunStatus.CANCELLED -> "执行已取消"
                RoutineRunStatus.TIMED_OUT -> "执行超时，已取消"
                RoutineRunStatus.NEEDS_RECONCILIATION -> "执行结果未知，需要确认：" +
                    RoutineJson.prefixCodePoints(delivery.error ?: "未知原因", 300)
                else -> "执行失败：" + RoutineJson.prefixCodePoints(delivery.error ?: "未知错误", 300)
            }
            if (delivery.resultStatus == RoutineRunStatus.SUCCEEDED &&
                delivery.text.trim().isEmpty()
            ) {
                result = "已完成（没有新结果）"
            }
            var context = delivery.context
            fun append(value: String) {
                context = if (context.isEmpty()) value else "$context · $value"
            }
            delivery.quietDeferredFrom?.let { deferredFrom ->
                val clock = RoutineTime.formatMinute(deferredFrom, RoutineTime.defaultZoneId()) ?: "—"
                append("（因安静时段延后，原定 ${clock.takeLast(5)}）")
            } ?: run {
                if (delivery.lateByMs > 60_000) {
                    append("（延迟 ${maxOf(1L, (delivery.lateByMs + 30_000) / 60_000)} 分钟触发）")
                }
            }
            if (delivery.urgent) {
                append("（紧急：${if (delivery.urgentReason.isEmpty()) "—" else delivery.urgentReason}）")
            }
            if (delivery.heldInbox == "failed") append("结果未能交给主对话")
            if (delivery.delivery == RoutineDeliveryMode.INTERRUPT) {
                if (delivery.notified == "sent") append("已通知")
                if (delivery.notified == "skipped") append("未通知：${delivery.notifyReason ?: "unknown"}")
            }
            return RoutineAutomation(
                id = RoutineDelivery.rowId(delivery.routineId, delivery.attempt),
                botId = delivery.agentId,
                kind = "routine-run",
                status = status,
                result = result,
                error = delivery.error,
                routineId = delivery.routineId,
                routineTitle = delivery.routineTitle,
                deliveryKey = delivery.deliveryKey,
                attempt = delivery.attempt,
                runId = delivery.runId,
                delivery = delivery.delivery,
                quiet = delivery.quiet,
                urgent = delivery.urgent,
                urgentReason = delivery.urgentReason,
                context = context,
                scheduledFor = delivery.scheduledFor,
                lateByMs = delivery.lateByMs,
                startedAt = delivery.startedAt,
                finishedAt = delivery.finishedAt,
                nextRunAt = delivery.nextRunAt,
                notified = delivery.notified,
                notifyReason = delivery.notifyReason,
                proactiveMode = delivery.proactiveMode,
                heldInbox = delivery.heldInbox,
                heldInboxError = delivery.heldInboxError,
            )
        }
    }
}

interface RoutineResultSink {
    fun deliver(automation: RoutineAutomation): Boolean
}

/**
 * One interrupt candidate for the proactive admission chain (v2 §3). B4 owns
 * the DND/fuse/mode engine; the scheduler only builds the candidate and writes
 * the resulting notification state back to the delivery.
 */
data class RoutineInterruptCandidate(
    val id: String,
    val kind: String,
    val botId: String,
    val dedupeKey: String,
    val trigger: String,
    val createdAt: Long,
    val title: String,
    val body: String,
    val status: String,
    val routineId: String,
    val runId: String,
    val attempt: Int,
    val delivery: RoutineDeliveryMode,
    val quiet: Boolean,
    val resultExcerpt: String,
    val deliveryKey: String,
    val rowId: String,
)

data class RoutineInterruptDecision(val mode: String, val decision: String, val reason: String? = null)

interface RoutineInterruptConsiderer {
    fun consider(candidate: RoutineInterruptCandidate): RoutineInterruptDecision
}
