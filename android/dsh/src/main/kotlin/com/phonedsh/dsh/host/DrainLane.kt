// phone-dsh — :dsh / com.phonedsh.dsh.host: the owner of the drain's exit.
// SPDX-License-Identifier: MIT
//
// ---- the hole this file closes ---------------------------------------------
// budgets.md §2 gives `Draining` two ways out: `Draining -> Parked` when the
// drain completes or the 20 s deadline ends the wait, and
// `Draining -> Recovering` on a planned restart / WebContent termination. The
// controller records the first row's actions as effects (CLOSE_EPOCH,
// FSYNC_MATERIALIZED, STOP_WORKER) and returns; somebody has to perform them and
// then feed `DrainCompleted`. Until this file existed, *nobody* did:
//
//   * `DrainCompleted` had no producer in any main source set (only tests);
//   * `ARM_DRAIN_DEADLINE` / `START_BACKGROUND_TASK` were debug lines in the
//     notifier lane ("has no Notifier surface in this lane").
//
// So one HOME switch was enough to park the host in `Draining` for the life of
// the process: no epoch was closed, no deadline was armed, and the only later
// edge the machine knows — `scenePhase(active)` — is not a row out of
// `Draining`, so the return to the foreground was refused as
// `ILLEGAL_TRANSITION` and the App never became usable again (P5 reported it;
// P10 reproduced it on emulator API 35, 2026-11-01).
//
// ---- what this lane does, and what it refuses to do ------------------------
//   * it performs the drain in the D18 order: close the epoch (the WAL's fsync
//     and manifest are inside [HostWal.closeEpoch]), then stop the worker;
//   * the 20 s deadline is a BOUND, not a wait: the drain closes as soon as it
//     can (milliseconds), it never sits idle for 20 s. If the close has not
//     returned when the deadline arrives, the *wait* is abandoned — the close
//     itself is never cancelled, because an fsync cut in half is exactly the
//     torn epoch plan §7.10 forbids — the deadline signal is fed so the
//     controller records `FORCE_DRAIN_DEADLINE` / `CANCEL_IN_FLIGHT_REQUESTS`,
//     and the worker is stopped anyway;
//   * it arms exactly one drain per entry into `Draining` and reports exactly
//     one completion. A second `Running -> Draining` starts a new one;
//   * it does not touch admission, the notifier or the controller: the facade
//     owns those, and this class only reports what it performed.
//
// ---- `START_BACKGROUND_TASK` on this platform ------------------------------
// The probe App declares no service (`AndroidManifest` has none) and its
// `Notifier` is DISABLED, so there is no OS background window to open. That is
// not a reason to leave the drain unowned: the effect exists to keep the process
// alive *while the drain runs*, and a drain that closes in milliseconds needs no
// window. The honest report is therefore "performed in-process, no background
// window", not a silent drop — [DrainOutcome.backgroundWindow] carries it and
// the facade logs it.

package com.phonedsh.dsh.host

import com.phonedsh.platform.Clock
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Performs `Draining -> Parked` and reports it, so the state machine has an exit
 * it can actually take.
 *
 * Thread-safe: [arm] and [foregroundReturn] may be called from the facade's
 * signal thread and from the UI thread, and the drain itself runs on the
 * facade's scope.
 *
 * @param scope where the drain runs. The close is a child launch of this scope,
 *   not of the waiting coroutine, so neither the deadline nor a caller's
 *   cancellation can end an fsync that is already writing. The scope must not be
 *   the facade's per-boot [kotlinx.coroutines.Job] list (which `stop()` cancels).
 * @param clock the facade's monotonic clock; the deadline is a duration.
 * @param closeEpoch the WAL seam (`CLOSE_EPOCH` + `FSYNC_MATERIALIZED`).
 * @param stopWorker the `:engine` seam (`STOP_WORKER`).
 * @param awaitWorkerStopped waits until the worker really is gone; `Parked`
 *   claims "WebContent stopped" (§1), so the completion is not reported before
 *   this returns `true`.
 * @param onDeadlineElapsed feeds `ControllerSignal.DrainDeadlineElapsed`, so the
 *   controller records the force and the abort instead of this lane doing
 *   neither.
 * @param onDrained reports the one completion of this drain.
 */
