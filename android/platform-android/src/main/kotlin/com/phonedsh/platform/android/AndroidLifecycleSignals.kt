// Lifecycle, battery, thermal and network readings from the Android OS.
// SPDX-License-Identifier: MIT
//
// The controller consumes one ordered stream instead of five platform streams
// (budgets.md §3), and the first frame every collector receives must be a
// LifecycleSnapshot with the current values: a controller started after boot
// would otherwise miss the state it booted into.
//
// Foreground/scene detection uses Application.ActivityLifecycleCallbacks, not
// androidx ProcessLifecycleOwner, so this module adds no AndroidX dependency.
// Consequence, stated rather than hidden: ActivityLifecycleCallbacks cannot
// replay the state of an activity that was already resumed, so a collector that
// subscribes before the first activity event gets a snapshot without
// AppForeground/ScenePhase. Construct the adapter in Application.onCreate -- the
// documented wiring -- where every activity event is still ahead; battery,
// thermal and network are readable immediately in any case.
//
// Retained-instance churn (a rotation) must not look like "went to background":
// the INACTIVE and BACKGROUND transitions are posted with a grace period and
// cancelled by the next onActivityStarted/onActivityResumed, which is the same
// debounce ProcessLifecycleOwner uses. Without it a rotation would emit
// BACKGROUND and the controller would start Draining (platform.scene-phase's
// rationale).

package com.phonedsh.platform.android

import android.app.Activity
import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import com.phonedsh.platform.AppForeground
import com.phonedsh.platform.Battery
import com.phonedsh.platform.LifecycleSignal
import com.phonedsh.platform.LifecycleSignals
import com.phonedsh.platform.LifecycleSnapshot
import com.phonedsh.platform.NetworkPath
import com.phonedsh.platform.ScenePhase
import com.phonedsh.platform.ThermalPressure
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

private const val TAG = "PhdShPlatform"

private const val KIND_FOREGROUND = "app-foreground"
private const val KIND_SCENE = "scene-phase"
private const val KIND_THERMAL = "thermal-pressure"
private const val KIND_BATTERY = "battery"
private const val KIND_NETWORK = "network-path"

/** The adapter's fixed startup order; input to state-machine initialization. */
private val SNAPSHOT_ORDER = listOf(
    KIND_FOREGROUND,
    KIND_SCENE,
    KIND_THERMAL,
    KIND_BATTERY,
    KIND_NETWORK,
)

/** Rotation grace period; matches ProcessLifecycleOwner's debounce. */
private const val BACKGROUND_GRACE_MILLIS = 700L

/**
 * [LifecycleSignals] over the Android framework.
 *
 * Registrations are per collector and released when collection stops, so two
 * collectors never share mutable counters and a test that calls `first()`
 * unregisters immediately.
 *
 * **Construct this adapter in `Application.onCreate`.** Activity callbacks
 * cannot replay an Activity that is already resumed, so an adapter created
 * after the first Activity started has no foreground reading; the contract is
 * that it registers its observers before the transitions it must report and
 * maintains its own last-known value from then on.
 *
 * The first snapshot carries only the kinds actually observed (see
 * [LifecycleSnapshot]): when no Activity callback has fired yet,
 * `AppForeground` and `ScenePhase` are **absent** from the snapshot. That is a
 * deliberate "unknown", not `false` / `BACKGROUND`; a consumer that treats the
 * absence as a default would turn a missing answer into an invented one.
 *
 * Readings: `Battery.lowPower` is `PowerManager.isPowerSaveMode` (refreshed on
 * `ACTION_POWER_SAVE_MODE_CHANGED` as well as `ACTION_BATTERY_CHANGED`);
 * `ThermalPressure` is `PowerManager.currentThermalStatus` (API 29+, otherwise
 * `NOMINAL` and a `thermal: api<29` log marker); `NetworkPath` is the
 * `ConnectivityManager` callback; foreground/scene come from the Activity
 * callbacks with the rotation grace period described above.
 *
 * @param context any context; the application context is used.
 * @param log diagnostic sink; receives the `thermal: api<29` fallback marker and
 *   permission failures. The default writes to logcat under [TAG].
 */
