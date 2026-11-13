// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import com.phonedsh.bot.fish.BotFishLifecycle
import kotlin.math.floor

/** One keyframe of a [BotFishLivelyTrack] (fish.md §5.5). */
public data class BotFishLivelyKeyframe(public val phase: Double, public val value: Double)

/** A looping scalar keyframe track. */
public class BotFishLivelyTrack(keys: List<Pair<Double, Double>>) {
    private val keys: List<BotFishLivelyKeyframe> =
        keys.map { BotFishLivelyKeyframe(it.first, it.second) }

    public fun valueAt(phase: Double): Double {
        val first = keys.firstOrNull() ?: return 0.0
        val last = keys.lastOrNull() ?: return 0.0
        val p = phase - floor(phase)
        if (p <= first.phase) return first.value
        if (p >= last.phase) return last.value
        for (index in 1 until keys.size) {
            val a = keys[index - 1]
            val b = keys[index]
            if (p > b.phase) continue
            val span = b.phase - a.phase
            val eased = if (span <= 0) 1.0 else BotFishMath.smooth((p - a.phase) / span)
            return BotFishMath.lerp(a.value, b.value, eased)
        }
        return last.value
    }

    /** One-shot sampling: clamp into the clip and hold the last key. */
    public fun valueClamped(q: Double): Double {
        val first = keys.firstOrNull() ?: return 0.0
        val last = keys.lastOrNull() ?: return 0.0
        val t = BotFishMath.clamp(q, 0.0, 1.0)
        if (t <= first.phase) return first.value
        if (t >= last.phase) return last.value
        for (index in 1 until keys.size) {
            val a = keys[index - 1]
            val b = keys[index]
            if (t > b.phase) continue
            val span = b.phase - a.phase
            val eased = if (span <= 0) 1.0 else BotFishMath.smooth((t - a.phase) / span)
            return BotFishMath.lerp(a.value, b.value, eased)
        }
        return last.value
    }

    public companion object {
        public val ZERO: BotFishLivelyTrack = BotFishLivelyTrack(listOf(0.0 to 0.0, 1.0 to 0.0))
    }
}

/**
 * App-only `.lively` clip set (`BotFishLivelyMotion.swift:26-368`, fish.md
 * §5.5). These values never enter the lifecycle vocabulary; only the view's
 * motion profile selects them.
 */
public object BotFishLivelyMotion {
    public const val BLINK_INTERVAL_LOWER_MS: Double = 3000.0
    public const val BLINK_INTERVAL_UPPER_MS: Double = 5000.0
    public const val POSE_SPRING_OMEGA: Double = 18.0
    public const val TRANSITION_MS: Double = 320.0
    public const val GAZE_EMPHASIS: Double = 2.4
    public const val DOTS_CYCLE_MS: Double = 1080.0
    public const val DOTS_STAGGER_MS: Double = 120.0
    public const val DOTS_LIFT: Double = 12.0
    public const val DOTS_SCALE: Double = 1.5

    public const val THINKING_PERIOD: Double = 4800.0
    private val thinkingRoll = BotFishLivelyTrack(listOf(
        0.0 to 0.0, 0.25 to -6.0, 0.5 to 0.0, 0.75 to 6.0, 1.0 to 0.0,
    ))
    private val thinkingHeadX = BotFishLivelyTrack(listOf(
        0.0 to 0.0, 0.25 to 1.4, 0.5 to 0.0, 0.75 to -1.4, 1.0 to 0.0,
    ))
    private val thinkingGazeX = BotFishLivelyTrack(listOf(
        0.0 to -0.5, 0.25 to -0.75, 0.5 to 0.6, 0.75 to 0.75, 1.0 to -0.5,
    ))
    private val thinkingGazeY = BotFishLivelyTrack(listOf(
        0.0 to -0.6, 0.25 to -0.85, 0.5 to -0.35, 0.75 to -0.8, 1.0 to -0.6,
    ))
    private val thinkingHairSway = BotFishLivelyTrack(listOf(
        0.0 to 0.0, 0.25 to -6.0, 0.5 to 0.0, 0.75 to 6.0, 1.0 to 0.0,
    ))
    private val thinkingEarFlutter = BotFishLivelyTrack(listOf(
        0.0 to 0.0, 0.25 to 4.0, 0.5 to 0.0, 0.75 to -4.0, 1.0 to 0.0,
    ))

