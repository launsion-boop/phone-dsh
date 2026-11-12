// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.bot.fish.BotFishLifecycle

/**
 * The inputs of the single shared fish-lifecycle projection frozen by the
 * owner decision UI-1 and normatively specified in `ui-state.md` §4.7.
 *
 * @property running the runtime's own truth: `liveRunning ∨ remoteBusy ∨
 *   routineRunning`; the page's local equivalent is
 *   `runningTurnID != null ∨ live != null`.
 * @property liveTurn a live turn exists. `ended` live states still count here;
 *   the page clears [livePresentation] separately.
 * @property durablePresentation the durable presentation; null/absent members
 *   default to `idle` and no one-shot.
 */
public data class BotFishProjectionInput(
    public val pendingApprovalCount: Int = 0,
    public val running: Boolean = false,
    public val idleSleeping: Boolean = false,
    public val livePresentation: BotRuntimePresentation? = null,
    public val durablePresentation: BotRuntimePresentation? = null,
    public val liveTurn: Boolean = false,
    public val now: Long,
)

/**
 * UI-1: one fish-lifecycle projection for the page header, the chat page and
 * the roster (`ui-state.md` §4.7). Priority, first match wins:
 *
 * 1. a pending approval -> [BotFishLifecycle.ALERTING];
 * 2. an unexpired one-shot; the live presentation's one-shot is checked first,
 *    then the durable presentation's (the last live one-shot is honoured after
 *    the live turn settles, until the durable projection catches up);
 * 3. base: the live presentation's `fishState` when [BotFishProjectionInput.liveTurn]
 *    is true and the live presentation exists, else the durable presentation's
 *    `fishState` (absent -> `idle`);
 * 4. `running` coerces base `idle` to `working` and never changes a non-idle base;
 * 5. not running and `idleSleeping` -> `sleeping`;
 * 6. otherwise base.
 *
 * Pending approval outranks everything, including an unexpired one-shot.
 */
public object BotFishProjection {
    public fun resolve(input: BotFishProjectionInput): BotFishLifecycle {
        if (input.pendingApprovalCount > 0) return BotFishLifecycle.ALERTING
        val oneShot = unexpiredOneShot(input.livePresentation, input.now)
            ?: unexpiredOneShot(input.durablePresentation, input.now)
        if (oneShot != null) return oneShot.state
        val base = if (input.liveTurn && input.livePresentation != null) {
            input.livePresentation.fishState
        } else {
            input.durablePresentation?.fishState ?: BotFishLifecycle.IDLE
        }
        if (input.running) {
            return if (base == BotFishLifecycle.IDLE) BotFishLifecycle.WORKING else base
        }
        if (input.idleSleeping) return BotFishLifecycle.SLEEPING
        return base
    }

    private fun unexpiredOneShot(
        presentation: BotRuntimePresentation?,
        now: Long,
    ): com.phonedsh.bot.fish.BotFishOneShot? =
        presentation?.oneShot?.takeIf { now < it.endsAt }

    /** Convenience overload with named scalars; same rule as [resolve]. */
    public fun resolve(
        pendingApprovalCount: Int,
        running: Boolean,
        idleSleeping: Boolean,
        livePresentation: BotRuntimePresentation?,
        durablePresentation: BotRuntimePresentation?,
        liveTurn: Boolean,
        now: Long,
    ): BotFishLifecycle = resolve(
        BotFishProjectionInput(
            pendingApprovalCount = pendingApprovalCount,
            running = running,
            idleSleeping = idleSleeping,
            livePresentation = livePresentation,
            durablePresentation = durablePresentation,
            liveTurn = liveTurn,
            now = now,
        )
    )
}
