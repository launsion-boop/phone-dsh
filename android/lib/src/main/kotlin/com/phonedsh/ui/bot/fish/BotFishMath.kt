// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.sin

/**
 * The scalar helpers frozen by `spec/ui/v1/bot/fish/fish.md` §5.3 and ported
 * from `BotFishModel.swift:11-31`.
 */
public object BotFishMath {
    public fun clamp(value: Double, lower: Double, upper: Double): Double =
        maxOf(lower, minOf(upper, value))

    public fun lerp(a: Double, b: Double, t: Double): Double = a + (b - a) * t

    /** `ease` in the upstream model (`smoothstep` after clamping). */
    public fun smooth(value: Double): Double {
        val t = clamp(value, 0.0, 1.0)
        return t * t * (3 - 2 * t)
    }

    /**
     * Swift `Double.rounded()`: nearest integer, ties away from zero. Kotlin
     * `kotlin.math.round` is not guaranteed to use the same tie rule on every
     * platform, so the frozen arithmetic spells it out.
     */
    public fun roundHalfAway(value: Double): Double =
        if (value >= 0) floor(value + 0.5) else ceil(value - 0.5)

    public fun bump(x: Double, a: Double, b: Double): Double {
        if (x <= a || x >= b) return 0.0
        val s = sin((x - a) / (b - a) * PI)
        return s * s
    }
}
