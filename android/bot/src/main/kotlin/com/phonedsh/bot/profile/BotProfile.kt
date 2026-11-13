// SPDX-License-Identifier: MIT
package com.phonedsh.bot.profile

/** The fifteen coat colours the desktop DSH bot exposes (declaration order is the seed order). */
public enum class BotFishColor(
    public val wire: String,
    public val hex: String,
    public val displayName: String,
) {
    WHITE("white", "#FFFFFF", "白"),
    BROWN("brown", "#9D6937", "棕"),
    RED("red", "#E5484D", "红"),
    ORANGE("orange", "#F76B15", "橘"),
    AMBER("amber", "#FFB224", "橙黄"),
    GREEN("green", "#14C16F", "绿"),
    TEAL("teal", "#13B7A2", "青绿"),
    BLUE("blue", "#1680F3", "蓝"),
    PURPLE("purple", "#8F59F9", "紫"),
    MAGENTA("magenta", "#F93498", "桃红"),
    GRAY("gray", "#8B8B8B", "灰"),
    BLACK("black", "#1C1C1C", "黑"),
    SILVER("silver", "#C9CBD1", "银"),
    PEACH("peach", "#F3B6A4", "粉肤"),
    SKY("sky", "#7ED0E8", "天蓝"),
    ;

    public companion object {
        public fun fromWire(value: String): BotFishColor? = entries.firstOrNull { it.wire == value }
    }
}

/** The four desktop DSH bot hairstyles. */
public enum class BotFishHairstyle(
    public val wire: String,
    public val displayName: String,
    public val accessibilityHint: String,
) {
    LONG("long", "经典长卷发", "经典长卷发・白褶发箍"),
    TWIN_TAIL("twin-tail", "高双马尾", "高双马尾・大蝴蝶结"),
    BOB("bob", "短鲍伯", "短鲍伯・贝壳珍珠夹"),
    SIDE_BRAID("side-braid", "粗侧辫", "粗侧辫・小贝雷帽"),
    ;

    public companion object {
        public fun fromWire(value: String): BotFishHairstyle? = entries.firstOrNull { it.wire == value }
    }
}

/**
 * One Bot record as stored in dsh-bot `agents-index.json` (record `schema: 3`).
 * This lane owns the pure rules only; the file store's format is not frozen.
 */
public data class BotProfile(
    public val id: String,
    public val name: String,
    /** `null` means automatic (seeded from the Bot id). */
    public val fishColor: BotFishColor? = null,
    /** `null` means automatic (seeded from the Bot id). */
    public val fishHairstyle: BotFishHairstyle? = null,
    public val nameExplicit: Boolean = false,
    public val createdAt: Long = 0,
    public val updatedAt: Long = 0,
    public val description: String = "",
    public val hiddenByUser: Boolean = false,
    public val pinned: Boolean = false,
    public val unreadCount: Int = 0,
    public val lastMessageAt: Long? = null,
)

/** One Bot's resolved visual identity. */
public data class BotFishAppearance(
    public val color: BotFishColor,
    public val hairstyle: BotFishHairstyle,
    public val autoColor: Boolean = false,
    public val autoHairstyle: Boolean = false,
) {
    public companion object {
        /** The historical phoneDSH look and the desktop "new Bot" default. */
        public val CLASSIC: BotFishAppearance = BotFishAppearance(BotFishColor.BLUE, BotFishHairstyle.LONG)

        /**
         * Deterministic desktop DSH seed. The hash is FNV-1a over the
         * JavaScript string's code points, but each code point contributes only
         * its first UTF-16 unit. For BMP scalars that is the scalar value; for
         * an astral scalar (emoji) it is the high surrogate. The golden vector
         * locks this behaviour, so it is not a scalar hash.
         */
        public fun seed(seed: String): BotFishSeedResult {
            val colorIndex = (BotFishSeed.hash(seed) % BotFishColor.entries.size.toLong()).toInt()
            val hairstyleIndex =
                (BotFishSeed.hash(seed + ":hair") % BotFishHairstyle.entries.size.toLong()).toInt()
            return BotFishSeedResult(
                color = BotFishColor.entries[colorIndex],
                hairstyle = BotFishHairstyle.entries[hairstyleIndex],
            )
        }

        /** Explicit stored fields win item by item; missing fields fall back to the seed from `id`, then `name`, then `"fish"`. */
        public fun resolve(profile: BotProfile): BotFishAppearance {
            val seedValue = when {
                profile.id.isNotEmpty() -> profile.id
                profile.name.isNotEmpty() -> profile.name
                else -> "fish"
            }
            val seeded = seed(seedValue)
            return BotFishAppearance(
                color = profile.fishColor ?: seeded.color,
                hairstyle = profile.fishHairstyle ?: seeded.hairstyle,
                autoColor = profile.fishColor == null,
                autoHairstyle = profile.fishHairstyle == null,
            )
        }
    }
}

/** The two seeded fields. */
public data class BotFishSeedResult(
    public val color: BotFishColor,
    public val hairstyle: BotFishHairstyle,
)

/**
 * `null`, `""` and `"auto"` mean automatic; anything else is lower-cased and
 * accepted only when it is an exact known id. There is no trimming: `" blue"`
 * is unknown. Unknown values do not throw; they also mean automatic.
 */
public object BotProfileNormalizer {
    public fun fishColor(raw: String?): BotFishColor? {
        if (raw == null) return null
        val lowered = raw.lowercase()
        if (lowered == "auto" || lowered.isEmpty()) return null
        return BotFishColor.fromWire(lowered)
    }

    public fun fishHairstyle(raw: String?): BotFishHairstyle? {
        if (raw == null) return null
        val lowered = raw.lowercase()
        if (lowered == "auto" || lowered.isEmpty()) return null
        return BotFishHairstyle.fromWire(lowered)
    }
}

/** FNV-1a 32-bit with JavaScript `Math.imul`-compatible wrapping. */
private object BotFishSeed {
    private const val OFFSET_BASIS: Long = 2_166_136_261L
    private const val PRIME: Long = 16_777_619L
    private const val MASK: Long = 0xFFFFFFFFL

    fun hash(value: String): Long {
        var hash = OFFSET_BASIS
        var index = 0
        while (index < value.length) {
            val codePoint = value.codePointAt(index)
            val unit = if (codePoint <= 0xFFFF) {
                codePoint
            } else {
                val offset = codePoint - 0x10000
                0xD800 + (offset shr 10)
            }
            hash = ((hash xor unit.toLong()) * PRIME) and MASK
            index += Character.charCount(codePoint)
        }
        return hash
    }
}
