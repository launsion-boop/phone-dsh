// phone-dsh — :dsh / com.phonedsh.dsh.host: D14 effects on the Notifier surface.
// SPDX-License-Identifier: MIT
//
// The controller is pure: it returns `ControllerEffect`s and expects the facade to
// perform them (ControllerEffect's KDoc says as much). This file is the facade's
// share of that:
//
//   * the boot-recovery surface (`reportBootRecovery` in the controller's own
//     vocabulary) — the one user-visible effect this lane can honestly produce,
//     because it needs no WAL and no lease backend;
//   * the failure notification, so "Failed" is not only a flow value the UI may
//     never render;
//   * everything else: a debug line naming the effect, not a deferred stub and not
//     a silent drop. Each of those effects belongs to a lane that owns the resource
//     (WAL, fence, drain deadline, retry schedule), and this file says which.
//
// Notification ids sit in their own range (7401-7499): the background lane owns
// 7301-7399 (TurnNotifications) and two lanes must never overwrite each other's
// notification.

package com.phonedsh.dsh.host

import com.phonedsh.controller.ControllerEffect
import com.phonedsh.controller.ControllerStateMachine
import com.phonedsh.controller.BootDisposition
import com.phonedsh.controller.HostState
import com.phonedsh.controller.SignalOutcome
import com.phonedsh.platform.Notifier
import com.phonedsh.platform.NotifierAvailability

/**
 * Applies the controller's effects to the user-visible [Notifier].
 *
 * Synchronous by design: a notification is posted where the transition is
 * recorded, so the log order and the notification order cannot drift.
 */
internal class ControllerEffects(
    private val notifier: Notifier,
    private val logger: HostLog,
) {
    /**
     * The boot surface.
     *
     * D14's boot mapping sends `Recovering -> ...` for a crash or a parked resume,
     * and the user must be able to tell "recovering" from "running". A cold start
     * has nothing to recover, so it posts nothing.
     */
    fun onBoot(machine: ControllerStateMachine) {
        val disposition = machine.bootDisposition
        val recovering = machine.state == HostState.RECOVERING &&
            (disposition == BootDisposition.CRASH_RECOVERY || disposition == BootDisposition.PARKED_RESUME)
        if (recovering) {
            reportBootRecovery(machine)
        } else {
            logger.info(
                "boot: disposition=${disposition.wireName}, state=${machine.state.wireName} " +
                    "(${machine.bootReason}); no recovery notification",
            )
        }
        apply(machine.initialBoot.effects, machine)
    }

    /** The effects of one handled signal; rejections carry none. */
    fun onOutcome(outcome: SignalOutcome, machine: ControllerStateMachine) {
        when (outcome) {
            is SignalOutcome.Transitioned -> apply(outcome.record.effects, machine)
            is SignalOutcome.Observed -> apply(outcome.effects, machine)
            is SignalOutcome.Rejected -> Unit
        }
    }

    private fun reportBootRecovery(machine: ControllerStateMachine) {
        if (notifier.availability == NotifierAvailability.DISABLED) {
            // §7.4-4: a degraded presentation path must stay visible to the host
            // log instead of pretending the user saw something.
            logger.warn(
                "boot recovery (${machine.bootReason}) is not user-visible: notifications are DISABLED",
            )
            return
        }
        notifier.notify(
            id = BOOT_RECOVERY_NOTIFICATION_ID,
            title = "正在恢复上次会话",
            body = "上次退出时还有未完成的工作，正在恢复。",
            ongoing = true,
            action = null,
        )
        logger.info("notified boot recovery: disposition=${machine.bootDisposition.wireName}")
    }

    private fun apply(effects: List<ControllerEffect>, machine: ControllerStateMachine) {
        for (effect in effects) {
            when (effect) {
                // Admission opening is the end of the recovery surface: the host
                // is Running, so the "recovering" notification is a lie from here
                // on. This is the only effect in this lane that clears a
                // notification.
                ControllerEffect.OPEN_ADMISSION -> {
                    notifier.cancel(BOOT_RECOVERY_NOTIFICATION_ID)
                    logger.debug("admission open; boot recovery surface cleared")
                }

                // budgets.md §2: `any state -> Failed` is fail-loud. The reason
                // code is a closed vocabulary (ControllerFailure), safe to show.
                ControllerEffect.RECORD_FAILURE -> {
                    val code = machine.lastFailure?.code ?: "UNRECORDED"
                    val detail = machine.lastFailureDetail
                    notifier.notify(
                        id = HOST_FAILURE_NOTIFICATION_ID,
                        title = "PhoneDSH 已停止",
                        body = if (detail == null) code else "$code（$detail）",
                        ongoing = false,
                        action = null,
                    )
                    logger.warn(
                        "notified failure: $code" + (detail?.let { " detail=$it" } ?: ""),
                    )
                }

                // Performed by the host facade rather than by a notification:
                // reset recovery is owned by PhoneDshHost.resetFailure(), the
                // drain's exit (budgets.md §2 `Draining -> Parked`) by DrainLane,
                // and the worker edges by DrainLane / the `:engine` seam. They are
                // named here so the notifier lane does not read as their owner,
                // and they are NOT dropped: PhoneDshHost.applyHostEffects
                // performs them.
                ControllerEffect.ARM_DRAIN_DEADLINE,
                ControllerEffect.START_BACKGROUND_TASK,
                ControllerEffect.FORCE_DRAIN_DEADLINE,
                ControllerEffect.CANCEL_IN_FLIGHT_REQUESTS,
                ControllerEffect.CLOSE_EPOCH,
                ControllerEffect.FSYNC_MATERIALIZED,
                ControllerEffect.START_WORKER,
                ControllerEffect.RESTART_WORKER,
                ControllerEffect.RE_RUN_RECOVERY,
                ControllerEffect.STOP_WORKER,
                -> logger.debug(
                    "effect '${effect.label}' is performed by the host facade, not by a Notifier",
                )

                // The rest belong to lanes that own the resource:
                //   FREEZE_WAL_SEQ / KEEP_WAL_READ_ONLY
                //       -> WAL + recovery lanes (NativeWal, another lane);
                //   VERIFY_LEASE -> [LeaseProbe];
                //   SEND_FENCE / SEND_LIFECYCLE_OPEN / POST_RECLAIM_TOKEN
                //       -> the handoff lane (:net gateway/reclaim);
                //   LIMIT_SUB_AGENTS / NO_NEW_SUB_AGENTS / PAUSE_ACCELERATORS /
                //       NO_OPTIONAL_ACCELERATORS -> the budget consumer (:lib UI).
                //   START_RETRY_SCHEDULE -> [RetryLane], armed by
                //       PhoneDshHost.applyHostEffects (P15: it used to be a name
                //       with no owner, which is why Backoff was terminal);
                //   PERSIST_HOST_STATE -> [HostStateStore], performed by
                //       PhoneDshHost.applyHostEffects (P15: `persistedState` was
                //       a literal `null`, so every boot was a cold start);
                // Each is a named owner; none is a stub.
                else -> logger.debug("effect '${effect.label}' has no Notifier surface in this lane")
            }
        }
    }

    companion object {
        /** The boot-recovery notification; `ongoing` while the host is Recovering. */
        const val BOOT_RECOVERY_NOTIFICATION_ID: Int = 7401

        /** The terminal fail-loud notification. */
        const val HOST_FAILURE_NOTIFICATION_ID: Int = 7402
    }
}
