// The one back chain and the one predictive-back measurement.
// SPDX-License-Identifier: MIT
//
// `spec/ui/v1/README.md` §5 `back-gesture`: 系统预测性返回，页面栈逐级出栈，根页面退出应用；
// Android MAY 用预测性动画，state 变更序列 MUST 一致. `spec/platform/whitelist.json`
// `platform.predictive-back` names the mechanism (`OnBackInvokedCallback`, androidx's
// `OnBackPressedDispatcher`) and its evidence level (`emulator-probe`).
//
// This file owns the two things a Compose `BackHandler` call cannot express:
//
//   1. the *chain*. One gesture means, in order, close the drawer, step out of the
//      top route's own inner level (a sheet's sub-page, a folder drill-down, an
//      embedded preview — the route registers it on [PdshBackLevel]), pop the route
//      stack. Nothing else registers a back callback, so the order is one place.
//   2. the *measurement*. The manifest declares
//      `android:enableOnBackInvokedCallback="true"`; that is a build-time claim.
//      Whether this platform actually carries the gesture through the new path is
//      only observable when the platform sends an animation event
//      (`OnBackPressedCallback.handleOnBackStarted`, API 34+), so the settings row
//      reports what arrived instead of what the manifest asked for. See
//      [predictiveBackFact].
//
// Why the root case registers nothing: a callback that popped-and-finished would
// produce the same visible result, but it would take the task away from the
// platform's own predictive animation and from the multi-window/recents semantics
// that apply when the *system* ends an Activity. So `enabled` is false at the root
// and the platform's default (finish) runs.
package com.phonedsh.probe

import android.os.Build
import android.util.Log
import androidx.activity.BackEventCompat
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.LocalOnBackPressedDispatcherOwner
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.SettingsPlatformFacts

/**
 * The one system-back handler for the whole app.
 *
 * When [enabled] is false the callback is not registered at all, so the platform's
 * default behaviour runs: at the root route that is `finish()`, which is the
 * documented Android behaviour for "back at the start of the task" and the one the
 * predictive back-to-home animation is attached to.
 *
 * The animation overrides do not change what back *does*: they only record that the
 * platform delivered a predictive gesture, which is what [predictiveBackFact]
 * reports. A host that saw no gesture keeps saying 未知 rather than claiming the
 * manifest made it so.
 *
 * @param enabled whether any level of the chain can consume the gesture.
 * @param onBack consumes one level; only called when [enabled].
 */
@Composable
internal fun PdshBackHandler(enabled: Boolean, onBack: () -> Unit) {
    val dispatcher = LocalOnBackPressedDispatcherOwner.current?.onBackPressedDispatcher ?: return
    // The lambda closes over `nav`, which moves on every gesture; the callback is
    // registered once per `enabled` change, so it must read the latest lambda.
    val current = rememberUpdatedState(onBack)
    DisposableEffect(dispatcher, enabled) {
        if (!enabled) {
            return@DisposableEffect onDispose {}
        }
        val callback = object : OnBackPressedCallback(true) {
            override fun handleOnBackStarted(backEvent: BackEventCompat) {
                PredictiveBack.observeStarted(backEvent.progress)
            }

            override fun handleOnBackProgressed(backEvent: BackEventCompat) {
                PredictiveBack.observeProgressed(backEvent.progress)
            }

            override fun handleOnBackCancelled() {
                PredictiveBack.observeCancelled()
            }

            override fun handleOnBackPressed() {
                current.value()
            }
        }
        dispatcher.addCallback(callback)
        onDispose { callback.remove() }
    }
}

/**
 * What this process has observed about the platform's back path.
 *
 * `started`/`progressed`/`cancelled` are only ever called on API 34+ (the platform
 * has no `BackEvent` before that), and only for an app that opted in *and* a
 * gesture navigation mode that previews the destination. So one `started` event is
 * a proof of all three; its absence proves nothing (three-button navigation never
 * previews, and API 33 cannot send the event at all).
 */
internal object PredictiveBack {
    /** Composition-visible so the settings row moves on the first gesture. */
    private val started = mutableStateOf(false)

