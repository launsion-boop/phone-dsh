// phone-dsh — :dsh / com.phonedsh.dsh.host: the owner of Backoff's exit.
// SPDX-License-Identifier: MIT
//
// ---- the hole this file closes ---------------------------------------------
// budgets.md §2 gives `Backoff` exactly one exit: `Backoff -> Running` when
// "Retry-After elapsed, network path satisfied, one probe succeeded". The
// `Running -> Backoff` row's Actions column says "start the retry schedule",
// and the controller records that as `ControllerEffect.START_RETRY_SCHEDULE`
// and returns. Until this file existed, *nobody* performed it:
//
//   * `START_RETRY_SCHEDULE` had no owner (ControllerEffects logged "the retry
//     schedule owner" and dropped it);
//   * `RetryAfterElapsed` and `RetryProbeSucceeded` had no producer in any main
//     source set (only tests).
//
// So one `svc wifi disable` put the host in `Backoff` for the life of the
// process: the network came back, NWPath reported `satisfied`, the controller
// recorded it as an observation ("no D14 edge"), and the guard's third
// conjunct — a Retry-After window that no scheduler ever elapsed — stayed
// false forever. Admission never reopened and every turn failed (P15
// reproduced it on emulator API 35, 2026-11-01).
//
// ---- what this lane does, and what it refuses to do -------------------------
//   * it arms exactly one schedule per entry into `Backoff`, from the
//     `START_RETRY_SCHEDULE` effect;
//   * after the window it feeds `RetryAfterElapsed` — the signal §2's guard
//     names — and then waits for the network path to be satisfied before it
//     probes, because the guard needs both and a probe fed against an
//     unsatisfied path would only manufacture a GUARD_FAILED rejection;
//   * it performs one probe through [RetryProbe] and feeds
//     `RetryProbeSucceeded(leaseVerified = true)` **only** when that probe
//     returned true. A failed probe feeds no signal: "one probe succeeded" is
//     not made true by a probe that failed, and the lane must not fake the
//     guard to get out of the state;
//   * it does not change the state machine, admission or the guard. It feeds
//     the three facts §2 asks for and lets the table decide.
//
// ---- the contract hole this lane cannot close -------------------------------
// `Backoff -> Running` demands a "Retry-After", but the NWPath entry has no
// HTTP response and therefore no `Retry-After` header (budgets.md §2 line 48's
// second alternative; §3 line 72 describes that exit as "after one successful
// probe" and does not mention Retry-After at all — the two rows disagree).
// The lane resolves it the only way that keeps the written guard intact: for a
// non-HTTP entry the retry window is the schedule's own delay ([RetryPolicy]),
// which is exactly what §1's "retry with backoff and jitter" describes. The
// spec fix belongs to the spec owner (the guard should be split by entry), not
// to this class; see the P15 report.

package com.phonedsh.dsh.host

import com.phonedsh.platform.Clock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlin.random.Random

/**
 * Performs the retry schedule of a `Backoff` entry and feeds the two signals
 * that end it.
 *
 * Thread-safe: [arm] and [onNetworkPath] are called from the facade's signal
 * thread, [release] from any thread, and the schedule itself runs on the
 * facade's scope.
 *
 * @param scope where the schedule runs. Must outlive one `Backoff` entry; the
 *   facade passes its own per-boot scope, so [release] (and `stop()`) is the
 *   only thing that ends a schedule early.
 * @param clock the facade's monotonic clock; a retry window is a duration.
 * @param probe the "one probe succeeded" seam.
 * @param policy the delay of each window.
 * @param onRetryAfterElapsed feeds `ControllerSignal.RetryAfterElapsed`.
 * @param onProbeSucceeded feeds `ControllerSignal.RetryProbeSucceeded(true)`.
 *   Called only for a probe that returned `true`.
 * @param sleepFor the window itself; injected so a test drives the schedule
 *   without wall-clock time. Production uses `kotlinx.coroutines.delay`.
 * @param randomDouble the jitter draw; injected for the same reason.
 */
