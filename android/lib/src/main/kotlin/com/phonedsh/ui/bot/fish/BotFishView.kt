// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.profile.BotFishAppearance
import kotlinx.coroutines.isActive
import kotlin.math.roundToInt

/**
 * The Compose BotFish view. Its frozen inputs mirror the iOS façade in
 * `spec/ui/v1/bot/fish/fish.md` §2.1: lifecycle, size, appearance and crown.
 * `paused` is the Android equivalent of the environment pause key and keeps
 * one frozen frame; `still`, `reducedMotion`, `reaction`, `motionProfile` and
 * `workStyle` are the same optional view inputs the iOS view exposes.
 *
 * The requested frame ceiling follows fish.md §3.1: 15 fps for standard
 * avatars <= 40 pt, 20 fps above, 30 fps for `.lively`. It is a ceiling, not a
 * promise of delivery.
 */
@Composable
public fun BotFishView(
    lifecycle: BotFishLifecycle,
    appearance: BotFishAppearance = BotFishAppearance.CLASSIC,
    crowned: Boolean = false,
    size: Dp,
    paused: Boolean = false,
    modifier: Modifier = Modifier,
    still: Boolean = false,
    reducedMotion: Boolean = false,
    reaction: BotFishReaction? = null,
    motionProfile: BotFishMotionProfile = BotFishMotionProfile.STANDARD,
    workStyle: BotFishWorkStyle = BotFishWorkStyle.GENERIC,
) {
    val context = LocalContext.current
    val density = LocalDensity.current
    val renderer = remember(context.assets) { BotFishRenderer(context.assets) }
    val engine = remember { BotFishEngine() }
    var frame by remember { mutableStateOf<BotFishFrame?>(null) }
    var layers by remember { mutableStateOf<BotFishLayers?>(null) }

    val sizePt = size.value.toDouble()
    val displayScale = density.density.toDouble()

    LaunchedEffect(
        paused, lifecycle, appearance, crowned, size, still, reducedMotion,
        reaction?.id, motionProfile, workStyle, displayScale,
    ) {
        fun drawFrame(deltaMs: Double) {
            val next = engine.advanceBy(
                deltaMs = deltaMs,
                state = lifecycle,
                still = still,
                reducedMotion = reducedMotion,
                sizePt = sizePt,
                displayScale = displayScale,
                appearance = appearance,
                crowned = crowned,
                reaction = reaction,
                profile = motionProfile,
                workStyle = workStyle,
            )
            frame = next
            layers = renderer.render(
                frame = next,
                sizePt = sizePt,
                displayScale = displayScale,
                appearance = appearance,
                crowned = crowned,
                profile = motionProfile,
            )
        }

        if (paused || still || reducedMotion) {
            // One frozen frame. The next recomposition only replaces it when
            // an input above changes, so a paused avatar schedules nothing.
            engine.resetClock()
            drawFrame(0.0)
            return@LaunchedEffect
        }

        engine.resetClock()
        val intervalNanos =
            (BotFishFrameClock.intervalMilliseconds(sizePt, motionProfile) * 1_000_000).toLong()
        var lastDrawNanos = 0L
        while (isActive) {
            withFrameNanos { now ->
                if (lastDrawNanos == 0L || now - lastDrawNanos >= intervalNanos) {
                    val deltaMs = if (lastDrawNanos == 0L) {
                        0.0
                    } else {
                        (now - lastDrawNanos) / 1_000_000.0
                    }
                    lastDrawNanos = now
                    drawFrame(deltaMs)
                }
            }
        }
    }

    Canvas(
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            .semantics { contentDescription = "Bot 头像" }
            .graphicsLayer { alpha = frame?.alpha?.toFloat() ?: 1f },
    ) {
        val currentFrame = frame
        val currentLayers = layers
        if (currentFrame == null || currentLayers == null) return@Canvas

        val side = this.size.minDimension
        val target = side.roundToInt().coerceAtLeast(1)
        val pivot = Offset(
            x = side / 2f,
            y = side * (if (crowned) (340.0 / 448.0) else (320.0 / 416.0)).toFloat(),
        )
        val offsetX = (currentFrame.pose.offsetX * density.density).toFloat()
        val offsetY = (currentFrame.pose.offsetY * density.density).toFloat()

        withTransform({
            translate(offsetX + pivot.x, offsetY + pivot.y)
            rotate(currentFrame.pose.roll.toFloat())
            scale(currentFrame.pose.scaleX.toFloat(), currentFrame.pose.scaleY.toFloat())
            translate(-pivot.x, -pivot.y)
        }) {
            drawImage(
                image = currentLayers.base,
                dstOffset = IntOffset.Zero,
                dstSize = IntSize(target, target),
            )
            drawImage(
                image = currentLayers.face,
                dstOffset = IntOffset.Zero,
                dstSize = IntSize(target, target),
            )
        }
    }
}
