// PR22 home (任务 tab) grid, size and radius constants, declared once.
// SPDX-License-Identifier: MIT
//
// Authority: reviewed `spec/ui/v1/tokens.json`, whose values trace to PR22 iOS
// owners. The numbers are *not* typed here: `:lib:generateUiTokens` emits
// `HomeSpecData` as a compatibility facade from that JSON, and this object is the
// single Android declaration site that re-exports them under one stable name. A
// page reads `HomeMetrics.chromeInset` (Dp) or `HomeMetrics.CHROME_INSET_PT` (the
// raw point value) and never re-types 16.
//
// `HomeMetricsTest` compares this facade and the generated data to the JSON
// source; the Swift source is never a second Kotlin table.
package com.phonedsh.ui

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.theme.generated.HomeSpecData

/** HomeSpec's grid, size and radius table (430x932pt). */
public object HomeMetrics {
    // ------------------------------------------------------------------ grid

    /** Floating chrome (nav buttons, composer) is 16pt from the screen edge. */
    public const val CHROME_INSET_PT: Float = HomeSpecData.CHROME_INSET

    /** Reading content (messages, cards, tables) is 20pt from the edge. */
    public const val CONTENT_INSET_PT: Float = HomeSpecData.CONTENT_INSET

    /** The nav row starts 8pt below the top safe area. */
    public const val NAV_TOP_PT: Float = HomeSpecData.NAV_TOP

    /** Tab-bar content height above the bottom safe area. */
    public const val TAB_BAR_HEIGHT_PT: Float = HomeSpecData.TAB_BAR_HEIGHT

    // ------------------------------------------------------------------ type

    /** Nav title size (`17.5 / 600 / 22`; weight and line come from the HTML spec). */
    public const val NAV_TITLE_SIZE_PT: Float = HomeSpecData.NAV_TITLE_SIZE

    /** Nav title line box. */
    public const val NAV_TITLE_LINE_PT: Float = HomeSpecData.NAV_TITLE_LINE

    /** Nav subtitle (folder name) size. */
    public const val NAV_SUBTITLE_SIZE_PT: Float = HomeSpecData.NAV_SUBTITLE_SIZE

    /** Nav subtitle line box. */
    public const val NAV_SUBTITLE_LINE_PT: Float = HomeSpecData.NAV_SUBTITLE_LINE

    /** Body size (`16 / 24`). */
    public const val BODY_SIZE_PT: Float = HomeSpecData.BODY_SIZE

    /** Body line box. */
    public const val BODY_LINE_PT: Float = HomeSpecData.BODY_LINE

    /** Process-row size (`15`). */
    public const val PROCESS_SIZE_PT: Float = HomeSpecData.PROCESS_SIZE

    /** Step-list item size (`14 / 22`). */
    public const val LIST_ITEM_SIZE_PT: Float = HomeSpecData.LIST_ITEM_SIZE

    /** Step-list item line box. */
    public const val LIST_ITEM_LINE_PT: Float = HomeSpecData.LIST_ITEM_LINE

    /** Tag label size (`12`, `HomeTag`). */
    public const val TAG_LABEL_SIZE_PT: Float = HomeSpecData.TAG_LABEL_SIZE

    /** Tab label size (`10.5`). */
    public const val TAB_LABEL_SIZE_PT: Float = HomeSpecData.TAB_LABEL_SIZE

    // --------------------------------------------------------------- spacing

    /** Between transcript blocks (process rows, paragraphs, cards). */
    public const val BLOCK_GAP_PT: Float = HomeSpecData.BLOCK_GAP

    /** After a user bubble, and between paragraphs. */
    public const val PARAGRAPH_GAP_PT: Float = HomeSpecData.PARAGRAPH_GAP

    /** From a process row to the card it opens. */
    public const val DISCLOSURE_GAP_PT: Float = HomeSpecData.DISCLOSURE_GAP

    // ----------------------------------------------------------------- sizes

    /** Square floating nav button (`44 x 44`, r22). */
    public const val NAV_BUTTON_PT: Float = HomeSpecData.NAV_BUTTON

    /** Device + more pill width (`92 x 44`). */
    public const val NAV_PILL_WIDTH_PT: Float = HomeSpecData.NAV_PILL_WIDTH

    /** Nav button glyph box. */
    public const val NAV_ICON_PT: Float = HomeSpecData.NAV_ICON

    /** Process row height. */
    public const val PROCESS_ROW_HEIGHT_PT: Float = HomeSpecData.PROCESS_ROW_HEIGHT

    /** Process row glyph box. */
    public const val PROCESS_ICON_PT: Float = HomeSpecData.PROCESS_ICON

    /** Step-list row height. */
    public const val LIST_ROW_HEIGHT_PT: Float = HomeSpecData.LIST_ROW_HEIGHT

    /** Grouped list/Form default minimum row height (HomeSpec 48, separate from compact 22pt rows). */
    public const val DEFAULT_MIN_LIST_ROW_HEIGHT_PT: Float = HomeSpecData.DEFAULT_MIN_LIST_ROW_HEIGHT

    /** HomeSpec primary action capsule height (50). */
    public const val HOME_PRIMARY_BUTTON_HEIGHT_PT: Float = HomeSpecData.HOME_PRIMARY_BUTTON_HEIGHT

