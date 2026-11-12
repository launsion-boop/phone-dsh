// Compose glue for the layered back chain of `interaction.md` §4.
// SPDX-License-Identifier: MIT
//
// The state machine is [PushBackState]; this file owns only the platform
// callbacks. It registers the platform's predictive back handler when the
// generated `predictiveBack` token allows it, forwards gesture progress to the
// current top layer for its own preview, and commits by calling the *same*
// [dispatchBack] path as a non-predictive gesture. No state changes on progress
// or cancel (rule 6), and no transition duration is written here (rule 8): page
// transitions remain the platform NavigationStack/Compose transition.
package com.phonedsh.ui.nav

import androidx.activity.compose.BackHandler
import androidx.activity.compose.PredictiveBackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import com.phonedsh.ui.theme.generated.TokenBackLayer
import com.phonedsh.ui.theme.generated.TokenPredictiveBack
import com.phonedsh.ui.theme.generated.UiTokenData
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.collect

/**
 * One layer that can consume a back gesture before [PushBackState] applies its
 * own transition (`interaction.md` §4 rule 7).
 *
 * The coordinator calls [consumeBack] only while this layer is the topmost
 * present layer in `backOrder`. Returning `true` means the layer handled the
 * gesture and the state must not change; returning `false` lets the coordinator
 * close the overlay (or pop the stack/exit) normally.
 *
 * A sheet registers here and returns `true` while its inner `NavigationStack`
 * can pop, so the inner page leaves before the sheet closes. The drawer may
 * register to run its own close motion and report completion; it may also leave
 * [consumeBack] false and let the host drive `isOpen` through
 * [PushBackState.closeOverlay]. This interface deliberately references no sheet
 * or drawer implementation (wave 3 plugs them in).
 */
public interface PushBackLayer {
    /** The generated back layer this delegate owns. */
    public val layer: TokenBackLayer

    /** Consume one back inside the layer; `true` keeps the state unchanged. */
    public fun consumeBack(): Boolean

    /** Platform gesture started; only the top layer receives this. */
    public fun onPredictiveBackStarted(): Unit = Unit

    /** Platform gesture progress; must not mutate [PushBackState] (rule 6). */
    public fun onPredictiveBackProgressed(progress: Float): Unit = Unit

    /** Platform gesture cancelled; the state stays as it was (rule 6). */
    public fun onPredictiveBackCancelled(): Unit = Unit
}

/** The result of one committed back, including whether a registered layer consumed it. */
public data class BackDispatch(
    public val state: PushBackState,
    public val exited: Boolean,
    public val consumedByLayer: Boolean,
    public val layer: TokenBackLayer?,
)

/**
 * Apply one committed back to [state].
 *
 * This is the one transition shared by predictive commit and non-predictive back
 * (rule 6). The topmost registered layer gets the first refusal, then the state
 * machine consumes exactly one layer in `backOrder` (rule 5). The sheet's inner
 * stack therefore pops before the sheet closes (rule 7).
 */
public fun dispatchBack(
    state: PushBackState,
    layers: List<PushBackLayer> = emptyList(),
): BackDispatch {
    val top = state.topLayer()
    val delegate = top?.let { layer -> layers.firstOrNull { it.layer == layer } }
    if (delegate != null && delegate.consumeBack()) {
        return BackDispatch(state = state, exited = false, consumedByLayer = true, layer = top)
    }
    val result = state.back()
    return BackDispatch(
        state = result.state,
        exited = result.exited,
        consumedByLayer = false,
        layer = top,
    )
}

/**
 * Registers the host's one back callback and drives [PushBackState].
 *
 * Rules implemented here:
 *  * §4 rule 5 — [dispatchBack] consumes one layer through `backOrder`;
 *  * §4 rule 6 — [PredictiveBackHandler] progress is forwarded to the top layer
 *    without touching state; cancellation leaves state unchanged; the committed
 *    gesture calls the same [dispatchBack] as [BackHandler];
 *  * §4 rule 7 — a registered sheet layer is asked before the overlay closes;
 *  * §4 rule 8 — no transition duration or curve is set; the page transition is
 *    the platform's own.
 *
 * At the selected tab's root this composable registers nothing by default, so
 * the platform's own exit/back-to-home behaviour remains in charge. Pass
 * [onExit] to intercept that root instead (the callback then calls it after
 * [PushBackState.back] reports `exited`).
 *
 * @param state the current per-tab push state.
 * @param onStateChange receives the state after every committed transition; a
 *   layer that consumes the gesture leaves the state unchanged and publishes
 *   nothing.
 * @param layers delegates for overlay/inner-stack layers, in any order.
 * @param onExit called when a root back is committed, or `null` to leave the
 *   root to the platform.
 * @param enabled whether the callback is registered; defaults to "any non-root
 *   layer is present, or a root exit handler was supplied".
 */
@Composable
public fun BackCoordinator(
    state: PushBackState,
    onStateChange: (PushBackState) -> Unit,
    layers: List<PushBackLayer> = emptyList(),
    onExit: (() -> Unit)? = null,
    enabled: Boolean = state.canConsumeBack || onExit != null,
) {
    val latestState by rememberUpdatedState(state)
    val latestLayers by rememberUpdatedState(layers)
    val latestOnStateChange by rememberUpdatedState(onStateChange)
    val latestOnExit by rememberUpdatedState(onExit)

    fun commitBack() {
        val result = dispatchBack(latestState, latestLayers)
        // A layer that consumed the gesture owns the transition; the state is
        // required to stay unchanged, so there is nothing to publish.
        if (!result.consumedByLayer) latestOnStateChange(result.state)
        if (result.exited) latestOnExit?.invoke()
    }

    if (UiTokenData.push.predictiveBack == TokenPredictiveBack.ALLOWED) {
        PredictiveBackHandler(enabled = enabled) { progress ->
            val top = latestState.topLayer()
            val delegate = top?.let { layer -> latestLayers.firstOrNull { it.layer == layer } }
            delegate?.onPredictiveBackStarted()
            try {
                progress.collect { event ->
                    delegate?.onPredictiveBackProgressed(event.progress)
                }
                // The gesture committed: the same transition as a plain back.
                commitBack()
            } catch (cancelled: CancellationException) {
                delegate?.onPredictiveBackCancelled()
                throw cancelled
            }
        }
    } else {
        BackHandler(enabled = enabled) { commitBack() }
    }
}
