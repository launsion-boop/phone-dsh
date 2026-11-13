// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import com.phonedsh.bot.fish.BotFishLifecycle
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * Port of the Swift `BotFishStateMachine`
 * (`examples/probe-app/PhoneDSHProbe/Bot/Fish/BotFishEngine.swift:61-486`,
 * fish.md §6). The machine is deterministic apart from [random]; the
 * trajectory supplies its consumed LCG prefix.
 */
public class BotFishStateMachine(
    state: BotFishLifecycle = BotFishLifecycle.IDLE,
    reduced: Boolean = false,
    isStatic: Boolean = false,
    profile: BotFishMotionProfile = BotFishMotionProfile.STANDARD,
    workStyle: BotFishWorkStyle = BotFishWorkStyle.GENERIC,
    private val random: () -> Double = { kotlin.random.Random.nextDouble() },
) {
    private val pokeOnInit: Boolean = state == BotFishLifecycle.POKE
    public var state: BotFishLifecycle = if (state == BotFishLifecycle.POKE) {
        BotFishLifecycle.IDLE
    } else {
        state
    }
        private set
    public var time: Double = 0.0
        private set
    public var elapsed: Double = 0.0
        private set
    public var isStatic: Boolean = isStatic
        private set
    public var reduced: Boolean = reduced
        private set
    public var profile: BotFishMotionProfile = profile
        private set
    public var workStyle: BotFishWorkStyle = workStyle
        private set

    private val playing: Boolean = true
    private var idleEntered: Double = 0.0
    private var nextIdleAt: Double = Double.POSITIVE_INFINITY
    private var nextBlinkAt: Double = Double.POSITIVE_INFINITY

    private val poseXSpring = BotFishSpring(0.0, BotFishLivelyMotion.POSE_SPRING_OMEGA)
    private val poseYSpring = BotFishSpring(0.0, BotFishLivelyMotion.POSE_SPRING_OMEGA)
    private val poseRollSpring = BotFishSpring(0.0, BotFishLivelyMotion.POSE_SPRING_OMEGA)
    private val poseScaleXSpring = BotFishSpring(1.0, BotFishLivelyMotion.POSE_SPRING_OMEGA)
    private val poseScaleYSpring = BotFishSpring(1.0, BotFishLivelyMotion.POSE_SPRING_OMEGA)

    private var directGaze: Pair<Double, Double>? = null
    private var lookOverride: Triple<Double, Double, Double>? = null
    private var blinkStart: Double = Double.NEGATIVE_INFINITY
    private var pokeStart: Double = Double.NEGATIVE_INFINITY
    private val morphTarget: Pair<Double, Double> = 1.0 to 1.0

    private val faceSprings = LinkedHashMap<BotFishFaceKey, BotFishSpring>()
    private val gazeXSpring = BotFishSpring(0.0, omega = 23.0)
    private val gazeYSpring = BotFishSpring(0.0, omega = 23.0)
    private val headXSpring = BotFishSpring(0.0, omega = 8.0)
    private val headYSpring = BotFishSpring(0.0, omega = 8.0)
    private val bodyXSpring = BotFishSpring(0.0, omega = 5.0)
    private val bodyYSpring = BotFishSpring(0.0, omega = 5.0)
    private val morphXSpring = BotFishSpring(1.0, omega = 13.0)
    private val morphYSpring = BotFishSpring(1.0, omega = 13.0)

    private var artFrom: Pair<String?, String?>? = null
    private var artStart: Double = Double.NEGATIVE_INFINITY
    private var last: BotFishParams? = null

    private var reaction: BotFishReaction? = null
    private var reactionLifecycle: BotFishLifecycle? = null
    private var reactionStart: Double = Double.NEGATIVE_INFINITY

    public val currentParams: BotFishParams? get() = last
    public val currentTime: Double get() = time

    public val activeReaction: BotFishReaction?
        get() {
            val value = reaction ?: return null
            if (reactionLifecycle == null) return null
            if (time < reactionStart) return null
            if (time - reactionStart >= value.durationMs.toDouble()) return null
            return value
        }

    public val hasActiveReaction: Boolean get() = activeReaction != null

    init {
        armIdle()
        armBlink()
        if (pokeOnInit) {
            poke()
        }
    }

    private fun armIdle() {
        nextIdleAt = if (
            state == BotFishLifecycle.IDLE && playing && !reduced && !isStatic
        ) {
            time + 6000 + BotFishMath.clamp(random(), 0.0, 1.0) * 6000
        } else {
            Double.POSITIVE_INFINITY
        }
    }

    private fun armBlink() {
        if (profile != BotFishMotionProfile.LIVELY || !playing || reduced || isStatic) {
            nextBlinkAt = Double.POSITIVE_INFINITY
            return
        }
        nextBlinkAt = time + BotFishLivelyMotion.BLINK_INTERVAL_LOWER_MS +
            BotFishMath.clamp(random(), 0.0, 1.0) *
            (BotFishLivelyMotion.BLINK_INTERVAL_UPPER_MS -
                BotFishLivelyMotion.BLINK_INTERVAL_LOWER_MS)
    }

    public fun updateFlags(isStatic: Boolean? = null, reduced: Boolean? = null) {
        if (isStatic != null) this.isStatic = isStatic
        if (reduced != null) this.reduced = reduced
        armIdle()
        armBlink()
    }

    public fun updateProfile(profile: BotFishMotionProfile, workStyle: BotFishWorkStyle) {
        if (profile == this.profile && workStyle == this.workStyle) return
        this.profile = profile
        this.workStyle = workStyle
        last?.let { frame ->
            poseXSpring.value = frame.x
            poseYSpring.value = frame.y
            poseRollSpring.value = frame.roll
            poseScaleXSpring.value = frame.sx
            poseScaleYSpring.value = frame.sy
        }
        armIdle()
        armBlink()
    }

    public fun setState(value: BotFishLifecycle): Boolean {
        if (value == BotFishLifecycle.POKE) {
            poke()
            return true
        }
        if (value == state) return true
        artFrom = last?.let { it.eyeArt to it.mouthArt }
        if (profile == BotFishMotionProfile.LIVELY) {
            last?.let { frame ->
                poseXSpring.value = frame.x
                poseXSpring.velocity = 0.0
                poseYSpring.value = frame.y
                poseYSpring.velocity = 0.0
                poseRollSpring.value = frame.roll
                poseRollSpring.velocity = 0.0
                poseScaleXSpring.value = frame.sx
                poseScaleXSpring.velocity = 0.0
                poseScaleYSpring.value = frame.sy
                poseScaleYSpring.velocity = 0.0
            }
        }
        artStart = time
        state = value
        elapsed = 0.0
        lookOverride = null
        blinkStart = Double.NEGATIVE_INFINITY
        pokeStart = Double.NEGATIVE_INFINITY
        idleEntered = time
        armIdle()
        return true
    }

    public fun poke() {
        if (reaction?.kind == BotFishReactionKind.ACTION) clearReaction()
        pokeStart = time
        blinkStart = Double.NEGATIVE_INFINITY
        lookOverride = null
    }

    public fun playReaction(value: BotFishReaction): Boolean {
        val lifecycle = value.lifecycle ?: return false
        artFrom = last?.let { it.eyeArt to it.mouthArt }
        artStart = time
        reaction = value
        reactionLifecycle = lifecycle
        reactionStart = time
        if (value.kind == BotFishReactionKind.ACTION) {
            pokeStart = Double.NEGATIVE_INFINITY
            blinkStart = Double.NEGATIVE_INFINITY
            lookOverride = null
        }
        return true
    }

    public fun clearReaction() {
        if (reaction == null) return
        artFrom = last?.let { it.eyeArt to it.mouthArt }
        artStart = time
        reaction = null
        reactionLifecycle = null
        reactionStart = Double.NEGATIVE_INFINITY
    }

    private fun expireReactionIfNeeded() {
        val value = reaction ?: return
        if (time - reactionStart < value.durationMs.toDouble()) return
        artFrom = last?.let { it.eyeArt to it.mouthArt }
        artStart = time
        reaction = null
        reactionLifecycle = null
        reactionStart = Double.NEGATIVE_INFINITY
    }

    private fun reactionSampleTime(value: BotFishReaction, expression: Boolean): Double {
        if (isStatic || reduced) {
            if (expression) return BotFishFrameClock.FREEZE_SAMPLE_MS
            val phase = STATIC_ACTION_PHASE[value.name] ?: 0.25
            return max(1.0, value.durationMs.toDouble() * phase)
        }
        return max(0.0, time - reactionStart)
    }

    private fun blink() {
        blinkStart = time
    }

    private fun springFor(key: BotFishFaceKey, initial: Double): BotFishSpring =
        faceSprings.getOrPut(key) { BotFishSpring(initial, omega = 22.0) }

    public fun step(dtMilliseconds: Double): BotFishParams {
        val dt = BotFishMath.clamp(dtMilliseconds, 0.0, 100.0)
        time += dt
        if (playing && !isStatic) elapsed += dt

        if (
            profile == BotFishMotionProfile.STANDARD &&
            state == BotFishLifecycle.IDLE &&
            reaction == null &&
            time - idleEntered >= 3000 &&
            time >= nextIdleAt &&
            playing && !reduced && !isStatic
        ) {
            if (random() < 0.6) {
                blink()
            } else {
                val directions = listOf(
                    -0.8 to 0.0,
                    0.8 to 0.0,
                    0.0 to -0.7,
                )
                val index = min(2, floor(random() * 3).toInt())
                val direction = directions[index]
                lookOverride = Triple(direction.first, direction.second, time + 700)
            }
            armIdle()
        }
        if (
            profile == BotFishMotionProfile.LIVELY &&
            playing && !reduced && !isStatic &&
            time >= nextBlinkAt
        ) {
            blink()
            armBlink()
        }

        expireReactionIfNeeded()
        val pokeAge = time - pokeStart
        val poking = pokeAge >= 0 && pokeAge < 420
        val stateTime = if (reduced || isStatic) {
            BotFishFrameClock.FREEZE_SAMPLE_MS
        } else {
            elapsed
        }
        val active = activeReaction
        val action = if (active?.kind == BotFishReactionKind.ACTION) active else null
        val expression = if (active?.kind == BotFishReactionKind.EXPRESSION) active else null

        val sampledState: BotFishLifecycle
        val sampledTime: Double
        if (poking) {
            sampledState = BotFishLifecycle.POKE
            sampledTime = pokeAge
        } else if (action != null && reactionLifecycle != null) {
            sampledState = reactionLifecycle!!
            sampledTime = reactionSampleTime(action, expression = false)
        } else {
            sampledState = state
            sampledTime = stateTime
        }

        val livelySample = if (
            profile == BotFishMotionProfile.LIVELY && !poking && action == null
        ) {
            BotFishLivelyMotion.sample(sampledState, workStyle, stateTime)
        } else {
            null
        }
        val p = livelySample ?: BotFishModel.sample(sampledState, sampledTime)

        if (!poking && expression != null && reactionLifecycle != null) {
            val face = BotFishModel.sample(
                reactionLifecycle!!,
                reactionSampleTime(expression, expression = true),
            )
            for (key in BotFishFaceKey.entries) {
                p.setFaceValue(key, face.faceValue(key))
            }
            p.eyeArt = face.eyeArt
            p.mouthArt = face.mouthArt
            p.puff = face.puff
            if (reactionLifecycle == BotFishLifecycle.LOVE) {
                p.decoration = "hearts"
            }
        }

        for (key in BotFishFaceKey.entries) {
            val target = p.faceValue(key)
            val spring = springFor(key, target)
            spring.target = target
            if (reduced || isStatic) {
                spring.value = target
                spring.velocity = 0.0
            }
            p.setFaceValue(key, spring.step(dt / 1000))
        }

        val look = lookOverride
        if (look != null && time >= look.third) {
            lookOverride = null
        }
        val gaze = lookOverride?.let { it.first to it.second } ?: directGaze ?: (0.0 to 0.0)

        gazeXSpring.target = BotFishMath.clamp(gaze.first + p.gazeX, -1.0, 1.0)
        gazeYSpring.target = BotFishMath.clamp(gaze.second + p.gazeY, -1.0, 1.0)
        if (reduced || isStatic) {
            gazeXSpring.value = gazeXSpring.target
            gazeYSpring.value = gazeYSpring.target
        }
        p.gazeX = gazeXSpring.step(dt / 1000)
        p.gazeY = gazeYSpring.step(dt / 1000)

        if (profile == BotFishMotionProfile.LIVELY) {
            headXSpring.target = BotFishMath.clamp(gaze.first + p.headX, -2.0, 2.0)
            headYSpring.target = BotFishMath.clamp(gaze.second + p.headY, -1.0, 1.0)
        } else {
            headXSpring.target = gaze.first
            headYSpring.target = gaze.second
        }
        p.headX = headXSpring.step(dt / 1000)
        p.headY = headYSpring.step(dt / 1000)
        bodyXSpring.target = p.headX
        bodyYSpring.target = p.headY
        p.bodyX = bodyXSpring.step(dt / 1000)
        p.bodyY = bodyYSpring.step(dt / 1000)
        p.x += p.bodyX * 1.6
        p.y += p.bodyY * 0.9
        p.roll += p.bodyX * 0.35

        val blinkAge = time - blinkStart
        var blink = 1.0
        if (blinkAge >= 0 && blinkAge < BotFishFrameClock.BLINK_DURATION_MS) {
            val q = blinkAge / BotFishFrameClock.BLINK_DURATION_MS
            blink = if (q < 0.45) 1 - q / 0.45 else (q - 0.45) / 0.55
        }
        p.blink = max(0.02, blink)

        morphXSpring.target = morphTarget.first
        morphYSpring.target = morphTarget.second
        p.morphX = morphXSpring.step(dt / 1000)
        p.morphY = morphYSpring.step(dt / 1000)

        if (reduced || isStatic) {
            p.headX = 0.0
            p.headY = 0.0
            p.bodyX = 0.0
            p.bodyY = 0.0
        }
        if (reduced) {
            p.hairSway = 0.0
            p.earFlutter = 0.0
            p.x = 0.0
            p.y = 0.0
            p.roll = 0.0
            p.sx = 1.0
            p.sy = 1.0
            p.morphX = 1.0
            p.morphY = 1.0
            p.finWave = 0.0
        }
        if (profile == BotFishMotionProfile.LIVELY) {
            poseXSpring.target = p.x
            poseYSpring.target = p.y
            poseRollSpring.target = p.roll
            poseScaleXSpring.target = p.sx
            poseScaleYSpring.target = p.sy
            if (reduced || isStatic) {
                poseXSpring.value = p.x
                poseYSpring.value = p.y
                poseRollSpring.value = p.roll
                poseScaleXSpring.value = p.sx
                poseScaleYSpring.value = p.sy
                poseXSpring.velocity = 0.0
                poseYSpring.velocity = 0.0
                poseRollSpring.velocity = 0.0
                poseScaleXSpring.velocity = 0.0
                poseScaleYSpring.velocity = 0.0
            }
            p.x = poseXSpring.step(dt / 1000)
            p.y = poseYSpring.step(dt / 1000)
            p.roll = poseRollSpring.step(dt / 1000)
            p.sx = poseScaleXSpring.step(dt / 1000)
            p.sy = poseScaleYSpring.step(dt / 1000)
        }

        p.artMix = if (reduced || isStatic) {
            1.0
        } else {
            BotFishMath.clamp((time - artStart) / 180, 0.0, 1.0)
        }
        p.eyeArtPrev = artFrom?.first
        p.mouthArtPrev = artFrom?.second
        last = p
        return p
    }

    public val needsAnimation: Boolean
        get() {
            if (reaction != null) return true
            val clip = BotFishClip.forState(state)
            val continuous = playing && !reduced && !isStatic && !clip.isStatic &&
                (clip.period != null || elapsed < (clip.duration ?: 0.0))
            if (continuous) return true
            if (!reduced && !isStatic && time - artStart < 180) return true
            val pokeAge = time - pokeStart
            if (pokeAge >= 0 && pokeAge < 420) return true
            val blinkAge = time - blinkStart
            if (blinkAge >= 0 && blinkAge < BotFishFrameClock.BLINK_DURATION_MS) return true
            if (lookOverride != null) return true
            for (spring in listOf(
                gazeXSpring, gazeYSpring, headXSpring, headYSpring,
                bodyXSpring, bodyYSpring, morphXSpring, morphYSpring,
            )) {
                if (!spring.settled) return true
            }
            for (spring in faceSprings.values) {
                if (!spring.settled) return true
            }
            return false
        }

    private companion object {
        /**
         * Static/reduced sampling phase per action
         * (`BotFishEngine.swift:259-265`). An unknown name defaults to .25.
         */
        val STATIC_ACTION_PHASE: Map<String, Double> = mapOf(
            "waving" to 0.25, "bowing" to 0.50, "clapping" to 0.125, "kiss" to 0.50,
            "cheering" to 0.25, "shy" to 0.50, "smug" to 0.50, "crying" to 0.50,
            "sighing" to 0.60, "shaking-head" to 0.125, "stretching" to 0.50,
            "yawning" to 0.50, "high-five" to 0.50, "nod" to 0.25,
            "celebrate" to 0.25, "dancing" to 0.25,
        )
    }
}
