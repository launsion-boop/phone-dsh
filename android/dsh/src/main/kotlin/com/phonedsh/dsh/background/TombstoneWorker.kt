// phone-dsh — :dsh / com.phonedsh.dsh.background: tombstone check worker.
// SPDX-License-Identifier: MIT
//
// What this worker may do (plan §7.4-3): read the durable marker, post one
// guidance notification, and return. What it must not do: start a foreground
// service, schedule the turn again, touch the WAL, or "recover" anything. The
// notice says the turn will not resume automatically because that is true.

package com.phonedsh.dsh.background

import android.content.Context
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters

class TombstoneWorker(
    appContext: Context,
    params: WorkerParameters,
) : Worker(appContext, params) {
    override fun doWork(): Result {
        val store = InterruptedTurnStore(applicationContext)
        val turn = store.interrupted() ?: return Result.success()

        // A live in-process turn wrote this marker; it is not an interruption yet.
        // This check consumes this one tombstone: if that long turn dies later, the
        // next-open banner (the primary path, plan §7.10-B10④) still reports it.
        if (TurnRuntime.snapshot().isRunning) {
            Log.i(TAG, "turn is live in this process; tombstone stays quiet")
            return Result.success()
        }
        if (turn.reported) return Result.success()

        val capability = NotificationCapability.probe(applicationContext)
        if (!capability.progressVisible) {
            // The notification link is degraded: hand the report to the next
            // foregrounding UI instead of dropping it.
            store.promotePendingReport(turn)
            Log.i(TAG, "notifications unavailable; interruption queued for next open")
            return Result.success()
        }
        return if (TurnNotifications.postTombstone(applicationContext, turn)) {
            store.markReported()
            Log.i(TAG, "tombstone notification posted for epoch ${turn.epoch}")
            Result.success()
        } else {
            // Posting failed (permission revoked mid-flight): retry with backoff
            // rather than claim the user was told.
            Result.retry()
        }
    }

    private companion object {
        const val TAG = "PDSHTombstoneWorker"
    }
}
