// "Warm but sealed": the state machine that lets the environment stay up while
// the internal roots stay at chmod 000 between jobs.
// SPDX-License-Identifier: MIT
//
// ---- the one idea this file exists for ------------------------------------
// Plan §3 layer 0 splits two lifecycles that the first draft had welded
// together:
//
//   environment:  start -> (may span several jobs) -> close
//   seal:         per job:  seal -> run -> restore
//
// Welded, the design can only be one of two bad shapes: cold-start every job
// (the environment is re-created per seal), or keep the environment warm with
// the internal roots readable for as long as it lives (a permanent extension of
// the exposure window). Split, the interesting state appears:
//
//   IdleSealed -- the environment is alive and warm, no job is running, and the
//   internal roots are still 000.
//
// That state is the only shape that gets both the low latency and the small
// window, so it is a first-class state here rather than an incidental "no job"
// flag. Every transition in and out of it is tested
// (`BuildRuntimeStateMachineTest`).
//
// ---- who may close ---------------------------------------------------------
// Plan §4.5 is asymmetric on purpose: the agent may close at any time without
// asking, and may not stop the system from closing. So [close] takes a
// [CloseReason] but no veto, and works from [BuildRuntimeState.JobRunning]
// exactly as it works from [BuildRuntimeState.IdleSealed]. Closing early costs a
// cold start next time; closing late costs exposure, which is not recoverable.
//
// ---- restore is in the finally --------------------------------------------
// A close has three parts: reap the process tree, restore the roots, and say so.
// The restore must happen even when the reap throws, because "the job died
// badly" is exactly when a root is most likely to be left at 000. Every path
// through [close] therefore runs the restore in a `finally`, and the resulting
// state is [BuildRuntimeState.Closed] unless the restore itself failed, in which
// case it is [BuildRuntimeState.Broken] with the marker left for the next boot.

package com.phonedsh.platform.android

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * The live watch behind the audit: a `FileObserver` on the device, a fake in the
 * host JVM suite.
 *
 * The runtime owns the window because the audit is per job: `beginJob` arms it,
 * `endJob` and `close` disarm it, so an access between two jobs cannot be
 * attributed to the wrong one.
 */
interface SealWatch {
    /** Starts delivering events into the audit. */
    fun start()

    /** Stops delivering events. Idempotent. */
    fun stop()
}

/** Why a close happened; the reason never changes what the close does. */
enum class CloseReason {
    /** The agent decided it was done. Always allowed, never asked about. */
    AGENT,

    /** The idle timeout fired. */
    SYSTEM_TIMEOUT,

    /** The app moved to the background (Doze, user switched away). */
    SYSTEM_BACKGROUND,

    /** The system is short of memory; the app may be next. */
    MEMORY_PRESSURE,

    /** A test drove the close directly. */
    TEST,
}

/**
 * The lifecycle of the local environment, with the seal folded in.
 *
 * The states carry the seal handle so a caller can only ever restore a seal it
 * was given, and so the "warm but sealed" state proves what it claims.
 */
sealed interface BuildRuntimeState {
    /** No environment was ever started in this process. */
    data object NotStarted : BuildRuntimeState

    /**
     * Started, warm, no job running, **and the internal roots are 000**.
     *
     * @property seal the active seal: the evidence that this state is sealed
     *   rather than merely idle.
     * @property sinceMs when the environment entered this state.
     */
    data class IdleSealed(val seal: SealHandle, val sinceMs: Long) : BuildRuntimeState

    /**
     * A job is running inside the seal.
     *
     * @property seal the active seal.
     * @property job the job id.
     * @property startedAtMs when the job started.
     */
    data class JobRunning(val seal: SealHandle, val job: String, val startedAtMs: Long) : BuildRuntimeState

    /**
     * Closing: reaping the process tree and restoring the roots.
     *
     * @property reason why the close started.
     */
    data class Reaping(val reason: CloseReason) : BuildRuntimeState

    /** Reaped and restored; nothing of this environment is left running. */
    data object Closed : BuildRuntimeState

    /**
     * Fail-closed: the seal could not be established or restored, so the
     * environment must not run.
     *
     * @property failure the stable reason.
     * @property detail what to show the user.
     * @property atMs when it broke.
     */
    data class Broken(val failure: SealFailure, val detail: String, val atMs: Long) : BuildRuntimeState
}

/** The outcome of one requested transition; a refusal leaves the state alone. */
sealed interface Transition {
    /** The transition ran. */
    data class Accepted(val from: BuildRuntimeState, val to: BuildRuntimeState) : Transition

    /**
     * The transition is not legal from the current state, and nothing changed.
     *
     * Callers must treat this as a refusal: a refused [BuildRuntime.beginJob]
     * means **the job must not start**, which is the fail-closed rule.
     */
    data class Refused(val state: BuildRuntimeState, val reason: String) : Transition
}

