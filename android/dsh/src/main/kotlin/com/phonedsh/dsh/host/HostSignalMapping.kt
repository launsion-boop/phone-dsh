// phone-dsh — :dsh / com.phonedsh.dsh.host: platform signals to D14 signals.
// SPDX-License-Identifier: MIT
//
// budgets.md §3 names five OS inputs: scenePhase, thermalState, battery/low-power
// mode, NWPathMonitor and the app foreground flag. :platform flattens them into
// one ordered stream (`LifecycleSignals.events`); the D14 table speaks
// `ControllerSignal`. This file is that translation and nothing else: pure
// functions, no clock, no I/O, no state.
//
// Two mappings are deliberately lossy, and the loss is written down instead of
// being smoothed over:
//   * `NetworkPath.expensive` has no D14 row (no budget change follows from it),
//     so it is dropped;
//   * `:platform.Battery` carries `lowPower` (added when the Android adapter landed),
//     so the controller snapshot passes it through unchanged. It is never derived from
//     the percentage: a guess and a reading are different inputs.
//
// Engine states are mapped for the same reason: D14 only has an edge for
// termination, but the controller must see the state to record it, and the facade
// needs `Running` to know when the lease probe may run.

package com.phonedsh.dsh.host

import com.phonedsh.controller.BatterySnapshot
import com.phonedsh.controller.ControllerSignal
import com.phonedsh.controller.NetworkPathStatus
import com.phonedsh.controller.EngineHostState as ControllerEngineState
import com.phonedsh.controller.ScenePhase as ControllerScenePhase
import com.phonedsh.controller.ThermalPressure as ControllerThermalPressure
import com.phonedsh.platform.AppForeground
import com.phonedsh.platform.Battery
import com.phonedsh.platform.EngineHostState
import com.phonedsh.platform.LifecycleSignal
import com.phonedsh.platform.LifecycleSnapshot
import com.phonedsh.platform.NetworkPath
import com.phonedsh.platform.ScenePhase
import com.phonedsh.platform.ThermalPressure

/** The `:platform` -> `:controller` translation used by [DefaultPhoneDshHost]. */
internal object HostSignalMapping {
    /**
     * The D14 signal for [signal], or `null` when it has no `ControllerSignal`.
     *
     * Two variants answer `null`:
     * - `AppForeground` is not a D14 input: it only decides `wasForeground` on an
     *   engine termination;
     * - `LifecycleSnapshot` is the batch frame the facade expands before it maps
     *   its members, so a snapshot itself never becomes one controller signal.
     */
    fun from(signal: LifecycleSignal): ControllerSignal? = when (signal) {
        is ScenePhase -> ControllerSignal.ScenePhaseChanged(scenePhase(signal.phase))
        is ThermalPressure -> ControllerSignal.ThermalStateChanged(thermalPressure(signal.pressure))
        is Battery -> ControllerSignal.BatteryChanged(battery(signal))
        is NetworkPath -> ControllerSignal.NetworkPathChanged(networkPath(signal))
        is AppForeground -> null
        is LifecycleSnapshot -> null
    }

    fun scenePhase(phase: ScenePhase.Phase): ControllerScenePhase = when (phase) {
        ScenePhase.Phase.ACTIVE -> ControllerScenePhase.ACTIVE
        ScenePhase.Phase.INACTIVE -> ControllerScenePhase.INACTIVE
        ScenePhase.Phase.BACKGROUND -> ControllerScenePhase.BACKGROUND
    }

    fun thermalPressure(pressure: ThermalPressure.Pressure): ControllerThermalPressure = when (pressure) {
        ThermalPressure.Pressure.NOMINAL -> ControllerThermalPressure.NOMINAL
        ThermalPressure.Pressure.FAIR -> ControllerThermalPressure.FAIR
        ThermalPressure.Pressure.SERIOUS -> ControllerThermalPressure.SERIOUS
        ThermalPressure.Pressure.CRITICAL -> ControllerThermalPressure.CRITICAL
    }

    fun battery(battery: Battery): BatterySnapshot = BatterySnapshot(
        levelPercent = battery.percent,
        charging = battery.charging,
        // Passed through, never derived: see the file header.
        lowPowerMode = battery.lowPower,
    )

    /**
     * `available = true` is `satisfied`; every other path is `unsatisfied`
     * (budgets §3, and `NetworkPath`'s own contract: it is false for the
     * "requires connection" case as well).
     *
     * `REQUIRES_CONNECTION` is never produced here: the controller rejects it as a
     * `Running -> Backoff` edge, so emitting it would only manufacture rejects.
     */
    fun networkPath(path: NetworkPath): NetworkPathStatus =
        if (path.available) NetworkPathStatus.SATISFIED else NetworkPathStatus.UNSATISFIED

    /**
     * The controller's engine vocabulary.
     *
     * `Failed` is `TERMINATED` because that is the one engine event D14 has a row
     * for (`Running/Draining -> Recovering`, restart the worker). `Recovering` is
     * `STARTING`: it is a non-terminal engine state and only an observation to the
     * controller, whose own `Recovering` is a different notion (it waits for the
     * lease, not for the page).
     */
    fun engineState(state: EngineHostState): ControllerEngineState = when (state) {
        EngineHostState.Stopped -> ControllerEngineState.STOPPED
        EngineHostState.Starting -> ControllerEngineState.STARTING
        is EngineHostState.Running -> ControllerEngineState.READY
        EngineHostState.Recovering -> ControllerEngineState.STARTING
        is EngineHostState.Failed -> ControllerEngineState.TERMINATED
    }

    /** The `engine state` driving signal; [foreground] is the last `AppForeground`. */
    fun engine(state: EngineHostState, foreground: Boolean): ControllerSignal =
        ControllerSignal.EngineStateChanged(engineState(state), wasForeground = foreground)
}
