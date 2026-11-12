// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import com.phonedsh.bot.fish.BotFishLifecycle
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.sin

/**
 * Pure port of the Swift `BotFishModel`
 * (`examples/probe-app/PhoneDSHProbe/Bot/Fish/BotFishModel.swift:186-697`).
 * It reproduces the per-state assignments and `expressiveMotion` overlays that
 * `spec/ui/v1/bot/fish/fish.md` §5 freezes.
 */
public object BotFishModel {
    public fun sample(state: BotFishLifecycle, time: Double): BotFishParams {
        val spec = BotFishClip.forState(state)
        val phase = spec.period?.let { period ->
            if (period == 0.0) 0.0 else time % period / period
        } ?: 0.0
        val s = sin(phase * PI * 2)
        val q = spec.duration?.let { duration -> BotFishMath.clamp(time / duration, 0.0, 1.0) } ?: phase
        val p = BotFishParams()
        p.phase = phase
        p.progress = q

        when (state) {
            BotFishLifecycle.IDLE -> {
                p.sy = 1 + s * 0.004
            }
            BotFishLifecycle.THINKING -> {
                p.gazeY = -0.65
                p.gazeX = -0.25
                p.browL = 0.65
                p.browR = -0.15
                p.roll = -2.5
                p.smile = 0.05
                p.mouthWidth = 0.65
                p.decoration = "dots"
            }
            BotFishLifecycle.STREAMING -> {
                p.eyeL = 0.70
                p.eyeR = 0.70
                p.mouth = 0.10 + 0.20 * (s + 1) / 2
                p.smile = 0.5
                p.mouthWidth = 0.75
            }
            BotFishLifecycle.WORKING -> {
                p.eyeL = 0.84
                p.eyeR = 0.84
                p.anger = 0.25
                p.browL = -0.35
                p.browR = -0.35
                p.y = max(0.0, s) * 2.6
                p.smile = 0.15
            }
            BotFishLifecycle.SLEEPING -> {
                p.eyeL = 0.0
                p.eyeR = 0.0
                p.mouth = 0.06
                p.mouthWidth = 0.42
                p.round = 1.0
                p.sy = 1 + s * 0.008
                p.y = 1.8 * s
                p.decoration = "sleep"
            }
            BotFishLifecycle.ALERTING -> {
                p.eyeL = 1.14
                p.eyeR = 1.14
                p.browL = 0.7
                p.browR = 0.7
                p.mouth = 0.55
                p.mouthWidth = 0.65
                p.round = 1.0
                p.y = -max(0.0, s) * 9
                p.decoration = "alert"
            }
            BotFishLifecycle.LISTENING -> {
                p.eyeL = 1.03
                p.eyeR = 1.03
                p.browL = 0.12
                p.browR = 0.12
                p.roll = s * 1.3
                p.finL = 0.15
                p.finR = 0.15
                p.smile = 0.35
                p.decoration = "listen"
            }
            BotFishLifecycle.SPEAKING -> {
                val frame = floor(time / 111).toInt() % 3
                p.mouth = listOf(0.0, 0.46, 0.82)[frame]
                p.mouthWidth = if (frame == 2) 0.62 else 1.0
                p.round = if (frame == 2) 1.0 else 0.0
                p.roll = s * 0.6
            }
            BotFishLifecycle.HAPPY -> {
                p.eyeL = 0.82
                p.eyeR = 0.82
                p.joy = 0.65
                p.smile = 1.0
                p.mouth = 0.17
                p.blush = 0.65
                p.y = -2 * s
            }
            BotFishLifecycle.SAD -> {
                p.eyeL = 0.76
                p.eyeR = 0.76
                p.sorrow = 1.0
                p.browL = 0.35
                p.browR = 0.35
                p.smile = -0.7
                p.mouthWidth = 0.75
                p.tears = 0.8
                p.roll = -1.5
                p.y = 2.0
            }
            BotFishLifecycle.SURPRISED -> {
                p.eyeL = 1.18
                p.eyeR = 1.18
                p.browL = 0.8
                p.browR = 0.8
                p.mouth = 0.8
                p.mouthWidth = 0.58
                p.round = 1.0
                p.decoration = "spark"
            }
            BotFishLifecycle.CONFUSED -> {
                p.eyeL = 1.0
                p.eyeR = 0.70
                p.browL = 0.7
                p.browR = -0.3
                p.roll = s * 3
                p.gazeX = s * 0.55
                p.smile = -0.05
                p.mouthWidth = 0.6
                p.decoration = "question"
            }
            BotFishLifecycle.LAUGHING -> {
                p.eyeL = 0.02
                p.eyeR = 0.02
                p.joy = 1.0
                p.smile = 1.0
                p.mouth = 0.80 + 0.08 * s
                p.blush = 0.55
                p.y = -4 * abs(s)
                p.roll = s
            }
            BotFishLifecycle.LOVE -> {
                p.love = 1.0
                p.joy = 0.3
                p.blush = 0.9
                p.smile = 1.0
                p.mouth = 0.13
                p.roll = 1.3 * s
                p.decoration = "hearts"
            }
            BotFishLifecycle.ANGRY -> {
                p.eyeL = 0.72
                p.eyeR = 0.72
                p.anger = 1.0
                p.browL = -0.55
                p.browR = -0.55
                p.smile = -0.65
                p.blush = 0.2
                p.decoration = "anger"
            }
            BotFishLifecycle.WINK -> {
                p.eyeL = 0.02
                p.eyeR = 1.0
                p.joy = 0.8
                p.smile = 1.0
                p.roll = 3.0
                p.blush = 0.35
                p.decoration = "spark"
            }
            BotFishLifecycle.NOD -> {
                p.y = s * 4
                p.sy = 1 - max(0.0, s) * 0.015
                p.gazeY = -s * 0.15
                p.smile = 0.65
            }
            BotFishLifecycle.SHRUG -> {
                p.finL = 1.0
                p.finR = 1.0
                p.roll = -2.2
                p.eyeL = 0.9
                p.eyeR = 0.76
                p.browL = 0.5
                p.smile = -0.05
                p.mouthWidth = 0.7
            }
            BotFishLifecycle.CELEBRATE -> {
                p.eyeL = 0.02
                p.eyeR = 0.02
                p.joy = 1.0
                p.mouth = 0.75
                p.smile = 1.0
                p.blush = 0.6
                p.finL = 1.0
                p.finR = 1.0
                p.finWave = s * 0.3
                p.y = -abs(s) * 6
                p.decoration = "confetti"
            }
            BotFishLifecycle.POKE -> {
                val keys = listOf(
                    Triple(0.0, 1.0, 1.0),
                    Triple(0.23, 1.07, 0.90),
                    Triple(0.57, 0.95, 1.05),
                    Triple(1.0, 1.0, 1.0),
                )
                var a = keys[0]
                var b = keys[keys.size - 1]
                for (index in 1 until keys.size) {
                    if (q <= keys[index].first) {
                        a = keys[index - 1]
                        b = keys[index]
                        break
                    }
                }
                val k = BotFishMath.smooth((q - a.first) / (b.first - a.first))
                p.sx = BotFishMath.lerp(a.second, b.second, k)
                p.sy = BotFishMath.lerp(a.third, b.third, k)
                p.blush = 0.6
                p.mouth = 0.35
                p.mouthWidth = 0.65
                p.round = 0.8
            }
            BotFishLifecycle.WAKING -> {
                val o = BotFishMath.smooth(q)
                p.eyeL = o
                p.eyeR = o
                p.smile = 0.4
                p.y = (1 - o) * 5
                p.alpha = 0.7 + 0.3 * o
                p.decoration = if (q < 0.8) "spark" else ""
            }
            BotFishLifecycle.WAITING -> {
                p.eyeL = 0.90
                p.eyeR = 0.90
                p.smile = 0.25
                p.sy = 1 + s * 0.003
                p.decoration = "waiting"
            }
            BotFishLifecycle.LOADING -> {
                p.eyeL = 0.92
                p.eyeR = 0.92
                p.smile = 0.25
                p.decoration = "loading"
            }
            BotFishLifecycle.DONE -> {
                p.joy = 0.4
                p.smile = 1.0
                p.blush = 0.25
                p.sx = 1 + sin(q * PI) * 0.025
                p.sy = 1 + sin(q * PI) * 0.025
                p.decoration = "check"
            }
            BotFishLifecycle.STANDBY -> {
                p.eyeL = 0.35
                p.eyeR = 0.35
                p.alpha = 0.65
                p.smile = 0.2
            }
            BotFishLifecycle.POWERING_DOWN -> {
                p.eyeL = 1 - BotFishMath.smooth(q)
                p.eyeR = 1 - BotFishMath.smooth(q)
                p.alpha = 1 - 0.65 * BotFishMath.smooth(q)
                p.y = q * 5
                p.smile = 0.15
            }
            BotFishLifecycle.SPAWNING -> {
                val v = 1 - (1 - q).pow(3)
                p.sx = 0.65 + 0.35 * v + sin(q * PI) * 0.025
                p.sy = 0.65 + 0.35 * v + sin(q * PI) * 0.025
                p.alpha = BotFishMath.smooth(q * 2)
                p.y = (1 - v) * 14
                p.decoration = if (q < 0.85) "spark" else ""
            }
            BotFishLifecycle.BOUNCING -> {
                p.y = -abs(s) * 13
                p.sx = 1 + abs(s) * 0.01
                p.sy = 1 - abs(s) * 0.015
                p.smile = 0.8
            }
            BotFishLifecycle.DANCING -> {
                p.roll = s * 4.5
                p.y = -abs(s) * 4
                p.joy = 0.45
                p.mouth = 0.4
                p.smile = 1.0
                p.finL = 0.7
                p.finR = 0.7
                p.finWave = s
                p.decoration = "music"
            }
            BotFishLifecycle.WAVING -> {
                p.finR = 1.0
                p.finWave = s
                p.roll = -1.2
                p.smile = 0.9
                p.mouth = 0.16
                p.blush = 0.2
            }
            BotFishLifecycle.SHY, BotFishLifecycle.SMUG, BotFishLifecycle.CRYING,
            BotFishLifecycle.SIGHING, BotFishLifecycle.CHEERING, BotFishLifecycle.BOWING,
            BotFishLifecycle.SHAKING_HEAD, BotFishLifecycle.CLAPPING,
            BotFishLifecycle.STRETCHING, BotFishLifecycle.YAWNING,
            BotFishLifecycle.KISS, BotFishLifecycle.HIGH_FIVE,
            -> Unit
        }

        return expressiveMotion(state, time, p)
    }

