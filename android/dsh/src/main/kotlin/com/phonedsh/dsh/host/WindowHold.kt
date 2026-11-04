// phone-dsh — :dsh / com.phonedsh.dsh.host: the bounded hold that defers a drain.
// SPDX-License-Identifier: MIT
//
// `WindowHold` is the guard on budgets.md §2's `Running -> Draining` row: the
// facade offers every `scenePhase(background)` here first, and only feeds the
// edge when the hold refuses it (no window in place) or when the hold expires.
//
// ---- why the edge is deferred instead of cancelled -------------------------
// With a window in place the platform has granted the turn execution authority,
// so plan §7.9 says "尽量完成" and the D14 row's premise is false. The facade
// therefore does not feed the edge; it queues it, exactly as it already queues
// `scenePhase(active)` while `Draining` (budgets.md §2 has no reverse edge for
// either case). The queued edge is fed when the window ends — the turn completed,
// the user pressed 停止本轮, the platform took the job/service away — which runs
// the ordinary `Draining -> Parked` exit and closes the epoch.
//
// ---- why the hold is bounded ------------------------------------------------
// A turn that hangs on the network must not hold the host in `Running` forever,
// and the window is not a licence to: `maxHoldMillis` is the bound. When it
// expires the hold releases and the queued edge is fed even though the window is
// still in place — the drain wins, because a host with no exit is worse than a
// turn cut short. `DefaultPhoneDshHost.WINDOW_HOLD_MAX_MILLIS` documents the
// value and its relation to the job's own timeout.
//
// That bound is what makes a `SCHEDULED` window safe to hold (L53). A scheduled
// window is an accepted promise, not a running component, and it may be accepted
// and then never start (the job's constraint is never satisfied, the system
// quietly drops the job without `onStopJob`). It is still bounded here because
// the clock starts at the background edge, not at the start of the window: a
// `SCHEDULED` phase that never becomes `RUNNING` expires exactly like a stalled
// `RUNNING` one, and a `SCHEDULED -> RUNNING` transition does not re-arm it.
//
// ---- one more refusal -------------------------------------------------------
// After a hold expires, the same window may not defer another edge until the app
// has been in the foreground again. Otherwise a background frame that raced the
// release could re-arm a hold on a window that already proved it can wedge.

package com.phonedsh.dsh.host

import com.phonedsh.platform.Clock

/**
 * The one held background edge of a `Running` host.
 *
 * Thread-safe: [hold], [check] and the foreground release may be called from the
 * signal thread, the window watch coroutine and `stop()`. It performs no I/O and
 * starts nothing; the facade owns the coroutine that calls [check].
 */
