// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonValue
import com.phonedsh.bot.BotJson
import java.net.URI

/** One resolved tool phrase: category always follows the tool name. */
public data class BotToolActivityPhrase(
    public val category: BotActivityCategory,
    public val text: String,
)

/**
 * The frozen tool -> category/phrase table, model-description cleaning, target
 * rendering, rotation phrases and minute suffix (`activity-phrases.json`).
 *
 * The values are generated in [BotActivityPhraseData] and proven equal to that
 * JSON by `BotActivityPhraseDataGoldenTest`; this object only owns the pure
 * selection rules.
 */
public object BotActivityPhrases {
    private val RULES: Map<String, BotActivityRule> get() = BotActivityPhraseData.RULES

    /** Resolves one `tool/call`; a model description wins over the table phrase. */
    public fun toolActivity(
        rawToolName: String,
        arguments: Map<String, JsonValue> = emptyMap(),
    ): BotToolActivityPhrase {
        val rule = RULES[bareToolName(rawToolName).lowercase()] ?: genericRule()
        modelText(arguments)?.let { raw ->
            cleanedModelText(raw)?.let { text ->
                return BotToolActivityPhrase(rule.category, text)
            }
        }
        if (rule.category == BotActivityCategory.GENERIC) {
            return BotToolActivityPhrase(BotActivityCategory.GENERIC, "")
        }
        val target = targetText(rule, arguments)
        return BotToolActivityPhrase(
            category = rule.category,
            text = if (target.isEmpty()) rule.phrase else "${rule.phrase} · $target",
        )
    }

    /** The category alone, for callers that only need the avatar style. */
    public fun categoryForTool(rawToolName: String): BotActivityCategory =
        (RULES[bareToolName(rawToolName).lowercase()] ?: genericRule()).category

    /** `mcp__phone__ReadMemory` -> `ReadMemory`; other names pass through. */
    public fun bareToolName(rawName: String): String {
        val prefix = BotActivityPhraseData.BARE_TOOL_PREFIX
        if (!rawName.startsWith(prefix)) return rawName
        val parts = rawName.split("__")
        if (parts.size <= 2) return rawName
        return parts.drop(2).joinToString("__")
    }

    /** Trim, strip trailing sentence punctuation, then cap at 20 code points. */
    public fun cleanedModelText(raw: String?): String? {
        if (raw == null) return null
        var text = raw.trim()
        if (text.isEmpty()) return null
        val punctuation = BotActivityPhraseData.STRIP_TRAILING_PUNCTUATION
        while (text.isNotEmpty() && text.last() in punctuation) {
            text = text.dropLast(1)
        }
        text = text.trim()
        if (text.isEmpty()) return null
        return capByCodePoints(
            text,
            BotActivityPhraseData.MAX_CHARACTERS,
            BotActivityPhraseData.TRUNCATE_AT,
            BotActivityPhraseData.ELLIPSIS,
        )
    }

    /** The displayed target: last path component or URL host, capped at 42. */
    public fun shortTarget(value: String): String {
        val text = value.trim()
        val base = text.split('/', '\\').filter { it.isNotEmpty() }.lastOrNull() ?: text
        return capByCodePoints(
            base,
            BotActivityPhraseData.TARGET_MAX_CHARACTERS,
            BotActivityPhraseData.TARGET_TRUNCATE_AT,
            BotActivityPhraseData.ELLIPSIS,
        )
    }

    /** The host of a URL candidate, without a leading `www.`; null when absent. */
    public fun urlHost(value: String): String? {
        val trimmed = value.trim()
        val candidate = if (trimmed.contains("://")) trimmed else "https://$trimmed"
        val host = try {
            URI(candidate).host
        } catch (_: Exception) {
            null
        }
        if (host.isNullOrEmpty()) return null
        return if (host.startsWith("www.")) host.substring(4) else host
    }

