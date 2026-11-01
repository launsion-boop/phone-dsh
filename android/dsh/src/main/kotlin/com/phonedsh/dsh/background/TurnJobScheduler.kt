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

package com.phonedsh.dsh.background

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
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
    }
}

class TurnJobScheduler(context: Context) {
    private val appContext: Context = context.applicationContext

    fun channel(): TurnChannel = TurnChannel.current(NotificationCapability.probe(appContext))

    /**
     * Opens the best available window for [request].
     *
     * @param appVisible the caller's truth about the top state. UIDT is only
     *   schedulable from a visible app; the caller is the only party that knows.
     *   Below Android 14 this is ignored: the foreground service is attempted and
     *   its refusal is mapped to [TurnStartResult.ForegroundOnly].
     */
    fun schedule(request: TurnRequest, appVisible: Boolean): TurnStartResult {
        val capability = NotificationCapability.probe(appContext)
        return when (TurnChannel.select(Build.VERSION.SDK_INT, capability)) {
            TurnChannel.FOREGROUND_ONLY -> {
                Log.i(TAG, "no visible notification link; keeping the turn foreground-only")
                TurnStartResult.ForegroundOnly(
                    TurnStartResult.ForegroundOnlyReason.NOTIFICATIONS_UNAVAILABLE,
                )
            }

            TurnChannel.USER_INITIATED_JOB -> scheduleUserInitiated(request, appVisible)

            TurnChannel.DATA_SYNC_FOREGROUND_SERVICE -> startForegroundService(request)
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
