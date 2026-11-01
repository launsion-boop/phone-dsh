// phone-dsh Android — :controller transition records, outcomes and boot result.
// SPDX-License-Identifier: MIT

package com.phonedsh.controller

/** One accepted D14 transition, the unit observers and tests consume. */
data class TransitionRecord(
    val from: HostState,
    val to: HostState,
    /** Stable signal label, for example `scenePhase(background)`. */
    val signal: String,
    /** Logical controller time in milliseconds; no wall clock is read here. */
    val atMillis: Long,
    /** Admission after the transition; open only when [to] is `Running`. */
    val admission: Admission,
    /** The D14 actions of the row, in execution order. */
    val effects: List<ControllerEffect>,
    /** Boot label or the explicit user reset reason, otherwise `null`. */
    val reason: String? = null,
)

/** Why a signal was refused. */
enum class RejectionReason {
    /** The (state, signal) pair is not a row of the D14 table. */
    ILLEGAL_TRANSITION,

    /** The row exists but its guard did not hold. */
    GUARD_FAILED,

    /** `Draining -> Parked` on the 20 s deadline before the clock reached it. */
    DEADLINE_NOT_REACHED,
}

/** Result of feeding one signal to the state machine. */
sealed interface SignalOutcome {
    /** A D14 row was taken; the state and admission changed. */
    data class Transitioned(val record: TransitionRecord) : SignalOutcome

    /**
     * The signal is an observation (thermal, battery, a non-terminal engine
     * state, a deadline that still owes its epoch close) and changed no state.
     */
    data class Observed(
        val signal: String,
        val effects: List<ControllerEffect>,
        val note: String,
    ) : SignalOutcome

    /** The signal was refused; state, admission and the transition log are unchanged. */
    data class Rejected(
        val from: HostState,
        val signal: String,
        val reason: RejectionReason,
        val detail: String,
    ) : SignalOutcome
}

/**
 * The D14 boot mapping. Boot is a pure function of the persisted record, not an
 * edge out of a live state, so it does not appear in [ControllerStateMachine.transitions].
 */
data class BootResult(
    val state: HostState,
    val disposition: BootDisposition,
    val reason: String,
    val admission: Admission,
    val effects: List<ControllerEffect>,
)