/**
 * What one close produced.
 *
 * @property reason the reason it was asked for.
 * @property harvest the process-tree report, or `null` when no reaper was
 *   configured or the environment never started.
 * @property sealRestored whether the roots are back at their original modes.
 * @property restoreDetail why the restore failed, when it did.
 * @property state the state after the close.
 */
data class CloseOutcome(
    val reason: CloseReason,
    val harvest: HarvestReport?,
    val sealRestored: Boolean,
    val restoreDetail: String?,
    val state: BuildRuntimeState,
)

/**
 * The environment's lifecycle owner.
 *
 * One instance per process. All transitions are serialised by one [Mutex] so a
 * system close racing an agent close cannot interleave two reaps, and the state
 * flow always names a state the runtime can actually be in.
 *
 * @param seal the seal over the workspace's internal roots.
 * @param tripwire the audit the watch feeds; the runtime opens and closes its
 *   window per job.
 * @param reaper the process-tree reaper; `null` when no job process can exist
 *   (the JVM tests use a fake table, the device path uses the real one).
 * @param clock the wall clock, for the state timestamps.
 */
class BuildRuntime(
    private val seal: BuildSeal,
    private val tripwire: BuildSealTripwire,
    private val reaper: ProcessTreeReaper?,
    private val watch: SealWatch? = null,
    private val nowMs: () -> Long = { System.currentTimeMillis() },
) {
    private val mutex = Mutex()

    private val mutableState = MutableStateFlow<BuildRuntimeState>(BuildRuntimeState.NotStarted)

    /** The current state, readable from any thread. */
    val state: StateFlow<BuildRuntimeState> = mutableState.asStateFlow()

    /** The pids of the running job, so a close can reap them without the caller. */
    private val jobPids = LinkedHashSet<Int>()

    /** The process groups of the job, recorded before the pid can vanish. */
    private val jobGroups = LinkedHashSet<Int>()

    /** The last closed audit, so a status can still carry it after the close. */
    private var lastAudit: TripwireReport = EMPTY_REPORT

    /** The current state, without collecting the flow. */
    fun snapshot(): BuildRuntimeState = mutableState.value

    /** The audit of the most recent job. */
    fun lastAudit(): TripwireReport = lastAudit

    /**
     * Starts the environment and seals it: `NotStarted`/`Closed` -> `IdleSealed`.
     *
     * The seal is established before the state says "started", so there is no
     * moment in which the environment is up and the roots are readable. A seal
     * failure moves the state to [BuildRuntimeState.Broken] and no job may
     * start afterwards.
     *
     * @param job the job id the seal is booked under.
     */
    suspend fun start(job: String = "environment"): Transition = mutex.withLock {
        val from = mutableState.value
        when (from) {
            is BuildRuntimeState.NotStarted, is BuildRuntimeState.Closed -> Unit
            else -> return@withLock Transition.Refused(from, "the environment is already started")
        }
        try {
            val handle = seal.seal(job)
            val to = BuildRuntimeState.IdleSealed(handle, nowMs())
            mutableState.value = to
            Transition.Accepted(from, to)
        } catch (failure: SealException) {
            val broken = BuildRuntimeState.Broken(failure.failure, failure.detail, nowMs())
            mutableState.value = broken
            Transition.Accepted(from, broken)
        }
    }

    /**
     * Opens one job: `IdleSealed` -> `JobRunning`.
     *
     * The roots are already 000 from [start], so beginning a job never widens
     * the seal -- that is the whole point of keeping the environment warm.
     *
     * @param job the job id.
     */
    suspend fun beginJob(job: String): Transition = mutex.withLock {
        val from = mutableState.value
        if (from !is BuildRuntimeState.IdleSealed) {
            return@withLock Transition.Refused(from, "only an idle sealed environment can begin a job")
        }
        jobPids.clear()
        jobGroups.clear()
        tripwire.begin()
        watch?.start()
        val to = BuildRuntimeState.JobRunning(from.seal, job, nowMs())
        mutableState.value = to
        Transition.Accepted(from, to)
    }

    /**
     * Ends one job: `JobRunning` -> `IdleSealed`.
     *
     * The seal stays where it is. Closing the audit here is what makes
     * `internalAccessObserved` per job rather than per environment.
     *
     * inotify delivery is asynchronous: the job's last `chmod` can still be in
     * the kernel queue when the job exits, so the audit waits [settleMs] before
     * closing. Without it, a bypass in the final milliseconds of a job would be
     * reported as a clean run -- the exact false negative §4 is not allowed to
     * have. The cost is one short sleep on the close path, not on the run path.
     *
     * @param job the job id.
     * @param settleMs how long to keep the audit open after the job exits.
     */
    suspend fun endJob(job: String, settleMs: Long = DEFAULT_AUDIT_SETTLE_MS): Transition = mutex.withLock {
        val from = mutableState.value
        if (from !is BuildRuntimeState.JobRunning || from.job != job) {
            return@withLock Transition.Refused(from, "no job \"$job\" is running")
        }
        if (settleMs > 0) delay(settleMs)
        lastAudit = tripwire.end()
        watch?.stop()
        val to = BuildRuntimeState.IdleSealed(from.seal, nowMs())
        mutableState.value = to
        Transition.Accepted(from, to)
    }

    /**
     * Records a job process and its process group, so the close can reap both
     * without the caller having to remember them.
     *
     * The group has to be recorded up front: by the time the close runs the root
     * pid is usually gone, and a pid that no longer exists has no readable
     * process group.
     *
     * @param pid the job's pid.
     * @param processGroup the group it leads; `setsid` makes both the same.
     */
    fun noteProcess(pid: Int, processGroup: Int = pid) {
        synchronized(jobPids) {
            jobPids.add(pid)
            jobGroups.add(processGroup)
        }
    }

    /**
     * Closes the environment: reap, restore, report.
     *
     * Works from every state, including [BuildRuntimeState.JobRunning] (the
     * system has no veto to respect) and from [BuildRuntimeState.Broken] (the
     * seal still has to be undone if it was partly applied). Calling it twice
     * is a no-op the second time.
     *
     * @param reason why; it is reported, never used to decide what to do.
     */
    suspend fun close(reason: CloseReason): CloseOutcome = withContext(NonCancellable) {
        // NonCancellable, because "the caller's coroutine was cancelled" is not
        // a reason to leave the roots at 000: a job that is cancelled mid-flight
        // is exactly when a close matters. A close that arrives while another is
        // running waits here and then observes Closed, so two reaps cannot
        // interleave and the second call never re-chmods a restored root.
        mutex.withLock { closeLocked(reason) }
    }

    private suspend fun closeLocked(reason: CloseReason): CloseOutcome {
        val from = mutableState.value
        if (from is BuildRuntimeState.Closed) {
            return closeOutcome(reason, null, from, null)
        }
        if (from is BuildRuntimeState.NotStarted) {
            mutableState.value = BuildRuntimeState.Closed
            return closeOutcome(reason, null, BuildRuntimeState.Closed, null)
        }

        mutableState.value = BuildRuntimeState.Reaping(reason)
        // Stop attributing events before the restore chmods the roots back. The
        // window may already be closed by endJob, and a close that follows one
        // must not stop the watch twice or overwrite that job's report.
        if (tripwire.isArmed()) {
            watch?.stop()
            lastAudit = tripwire.end()
        }

        var harvest: HarvestReport? = null
        var restoreDetail: String? = null
        var restored = true
        var state = from
        try {
            val pids = synchronized(jobPids) { jobPids.toList() }
            val groups = synchronized(jobPids) { jobGroups.toList() }
            harvest = reaper?.harvest(pids, groups)
        } catch (failure: Throwable) {
            // The reap is reported, never trusted to have happened.
            harvest = HarvestReport(
                tree = emptyList(),
                groups = emptyList(),
                skippedGroups = emptyList(),
                survivors = emptyList(),
                killedSurvivors = emptyList(),
                unkillable = emptyList(),
                errors = listOf("harvest failed: ${failure.message}"),
            )
        } finally {
            // Plan §4.5: the restore happens even when everything above threw.
            try {
                val handle = (from as? BuildRuntimeState.IdleSealed)?.seal
                    ?: (from as? BuildRuntimeState.JobRunning)?.seal
                    ?: seal.active()
                if (handle != null) seal.restore(handle)
            } catch (failure: SealException) {
                restored = false
                restoreDetail = failure.detail
            } catch (failure: Throwable) {
                restored = false
                restoreDetail = failure.message
            }
            synchronized(jobPids) {
                jobPids.clear()
                jobGroups.clear()
            }
            state = if (restored) {
                BuildRuntimeState.Closed
            } else {
                BuildRuntimeState.Broken(
                    SealFailure.RESTORE_FAILED,
                    restoreDetail ?: "the seal could not be restored",
                    nowMs(),
                )
            }
            mutableState.value = state
        }
        return closeOutcome(reason, harvest, state, restoreDetail)
    }

    private fun closeOutcome(
        reason: CloseReason,
        harvest: HarvestReport?,
        state: BuildRuntimeState,
        restoreDetail: String?,
    ): CloseOutcome = CloseOutcome(
        reason = reason,
        harvest = harvest,
        sealRestored = state is BuildRuntimeState.Closed,
        restoreDetail = restoreDetail,
        state = state,
    )

    companion object {
        /** How long the audit stays open after a job exits, for inotify delivery. */
        const val DEFAULT_AUDIT_SETTLE_MS: Long = 200L

        private val EMPTY_REPORT = TripwireReport(
            armed = false,
            observed = false,
            events = emptyList(),
            dropped = 0,
            excused = 0,
        )
    }
}
