// The Shell + Files family's iOS-measured geometry.
// SPDX-License-Identifier: MIT
//
// Shell: `NativeShell.swift:39-43` (`NativeHeaderStyle`) and the drawer
// furniture row. Files: `FilesPage.swift` first, then the system-drawn
// navigation bar and search field, which the page never writes as literals.
//
// PR22 Files is a `.homeGroupedList()` page (`FilesPage.swift:124`) with an
// **inline** navigation title, not the old large title: the page no longer
// draws a 34 pt large-title header. The grouped card margins/radius/row height
// measured for Settings therefore apply here too
// ([SettingsMetrics.CARD_MARGIN_H_PT], [SettingsMetrics.CARD_RADIUS_PT],
// [SettingsMetrics.ROW_HEIGHT_PT]); the empty state is still the only
// Files-specific capture, so [LARGE_TITLE_REF_PT] is kept as a legacy
// measurement and [INLINE_TITLE_REF_PT] is the PR22 value.
//
// Confidence: see the vocabulary in `ChatMetrics.kt`.

package com.phonedsh.ui

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Shell page header and Files page geometry. */
public object ShellFilesMetrics {
    // ------------------------------------------------------------------- shell

    /** Plain page header height used by shell-level pages. Source: `NativeShell.swift:39` (`NativeHeaderStyle.barHeight = 44`), also `tokens.json` `geometry.pageHeaderMinHeight`. Not the chat header (that is 50, `ChatMetrics.HEADER_HEIGHT_PT`). Confidence: exact. */
    public const val HEADER_HEIGHT_PT: Int = 44

    /** Header horizontal inset. Source: `NativeShell.swift:40` (`horizontalInset = 16`), applied at `:432`. Confidence: exact. */
    public const val HEADER_INSET_H_PT: Int = 16

    /** Header title size. Reference only: Source: `NativeShell.swift:41` (`titleSize = 17`). Confidence: exact. */
    public const val HEADER_TITLE_REF_PT: Int = 17

    /** Run-status dot diameter. Source: `NativeShell.swift:42` (`statusDot = 8`). Confidence: exact. */
    public const val STATUS_DOT_PT: Int = 8

    /** Drawer furniture row height (定时任务 / 设置). Source: `NativeShell.swift:433`. Confidence: exact. */
    public const val DRAWER_ROW_HEIGHT_PT: Int = 48

    /** Drawer furniture icon slot. Source: `NativeShell.swift:422`. Confidence: exact. */
    public const val DRAWER_ROW_ICON_SLOT_PT: Int = 22

    // ------------------------------------------------------------------- files

    /** Legacy large-title measurement; PR22 Files uses an inline title. Source: old `.large` capture. Confidence: measured (legacy). */
    public const val LARGE_TITLE_REF_PT: Int = 34

    /** PR22 inline navigation title. Source: `FilesPage.swift` `.navigationBarTitleDisplayMode(.inline)` + `HomeAppearance` 17 pt semibold. Confidence: exact. */
    public const val INLINE_TITLE_REF_PT: Int = 17

    /** PR22 grouped-list body text. Source: `HomeSpec.homeGroupedList()` (`HomeSpec.bodySize = 16`). Confidence: exact. */
    public const val GROUPED_LIST_BODY_REF_PT: Int = 16

    /** PR22 grouped-list minimum row height. Source: `HomeSpec.homeGroupedList()` (`48`). Confidence: exact. */
    public const val GROUPED_LIST_MIN_ROW_HEIGHT_PT: Int = 48

    /** Large title leading inset, measured: glyph starts x=53 px = 17.7 pt (16 pt page margin plus ~1.7 pt glyph bearing). Source: `darkpass-files-light.png` title ink box. Confidence: measured (glyph), inferred (the 16 pt margin). */
    public const val LARGE_TITLE_INSET_PT: Int = 16

    /** Search field height: same system control as Sessions. Source: [SessionsMetrics.SEARCH_HEIGHT_PT] (measured 44.0 pt). Confidence: measured. */
    public const val SEARCH_HEIGHT_PT: Int = SessionsMetrics.SEARCH_HEIGHT_PT

    /** Search field radius: capsule. Source: [SessionsMetrics.SEARCH_RADIUS_PT]. Confidence: measured. */
    public const val SEARCH_RADIUS_PT: Int = SessionsMetrics.SEARCH_RADIUS_PT

