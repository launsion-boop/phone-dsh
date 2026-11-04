// phone-dsh — :dsh / com.phonedsh.dsh.background: the public background facade.
// SPDX-License-Identifier: MIT
//
// One entry point for the composition root:
//
//   TurnBackground.capability(context)  -> whether progress is visible at all
//   TurnBackground.start(request, appVisible) -> which window actually opened
//   TurnBackground.progress(step)       -> update notification + durable step
//   TurnBackground.complete()/stop()    -> close the window honestly
//   TurnBackground.lastInterruptedTurn()/pendingReport() -> next-open report
//
// The facade is intentionally thin: channel choice lives in TurnJobScheduler, state
// in TurnRuntime, durability in InterruptedTurnStore, text in TurnNotifications.

package com.phonedsh.dsh.background

import android.app.job.JobScheduler
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi

object TurnBackground {
    fun capability(context: Context): NotificationCapability =
        NotificationCapability.probe(context.applicationContext)

    fun channel(context: Context): TurnChannel =
        TurnChannel.current(capability(context))

    fun state(): TurnRuntime.Snapshot = TurnRuntime.snapshot()

    /**
     * Opens the best available window. The returned [TurnStartResult] is the truth:
     * when it is [TurnStartResult.ForegroundOnly] no background execution is
     * happening, regardless of what the caller asked for.
     */
    fun start(
        context: Context,
        request: TurnRequest,
        appVisible: Boolean,
    ): TurnStartResult = TurnJobScheduler(context.applicationContext).schedule(request, appVisible)

    /** Updates the notification and the durable last-step marker. */
    fun progress(context: Context, step: Int) {
        if (!TurnRuntime.snapshot().isRunning) return
        val snapshot = TurnRuntime.progress(step)
        InterruptedTurnStore(context.applicationContext).advance(snapshot.step, snapshot.totalSteps)
        when (snapshot.backend) {
            TurnRuntime.Backend.FOREGROUND_SERVICE ->
                TurnNotifications.postProgress(context.applicationContext, snapshot)

            TurnRuntime.Backend.USER_INITIATED_JOB ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    updateUserInitiatedNotification()
                }

            null -> Unit
        }
    }

    /**
     * The turn finished successfully. Stops whichever backend owns the window and
     * removes the marker: a completed turn must not produce a tombstone.
     *
     * A window that was only `SCHEDULED` (the turn ended before the platform
     * started the component) is closed the same way [stop] closes it: the queued
     * job must not start after its owner is gone and reopen a window nobody will
     * close.
     */
    fun complete(context: Context) {
        val snapshot = TurnRuntime.snapshot()
        if (snapshot.isScheduled) {
            // Not "running", so the body below would return early and leave the
            // reservation behind. `stop` owns the cancel path for a window that
            // never started, including the queued `JobScheduler` job.
            stop(context, TurnRuntime.StopReason.COMPLETED)
            return
        }
        if (!snapshot.isRunning) return
        TurnRuntime.finish(TurnRuntime.StopReason.COMPLETED)
        InterruptedTurnStore(context.applicationContext).complete()
        TombstoneScheduler.cancel(context.applicationContext)
        when (snapshot.backend) {
            TurnRuntime.Backend.FOREGROUND_SERVICE ->
                context.applicationContext.stopService(
                    Intent(context.applicationContext, TurnForegroundService::class.java),
                )

            TurnRuntime.Backend.USER_INITIATED_JOB -> TurnRuntime.finishJob(false)

            null -> Unit
        }
        TurnNotifications.cancelProgress(context.applicationContext)
    }

    /**
     * Ends the window on request (user stop, task removal, controller decision).
     * Returns whether a live window existed — `SCHEDULED` included: a window the
     * platform accepted but has not started is exactly what the user's 停止本轮
     * is about on a device that just booted, and it must end immediately rather
     * than linger until the job's constraint is satisfied.
     *
     * No drain, no fsync: the WAL write path is the durability guarantee
     * (plan §7.4-1).
     */
    fun stop(context: Context, reason: TurnRuntime.StopReason): Boolean {
        val appContext = context.applicationContext
        val snapshot = TurnRuntime.snapshot()
        // Closes RUNNING and SCHEDULED alike in one step; a second close (a
        // duplicated stop) reports `false`. It still revokes a retriable system
        // stop, because a job the platform rescheduled must not resume a turn
        // the user just ended (L60 #7).
        val hadWindow = TurnRuntime.closeWindow(reason)
        if (hadWindow) {
            // A stop the user asked for is not an interruption to report later.
            InterruptedTurnStore(appContext).complete()
            TombstoneScheduler.cancel(appContext)
            when (snapshot.backend) {
                TurnRuntime.Backend.FOREGROUND_SERVICE ->
                    appContext.stopService(Intent(appContext, TurnForegroundService::class.java))

                TurnRuntime.Backend.USER_INITIATED_JOB -> TurnRuntime.finishJob(false)

                null -> Unit
            }
            TurnNotifications.cancelProgress(appContext)
        }
        // A UIDT can be scheduled without onStartJob having run yet; a user stop
        // must cancel it too. When a running job was just finished, cancelling it
        // again could race with a retry request, so it is skipped in that case.
        val justFinishedJob = snapshot.isRunning &&
            snapshot.backend == TurnRuntime.Backend.USER_INITIATED_JOB
        if (!justFinishedJob) {
            runCatching {
                appContext.getSystemService(JobScheduler::class.java)?.cancel(TurnJobScheduler.JOB_ID)
            }
        }
        return hadWindow
    }

    /** The surviving interruption marker for the next-open banner, if any. */
    fun lastInterruptedTurn(context: Context): InterruptedTurnStore.InterruptedTurn? =
        InterruptedTurnStore(context.applicationContext).interrupted()

    /** Clears the marker after the UI has shown it. */
    fun clearInterruptedTurn(context: Context) {
        InterruptedTurnStore(context.applicationContext).complete()
    }

    /** The report queued while notifications were unavailable. */
    fun pendingReport(context: Context): InterruptedTurnStore.PendingReport? =
        InterruptedTurnStore(context.applicationContext).pendingReport()

    fun consumePendingReport(context: Context): InterruptedTurnStore.PendingReport? =
        InterruptedTurnStore(context.applicationContext).consumePendingReport()

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun updateUserInitiatedNotification() {
        val binding = TurnRuntime.jobBinding() ?: return
        val service = binding.service as? TurnJobService
        if (service == null) {
            Log.w(TAG, "UIDT binding is not a TurnJobService; notification not updated")
            return
        }
        runCatching { service.updateNotification(binding.params) }
            .onFailure { Log.w(TAG, "UIDT notification update failed: ${it.message}") }
    }

    private const val TAG = "PDSHTurnBackground"
}
