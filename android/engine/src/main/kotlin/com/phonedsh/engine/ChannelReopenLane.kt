// phone-dsh — :engine / com.phonedsh.engine: the ordered channel's way back.
// SPDX-License-Identifier: MIT
//
// ---- the defect this file removes ------------------------------------------
// A WebView flap (WiFi -> cellular, a lift, the underground) kills the page's one
// WebSocket. The origin reports the close, the engine logs `channel channel-1:
// closed cause=...`, the screen says 「未连接」 — and *nothing reopens it*: the
// page's own client gives up on a protocol error (it never retries after
// `BAD_MSEQ`/`RING_TIMEOUT`), the host has no reconnect loop, and the only state
// machine that could rebuild the page (`Running -> Recovering -> Running`) is
// wired to renderer death alone. The App then answers `no_channel` /
// `api_aborted` for the rest of the process (measured 2026-11-01, P22).
//
// So this lane is the missing exit: a channel close while the engine is `Running`
// is an episode of page reloads with exponential backoff, and the engine goes
// `Recovering` for its duration. It reuses the existing edges — the same
// `markRecovering`/`markRunning` pair the renderer path uses — instead of adding
// a new state.
//
// ---- why a page reload, and not a socket retry ------------------------------
// The WebSocket is created by page script; the host cannot dial it. The worker
// bundle's client *does* retry a transport loss on its own (`backoffMinMs` 100 ms,
// cap 5 s), which is why a plain momentary loss needs no reload at all: the first
// backoff window below is also the grace period in which that self-reconnect can
// win. A *fatal* client error (a protocol error such as `BAD_MSEQ`, or the 30 s
// ring timeout) sets the client's `fatalError` and stops its retry loop for good;
// the only thing that can hand the page a fresh client is a fresh page.
//
// ---- why the reload waits for the host ------------------------------------
// A reloaded page gets a new worker, which sends its first `VFS_MUT` at the mseq
// the host HELLO names. That is only a repair if the host is willing to accept
// writes: while D14 admission is closed (`Backoff`, `Draining`, `Parked`,
// `Recovering`) the sink refuses every mutation and answers `VFS_RESYNC`, and the
// bundled worker does not act on that frame — it keeps allocating mseqs the host
// never accepts, so the *next* mutation after the reopen is out of order and the
// channel dies again. Reloading into that state would therefore loop. The lane
// asks [hostAcceptsWrites] first and waits instead: no page is reloaded while the
// host would refuse its writes.

package com.phonedsh.engine

import com.phonedsh.platform.EngineHostState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The backoff of the page reloads that try to bring the ordered channel back.
 *
 * Doubling from [firstDelayMillis] to [maxDelayMillis]: `4000, 8000, 15000,
 * 15000, ...`. [attemptsWithin] is the bound that makes "no storm" a number
 * instead of a claim (`4+8+15 = 27 s` → three reloads in the first 30 s), and the
 * delay never shrinks again while losses keep coming faster than the channel
 * stays up.
 *
 * The first window is deliberately longer than any other: it is also the grace
 * period in which the page's own client may reconnect, and a reload that fires
 * before that races a healthy page. Measured 2026-11-01: the worker closes its
 * ordered channel when its tree activates on the first `/api` request and opens a
 * new one **1.2 s later**; a 1 s window turned that self-heal into a reload that
 * killed the turn in flight. `4 s` is above that measurement and below the 5 s cap
 * of the worker's own reconnect backoff.
 */