    private data class WorkingTracks(
        val period: Double,
        val roll: BotFishLivelyTrack,
        val headX: BotFishLivelyTrack,
        val y: BotFishLivelyTrack,
        val gazeX: BotFishLivelyTrack,
        val gazeY: BotFishLivelyTrack,
        val scaleX: BotFishLivelyTrack,
        val scaleY: BotFishLivelyTrack,
        val hairSway: BotFishLivelyTrack,
        val eyeArt: String?,
        val brow: Double,
        val anger: Double,
        val smile: Double,
    )

    private val workingGeneric = WorkingTracks(
        period = 2400.0,
        roll = BotFishLivelyTrack(listOf(
            0.0 to 0.0, 0.18 to 5.5, 0.4 to 0.0, 0.62 to -5.5, 0.82 to 0.0, 1.0 to 0.0,
        )),
        headX = BotFishLivelyTrack(listOf(
            0.0 to 0.0, 0.18 to -1.2, 0.4 to 0.0, 0.62 to 1.2, 0.82 to 0.0, 1.0 to 0.0,
        )),
        y = BotFishLivelyTrack(listOf(
            0.0 to 0.0, 0.1 to 18.0, 0.2 to 0.0, 0.32 to 13.0, 0.42 to 0.0,
            0.55 to 0.0, 1.0 to 0.0,
        )),
        gazeX = BotFishLivelyTrack.ZERO,
        gazeY = BotFishLivelyTrack(listOf(
            0.0 to 0.0, 0.5 to 0.0, 0.6 to 0.25, 0.8 to 0.1, 1.0 to 0.0,
        )),
        scaleX = BotFishLivelyTrack(listOf(
            0.0 to 1.0, 0.55 to 1.0, 0.6 to 1.06, 0.68 to 0.975, 0.76 to 1.01,
            0.86 to 1.0, 1.0 to 1.0,
        )),
        scaleY = BotFishLivelyTrack(listOf(
            0.0 to 1.0, 0.55 to 1.0, 0.6 to 0.93, 0.68 to 1.035, 0.76 to 0.995,
            0.86 to 1.0, 1.0 to 1.0,
        )),
        hairSway = BotFishLivelyTrack(listOf(
            0.0 to 0.0, 0.18 to 5.0, 0.4 to 0.0, 0.62 to -5.0, 0.82 to 0.0, 1.0 to 0.0,
        )),
        eyeArt = "focused", brow = -0.3, anger = 0.2, smile = 0.15,
    )

    private val workingReading = WorkingTracks(
        period = 3600.0,
        roll = BotFishLivelyTrack(listOf(
            0.0 to -2.0, 0.15 to -2.0, 0.5 to 3.0, 0.72 to 3.0, 0.85 to -2.0, 1.0 to -2.0,
        )),
        headX = BotFishLivelyTrack(listOf(
            0.0 to 0.9, 0.15 to 0.9, 0.5 to -1.1, 0.72 to -1.1, 0.85 to 0.9, 1.0 to 0.9,
        )),
        y = BotFishLivelyTrack(listOf(
            0.0 to 0.0, 0.15 to 5.0, 0.5 to 2.0, 0.72 to 6.0, 0.85 to 0.0, 1.0 to 0.0,
        )),
        gazeX = BotFishLivelyTrack(listOf(
            0.0 to -0.95, 0.15 to -0.95, 0.5 to 0.95, 0.72 to 0.95,
            0.85 to -0.95, 1.0 to -0.95,
        )),
        gazeY = BotFishLivelyTrack(listOf(0.0 to 0.35, 1.0 to 0.35)),
        scaleX = BotFishLivelyTrack(listOf(
            0.0 to 1.0, 0.8 to 1.0, 0.86 to 1.02, 0.92 to 0.995, 1.0 to 1.0,
        )),
        scaleY = BotFishLivelyTrack(listOf(
            0.0 to 1.0, 0.8 to 1.0, 0.86 to 0.985, 0.92 to 1.005, 1.0 to 1.0,
        )),
        hairSway = BotFishLivelyTrack(listOf(
            0.0 to -3.0, 0.5 to 4.0, 0.85 to -3.0, 1.0 to -3.0,
        )),
        eyeArt = null, brow = -0.2, anger = 0.1, smile = 0.3,
    )

