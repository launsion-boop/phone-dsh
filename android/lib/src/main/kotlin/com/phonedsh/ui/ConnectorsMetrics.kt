// The 发现 tab's iOS-written geometry (`ConnectorsPage.swift`).
// SPDX-License-Identifier: MIT
//
// Every value is a literal the baseline source writes; the line is cited on each.
// The page is a `.homeGroupedList()` (`:91`), so its card margins, radius and row
// pitch are the settings family's (`SettingsMetrics`), not repeated here.
//
// Confidence: see the vocabulary in `ChatMetrics.kt`. "exact" = the literal in the
// Swift source; nothing here was measured from a screenshot.

package com.phonedsh.ui

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** 发现 page and connector sheet geometry. */
public object ConnectorsMetrics {
    /** Row tile side. Source: `ConnectorsPage.swift:134` (`ConnectorTile(…, size: 44)`). Confidence: exact. */
    public val rowTile: Dp get() = 44.dp

    /** Sheet tile side. Source: `:198` (`size: 96`). Confidence: exact. */
    public val sheetTile: Dp get() = 96.dp

    /** Tile corner radius as a share of its side. Source: `:167` (`cornerRadius: size * 0.27`). Confidence: exact. */
    public const val TILE_RADIUS_RATIO: Float = 0.27f

    /** Tile glyph as a share of its side. Source: `:163` (`size * 0.46`). Confidence: exact. */
    public const val TILE_GLYPH_RATIO: Float = 0.46f

    /** Row spacing between tile, text and pill. Source: `:133` (`HStack(spacing: 14)`). Confidence: exact. */
    public val rowSpacing: Dp get() = 14.dp

    /** Row vertical padding. Source: `:147` (`.padding(.vertical, 4)`) over the list row's own inset. Confidence: approximate. */
    public val rowPaddingV: Dp get() = 10.dp

    /** Row separator leading inset. Source: `:151` (`listRowSeparatorLeading … 58`) plus the 16 pt card inset. Confidence: approximate. */
    public val rowSeparatorInset: Dp get() = 74.dp

    /** Subtitle under the connector name. Source: `:140` (`.font(.system(size: 13))`). Confidence: exact. */
    public val subtitleSize: TextUnit get() = 13.sp

    /** Pill label. Source: `:178` (`.font(.system(size: 15, weight: .semibold))`). Confidence: exact. */
    public val pillTextSize: TextUnit get() = 15.sp

    /** Pill horizontal padding. Source: `:180` (`.padding(.horizontal, 16)`). Confidence: exact. */
    public val pillPaddingH: Dp get() = 16.dp

    /** Pill height. Source: `:181` (`.frame(height: 32)`). Confidence: exact. */
    public val pillHeight: Dp get() = 32.dp

    /** Section header size. Source: `:126` (`.font(.system(size: 15, weight: .medium))`). Confidence: exact. */
    public val sectionHeaderSize: TextUnit get() = 15.sp

    /** Sheet tile top. Source: `:200` (`.padding(.top, 28)`). Confidence: exact. */
    public val sheetTileTop: Dp get() = 28.dp

    /** Sheet title size. Source: `:202` (`.font(.system(size: 24, weight: .bold))`). Confidence: exact. */
    public val sheetTitleSize: TextUnit get() = 24.sp

    /** Sheet title top. Source: `:204` (`.padding(.top, 16)`). Confidence: exact. */
    public val sheetTitleTop: Dp get() = 16.dp

    /** Sheet action top. Source: `:208` (`.padding(.top, 20)`). Confidence: exact. */
    public val sheetActionTop: Dp get() = 20.dp

    /** Sheet action max width. Source: `:207` (`.frame(maxWidth: 260)`). Confidence: exact. */
    public val sheetActionMaxWidth: Dp get() = 260.dp

    /** Sheet body top. Source: `:222` (`.padding(.top, 28)`). Confidence: exact. */
    public val sheetBodyTop: Dp get() = 28.dp

    /** Sheet body bottom. Source: `:223` (`.padding(.bottom, 32)`). Confidence: exact. */
    public val sheetBodyBottom: Dp get() = 32.dp

    /** Sheet body spacing. Source: `:210` (`VStack(alignment: .leading, spacing: 14)`). Confidence: exact. */
    public val sheetBodySpacing: Dp get() = 14.dp

    /** Sheet summary and 关于此连接器 header size. Source: `:212`, `:216` (`size: 15`). Confidence: exact. */
    public val sheetBodyTextSize: TextUnit get() = 15.sp

    /** 关于此连接器 header top. Source: `:218` (`.padding(.top, 10)`). Confidence: exact. */
    public val aboutHeaderTop: Dp get() = 10.dp

    /** About card radius. Source: `:317` (`RoundedRectangle(cornerRadius: 20)`). Confidence: exact. */
    public val aboutCardRadius: Dp get() = 20.dp

    /** About row padding. Source: `:338` (`.padding(16)`). Confidence: exact. */
    public val aboutRowPadding: Dp get() = 16.dp

    /** About detail line under the row title. Source: `:327` (`VStack(… spacing: 4)`). Confidence: exact. */
    public val aboutRowSpacing: Dp get() = 4.dp

    /** List bottom clearance above the bottom menu. Approximate: the grouped list's own bottom inset. */
    public val listBottom: Dp get() = 24.dp
}
