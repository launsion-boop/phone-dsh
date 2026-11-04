// phone-dsh — :dsh / com.phonedsh.dsh.background: UIDT construction and selection.
// SPDX-License-Identifier: MIT
//
// Plan §7.2: UIDT (user-initiated data transfer job) is the primary turn channel
// on Android 14+: `setUserInitiated(true)`, a payload estimate, and the job's own
// notification. Everything about building/scheduling that JobInfo lives here so
// the SDK branch exists in exactly one place:
//
//   API 26–33  -> dataSync foreground service (UIDT does not exist)
//   API 34+    -> UIDT, with the foreground service as fallback when the job
//                 cannot be scheduled (not visible, scheduler refusal)
//   no visible notification -> foreground-only (whitelist
//                 `platform.post-notifications-degraded`)
//
// UIDT contracts enforced from the platform validation rules:
//   * no time delay, no deadline, no periodic, no device-idle, no prefetch;
//   * a network estimate is only legal together with a network constraint, so a
//     no-network turn does not pretend to be a data transfer job;
//   * RUN_USER_INITIATED_JOBS is required or `schedule` throws SecurityException.
//
// ---- success is a window, and it is recorded here (L53) --------------------
// `schedule()` is the only place that knows the platform *accepted* a window
// before any component ran: `JobScheduler.schedule()` returning RESULT_SUCCESS
// and a foreground-service start that was not refused. That acceptance is
// [TurnRuntime.Phase.SCHEDULED] — distinct from [TurnRuntime.Phase.RUNNING],
// which only the component's own `onStartJob` / `onStartCommand` may set. The
// distinction is the whole point: a UIDT job pending on `CONNECTIVITY` is a
// window the OS promised to run, and treating it as "no window" is what killed
// early-HOME turns. A failure ([ForegroundOnly]) records nothing: "maybe it was
// queued" must not exempt a turn from the drain.

package com.phonedsh.dsh.background

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.PersistableBundle
import android.util.Log
import androidx.annotation.RequiresApi

/**
 * Where the turn actually runs after [schedule] is called.
 *
 * The sealed result is the observable degradation contract: callers must not
 * assume a background window was opened when the answer is [ForegroundOnly].
 */
sealed interface TurnStartResult {
    /** UIDT accepted by the system; the job service will post its notification. */
    data class UserInitiatedJobScheduled(val jobId: Int) : TurnStartResult

    /** dataSync foreground service started (below Android 14, or UIDT fallback). */
    data object DataSyncForegroundServiceStarted : TurnStartResult

    /** No background window: run the turn while the app is visible. */
    data class ForegroundOnly(val reason: ForegroundOnlyReason) : TurnStartResult

    enum class ForegroundOnlyReason {
        /** POST_NOTIFICATIONS denied / notifications off: UIDT's progress contract fails. */
        NOTIFICATIONS_UNAVAILABLE,

        /** UIDT can only be scheduled while the app is visible (plan §7.10-B2). */
        APP_NOT_VISIBLE,

        /** The platform refused the foreground-service start. */
        START_NOT_ALLOWED,

        /**
         * The turn ended (user stop / host stop) while its window was being
         * created: the platform accepted it, but no owner is left, so the
         * scheduler cancelled it instead of leaving a window nobody would close.
         */
        TURN_ALREADY_ENDED,
    }
}

/**
 * Which background backend a start result names, or `null` when the result is
 * not a window at all.
 *
 * `null` is the contract the drain guard depends on: a
 * [TurnStartResult.ForegroundOnly] must never be recorded as `SCHEDULED`, or
 * "maybe it was queued" would exempt a turn that has no OS promise behind it.
 * `internal` so the JVM suite can assert the mapping without a `Context`.
 */
internal fun TurnStartResult.windowBackend(): TurnRuntime.Backend? = when (this) {
    is TurnStartResult.UserInitiatedJobScheduled -> TurnRuntime.Backend.USER_INITIATED_JOB
    TurnStartResult.DataSyncForegroundServiceStarted -> TurnRuntime.Backend.FOREGROUND_SERVICE
    is TurnStartResult.ForegroundOnly -> null
}

/**
 * What recording one accepted window did to [TurnRuntime].
 *
 * Deliberately a value, not a side effect: the scheduler's `when` is then the
 * only Android-touching part, and the rule below is exercised on the JVM
 * without a `Context` (L53's unit tests).
 */
internal enum class WindowMark {
    /** The result names no channel (foreground-only): the runtime was not touched. */
    NOT_A_WINDOW,

    /** `SCHEDULED(backend)` was recorded: the platform accepted, the component has not run. */
    RESERVED,