internal class WindowHold(
    private val clock: Clock,
    private val window: TurnWindowRead,
    private val maxHoldMillis: Long,
    private val logger: HostLog = HostLog.None,
) {
    /** Why a hold ended. Both reasons feed the deferred edge. */
    enum class ReleaseReason(val wireName: String) {
        /** The window is gone: the turn completed, was stopped, or was taken away. */
        WINDOW_ENDED("window_ended"),

        /** The window is still in place but `maxHoldMillis` elapsed. */
        HOLD_DEADLINE("hold_deadline"),
    }

    /** What is being held: which window, and since when (monotonic millis). */
    data class Held(
        val backend: TurnWindowBackend,
        val phase: TurnWindowPhase,
        val sinceMillis: Long,
    )

    /**
     * One ended hold.
     *
     * @param reason why it ended.
     * @param heldMillis how long the edge was deferred.
     * @param backend the window that deferred it.
     * @param phase how far that window had got when the hold ended.
     */
    data class Release(
        val reason: ReleaseReason,
        val heldMillis: Long,
        val backend: TurnWindowBackend,
        val phase: TurnWindowPhase,
    )

    private val lock = Any()

    private var held: Held? = null

    /** Set by [ReleaseReason.HOLD_DEADLINE]; cleared when the app is foreground again. */
    private var expired = false

    /** `true` while a background edge is deferred for a measured window. */
    val isHeld: Boolean get() = synchronized(lock) { held != null }

    /**
     * Offers one `scenePhase(background)` to the window.
     *
     * A `SCHEDULED` window (the platform accepted the job/service but has not
     * started it) is offered exactly like a `RUNNING` one: the edge is deferred
     * either way.
     *
     * @return the held edge when the edge must **not** be fed, or `null` when the
     *   caller must feed it now (no window, an unreadable window, or a previous
     *   hold that already expired).
     */
    fun hold(): Held? {
        synchronized(lock) {
            if (held != null) {
                // A duplicated background frame while the first edge is deferred:
                // it is the same edge, not a second one.
                logger.debug("window: the background edge is already held; no second hold")
                return held
            }
            if (expired) {
                logger.warn(
                    "window: a previous hold expired for this background spell; not deferring " +
                        "the edge again until the app is foreground (the drain is the exit)",
                )
                return null
            }
            val reading = readSafely()
            return when (reading) {
                is TurnWindow.InPlace -> {
                    val now = clock.monotonicMillis()
                    held = Held(reading.backend, reading.phase, now)
                    logger.info(
                        "window: the turn window is in place (backend=${reading.backend.wireName}, " +
                            "phase=${reading.phase.wireName}); " +
                            "the Running -> Draining edge is deferred",
                    )
                    held
                }

                TurnWindow.Absent -> {
                    logger.debug("window: no turn window is in place; the background edge is fed")
                    null
                }

                is TurnWindow.Unreadable -> {
                    // Fail-safe direction: an unmeasured window is not a window.
                    logger.warn(
                        "window: the turn-window reading is unusable (${reading.reason}); " +
                            "fail-safe direction: treating it as no window and feeding the drain",
                    )
                    null
                }
            }
        }
    }

    /**
     * The app came back (or the host is stopping): drop the hold without feeding
     * the deferred edge.
     *
     * A foreground return means the queued "went to background" no longer
     * describes the world, so it is dropped; §2 has no `Running -> ...` row for it
     * and none is needed.
     *
     * @return `true` when a hold existed.
     */
    fun releaseForForeground(reason: String): Boolean = synchronized(lock) {
        // Any foreground return ends the refusal an expired hold installed: the
        // next background spell may defer again, on a fresh window.
        expired = false
        val current = held ?: return false
        held = null
        logger.info(
            "window: $reason; the background edge held since ${current.sinceMillis} ms is " +
                "dropped (no D14 edge, no drain)",
        )
        true
    }

    /**
     * Records that the app is visible again, without touching a live hold.
     *
     * `AppForeground(true)` arrives before `scenePhase(active)`; the hold itself
     * is released by that scene-phase signal (which is the one the D14 edge would
     * have been about), but the expired-hold refusal is a foreground fact and ends
     * here.
     */
    fun onForeground() {
        synchronized(lock) { expired = false }
    }

    /**
     * Ends a hold when the window watch fires.
     *
     * A `SCHEDULED -> RUNNING` transition is the same window making progress, not
     * a new one: [Held.sinceMillis] is kept, so the bound does not restart when
     * the job finally enters its execution slot. The hold also keeps reporting
     * the latest reading, so a release names the phase the window had reached.
     *
     * @return the ended hold, or `null` while it must stay held.
     */
    fun check(): Release? {
        synchronized(lock) {
            val current = held ?: return null
            val reading = readSafely()
            val heldMillis = (clock.monotonicMillis() - current.sinceMillis).coerceAtLeast(0L)
            val live = reading as? TurnWindow.InPlace
            val reason = when {
                live == null -> ReleaseReason.WINDOW_ENDED
                heldMillis >= maxHoldMillis -> ReleaseReason.HOLD_DEADLINE
                else -> {
                    if (live.phase != current.phase || live.backend != current.backend) {
                        // Same hold, same start: only the reading got sharper.
                        held = current.copy(backend = live.backend, phase = live.phase)
                        logger.info(
                            "window: the held window changed reading " +
                                "(${current.backend.wireName}/${current.phase.wireName} -> " +
                                "${live.backend.wireName}/${live.phase.wireName}) after $heldMillis ms; " +
                                "the hold and its ${maxHoldMillis} ms bound stay as they were",
                        )
                    }
                    return null
                }
            }
            held = null
            if (reason == ReleaseReason.HOLD_DEADLINE) expired = true
            val release = Release(
                reason = reason,
                heldMillis = heldMillis,
                backend = live?.backend ?: current.backend,
                phase = live?.phase ?: current.phase,
            )
            when {
                reason == ReleaseReason.HOLD_DEADLINE -> logger.warn(
                    "window: ${release.backend.wireName} is still in place after $heldMillis ms " +
                        "(phase=${release.phase.wireName}, the bound is $maxHoldMillis ms); " +
                        "the hold expires and the drain runs",
                )

                reading is TurnWindow.Unreadable -> logger.warn(
                    "window: the turn-window reading became unusable (${reading.reason}); " +
                        "fail-safe direction: the hold ends after $heldMillis ms and the drain runs",
                )

                else -> logger.info(
                    "window: the ${release.backend.wireName} window ended after $heldMillis ms " +
                        "(phase=${release.phase.wireName}); " +
                        "the deferred background edge is released",
                )
            }
            return release
        }
    }

    /** `true` when a hold already expired in this background spell (diagnostics). */
    val isExpired: Boolean get() = synchronized(lock) { expired }

    private fun readSafely(): TurnWindow = try {
        window.read()
    } catch (failure: Exception) {
        TurnWindow.Unreadable(failure.javaClass.simpleName)
    }
}
