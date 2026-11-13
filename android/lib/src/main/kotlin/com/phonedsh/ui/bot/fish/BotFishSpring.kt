// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import kotlin.math.abs
import kotlin.math.min

/**
 * Critically damped spring stepped in at most 1/120 s substeps
 * (`BotFishModel.swift:702-728`, fish.md §6.1).
 */
public class BotFishSpring(
    public var value: Double = 0.0,
    public val omega: Double = 18.0,
) {
    public var velocity: Double = 0.0
    public var target: Double = value

    public fun step(dt: Double): Double {
        var left = BotFishMath.clamp(dt, 0.0, 0.1)
        while (left > 1e-8) {
            val h = min(left, 1.0 / 120.0)
            velocity += (-2 * omega * velocity - omega * omega * (value - target)) * h
            value += velocity * h
            left -= h
        }
        return value
    }

    public val settled: Boolean
        get() = abs(value - target) < 0.0002 && abs(velocity) < 0.0002
}