class ReopenPolicy(
    val firstDelayMillis: Long = DEFAULT_FIRST_DELAY_MILLIS,
    val maxDelayMillis: Long = DEFAULT_MAX_DELAY_MILLIS,
) {
    init {
        require(firstDelayMillis > 0) { "the first reopen delay must be positive, was $firstDelayMillis" }
        require(maxDelayMillis >= firstDelayMillis) {
            "the reopen delay cap must not be below the first delay, was $maxDelayMillis"
        }
    }

    /** The delay before reload attempt [attempt] (1-based). */
    fun delayFor(attempt: Int): Long {
        require(attempt >= 1) { "attempt is 1-based, was $attempt" }
        var delay = firstDelayMillis
        repeat(attempt - 1) { delay = minOf(delay * 2, maxDelayMillis) }
        return delay
    }

    /**
     * How many reload attempts fit in [windowMillis], i.e. how many backoff
     * windows start inside it. The counting stops at 64 attempts, which no
     * realistic window reaches.
     */
    fun attemptsWithin(windowMillis: Long): Int {
        var spent = 0L
        var attempts = 0
        while (attempts < 64) {
            val next = spent + delayFor(attempts + 1)
            if (next > windowMillis) return attempts
            spent = next
            attempts += 1
        }
        return attempts
    }

    companion object {
        /**
         * Four seconds: above the 1.2 s the packaged worker needs to reopen its
         * channel after a lazy activation (measured), and below the 5 s cap of its
         * own reconnect backoff.
         */
        const val DEFAULT_FIRST_DELAY_MILLIS: Long = 4_000L

        /** Fifteen seconds: a bounded retry floor that still heals unattended. */
        const val DEFAULT_MAX_DELAY_MILLIS: Long = 15_000L

        val DEFAULT = ReopenPolicy()
    }
}

/**
 * The owner of "the ordered channel closed while the page is up; get one back".
 *
 * One episode at a time. Each attempt waits its backoff window (the page's own
 * client may still reconnect, which ends the episode), waits until the host
 * accepts writes, reloads the page through [reload], and then polls for the
 * channel for [openTimeoutMillis]. Success ends the episode; failure schedules
 * the next attempt from the same backoff, so a page that cannot hold the channel
 * is retried at a decreasing rate instead of in a loop.
 *
 * The counter of attempts survives an episode until the channel has stayed up
 * for [stableMillis]: a channel that dies again 200 ms after it opened is a
 * flapping page, not a fresh incident, and it must not reset the backoff.
 *
 * @param onEpisodeStart called once, when an episode is about to start: the
 *   engine takes `Running -> Recovering` there, which is the one existing edge
 *   the contract already has for "the worker is gone, rebuild it" (budgets.md §2
 *   `Running -> Recovering`, actions `RESTART_WORKER`/`VERIFY_LEASE`). It is a
 *   callback rather than an engine reference so the ordering is asserted by this
 *   class's own test.
 * @param reload replaces the page; the engine marshals this onto the UI thread and
 *   is the only implementation.
 * @param engineState the lifecycle the episode is allowed to run in
 *   (`Running`/`Recovering`); leaving it (a `stop()`, a `Failed`) ends the episode.
 * @param hostAcceptsWrites D14's admission, read through a lambda because the
 *   engine has no controller; `true` keeps the pre-P22 behaviour (reload at once).
 * @param delayMillis the one timing seam: production is [delay], tests replace it.
 * @param clock monotonic-free wall reading, used only for the stability comparison.
 */