    /** Reviewing text carries the finished call's target; empty rotates. */
    public fun reviewingText(
        rawToolName: String,
        arguments: Map<String, JsonValue> = emptyMap(),
    ): String {
        val rule = RULES[bareToolName(rawToolName).lowercase()] ?: genericRule()
        if (rule.category == BotActivityCategory.GENERIC) return ""
        val target = targetText(rule, arguments)
        if (target.isEmpty()) return ""
        return "${primaryPhrase(BotActivityCategory.REVIEWING)} · $target"
    }

    /** Phrases used when the activity has no concrete detail. */
    public fun rotationPhrases(activity: BotActivity): List<String> {
        // A concrete detail is the whole list: it never rotates, and the
        // golden rotation case (`detail-suppresses-rotation`) freezes that.
        if (activity.detail.isNotEmpty()) return listOf(activity.detail)
        return BotActivityPhraseData.ROTATION[activity.category]
            ?: listOf(primaryPhrase(activity.category))
    }

    public fun primaryPhrase(category: BotActivityCategory): String =
        BotActivityPhraseData.PRIMARY[category]
            ?: BotUiStrings.ACTIVITY_GENERIC_PRIMARY

    /** The App-only lively working sub-style for a category. */
    public fun workStyle(category: BotActivityCategory): BotWorkStyle =
        BotActivityPhraseData.WORK_STYLE[category] ?: BotWorkStyle.GENERIC

    /** `0` before a full minute, then the whole minutes for the same activity. */
    public fun sustainedMinutes(activity: BotActivity, now: Long): Int {
        val start = activity.startedAt
        if (start <= 0 || now < start) return 0
        val elapsed = now - start
        if (elapsed < BotActivityPhraseData.MINUTE_MILLIS) return 0
        return maxOf(1, (elapsed / BotActivityPhraseData.MINUTE_MILLIS).toInt())
    }

    private fun targetText(rule: BotActivityRule, arguments: Map<String, JsonValue>): String {
        for (key in rule.targetKeys) {
            val value = arguments[key] ?: continue
            if (rule.targetArray && value is com.phonedsh.agentcore.JsonArray) {
                val first = value.values.firstNotNullOfOrNull { item ->
                    (item as? com.phonedsh.agentcore.JsonString)?.value?.takeIf { it.isNotEmpty() }
                }
                if (first != null) return shortTarget(first)
                continue
            }
            val text = JsonSupport.string(value) ?: continue
            if (text.isEmpty()) continue
            if (rule.targetIsUrl) {
                urlHost(text)?.let { return shortTarget(it) }
            }
            return shortTarget(text)
        }
        return ""
    }

    private fun modelText(arguments: Map<String, JsonValue>): String? {
        for (key in BotActivityPhraseData.MODEL_TEXT_KEYS) {
            val value = JsonSupport.string(arguments[key]) ?: continue
            if (value.trim().isNotEmpty()) return value
        }
        return null
    }

    private fun genericRule(): BotActivityRule = BotActivityRule(
        category = BotActivityCategory.GENERIC,
        phrase = BotActivityPhraseData.GENERIC_PHRASE,
        targetKeys = emptyList(),
        targetIsUrl = false,
        targetArray = false,
    )

    private fun capByCodePoints(text: String, max: Int, at: Int, ellipsis: String): String {
        if (text.codePointCount(0, text.length) <= max) return text
        val end = text.offsetByCodePoints(0, at)
        return text.substring(0, end) + ellipsis
    }
}

/** The rendered activity line plus its next scheduled change. */
public data class BotActivityLine(
    public val text: String,
    public val nextDeadline: Long?,
) {
    public fun toJson(): JsonObject = BotJson.objectOf(
        "text" to com.phonedsh.agentcore.JsonString(text),
        "nextDeadline" to (nextDeadline?.let(BotJson::number)
            ?: com.phonedsh.agentcore.JsonNull),
    )

    public companion object {
        public val EMPTY: BotActivityLine = BotActivityLine("", null)
    }
}

/**
 * The 800 ms / 2 400 ms / 60 000 ms activity-line timing machine
 * (`BotActivityLineState`). `now` is always an explicit event-clock input.
 */
public class BotActivityLineState {
    public var activity: BotActivity? = null
        private set
    public var text: String = ""
        private set
    public var nextDeadline: Long? = null
        private set