    /**
     * The same turn's window is already `RUNNING` — the platform started the
     * component before `schedule()` returned. The stronger state is kept; the
     * caller cancels nothing.
     */
    ALREADY_RUNNING,

    /**
     * The turn ended while its window was being created (`stop()` ran before the
     * job existed). The caller must cancel what it just queued: a window nobody
     * owns must not start later.
     */
    TURN_ENDED,
}

/**
 * The one place `schedule()` success becomes `TurnRuntime.Phase.SCHEDULED`.
 *
 * The rule is negative as much as positive: a [TurnStartResult.ForegroundOnly]
 * returns [WindowMark.NOT_A_WINDOW] **before** touching the runtime, so a failed
 * schedule can never be read as a window by `TurnWindowRead.Platform` and the
 * drain behaves exactly as it did before the scheduled phase existed.
 */
internal fun markAcceptedWindow(request: TurnRequest, result: TurnStartResult): WindowMark {
    val backend = result.windowBackend() ?: return WindowMark.NOT_A_WINDOW
    val marked = TurnRuntime.scheduled(backend, request)
    return when {
        marked.isScheduled && marked.backend == backend -> WindowMark.RESERVED
        marked.phase == TurnRuntime.Phase.STOPPED && marked.epoch == request.epoch ->
            WindowMark.TURN_ENDED

        else -> WindowMark.ALREADY_RUNNING
    }
}

class TurnJobScheduler(context: Context) {
    private val appContext: Context = context.applicationContext

    fun channel(): TurnChannel = TurnChannel.current(NotificationCapability.probe(appContext))

    /**
     * Opens the best available window for [request].
     *
     * A result that names a channel ([TurnStartResult.UserInitiatedJobScheduled],
     * [TurnStartResult.DataSyncForegroundServiceStarted]) is recorded as
     * [TurnRuntime.Phase.SCHEDULED] before it is returned; a
     * [TurnStartResult.ForegroundOnly] is not a window and records nothing.
     *
     * @param appVisible the caller's truth about the top state. UIDT is only
     *   schedulable from a visible app; the caller is the only party that knows.
     *   Below Android 14 this is ignored: the foreground service is attempted and
     *   its refusal is mapped to [TurnStartResult.ForegroundOnly].
     */
    fun schedule(request: TurnRequest, appVisible: Boolean): TurnStartResult {
        val capability = NotificationCapability.probe(appContext)
        val result = when (TurnChannel.select(Build.VERSION.SDK_INT, capability)) {
            TurnChannel.FOREGROUND_ONLY -> {
                Log.i(TAG, "no visible notification link; keeping the turn foreground-only")
                TurnStartResult.ForegroundOnly(
                    TurnStartResult.ForegroundOnlyReason.NOTIFICATIONS_UNAVAILABLE,
                )
            }

            TurnChannel.USER_INITIATED_JOB -> scheduleUserInitiated(request, appVisible)

            TurnChannel.DATA_SYNC_FOREGROUND_SERVICE -> startForegroundService(request)
        }
        return recordScheduledWindow(request, result)
    }

    /**
     * Records the accepted window, or leaves the runtime untouched on failure.
     *
     * The decision itself lives in [markAcceptedWindow] (pure: no `Context`, no
     * `Log`) so the JVM suite can prove "success reserves, failure records
     * nothing" without a device. This method only performs the side effects that
     * need the platform: the log line and, for the one refusal that leaves a real
     * job behind, the cancel.
     */
    private fun recordScheduledWindow(
        request: TurnRequest,
        result: TurnStartResult,
    ): TurnStartResult {
        return when (markAcceptedWindow(request, result)) {
            WindowMark.NOT_A_WINDOW -> {
                Log.i(
                    TAG,
                    "no window accepted for epoch ${request.epoch} (foreground-only); " +
                        "the turn runtime is left untouched",
                )
                result
            }

            WindowMark.RESERVED -> {
                Log.i(
                    TAG,
                    "window accepted: backend=${result.windowBackend()} phase=scheduled " +
                        "epoch=${request.epoch} step=${request.step}/${request.totalSteps} " +
                        "(the component has not run yet)",
                )
                result
            }

            WindowMark.ALREADY_RUNNING -> {
                Log.i(
                    TAG,
                    "epoch ${request.epoch}: the window is already running " +
                        "(the platform started the component before schedule() returned); " +
                        "the stronger state is kept and nothing is cancelled",
                )
                result
            }

            WindowMark.TURN_ENDED -> {
                Log.w(
                    TAG,
                    "epoch ${request.epoch} ended while its window was being created; " +
                        "cancelling the window that was just accepted",
                )
                result.windowBackend()?.let(::cancelWindow)
                TurnStartResult.ForegroundOnly(
                    TurnStartResult.ForegroundOnlyReason.TURN_ALREADY_ENDED,
                )
            }
        }
    }

