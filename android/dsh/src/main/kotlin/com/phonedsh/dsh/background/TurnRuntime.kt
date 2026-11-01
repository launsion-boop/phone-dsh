// phone-dsh — :dsh / com.phonedsh.dsh.background: process-wide turn execution state.
// SPDX-License-Identifier: MIT
//
// This object is NOT durability: it dies with the process, which is exactly why
// InterruptedTurnStore exists. Its one semantic job is admission. The moment the
// background window stops being valid, admission closes — and *only* admission:
// closing the WAL epoch / fsync here is forbidden (plan §7.10: onTimeout and
// epoch close are decoupled; a few seconds of window would tear an epoch).
//
// budgets.md §2 D14 mapping (owned by :controller, described here so the seam is
// explicit):
//   Running -> Draining  : scenePhase background (not this lane's signal)
//   Draining -> Parked   : epoch close on its own timer, not on onTimeout
//   any -> Recovering    : next process start, WAL replay by :controller

package com.phonedsh.dsh.background

import android.app.job.JobParameters
import android.app.job.JobService

object TurnRuntime {
    /** Which official channel owns the current window. */
    enum class Backend { FOREGROUND_SERVICE, USER_INITIATED_JOB }

    enum class Phase { IDLE, RUNNING, STOPPED }

    /**
     * Why the background window ended.
     *
     * There is intentionally no "drained" value: this lane closes admission, it
     * never closes an epoch.
     */
    enum class StopReason {
        /** Caller finished the turn; the normal close. */
        COMPLETED,

        /** The user pressed the notification's stop action. */
        USER_STOPPED,

        /** The user removed the task (only a callback because the service says so). */
        TASK_REMOVED,

        /** The platform stopped the service without asking us (OEM/ battery saver). */
        SERVICE_STOPPED,

        /** `dataSync` foreground-service time budget expired (Android 15, 6 h). */
        SYSTEM_TIMEOUT,

        /** `JobScheduler` stopped a UIDT job; the job is retriable. */
        JOB_STOPPED,
    }

    data class Snapshot(
        val phase: Phase = Phase.IDLE,
        val admissionOpen: Boolean = false,
        val backend: Backend? = null,
        val epoch: Long = UNKNOWN_EPOCH,
        val step: Int = 0,
        val totalSteps: Int = 0,
        val stopReason: StopReason? = null,
    ) {
        val isRunning: Boolean get() = phase == Phase.RUNNING
    }

    const val UNKNOWN_EPOCH: Long = -1L

    private val lock = Any()
    private var state = Snapshot()
    private var jobBinding: JobBinding? = null

    /**
     * The running UIDT service and its parameters. `JobService.jobFinished` is an
     * instance method bound to the service the system started, so finishing the
     * job from the stop receiver or from `TurnBackground.complete()` needs this
     * exact pair.
     */
    data class JobBinding(val service: JobService, val params: JobParameters)

    fun begin(backend: Backend, request: TurnRequest): Snapshot = synchronized(lock) {
        state = Snapshot(
            phase = Phase.RUNNING,
            admissionOpen = true,
            backend = backend,
            epoch = request.epoch,
            step = request.step,
            totalSteps = request.totalSteps,
        )
        state
    }

    fun progress(step: Int): Snapshot = synchronized(lock) {
        if (state.phase == Phase.RUNNING) {
            state = state.copy(step = step.coerceAtLeast(state.step))
        }
        state
    }

    /** Closes admission only — never an epoch, never an fsync (plan §7.10). */
    fun closeAdmission(reason: StopReason): Snapshot = synchronized(lock) {
        state = state.copy(admissionOpen = false, stopReason = reason)
        state
    }

    fun finish(reason: StopReason): Snapshot = synchronized(lock) {
        state = state.copy(phase = Phase.STOPPED, admissionOpen = false, stopReason = reason)
        state
    }

    fun bindJob(service: JobService, params: JobParameters) {
        synchronized(lock) { jobBinding = JobBinding(service, params) }
    }

    fun jobBinding(): JobBinding? = synchronized(lock) { jobBinding }

    /** Ends the UIDT job through the service instance the system bound. */
    fun finishJob(wantsReschedule: Boolean): Boolean {
        val binding = synchronized(lock) {
            val current = jobBinding
            jobBinding = null
            current
        } ?: return false
        return runCatching { binding.service.jobFinished(binding.params, wantsReschedule) }.isSuccess
    }

    fun snapshot(): Snapshot = synchronized(lock) { state }
}
