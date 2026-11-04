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
//
// ---- `SCHEDULED` is a window, not execution (L53) ---------------------------
// L49 gave the drain guard a reading, but the reading could only see `RUNNING`
// (`onStartJob` / `onStartCommand` actually ran). That left the earliest and
// most real case out: `JobScheduler.schedule()` returns RESULT_SUCCESS while the
// UIDT job sits pending on its network constraint (a just-booted device whose
// network is not validated yet), so pressing HOME before the job enters its
// execution slot read `Absent` and the drain killed a turn the platform had
// already accepted. `Phase.SCHEDULED` records that acceptance. It is *not*
// execution: admission stays closed until [begin] is called by the component
// the platform started, and a scheduled phase that never becomes `RUNNING` is
// still bounded by the host's `WindowHold` (600 s) because the holder measures
// from the background edge, not from the start of the job.

package com.phonedsh.dsh.background

import android.app.job.JobParameters
import android.app.job.JobService

object TurnRuntime {
    /**
     * Which official channel owns the current window.
     */
    enum class Backend { FOREGROUND_SERVICE, USER_INITIATED_JOB }

    /**
     * What this process knows about the current turn's window.
     *
     * The two window-bearing phases differ in exactly one thing, and the
     * difference is the reason [SCHEDULED] exists: `SCHEDULED` means the platform
     * **accepted** a window ([TurnJobScheduler.schedule] returned success) while
     * `RUNNING` means the platform **started** the component that holds it.
     * Execution-relevant state (`admissionOpen`) is only opened by [RUNNING].
     */
    enum class Phase {
        /** No window: nothing was scheduled for this turn, or it never opened one. */
        IDLE,

        /**
         * The scheduler accepted the window, the component has not run yet.
         *
         * The honest reading of a UIDT job waiting on its `CONNECTIVITY`
         * constraint, or of a foreground-service start that has not reached
         * `onStartCommand`. For the D14 drain guard this is a window in place:
         * the OS has promised to run the turn as soon as it can, and killing the
         * turn now destroys a promise the platform is still keeping.
         */
        SCHEDULED,

        /** `onStartJob` / `onStartCommand` ran: the window is held by a component. */
        RUNNING,

