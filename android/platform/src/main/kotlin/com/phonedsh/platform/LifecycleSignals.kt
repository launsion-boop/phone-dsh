// OS lifecycle and resource signals, flattened into one ordered stream.
// SPDX-License-Identifier: MIT
//
// budgets.md §3 lists scenePhase, thermalState, battery/low-power mode and
// NWPathMonitor as the OS inputs that drive D14. Android reports them through
// the Activity lifecycle callbacks, PowerManager/BatteryManager and
// ConnectivityManager; the controller consumes this single Flow instead of five
// platform streams, so a JVM test can drive the transition table with
// FakePlatform.emit(...).
//
// AppForeground is deliberately separate from ScenePhase: Android "app went to
// background" and "Activity was recreated" are different events, and
// platform.scene-phase's rationale forbids conflating them (a rotation must not
// trigger Draining).

package com.phonedsh.platform

import kotlinx.coroutines.flow.Flow

/**
 * One observation of an OS resource the host state machine depends on.
 *
 * Every variant except [LifecycleSnapshot] is a change event, not a query.
 * Implementations publish the current state through [LifecycleSnapshot] when
 * observation starts and individual change events afterwards.
 */
sealed interface LifecycleSignal

/**
 * The current value of every signal the adapter has actually read, delivered as
 * the first frame after subscription.
 *
 * [signals] carries **only** members whose value is known. A signal the adapter
 * has not observed yet is **absent**, never present with a fabricated default:
 * "unknown" and "known to be false / 0" are different inputs to the host state
 * machine, and a default silently turns an unanswered question into a claim.
 * Consumers must treat an absent member as unknown (defer, or keep the previous
 * decision) and must not substitute a default of their own.
 *
 * The order of [signals] is the adapter's fixed startup order; it is an input
 * to state-machine initialization, not an accident of map iteration. A snapshot
 * never contains another snapshot and carries at most one value per signal
 * kind.
 */
data class LifecycleSnapshot(val signals: List<LifecycleSignal>) : LifecycleSignal {
    init {
        require(signals.none { it is LifecycleSnapshot }) {
            "a LifecycleSnapshot cannot contain another LifecycleSnapshot"
        }
        require(signals.distinctBy { it.javaClass }.size == signals.size) {
            "a LifecycleSnapshot carries at most one value per signal kind"
        }
    }
}

/** Frontmost/interactive state, mapped from the platform scene lifecycle. */
data class ScenePhase(val phase: Phase) : LifecycleSignal {
    enum class Phase { ACTIVE, INACTIVE, BACKGROUND }
}

/**
 * Thermal pressure, mapped from the platform thermal API.
 *
 * Android's thermal levels are coarser than iOS's; the adapter's mapping table
 * (including the value used when the reading is unavailable) is policy above
 * this interface and must be conservative (plan §7.10).
 */
data class ThermalPressure(val pressure: Pressure) : LifecycleSignal {
    enum class Pressure { NOMINAL, FAIR, SERIOUS, CRITICAL }
}

/**
 * Battery snapshot.
 *
 * [percent] is 0...100. An unknown reading must not be emitted as a made-up
 * value: withhold the signal and let the adapter's documented conservative
 * default apply instead.
 *
 * [charging] is the OS charging state. [lowPower] is the OS low-power /
 * power-save mode (Android `PowerManager.isPowerSaveMode`). Both are readings,
 * not policy: the host decides what a low-power reading means, and the adapter
 * must not derive it from [percent].
 */
data class Battery(
    val percent: Int,
    val charging: Boolean,
    val lowPower: Boolean,
) : LifecycleSignal {
    init {
        require(percent in 0..100) { "percent must be 0...100, was $percent" }
    }
}

/**
 * Network reachability.
 *
 * [available] is `false` for every non-satisfied path, including the platform's
 * "requires connection" case: the controller goes to Backoff on `false` and
 * reopens admission only after a successful probe on `true` (budgets §3).
 */
data class NetworkPath(val available: Boolean, val expensive: Boolean) : LifecycleSignal

/** Whether the application process is in the foreground. */
data class AppForeground(val foreground: Boolean) : LifecycleSignal

/**
 * The OS signals the host observes.
 *
 * The stream is hot. The **first** element every collector receives is exactly
 * one [LifecycleSnapshot] carrying the current value of each signal the
 * implementation can read (the snapshot may be empty when no reading is
 * available yet). Later elements are the individual change events and are
 * never another snapshot on the same subscription. Without this frame a
 * controller started after boot would miss the state it booted into, and two
 * adapters would drift on the initial ordering.
 *
 * A snapshot carries only the signals already observed: a member that cannot be
 * read yet is **absent**, never a fabricated default (see [LifecycleSnapshot]).
 * Consumers must treat absence as unknown, not as `false` / `0`.
 *
 * Wiring requirement: an adapter registers its observers before the first
 * transition it has to report and then maintains its own last-known value. The
 * Android adapter must therefore be constructed in `Application.onCreate`:
 * activity callbacks cannot replay an Activity that is already resumed, so an
 * adapter created later legitimately has no foreground reading yet -- and says
 * so by omitting `AppForeground`/`ScenePhase` from the snapshot instead of
 * guessing.
 */
interface LifecycleSignals {
    val events: Flow<LifecycleSignal>
}
