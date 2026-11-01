// phone-dsh Android — :controller driving signals (D14 table, budgets.md §3).
// SPDX-License-Identifier: MIT

package com.phonedsh.controller

/**
 * A driving input of the D14 transition table plus the observation signals of
 * budgets.md §3. A signal is a fact, not a request: the machine rejects it when
 * the current state has no matching row or the row's guard does not hold.
 *
 * Thermal, battery and non-terminal engine states are observations: they never
 * change the nine-state host state, but they carry the policy effects of §3.
 */
sealed interface ControllerSignal {
    /** Stable label used in transition records, rejections and test failures. */
    val label: String

    // ---- scene / engine / restart -------------------------------------------------

    data class ScenePhaseChanged(val phase: ScenePhase) : ControllerSignal {
        override val label: String get() = "scenePhase(${phase.wireName})"
    }

    /**
     * Engine state changed. [wasForeground] is meaningful only for
     * [EngineHostState.TERMINATED]; a background termination is not a
     * `Running -> Recovering` edge (budgets.md §2).
     */
    data class EngineStateChanged(
        val state: EngineHostState,
        val wasForeground: Boolean,
    ) : ControllerSignal {
        override val label: String
            get() = "engineState(${state.wireName}, foreground=$wasForeground)"
    }

    /** Planned WebContent restart at a tool-call boundary (budgets.md §4). */
    data object PlannedRestartRequested : ControllerSignal {
        override val label: String get() = "plannedRestart"
    }

    // ---- drain --------------------------------------------------------------------

    /** The drain work settled early and the epoch close completed. */
    data object DrainCompleted : ControllerSignal {
        override val label: String get() = "drainCompleted"
    }

    /** The injected 20 s drain deadline was reached (budgets.md §1). */
    data object DrainDeadlineElapsed : ControllerSignal {
        override val label: String get() = "drainDeadlineElapsed"
    }

    /** The OS background task expired; it forces the drain deadline early. */
    data object BackgroundTaskExpired : ControllerSignal {
        override val label: String get() = "backgroundTaskExpired"
    }

    // ---- network ------------------------------------------------------------------

    data class NetworkPathChanged(val status: NetworkPathStatus) : ControllerSignal {
        override val label: String get() = "networkPath(${status.wireName})"
    }

    /** The model upstream answered with an HTTP status. */
    data class UpstreamUnavailable(val statusCode: Int) : ControllerSignal {
        override val label: String get() = "upstreamUnavailable($statusCode)"
    }

    /** The `Retry-After` window of the current `Backoff` elapsed. */
    data object RetryAfterElapsed : ControllerSignal {
        override val label: String get() = "retryAfterElapsed"
    }

    /**
     * One probe succeeded. The lease result travels with it because
     * `Backoff -> Running` reopens admission "after a lease check" and has no
     * other signal that could carry the result.
     */
    data class RetryProbeSucceeded(val leaseVerified: Boolean) : ControllerSignal {
        override val label: String get() = "retryProbeSucceeded(leaseVerified=$leaseVerified)"
    }

    // ---- lease --------------------------------------------------------------------

    /** Result of the lease verification required by `Recovering -> Running`. */
    data class LeaseCheckResult(val verified: Boolean) : ControllerSignal {
        override val label: String get() = "leaseCheckResult(verified=$verified)"
    }

    // ---- handoff / reclaim --------------------------------------------------------

    /** Handoff decision while foreground or draining. */
    data object HandoffRequested : ControllerSignal {
        override val label: String get() = "handoffRequested"
    }

    /** The fence CAS installed the remote generation. */
    data object HandoffFenceInstalled : ControllerSignal {
        override val label: String get() = "handoffFenceInstalled"
    }

    /** Remote accepted fence, snapshot and segments and opened its admission. */
    data class HandoffCompleted(val remoteAdmissionOpen: Boolean) : ControllerSignal {
        override val label: String get() = "handoffCompleted(remoteAdmissionOpen=$remoteAdmissionOpen)"
    }

    /** Handoff failed after a successful fence; the token must be reclaimed. */
    data object HandoffFailed : ControllerSignal {
        override val label: String get() = "handoffFailed"
    }

    /** User request or foreground return asks to reclaim authority. */
    data object ReclaimRequested : ControllerSignal {
        override val label: String get() = "reclaimRequested"
    }

    /** The reclaim response and returned segments were applied. */
    data object ReclaimResponseApplied : ControllerSignal {
        override val label: String get() = "reclaimResponseApplied"
    }

    /** The new fence is persisted and the epoch is closed. */
    data class ReclaimCompleted(
        val fencePersisted: Boolean,
        val epochClosed: Boolean,
    ) : ControllerSignal {
        override val label: String
            get() = "reclaimCompleted(fencePersisted=$fencePersisted, epochClosed=$epochClosed)"
    }

    // ---- failure / reset ----------------------------------------------------------

    /** An unrecoverable condition: any state -> Failed, fail loud. */
    data class FailureRaised(
        val reason: ControllerFailure,
        val detail: String? = null,
    ) : ControllerSignal {
        override val label: String
            get() = if (detail == null) "failure(${reason.code})" else "failure(${reason.code}: $detail)"
    }

    /** The only exit from Failed: an explicit user reset. */
    data object UserReset : ControllerSignal {
        override val label: String get() = "userReset"
    }

    // ---- policy observations (never a D14 transition) -----------------------------

    data class ThermalStateChanged(val pressure: ThermalPressure) : ControllerSignal {
        override val label: String get() = "thermalState(${pressure.wireName})"
    }

    data class BatteryChanged(val snapshot: BatterySnapshot) : ControllerSignal {
        override val label: String
            get() = "battery(level=${snapshot.levelPercent}, charging=${snapshot.charging}, lowPower=${snapshot.lowPowerMode})"
    }
}