    private val workingSearching = WorkingTracks(
        period = 2600.0,
        roll = BotFishLivelyTrack(listOf(
            0.0 to 0.0, 0.12 to -7.0, 0.28 to -7.0, 0.4 to 0.0, 0.52 to 7.0,
            0.66 to 7.0, 0.78 to 0.0, 0.9 to 0.0, 1.0 to 0.0,
        )),
        headX = BotFishLivelyTrack(listOf(
            0.0 to 0.0, 0.12 to 1.8, 0.28 to 1.8, 0.4 to 0.0, 0.52 to -1.8,
            0.66 to -1.8, 0.78 to 0.0, 0.9 to 0.0, 1.0 to 0.0,
        )),
        y = BotFishLivelyTrack.ZERO,
        gazeX = BotFishLivelyTrack(listOf(
            0.0 to 0.0, 0.06 to -1.0, 0.18 to 1.0, 0.28 to -1.0, 0.4 to 0.9,
            0.52 to -0.9, 0.66 to 0.9, 0.78 to 0.0, 0.9 to 0.0, 1.0 to 0.0,
        )),
        gazeY = BotFishLivelyTrack(listOf(0.0 to 0.0, 0.5 to -0.15, 1.0 to 0.0)),
        scaleX = BotFishLivelyTrack(listOf(
            0.0 to 1.0, 0.4 to 1.0, 0.46 to 1.015, 0.56 to 1.0, 1.0 to 1.0,
        )),
        scaleY = BotFishLivelyTrack(listOf(
            0.0 to 1.0, 0.4 to 1.0, 0.46 to 0.99, 0.56 to 1.0, 1.0 to 1.0,
        )),
        hairSway = BotFishLivelyTrack(listOf(
            0.0 to 0.0, 0.12 to 5.4, 0.4 to 0.0, 0.52 to -5.4, 0.78 to 0.0, 1.0 to 0.0,
        )),
        eyeArt = null, brow = -0.35, anger = 0.15, smile = 0.1,
    )

    private val workingRunning = WorkingTracks(
        period = 1200.0,
        roll = BotFishLivelyTrack(listOf(
            0.0 to 0.0, 0.15 to 3.5, 0.35 to 0.0, 0.55 to -3.5, 0.75 to 0.0, 1.0 to 0.0,
        )),
        headX = BotFishLivelyTrack(listOf(
            0.0 to 0.0, 0.15 to -0.9, 0.35 to 0.0, 0.55 to 0.9, 0.75 to 0.0, 1.0 to 0.0,
        )),
        y = BotFishLivelyTrack(listOf(
            0.0 to 0.0, 0.08 to 18.0, 0.16 to 0.0, 0.28 to 14.0, 0.36 to 0.0,
            0.52 to 0.0, 0.6 to 18.0, 0.68 to 0.0, 0.8 to 14.0, 0.88 to 0.0, 1.0 to 0.0,
        )),
        gazeX = BotFishLivelyTrack.ZERO,
        gazeY = BotFishLivelyTrack(listOf(0.0 to -0.05, 0.5 to 0.1, 1.0 to -0.05)),
        scaleX = BotFishLivelyTrack(listOf(
            0.0 to 1.0, 0.08 to 1.02, 0.16 to 0.99, 0.28 to 1.02, 0.36 to 1.0,
            0.6 to 1.02, 0.68 to 1.0, 0.8 to 1.02, 0.88 to 1.0, 1.0 to 1.0,
        )),
        scaleY = BotFishLivelyTrack(listOf(
            0.0 to 1.0, 0.08 to 0.98, 0.16 to 1.01, 0.28 to 0.98, 0.36 to 1.0,
            0.6 to 0.98, 0.68 to 1.0, 0.8 to 0.98, 0.88 to 1.0, 1.0 to 1.0,
        )),
        hairSway = BotFishLivelyTrack(listOf(
            0.0 to 0.0, 0.15 to -3.6, 0.35 to 0.0, 0.55 to 3.6, 0.75 to 0.0, 1.0 to 0.0,
        )),
        eyeArt = "focused", brow = -0.4, anger = 0.25, smile = 0.1,
    )

