// SPDX-License-Identifier: MIT
// The predictive-back observation the reference consumer shares with the host.
//
// `:lib` publishes `BackCoordinator` (the one layered back chain, `interaction.md`
// §4) and `PdshBackLevel` (the one level of back that lives *inside* a route).
// A host no longer writes a second `OnBackPressedCallback`: the platform
// dispatches a gesture to one enabled callback, so two chains would either
// never run or consume it twice. What the host still owns is the *measurement*
// half: `BackCoordinator` forwards predictive-gesture callbacks to the active
// `PushBackLayer`, and `observingBackLayer` records them for the 返回手势 row.
//
// The measurement is not decoration. Without a predictive animation event
// (API 34+) the row reports whatever the manifest claimed; with it the row says
// what the platform actually delivered.
//
// This file is the reference implementation from
// docs/design/android-aar-consumer-api-2026-11-02.md §5.2, kept here so the
// document's code is compiled and R8-processed by
// `:lib-consumer-test:assembleRelease` instead of drifting as prose.
package com.phonedsh.consumer


import android.os.Build
import android.util.Log
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.nav.PushBackLayer
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.SettingsPlatformFacts
import com.phonedsh.ui.theme.generated.TokenBackLayer

/**
 * Wraps one [PushBackLayer] so the coordinator's gesture callbacks also feed
 * [PredictiveBack].
 *
 * The coordinator calls `onPredictiveBack*` only on the topmost present layer's
 * delegate, which is exactly the gesture the person performed; the delegate
 * stays the only consumer of the back. A gesture at the root registers no
 * callback at all, and no observation is claimed for it.
 *
 * @param layer the generated layer this delegate owns.
 * @param onConsume the layer's own one-level back; `true` leaves the state alone.
 */
internal fun observingBackLayer(
    layer: TokenBackLayer,
    onConsume: () -> Boolean,
): PushBackLayer = object : PushBackLayer {
    override val layer: TokenBackLayer = layer

    override fun consumeBack(): Boolean = onConsume()

    override fun onPredictiveBackStarted() {
        PredictiveBack.observeStarted(0f)
    }

    override fun onPredictiveBackProgressed(progress: Float) {
        PredictiveBack.observeProgressed(progress)
    }

    override fun onPredictiveBackCancelled() {
        PredictiveBack.observeCancelled()
    }
}

/**
 * What this process has observed about the platform's back path.
 *
 * `started`/`progressed`/`cancelled` are only ever called on API 34+, and only
 * for an app that opted in and a gesture mode that previews the destination.
 * One `started` event proves all three; its absence proves nothing.
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
 * The 返回手势 row's value, from three readings rather than one constant.
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
 * Projects the measurement onto the facts the router reads.
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
 * `src/main/AndroidManifest.xml` carries
 * `android:enableOnBackInvokedCallback="true"`; `:app` keeps this honest with a
 * unit test that parses the XML. A host that cannot afford that test should
 * pass `declared` explicitly rather than trust a constant.
 */
internal const val MANIFEST_DECLARES_BACK_INVOKED: Boolean = true

/** Logcat tag for the back chain and its measurement. */
private const val TAG_BACK: String = "PDSHNav"