    /** Search field side inset. Source: PNG check grey field x=49..1155 px → 16.3..385.0 pt. Confidence: measured. */
    public const val SEARCH_INSET_PT: Int = 16

    /** Search placeholder size. Source: PNG check ink box 46 px = 15.3 pt → 17 pt font. Reference only. Confidence: measured. */
    public const val SEARCH_TEXT_REF_PT: Int = 17

    /** Folder row minimum height. Source: `FilesPage.swift:120` (`.frame(minHeight: 44)`). Confidence: exact. */
    public const val FOLDER_ROW_MIN_HEIGHT_PT: Int = 44

    /** File row glyph slot (icon centred inside). Source: `FilesPage.swift:189` (`.frame(width: 34, height: 38)`). Confidence: exact. */
    public const val FILE_ROW_GLYPH_SLOT_WIDTH_PT: Int = 34

    /** File row glyph slot height. Source: `FilesPage.swift:189`. Confidence: exact. */
    public const val FILE_ROW_GLYPH_SLOT_HEIGHT_PT: Int = 38

    /** File row icon size passed to `FileTypeGlyph`. Source: `FilesPage.swift:188` (`size: 24`). Confidence: exact. */
    public const val FILE_ROW_GLYPH_PT: Int = 24

    /** File row glyph-to-text gap. Source: `FilesPage.swift:187` (`HStack(spacing: 12)`). Confidence: exact. */
    public const val FILE_ROW_GAP_PT: Int = 12

    /** File row title-to-metadata gap. Source: `FilesPage.swift:191` (`VStack(spacing: 3)`). Confidence: exact. */
    public const val FILE_ROW_TEXT_GAP_PT: Int = 3

    /** File row extra vertical padding. Source: `FilesPage.swift:212` (`.padding(.vertical, 3)`). Confidence: exact. */
    public const val FILE_ROW_PADDING_V_PT: Int = 3

    /** Files empty-state title/body gap. Source: `FilesPage.swift:101` (`VStack(spacing: 8)`). Confidence: exact. */
    public const val EMPTY_STATE_GAP_PT: Int = 8

    /** Files empty-state vertical padding. Source: `FilesPage.swift:112` (`.padding(.vertical, 24)`). Confidence: exact. */
    public const val EMPTY_STATE_PADDING_V_PT: Int = 24

    /** Files empty-state title size. Source: `FilesPage.swift:103` (`.font(.system(size: 17, weight: .semibold))`). Reference only. Confidence: exact. */
    public const val EMPTY_STATE_TITLE_REF_PT: Int = 17

    /** Files empty-state body size. Source: `FilesPage.swift:106` (`.font(.system(size: 13))`). Reference only. Confidence: exact. */
    public const val EMPTY_STATE_BODY_REF_PT: Int = 13

    // ------------------------------------------------------------ dp accessors

    /** [HEADER_HEIGHT_PT] as a Compose length. */
    public val headerHeight: Dp get() = HEADER_HEIGHT_PT.dp

    /** [HEADER_INSET_H_PT] as a Compose length. */
    public val headerInset: Dp get() = HEADER_INSET_H_PT.dp

    /** [SEARCH_HEIGHT_PT] as a Compose length. */
    public val searchHeight: Dp get() = SEARCH_HEIGHT_PT.dp

    /** [SEARCH_RADIUS_PT] as a Compose length. */
    public val searchRadius: Dp get() = SEARCH_RADIUS_PT.dp

    /** [FOLDER_ROW_MIN_HEIGHT_PT] as a Compose length. */
    public val folderRowMinHeight: Dp get() = FOLDER_ROW_MIN_HEIGHT_PT.dp

    /** [FILE_ROW_GLYPH_SLOT_WIDTH_PT] as a Compose length. */
    public val fileRowGlyphSlotWidth: Dp get() = FILE_ROW_GLYPH_SLOT_WIDTH_PT.dp

    /** [FILE_ROW_GLYPH_SLOT_HEIGHT_PT] as a Compose length. */
    public val fileRowGlyphSlotHeight: Dp get() = FILE_ROW_GLYPH_SLOT_HEIGHT_PT.dp
}
