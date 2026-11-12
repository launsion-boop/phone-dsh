// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

/**
 * Every timer the Bot page freezes (`ui-state.md` §4.11), in milliseconds.
 *
 * The page owns the scheduling; these constants are the one authority for the
 * values, so no page or test retypes a duration. The activity-line entries are
 * used by [BotActivityLineState]; the others are the page/task windows.
 */
public object BotTimers {
    /** Armed by a local send when no turn is running; expiry clears awaiting. */
    public const val AWAITING_TURN: Long = 120_000

    /** Runtime notice lifetime; a repeated failure re-arms it. */
    public const val RUNTIME_NOTICE: Long = 6_000

    /** Idle sleep window; any touch/send/turn start cancels it. */
    public const val IDLE_SLEEP: Long = 60_000

    /** Stream coalescer: at most one flush per window while text is pending. */
    public const val STREAM_COALESCE: Long = 100

    /** Live `textDelta` accumulator flush window. */
    public const val LIVE_TEXT_FLUSH: Long = 80

    /** One watch + turnProcesses + presentation poll per window when active. */
    public const val WATCH_POLL: Long = 800

    /** Minimum time an activity stays visible before a different one replaces it. */
    public const val ACTIVITY_MIN_VISIBLE: Long = 800

    /** Activity phrase rotation interval. */
    public const val ACTIVITY_ROTATION: Long = 2_400

    /** `· N 分钟` suffix boundary. */
    public const val MINUTE: Long = 60_000
}
