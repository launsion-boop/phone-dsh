// phone-dsh — :dsh / com.phonedsh.dsh.background: the dataSync foreground service.
// SPDX-License-Identifier: MIT
//
// The fallback channel (plan §7.2): below Android 14 this is the only official
// way to keep a turn executing in the background; on 14+ it backs UIDT when the
// job cannot be scheduled. It is a *window*, not the drain:
//   * it holds the process and shows the honest progress notification;
//   * `onTimeout` closes admission and nothing else — no fsync, no WAL epoch close
//     (plan §7.10: a few seconds of window would tear an epoch);
//   * it never restarts itself (`START_NOT_STICKY`): a platform restart is not a
//     turn resume; the tombstone reports the interruption instead.
//
// Task Manager Stop / OEM force-stop kill this service with zero callbacks. That
// is expected: durability lives in the WAL write path, and the surviving
// InterruptedTurnStore marker is what the next process reports.

package com.phonedsh.dsh.background

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

class TurnForegroundService : Service() {
    override fun onCreate() {
        super.onCreate()
        TurnNotifications.ensureChannels(this)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // Kept for callers that hold a service Intent (the notification itself
            // goes through TurnStopReceiver so both channels share one entry point).
            TurnBackground.stop(this, TurnRuntime.StopReason.USER_STOPPED)
            return START_NOT_STICKY
        }
        val request = TurnRequest.fromIntent(intent)
        if (request == null) {
            Log.w(TAG, "start without a turn request; refusing to run an unowned window")
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (!TurnRuntime.snapshot().isRunning) {
            when (val begun = TurnRuntime.begin(TurnRuntime.Backend.FOREGROUND_SERVICE, request)) {
                is TurnRuntime.BeginResult.Refused -> {
                    // A start queued before the user stopped the turn: the same
                    // ghost window the UIDT path refuses (L60 #7). Nothing was
                    // promoted to the foreground, so there is nothing to detach;
                    // stop what the platform started and write no marker.
                    Log.w(
                        TAG,
                        "start for epoch=${request.epoch} refused (${begun.reason.wire}); " +
                            "the turn already ended, stopping without running",
                    )
                    stopSelf(startId)
                    return START_NOT_STICKY
                }

                is TurnRuntime.BeginResult.Started -> Unit
            }
        }
        val snapshot = TurnRuntime.snapshot()
        val started = try {
            ServiceCompat.startForeground(
                this,
                TurnNotifications.PROGRESS_NOTIFICATION_ID,
                TurnNotifications.progress(this, snapshot),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
            true
        } catch (error: RuntimeException) {
            // ForegroundServiceStartNotAllowedException (12+), missing type or
            // revoked permission: the window is not valid. Do not pretend it is.
            Log.w(TAG, "foreground promotion refused: ${error.javaClass.simpleName}")
            false
        }
        if (!started) {
            TurnRuntime.closeAdmission(TurnRuntime.StopReason.SERVICE_STOPPED)
            TurnRuntime.finish(TurnRuntime.StopReason.SERVICE_STOPPED)
            val store = InterruptedTurnStore(this)
            val marker = store.begin(request.epoch, request.step, request.totalSteps)
            store.noteInterruption(TurnRuntime.StopReason.SERVICE_STOPPED)
            store.promotePendingReport(store.interrupted() ?: marker)
            stopSelf(startId)
            return START_NOT_STICKY
        }
        // The marker is written only after the window is actually open.
        InterruptedTurnStore(this).begin(request.epoch, request.step, request.totalSteps)
        TombstoneScheduler.enqueue(this)
        return START_NOT_STICKY
    }

    /**
     * Android 8.0–14: called for short-service time limits; this service is
     * dataSync, so the interesting path on Android 15+ is the two-argument
     * override below.
     */
    override fun onTimeout(startId: Int) {
        handleTimeout("onTimeout(startId=$startId)")
    }

    /** Android 15+ dataSync budget (6 h / 24 h rolling) expires through here. */
    @RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
    override fun onTimeout(startId: Int, fgsType: Int) {
        handleTimeout("onTimeout(startId=$startId, fgsType=$fgsType)")
    }

    /**
     * Plan §7.10 "onTimeout 与 epoch close 解耦": close admission, write down why,
     * tell the user, and leave. No fsync and no epoch close happen here — the epoch
     * belongs to the timer in `:controller`, and a sliced epoch is worse than an
     * interrupted turn.
     */
    private fun handleTimeout(reason: String) {
        if (!TurnRuntime.snapshot().isRunning) return
        Log.i(TAG, "foreground-service budget expired by $reason; closing admission only")
        TurnRuntime.closeAdmission(TurnRuntime.StopReason.SYSTEM_TIMEOUT)
        val store = InterruptedTurnStore(this)
        val turn = store.noteInterruption(TurnRuntime.StopReason.SYSTEM_TIMEOUT)
        val snapshot = TurnRuntime.snapshot()
        // Post before detaching so the notification is replaced, not flickered away.
        val posted = TurnNotifications.postTimedOut(this, snapshot)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_DETACH)
        TurnRuntime.finish(TurnRuntime.StopReason.SYSTEM_TIMEOUT)
        when {
            posted -> store.markReported()
            turn != null -> store.promotePendingReport(turn)
        }
        stopSelf()
    }

    /**
     * Defensive path: with `android:stopWithTask="true"` the platform stops the
     * service on task removal and normally skips this callback. If a ROM calls it
     * first, take the deterministic route: close admission, keep the WAL and the
     * marker, stop.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (TurnRuntime.snapshot().isRunning) {
            Log.i(TAG, "task removed; closing admission (no drain, no fsync)")
            TurnRuntime.closeAdmission(TurnRuntime.StopReason.TASK_REMOVED)
            TurnRuntime.finish(TurnRuntime.StopReason.TASK_REMOVED)
            InterruptedTurnStore(this).noteInterruption(TurnRuntime.StopReason.TASK_REMOVED)
        }
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        val snapshot = TurnRuntime.snapshot()
        if (snapshot.isRunning) {
            // Nobody decided the outcome: the platform ended the service (battery
            // saver, OEM kill, task removal through stopWithTask). Keep the marker
            // for the next-open / tombstone report.
            TurnRuntime.closeAdmission(TurnRuntime.StopReason.SERVICE_STOPPED)
            TurnRuntime.finish(TurnRuntime.StopReason.SERVICE_STOPPED)
            InterruptedTurnStore(this).noteInterruption(TurnRuntime.StopReason.SERVICE_STOPPED)
        }
        // The timeout notification is detached on purpose and must survive this
        // service instance; every other path owns a notification that must go.
        if (snapshot.stopReason != TurnRuntime.StopReason.SYSTEM_TIMEOUT) {
            TurnNotifications.cancelProgress(this)
        }
        super.onDestroy()
    }

    companion object {
        const val TAG = "PDSHTurnFgs"
        const val ACTION_STOP = "com.phonedsh.dsh.background.action.STOP_TURN_FGS"

        /**
         * Starts the fallback window. Returns false when the platform refused the
         * background start; callers should then report the turn as foreground-only
         * instead of assuming it proceeded.
         */
        fun start(context: Context, request: TurnRequest): Boolean = try {
            ContextCompat.startForegroundService(
                context,
                request.into(Intent(context, TurnForegroundService::class.java)),
            )
            true
        } catch (error: IllegalStateException) {
            Log.w(TAG, "background foreground-service start refused: ${error.javaClass.simpleName}")
            false
        } catch (error: SecurityException) {
            Log.w(TAG, "foreground-service start denied: ${error.message}")
            false
        }
    }
}