    /** `HomePrimaryButtonStyle` disabled fill opacity. */
    public const val HOME_PRIMARY_BUTTON_DISABLED_OPACITY: Float = HomeSpecData.HOME_PRIMARY_BUTTON_DISABLED_OPACITY

    /** `HomePrimaryButtonStyle` pressed content opacity. */
    public const val HOME_PRIMARY_BUTTON_PRESSED_OPACITY: Float = HomeSpecData.HOME_PRIMARY_BUTTON_PRESSED_OPACITY

    /** Open composer minimum height. */
    public const val COMPOSER_OPEN_MIN_HEIGHT_PT: Float = HomeSpecData.COMPOSER_OPEN_MIN_HEIGHT

    /** Send / stop circle diameter. */
    public const val SEND_BUTTON_PT: Float = HomeSpecData.SEND_BUTTON

    /** Composer glyph box. */
    public const val COMPOSER_ICON_PT: Float = HomeSpecData.COMPOSER_ICON

    /** Tab bar glyph box. */
    public const val TAB_ICON_PT: Float = HomeSpecData.TAB_ICON

    // ----------------------------------------------------------------- radii

    /** User bubble radius; the top-trailing corner is square (see below). */
    public const val BUBBLE_RADIUS_PT: Float = HomeSpecData.BUBBLE_RADIUS

    /** Top-trailing corner of `HomeSpec.bubbleShape`: `UnevenRoundedRectangle` sets it to 0. */
    public const val BUBBLE_TOP_TRAILING_RADIUS_PT: Float = HomeSpecData.BUBBLE_TOP_TRAILING_RADIUS

    /** Runtime bubble cap rule: `(containerWidth - 2 * contentInset) * ratio`; never a fixed width. */
    public const val BUBBLE_MAX_WIDTH_RATIO: Float = HomeSpecData.BUBBLE_MAX_WIDTH_RATIO

    /** White step-list card radius. */
    public const val LIST_CARD_RADIUS_PT: Float = HomeSpecData.LIST_CARD_RADIUS

    /** Open composer radius. */
    public const val COMPOSER_OPEN_RADIUS_PT: Float = HomeSpecData.COMPOSER_OPEN_RADIUS

    // ------------------------------------------------------------ dp accessors

    public val chromeInset: Dp get() = CHROME_INSET_PT.dp
    public val contentInset: Dp get() = CONTENT_INSET_PT.dp
    public val navTop: Dp get() = NAV_TOP_PT.dp
    public val tabBarHeight: Dp get() = TAB_BAR_HEIGHT_PT.dp
    public val blockGap: Dp get() = BLOCK_GAP_PT.dp
    public val paragraphGap: Dp get() = PARAGRAPH_GAP_PT.dp
    public val disclosureGap: Dp get() = DISCLOSURE_GAP_PT.dp
    public val navButton: Dp get() = NAV_BUTTON_PT.dp
    public val navPillWidth: Dp get() = NAV_PILL_WIDTH_PT.dp
    public val navIcon: Dp get() = NAV_ICON_PT.dp
    public val processRowHeight: Dp get() = PROCESS_ROW_HEIGHT_PT.dp
    public val processIcon: Dp get() = PROCESS_ICON_PT.dp
    public val listRowHeight: Dp get() = LIST_ROW_HEIGHT_PT.dp
    public val defaultMinListRowHeight: Dp get() = DEFAULT_MIN_LIST_ROW_HEIGHT_PT.dp
    public val homePrimaryButtonHeight: Dp get() = HOME_PRIMARY_BUTTON_HEIGHT_PT.dp
    public val composerOpenMinHeight: Dp get() = COMPOSER_OPEN_MIN_HEIGHT_PT.dp
    public val sendButton: Dp get() = SEND_BUTTON_PT.dp
    public val composerIcon: Dp get() = COMPOSER_ICON_PT.dp
    public val tabIcon: Dp get() = TAB_ICON_PT.dp
    public val bubbleRadius: Dp get() = BUBBLE_RADIUS_PT.dp
    public val listCardRadius: Dp get() = LIST_CARD_RADIUS_PT.dp
    public val composerOpenRadius: Dp get() = COMPOSER_OPEN_RADIUS_PT.dp

    // ------------------------------------------------------------ type sizes

    public val navTitleSize: Dp get() = NAV_TITLE_SIZE_PT.dp
    public val navTitleLine: Dp get() = NAV_TITLE_LINE_PT.dp
    public val navSubtitleSize: Dp get() = NAV_SUBTITLE_SIZE_PT.dp
    public val navSubtitleLine: Dp get() = NAV_SUBTITLE_LINE_PT.dp
    public val bodySize: Dp get() = BODY_SIZE_PT.dp
    public val bodyLine: Dp get() = BODY_LINE_PT.dp
    public val processSize: Dp get() = PROCESS_SIZE_PT.dp
    public val listItemSize: Dp get() = LIST_ITEM_SIZE_PT.dp
    public val listItemLine: Dp get() = LIST_ITEM_LINE_PT.dp
    public val tagLabelSize: Dp get() = TAG_LABEL_SIZE_PT.dp
    public val tabLabelSize: Dp get() = TAB_LABEL_SIZE_PT.dp
}