    private val workingWriting = WorkingTracks(
        period = 1800.0,
        roll = BotFishLivelyTrack(listOf(
            0.0 to -4.5, 0.18 to -4.5, 0.3 to -2.5, 0.42 to -4.5,
            0.54 to -2.5, 0.66 to -4.5, 0.8 to -4.5, 1.0 to -4.5,
        )),
        headX = BotFishLivelyTrack(listOf(
            0.0 to 0.7, 0.18 to 0.7, 0.3 to -0.7, 0.42 to 0.7,
            0.54 to -0.7, 0.66 to 0.7, 0.8 to 0.7, 1.0 to 0.7,
        )),
        y = BotFishLivelyTrack(listOf(
            0.0 to 14.0, 0.2 to 14.0, 0.35 to 12.0, 0.5 to 14.0, 0.65 to 12.0,
            0.8 to 14.0, 1.0 to 14.0,
        )),
        gazeX = BotFishLivelyTrack(listOf(
            0.0 to -0.25, 0.25 to 0.3, 0.5 to -0.3, 0.75 to 0.25, 1.0 to -0.25,
        )),
        gazeY = BotFishLivelyTrack(listOf(0.0 to 0.8, 1.0 to 0.8)),
        scaleX = BotFishLivelyTrack(listOf(
            0.0 to 1.0, 0.3 to 1.01, 0.45 to 0.995, 0.6 to 1.01, 0.75 to 1.0, 1.0 to 1.0,
        )),
        scaleY = BotFishLivelyTrack(listOf(
            0.0 to 1.0, 0.3 to 0.99, 0.45 to 1.005, 0.6 to 0.99, 0.75 to 1.0, 1.0 to 1.0,
        )),
        hairSway = BotFishLivelyTrack(listOf(
            0.0 to 2.8, 0.3 to -2.8, 0.54 to 2.8, 0.8 to 2.8, 1.0 to 2.8,
        )),
        eyeArt = null, brow = -0.4, anger = 0.25, smile = 0.05,
    )

    public const val STREAMING_PERIOD: Double = 1600.0
    public const val SPEAKING_PERIOD: Double = 1400.0
    private val speechRoll = BotFishLivelyTrack(listOf(
        0.0 to 0.0, 0.12 to 9.0, 0.28 to 4.0, 0.42 to -10.0, 0.58 to -4.0,
        0.72 to 8.0, 0.88 to 2.0, 1.0 to 0.0,
    ))
    private val speechHeadX = BotFishLivelyTrack(listOf(
        0.0 to 0.0, 0.12 to -0.9, 0.42 to 0.9, 0.72 to -0.8, 1.0 to 0.0,
    ))
    private val speechGazeX = BotFishLivelyTrack(listOf(
        0.0 to 0.0, 0.32 to 0.25, 0.64 to -0.2, 1.0 to 0.0,
    ))
    private val speechGazeY = BotFishLivelyTrack(listOf(
        0.0 to 0.0, 0.5 to -0.15, 1.0 to 0.0,
    ))
    private val speechHairSway = BotFishLivelyTrack(listOf(
        0.0 to 0.0, 0.12 to -4.0, 0.42 to 4.0, 0.72 to -3.0, 1.0 to 0.0,
    ))