internal class DrainLane(
    private val scope: CoroutineScope,
    private val clock: Clock,
    private val closeEpoch: suspend () -> Long?,
    private val stopWorker: () -> Unit,
    private val awaitWorkerStopped: suspend () -> Boolean,
    private val onDeadlineElapsed: () -> Unit,
    private val onDrained: (DrainOutcome) -> Unit,
    private val logger: HostLog = HostLog.None,
) {
    /** Why a drain ended. Every reason still ends in `Parked`. */
    enum class Reason(val wireName: String) {
        /** The epoch closed inside the deadline; the normal path. */
        CLOSED("closed"),

        /** The 20 s deadline ended the wait; the close keeps running behind it. */
        DEADLINE("deadline"),

        /** The WAL refused the close; that failure is already a D14 `Failed`. */
        CLOSE_FAILED("close_failed"),
    }

    /**
     * What one drain performed.
     *
     * @param reason why the wait for the epoch close ended.
     * @param durableUpto the close record's watermark, or `null` when the close
     *   did not return (deadline/failure) or no sink is attached.
     * @param workerStopped whether `Parked`'s "WebContent stopped" is true.
     * @param backgroundWindowAlways `false` on this platform: no service, so the
     *   drain ran in-process with no OS background window.
     */
    data class DrainOutcome(
        val reason: Reason,
        val durableUpto: Long?,
        val workerStopped: Boolean,
        val backgroundWindowAlways: Boolean = false,
    )

    private val lock = Any()

    /** The one drain of the current `Draining` entry. */
    private var drainJob: Job? = null

    /**
     * Arms the drain of one `Running -> Draining` entry.
     *
     * Idempotent per entry: a repeated arm while the same drain is running is a
     * no-op, so a duplicated effect cannot close two epochs.
     *
     * @param deadlineAtMillis the controller's `drainDeadlineAtMillis`.
     */
    fun arm(deadlineAtMillis: Long?) {
        val deadline = deadlineAtMillis ?: (clock.monotonicMillis() + DEFAULT_DEADLINE_MILLIS)
        synchronized(lock) {
            if (drainJob?.isActive == true) {
                logger.debug("drain already armed for this Draining entry; no second close")
                return
            }
            drainJob = scope.launch { run(deadline) }
        }
    }

    /**
     * A foreground return arrived while the host is `Draining`.
     *
     * It changes nothing about the close — the epoch must still be durably
     * closed, and a wait of a few milliseconds is not worth a torn epoch — it
     * only records that the resume is waiting. The facade re-feeds its
     * `scenePhase(active)` when [onDrained] reports.
     *
     * Returns `false` when no drain is in flight (the caller then arms one, so a
     * composition that never armed it cannot leave the host parked there).
     */
    fun foregroundReturn(): Boolean {
        synchronized(lock) {
            if (drainJob?.isActive != true) return false
        }
        logger.info(
            "foreground return while Draining: the drain finishes as soon as the epoch close " +
                "returns, then the resume follows (the close is never cancelled)",
        )
        return true
    }

    /** `true` while a drain is still in flight (diagnostics and tests). */
    val isDraining: Boolean get() = synchronized(lock) { drainJob?.isActive == true }

    private suspend fun run(deadlineAtMillis: Long) {
        val remaining = (deadlineAtMillis - clock.monotonicMillis()).coerceAtLeast(0L)
        logger.info(
            "drain: closing the epoch now (deadline in $remaining ms; " +
                "no background window: this App declares no service)",
        )
        val wait = closeBounded(remaining)
        val attempt = (wait as? CloseWait.Closed)?.attempt
        val reason = when {
            attempt == null -> {
                logger.warn(
                    "drain deadline reached with the epoch close still running; the wait is " +
                        "abandoned (the close is not cancelled: a torn epoch is worse)",
                )
                onDeadlineElapsed()
                Reason.DEADLINE
            }
            attempt.failure != null -> {
                // The sink already reported this to the controller as a D14
                // failure; the drain still stops the worker and reports, and the
                // machine itself refuses `DrainCompleted` from `Failed`.
                logger.warn("drain: epoch close failed (${attempt.failure}); the drain still parks")
                Reason.CLOSE_FAILED
            }
            else -> {
                logger.info("drain: epoch closed, durable_upto=${attempt.durableUpto ?: 0}")
                Reason.CLOSED
            }
        }
        // §2's `Draining -> Parked` actions are "close the epoch, fsync, stop the
        // worker": the close is either done or running behind us (both reported),
        // and the worker stop is what remains.
        stopWorker()
        val stopped = awaitWorkerStopped()
        if (!stopped) {
            logger.warn("drain: the worker did not report Stopped inside the bound; parking anyway")
        }
        val drained = DrainOutcome(
            reason = reason,
            durableUpto = attempt?.durableUpto,
            workerStopped = stopped,
        )
        logger.info(
            "drain done: reason=${drained.reason.wireName}, durable_upto=${drained.durableUpto ?: -1}, " +
                "worker_stopped=${drained.workerStopped}, background_window=false",
        )
        onDrained(drained)
    }

    /**
     * Waits for the close until the deadline.
     *
     * The close runs as a child launch on the lane's scope, not on this
     * coroutine, so the timeout ends the *wait* without cancelling the fsync that
     * is already writing.
     */
    private suspend fun closeBounded(remainingMillis: Long): CloseWait {
        val attempt = AtomicReference<CloseAttempt?>(null)
        val closed = CompletableDeferred<Unit>()
        scope.launch {
            val result = try {
                CloseAttempt(durableUpto = closeEpoch(), failure = null)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                CloseAttempt(durableUpto = null, failure = failure.javaClass.simpleName)
            }
            attempt.set(result)
            closed.complete(Unit)
        }
        withTimeoutOrNull(remainingMillis) { closed.await() }
        val finished = attempt.get()
        return if (finished != null) CloseWait.Closed(finished) else CloseWait.Deadline
    }

    private data class CloseAttempt(val durableUpto: Long?, val failure: String?)

    private sealed interface CloseWait {
        data class Closed(val attempt: CloseAttempt) : CloseWait

        data object Deadline : CloseWait
    }

    companion object {
        /** budgets.md §1's drain deadline, used only when the machine has no value. */
        const val DEFAULT_DEADLINE_MILLIS: Long = 20_000L
    }
}
