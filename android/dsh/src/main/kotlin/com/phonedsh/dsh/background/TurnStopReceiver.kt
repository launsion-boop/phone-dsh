// phone-dsh — :dsh / com.phonedsh.dsh.background: the notification stop action.
// SPDX-License-Identifier: MIT
//
// One PendingIntent for both channels (foreground service and UIDT): the action
// means "the user asked this turn to stop", not "call this specific component".
// TurnBackground.stop() then closes admission, ends whichever backend owns the
// window, and removes the durable marker (a user stop is not an interruption to
// report later).
//
// This is the graceful stop path the whitelist `platform.fgs-turn-notification`
// requires; the Task Manager's Stop has no callback at all, which is exactly why
// the notification must carry this button.

package com.phonedsh.dsh.background

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class TurnStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != TurnNotifications.ACTION_STOP_TURN) return
        val stopped = TurnBackground.stop(context, TurnRuntime.StopReason.USER_STOPPED)
        Log.i(TAG, "stop action received; running window existed=$stopped")
    }

    private companion object {
        const val TAG = "PDSHTurnStop"
    }
}
