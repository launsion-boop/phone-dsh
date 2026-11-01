// phone-dsh — :dsh / com.phonedsh.dsh.background: the UIDT job service.
// SPDX-License-Identifier: MIT
//
// The primary turn channel on Android 14+ (plan §7.2). The job gets a window the
// system itself manages (wakelock included, no App Standby quota), and the
// notification is attached with `setNotification` so the system can show it in
// both the status bar and the Task Manager.
//
// Two contracts matter here:
//   * `onStopJob` returns true: a system stop is a *retriable* event (resume
//     semantics, whitelist `platform.bgtask-drain-window`), and admission closes
//     before we hand control back;
//   * the job must record its state durably *before* finishing, because the
//     platform documents that onStopJob is not guaranteed to be called (plan
//     §7.4: even without a callback, persist state and recover on next start). The
//     InterruptedTurnStore marker is written in onStartJob, so a silent death still
//     leaves a tombstone.

package com.phonedsh.dsh.background

import android.app.job.JobParameters
import android.app.job.JobService
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi

class TurnJobService : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        TurnNotifications.ensureChannels(this)
        val request = requestFrom(params)
        if (request == null) {
            Log.w(TAG, "job ${params.jobId} has no turn extras; finishing without work")
            jobFinished(params, false)
            return false
        }
        TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request)
        TurnRuntime.bindJob(this, params)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            attachNotification(params)
        }
        InterruptedTurnStore(this).begin(request.epoch, request.step, request.totalSteps)
        TombstoneScheduler.enqueue(this)
        // The turn runtime (owner: :controller) ends the job through
        // TurnBackground.complete()/stop(); returning true keeps the window open.
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        // Whitelist `platform.bgtask-drain-window`: system stop is retriable. Close
        // admission, keep the durable marker, and let the system reschedule.
        if (TurnRuntime.snapshot().backend == TurnRuntime.Backend.USER_INITIATED_JOB) {
            TurnRuntime.closeAdmission(TurnRuntime.StopReason.JOB_STOPPED)
            TurnRuntime.finish(TurnRuntime.StopReason.JOB_STOPPED)
        }
        InterruptedTurnStore(this).noteInterruption(TurnRuntime.StopReason.JOB_STOPPED)
        TurnNotifications.cancelProgress(this)
        Log.i(TAG, "UIDT stopped by system (stopReason=${stopReasonName(params)}); retriable")
        return true
    }

    /** Exposed for the job's own notification updates. Caller must be on API 34+. */
    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    internal fun updateNotification(params: JobParameters) {
        setNotification(
            params,
            TurnNotifications.PROGRESS_NOTIFICATION_ID,
            TurnNotifications.progress(this, TurnRuntime.snapshot()),
            JobService.JOB_END_NOTIFICATION_POLICY_DETACH,
        )
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun attachNotification(params: JobParameters) {
        setNotification(
            params,
            TurnNotifications.PROGRESS_NOTIFICATION_ID,
            TurnNotifications.progress(this, TurnRuntime.snapshot()),
            JobService.JOB_END_NOTIFICATION_POLICY_DETACH,
        )
    }

    private fun requestFrom(params: JobParameters): TurnRequest? {
        val extras = params.extras
        val epoch = extras.getLong(TurnRequest.EXTRA_EPOCH, TurnRuntime.UNKNOWN_EPOCH)
        if (epoch == TurnRuntime.UNKNOWN_EPOCH) return null
        return TurnRequest(
            epoch = epoch,
            step = extras.getInt(TurnRequest.EXTRA_STEP, 0),
            totalSteps = extras.getInt(TurnRequest.EXTRA_TOTAL_STEPS, 0),
        )
    }

    private fun stopReasonName(params: JobParameters): String = if (
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
    ) {
        params.stopReason.toString()
    } else {
        "unavailable below API 31"
    }

    companion object {
        const val TAG = "PDSHTurnJobService"
    }
}
