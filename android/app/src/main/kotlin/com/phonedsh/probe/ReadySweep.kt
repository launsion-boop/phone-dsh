// SPDX-License-Identifier: MIT
package com.phonedsh.probe

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ensureActive
import kotlin.coroutines.coroutineContext

internal enum class ReadySweepStep(val budgetMs: Long) {
    userOutbox(2_000),
    externalAdmission(2_000),
    cloudTaskPull(5_000),
    botHeldInbox(2_000),
    missedRoutines(5_000),
    connectorScan(10_000),
    approvalReminderSync(1_000),
    dshSchedule(3_000),
    hostRetries(2_000);

    fun canRun(remainingMs: Long): Boolean {
        require(remainingMs >= 0)
        return remainingMs >= budgetMs + PARK_MARGIN_MS
    }

    companion object {
        const val PARK_MARGIN_MS = 5_000L
    }
}

internal class ReadySweep(
    private val operations: Map<ReadySweepStep, suspend () -> Unit>,
    private val onFailure: (ReadySweepStep, Exception) -> Unit,
) {
    suspend fun run(remainingMs: () -> Long) {
        for (step in ReadySweepStep.entries) {
            coroutineContext.ensureActive()
            val operation = operations[step] ?: continue
            if (!step.canRun(remainingMs())) continue
            try {
                operation()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                onFailure(step, failure)
            }
        }
    }
}