class ChannelReopenLane(
    private val scope: CoroutineScope,
    private val logger: EngineLogger,
    private val reload: suspend (attempt: Int) -> Unit,
    private val engineState: () -> EngineState,
    private val onEpisodeStart: () -> Unit = {},
    /**
     * Whether the origin refused a channel upgrade since the episode began (a
     * stale single-channel slot). Consulted only after a reload failed.
     */
    private val originRefusedUpgrades: () -> Boolean = { false },
    /**
     * The last resort of an episode: stop and start the worker. Returns `true`
     * when a fresh worker is running (the episode is then over; the new channel
     * reports itself through [onChannelOpened]).
     */
    private val restartWorker: (suspend () -> Boolean)? = null,
    private val policy: ReopenPolicy = ReopenPolicy.DEFAULT,
    private val hostAcceptsWrites: () -> Boolean = { true },
    private val openTimeoutMillis: Long = DEFAULT_OPEN_TIMEOUT_MILLIS,
    private val stableMillis: Long = DEFAULT_STABLE_MILLIS,
    private val admissionPollMillis: Long = DEFAULT_ADMISSION_POLL_MILLIS,
    private val delayMillis: suspend (Long) -> Unit = { delay(it) },
    private val clock: () -> Long = { System.currentTimeMillis() },
) {
    private val lock = Any()
    private var job: Job? = null
    private var openSignal: CompletableDeferred<Unit>? = null
    private var lastLossAtMillis: Long? = null
    private var attemptsSinceStable = 0
    private var waitingForHost = false

    /** True while an episode owns the page. */
    val isReopening: Boolean get() = synchronized(lock) { job?.isActive == true }

    /** Attempts spent since the channel last stayed up for [stableMillis]. */
    val attempts: Int get() = synchronized(lock) { attemptsSinceStable }

    /** True while the next attempt is parked on D14's closed admission. */
    val isWaitingForHost: Boolean get() = synchronized(lock) { waitingForHost }

    /**
     * One channel close. Starts an episode when the engine is `Running`; a close
     * during `Starting`/`Stopped`/`Failed` is somebody else's teardown and is only
     * logged.
     */
    fun onChannelLost(cause: String) {
        val state = engineState()
        if (state != EngineHostState.Recovering && state !is EngineHostState.Running) {
            logger.debug(
                "channel lost (cause=$cause) while ${EngineLogText.describe(state)}; " +
                    "not a page incident, no reopen",
            )
            return
        }
        synchronized(lock) {
            if (job?.isActive == true) {
                logger.info(
                    "channel lost again (cause=$cause) while the reopen is in flight; " +
                        "the attempt in flight owns the next reload",
                )
                return
            }
        }
        val now = clock()
        val previous = lastLossAtMillis
        val escalating = previous != null && now - previous < stableMillis
        if (!escalating) {
            synchronized(lock) { attemptsSinceStable = 0 }
        }
        lastLossAtMillis = now
        val signal = CompletableDeferred<Unit>()
        synchronized(lock) {
            openSignal = signal
            waitingForHost = false
            attemptsSinceStable += 1
        }
        val first = policy.delayFor(attempts)
        logger.warn(
            "ordered channel lost (cause=$cause); reopening the page for a new one " +
                "(attempt ${attempts}, first backoff $first ms" +
                (if (escalating) ", escalating: the last channel did not stay up for $stableMillis ms" else "") +
                ")",
        )
        // The engine takes `Running -> Recovering` here, not at the reload: the
        // page is unusable from the moment the channel closed, and the turn gate
        // that waits for `Running` must see that from the first millisecond.
        onEpisodeStart()
        val started = scope.launch { runEpisode(signal) }
        synchronized(lock) { job = started }
        started.invokeOnCompletion {
            synchronized(lock) { if (job === started) job = null }
        }
    }

    /**
     * The ordered channel is open again.
     *
     * Ends the episode in flight (the page may have reconnected on its own, which
     * is the cheap outcome) and lets the engine take `Recovering -> Running`.
     */
    fun onChannelOpened() {
        val signal = openSignal
        openSignal = null
        synchronized(lock) { waitingForHost = false }
        if (signal != null && !signal.isCompleted) signal.complete(Unit)
    }

    /** `stop()`, `shutdown()`, a renderer rebuild: nothing of this lane survives. */
    fun cancel() {
        val running = synchronized(lock) {
            openSignal = null
            waitingForHost = false
            job.also { job = null }
        }
        running?.cancel()
    }

    private suspend fun runEpisode(signal: CompletableDeferred<Unit>) {
        try {
            while (true) {
                // The counter is global to a flapping channel; the delay is its
                // schedule, not the episode's.
                val scheduled = policy.delayFor(attempts)
                if (!episodeMayContinue(signal)) return
                logger.info("channel reopen: attempt ${attempts} in $scheduled ms (page reload)")
                delayMillis(scheduled)
                if (!episodeMayContinue(signal)) return
                if (!waitForHost(signal)) return
                // One attempt number for both lines: the engine logs the URL it
                // reloads with the same number this line carries.
                logger.info("channel reopen: reloading the page (attempt ${attempts})")
                reload(attempts)
                if (awaitChannel(signal)) {
                    logger.info(
                        "channel reopen: the ordered channel is back after ${attempts} reload attempt(s)",
                    )
                    return
                }
                if (!episodeMayContinue(signal)) return
                val originStuck = originRefusedUpgrades()
                logger.warn(
                    "channel reopen: attempt ${attempts} did not bring the channel back within " +
                        "$openTimeoutMillis ms" +
                        (if (originStuck) "; the origin refused the new upgrade (stale channel slot)" else "") +
                        "; backing off",
                )
                val restart = restartWorker
                if (originStuck && restart != null) {
                    logger.warn(
                        "channel reopen: escalating to a full worker restart (RESTART_WORKER); " +
                            "a reload cannot clear a stale channel slot",
                    )
                    if (restart()) {
                        logger.info("channel reopen: the worker was restarted; the new page owns the channel")
                        return
                    }
                    logger.error("channel reopen: the worker restart failed; continuing with reloads")
                }
                synchronized(lock) { attemptsSinceStable += 1 }
                lastLossAtMillis = clock()
            }
        } catch (cancelled: CancellationException) {
            logger.info("channel reopen: episode cancelled (${EngineLogText.describe(engineState())})")
            throw cancelled
        }
    }

    /** Ends the episode when the engine left the two states it may reload from. */
    private fun episodeMayContinue(signal: CompletableDeferred<Unit>): Boolean {
        if (signal.isCompleted) {
            logger.info("channel reopen: the page reopened the ordered channel on its own")
            return false
        }
        val state = engineState()
        if (state != EngineHostState.Recovering && state !is EngineHostState.Running) {
            logger.info(
                "channel reopen: abandoned while ${EngineLogText.describe(state)}",
            )
            return false
        }
        return true
    }

    /**
     * Waits until D14's admission lets a write through.
     *
     * No page is reloaded into a host that would refuse the new worker's first
     * `VFS_MUT`: see the file header. The wait is logged once, not per poll, so an
     * offline phone does not fill logcat.
     */
    private suspend fun waitForHost(signal: CompletableDeferred<Unit>): Boolean {
        if (hostAcceptsWrites()) return true
        logger.info(
            "channel reopen: waiting for the host to accept writes (D14 admission is closed); " +
                "no page is reloaded into a host that would refuse it",
        )
        synchronized(lock) { waitingForHost = true }
        try {
            while (!hostAcceptsWrites()) {
                if (!episodeMayContinue(signal)) return false
                delayMillis(admissionPollMillis)
            }
        } finally {
            synchronized(lock) { waitingForHost = false }
        }
        if (!episodeMayContinue(signal)) return false
        logger.info("channel reopen: the host accepts writes again; reloading now")
        return true
    }

    /** Polls for the channel after a reload. Bounded by [openTimeoutMillis]. */
    private suspend fun awaitChannel(signal: CompletableDeferred<Unit>): Boolean {
        var waited = 0L
        while (waited < openTimeoutMillis) {
            if (signal.isCompleted) return true
            delayMillis(OPEN_POLL_MILLIS)
            waited += OPEN_POLL_MILLIS
        }
        return signal.isCompleted
    }

    companion object {
        /** A reloaded page needs a few seconds to materialize and handshake. */
        const val DEFAULT_OPEN_TIMEOUT_MILLIS: Long = 8_000L

        /**
         * A channel that stayed up this long is a recovery, not a flap: only then
         * does the backoff start over at its first delay.
         */
        const val DEFAULT_STABLE_MILLIS: Long = 20_000L

        /** How often a parked attempt re-reads D14's admission. */
        const val DEFAULT_ADMISSION_POLL_MILLIS: Long = 2_000L

        /** Channel polls inside [awaitChannel]; granular enough for a 1 s page. */
        const val OPEN_POLL_MILLIS: Long = 250L
    }
}

/**
 * The one decision of the stale-channel watchdog in [WebViewEngine].
 *
 * The origin keeps a single channel slot and answers a second upgrade with HTTP
 * 409. While one channel is live, the only client that can ask for a second
 * upgrade is the page itself, and the page only retries after **its** socket
 * died — so growth in `channelsRejected` while this engine still believes it is
 * connected means the channel it believes in is a zombie (measured 2026-11-01:
 * `channelsRejected=2` with `connected=true`, every `/api` request timing out).
 *
 * Pure and separate so the rule is asserted on the JVM; the polling that feeds it
 * is device-verified (see the P22 receipt §6).
 */
internal object StaleChannelRule {
    /**
     * @param connected the engine's own belief (`ChannelStatus.connected`)
     * @param rejected `LoopbackMetrics.channelsRejected` now
     * @param seenRejected the reading taken at the previous poll
     * @param accepted `LoopbackMetrics.channelsAccepted` now; a second accepted
     *   channel means the page *did* reconnect, which is not a zombie
     */
    fun isStale(connected: Boolean, rejected: Long, seenRejected: Long, accepted: Long): Boolean =
        connected && rejected > seenRejected && accepted >= 1
}
