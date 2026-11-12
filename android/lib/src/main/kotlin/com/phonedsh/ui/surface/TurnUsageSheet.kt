// The turn-usage sheet: one finished turn's token breakdown.
// SPDX-License-Identifier: MIT
//
// Mirror: `examples/probe-app/PhoneDSHProbe/NativeMessageActions.swift:73-92`
// (`NativeTurnUsageDetails`). The page id is the frozen `turnUsage` detent site
// in `spec/ui/v1/tokens.json#interaction.sheet.pageDetents`; `PdshSheet` resolves
// the platform medium detent and the system chrome, so this file writes neither.
//
// Copy gap: `spec/ui/v1/pages/chat.json` `sheet-913` names only the destination
// and trigger, not the sheet's rows. The labels and `tok`/`%` formats below are
// the exact Swift provenance, recorded as a contract change request in the
// handoff; no invented wording is used.
package com.phonedsh.ui.surface

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.sheet.PdshSheet
import com.phonedsh.ui.state.TurnUsage
import kotlin.math.roundToInt

/** The frozen `interaction.sheet.pageDetents` id for this sheet. */
internal const val TURN_USAGE_PAGE_ID: String = "turnUsage"

/**
 * The iOS `NativeTurnUsageDetails` list: one `LabeledContent` row per measured
 * bucket, in the baseline's order.
 *
 * A `null` cache/reasoning bucket omits its row (iOS `if let`), and a `null`
 * cache-hit percentage omits that row too. Values are the exact iOS formats:
 * an integer token count with a ` tok` suffix and `nativePercent`'s rounded
 * percentage. A partially reported primary counter also omits its row instead
 * of inventing a zero.
 */
internal fun turnUsageRows(usage: TurnUsage): List<Pair<String, String>> = buildList {
    usage.cacheHitPercent?.let { percent ->
        add(UiStrings.TURN_USAGE_CACHE_HIT to formatTurnUsagePercent(percent) + UiStrings.TURN_USAGE_PERCENT_SUFFIX)
    }
    usage.inputTokens?.let { tokens ->
        add(UiStrings.TURN_USAGE_UNCACHED_INPUT to formatTurnUsageTokens(tokens))
    }
    usage.cacheReadTokens?.let { tokens ->
        add(UiStrings.TURN_USAGE_CACHE_READ to formatTurnUsageTokens(tokens))
    }
    usage.cacheWriteTokens?.let { tokens ->
        add(UiStrings.TURN_USAGE_CACHE_WRITE to formatTurnUsageTokens(tokens))
    }
    usage.outputTokens?.let { tokens ->
        add(UiStrings.TURN_USAGE_OUTPUT to formatTurnUsageTokens(tokens))
    }
    usage.reasoningTokens?.let { tokens ->
        add(UiStrings.TURN_USAGE_REASONING to formatTurnUsageTokens(tokens))
    }
    usage.totalTokens?.let { tokens ->
        add(UiStrings.TURN_USAGE_TOTAL to formatTurnUsageTokens(tokens))
    }
}

/** iOS `NativeMessageActions`'s `"\(value) tok"` value format. */
internal fun formatTurnUsageTokens(value: Long): String = "$value${UiStrings.TURN_USAGE_TOKENS_SUFFIX}"

/**
 * iOS `nativePercent`: 100 at and above 99.95, an integer at and above 10, and
 * one decimal below that.
 */
internal fun formatTurnUsagePercent(value: Double): String = when {
    value >= 99.95 -> "100"
    value >= 10 -> value.roundToInt().toString()
    else -> ((value * 10).roundToInt() / 10.0).toString()
}

/**
 * iOS `nativeCompactTokens`: the tail action's compact total (`198K`, `1.0M`),
 * never used for the sheet's exact rows.
 */
internal fun formatTurnUsageCompactTokens(value: Long): String {
    fun scaled(number: Double): String =
        if (number >= 100) number.roundToInt().toString()
        else ((number * 10).roundToInt() / 10.0).toString()
    return when {
        value < 1_000L -> value.toString()
        value < 1_000_000L -> scaled(value / 1_000.0) + "K"
        else -> scaled(value / 1_000_000.0) + "M"
    }
}

/**
 * A system modal bottom sheet for one turn's usage.
 *
 * `pageId = "turnUsage"` is the contract's medium-only detent site
 * (`spec/ui/v1/pages/chat.json` `sheet-913`), so the platform owns the partial
 * height, the present/dismiss motion and every close path (scrim, drag, system
 * back). The caller only observes `onDismissRequest` after the hide animation.
 *
 * @param usage the turn's measured counters.
 * @param onDismissRequest clears the caller's open state after the platform hide.
 */
@Composable
public fun TurnUsageSheet(
    usage: TurnUsage,
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val rows = turnUsageRows(usage)
    PdshSheet(
        pageId = TURN_USAGE_PAGE_ID,
        onDismissRequest = onDismissRequest,
        modifier = modifier,
    ) {
        SettingsSubPageFrame(
            title = UiStrings.TURN_USAGE_TITLE,
            grouped = true,
            rootTag = UiTags.TURN_USAGE_SHEET,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(top = HomeMetrics.paragraphGap, bottom = HomeMetrics.blockGap),
            ) {
                SettingsGroupCard {
                    rows.forEachIndexed { index, row ->
                        SettingsGroupedRow(
                            title = row.first,
                            value = row.second,
                            dividerBelow = index != rows.lastIndex,
                        )
                    }
                }
            }
        }
    }
}
