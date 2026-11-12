// Send and stop keys from spec/ui/v1/interaction.md §5.
// SPDX-License-Identifier: MIT
//
// Both keys are the 36 pt `geometry.sendButton` circle; the click target is the
// circle itself (rule 5), not a larger transparent box. The send key's enabled
// appearance enters with `motion.composerSend` from `scale = 0.8` and
// `opacity = 0`; the disabled appearance stays visible underneath it (rules 3,
// 4). The stop key is static and shares no transition with the send key (rule 6).
package com.phonedsh.ui.composer

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.AnimationVector1D
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.ChatMetrics
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.icon.PdshIcon
import com.phonedsh.ui.icon.PdshIconView
import com.phonedsh.ui.theme.LocalUiDarkTheme
import com.phonedsh.ui.theme.LocalUiTokens

/** Stable tags for the two layers the transition test needs to address. */
internal object ComposerSendTags {
    const val SEND_ENABLED_LAYER: String = "pdsh.composer.send.enabled"
}

/**
 * Rule 4's transition state.
 *
 * `progress` is 0 for the disabled appearance (`transitionScale`/opacity from
 * the token group) and 1 for the enabled appearance. It is keyed on
 * `canSubmit` only, so editing draft text with an unchanged `canSubmit` never
 * restarts the animation.
 */
@Stable
internal class ComposerSendTransition {
    internal val progress: Animatable<Float, AnimationVector1D> =
        Animatable(0f)
    private val startCount = mutableIntStateOf(0)

    /** Number of launched transitions; the test seam for "did typing restart it?". */
    internal val animationStarts: Int get() = startCount.intValue

    internal suspend fun animateTo(target: Float, animationSpec: AnimationSpec<Float>) {
        startCount.intValue += 1
        progress.animateTo(targetValue = target, animationSpec = animationSpec)
    }
}

/**
 * The send key.
 *
 * Rule 2's result is passed as [canSubmit]; the key is disabled (and still
 * drawn, rule 3) when it is false. Rules 5 and 7 put the click on the 36 pt
 * circle and the verbatim label on the same node.
 *
 * @param canSubmit rule 2's value: whether this key may submit.
 * @param turnRunning a turn is running, which selects the steer/queue label.
 * @param steer the running turn is in steer mode.
 * @param onClick submit the draft; never called while [canSubmit] is false.
 */
@Composable
public fun PdshSendButton(
    canSubmit: Boolean,
    turnRunning: Boolean,
    steer: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    ComposerSendButton(
        canSubmit = canSubmit,
        turnRunning = turnRunning,
        steer = steer,
        onClick = onClick,
        modifier = modifier,
        transition = remember { ComposerSendTransition() },
    )
}

/**
 * The send key with an injectable transition.
 *
 * This is the production implementation; the public overload only supplies a
 * remembered [ComposerSendTransition]. Tests pass their own so the animation
 * start count and progress are observable on the JVM.
 */
@Composable
internal fun ComposerSendButton(
    canSubmit: Boolean,
    turnRunning: Boolean,
    steer: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    transition: ComposerSendTransition,
) {
    val tokens = LocalUiTokens.current
    val dark = LocalUiDarkTheme.current
    val composer = tokens.composerSend
    val palette = composerSendPalette(composer, dark)
    val durationMs = composer.motion.durationMs
    val easing = tokens.motion.easing(composer.motion.curve)
    val spec = tween<Float>(durationMillis = durationMs, easing = easing)

    // Rule 4: the value is canSubmit, never the draft text.
    LaunchedEffect(canSubmit) {
        transition.animateTo(target = if (canSubmit) 1f else 0f, animationSpec = spec)
    }

    val size = tokens.geometry.sendButtonDiameter
    Box(
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            .clickable(enabled = canSubmit, role = Role.Button, onClick = onClick)
            .testTag(UiTags.COMPOSER_SEND)
            .semantics { contentDescription = ComposerSendRule.sendLabel(turnRunning, steer) },
        contentAlignment = Alignment.Center,
    ) {
        // Rules 3 and 4: the disabled key is always drawn; the enabled
        // appearance fades/scales over it. Neither layer changes the 36 pt box.
        SendAppearance(
            fill = palette.disabledFill,
            ink = palette.disabledInk,
            modifier = Modifier.matchParentSize(),
        )
        Box(
            modifier = Modifier
                .matchParentSize()
                .graphicsLayer {
                    val scale = ComposerSendRule.transitionScale(transition.progress.value)
                    val alpha = ComposerSendRule.transitionAlpha(transition.progress.value)
                    scaleX = scale
                    scaleY = scale
                    this.alpha = alpha
                }
                .testTag(ComposerSendTags.SEND_ENABLED_LAYER),
        ) {
            SendAppearance(
                fill = palette.enabledFill,
                ink = palette.enabledInk,
                modifier = Modifier.matchParentSize(),
            )
        }
    }
}

