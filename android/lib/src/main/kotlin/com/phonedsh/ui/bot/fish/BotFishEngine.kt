// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import com.phonedsh.bot.fish.BotFishLifecycle
import com.phonedsh.bot.profile.BotFishAppearance
import kotlin.math.max
import kotlin.math.min

/** One display-ready numeric frame; rasterisation lives in the Compose layer. */
public data class BotFishFrame(
    public val timeMs: Double,
    public val params: BotFishParams,
    public val pose: BotFishPose,
    public val alpha: Double,
    public val needsAnimation: Boolean,
    public val pixelSide: Int,
    public val viewMotionScale: Double,
)

/**
 * Numeric part of the Swift `BotFishEngine` (`BotFishEngine.swift:555-667`):
 * configure-before-step, view amplification, pose quantisation and alpha.
 * Pixel preparation is deliberately separate ([BotFishRenderer]) so this
 * class stays host-JVM testable.
 */
public class BotFishEngine(
    random: () -> Double = { kotlin.random.Random.nextDouble() },
) {
    public val machine: BotFishStateMachine = BotFishStateMachine(random = random)
    public var currentFrame: BotFishFrame? = null
        private set

    private var lastTimestampMs: Double? = null
    private var configuredState: BotFishLifecycle = machine.state
    private var configuredProfile: BotFishMotionProfile = machine.profile
    private var configuredWorkStyle: BotFishWorkStyle = machine.workStyle
    private var configuredReactionID: String? = null

    public val needsAnimation: Boolean get() = machine.needsAnimation

    public fun configure(
        state: BotFishLifecycle,
        still: Boolean,
        reducedMotion: Boolean,
        reaction: BotFishReaction? = null,
        profile: BotFishMotionProfile = BotFishMotionProfile.STANDARD,
        workStyle: BotFishWorkStyle = BotFishWorkStyle.GENERIC,
    ) {
        if (configuredProfile != profile || configuredWorkStyle != workStyle) {
            configuredProfile = profile
            configuredWorkStyle = workStyle
            machine.updateProfile(profile, workStyle)
        }
        // `.poke` is a transient: compare the last requested value rather than
        // the machine's lifecycle state (`BotFishEngine.swift:537-541`).
        if (configuredState != state) {
            configuredState = state
            machine.setState(state)
        }
        if (machine.isStatic != still || machine.reduced != reducedMotion) {
            machine.updateFlags(isStatic = still, reduced = reducedMotion)
        }
        if (configuredReactionID != reaction?.id) {
            configuredReactionID = reaction?.id
            if (reaction != null) {
                machine.playReaction(reaction)
            } else {
                machine.clearReaction()
            }
        }
    }

    /** Advances with an already-computed clamped delta in milliseconds. */
    public fun advanceBy(
        deltaMs: Double,
        state: BotFishLifecycle,
        still: Boolean,
        reducedMotion: Boolean,
        sizePt: Double,
        displayScale: Double,
        appearance: BotFishAppearance = BotFishAppearance.CLASSIC,
        crowned: Boolean = false,
        reaction: BotFishReaction? = null,
        profile: BotFishMotionProfile = BotFishMotionProfile.STANDARD,
        workStyle: BotFishWorkStyle = BotFishWorkStyle.GENERIC,
    ): BotFishFrame {
        configure(state, still, reducedMotion, reaction, profile, workStyle)
        val raw = machine.step(deltaMs)

        // Small avatars get the upstream 2.2× readable-motion boost. The boost
        // is applied to a copy so the trajectory params stay pre-amplification.
        val boost = if (raw.isLivelyMotion) 1.0 else BotFishGeometry.motionBoost(sizePt)
        val amplified = raw.copy()
        amplified.motionScale = boost
        if (boost > 1) {
            amplified.x = BotFishMath.clamp(
                amplified.x * boost,
                -BotFishGeometry.MOTION_BOOST_MAX_TRANSLATION,
                BotFishGeometry.MOTION_BOOST_MAX_TRANSLATION,
            )
            amplified.y = BotFishMath.clamp(
                amplified.y * boost,
                -BotFishGeometry.MOTION_BOOST_MAX_TRANSLATION,
                BotFishGeometry.MOTION_BOOST_MAX_TRANSLATION,
            )
            amplified.roll = BotFishMath.clamp(
                amplified.roll * boost,
                -BotFishGeometry.MOTION_BOOST_MAX_ROLL,
                BotFishGeometry.MOTION_BOOST_MAX_ROLL,
            )
        }

        val pixelSide = BotFishGeometry.pixelSide(sizePt, displayScale)
        val pose = BotFishGeometry.pose(amplified, sizePt, pixelSide, crowned)
        val frame = BotFishFrame(
            timeMs = machine.time,
            params = raw,
            pose = pose,
            alpha = BotFishGeometry.quantisedAlpha(raw.alpha),
            needsAnimation = machine.needsAnimation,
            pixelSide = pixelSide,
            viewMotionScale = if (raw.isLivelyMotion) 1.0 else boost,
        )
        currentFrame = frame
        return frame
    }

    /**
     * Wall-clock advance: the first call has delta 0 and later deltas are
     * clamped to the 100 ms ceiling (fish.md §3.3).
     */
    public fun advance(
        nowMs: Double,
        state: BotFishLifecycle,
        still: Boolean,
        reducedMotion: Boolean,
        sizePt: Double,
        displayScale: Double,
        appearance: BotFishAppearance = BotFishAppearance.CLASSIC,
        crowned: Boolean = false,
        reaction: BotFishReaction? = null,
        profile: BotFishMotionProfile = BotFishMotionProfile.STANDARD,
        workStyle: BotFishWorkStyle = BotFishWorkStyle.GENERIC,
    ): BotFishFrame {
        val delta = lastTimestampMs?.let { previous ->
            min(100.0, max(0.0, nowMs - previous))
        } ?: 0.0
        lastTimestampMs = nowMs
        return advanceBy(
            deltaMs = delta,
            state = state,
            still = still,
            reducedMotion = reducedMotion,
            sizePt = sizePt,
            displayScale = displayScale,
            appearance = appearance,
            crowned = crowned,
            reaction = reaction,
            profile = profile,
            workStyle = workStyle,
        )
    }

    public fun poke() {
        machine.poke()
    }

    public fun resetClock() {
        lastTimestampMs = null
    }
}
