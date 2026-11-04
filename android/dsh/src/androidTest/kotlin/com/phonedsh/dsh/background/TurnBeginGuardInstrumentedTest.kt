// phone-dsh — :dsh / androidTest: the late component start cannot revive a stop.
// SPDX-License-Identifier: MIT
//
// L60 #7, on the real platform components. The audit's interleaving is:
//
//   controller coroutine:  TurnBackground.stop() -> closeWindow()      -> STOPPED
//   main-thread queue:     onStartJob/onStartCommand (already posted)  -> RUNNING
//
// The foreground test reproduces the *real* late start deterministically:
// `TurnForegroundService` is already running (so the platform has a live service
// to deliver to), the app's main thread is then held, a second start for the same
// epoch is queued behind it, the user's stop closes the window, and only then is
// the queue released. Before the fix the queued `onStartCommand` called `begin()`
// unconditionally and wrote `RUNNING` — the ghost window. Now it must find
// `STOPPED` and `stopSelf(startId)` without promoting, binding or writing a marker.
//
// The UIDT test proves the same seam with the real `JobScheduler`: a job accepted
// and then stopped has a `STOPPED` epoch, and `begin()` (the first statement of a
// late `onStartJob`) answers `Refused` and changes nothing.

package com.phonedsh.dsh.background

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TurnBeginGuardInstrumentedTest {
    private lateinit var context: Context
    private var scenario: ActivityScenario<BackgroundTestActivity>? = null

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        resetBackgroundState(context)
        grantNotificationPermission(context)
        TurnNotifications.ensureChannels(context)
        scenario = launchVisibleTestApp()
        await("notification capability visible") {
            TurnBackground.capability(context).progressVisible
        }
    }

    @After
    fun tearDown() {
        TurnRuntime.resetForTest()
        context.getSystemService(android.app.job.JobScheduler::class.java)
            ?.cancel(TurnJobScheduler.JOB_ID)
        scenario?.close()
        TurnBackground.stop(context, TurnRuntime.StopReason.USER_STOPPED)
        InterruptedTurnStore(context).complete()
        TombstoneScheduler.cancel(context)
    }

    @Test
    fun aLateForegroundStartAfterTheUserStopIsStoppedNotRun() {
        val request = TurnRequest(epoch = 602L, step = 1, totalSteps = 3)
        assertTrue("the foreground window must open", TurnForegroundService.start(context, request))
        await("the foreground window is running") {
            val snapshot = TurnRuntime.snapshot()
            snapshot.isRunning &&
                snapshot.backend == TurnRuntime.Backend.FOREGROUND_SERVICE &&
                snapshot.epoch == 602L
        }

        // Hold the main thread: the platform's `onStartCommand` is delivered
        // there, so the second start below can be queued but not executed.
        val mainBlocked = CountDownLatch(1)
        val releaseMain = CountDownLatch(1)
        Handler(Looper.getMainLooper()).post {
            mainBlocked.countDown()
            releaseMain.await(30, TimeUnit.SECONDS)
        }
        assertTrue(
            "the test must hold the main thread before queueing the late start",
            mainBlocked.await(5, TimeUnit.SECONDS),
        )
        try {
            // The late start: same service, same epoch, accepted by the platform
            // and queued behind the blocked main thread.
            context.startService(request.into(Intent(context, TurnForegroundService::class.java)))
            SystemClock.sleep(500L)

            // The controller's stop runs here, on the instrumentation thread.
            assertTrue(
                "the user's stop must close the running window",
                TurnBackground.stop(context, TurnRuntime.StopReason.USER_STOPPED),
            )
            assertEquals(TurnRuntime.Phase.STOPPED, TurnRuntime.snapshot().phase)
            assertFalse(TurnRuntime.snapshot().admissionOpen)
        } finally {
            releaseMain.countDown()
        }

        // The queued onStartCommand runs now. Before the fix this was RUNNING.
        SystemClock.sleep(1_500L)
        val after = TurnRuntime.snapshot()
        assertEquals(
            "a start queued before the stop must not revive the turn",
            TurnRuntime.Phase.STOPPED,
            after.phase,
        )
        assertFalse("a ghost window would have opened admission", after.admissionOpen)
        assertFalse("no stop may be re-armed after the user ended the turn", after.retriable)
    }

    @Test
    fun aStoppedUidtEpochIsRefusedAtTheRuntimeSeam() {
        assumeTrue(
            "UIDT needs API ${TurnChannel.USER_INITIATED_JOB_MIN_SDK}+; this image is " +
                "API ${Build.VERSION.SDK_INT}",
            Build.VERSION.SDK_INT >= TurnChannel.USER_INITIATED_JOB_MIN_SDK,
        )
        val request = TurnRequest(epoch = 601L, step = 2, totalSteps = 5)
        val scheduled = TurnJobScheduler(context).schedule(request, appVisible = true)
        assertEquals(
            "the real JobScheduler must accept the window",
            TurnStartResult.UserInitiatedJobScheduled(TurnJobScheduler.JOB_ID),
            scheduled,
        )
        assertEquals(TurnRuntime.Phase.SCHEDULED, TurnRuntime.snapshot().phase)

        assertTrue(
            "the user's stop must close the queued window",
            TurnBackground.stop(context, TurnRuntime.StopReason.USER_STOPPED),
        )
        assertEquals(TurnRuntime.Phase.STOPPED, TurnRuntime.snapshot().phase)

        // The first statement of a late `onStartJob`, with the request the job
        // carries in its extras.
        val refused = TurnRuntime.begin(TurnRuntime.Backend.USER_INITIATED_JOB, request)
        assertTrue("the runtime must refuse the stopped epoch: $refused", refused is TurnRuntime.BeginResult.Refused)
        assertEquals(TurnRuntime.Phase.STOPPED, TurnRuntime.snapshot().phase)
        assertFalse(TurnRuntime.snapshot().admissionOpen)
        assertNull("a refused start must not bind the job", TurnRuntime.jobBinding())
    }
}
