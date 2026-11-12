// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import com.phonedsh.bot.profile.BotFishColor

/**
 * One 256-entry tint palette built from a Bot colour
 * (`BotFishAssets.swift:30-96`, fish.md §8.2). `lut` is 768 bytes in RGB order.
 */
public class BotFishPalette private constructor(
    public val id: String,
    public val hex: String,
    public val lut: IntArray,
    public val ink: IntArray,
    public val mid: IntArray,
    public val light: IntArray,
) {
    public companion object {
        /** The fixed classic fish colour, `#1680F3`. */
        public val BLUE: BotFishPalette = fromHex("blue", "#1680F3")

        public fun forColor(color: BotFishColor): BotFishPalette = fromHex(color.wire, color.hex)

        private fun fromHex(id: String, hex: String): BotFishPalette {
            val raw = hex.removePrefix("#")
            val value = raw.toLongOrNull(16) ?: 0x1680F3
            val rgb = doubleArrayOf(
                ((value shr 16) and 0xFF).toDouble(),
                ((value shr 8) and 0xFF).toDouble(),
                (value and 0xFF).toDouble(),
            )

            fun shade(amount: Double, white: Double = 0.0): IntArray = IntArray(3) { channel ->
                BotFishMath.roundHalfAway(BotFishMath.lerp(rgb[channel] * amount, 255.0, white)).toInt()
            }

            val stops = listOf(
                0.00 to intArrayOf(13, 15, 25),
                0.20 to shade(0.25),
                0.48 to shade(0.52),
                0.73 to intArrayOf(rgb[0].toInt(), rgb[1].toInt(), rgb[2].toInt()),
                0.91 to shade(1.0, white = 0.36),
                1.00 to shade(1.0, white = 0.73),
            )

            val lut = IntArray(256 * 3)
            for (index in 0..255) {
                val x = index.toDouble() / 255
                var lower = stops[0]
                var upper = stops[stops.size - 1]
                for (candidate in 1 until stops.size) {
                    if (x <= stops[candidate].first) {
                        lower = stops[candidate - 1]
                        upper = stops[candidate]
                        break
                    }
                }
                val span = upper.first - lower.first
                val t = if (span == 0.0) 0.0 else (x - lower.first) / span
                for (channel in 0..2) {
                    val value = BotFishMath.roundHalfAway(
                        BotFishMath.lerp(
                            lower.second[channel].toDouble(),
                            upper.second[channel].toDouble(),
                            t,
                        ),
                    ).toInt()
                    lut[index * 3 + channel] = value.coerceIn(0, 255)
                }
            }

            return BotFishPalette(
                id = id,
                hex = hex,
                lut = lut,
                ink = shade(0.22),
                mid = intArrayOf(rgb[0].toInt(), rgb[1].toInt(), rgb[2].toInt()),
                light = shade(1.0, white = 0.5),
            )
        }
    }
}
