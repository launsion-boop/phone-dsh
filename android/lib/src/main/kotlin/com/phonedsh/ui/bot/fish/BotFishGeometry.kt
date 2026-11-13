// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** The pose the Compose layer applies on the GPU (fish.md §7.2). */
public data class BotFishPose(
    public val offsetX: Double = 0.0,
    public val offsetY: Double = 0.0,
    public val roll: Double = 0.0,
    public val scaleX: Double = 1.0,
    public val scaleY: Double = 1.0,
)

/**
 * Frozen geometry constants (`BotFishRenderer.swift:93-199`, fish.md §7).
 * The FISH-1 decision in PC-20261112-android-bot-w4 §7 is represented by the
 * two distinct head-slice quanta: standard 0.1, lively 0.25.
 */
public object BotFishGeometry {
    public const val DESIGN_CANVAS: Double = 512.0
    public const val PAD: Double = 24.0
    public const val DESIGN_SCALE: Double = 464.0 / 1024.0

    public const val CROP_X: Double = 48.0
    public const val CROP_Y: Double = 30.0
    public const val CROP_SIDE: Double = 416.0
    public const val CROWNED_CROP_X: Double = 32.0
    public const val CROWNED_CROP_Y: Double = 10.0
    public const val CROWNED_CROP_SIDE: Double = 448.0

    public const val MOTION_BOOST_SMALL_SIZE: Double = 40.0
    public const val MOTION_BOOST_LARGE_SIZE: Double = 64.0
    public const val MOTION_BOOST_FACTOR: Double = 2.2
    public const val MOTION_BOOST_MAX_TRANSLATION: Double = 20.0
    public const val MOTION_BOOST_MAX_ROLL: Double = 9.0

    public const val HEAD_SLICING_MINIMUM_SIZE: Double = 40.0
    public const val LIVELY_HEAD_SLICING_MINIMUM_SIZE: Double = 24.0
    public const val HEAD_SLICE_QUANTUM: Double = 0.1
    public const val LIVELY_HEAD_SLICE_QUANTUM: Double = 0.25
    public const val HEAD_SLICE_SOURCE_SIZE: Double = 8.0

    public const val OFFSET_QUANTUM: Double = 0.25
    public const val ROLL_QUANTUM: Double = 0.1
    public const val ALPHA_QUANTUM: Double = 1.0 / 64.0

    public fun pixelSide(sizePt: Double, displayScale: Double): Int =
        max(1, ceil(max(1.0, sizePt) * max(1.0, displayScale)).toInt())

    public fun motionBoost(size: Double): Double {
        if (size <= MOTION_BOOST_SMALL_SIZE) return MOTION_BOOST_FACTOR
        if (size >= MOTION_BOOST_LARGE_SIZE) return 1.0
        val t = (size - MOTION_BOOST_SMALL_SIZE) /
            (MOTION_BOOST_LARGE_SIZE - MOTION_BOOST_SMALL_SIZE)
        return MOTION_BOOST_FACTOR + (1 - MOTION_BOOST_FACTOR) * t
    }

    public fun headSlicingEnabled(profile: BotFishMotionProfile, size: Double): Boolean =
        if (profile == BotFishMotionProfile.LIVELY) {
            size >= LIVELY_HEAD_SLICING_MINIMUM_SIZE
        } else {
            size > HEAD_SLICING_MINIMUM_SIZE
        }

    public fun headSliceQuantum(profile: BotFishMotionProfile): Double =
        if (profile == BotFishMotionProfile.LIVELY) {
            LIVELY_HEAD_SLICE_QUANTUM
        } else {
            HEAD_SLICE_QUANTUM
        }

    /** Pose quantisation from `BotFishEngine.pose` (`BotFishEngine.swift:643-667`). */
    public fun pose(params: BotFishParams, size: Double, pixelSide: Int, crowned: Boolean): BotFishPose {
        val target = max(1, pixelSide).toDouble()
        val cropSide = if (crowned) CROWNED_CROP_SIDE else CROP_SIDE
        val pixelScale = target / cropSide
        val pointsPerPixel = max(1.0, size) / target

        fun offset(value: Double): Double {
            val pixels = value * pixelScale
            return BotFishMath.roundHalfAway(pixels / OFFSET_QUANTUM) * OFFSET_QUANTUM * pointsPerPixel
        }

        val scaleQuantum = 0.5 / target
        fun scale(value: Double): Double =
            BotFishMath.roundHalfAway(value / scaleQuantum) * scaleQuantum

        return BotFishPose(
            offsetX = offset(params.x),
            offsetY = offset(params.y),
            roll = BotFishMath.roundHalfAway(params.roll / ROLL_QUANTUM) * ROLL_QUANTUM,
            scaleX = scale(params.sx * params.morphX),
            scaleY = scale(params.sy * params.morphY),
        )
    }

