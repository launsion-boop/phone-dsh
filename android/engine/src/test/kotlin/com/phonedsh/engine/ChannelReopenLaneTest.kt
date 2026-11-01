// phone-dsh — :engine unit test: the ordered channel's exit after a loss (P22).
// SPDX-License-Identifier: MIT
//
// What this file has to prove, and why each assertion exists:
//   * a closed ordered channel is reopened by the engine (the defect: nothing did);
//   * the reopen is a reload *with backoff*, not a spin — the first 30 s hold a
//     bounded number of reloads;
//   * the page's own client gets the first window to reconnect by itself, so a
//     momentary loss costs no reload at all;
//   * no page is reloaded into a host whose admission is closed (that is how a
//     fresh worker's mseq would diverge from the WAL again);
//   * a teardown (stop/Failed) ends the episode instead of fighting it;
//   * a channel that dies again 5 s later keeps the escalated delay.
//
// The clock and the delay are injected, so every case runs on the plain JVM with
// no coroutines-test dependency and no wall-clock wait. The `delayMillis` hook is
// also where each test ends the episode: the lane retries forever by design, so a
// test that never lets it out would not terminate.

package com.phonedsh.engine

import com.phonedsh.loopback.ChannelCloseCause
import com.phonedsh.platform.EngineHostState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChannelReopenLaneTest {
    private val logger = RecordingEngineLogger()
    // Unconfined: `onChannelLost` runs the whole episode on this thread, and the
    // injected `delayMillis` never actually suspends, so the assertions below need
    // no waiting and no test dispatcher.
    private val scope = CoroutineScope(Job() + Dispatchers.Unconfined)

    /** Recorded reload attempts, 1-based as the lane reports them. */
    private val reloads = mutableListOf<Int>()

    /** Every delay the lane asked for, in call order: the storm evidence. */
    private val delays = mutableListOf<Long>()

    private var state: EngineState = RUNNING

    /** D14's admission, as the composition root supplies it. */
    private var hostWrites = true

    private var nowMillis = 1_000L

    /** The reload count whose channel opens; `null` never opens one. */
    private var openOnReload: Int? = 1

    /** The delay count whose channel opens by itself (before any reload). */
    private var reconnectOnDelay: Int? = null

    /** The delay count at which the engine is torn down (a `stop()` mid-window). */
    private var stopOnDelay: Int? = null

    /** The reload count after which the engine is `Stopped` (a page that never recovers). */
    private var abandonAfterReloads: Int? = null

    /** Admission polls that must fail before the host accepts writes. */
    private var admissionClosedPolls = 0

    /** Episodes that asked the engine to take `Running -> Recovering`. */
    private var episodeStarts = 0

    /** Worker restarts the lane escalated to. */
    private var restarts = 0

    /** Whether the origin answered 409 to the reloaded page's upgrade. */
    private var originStuck = false

    private lateinit var lane: ChannelReopenLane

    /** The delays that were backoff windows, i.e. everything but the 250 ms open polls. */
    private val backoffDelays: List<Long>
        get() = delays.filter { it != ChannelReopenLane.OPEN_POLL_MILLIS }

    private fun newLane(): ChannelReopenLane {
        lateinit var created: ChannelReopenLane
        var polls = 0
        created = ChannelReopenLane(
            scope = scope,
            logger = logger,
            policy = ReopenPolicy.DEFAULT,
            reload = { attempt ->
                reloads += attempt
                if (openOnReload == reloads.size) created.onChannelOpened()
                if (abandonAfterReloads == reloads.size) state = EngineHostState.Stopped
            },
            engineState = { state },
            onEpisodeStart = { episodeStarts += 1 },
            originRefusedUpgrades = { originStuck },
            restartWorker = {
                restarts += 1
                state = RUNNING
                true
            },
            hostAcceptsWrites = {
                polls += 1
                if (polls <= admissionClosedPolls) false else hostWrites
            },
            openTimeoutMillis = 1_000L,
            stableMillis = 20_000L,
            admissionPollMillis = 2_000L,
            delayMillis = { millis ->
                delays += millis
                nowMillis += millis
                if (reconnectOnDelay == delays.size) created.onChannelOpened()
                if (stopOnDelay == delays.size) state = EngineHostState.Stopped
                // The lane retries forever by design; a test that never lets it out
                // would not terminate, so this is the backstop, not an assertion.
                if (delays.size >= 400) state = EngineHostState.Stopped
            },
            clock = { nowMillis },
        )
        lane = created
        return created
    }

    // ---- 1. the defect: nothing reopened the channel --------------------------

    @Test
    fun aLostChannelIsReopenedByReloadingThePage() {
        newLane().onChannelLost(ChannelCloseCause.CLIENT_CLOSED.name)

        assertEquals("exactly one reload reaches the channel", listOf(1), reloads)
        assertEquals("the engine takes Running -> Recovering once, at the loss", 1, episodeStarts)
        assertEquals("the first window is the policy's first delay", 4_000L, delays.first())
        assertTrue(
            "the loss names the cause",
            logger.contains("ordered channel lost (cause=CLIENT_CLOSED)"),
        )
        assertTrue(
            "the attempt is logged with its backoff",
            logger.contains("channel reopen: attempt 1 in 4000 ms"),
        )
        assertTrue(logger.contains("channel reopen: reloading the page (attempt 1)"))
        assertTrue(
            logger.contains("channel reopen: the ordered channel is back after 1 reload attempt(s)"),
        )
    }

    // ---- 2. the page's own client gets the first window ----------------------

    @Test
    fun thePageGetsTheFirstWindowToReconnectOnItsOwn() {
        reconnectOnDelay = 1
        newLane().onChannelLost(ChannelCloseCause.TRANSPORT_LOST.name)

        assertTrue("a self-reconnect must cost no reload", reloads.isEmpty())
        assertTrue(logger.contains("the page reopened the ordered channel on its own"))
    }

    // ---- 3. no storm: doubling backoff --------------------------------------

    @Test
    fun aPageThatNeverReconnectsIsRetriedWithADoublingDelay() {
        openOnReload = null
        abandonAfterReloads = 3
        newLane().onChannelLost(ChannelCloseCause.CLIENT_CLOSED.name)

        assertEquals("one reload per attempt", listOf(1, 2, 3), reloads)
        assertEquals("doubling backoff, not a spin", listOf(4_000L, 8_000L, 15_000L), backoffDelays)
        assertTrue(logger.contains("attempt 1 did not bring the channel back"))
        assertTrue(logger.contains("attempt 2 did not bring the channel back"))
        assertTrue(
            "the attempt number grows across the episode",
            logger.contains("channel reopen: attempt 3 in 15000 ms"),
        )
    }

    // ---- 4. no reload into a host that would refuse it ----------------------

    @Test
    fun noPageIsReloadedWhileTheHostRefusesWrites() {
        admissionClosedPolls = 4 // the first four admission reads say "closed"
        newLane().onChannelLost(ChannelCloseCause.CLIENT_CLOSED.name)

        assertTrue(
            "the wait is logged once, not per poll",
            logger.contains("waiting for the host to accept writes (D14 admission is closed)"),
        )
        assertTrue(
            "the reload happens only after admission reopened",
            logger.contains("the host accepts writes again; reloading now"),
        )
        assertEquals("one reload after the wait", 1, reloads.size)
        assertEquals("the backoff window is the first delay", 4_000L, delays.first())
        assertTrue(
            "every wait after it is one admission poll",
            delays.drop(1).all { it == 2_000L },
        )
    }

    // ---- 4b. a stale origin slot escalates to a worker restart --------------

    @Test
    fun aReloadThatCannotGetAChannelEscalatesToAWorkerRestart() {
        // Measured 2026-11-01: the origin still holds the dead channel, so the
        // reloaded page's upgrade gets 409 on every attempt. Another reload cannot
        // clear that; only stopping the origin can.
        openOnReload = null
        originStuck = true
        newLane().onChannelLost(ChannelCloseCause.CLIENT_CLOSED.name)

        assertEquals("one reload is tried first", 1, reloads.size)
        assertEquals("then the worker is restarted once", 1, restarts)
        assertTrue(
            logger.contains("escalating to a full worker restart (RESTART_WORKER)"),
        )
        assertTrue(logger.contains("the worker was restarted"))
    }

    @Test
    fun aPageThatFailsForAnotherReasonKeepsReloadingInstead() {
        openOnReload = null
        originStuck = false
        abandonAfterReloads = 2
        newLane().onChannelLost(ChannelCloseCause.CLIENT_CLOSED.name)

        assertEquals("no restart without a refused upgrade", 0, restarts)
        assertEquals(listOf(1, 2), reloads)
    }

    // ---- 5. a teardown wins -------------------------------------------------

    @Test
    fun aCloseOutsideRunningIsNotAPageIncident() {
        state = EngineHostState.Stopped
        newLane().onChannelLost(ChannelCloseCause.CLIENT_CLOSED.name)

        assertTrue(reloads.isEmpty())
        assertTrue(delays.isEmpty())
        assertEquals("no D14/engine transition for a teardown", 0, episodeStarts)
        assertTrue(logger.contains("not a page incident, no reopen"))
    }

    @Test
    fun aStopDuringTheBackoffWindowCancelsTheReload() {
        stopOnDelay = 1
        newLane().onChannelLost(ChannelCloseCause.CLIENT_CLOSED.name)

        assertTrue("the stop won before the window ended", reloads.isEmpty())
        assertTrue(logger.contains("abandoned while Stopped"))
    }

    // ---- 6. a flapping channel keeps its escalated delay --------------------

    @Test
    fun aChannelThatDiesAgainQuicklyKeepsEscalating() {
        val lane = newLane()

        lane.onChannelLost(ChannelCloseCause.CLIENT_CLOSED.name)
        assertEquals(listOf(4_000L), backoffDelays)

        // Second incident 5 s later: the channel never stayed up for the 20 s
        // stability window, so the next delay doubles instead of starting over.
        nowMillis += 5_000L
        delays.clear()
        reloads.clear()
        lane.onChannelLost(ChannelCloseCause.CLIENT_CLOSED.name)

        assertEquals("escalation survives a flapping channel", listOf(8_000L), backoffDelays)
        assertTrue(logger.contains("escalating: the last channel did not stay up for 20000 ms"))
    }

    @Test
    fun aChannelThatStayedUpStartsOverAtTheFirstDelay() {
        val lane = newLane()

        lane.onChannelLost(ChannelCloseCause.CLIENT_CLOSED.name)
        assertEquals(listOf(4_000L), backoffDelays)

        // 25 s of a healthy channel > the 20 s stability window: a new incident is a
        // new incident.
        nowMillis += 25_000L
        delays.clear()
        reloads.clear()
        lane.onChannelLost(ChannelCloseCause.CLIENT_CLOSED.name)

        assertEquals(listOf(4_000L), backoffDelays)
        assertFalse(logger.contains("escalating: the last channel"))
    }

    // ---- 6b. the stale-channel rule ----------------------------------------

    @Test
    fun aRefusedUpgradeWhileConnectedMeansTheChannelIsStale() {
        assertTrue(
            "connected + a refused upgrade = the page retried, so its socket died",
            StaleChannelRule.isStale(connected = true, rejected = 2, seenRejected = 0, accepted = 2),
        )
        assertFalse(
            "no growth is a healthy channel",
            StaleChannelRule.isStale(connected = true, rejected = 2, seenRejected = 2, accepted = 2),
        )
        assertFalse(
            "an engine that already knows it is disconnected is not a zombie",
            StaleChannelRule.isStale(connected = false, rejected = 9, seenRejected = 0, accepted = 2),
        )
        assertFalse(
            "no accepted channel at all means the page never connected",
            StaleChannelRule.isStale(connected = true, rejected = 1, seenRejected = 0, accepted = 0),
        )
    }

    // ---- 7. the schedule itself --------------------------------------------

    @Test
    fun theBackoffIsBoundedOverTheFirstThirtySeconds() {
        val policy = ReopenPolicy.DEFAULT

        assertEquals(4_000L, policy.delayFor(1))
        assertEquals(8_000L, policy.delayFor(2))
        assertEquals(15_000L, policy.delayFor(3))
        assertEquals(15_000L, policy.delayFor(4))
        assertEquals(15_000L, policy.delayFor(5))
        assertEquals("the delay is capped, it never doubles past the cap", 15_000L, policy.delayFor(40))

        val attempts = policy.attemptsWithin(30_000L)
        assertTrue("the first 30 s hold $attempts reloads; a storm would be dozens", attempts in 2..4)
        for (attempt in 1..20) {
            assertTrue(
                "no window of the schedule is shorter than the first delay",
                policy.delayFor(attempt) >= policy.firstDelayMillis,
            )
        }
    }

    @Test
    fun aFailedEngineIsNeverReloaded() {
        state = EngineHostState.Failed("the worker handshake was refused")
        newLane().onChannelLost(ChannelCloseCause.CLIENT_CLOSED.name)

        assertTrue("a terminal engine has no page to reload", reloads.isEmpty())
        assertTrue(delays.isEmpty())
        assertEquals("a Failed engine is not moved back through Recovering", 0, episodeStarts)
        assertTrue(logger.contains("not a page incident, no reopen"))
    }

    private companion object {
        val RUNNING = EngineHostState.Running("http://127.0.0.1:40000", 40000)
    }
}