    public const val CELEBRATION_DURATION: Double = 1200.0
    private val celebrationHopY = BotFishLivelyTrack(listOf(
        0.0 to 0.0, 0.08 to 4.0, 0.2 to -20.0, 0.34 to -12.0, 0.48 to 0.0,
        0.6 to -7.0, 0.74 to 0.0, 1.0 to 0.0,
    ))
    private val celebrationRoll = BotFishLivelyTrack(listOf(
        0.0 to 0.0, 0.2 to -4.0, 0.48 to 3.0, 0.74 to -2.0, 1.0 to 0.0,
    ))
    private val celebrationScaleX = BotFishLivelyTrack(listOf(
        0.0 to 1.0, 0.08 to 1.05, 0.2 to 0.95, 0.34 to 0.98, 0.48 to 1.02,
        0.6 to 0.99, 1.0 to 1.0,
    ))
    private val celebrationScaleY = BotFishLivelyTrack(listOf(
        0.0 to 1.0, 0.08 to 0.94, 0.2 to 1.06, 0.34 to 1.01, 0.48 to 0.98,
        0.6 to 1.01, 1.0 to 1.0,
    ))
    private val celebrationHairSway = BotFishLivelyTrack(listOf(
        0.0 to 0.0, 0.2 to -7.0, 0.48 to 5.0, 0.74 to -3.0, 1.0 to 0.0,
    ))
    private val celebrationEarFlutter = BotFishLivelyTrack(listOf(
        0.0 to 0.0, 0.2 to 5.0, 0.48 to -3.0, 1.0 to 0.0,
    ))
    private val celebrationFinWave = BotFishLivelyTrack(listOf(
        0.0 to 0.0, 0.2 to 0.5, 0.48 to -0.3, 1.0 to 0.0,
    ))

    /**
     * Returns `null` for states that keep the upstream `.standard` model.
     * `elapsed` is state-relative and already frozen at 650 ms for
     * still/reduced frames.
     */
    public fun sample(
        state: BotFishLifecycle,
        workStyle: BotFishWorkStyle,
        elapsed: Double,
    ): BotFishParams? {
        val params = when (state) {
            BotFishLifecycle.THINKING -> thinking(elapsed)
            BotFishLifecycle.WORKING -> working(elapsed, workStyle)
            BotFishLifecycle.STREAMING -> speech(
                elapsed, STREAMING_PERIOD, 170.0,
                listOf("smile", "vowel-e", "small-o"),
            )
            BotFishLifecycle.SPEAKING -> speech(
                elapsed, SPEAKING_PERIOD, 111.0,
                listOf("smile", "vowel-a", "small-o"),
            )
            BotFishLifecycle.CELEBRATE -> celebration(elapsed, done = false)
            BotFishLifecycle.DONE -> celebration(elapsed, done = true)
            else -> return null
        }
        params.isLivelyMotion = true
        return params
    }

    private fun phase(elapsed: Double, period: Double): Double =
        if (period <= 0) 0.0 else (elapsed / period) % 1.0

    private fun thinking(elapsed: Double): BotFishParams {
        val q = phase(elapsed, THINKING_PERIOD)
        val p = BotFishParams()
        p.roll = thinkingRoll.valueAt(q)
        p.headX = thinkingHeadX.valueAt(q)
        p.gazeX = thinkingGazeX.valueAt(q)
        p.gazeY = thinkingGazeY.valueAt(q)
        p.gazeEmphasis = GAZE_EMPHASIS
        p.browL = 0.65
        p.browR = -0.15
        p.smile = 0.1
        p.mouthWidth = 0.65
        p.hairSway = thinkingHairSway.valueAt(q)
        p.earFlutter = thinkingEarFlutter.valueAt(q)
        p.decoration = "dots"
        p.dotLift = DOTS_LIFT
        p.dotScale = DOTS_SCALE
        p.dotStagger = DOTS_STAGGER_MS / DOTS_CYCLE_MS
        p.phase = phase(elapsed, DOTS_CYCLE_MS)
        return p
    }