    public fun quantisedAlpha(value: Double): Double =
        BotFishMath.roundHalfAway(BotFishMath.clamp(value, 0.0, 1.0) * 64) / 64
}

/** Requested frame ceilings (`BotFishView.frameInterval`, fish.md §3.1). */
public object BotFishFrameClock {
    public const val STANDARD_FPS: Int = 20
    public const val STANDARD_SMALL_FPS: Int = 15
    public const val STANDARD_SMALL_MAX_SIZE_PT: Double = 40.0
    public const val LIVELY_FPS: Int = 30
    public const val DELTA_CLAMP_MS: Double = 100.0
    public const val FREEZE_SAMPLE_MS: Double = 650.0
    public const val BLINK_DURATION_MS: Double = 260.0
    public const val POSE_SPRING_OMEGA: Double = 18.0
    public const val POSE_TRANSITION_MS: Double = 320.0

    public fun intervalMilliseconds(
        sizePt: Double,
        profile: BotFishMotionProfile,
    ): Double = when {
        profile == BotFishMotionProfile.LIVELY -> 1000.0 / LIVELY_FPS
        sizePt <= STANDARD_SMALL_MAX_SIZE_PT -> 1000.0 / STANDARD_SMALL_FPS
        else -> 1000.0 / STANDARD_FPS
    }
}

/**
 * Quantised head-slice inputs and displacement. FISH-1 (`PC §7`) is carried
 * end to end: the same quantum quantises the signature and converts it back,
 * so `.lively` uses its coarser 0.25 cache step without shrinking the
 * displacement by 2.5× (the old 0.25/0.1 mismatch).
 */
public object BotFishHeadSlicing {
    public data class Signature(
        public val headX: Int = 0,
        public val headY: Int = 0,
        public val hairSway: Int = 0,
        public val earFlutter: Int = 0,
    ) {
        public val isIdentity: Boolean
            get() = headX == 0 && headY == 0 && hairSway == 0 && earFlutter == 0
    }

    public fun signature(
        params: BotFishParams,
        enabled: Boolean,
        quantum: Double,
    ): Signature {
        if (!enabled) return Signature()
        val step = if (quantum > 0) quantum else BotFishGeometry.HEAD_SLICE_QUANTUM
        fun quantise(value: Double): Int = BotFishMath.roundHalfAway(value / step).roundToInt()
        return Signature(
            headX = quantise(params.headX),
            headY = quantise(params.headY),
            hairSway = quantise(params.hairSway),
            earFlutter = quantise(params.earFlutter),
        )
    }

    /** Returns `(dx, dy)` in source (512-space) units for one 8px row. */
    public fun displacement(y: Double, signature: Signature, quantum: Double): Pair<Double, Double> {
        val headX = signature.headX * quantum
        val headY = signature.headY * quantum
        val hairSway = signature.hairSway * quantum
        val earFlutter = signature.earFlutter * quantum

        val v = BotFishMath.clamp((y - 365) / 65, 0.0, 1.0)
        val headWeight = 1 - v * v * (3 - 2 * v)
        val dx = headX * (4.5 + (350 - y) * 0.009) * headWeight +
            hairSway * max(0.0, (y - 310) / 160)
        val dy = headY * 2.8 * headWeight +
            earFlutter * exp(-((y - 245) / 45).let { it * it })
        return dx to dy
    }

    /** The output-pixel row bounds for one source slice. */
    public fun outputRow(
        y: Double,
        cropY: Double,
        pixelScale: Double,
        target: Int,
    ): Pair<Int, Int> {
        val nextY = min(BotFishGeometry.DESIGN_CANVAS, y + BotFishGeometry.HEAD_SLICE_SOURCE_SIZE)
        val yPixel = (y - cropY) * pixelScale
        val nextPixel = (nextY - cropY) * pixelScale
        val top = max(0, floor(yPixel).toInt())
        val bottom = min(target, floor(nextPixel).toInt())
        return top to bottom
    }
}
