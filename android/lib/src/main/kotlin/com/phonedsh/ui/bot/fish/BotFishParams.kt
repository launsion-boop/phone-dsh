// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import com.phonedsh.bot.fish.BotFishLifecycle
/**
 * Every animated parameter the renderer consumes; the defaults are the frozen
 * baseline of `spec/ui/v1/bot/fish/fish.md` §5.2
 * (`BotFishModel.swift:61-129`).
 *
 * The fields are mutable because [BotFishModel.sample] and
 * [BotFishStateMachine.step] apply the Swift struct's `p.field = value`
 * assignments in order. The engine hands out an unmodified copy so the
 * trajectory's `params` stay pre-amplification.
 */
public data class BotFishParams(
    // Face.
    public var eyeL: Double = 1.0,
    public var eyeR: Double = 1.0,
    public var joy: Double = 0.0,
    public var browL: Double = 0.0,
    public var browR: Double = 0.0,
    public var anger: Double = 0.0,
    public var sorrow: Double = 0.0,
    public var smile: Double = 0.55,
    public var mouth: Double = 0.0,
    public var mouthWidth: Double = 1.0,
    public var round: Double = 0.0,
    public var blush: Double = 0.0,
    public var tears: Double = 0.0,
    public var love: Double = 0.0,
    public var gazeX: Double = 0.0,
    public var gazeY: Double = 0.0,
    // Pose.
    public var roll: Double = 0.0,
    public var y: Double = 0.0,
    public var x: Double = 0.0,
    public var sx: Double = 1.0,
    public var sy: Double = 1.0,
    public var alpha: Double = 1.0,
    // Fins.
    public var finL: Double = 0.0,
    public var finR: Double = 0.0,
    public var finWave: Double = 0.0,
    // Decoration and clip progress.
    public var decoration: String = "",
    public var progress: Double = 0.0,
    public var phase: Double = 0.0,
    // Filled by expressiveMotion.
    public var eyeArt: String? = null,
    public var mouthArt: String? = null,
    public var finFold: Double = 0.0,
    public var hairSway: Double = 0.0,
    public var earFlutter: Double = 0.0,
    public var puff: Double = 0.0,
    public var breath: Double = 0.0,
    // Filled by the controller.
    public var headX: Double = 0.0,
    public var headY: Double = 0.0,
    public var bodyX: Double = 0.0,
    public var bodyY: Double = 0.0,
    public var blink: Double = 1.0,
    public var morphX: Double = 1.0,
    public var morphY: Double = 1.0,
    public var artMix: Double = 1.0,
    public var eyeArtPrev: String? = null,
    public var mouthArtPrev: String? = null,
    public var motionScale: Double = 1.0,
    // App-only lively inputs (§5.5).
    public var gazeEmphasis: Double = 1.0,
    public var dotLift: Double = 0.0,
    public var dotScale: Double = 1.0,
    public var dotStagger: Double = 0.0,
    public var isLivelyMotion: Boolean = false,
) {
    internal fun faceValue(key: BotFishFaceKey): Double = when (key) {
        BotFishFaceKey.EYE_L -> eyeL
        BotFishFaceKey.EYE_R -> eyeR
        BotFishFaceKey.JOY -> joy
        BotFishFaceKey.BROW_L -> browL
        BotFishFaceKey.BROW_R -> browR
        BotFishFaceKey.ANGER -> anger
        BotFishFaceKey.SORROW -> sorrow
        BotFishFaceKey.SMILE -> smile
        BotFishFaceKey.MOUTH -> mouth
        BotFishFaceKey.MOUTH_WIDTH -> mouthWidth
        BotFishFaceKey.ROUND -> round
        BotFishFaceKey.BLUSH -> blush
        BotFishFaceKey.TEARS -> tears
        BotFishFaceKey.LOVE -> love
        BotFishFaceKey.GAZE_X -> gazeX
        BotFishFaceKey.GAZE_Y -> gazeY
    }

    internal fun setFaceValue(key: BotFishFaceKey, value: Double) {
        when (key) {
            BotFishFaceKey.EYE_L -> eyeL = value
            BotFishFaceKey.EYE_R -> eyeR = value
            BotFishFaceKey.JOY -> joy = value
            BotFishFaceKey.BROW_L -> browL = value
            BotFishFaceKey.BROW_R -> browR = value
            BotFishFaceKey.ANGER -> anger = value
            BotFishFaceKey.SORROW -> sorrow = value
            BotFishFaceKey.SMILE -> smile = value
            BotFishFaceKey.MOUTH -> mouth = value
            BotFishFaceKey.MOUTH_WIDTH -> mouthWidth = value
            BotFishFaceKey.ROUND -> round = value
            BotFishFaceKey.BLUSH -> blush = value
            BotFishFaceKey.TEARS -> tears = value
            BotFishFaceKey.LOVE -> love = value
            BotFishFaceKey.GAZE_X -> gazeX = value
            BotFishFaceKey.GAZE_Y -> gazeY = value
        }
    }
}

