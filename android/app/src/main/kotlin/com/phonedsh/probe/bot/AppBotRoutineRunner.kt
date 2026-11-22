// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.bot.authz.BotApprovalCoordinator
import com.phonedsh.bot.routines.RoutineCancellationResult
import com.phonedsh.bot.routines.RoutineExecutionResult
import com.phonedsh.bot.routines.RoutineExecutionStatus
import com.phonedsh.bot.routines.RoutineRunHandle
import com.phonedsh.bot.routines.RoutineRunRequest
import com.phonedsh.bot.routines.RoutineRunner
import com.phonedsh.bot.session.BotSessionRuntime
import com.phonedsh.bot.wake.RoutineWakeBuilder
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible

/** The routine scheduler keeps the durable claim. This adapter only owns its live DSH turn. */
internal class AppBotRoutineRunner(
    private val runtime: BotSessionRuntime,
    private val approvals: BotApprovalCoordinator,
) : RoutineRunner, AutoCloseable {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun start(request: RoutineRunRequest): RoutineRunHandle {
        val session = AtomicReference<String?>()
        val result = AtomicReference<RoutineExecutionResult?>()
        val job = scope.launch {
            val requestId = "routine:${request.runId}" +
                request.resumeApprovalId?.let { ":resume:$it" }.orEmpty()
            try {
                val turn = runInterruptible {
                    runtime.runRoutineTurn(request.wake.text, requestId, request.resumeSessionId, session::set)
                }
                val pending = approvals.pendingApproval(turn.sessionId)
                val reply = RoutineWakeBuilder.normalizeReply(turn.finalText ?: turn.text)
                result.set(when {
                    pending != null -> RoutineExecutionResult.waiting(pending.approvalID, turn.sessionId)
                    turn.status == "completed" -> RoutineExecutionResult.success(reply.text, reply.quiet)
                    turn.status == "cancelled" -> RoutineExecutionResult(RoutineExecutionStatus.CANCELLED)
                    else -> RoutineExecutionResult.failure("routine turn failed")
                })
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                val id = session.get()
                val pending = id?.let(approvals::pendingApproval)
                result.set(if (id != null && pending != null) {
                    RoutineExecutionResult.waiting(pending.approvalID, id)
                } else RoutineExecutionResult.failure("routine transport unavailable"))
            }
        }
        return object : RoutineRunHandle {
            override fun resultOrNull(): RoutineExecutionResult? = result.get()

            override fun cancel(reason: String): RoutineCancellationResult {
                val id = session.get()
                if (id == null) {
                    job.cancel()
                    return RoutineCancellationResult(cancelled = false, reconciliationRequired = true)
                }
                return try {
                    runtime.cancelRoutineTurn(id)
                    RoutineCancellationResult(cancelled = true)
                } catch (_: Exception) {
                    RoutineCancellationResult(cancelled = false, reconciliationRequired = true)
                }
            }
        }
    }

    override fun close() = scope.cancel()
}