internal class RetryLane(
    private val scope: CoroutineScope,
    private val clock: Clock,
    private val probe: RetryProbe,
    private val onRetryAfterElapsed: (RetryAttempt) -> Unit,
    private val onProbeSucceeded: (RetryAttempt) -> Unit,
    private val policy: RetryPolicy = RetryPolicy.DEFAULT,
    private val logger: HostLog = HostLog.None,
    private val sleepFor: suspend (Long) -> Unit = { millis -> delay(millis) },
    private val randomDouble: () -> Double = { Random.nextDouble() },
) {
    /** Which D14 row entered `Backoff`; it decides whether a Retry-After exists. */
    enum class Entry(val wireName: String) {
        /**
         * NWPath unsatisfied (budgets.md §2 line 48, second alternative). No
         * HTTP response happened, so there is no `Retry-After` header: the
         * window is the schedule's own delay. This is the contract hole
         * described in the file header.
         */
        NETWORK_PATH("network_path"),

        /**
         * Upstream 429/5xx (budgets.md §2 line 48, first alternative). A
         * `Retry-After` hint may exist; when the model edge passes one it wins
         * over the schedule.
         */
        UPSTREAM("upstream"),

        /** A persisted `Backoff` restored by the boot mapping; the window is the remainder of the stored deadline. */
        BOOT("boot"),
    }

    /** One attempt of the schedule, for the log line and the fed signal. */
    data class RetryAttempt(
        val entry: Entry,
        val attempt: Int,
        val delayMillis: Long,
    )

    private val lock = Any()

    /** The one schedule of the current `Backoff` entry, or `null`. */
    private var job: Job? = null

    private var entry: Entry? = null

    private var attempt: Int = 0

    /**
     * Wall-clock deadline of the current window, for `host-state.json`'s
     * `backoff_until_ms`. Monotonic time decides when the window ends; this
     * field exists only so a boot can restore the remainder.
     */
    private var deadlineWallMillis: Long? = null

    /**
     * The last NWPath observation **while in `Backoff`**.
     *
     * Starts `false` on every entry because the machine does too: both
     * `Running -> Backoff` rows reset `isNetworkPathSatisfied`, so the guard
     * needs a fresh observation and a lane that started `true` would feed a
     * probe the machine must reject.
     */
    private val pathSatisfied = MutableStateFlow(false)

    /** Set by [release]; a cancelled schedule must not feed a stale signal. */
    @Volatile
    private var released: Boolean = false

    /** `true` between "the window elapsed" and "a satisfied path arrived". */
    private val waitingForPath = MutableStateFlow(false)

    /** `true` while a window (or its probe) is still in flight. */
    val isWaiting: Boolean
        get() = synchronized(lock) { job?.isActive == true }

    /**
     * `true` while an elapsed window is waiting for a satisfied network path.
     *
     * Diagnostic, and the one way a test can assert that the probe has **not**
     * run yet without racing a sleep: the guard needs both facts, so the lane
     * must not probe against an unsatisfied path.
     */
    val isWaitingForPath: Boolean
        get() = waitingForPath.value

    /** The attempt number of the current entry; `0` outside `Backoff`. */
    val attemptNumber: Int
        get() = synchronized(lock) { attempt }

    /** `backoff_until_ms` of the current window, or `null` outside `Backoff`. */
    val backoffUntilMillis: Long?
        get() = synchronized(lock) { deadlineWallMillis }

    /**
     * Arms the schedule of one `Backoff` entry.
     *
     * Idempotent per entry: a repeated `START_RETRY_SCHEDULE` (a duplicated
     * effect, or the boot effect racing the first transition) never arms a
     * second schedule.
     *
     * @param entry which row entered `Backoff`.
     * @param retryAfterMillis the upstream hint, `null` for the NWPath entry.
     * @param firstWindowMillis an explicit first window (the remainder of a
     *   persisted `backoff_until_ms`); `null` uses [RetryPolicy].
     */
    fun arm(
        entry: Entry,
        retryAfterMillis: Long? = null,
        firstWindowMillis: Long? = null,
    ) {
        // The first window — and therefore `backoff_until_ms` — is computed
        // here, not inside the coroutine: the `PERSIST_HOST_STATE` effect of the
        // same transition is performed right after this call, and a deadline
        // that only existed once the coroutine was dispatched would be written
        // as `null`.
        val firstWindow = firstWindowMillis ?: policy.delayFor(1, retryAfterMillis, randomDouble)
        synchronized(lock) {
            if (job?.isActive == true) {
                logger.debug(
                    "retry schedule already armed for this Backoff entry " +
                        "(${this.entry?.wireName}); no second schedule",
                )
                return
            }
            released = false
            this.entry = entry
            attempt = 1
            deadlineWallMillis = clock.nowMillis() + firstWindow
            pathSatisfied.value = false
            job = scope.launch { run(entry, firstWindow) }
        }
    }

    /**
     * One NWPath observation, forwarded by the facade while the host is in
     * `Backoff`. It only releases a waiting attempt; it is not a signal the
     * lane sends to the controller (the facade already fed that).
     */
    fun onNetworkPath(satisfied: Boolean) {
        pathSatisfied.value = satisfied
        if (satisfied) {
            logger.debug("retry schedule: the network path is satisfied; a pending attempt may probe")
        }
    }

    /**
     * Ends the schedule of the current entry.
     *
     * Called when the host leaves `Backoff` (the probe succeeded, or another
     * row took it) and from `stop()`. Safe to call twice and safe to call from
     * inside the schedule's own coroutine: the coroutine only checks
     * [released] at its suspension points.
     */
    fun release() {
        val cancelled = synchronized(lock) {
            val current = job
            job = null
            entry = null
            attempt = 0
            deadlineWallMillis = null
            pathSatisfied.value = false
            waitingForPath.value = false
            current
        }
        released = true
        if (cancelled != null) {
            logger.debug("retry schedule released: the host left Backoff")
            cancelled.cancel()
        }
    }

    private suspend fun run(entry: Entry, firstWindowMillis: Long) {
        var attempt = 1
        var delayMillis = firstWindowMillis
        while (!released) {
            synchronized(lock) {
                this.attempt = attempt
                deadlineWallMillis = clock.nowMillis() + delayMillis
            }
            logger.info(
                "retry schedule (${entry.wireName}): attempt $attempt in $delayMillis ms " +
                    "(window $delayMillis ms, admission stays closed)",
            )
            sleepFor(delayMillis)
            if (released) return
            logger.info(
                "retry schedule (${entry.wireName}): the window elapsed; " +
                    "feeding RetryAfterElapsed for attempt $attempt",
            )
            onRetryAfterElapsed(RetryAttempt(entry, attempt, delayMillis))
            if (released) return
            awaitSatisfiedPath(entry, attempt)
            if (released) return
            val succeeded = try {
                probe.probe()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                logger.warn(
                    "retry probe threw ${failure.javaClass.simpleName}; " +
                        "a thrown probe is a failed probe, not a pass",
                )
                false
            }
            if (succeeded) {
                synchronized(lock) { deadlineWallMillis = null }
                logger.info(
                    "retry probe succeeded (${entry.wireName}, attempt $attempt); " +
                        "feeding RetryProbeSucceeded(leaseVerified=true)",
                )
                onProbeSucceeded(RetryAttempt(entry, attempt, delayMillis))
                return
            }
            logger.warn(
                "retry probe failed (${entry.wireName}, attempt $attempt); " +
                    "the host stays in Backoff and the schedule proposes another window",
            )
            attempt += 1
            delayMillis = policy.delayFor(attempt, null, randomDouble)
        }
    }

    private suspend fun awaitSatisfiedPath(entry: Entry, attempt: Int) {
        if (pathSatisfied.value) return
        logger.info(
            "retry schedule (${entry.wireName}): attempt $attempt waits for a satisfied " +
                "network path before the probe (the guard needs both)",
        )
        waitingForPath.value = true
        try {
            pathSatisfied.first { it }
        } finally {
            waitingForPath.value = false
        }
    }
}