    private fun workingTracks(style: BotFishWorkStyle): WorkingTracks = when (style) {
        BotFishWorkStyle.GENERIC -> workingGeneric
        BotFishWorkStyle.READING -> workingReading
        BotFishWorkStyle.SEARCHING -> workingSearching
        BotFishWorkStyle.RUNNING -> workingRunning
        BotFishWorkStyle.WRITING -> workingWriting
    }

    private fun working(elapsed: Double, style: BotFishWorkStyle): BotFishParams {
        val tracks = workingTracks(style)
        val q = phase(elapsed, tracks.period)
        val p = BotFishParams()
        p.eyeArt = tracks.eyeArt
        p.roll = tracks.roll.valueAt(q)
        p.headX = tracks.headX.valueAt(q)
        p.y = tracks.y.valueAt(q)
        p.gazeX = tracks.gazeX.valueAt(q)
        p.gazeY = tracks.gazeY.valueAt(q)
        p.gazeEmphasis = GAZE_EMPHASIS
        p.sx = tracks.scaleX.valueAt(q)
        p.sy = tracks.scaleY.valueAt(q)
        p.hairSway = tracks.hairSway.valueAt(q)
        p.earFlutter = tracks.headX.valueAt(q) * 2
        p.browL = tracks.brow
        p.browR = tracks.brow
        p.anger = tracks.anger
        p.smile = tracks.smile
        p.mouthWidth = 0.8
        p.mouthArt = "smile"
        return p
    }

    private fun speech(
        elapsed: Double,
        period: Double,
        mouthFrameMilliseconds: Double,
        mouthArts: List<String>,
    ): BotFishParams {
        val q = phase(elapsed, period)
        val p = BotFishParams()
        p.mouthArt = mouthArts[floor(elapsed / mouthFrameMilliseconds).toInt() % mouthArts.size]
        p.roll = speechRoll.valueAt(q)
        p.headX = speechHeadX.valueAt(q)
        p.gazeX = speechGazeX.valueAt(q)
        p.gazeY = speechGazeY.valueAt(q)
        p.gazeEmphasis = 2.0
        p.hairSway = speechHairSway.valueAt(q)
        p.earFlutter = speechHeadX.valueAt(q) * 1.5
        p.smile = 0.6
        p.mouthWidth = 0.9
        return p
    }

    private fun celebration(elapsed: Double, done: Boolean): BotFishParams {
        val q = BotFishMath.clamp(elapsed / CELEBRATION_DURATION, 0.0, 1.0)
        val p = BotFishParams()
        p.joy = 1.0
        p.smile = 1.0
        p.blush = 0.55
        p.eyeArt = if (done) "excited" else "laughing"
        p.mouthArt = if (done) "smile-open" else "laugh"
        p.mouthWidth = if (done) 0.95 else 1.1
        p.y = celebrationHopY.valueClamped(q)
        p.roll = celebrationRoll.valueClamped(q)
        p.sx = celebrationScaleX.valueClamped(q)
        p.sy = celebrationScaleY.valueClamped(q)
        p.hairSway = celebrationHairSway.valueClamped(q)
        p.earFlutter = celebrationEarFlutter.valueClamped(q)
        p.finL = 0.9
        p.finR = 0.9
        p.finWave = celebrationFinWave.valueClamped(q)
        p.gazeEmphasis = 2.0
        p.decoration = if (done) "check" else "confetti"
        p.phase = q
        return p
    }
}
