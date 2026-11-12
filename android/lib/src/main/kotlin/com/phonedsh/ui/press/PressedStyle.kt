// Pressed-state table from spec/ui/v1/interaction.md §6.
// SPDX-License-Identifier: MIT
//
// This file deliberately has no Compose runtime dependency: JVM tests drive the
// same rest/pressed/disabled table as the Compose modifiers, and every number
// comes from the generated `interaction.pressed` / `motion.pressed` values. The
// table's two rest alphas (transparent for an overlay, opaque for content) are
// rules 2 and 3, not token values.
package com.phonedsh.ui.press

import com.phonedsh.ui.theme.generated.UiTokenData

/**
 * The three surfaces in `golden/pressed-states.golden.json`.
 *
 * The [id] is the golden row id; [PressedSurface.fromId] is the only mapping the
 * contract test needs, so a new row or an unknown id fails loudly.
 */
public enum class PressedSurface(public val id: String) {
    /** Drawer and Bot-drawer pills: black overlay at [PressedValues.pressed]. */
    DrawerPill("drawerPill"),

    /** Drawer and Bot-drawer rows: `colors.userBubble` fill at [PressedValues.pressed]. */
    DrawerRow("drawerRow"),

    /** `HomePrimaryButtonStyle`: whole-content opacity at [PressedValues.pressed]. */
    PrimaryButton("primaryButton"),
    ;

    public companion object {
        /** Resolves a golden row id; an unknown id is a contract/code mismatch. */
        public fun fromId(id: String): PressedSurface =
            entries.firstOrNull { it.id == id }
                ?: error("unknown pressed-states golden row '$id'")
    }
}

/**
 * The state a pressed surface is in.
 *
 * [Disabled] exists so rule 6 can be expressed in the table: a disabled control
 * never takes the [Pressed] alpha, and its disabled value (when the surface has
 * one) belongs to the background fill, not to the content.
 */
public enum class PressedState {
    Rest,
    Pressed,
    Disabled,
}

/**
 * One row of the §6 rest / pressed / disabled table, resolved for [state].
 *
 * [rest] and [pressed] are the alphas the surface paints for rules 2 and 3.
 * [disabled] is the primary button's disabled *background* alpha (rule 3); it is
 * null for the two drawer surfaces, which have no disabled row.
 *
 * [scale] is the contract's no-scaling rule 5; it is always emitted from
 * `interaction.pressed.scale` so a spec change cannot leave this table behind.
 */
public data class PressedValues(
    public val surface: PressedSurface,
    public val state: PressedState,
    public val rest: Float,
    public val pressed: Float,
    public val disabled: Float?,
    public val scale: Float,
) {
    /**
     * The alpha the style paints for [state].
     *
     * Rule 6: [PressedState.Disabled] always stays at [rest]. For
     * [PressedSurface.PrimaryButton] the 0.25 disabled value is a background
     * alpha, so it is exposed through [backgroundAlpha] instead.
     */
    public val alpha: Float
        get() = if (state == PressedState.Pressed) pressed else rest

    /**
     * The background fill multiplier for [state].
     *
     * 1 while enabled, the table's [disabled] value when disabled. Surfaces with
     * no disabled row keep an opaque fill if a caller ever asks.
     */
    public val backgroundAlpha: Float
        get() = if (state == PressedState.Disabled) disabled ?: 1f else 1f
}

/**
 * Pure projection of `tokens.json#interaction.pressed` into the golden table.
 *
 * Rules implemented:
 * 1. the result has no lingering state: every call is a pure function of
 *    `surface` and `state`;
 * 2. pill overlay 0.06 / row fill 0.7;
 * 3. primary content 0.8 pressed, 0.25 disabled background;
 * 5. scale is the generated 1.0 (never a local scale);
 * 6. [PressedState.Disabled] can never resolve to the pressed alpha.
 */
public object PressedStyle {
    /** Resolves the full rest/pressed/disabled table for [surface] at [state]. */
    public fun valuesFor(surface: PressedSurface, state: PressedState): PressedValues {
        val pressed = UiTokenData.pressed
        return when (surface) {
            PressedSurface.DrawerPill -> PressedValues(
                surface = surface,
                state = state,
                rest = TRANSPARENT,
                pressed = pressed.pillOverlay,
                disabled = null,
                scale = pressed.scale,
            )

            PressedSurface.DrawerRow -> PressedValues(
                surface = surface,
                state = state,
                rest = TRANSPARENT,
                pressed = pressed.rowFillOpacity,
                disabled = null,
                scale = pressed.scale,
            )

            PressedSurface.PrimaryButton -> PressedValues(
                surface = surface,
                state = state,
                rest = OPAQUE,
                pressed = pressed.primaryPressedOpacity,
                disabled = pressed.primaryDisabledOpacity,
                scale = pressed.scale,
            )
        }
    }

    /** Rule 2's rest alpha for an overlay/fill: nothing painted. */
    private const val TRANSPARENT: Float = 0f

    /** Rule 3's rest alpha for whole content: fully opaque. */
    private const val OPAQUE: Float = 1f
}
