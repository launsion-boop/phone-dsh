// Host contract 1 — the session goal projection.
// SPDX-License-Identifier: MIT
package com.phonedsh.agentcore

/**
 * The session's current goal projection, or `null` when the session has none.
 *
 * `blocked_reason` is required exactly when [phase] is [Phase.BLOCKED] and is
 * forbidden otherwise; the constructor and [HarnessJson] both enforce that.
 */
public data class HarnessGoal(
    public val objective: String,
    public val phase: Phase,
    public val roundsStarted: Long,
    public val maxGoalRounds: Long,
    /** Why the goal is blocked; non-null exactly when [phase] is [Phase.BLOCKED]. */
    public val blockedReason: String? = null,
) {
    init {
        require((phase == Phase.BLOCKED) == (blockedReason != null)) {
            "blocked_reason is required exactly when phase is blocked (phase=$phase, blockedReason=$blockedReason)"
        }
    }

    /** The four phases; `blocked` is the only one that carries a reason. */
    public enum class Phase(public val wire: String) {
        ACTIVE("active"),
        PAUSED("paused"),
        BLOCKED("blocked"),
        COMPLETE("complete"),
        ;

        public companion object {
            public fun fromWire(wire: String): Phase? = entries.firstOrNull { it.wire == wire }
        }
    }
}
