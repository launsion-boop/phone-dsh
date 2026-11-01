// phone-dsh — :dsh / com.phonedsh.dsh.background: the WorkManager tombstone.
// SPDX-License-Identifier: MIT
//
// Plan §7.4-2: a dead process cannot post a notification, so a persistent
// WorkManager task survives the death, gets the process back up, checks the
// durable turn marker, and *only* notifies the user. It never resumes the turn:
// resuming is a user decision made in the app (plan §7.9 row "进程被杀").
//
// Plan §7.10-B10④: WorkManager's practical minimum is ~15 minutes and OEMs may
// defer it until the next app open, so this is deliberately best effort; the
// primary path is the next-open banner reading the same marker. The delay is
// measured, not promised.

package com.phonedsh.dsh.background

import android.content.Context
import android.util.Log
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

object TombstoneScheduler {
    const val UNIQUE_WORK_NAME = "pdsh.turn.tombstone"
    const val WORK_TAG = "pdsh-tombstone"

    /**
     * 15 minutes: WorkManager's own minimum cadence for deferrable work. Enqueued
     * when the turn starts; if the turn finishes first, [cancel] removes it.
     */
    const val DEFAULT_DELAY_MS: Long = 15L * 60L * 1000L

    private const val TAG = "PDSHTombstone"

    /** Enqueues the single persistent tombstone check. Returns false if WorkManager is unavailable. */
    fun enqueue(context: Context, delayMs: Long = DEFAULT_DELAY_MS): Boolean {
        val request = OneTimeWorkRequest.Builder(TombstoneWorker::class.java)
            .setInitialDelay(delayMs.coerceAtLeast(0L), TimeUnit.MILLISECONDS)
            .addTag(WORK_TAG)
            .build()
        return try {
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
                UNIQUE_WORK_NAME,
                ExistingWorkPolicy.REPLACE,
                request,
            )
            true
        } catch (error: IllegalStateException) {
            // A consumer stripped the androidx.startup provider. The marker still
            // reaches the user on the next open; the notification is best effort.
            Log.w(TAG, "WorkManager unavailable: ${error.message}")
            false
        }
    }

    fun cancel(context: Context) {
        runCatching {
            WorkManager.getInstance(context.applicationContext)
                .cancelUniqueWork(UNIQUE_WORK_NAME)
        }.onFailure { Log.w(TAG, "cancel failed: ${it.message}") }
    }
}