class AndroidLifecycleSignals(
    context: Context,
    private val log: (String) -> Unit = { message -> Log.d(TAG, message) },
) : LifecycleSignals {

    private val app: Application = context.applicationContext as Application

    override val events: Flow<LifecycleSignal> = callbackFlow {
        val collector = Collector(channel = this)
        val releases = mutableListOf<() -> Unit>()

        registerActivitySignals(collector, releases)
        registerBatterySignals(collector, releases)
        registerThermalSignals(collector, releases)
        registerNetworkSignals(collector, releases)

        // Every registration above only records into the collector while it is
        // not started; the snapshot therefore carries the freshest values and
        // is guaranteed to be the first frame even when a sticky broadcast was
        // delivered synchronously during registration. Kinds that were never
        // observed (foreground/scene before the first Activity callback) are
        // absent from it on purpose: unknown is not a default value.
        collector.start()

        awaitClose {
            releases.forEach { release ->
                try {
                    release()
                } catch (ignored: Exception) {
                    // Unregistering twice is not worth failing the stream over.
                }
            }
        }
    }

    // ---- foreground / scene ---------------------------------------------

    private fun registerActivitySignals(
        collector: Collector,
        releases: MutableList<() -> Unit>,
    ) {
        val handler = Handler(Looper.getMainLooper())
        var startedActivities = 0
        var resumedActivities = 0

        val inactive = Runnable {
            if (resumedActivities == 0 && startedActivities > 0) {
                collector.record(KIND_SCENE, ScenePhase(ScenePhase.Phase.INACTIVE))
            }
        }
        val background = Runnable {
            if (startedActivities == 0) {
                collector.record(KIND_SCENE, ScenePhase(ScenePhase.Phase.BACKGROUND))
                collector.record(KIND_FOREGROUND, AppForeground(false))
            }
        }

        val callbacks = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit

            override fun onActivityStarted(activity: Activity) {
                startedActivities++
                handler.removeCallbacks(background)
                collector.record(KIND_FOREGROUND, AppForeground(true))
            }

            override fun onActivityResumed(activity: Activity) {
                resumedActivities++
                handler.removeCallbacks(inactive)
                handler.removeCallbacks(background)
                collector.record(KIND_SCENE, ScenePhase(ScenePhase.Phase.ACTIVE))
            }

            override fun onActivityPaused(activity: Activity) {
                resumedActivities = (resumedActivities - 1).coerceAtLeast(0)
                if (resumedActivities == 0) {
                    handler.removeCallbacks(inactive)
                    handler.postDelayed(inactive, BACKGROUND_GRACE_MILLIS)
                }
            }

            override fun onActivityStopped(activity: Activity) {
                startedActivities = (startedActivities - 1).coerceAtLeast(0)
                if (startedActivities == 0) {
                    handler.removeCallbacks(background)
                    handler.postDelayed(background, BACKGROUND_GRACE_MILLIS)
                }
            }

            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

            override fun onActivityDestroyed(activity: Activity) = Unit
        }

        app.registerActivityLifecycleCallbacks(callbacks)
        releases += {
            handler.removeCallbacks(inactive)
            handler.removeCallbacks(background)
            app.unregisterActivityLifecycleCallbacks(callbacks)
        }
    }

    // ---- battery ---------------------------------------------------------

    private fun registerBatterySignals(
        collector: Collector,
        releases: MutableList<() -> Unit>,
    ) {
        val filter = IntentFilter(Intent.ACTION_BATTERY_CHANGED).apply {
            // Power-save mode is part of the Battery reading. Without this
            // action `Battery.lowPower` would only refresh on the next level or
            // charging change, so a user toggling battery saver would not be
            // observed until then.
            addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val reading = when (intent?.action) {
                    // ACTION_POWER_SAVE_MODE_CHANGED carries no battery extras,
                    // so it re-reads the sticky broadcast instead.
                    Intent.ACTION_BATTERY_CHANGED -> batteryOf(intent)
                    else -> currentBattery()
                }
                reading?.let { collector.record(KIND_BATTERY, it) }
            }
        }
        try {
            app.registerReceiver(receiver, filter)
            releases += { app.unregisterReceiver(receiver) }
        } catch (failure: RuntimeException) {
            log("battery: receiver registration failed")
            return
        }
        // The sticky broadcast is readable without a receiver; registering a
        // receiver also replays it, and the collector de-duplicates.
        currentBattery()?.let { collector.record(KIND_BATTERY, it) }
    }

    private fun currentBattery(): Battery? =
        batteryOf(app.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)))

    private fun batteryOf(intent: Intent?): Battery? {
        if (intent == null) return null
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (level < 0 || scale <= 0) return null
        val percent = (level * 100 / scale).coerceIn(0, 100)
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        // A reading, not a policy: the host decides what low-power mode means.
        val lowPower = app.getSystemService(PowerManager::class.java)?.isPowerSaveMode ?: false
        return Battery(percent = percent, charging = charging, lowPower = lowPower)
    }

    // ---- thermal ---------------------------------------------------------

    private fun registerThermalSignals(
        collector: Collector,
        releases: MutableList<() -> Unit>,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // The thermal API starts at API 29. Reporting a conservative
            // NOMINAL is the documented fallback; the marker keeps the
            // downgrade visible in logcat instead of silently fabricating a
            // reading.
            log("thermal: api<29")
            collector.record(KIND_THERMAL, ThermalPressure(ThermalPressure.Pressure.NOMINAL))
            return
        }
        val powerManager = app.getSystemService(Context.POWER_SERVICE) as? PowerManager
        if (powerManager == null) {
            log("thermal: power-manager-missing")
            collector.record(KIND_THERMAL, ThermalPressure(ThermalPressure.Pressure.NOMINAL))
            return
        }

        val listener = PowerManager.OnThermalStatusChangedListener { status ->
            collector.record(KIND_THERMAL, thermalPressure(status))
        }
        try {
            powerManager.addThermalStatusListener(listener)
            releases += { powerManager.removeThermalStatusListener(listener) }
        } catch (failure: RuntimeException) {
            log("thermal: listener registration failed")
        }
        collector.record(KIND_THERMAL, thermalPressure(powerManager.currentThermalStatus))
    }

    /**
     * Maps `PowerManager.THERMAL_STATUS_*` to the SPI's four levels.
     *
     * The constants are compared numerically because `THERMAL_STATUS_LIGHT` is
     * API 30 while the listener is API 29: NONE(0) and LIGHT(1) are NOMINAL,
     * MODERATE(2) FAIR, SEVERE(3) SERIOUS, and CRITICAL(4)/EMERGENCY(5)/
     * SHUTDOWN(6) CRITICAL.
     */
    private fun thermalPressure(status: Int): ThermalPressure = when (status) {
        0, 1 -> ThermalPressure(ThermalPressure.Pressure.NOMINAL)
        2 -> ThermalPressure(ThermalPressure.Pressure.FAIR)
        3 -> ThermalPressure(ThermalPressure.Pressure.SERIOUS)
        else -> ThermalPressure(ThermalPressure.Pressure.CRITICAL)
    }

    // ---- network ---------------------------------------------------------

    private fun registerNetworkSignals(
        collector: Collector,
        releases: MutableList<() -> Unit>,
    ) {
        val connectivity = app.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        if (connectivity == null) {
            log("network: connectivity-manager-missing")
            return
        }

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                collector.record(KIND_NETWORK, pathOf(connectivity.getNetworkCapabilities(network)))
            }

            override fun onLost(network: Network) {
                collector.record(KIND_NETWORK, NetworkPath(available = false, expensive = false))
            }

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) {
                collector.record(KIND_NETWORK, pathOf(networkCapabilities))
            }
        }

        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        try {
            connectivity.registerNetworkCallback(request, callback)
            releases += { connectivity.unregisterNetworkCallback(callback) }
        } catch (failure: SecurityException) {
            log("network: permission-missing")
            return
        } catch (failure: RuntimeException) {
            log("network: callback registration failed")
            return
        }

        val current = try {
            connectivity.getNetworkCapabilities(connectivity.activeNetwork)
        } catch (failure: SecurityException) {
            log("network: permission-missing")
            null
        }
        collector.record(KIND_NETWORK, pathOf(current))
    }

    private fun pathOf(capabilities: NetworkCapabilities?): NetworkPath {
        if (capabilities == null) return NetworkPath(available = false, expensive = false)
        return NetworkPath(
            available = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
            expensive = !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
        )
    }

    // ---- stream assembly -------------------------------------------------

    /**
     * Folds observer callbacks into one snapshot-first frame.
     *
     * `record` is called from the main thread, the connectivity thread and the
     * receiver thread, so the state and the "snapshot already sent" switch are
     * read under one lock: a change that arrives while the snapshot is being
     * built is either part of it or queued after it, never before it.
     */
    private class Collector(private val channel: SendChannel<LifecycleSignal>) {
        private val lock = Any()
        private val values = LinkedHashMap<String, LifecycleSignal>()
        private var started = false

        fun record(kind: String, signal: LifecycleSignal) {
            synchronized(lock) {
                if (values[kind] == signal) return
                values[kind] = signal
                if (started) channel.trySend(signal)
            }
        }

        fun start() {
            synchronized(lock) {
                val current = SNAPSHOT_ORDER.mapNotNull { kind -> values[kind] }
                channel.trySend(LifecycleSnapshot(current))
                started = true
            }
        }
    }
}