    /** Undoes a window this scheduler created for a turn that has already ended. */
    private fun cancelWindow(backend: TurnRuntime.Backend) {
        when (backend) {
            TurnRuntime.Backend.USER_INITIATED_JOB -> runCatching {
                appContext.getSystemService(JobScheduler::class.java)?.cancel(JOB_ID)
            }.onFailure { Log.w(TAG, "cancelling the queued UIDT failed: ${it.message}") }

            TurnRuntime.Backend.FOREGROUND_SERVICE -> runCatching {
                appContext.stopService(Intent(appContext, TurnForegroundService::class.java))
            }.onFailure { Log.w(TAG, "stopping the queued foreground service failed: ${it.message}") }
        }
    }

    private fun scheduleUserInitiated(request: TurnRequest, appVisible: Boolean): TurnStartResult {
        if (!request.requiresNetwork) {
            // UIDT is a data-transfer job; a local-only turn must not claim it.
            Log.i(TAG, "turn needs no network; using the dataSync fallback instead of UIDT")
            return startForegroundService(request)
        }
        if (!appVisible) {
            Log.i(TAG, "app not visible; UIDT cannot be scheduled (plan §7.10-B2)")
            return TurnStartResult.ForegroundOnly(
                TurnStartResult.ForegroundOnlyReason.APP_NOT_VISIBLE,
            )
        }
        if (Build.VERSION.SDK_INT < TurnChannel.USER_INITIATED_JOB_MIN_SDK) {
            return startForegroundService(request)
        }
        val result = try {
            val scheduler = appContext.getSystemService(JobScheduler::class.java)
            scheduler.schedule(buildJobInfo(request))
        } catch (error: IllegalArgumentException) {
            Log.w(TAG, "UIDT rejected by JobScheduler: ${error.message}")
            JobScheduler.RESULT_FAILURE
        } catch (error: SecurityException) {
            Log.w(TAG, "UIDT permission missing: ${error.message}")
            JobScheduler.RESULT_FAILURE
        }
        return if (result == JobScheduler.RESULT_SUCCESS) {
            Log.i(TAG, "UIDT scheduled for epoch ${request.epoch}")
            TurnStartResult.UserInitiatedJobScheduled(JOB_ID)
        } else {
            // Whitelist `platform.bgtask-drain-window`: the dataSync FGS is the
            // fallback when the primary channel cannot be scheduled.
            Log.i(TAG, "UIDT refused by the platform; falling back to dataSync FGS")
            startForegroundService(request)
        }
    }

    /**
     * Builds the UIDT `JobInfo` without scheduling it. Public so device probes can
     * assert the shape (user-initiated, estimates, extras) even when the job starts
     * immediately and is therefore no longer in `getAllPendingJobs()`.
     */
    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    fun buildJobInfo(request: TurnRequest): JobInfo {
        val extras = PersistableBundle().apply {
            putLong(TurnRequest.EXTRA_EPOCH, request.epoch)
            putInt(TurnRequest.EXTRA_STEP, request.step)
            putInt(TurnRequest.EXTRA_TOTAL_STEPS, request.totalSteps)
        }
        val builder = JobInfo.Builder(
            JOB_ID,
            ComponentName(appContext, TurnJobService::class.java),
        )
            .setUserInitiated(true)
            .setExtras(extras)
        if (request.requiresNetwork) {
            builder.setRequiredNetwork(
                NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .build(),
            )
            // The platform only accepts estimates together with a network
            // constraint (JobInfo.enforceValidity), which is exactly the UIDT
            // payload contract of plan §7.2.
            builder.setEstimatedNetworkBytes(
                request.estimatedDownloadBytes,
                request.estimatedUploadBytes,
            )
        }
        return builder.build()
    }

    private fun startForegroundService(request: TurnRequest): TurnStartResult =
        if (TurnForegroundService.start(appContext, request)) {
            TurnStartResult.DataSyncForegroundServiceStarted
        } else {
            Log.w(TAG, "foreground-service start refused; reporting foreground-only")
            TurnStartResult.ForegroundOnly(
                TurnStartResult.ForegroundOnlyReason.START_NOT_ALLOWED,
            )
        }

    companion object {
        const val TAG = "PDSHTurnJob"
        const val JOB_ID = 8401
    }
}
