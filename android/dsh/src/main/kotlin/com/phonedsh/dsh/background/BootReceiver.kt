// phone-dsh — :dsh / com.phonedsh.dsh.background: BOOT_COMPLETED guidance only.
// SPDX-License-Identifier: MIT
//
// Plan §7.4-3: Android 15 forbids starting a dataSync foreground service from
// BOOT_COMPLETED, and Android 12+ forbids background FGS starts in general, so a
// post-reboot "resume" is not a thing this app may claim. The receiver therefore
// does exactly one thing: read the durable marker and guide the user to open the
// app. No foreground service, no job scheduling, no WAL scan, no resume.
//
// The marker lives in credential-encrypted storage, so the receiver listens to
// BOOT_COMPLETED (delivered after the user unlocks) and not LOCKED_BOOT_COMPLETED
// (plan §7.10-B10④).
//
// `android:exported="false"` in the manifest: BOOT_COMPLETED is a protected
// broadcast that only the system can send, and WorkManager's own boot receiver is
// declared the same way.

package com.phonedsh.dsh.background

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return
        Log.i(
            TAG,
            "BOOT_COMPLETED received: package=${intent.`package`} " +
                "component=${intent.component} extras=${intent.extras?.keySet()} " +
                "flags=0x${intent.flags.toString(16)}",
        )
        // Measured on API 35: WorkManager 2.10's ForceStopRunnable re-broadcasts
        // ACTION_BOOT_COMPLETED scoped to our own package after recovering from a
        // force-stop. That is not a reboot, and saying "设备已重启" would be false.
        // The system's real BOOT_COMPLETED is implicit (package == null).
        if (intent.`package` == context.packageName) {
            Log.i(TAG, "ignoring package-scoped BOOT_COMPLETED (force-stop reschedule, not a boot)")
            return
        }
        TurnNotifications.ensureChannels(context)
        val store = InterruptedTurnStore(context)
        val turn = store.interrupted() ?: return
        if (turn.reported) return
        if (TurnRuntime.snapshot().isRunning) return
        if (NotificationCapability.probe(context).progressVisible) {
            if (TurnNotifications.postBootGuide(context, turn)) {
                store.markReported()
                Log.i(TAG, "boot guidance posted for epoch ${turn.epoch}")
            }
        } else {
            store.promotePendingReport(turn)
            Log.i(TAG, "notifications unavailable at boot; interruption queued for next open")
        }
        // Deliberately nothing else here. Later ActivityManager policy changes must
        // not tempt this receiver into starting the turn: the plan's row
        // "重启后: 不自动续跑" is the promise, and this is where it is kept.
    }

    private companion object {
        const val TAG = "PDSHBoot"
    }
}
