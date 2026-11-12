// Per-tab push stacks and the layered back chain of `interaction.md` §4.
// SPDX-License-Identifier: MIT
//
// This file is deliberately free of Compose runtime dependencies: the JVM
// contract test drives the same state machine the coordinator uses. Layer order,
// root behaviour and tab-bar visibility are read from the generated
// `interaction.push` table; no contract number is repeated here.
package com.phonedsh.ui.nav

import com.phonedsh.ui.theme.generated.TokenBackLayer
import com.phonedsh.ui.theme.generated.TokenPushRootBack
import com.phonedsh.ui.theme.generated.UiTokenData

/** One overlay above the selected tab's stack, in the contract's back-layer vocabulary. */
public enum class PushOverlay(public val layer: TokenBackLayer) {
    /** A modal bottom sheet (`interaction.md` §4 rule 5). */
    SHEET(TokenBackLayer.SHEET),

    /** The session drawer (`interaction.md` §4 rule 5, §1 rule 9). */
    DRAWER(TokenBackLayer.DRAWER),
    ;

    /** The generated spec spelling (`sheet` / `drawer`). */
    public val spec: String get() = layer.spec
}

/** The state after consuming one back layer, plus whether the host must exit. */
public data class PushBackResult(
    public val state: PushBackState,
    public val exited: Boolean,
)

/**
 * Per-tab stack depths and the ordered overlay set for `interaction.md` §4.
 *
 * The state machine implements:
 *  * rule 1 — one independent stack per tab; switching tabs never clears the
 *    target tab's depth;
 *  * rule 2 — [selectTab] returns the same value for the current tab, so a
 *    re-tap can never pop to root;
 *  * rule 3 — [push] adds one, [pop] removes one, and [back] at the root exits;
 *  * rule 4 — [tabBarVisible] is true only for the selected tab at depth 0 with
 *    the keyboard hidden, from `barVisibleAtRoot` / `barHiddenWhenPushed`;
 *  * rule 5 — [back] consumes exactly one layer in `backOrder`: sheet, drawer,
 *    stack, root;
 *  * rule 6 — [predictiveProgress] and [predictiveCancel] change nothing; a
 *    committed gesture calls [back], the same transition as a non-predictive
 *    gesture.
 *
 * Depths for tabs without a pushed page are omitted from [stackDepths] and read
 * as zero through [depthOf].
 */
public data class PushBackState(
    public val selectedTab: HomeTab = HomeTab.TASKS,
    public val stackDepths: Map<HomeTab, Int> = emptyMap(),
    public val overlays: List<PushOverlay> = emptyList(),
    public val keyboardVisible: Boolean = false,
) {
    init {
        require(stackDepths.values.all { it >= 0 }) { "stack depth cannot be negative: $stackDepths" }
    }

    /** The selected tab's stack depth (rule 1). */
    public val depth: Int get() = depthOf(selectedTab)

    /** One tab's stack depth; a tab never visited is at its root. */
    public fun depthOf(tab: HomeTab): Int = stackDepths[tab] ?: 0

    /** Rule 4: the bottom bar follows the selected tab only. */
    public val tabBarVisible: Boolean
        get() {
            val visibleAtRoot = UiTokenData.push.barVisibleAtRoot
            val visibleAtDepth = depth == 0 || !UiTokenData.push.barHiddenWhenPushed
            return visibleAtRoot && visibleAtDepth && !keyboardVisible
        }

    /** True when a callback must be registered to consume a non-root layer. */
    public val canConsumeBack: Boolean get() = overlays.isNotEmpty() || depth > 0

    /** The topmost present layer in the generated `backOrder` (rule 5). */
    public fun topLayer(): TokenBackLayer? {
        for (layer in UiTokenData.push.backOrder) {
            val present = when (layer) {
                TokenBackLayer.SHEET -> PushOverlay.SHEET in overlays
                TokenBackLayer.DRAWER -> PushOverlay.DRAWER in overlays
                TokenBackLayer.STACK -> depth > 0
                TokenBackLayer.ROOT -> true
            }
            if (present) return layer
        }
        return null
    }

    /** Rule 3: push one page on [tab], defaulting to the selected tab. */
    public fun push(tab: HomeTab = selectedTab): PushBackState =
        copy(stackDepths = stackDepths + (tab to depthOf(tab) + 1))

    /**
     * Rule 3: pop one page from [tab]. A root stack is left unchanged; exiting
     * from the root is [back], not a negative depth.
     */
    public fun pop(tab: HomeTab = selectedTab): PushBackState {
        val current = depthOf(tab)
        if (current <= 0) return this
        val next = stackDepths.toMutableMap()
        if (current == 1) next.remove(tab) else next[tab] = current - 1
        return copy(stackDepths = next.toMap())
    }

    /** Rule 1/2: switch tabs without touching either stack; a re-tap is a no-op. */
    public fun selectTab(tab: HomeTab): PushBackState =
        if (tab == selectedTab) this else copy(selectedTab = tab)

    /** Rule 5: open an overlay layer. Re-opening the same layer changes nothing. */
    public fun openOverlay(overlay: PushOverlay): PushBackState {
        if (overlay in overlays) return this
        return copy(overlays = (overlays + overlay).sortedBy(::backOrderIndex))
    }

    /** Rule 5: close one overlay layer without touching stack depth. */
    public fun closeOverlay(overlay: PushOverlay): PushBackState =
        if (overlay !in overlays) this else copy(overlays = overlays - overlay)

    /** Rule 4: the keyboard is part of tab-bar visibility, not of the stack. */
    public fun withKeyboardVisible(visible: Boolean): PushBackState =
        if (visible == keyboardVisible) this else copy(keyboardVisible = visible)

    /**
     * Rule 5: consume exactly one layer. A sheet/drawer closes first, then the
     * selected tab's stack pops, then the root exits when `rootBack` is `exit`.
     */
    public fun back(): PushBackResult = when (topLayer()) {
        null -> PushBackResult(this, exited = false)
        TokenBackLayer.SHEET -> PushBackResult(closeOverlay(PushOverlay.SHEET), exited = false)
        TokenBackLayer.DRAWER -> PushBackResult(closeOverlay(PushOverlay.DRAWER), exited = false)
        TokenBackLayer.STACK -> PushBackResult(pop(), exited = false)
        TokenBackLayer.ROOT -> PushBackResult(
            state = this,
            exited = UiTokenData.push.rootBack == TokenPushRootBack.EXIT,
        )
    }

    /** Rule 6: gesture progress never changes depth or overlays. */
    public fun predictiveProgress(@Suppress("UNUSED_PARAMETER") progress: Float): PushBackState = this

    /** Rule 6: a cancelled gesture leaves the state exactly as it was. */
    public fun predictiveCancel(): PushBackState = this

    private fun backOrderIndex(overlay: PushOverlay): Int {
        val index = UiTokenData.push.backOrder.indexOf(overlay.layer)
        return if (index < 0) Int.MAX_VALUE else index
    }
}