/** The 16 face keys and their frozen spring order (`BotFishEngine.swift:12-15`). */
public enum class BotFishFaceKey {
    EYE_L, EYE_R, JOY, BROW_L, BROW_R, ANGER, SORROW, SMILE, MOUTH,
    MOUTH_WIDTH, ROUND, BLUSH, TEARS, LOVE, GAZE_X, GAZE_Y,
}

/** One lifecycle clip row (`BotFishModel.swift:131-181`, fish.md §4). */
public data class BotFishClip(
    public val period: Double? = null,
    public val duration: Double? = null,
    public val isStatic: Boolean = false,
) {
    public companion object {
        public fun forState(state: BotFishLifecycle): BotFishClip = when (state) {
            BotFishLifecycle.IDLE -> BotFishClip(period = 2400.0)
            BotFishLifecycle.THINKING -> BotFishClip(period = 2800.0)
            BotFishLifecycle.STREAMING -> BotFishClip(period = 1000.0)
            BotFishLifecycle.WORKING -> BotFishClip(period = 1800.0)
            BotFishLifecycle.SLEEPING -> BotFishClip(period = 4200.0)
            BotFishLifecycle.ALERTING -> BotFishClip(period = 1100.0)
            BotFishLifecycle.LISTENING -> BotFishClip(period = 3200.0)
            BotFishLifecycle.SPEAKING -> BotFishClip(period = 900.0)
            BotFishLifecycle.HAPPY -> BotFishClip(period = 2200.0)
            BotFishLifecycle.SAD -> BotFishClip(period = 3600.0)
            BotFishLifecycle.SURPRISED -> BotFishClip(period = 2000.0)
            BotFishLifecycle.CONFUSED -> BotFishClip(period = 3200.0)
            BotFishLifecycle.LAUGHING -> BotFishClip(period = 900.0)
            BotFishLifecycle.LOVE -> BotFishClip(period = 2400.0)
            BotFishLifecycle.ANGRY -> BotFishClip(period = 2400.0)
            BotFishLifecycle.WINK -> BotFishClip(period = 2200.0)
            BotFishLifecycle.NOD -> BotFishClip(period = 2000.0)
            BotFishLifecycle.SHRUG -> BotFishClip(period = 2800.0)
            BotFishLifecycle.CELEBRATE -> BotFishClip(period = 1500.0)
            BotFishLifecycle.POKE -> BotFishClip(duration = 420.0)
            BotFishLifecycle.WAKING -> BotFishClip(duration = 1400.0)
            BotFishLifecycle.WAITING -> BotFishClip(period = 4000.0)
            BotFishLifecycle.LOADING -> BotFishClip(period = 1600.0)
            BotFishLifecycle.DONE -> BotFishClip(duration = 1200.0)
            BotFishLifecycle.STANDBY -> BotFishClip(isStatic = true)
            BotFishLifecycle.POWERING_DOWN -> BotFishClip(duration = 1400.0)
            BotFishLifecycle.SPAWNING -> BotFishClip(duration = 1000.0)
            BotFishLifecycle.BOUNCING -> BotFishClip(period = 1400.0)
            BotFishLifecycle.DANCING -> BotFishClip(period = 1800.0)
            BotFishLifecycle.WAVING -> BotFishClip(period = 1600.0)
            BotFishLifecycle.SHY -> BotFishClip(period = 3200.0)
            BotFishLifecycle.SMUG -> BotFishClip(period = 2600.0)
            BotFishLifecycle.CRYING -> BotFishClip(period = 2400.0)
            BotFishLifecycle.SIGHING -> BotFishClip(period = 3600.0)
            BotFishLifecycle.CHEERING -> BotFishClip(period = 1600.0)
            BotFishLifecycle.BOWING -> BotFishClip(period = 2800.0)
            BotFishLifecycle.SHAKING_HEAD -> BotFishClip(period = 2400.0)
            BotFishLifecycle.CLAPPING -> BotFishClip(period = 1200.0)
            BotFishLifecycle.STRETCHING -> BotFishClip(period = 4200.0)
            BotFishLifecycle.YAWNING -> BotFishClip(period = 4800.0)
            BotFishLifecycle.KISS -> BotFishClip(period = 2600.0)
            BotFishLifecycle.HIGH_FIVE -> BotFishClip(period = 2200.0)
        }
    }
}

/** Row-major eye sprite names (`BotFishModel.swift:33-40`, fish.md §8.1). */
public object BotFishEyeCel {
    public val names: List<String> = listOf(
        "laughing", "focused", "surprised", "sad", "love", "confused",
        "angry", "sleepy", "wink", "excited", "deadpan", "shy",
    )

    public fun indexOf(name: String?): Int? = name?.let { names.indexOf(it).takeIf { index -> index >= 0 } }
}

/** Row-major mouth sprite names (`BotFishModel.swift:42-49`, fish.md §8.1). */
public object BotFishMouthCel {
    public val names: List<String> = listOf(
        "smile", "smile-open", "laugh", "shocked", "pout", "sad",
        "smug", "small-o", "vowel-a", "vowel-e", "kiss", "yawn",
    )

    public fun indexOf(name: String?): Int? = name?.let { names.indexOf(it).takeIf { index -> index >= 0 } }
}