/**
 * The stop key.
 *
 * Rule 6: this composable has no transition; it is drawn at the same 36 pt size
 * and the same `primaryButton`/`primaryButtonInk` roles throughout. Rule 7:
 * [stopping] only changes the verbatim label and suppresses the repeat tap, as
 * the iOS `stopButton` guards `!stopping`.
 *
 * @param onClick stop the running turn; ignored while [stopping].
 * @param stopping a stop request is in flight (`正在停止`).
 */
@Composable
public fun PdshStopButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    stopping: Boolean = false,
) {
    val tokens = LocalUiTokens.current
    val dark = LocalUiDarkTheme.current
    val composer = tokens.composerSend
    val palette = composerSendPalette(composer, dark)
    val size = tokens.geometry.sendButtonDiameter
    Box(
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            .clickable(role = Role.Button) { if (!stopping) onClick() }
            .testTag(UiTags.COMPOSER_STOP)
            .semantics { contentDescription = ComposerSendRule.stopLabel(stopping) },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .matchParentSize()
                .background(color = palette.enabledFill, shape = CircleShape),
        )
        Box(
            modifier = Modifier
                .size(ChatMetrics.STOP_GLYPH_PT.dp)
                .background(
                    color = palette.enabledInk,
                    shape = RoundedCornerShape(ChatMetrics.STOP_GLYPH_RADIUS_PT.dp),
                ),
        )
    }
}

/**
 * Rule 1's trailing action cluster: the stop key first, then the send key
 * [ComposerSendRule.STOP_SEND_GAP] away when both are visible.
 *
 * Wave 3's pages should replace their hand-built send/stop `Row` with this
 * composable so the visibility truth table has one implementation.
 *
 * @param canSubmit rule 2's value, resolved by the host through
 *   [ComposerSendRule.canSubmit].
 * @param turnRunning a turn is running (rule 1's visibility branch).
 * @param steer the running turn is in steer mode (rule 7's label).
 */
@Composable
public fun PdshComposerSendKeys(
    canSubmit: Boolean,
    turnRunning: Boolean,
    steer: Boolean,
    onSend: () -> Unit,
    onStop: () -> Unit,
    modifier: Modifier = Modifier,
    stopping: Boolean = false,
) {
    val layout = ComposerSendRule.layout(turnRunning = turnRunning, canSubmit = canSubmit)
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(ComposerSendRule.STOP_SEND_GAP),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (layout.stopVisible) {
            PdshStopButton(onClick = onStop, stopping = stopping)
        }
        if (layout.sendVisible) {
            PdshSendButton(
                canSubmit = canSubmit,
                turnRunning = turnRunning,
                steer = steer,
                onClick = onSend,
            )
        }
    }
}

@Composable
private fun SendAppearance(
    fill: androidx.compose.ui.graphics.Color,
    ink: androidx.compose.ui.graphics.Color,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier.background(color = fill, shape = CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        PdshIconView(
            icon = PdshIcon.SEND,
            size = ChatMetrics.SEND_GLYPH_PT.dp,
            tint = ink,
            contentDescription = null,
        )
    }
}
