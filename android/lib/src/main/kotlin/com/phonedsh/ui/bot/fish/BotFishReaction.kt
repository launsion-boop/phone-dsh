// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.fish

import com.phonedsh.bot.fish.BotFishLifecycle

/** `standard` or the app-only `lively` clip set (`BotFishMotionProfile.swift`). */
public enum class BotFishMotionProfile { STANDARD, LIVELY }

/** App-only `.working` sub-style; never a lifecycle value. */
public enum class BotFishWorkStyle { GENERIC, READING, SEARCHING, RUNNING, WRITING }

/** One Agent-driven cosmetic overlay (`BotFishReactions.swift:74-97`). */
public enum class BotFishReactionKind { ACTION, EXPRESSION }

/** A reaction sampled by name; the lifecycle lookup is the same 42-case enum. */
public data class BotFishReaction(
    public val id: String,
    public val kind: BotFishReactionKind,
    public val name: String,
    public val startedAt: Long = 0,
    public val durationMs: Long,
) {
    public val lifecycle: BotFishLifecycle? get() = BotFishLifecycle.fromWire(name)
}

/** The frozen action/expression vocabulary and TTLs (`BotFishReactions.swift:8-44`). */
public object BotFishReactionVocabulary {
    public val actions: List<String> = listOf(
        "waving", "bowing", "clapping", "kiss", "cheering", "shy", "smug", "crying",
        "sighing", "shaking-head", "stretching", "yawning", "high-five", "nod",
        "celebrate", "dancing",
    )

    public val expressions: List<String> = listOf(
        "happy", "sad", "surprised", "confused", "laughing", "love", "angry", "wink",
    )

    public const val EXPRESSION_DURATION_MS: Long = 4_000

    private val actionDurations: Map<String, Long> = mapOf(
        "waving" to 1_600, "bowing" to 2_800, "clapping" to 1_200, "kiss" to 2_600,
        "cheering" to 1_600, "shy" to 3_200, "smug" to 2_600, "crying" to 2_400,
        "sighing" to 3_600, "shaking-head" to 2_400, "stretching" to 4_200,
        "yawning" to 4_800, "high-five" to 2_200, "nod" to 2_000,
        "celebrate" to 1_500, "dancing" to 1_800,
    )

    public fun kindFor(name: String): BotFishReactionKind? = when {
        actionDurations.containsKey(name) -> BotFishReactionKind.ACTION
        expressions.contains(name) -> BotFishReactionKind.EXPRESSION
        else -> null
    }

    public fun durationMsFor(name: String): Long? = when (kindFor(name)) {
        BotFishReactionKind.ACTION -> actionDurations[name]
        BotFishReactionKind.EXPRESSION -> EXPRESSION_DURATION_MS
        null -> null
    }
}
