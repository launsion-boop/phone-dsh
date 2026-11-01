// phone-dsh Android — :controller host lifecycle vocabulary (D14, budgets.md §1–§3).
// SPDX-License-Identifier: MIT

package com.phonedsh.controller

/** Admission as published to the loopback layer. It is open only in [HostState.RUNNING]. */
enum class Admission(val wireName: String) {
    OPEN("open"),
    CLOSED("closed"),
}

/**
 * The nine D14 host states (budgets.md §1). The set is closed: the transition
 * table of §2 ends with "No other edge exists", and `HostStateTest` asserts
 * exactly [COUNT] entries.
 *
 * Admission is not an independent field. It is derived from the state, so a
 * side effect cannot observe an admitted state that the transition table did
 * not produce.
 */
enum class HostState(val wireName: String, val admission: Admission) {
    RUNNING("Running", Admission.OPEN),
    DRAINING("Draining", Admission.CLOSED),
    PARKED("Parked", Admission.CLOSED),
    RECOVERING("Recovering", Admission.CLOSED),
    BACKOFF("Backoff", Admission.CLOSED),
    HANDING_OFF("HandingOff", Admission.CLOSED),
    REMOTE("Remote", Admission.CLOSED),
    RECLAIMING("Reclaiming", Admission.CLOSED),
    FAILED("Failed", Admission.CLOSED),
    ;

    companion object {
        /** Number of D14 states; the closed set is asserted by the tests. */
        const val COUNT: Int = 9

        /** The fixture vocabulary (`Running`, `Draining`, ...), or `null`. */
        fun fromWireName(name: String): HostState? = entries.firstOrNull { it.wireName == name }

        fun requireWireName(name: String): HostState =
            fromWireName(name) ?: throw IllegalArgumentException("unknown D14 host state: $name")
    }
}

/** App lifecycle phase, the `scenePhase` signal of budgets.md §3. */
enum class ScenePhase(val wireName: String) {
    ACTIVE("active"),
    INACTIVE("inactive"),
    BACKGROUND("background"),
}

/** NWPathMonitor status, the `NWPathMonitor` row of budgets.md §3. */
enum class NetworkPathStatus(val wireName: String) {
    SATISFIED("satisfied"),
    UNSATISFIED("unsatisfied"),
    REQUIRES_CONNECTION("requiresConnection"),
}

/** ProcessInfo thermal levels of budgets.md §3. */
enum class ThermalPressure(val wireName: String) {
    NOMINAL("nominal"),
    FAIR("fair"),
    SERIOUS("serious"),
    CRITICAL("critical"),
}

/** Engine (WebContent / Worker) lifecycle state, the `engine state` driving signal. */
enum class EngineHostState(val wireName: String) {
    STOPPED("stopped"),
    STARTING("starting"),
    READY("ready"),
    TERMINATED("terminated"),
}

/**
 * Battery and low-power-mode snapshot (budgets.md §3): below 20 % while not
 * charging, or Low Power Mode on, caps sub-agents at one and disables optional
 * accelerators. Budgets are never raised by this signal.
 */
data class BatterySnapshot(
    val levelPercent: Int?,
    val charging: Boolean,
    val lowPowerMode: Boolean,
) {
    init {
        require(levelPercent == null || levelPercent in 0..100) {
            "levelPercent must be in 0..100 or null, was $levelPercent"
        }
    }

    /** `true` when the low-battery / low-power policy of budgets.md §3 applies. */
    val constrained: Boolean
        get() = lowPowerMode || (levelPercent != null && levelPercent < LOW_BATTERY_PERCENT && !charging)

    companion object {
        const val LOW_BATTERY_PERCENT: Int = 20
    }
}

/**
 * Why a process booted (Swift `HostBootDisposition`). The disposition is a
 * label on the boot mapping; it is not a tenth state.
 */
enum class BootDisposition(val wireName: String) {
    COLD_START("cold_start"),
    CRASH_RECOVERY("crash_recovery"),
    PARKED_RESUME("parked_resume"),
    USER_RESET("user_reset"),
    ;

    companion object {
        fun fromWireName(name: String): BootDisposition? = entries.firstOrNull { it.wireName == name }
    }
}

/**
 * The `any state -> Failed` conditions of budgets.md §2. They are a closed
 * vocabulary so a failure can be recorded without inventing prose.
 */
enum class ControllerFailure(val code: String) {
    WAL_CORRUPT("WAL_CORRUPT"),
    UNREPAIRED_BASE_MISMATCH("UNREPAIRED_BASE_MISMATCH"),
    MATERIALIZATION_IO("MATERIALIZATION_IO_FAILURE"),
    QUOTA_EXCEEDED("QUOTA_STILL_EXCEEDED_AFTER_COMPACTION"),
    MEMORY_HARD_CAP("MEMORY_HARD_CAP_AFTER_BUDGET_ACTIONS"),
    HOST_DEFECT("UNRECOVERABLE_HOST_DEFECT"),
}