        /** The turn ended for this process; the next [begin]/[scheduled] may open a new window. */
        STOPPED,
    }

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
        /**
         * `true` only for a stop the platform asked for and will retry
         * (`onStopJob` returning `true`): the same job — same epoch — is
         * rescheduled, and the component it starts is a **resume**, not a
         * resurrection. Every other way a turn ends clears it, and [begin]
         * refuses a stopped epoch that is not retriable.
         */
        val retriable: Boolean = false,
    ) {
        /** Execution: the component the platform started is running this turn. */
        val isRunning: Boolean get() = phase == Phase.RUNNING

        /** Acceptance: a window was granted and has not started yet. */
        val isScheduled: Boolean get() = phase == Phase.SCHEDULED

        /**
         * Either phase that owns a window. This is the predicate the D14 drain
         * guard reads (`TurnWindowRead.Platform`): the drain's premise is "no
         * background window", and a granted window is one — started or not.
         */
        val hasWindow: Boolean get() = phase == Phase.RUNNING || phase == Phase.SCHEDULED
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

    /**
     * What the platform-started component gets when it asks to open the window.
     *
     * The answer is a result rather than a silent state write because the
     * component has to *close what the platform started* when it is refused
     * (L60 #7): `onStartJob` calls `jobFinished(params, false)`, the foreground
     * service calls `stopSelf(startId)`. A refusal that only logged would leave
     * the job open and the notification attached for a turn nobody owns.
     */
    sealed interface BeginResult {
        /** The state after the call, whether it opened or refused. */
        val snapshot: Snapshot

        /** The window opened: this component now owns the turn. */
        data class Started(override val snapshot: Snapshot) : BeginResult

        /**
         * The window did not open and [snapshot] is the unchanged state. The
         * component must finish without running the turn: no marker, no
         * notification, no admission.
         */
        data class Refused(
            val reason: RefusalReason,
            override val snapshot: Snapshot,
        ) : BeginResult
    }

    /** Why [begin] refused a component the platform started. */
    enum class RefusalReason(val wire: String) {
        /**
         * The turn already ended in this process (`COMPLETED`, `USER_STOPPED`,
         * `TASK_REMOVED`, `SERVICE_STOPPED`, …) while the component's start was
         * still queued. Reopening `RUNNING` here is the ghost window L60 #7
         * found: the drain guard reads `InPlace(RUNNING)` and the next `begin`
         * path rewrites the interrupted marker for a turn the user killed.
         */
        TURN_ENDED("turn_ended"),
    }

    /**
     * The component the platform started asks to run [request] on [backend].
     *
     * One refusal, epoch-scoped, symmetric with [scheduled]'s second refusal:
     * a `STOPPED` state **for this same epoch** is a window that must not come
     * back. The stop can run on the controller's coroutine while `onStartJob` is
     * already queued on the main thread; whichever gets there second used to
     * win, which meant the platform could revive a turn its owner had ended.
     *
     * The exception is [Snapshot.retriable]: a UIDT `onStopJob` returns `true`
     * and the system reschedules the *same* job — same epoch — so that
     * component's `begin` is the documented resume, not a ghost. The flag is
     * cleared by every terminal close, and a late start after one is refused.
     *
     * @return [BeginResult.Started] with the new `RUNNING` state, or
     *   [BeginResult.Refused] carrying the unchanged state and the reason.
     */
    fun begin(backend: Backend, request: TurnRequest): BeginResult = synchronized(lock) {
        val current = state
        if (
            current.phase == Phase.STOPPED &&
            current.epoch == request.epoch &&
            !current.retriable
        ) {
            BeginResult.Refused(RefusalReason.TURN_ENDED, current)
        } else {
            state = Snapshot(
                phase = Phase.RUNNING,
                admissionOpen = true,
                backend = backend,
                epoch = request.epoch,
                step = request.step,
                totalSteps = request.totalSteps,
            )
            BeginResult.Started(state)
        }
    }

    /**
     * Records that the platform **accepted** a window for [request] — before the
     * component that holds it has run.
     *
     * Called only from [TurnJobScheduler.schedule] after a success result
     * (`RESULT_SUCCESS` for UIDT, a foreground-service start that was not refused).
     * A failure must not call this: "maybe it was queued" is not a window, and
     * `TurnRuntime` would then exempt a turn that has no OS promise behind it.
     *
     * Three refusals, all deliberate:
     * * a `RUNNING` window is stronger than a reservation and is never
     *   downgraded — the platform can start the job before `schedule()` returns;
     * * a `STOPPED` state **for this same epoch** means the turn ended while the
     *   window was being created (user stop, host stop). Resurrecting it would
     *   leave a window nobody owns; the caller cancels what it just queued;
     * * that refusal is epoch-scoped, so the *next* turn can be scheduled
     *   normally from `STOPPED` (the state is process-wide, not per-turn).
     *
     * @return the state after the call; see [Snapshot.isScheduled] to tell
     *   whether the reservation was taken.
     */
    fun scheduled(backend: Backend, request: TurnRequest): Snapshot = synchronized(lock) {
        val current = state
        when {
            current.phase == Phase.RUNNING -> current
            current.phase == Phase.STOPPED && current.epoch == request.epoch -> current

            else -> {
                state = Snapshot(
                    phase = Phase.SCHEDULED,
                    // No admission: a queued window is not an executing turn. The
                    // component's own `begin()` is what opens it.
                    admissionOpen = false,
                    backend = backend,
                    epoch = request.epoch,
                    step = request.step,
                    totalSteps = request.totalSteps,
                )
                state
            }
        }
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

    /**
     * Ends the turn.
     *
     * @param retriable `true` only from `onStopJob` returning `true`: the
     *   platform will reschedule this same epoch, so a late [begin] for it is a
     *   resume. The flag is only armed when a window was still open — if the
     *   turn already ended some other way, a late system stop must not re-arm
     *   it (that ordering is the second half of L60 #7).
     */
    fun finish(reason: StopReason, retriable: Boolean = false): Snapshot = synchronized(lock) {
        state = state.copy(
            phase = Phase.STOPPED,
            admissionOpen = false,
            stopReason = reason,
            retriable = retriable && state.hasWindow,
        )
        state
    }

    /**
     * Ends whichever window this process owns — `RUNNING` **or** `SCHEDULED` —
     * in one step.
     *
     * This is the one place a user stop (and the end of a turn) must go through:
     * a queued UIDT job is a window (L53), so 停止本轮 has to clear `SCHEDULED`
     * too. Leaving it would keep the drain guard exempt for a turn the user just
     * killed, and the end of the turn would be reported up to 600 s late
     * (`WindowHold`'s bound) instead of immediately.
     *
     * @return `true` when a window existed and was closed. `false` (no window)
     *   when the phase is already `IDLE`/`STOPPED` — but the call still revokes
     *   a [Snapshot.retriable] stop: the user's stop arriving *after* `onStopJob`
     *   must survive the system's reschedule, or the queued job would resume a
     *   turn its owner already ended (L60 #7).
     */
    fun closeWindow(reason: StopReason): Boolean = synchronized(lock) {
        if (state.hasWindow) {
            state = state.copy(
                phase = Phase.STOPPED,
                admissionOpen = false,
                stopReason = reason,
                retriable = false,
            )
            true
        } else {
            if (state.phase == Phase.STOPPED && state.retriable) {
                state = state.copy(stopReason = reason, retriable = false)
            }
            false
        }
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

    /**
     * Test seam: returns the process-wide state to `IDLE`.
     *
     * `TurnRuntime` is a process singleton, so a JVM test that reads
     * [TurnWindowRead.Platform] (`:dsh` host tests) must be able to start from a
     * known state without leaking a `SCHEDULED`/`RUNNING` window into the next
     * test in the same JVM. `internal`, so no other module can call it.
     */
    internal fun resetForTest() {
        synchronized(lock) {
            state = Snapshot()
            jobBinding = null
        }
    }
}
