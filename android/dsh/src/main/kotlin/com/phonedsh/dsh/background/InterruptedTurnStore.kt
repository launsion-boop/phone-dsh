// phone-dsh — :dsh / com.phonedsh.dsh.background: the durable turn marker.
// SPDX-License-Identifier: MIT
//
// Plan §7.4-2/§7.4-3 and whitelist `platform.bgtask-drain-window`: a dead process
// cannot notify anyone, so the durable record is written when the turn *starts*
// and only removed when the turn ends through an explicit path (completed, user
// stopped). If the process is killed, the marker survives and the WorkManager
// tombstone / boot receiver / next app open can report "the turn was interrupted
// at step N".
//
// Scope discipline: this is a *turn lifecycle marker*, not a WAL. It never stores
// payload bytes, never claims what the WAL contains, and is not a recovery
// source. :controller owns the WAL and decides what recovery means; this store
// only carries the last step the caller told us about.
//
// Storage: credential-encrypted app SharedPreferences (the same encryption domain
// as the WAL), so it is only readable after the user unlocks — which is why the
// boot path listens to BOOT_COMPLETED and not LOCKED_BOOT_COMPLETED (plan §7.10).

package com.phonedsh.dsh.background

import android.content.Context
import android.util.Log

class InterruptedTurnStore(context: Context) {
    private val prefs = context.applicationContext
        .getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)

    /** The durable record of a turn that started and has not closed explicitly. */
    data class InterruptedTurn(
        val epoch: Long,
        val step: Int,
        val totalSteps: Int,
        /**
         * `null` means the process died without any stop callback (Task Manager
         * Stop / OEM force-stop / LMK): the platform gave us no reason, and the
         * report must say exactly that instead of guessing.
         */
        val reason: TurnRuntime.StopReason?,
        val recordedAt: Long,
        val reported: Boolean,
    )

    /**
     * The "next open" report used when the notification link is degraded
     * (POST_NOTIFICATIONS denied): the user could not be told at the time, so the
     * interruption is handed to the next foregrounding UI instead of being lost.
     */
    data class PendingReport(
        val epoch: Long,
        val step: Int,
        val reason: TurnRuntime.StopReason?,
        val recordedAt: Long,
        val suppressedCount: Int,
    )

    /**
     * Writes the marker before the turn starts. Uses `commit()`: a process that
     * dies right after starting must still leave a tombstone behind. The write is
     * a few keys, not a WAL page.
     */
    fun begin(epoch: Long, step: Int, totalSteps: Int = 0, at: Long = now()): InterruptedTurn {
        val turn = InterruptedTurn(
            epoch = epoch,
            step = step,
            totalSteps = totalSteps,
            reason = null,
            recordedAt = at,
            reported = false,
        )
        synchronized(lock) {
            prefs.edit()
                .putBoolean(KEY_PRESENT, true)
                .putLong(KEY_EPOCH, turn.epoch)
                .putInt(KEY_STEP, turn.step)
                .putInt(KEY_TOTAL_STEPS, turn.totalSteps)
                .remove(KEY_REASON)
                .putLong(KEY_RECORDED_AT, turn.recordedAt)
                .putBoolean(KEY_REPORTED, false)
                .commit()
        }
        return turn
    }

    /**
     * Best-effort metadata update while a turn runs. `apply()` on purpose: a
     * progress tick must never block the service thread, and losing the tick only
     * costs report precision, never durability.
     */
    fun advance(step: Int, totalSteps: Int = 0) {
        synchronized(lock) {
            if (!prefs.getBoolean(KEY_PRESENT, false)) return
            prefs.edit()
                .putInt(KEY_STEP, step)
                .putInt(KEY_TOTAL_STEPS, totalSteps)
                .putLong(KEY_RECORDED_AT, now())
                .apply()
        }
    }

    /**
     * Records why the window ended while keeping the marker so the next process
     * can report it. `apply()` because the timeout path only has a few seconds and
     * the durable marker already exists from [begin]; the reason is metadata.
     */
    fun noteInterruption(
        reason: TurnRuntime.StopReason,
        at: Long = now(),
    ): InterruptedTurn? {
        synchronized(lock) {
            if (!prefs.getBoolean(KEY_PRESENT, false)) return null
            prefs.edit()
                .putString(KEY_REASON, reason.name)
                .putLong(KEY_RECORDED_AT, at)
                .putBoolean(KEY_REPORTED, false)
                .apply()
            return readLocked()
        }
    }

    /** The turn ended deliberately (completed or user stopped): no tombstone. */
    fun complete() {
        synchronized(lock) {
            prefs.edit()
                .remove(KEY_PRESENT)
                .remove(KEY_EPOCH)
                .remove(KEY_STEP)
                .remove(KEY_TOTAL_STEPS)
                .remove(KEY_REASON)
                .remove(KEY_RECORDED_AT)
                .remove(KEY_REPORTED)
                .apply()
        }
    }

    /**
     * The surviving marker, or `null` when the previous turn closed explicitly.
     * A marker whose [InterruptedTurn.reason] is `null` is the zero-callback case.
     */
    fun interrupted(): InterruptedTurn? = synchronized(lock) {
        if (!prefs.getBoolean(KEY_PRESENT, false)) null else readLocked()
    }

    fun markReported(at: Long = now()) {
        synchronized(lock) {
            if (!prefs.getBoolean(KEY_PRESENT, false)) return
            prefs.edit()
                .putBoolean(KEY_REPORTED, true)
                .putLong(KEY_RECORDED_AT, at)
                .apply()
        }
    }

    /**
     * Stores the interruption where the next foregrounding UI will read it
     * (notification link degraded). Only the latest report is kept; older ones
     * are counted, because silently dropping them would be the exact dishonest
     * degradation the whitelist forbids.
     */
    fun promotePendingReport(turn: InterruptedTurn) {
        synchronized(lock) {
            val sameEpoch = prefs.getBoolean(KEY_REPORT_PRESENT, false) &&
                prefs.getLong(KEY_REPORT_EPOCH, turn.epoch) == turn.epoch
            val suppressed = if (prefs.getBoolean(KEY_REPORT_PRESENT, false) && !sameEpoch) {
                prefs.getInt(KEY_REPORT_SUPPRESSED, 0) + 1
            } else {
                prefs.getInt(KEY_REPORT_SUPPRESSED, 0)
            }
            prefs.edit()
                .putBoolean(KEY_REPORT_PRESENT, true)
                .putLong(KEY_REPORT_EPOCH, turn.epoch)
                .putInt(KEY_REPORT_STEP, turn.step)
                .putLong(KEY_REPORT_AT, turn.recordedAt)
                .putInt(KEY_REPORT_SUPPRESSED, suppressed)
                .apply()
            turn.reason?.let { prefs.edit().putString(KEY_REPORT_REASON, it.name).apply() }
        }
    }

    fun pendingReport(): PendingReport? = synchronized(lock) {
        if (!prefs.getBoolean(KEY_REPORT_PRESENT, false)) return null
        PendingReport(
            epoch = prefs.getLong(KEY_REPORT_EPOCH, 0L),
            step = prefs.getInt(KEY_REPORT_STEP, 0),
            reason = prefs.getString(KEY_REPORT_REASON, null)?.toStopReason(),
            recordedAt = prefs.getLong(KEY_REPORT_AT, 0L),
            suppressedCount = prefs.getInt(KEY_REPORT_SUPPRESSED, 0),
        )
    }

    fun consumePendingReport(): PendingReport? {
        val report = pendingReport() ?: return null
        synchronized(lock) {
            prefs.edit()
                .remove(KEY_REPORT_PRESENT)
                .remove(KEY_REPORT_EPOCH)
                .remove(KEY_REPORT_STEP)
                .remove(KEY_REPORT_REASON)
                .remove(KEY_REPORT_AT)
                .remove(KEY_REPORT_SUPPRESSED)
                .apply()
        }
        return report
    }

    private fun readLocked(): InterruptedTurn = InterruptedTurn(
        epoch = prefs.getLong(KEY_EPOCH, TurnRuntime.UNKNOWN_EPOCH),
        step = prefs.getInt(KEY_STEP, 0),
        totalSteps = prefs.getInt(KEY_TOTAL_STEPS, 0),
        reason = prefs.getString(KEY_REASON, null)?.toStopReason(),
        recordedAt = prefs.getLong(KEY_RECORDED_AT, 0L),
        reported = prefs.getBoolean(KEY_REPORTED, false),
    )

    private fun String.toStopReason(): TurnRuntime.StopReason? = runCatching {
        TurnRuntime.StopReason.valueOf(this)
    }.onFailure {
        // A value written by a newer build must degrade to "unknown", not crash
        // the boot receiver or the tombstone worker.
        Log.w(TAG, "unknown stop reason persisted: $this")
    }.getOrNull()

    private fun now(): Long = System.currentTimeMillis()

    private companion object {
        const val TAG = "PDSHTurnStore"
        const val FILE_NAME = "pdsh_background_state"

        const val KEY_PRESENT = "turn.present"
        const val KEY_EPOCH = "turn.epoch"
        const val KEY_STEP = "turn.step"
        const val KEY_TOTAL_STEPS = "turn.total_steps"
        const val KEY_REASON = "turn.reason"
        const val KEY_RECORDED_AT = "turn.recorded_at"
        const val KEY_REPORTED = "turn.reported"

        const val KEY_REPORT_PRESENT = "report.present"
        const val KEY_REPORT_EPOCH = "report.epoch"
        const val KEY_REPORT_STEP = "report.step"
        const val KEY_REPORT_REASON = "report.reason"
        const val KEY_REPORT_AT = "report.at"
        const val KEY_REPORT_SUPPRESSED = "report.suppressed"

        val lock = Any()
    }
}
