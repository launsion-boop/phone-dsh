// SPDX-License-Identifier: MIT
// The system-back chain a host must own, in the form a consumer can paste.
//
// `:lib` publishes `PdshBackLevel` (the one level of back that lives *inside* a
// route) but, as of 0.1.0, no handler: `:app`'s implementation
// (`android/app/src/main/kotlin/com/phonedsh/probe/BackNavigation.kt`) is an
// app-level file and is `internal`. Every consumer therefore writes this, and
// the two ways to get it wrong are the two things this file gets right:
//
//   1. the root route registers NOTHING. `enabled` is false when no level can be
//      consumed, so the platform's default (`finish()`) runs together with the
//      predictive back-to-home animation. A callback that popped-and-finished
//      would look the same and steal that animation.
//   2. the callback is registered once per `enabled` change but must call the
//      *latest* `onBack`: `nav` moves on every gesture, so the lambda is read
//      through `rememberUpdatedState`.
//
// The measurement half is not decoration. The 返回手势 row of the settings sheet
// reports what the platform actually delivered, and the only proof is a
// predictive-back animation event (API 34+). Without this, the host reports
// whatever its manifest claimed.
//
// This file is the reference implementation from
// docs/design/android-aar-consumer-api-2026-11-02.md §5.2, kept here so the
// document's code is compiled and R8-processed by
// `:lib-consumer-test:assembleRelease` instead of drifting as prose.
package com.phonedsh.consumer

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
 * The one system-back handler for the whole host.
 *
 * @param enabled whether any level of the chain can consume the gesture. When
 *   false no callback is registered at all.
 * @param onBack consumes one level; only called when [enabled].
 */
@Composable
internal fun PdshBackHandler(enabled: Boolean, onBack: () -> Unit) {
    val dispatcher = LocalOnBackPressedDispatcherOwner.current?.onBackPressedDispatcher ?: return
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
