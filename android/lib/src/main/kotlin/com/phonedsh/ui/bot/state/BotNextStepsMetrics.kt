// SPDX-License-Identifier: MIT
package com.phonedsh.ui.bot.state

import com.phonedsh.agentcore.JsonString
import com.phonedsh.bot.rows.BotRow
import com.phonedsh.bot.rows.BotRowBodyType
import com.phonedsh.bot.rows.BotWidgetCardType

/**
 * Local-only next-steps card usage (iOS `BotNextStepsMetrics`, `Bot/BotNextStepsMetrics.swift`).
 *
 * A finished turn counts only when its final assistant text ends with a 2-4 item
 * option list; it additionally counts as "used" when the turn carries a `steps`
 * card. The counts never leave the device. Shown on the phone-permissions page
 * under 建议卡使用（本地）.
 */
public class BotNextStepsMetrics(private val store: BotNextStepsCountStore) {

    /** Counts for the permissions page. */
    public data class Snapshot(
        public val turnsWithOptions: Int,
        public val turnsWithStepsCard: Int,
    ) {
        public val usageRate: Double
            get() = if (turnsWithOptions > 0) turnsWithStepsCard.toDouble() / turnsWithOptions else 0.0
    }

    /** Records one finished turn from the displayed rows (iOS `recordTurn(rows:)`). */
    public fun recordTurn(rows: List<BotRow>) {
        val lastUser = rows.indexOfLast { it.role == "user" }
        if (lastUser < 0) return
        val turnRows = rows.subList(lastUser + 1, rows.size)
        val finalText = turnRows.lastOrNull {
            it.role == "assistant" && it.body.type == BotRowBodyType.TEXT
        }?.let { (it.body["text"] as? JsonString)?.value } ?: return
        // "Usage rate" is measured only over eligible turns: a card on a turn
        // with no prose options is not a denominator escape hatch.
        if (!endsWithOptionList(finalText)) return
        val hasCard = turnRows.any { it.body.cardType == BotWidgetCardType.STEPS }
        val counts = store.read().toMutableMap()
        counts[TURNS_WITH_OPTIONS] = (counts[TURNS_WITH_OPTIONS] ?: 0) + 1
        if (hasCard) counts[TURNS_WITH_NEXT_STEPS] = (counts[TURNS_WITH_NEXT_STEPS] ?: 0) + 1
        store.write(counts)
    }

    public fun snapshot(): Snapshot {
        val counts = store.read()
        return Snapshot(
            turnsWithOptions = counts[TURNS_WITH_OPTIONS] ?: 0,
            turnsWithStepsCard = counts[TURNS_WITH_NEXT_STEPS] ?: 0,
        )
    }

    public fun clear() {
        store.clear()
    }

    public companion object {
        private const val TURNS_WITH_OPTIONS = "turns_with_options"
        private const val TURNS_WITH_NEXT_STEPS = "turns_with_next_steps"

        /**
         * True only for a trailing 2-4 item list. Code blocks, tables and ordinary
         * numbered instructions in the middle of a reply do not count.
         *
         * Ported verbatim from iOS `endsWithOptionList`/`isListLine`, including its
         * numbered-item rule: it takes the first two characters as the number and
         * then expects `. ` or `) `, so `1. x` does not match there and does not
         * match here either. Fix both ends together.
         */
        public fun endsWithOptionList(text: String): Boolean {
            var trailing = 0
            var sawContentBefore = false
            for (raw in text.split("\n").asReversed()) {
                val line = raw.trim(' ', '\t')
                if (line.isEmpty()) continue
                if (isListLine(line)) {
                    trailing += 1
                    if (trailing > 4) return false
                    continue
                }
                sawContentBefore = true
                break
            }
            return sawContentBefore && trailing in 2..4
        }

        private fun isListLine(line: String): Boolean {
            val body: String = if (line.startsWith("- ") || line.startsWith("* ") || line.startsWith("• ")) {
                line.substring(2)
            } else {
                val digits = line.take(2)
                if (digits.firstOrNull()?.isDigit() != true || line.length <= digits.length) return false
                val rest = line.substring(digits.length)
                if (!rest.startsWith(". ") && !rest.startsWith(") ")) return false
                rest.substring(2)
            }
            return body.trim().length >= 2
        }
    }
}

/** Where [BotNextStepsMetrics] keeps its two counters. */
public interface BotNextStepsCountStore {
    public fun read(): Map<String, Int>
    public fun write(counts: Map<String, Int>)
    public fun clear()
}

/** Process-local store for previews and tests. */
public class InMemoryBotNextStepsCountStore : BotNextStepsCountStore {
    private var counts: Map<String, Int> = emptyMap()
    override fun read(): Map<String, Int> = counts
    override fun write(counts: Map<String, Int>) { this.counts = counts.toMap() }
    override fun clear() { counts = emptyMap() }
}