    /** Port of `expressiveMotion(state, time, p)` (`BotFishModel.swift:449-697`). */
    public fun expressiveMotion(
        state: BotFishLifecycle,
        time: Double,
        params: BotFishParams,
    ): BotFishParams {
        val p = params
        val special = when (state) {
            BotFishLifecycle.HAPPY -> 2200.0
            BotFishLifecycle.LAUGHING -> 900.0
            BotFishLifecycle.SAD -> 3600.0
            BotFishLifecycle.ANGRY -> 2400.0
            BotFishLifecycle.WAVING -> 1600.0
            BotFishLifecycle.DANCING -> 1800.0
            else -> 2400.0
        }
        val period = BotFishClip.forState(state).period ?: special
        val phase = if (period == 0.0) 0.0 else time % period / period
        val s = sin(phase * PI * 2)
        val s2 = sin(phase * PI * 4)

        p.eyeArt = null
        p.mouthArt = null
        p.finFold = 0.0
        p.hairSway = 0.0
        p.earFlutter = 0.0
        p.puff = 0.0
        p.breath = 0.0

        when (state) {
            BotFishLifecycle.STREAMING -> {
                p.mouthArt = listOf("smile", "vowel-e", "small-o")[floor(time / 170).toInt() % 3]
            }
            BotFishLifecycle.SPEAKING -> {
                p.mouthArt = listOf("smile", "vowel-a", "small-o")[floor(time / 111).toInt() % 3]
            }
            BotFishLifecycle.HAPPY -> {
                p.eyeArt = "excited"
                p.mouthArt = "smile-open"
                p.finL = 0.28
                p.finR = 0.28
                p.roll = s * 1.8
                p.hairSway = s * 1.8
            }
            BotFishLifecycle.LAUGHING -> {
                p.eyeArt = "laughing"
                p.mouthArt = "laugh"
                p.mouthWidth = 1.15
                p.y = -abs(s) * 7
                p.roll = s * 2.2
                p.hairSway = -s * 2.8
                p.finL = 0.6
                p.finR = 0.6
            }
            BotFishLifecycle.SAD -> {
                p.eyeArt = "sad"
                p.mouthArt = "sad"
                p.tears = 0.9
                p.roll = -2.6
                p.y = 3.0
                p.hairSway = s * 0.8
            }
            BotFishLifecycle.SURPRISED -> {
                p.eyeArt = "surprised"
                p.mouthArt = "shocked"
                val b = BotFishMath.bump(phase, 0.0, 0.38)
                p.sy = 1 + 0.018 * b
                p.y = -4 * b
                p.earFlutter = 3 * b
            }
            BotFishLifecycle.ANGRY -> {
                p.eyeArt = "angry"
                p.mouthArt = "pout"
                p.puff = 0.75
                p.roll = s * 0.7
                p.y = abs(s2) * 1.5
                p.finL = 0.5
                p.finR = 0.5
            }
            BotFishLifecycle.CONFUSED -> {
                p.eyeArt = "confused"
                p.mouthArt = "small-o"
                p.roll = s * 5
                p.gazeX = s * 0.65
                p.hairSway = -s * 2
            }
            BotFishLifecycle.LOVE -> {
                p.eyeArt = "love"
                p.mouthArt = "smile-open"
                p.finL = 0.7
                p.finR = 0.7
                p.finFold = 0.55
                p.y = -2 * s
                p.hairSway = s * 2
            }
            BotFishLifecycle.WINK -> {
                p.eyeArt = "wink"
                p.mouthArt = "smug"
                p.finR = 0.8
                p.finWave = s * 0.45
                p.earFlutter = s
            }
            BotFishLifecycle.SLEEPING -> {
                p.eyeArt = "laughing"
                p.mouthArt = "small-o"
                p.breath = (s + 1) * 0.5
            }
            BotFishLifecycle.WORKING -> {
                p.eyeArt = "focused"
                p.mouthArt = "smile"
                p.roll = s * 0.7
            }
            BotFishLifecycle.WAITING -> {
                p.eyeArt = "sleepy"
                p.mouthArt = "smile"
            }
            BotFishLifecycle.CELEBRATE -> {
                p.eyeArt = "laughing"
                p.mouthArt = "laugh"
                p.finL = 1.0
                p.finR = 1.0
                p.finWave = s * 0.65
                p.hairSway = -s * 3
                p.earFlutter = abs(s) * 2
            }
            BotFishLifecycle.WAVING -> {
                p.eyeArt = "excited"
                p.mouthArt = "smile-open"
                p.finR = 1.15
                p.finWave = s * 1.4
                p.roll = s * 2
                p.hairSway = -s * 2
            }
            BotFishLifecycle.DANCING -> {
                p.eyeArt = "excited"
                p.mouthArt = "smile-open"
                p.roll = s * 6
                p.y = -abs(s) * 7
                p.finL = 0.8
                p.finR = 0.8
                p.finWave = s * 1.5
                p.hairSway = -s * 3.5
                p.earFlutter = s * 2
            }
            BotFishLifecycle.SHY -> {
                p.eyeArt = "shy"
                p.mouthArt = "smile"
                p.blush = 1.0
                p.gazeX = -0.65
                p.gazeY = 0.25
                p.roll = 4 + s * 0.8
                p.sy = 0.985
                p.finL = 0.55
                p.finR = 0.55
                p.finFold = 0.8
                p.hairSway = s * 0.8
            }
            BotFishLifecycle.SMUG -> {
                p.eyeArt = "deadpan"
                p.mouthArt = "smug"
                p.blush = 0.35
                p.roll = -4 + s
                p.smile = 1.0
                p.finL = 0.6
                p.finFold = 0.2
                p.y = -2.0
            }
            BotFishLifecycle.CRYING -> {
                p.eyeArt = "sad"
                p.mouthArt = "sad"
                p.sorrow = 1.0
                p.tears = 1.0
                p.blush = 0.6
                p.y = 2 + abs(s2) * 3
                p.roll = s2 * 0.7
                p.finL = 0.7
                p.finR = 0.7
                p.finFold = 0.8
            }
            BotFishLifecycle.SIGHING -> {
                val exhale = BotFishMath.smooth((phase - 0.35) / 0.45)
                p.eyeArt = if (phase < 0.35) "sleepy" else "laughing"
                p.mouthArt = if (phase < 0.35) "small-o" else "shocked"
                p.y = 2 * exhale - 2 * (1 - exhale)
                p.sy = 1 + 0.018 * sin(phase * PI * 2)
                p.gazeY = 0.3
                p.breath = exhale
                p.roll = exhale * 2
            }
            BotFishLifecycle.CHEERING -> {
                p.eyeArt = "excited"
                p.mouthArt = "laugh"
                p.finL = 0.65 + 0.5 * max(0.0, s)
                p.finR = 0.65 + 0.5 * max(0.0, -s)
                p.finWave = s * 0.6
                p.y = -abs(s) * 8
                p.decoration = "spark"
                p.hairSway = -s * 2
            }
            BotFishLifecycle.BOWING -> {
                val bow = BotFishMath.bump(phase, 0.12, 0.86)
                p.eyeArt = if (bow > 0.45) "laughing" else null
                p.mouthArt = "smile"
                p.y = bow * 15
                p.sy = 1 - bow * 0.09
                p.sx = 1 + bow * 0.025
                p.roll = 0.0
                p.gazeY = bow * 0.6
                p.finL = 0.6
                p.finR = 0.6
                p.finFold = 0.5
                p.hairSway = -bow * 3
            }
            BotFishLifecycle.SHAKING_HEAD -> {
                val shake = sin(phase * PI * 4) * BotFishMath.bump(phase, 0.08, 0.92)
                p.eyeArt = "sleepy"
                p.mouthArt = "pout"
                p.roll = shake * 6
                p.x = shake * 5
                p.gazeX = -shake * 0.5
                p.hairSway = -shake * 4
            }
            BotFishLifecycle.CLAPPING -> {
                val clap = (1 + cos(phase * PI * 4)) * 0.5
                p.eyeArt = "laughing"
                p.mouthArt = "smile-open"
                p.finL = 1.0
                p.finR = 1.0
                p.finFold = 0.2 + 0.8 * clap
                p.finWave = s * 0.15
                p.y = -2 * clap
                p.blush = 0.5
                p.decoration = "spark"
            }
            BotFishLifecycle.STRETCHING -> {
                val stretch = BotFishMath.bump(phase, 0.05, 0.95)
                p.eyeArt = if (stretch > 0.5) "laughing" else "sleepy"
                p.mouthArt = if (stretch > 0.5) "small-o" else "smile"
                p.sy = 1 + 0.055 * stretch
                p.sx = 1 - 0.025 * stretch
                p.finL = 0.2 + stretch
                p.finR = 0.2 + stretch
                p.y = -5 * stretch
                p.finWave = stretch * 0.35
            }
            BotFishLifecycle.YAWNING -> {
                val yawn = BotFishMath.bump(phase, 0.12, 0.85)
                p.eyeArt = if (yawn > 0.3) "laughing" else "sleepy"
                p.mouthArt = if (yawn > 0.3) "yawn" else "small-o"
                p.mouthWidth = 0.5 + 0.5 * yawn
                p.finR = 0.3 + 0.8 * yawn
                p.finFold = yawn * 0.7
                p.sy = 1 + 0.018 * yawn
                p.y = -2 * yawn
            }
            BotFishLifecycle.KISS -> {
                val send = BotFishMath.bump(phase, 0.2, 0.8)
                p.eyeArt = "shy"
                p.mouthArt = "kiss"
                p.finR = 0.5 + 0.65 * send
                p.finFold = 0.8 * (1 - send)
                p.blush = 0.9
                p.roll = -3 * send
                p.decoration = "hearts"
            }
            BotFishLifecycle.HIGH_FIVE -> {
                val up = BotFishMath.bump(phase, 0.05, 0.95)
                p.eyeArt = "excited"
                p.mouthArt = "smile-open"
                p.finR = 0.2 + 1.15 * up
                p.finWave = -0.4 * up
                p.roll = -3 * up
                p.y = -3 * up
                p.sx = 1 + 0.018 * up
                p.decoration = "spark"
            }
            else -> Unit
        }
        return p
    }
}
