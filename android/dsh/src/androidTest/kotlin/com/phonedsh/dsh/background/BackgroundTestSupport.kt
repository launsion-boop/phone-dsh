// phone-dsh — :dsh / androidTest: helpers for the background lane's device probes.
// SPDX-License-Identifier: MIT
//
// These tests are instrumented on purpose: a notification that was never posted to
// a real NotificationManager, a JobInfo that was never accepted by a real
// JobScheduler, and a WorkInfo that only exists in a test fake would prove nothing
// about the platform contracts this lane implements.

package com.phonedsh.dsh.background

import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry

internal const val AWAIT_TIMEOUT_MS: Long = 15_000L

internal fun grantNotificationPermission(context: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
    InstrumentationRegistry.getInstrumentation().uiAutomation
        .grantRuntimePermission(context.packageName, NotificationCapability.POST_NOTIFICATIONS)
}

internal fun await(
    description: String,
    timeoutMs: Long = AWAIT_TIMEOUT_MS,
    pollMs: Long = 50L,
    condition: () -> Boolean,
) {
    val deadline = SystemClock.uptimeMillis() + timeoutMs
    while (SystemClock.uptimeMillis() < deadline) {
        if (condition()) return
        SystemClock.sleep(pollMs)
    }
    if (!condition()) {
        throw AssertionError("timed out after ${timeoutMs}ms waiting for: $description")
    }
}

internal fun NotificationManager.activeById(id: Int) =
    activeNotifications.firstOrNull { it.id == id }

internal fun NotificationManager.textOf(id: Int): String =
    activeById(id)?.notification?.extras
        ?.getCharSequence("android.text")
        ?.toString()
        .orEmpty()

/**
 * Puts the process in the state a real turn starts from: everything closed, no
 * leftover marker, no leftover unique work, no leftover notification.
 */
internal fun resetBackgroundState(context: Context) {
    TurnBackground.stop(context, TurnRuntime.StopReason.USER_STOPPED)
    TombstoneScheduler.cancel(context)
    InterruptedTurnStore(context).complete()
    context.getSystemService(NotificationManager::class.java)?.cancelAll()
}

/**
 * Android 12+ refuses foreground-service starts from the background, and UIDT may
 * only be scheduled while the app is visible. The real caller is a visible app, so
 * the probe makes the test APK visible with a no-op activity instead of pretending
 * the restriction does not exist.
 */
internal fun launchVisibleTestApp(): ActivityScenario<BackgroundTestActivity> {
    val scenario = ActivityScenario.launch(BackgroundTestActivity::class.java)
    InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    return scenario
}