    private var displayedAt: Long = 0
    private var phraseStart: Int = 0
    private var pending: BotActivity? = null
    private var pendingAt: Long? = null
    private var pendingStart: Int = 0

    public fun receive(
        next: BotActivity?,
        now: Long,
        rotationStart: (Int) -> Int = { 0 },
    ) {
        if (next == null) {
            activity = null
            text = ""
            nextDeadline = null
            displayedAt = 0
            pending = null
            pendingAt = null
            return
        }
        if (activity == next) {
            pending = null
            pendingAt = null
            refresh(now)
            return
        }
        if (activity == null ||
            now - displayedAt >= BotActivityPhraseData.MINIMUM_VISIBLE_MILLIS
        ) {
            show(next, now, startIndex(next, rotationStart))
        } else {
            pending = next
            pendingAt = displayedAt + BotActivityPhraseData.MINIMUM_VISIBLE_MILLIS
            pendingStart = startIndex(next, rotationStart)
            updateDeadline(now)
        }
    }

    public fun tick(now: Long) {
        val pendingActivity = pending
        val at = pendingAt
        if (pendingActivity != null && at != null && now >= at) {
            pending = null
            pendingAt = null
            show(pendingActivity, now, pendingStart)
            return
        }
        refresh(now)
    }

    private fun show(next: BotActivity, now: Long, startIndex: Int) {
        activity = next
        displayedAt = now
        phraseStart = startIndex
        pending = null
        pendingAt = null
        refresh(now)
    }

    private fun refresh(now: Long) {
        val current = activity
        if (current == null) {
            text = ""
            nextDeadline = null
            return
        }
        val base: String = if (current.detail.isNotEmpty()) {
            current.detail
        } else {
            val phrases = BotActivityPhrases.rotationPhrases(current)
            when {
                phrases.isEmpty() -> BotActivityPhrases.primaryPhrase(current.category)
                phrases.size == 1 -> phrases[0]
                else -> {
                    val elapsed = maxOf(0L, now - displayedAt)
                    val step = (elapsed / BotActivityPhraseData.ROTATION_INTERVAL_MILLIS).toInt()
                    phrases[(phraseStart + step) % phrases.size]
                }
            }
        }
        val minutes = BotActivityPhrases.sustainedMinutes(current, now)
        text = if (minutes > 0) {
            base + BotActivityPhraseData.MINUTE_SUFFIX_TEMPLATE.replace("{minutes}", minutes.toString())
        } else {
            base
        }
        updateDeadline(now)
    }

    private fun updateDeadline(now: Long) {
        val deadlines = mutableListOf<Long>()
        val at = pendingAt
        if (at != null && pending != null) deadlines.add(maxOf(now, at))
        val current = activity
        if (current != null) {
            if (current.detail.isEmpty()) {
                val phrases = BotActivityPhrases.rotationPhrases(current)
                if (phrases.size > 1) {
                    val elapsed = maxOf(0L, now - displayedAt)
                    val step = elapsed / BotActivityPhraseData.ROTATION_INTERVAL_MILLIS
                    deadlines.add(
                        displayedAt + (step + 1) * BotActivityPhraseData.ROTATION_INTERVAL_MILLIS)
                }
            }
            if (current.startedAt > 0) {
                deadlines.add(nextMinuteBoundary(current.startedAt, now))
            }
        }
        nextDeadline = deadlines.filter { it > now }.minOrNull()
    }

    private fun startIndex(activity: BotActivity, rotationStart: (Int) -> Int): Int {
        val count = BotActivityPhrases.rotationPhrases(activity).size
        if (count <= 1) return 0
        return rotationStart(count) % count
    }

    private fun nextMinuteBoundary(startedAt: Long, now: Long): Long {
        if (now < startedAt + BotActivityPhraseData.MINUTE_MILLIS) {
            return startedAt + BotActivityPhraseData.MINUTE_MILLIS
        }
        val minutes = (now - startedAt) / BotActivityPhraseData.MINUTE_MILLIS
        return startedAt + (minutes + 1) * BotActivityPhraseData.MINUTE_MILLIS
    }
}