    /** The furthest the platform let the gesture travel, for the log line only. */
    private var maxProgress by mutableFloatStateOf(0f)

    /** True once the platform has driven this app's back gesture predictively. */
    val observedOnThisDevice: Boolean get() = started.value

    fun observeStarted(progress: Float) {
        maxProgress = maxOf(maxProgress, progress)
        if (!started.value) {
            started.value = true
            Log.i(TAG_BACK, "predictive back: platform delivered OnBackStarted (API ${Build.VERSION.SDK_INT})")
        }
    }

    fun observeProgressed(progress: Float) {
        maxProgress = maxOf(maxProgress, progress)
    }

    fun observeCancelled() {
        Log.i(TAG_BACK, "predictive back: gesture cancelled at progress=$maxProgress")
    }
}

/**
 * The 返回手势 row's value, from three readings rather than from one constant.
 *
 *   1. the manifest's opt-in ([MANIFEST_DECLARES_BACK_INVOKED], kept honest by
 *      `BackNavigationManifestTest`). No opt-in means the legacy path **by
 *      construction** — `NO`, and not an unread value.
 *   2. the platform. `OnBackInvokedDispatcher` does not exist before API 33, so a
 *      pre-13 device is a measured `NO`.
 *   3. this process's observation. On API 34+ an animation event is the only proof
 *      that the platform really routed the gesture through the invoker, so before
 *      the first one the row stays `UNKNOWN` — "declared" is not "supported", and
 *      this page must not print a claim the device has not made.
 *
 * API 33 is the one asymmetric case: `BackEvent` does not exist there, so no
 * observation is *possible* and waiting for one would print 未知 forever on a
 * working device. The declaration plus the platform's invoker is the whole reading,
 * so it is `YES`.
 *
 * @param sdkInt the device's API level (`Build.VERSION.SDK_INT` in production).
 * @param declared whether this build's manifest opts in.
 * @param observed whether this process has seen a predictive gesture.
 */
internal fun predictiveBackFact(
    sdkInt: Int = Build.VERSION.SDK_INT,
    declared: Boolean = MANIFEST_DECLARES_BACK_INVOKED,
    observed: Boolean = PredictiveBack.observedOnThisDevice,
): FactState = when {
    !declared -> FactState.NO
    sdkInt < Build.VERSION_CODES.TIRAMISU -> FactState.NO
    observed -> FactState.YES
    sdkInt >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> FactState.UNKNOWN
    else -> FactState.YES
}

/**
 * Re-reads the one runtime-dependent fact the settings sheet shows.
 *
 * `PdshNavFacts` is rebuilt from the engine's state, not from this probe, so the
 * probe is applied where the facts are handed to the router: one gesture then moves
 * the 返回手势 row without waiting for the next engine event.
 *
 * @param facts the host's snapshot, otherwise untouched.
 */
@Composable
internal fun PredictiveBack.measured(facts: PdshNavFacts): PdshNavFacts {
    // Composition-observed read: this is what makes the row move.
    val observed = observedOnThisDevice
    val fact = predictiveBackFact(
        sdkInt = Build.VERSION.SDK_INT,
        declared = MANIFEST_DECLARES_BACK_INVOKED,
        observed = observed,
    )
    val platform = facts.settings.platform ?: SettingsPlatformFacts()
    if (platform.predictiveBack == fact) return facts
    return facts.copy(
        settings = facts.settings.copy(platform = platform.copy(predictiveBack = fact)),
    )
}

/**
 * The manifest's opt-in, as a constant because the platform exposes no public
 * getter for it (`ApplicationInfo.enableOnBackInvokedCallback` is `@hide`).
 *
 * `BackNavigationManifestTest` parses `src/main/AndroidManifest.xml` and fails when
 * the attribute is missing or false, so this constant cannot drift from the file it
 * describes; the device test then checks the other half (that the platform really
 * delivers back through the invoker).
 */
internal const val MANIFEST_DECLARES_BACK_INVOKED: Boolean = true

/** Logcat tag for the back chain and its measurement. */
private const val TAG_BACK: String = "PDSHNav"
