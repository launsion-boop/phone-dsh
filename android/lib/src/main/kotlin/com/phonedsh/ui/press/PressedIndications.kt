// Compose press indication for spec/ui/v1/interaction.md §6.
// SPDX-License-Identifier: MIT
//
// These are draw-only modifiers. They never change measurement, never scale,
// never add elevation and never install a Material ripple: callers pair them
// with `clickable(indication = null)` (the contract's rule 5). The press-in is
// animated by `motion.pressed`; release and cancel drop the target back to rest
// immediately (rule 1), so the table can never stay stuck in pressed.
package com.phonedsh.ui.press

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.addOutline
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.semantics
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.generated.TokenColorLiteral
import com.phonedsh.ui.theme.generated.UiTokenData

/**
 * The animated alpha exposed on the modifier's semantics node.
 *
 * It is the single observable value every Compose test reads: exactly the alpha
 * the draw pass paints. It is internal because it is a test/diagnostic seam, not
 * accessibility copy (an alpha has no meaningful spoken form).
 */
internal val PressedAlphaSemantics: SemanticsPropertyKey<Float> =
    SemanticsPropertyKey("PdshPressedAlpha")

/** The disabled/base fill alpha of [primaryPressed]; 1 enabled, 0.25 disabled. */
internal val PressedBackgroundAlphaSemantics: SemanticsPropertyKey<Float> =
    SemanticsPropertyKey("PdshPressedBackgroundAlpha")

private class PressedRender(
    val values: PressedValues,
    val alpha: State<Float>,
)

/**
 * Rule 2: a drawer/Bot pill paints a black capsule overlay at 0.06 while
 * pressed and nothing at rest.
 *
 * Rules 4-6: the overlay fades in with `motion.pressed`; release or cancel puts
 * the target back at rest immediately; a disabled control is forced to the
 * disabled row and never reaches the pressed alpha; drawing does not measure.
 *
 * Pair with `Modifier.clickable(interactionSource = …, indication = null)` so
 * the platform ripple cannot add a second feedback surface.
 */
@Composable
public fun Modifier.pillPressed(
    interactionSource: InteractionSource,
    enabled: Boolean = true,
): Modifier {
    val render = rememberPressed(PressedSurface.DrawerPill, interactionSource, enabled)
    val overlayColor = pillOverlayColor()
    return this
        .pressedAlphaSemantics(render)
        .drawWithContent {
            drawContent()
            val alpha = render.alpha.value
            if (alpha > 0f) {
                // iOS `Capsule()`: the corner radius is half the node height.
                drawRoundRect(
                    color = overlayColor.copy(alpha = overlayColor.alpha * alpha),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(
                        x = size.height / 2f,
                        y = size.height / 2f,
                    ),
                )
            }
        }
}

/**
 * Rule 2: a drawer/Bot row fills with `colors.userBubble` at 0.7 while pressed
 * and nothing at rest.
 *
 * [shape] is supplied by the row owner because §6 fixes the fill and alpha, not
 * the row's corner radius. Rules 4-6 behave exactly as [pillPressed]: animated
 * press-in, immediate rest on release/cancel, disabled never pressed, and no
 * measured-size change.
 *
 * Pair with `Modifier.clickable(interactionSource = …, indication = null)` so
 * the platform ripple cannot add a second feedback surface.
 */
@Composable
public fun Modifier.rowPressed(
    interactionSource: InteractionSource,
    enabled: Boolean = true,
    shape: Shape = RectangleShape,
): Modifier {
    val render = rememberPressed(PressedSurface.DrawerRow, interactionSource, enabled)
    val fill = LocalUiTokens.current.colors.userBubble
    return this
        .pressedAlphaSemantics(render)
        .drawBehind {
            val alpha = render.alpha.value
            if (alpha > 0f) {
                drawShape(shape, fill.copy(alpha = fill.alpha * alpha))
            }
        }
}

/**
 * Rule 3: the page primary pill dims its *whole content* to 0.8 while pressed;
 * when disabled only the capsule fill is 0.25, the label stays opaque.
 *
 * This overload owns the default `HomeSpec.primaryButton` fill and the capsule
 * shape, so adoption does not have to re-type either. It never removes a caller
 * background that was already in the chain; put it where the fill should be
 * painted.
 *
 * Rules 4-6: press-in uses `motion.pressed`, release/cancel returns to rest
 * immediately, disabled can never enter pressed, and the graphics layer changes
 * no measured size or scale.
 */
@Composable
public fun Modifier.primaryPressed(
    interactionSource: InteractionSource,
    enabled: Boolean = true,
    shape: Shape = androidx.compose.foundation.shape.RoundedCornerShape(percent = 50),
): Modifier = primaryPressed(
    interactionSource = interactionSource,
    backgroundColor = LocalUiTokens.current.colors.primaryButton,
    shape = shape,
    enabled = enabled,
)

/**
 * Rule 3 with an explicit fill (for a page whose primary role is not
 * `colors.primaryButton`). The same press/disabled rules as the default
 * overload apply.
 */
@Composable
public fun Modifier.primaryPressed(
    interactionSource: InteractionSource,
    backgroundColor: Color,
    shape: Shape,
    enabled: Boolean = true,
): Modifier {
    val render = rememberPressed(PressedSurface.PrimaryButton, interactionSource, enabled)
    val fill = if (enabled) {
        backgroundColor
    } else {
        backgroundColor.copy(alpha = backgroundColor.alpha * render.values.backgroundAlpha)
    }
    return this
        .pressedAlphaSemantics(render)
        // Report the contract alpha, not Color's 8-bit quantisation of it, so
        // the observable seam matches interaction.pressed.primaryDisabledOpacity.
        .semantics { this[PressedBackgroundAlphaSemantics] = render.values.backgroundAlpha }
        .graphicsLayer { alpha = render.alpha.value }
        .background(fill, shape)
}

@Composable
private fun rememberPressed(
    surface: PressedSurface,
    interactionSource: InteractionSource,
    enabled: Boolean,
): PressedRender {
    val isPressed by interactionSource.collectIsPressedAsState()
    val state = when {
        !enabled -> PressedState.Disabled
        isPressed -> PressedState.Pressed
        else -> PressedState.Rest
    }
    val values = PressedStyle.valuesFor(surface, state)
    val motion = LocalUiTokens.current.motion
    val alpha = animateFloatAsState(
        targetValue = values.alpha,
        // Rule 4 owns the press-in curve. Rule 1 says release/cancel is a state
        // drop, not a lingering press, so the release edge snaps back to rest.
        animationSpec = if (state == PressedState.Pressed) {
            tween(durationMillis = motion.pressedMs, easing = motion.pressedEasing)
        } else {
            snap()
        },
        label = "pdsh.${surface.id}.pressed",
    )
    return PressedRender(values, alpha)
}

private fun Modifier.pressedAlphaSemantics(render: PressedRender): Modifier =
    semantics { this[PressedAlphaSemantics] = render.alpha.value }

private fun DrawScope.drawShape(shape: Shape, color: Color) {
    val path = Path().apply {
        addOutline(shape.createOutline(size, layoutDirection, this@drawShape))
    }
    drawPath(path, color)
}

/**
 * `interaction.pressed.pillOverlayColor` is the literal `black`; the generated
 * enum keeps the spec spelling in one place. A new literal fails this `when`
 * instead of silently painting a different colour.
 */
private fun pillOverlayColor(): Color = when (UiTokenData.pressed.pillOverlayColor) {
    TokenColorLiteral.BLACK -> Color.Black
    TokenColorLiteral.CLEAR -> Color.Transparent
}
