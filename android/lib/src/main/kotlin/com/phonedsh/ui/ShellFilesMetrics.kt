// The Shell + Files family's iOS-measured geometry.
// SPDX-License-Identifier: MIT
//
// Shell: `NativeShell.swift:42-45` (`NativeHeaderStyle`) and the drawer
// furniture row. Files: `FilesPage.swift` first, then the system-drawn
// navigation bar and search field, which the page never writes as literals.
//
// PR22 Files is a `.homeGroupedList()` page (`FilesPage.swift:134`) with an
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
import com.phonedsh.ui.theme.generated.UiTokenData

/** Shell page header and Files page geometry. */
public object ShellFilesMetrics {
    // ------------------------------------------------------------------- shell

    /**
     * Plain page header height used by shell-level pages.
     *
     * Resolves `geometry.navButton` (the `geometry.pageHeaderMinHeight` alias),
     * 44. Source: `NativeShell.swift:42` (`NativeHeaderStyle.barHeight = 44`).
     * Not the chat header (`ChatMetrics.HEADER_HEIGHT_PT`, also 44) and not the
     * legacy `NativeParityTokens.headerHeight` (50).
     */
    public val HEADER_HEIGHT_PT: Int get() = UiTokenData.geometryNavButton.value.toInt()

    /** Header horizontal inset; resolves `geometry.chromeInset` (16). Source: `NativeShell.swift:43` (`horizontalInset = 16`), applied at `:563`. */
    public val HEADER_INSET_H_PT: Int get() = UiTokenData.geometryChromeInset.value.toInt()

    /** Shell drawer furniture row height (定时任务 / 设置). Source: `NativeShell.swift:579` (`.frame(height: 48)`). Confidence: exact. */
    public const val SHELL_DRAWER_ROW_HEIGHT_PT: Int = 48

    /** Shell drawer furniture icon slot. Source: `NativeShell.swift:568` (`.frame(width: 22)`). Confidence: exact. */
    public const val SHELL_DRAWER_ROW_ICON_SLOT_PT: Int = 22

    // ------------------------------------------------------------------- files

    /** Legacy large-title measurement; resolves `typography.largeTitle` (34). PR22 Files uses an inline title. Source: old `.large` capture. */
    public val LARGE_TITLE_REF_PT: Int get() = UiTokenData.typeLargeTitle.baseSize.toInt()

    /** PR22 inline navigation title; resolves `typography.pageTitle` (17). Source: `FilesPage.swift:52` (`.navigationBarTitleDisplayMode(.inline)`) + `HomeAppearance` 17 pt semibold. */
    public val INLINE_TITLE_REF_PT: Int get() = UiTokenData.typePageTitle.baseSize.toInt()

    /** PR22 grouped-list minimum row height; resolves `geometry.defaultMinListRowHeight` (48). Source: `HomeSpec.swift:207` (`.environment(\.defaultMinListRowHeight, 48)`). */
    public val GROUPED_LIST_MIN_ROW_HEIGHT_PT: Int get() = UiTokenData.geometryDefaultMinListRowHeight.value.toInt()

    /** Search field height: same system control as Sessions. Source: [SessionsMetrics.SEARCH_HEIGHT_PT] (measured 44.0 pt). Page-local, measured. Confidence: measured. */
    public const val SEARCH_HEIGHT_PT: Int = SessionsMetrics.SEARCH_HEIGHT_PT

    /** Search field radius: capsule. Source: [SessionsMetrics.SEARCH_RADIUS_PT]. Page-local, measured. Confidence: measured. */
    public const val SEARCH_RADIUS_PT: Int = SessionsMetrics.SEARCH_RADIUS_PT

    /** Search field side inset: same system control as Sessions. Source: [SessionsMetrics.SEARCH_INSET_PT] (measured 16 pt). Page-local, measured. Confidence: measured. */
    public const val SEARCH_INSET_PT: Int = SessionsMetrics.SEARCH_INSET_PT

    /** Folder row minimum height; resolves `geometry.pageRowMinHeight` (44). Source: `FilesPage.swift:116` (`.frame(minHeight: 44)`). */
    public val FOLDER_ROW_MIN_HEIGHT_PT: Int get() = UiTokenData.geometryPageRowMinHeight.value.toInt()

    /** File row glyph slot (icon centred inside). Source: `FilesPage.swift:183` (`.frame(width: 34, height: 38)`). Confidence: exact. */
    public const val FILE_ROW_GLYPH_SLOT_WIDTH_PT: Int = 34

    /** File row glyph slot height. Source: `FilesPage.swift:183` (`.frame(width: 34, height: 38)`). Confidence: exact. */
    public const val FILE_ROW_GLYPH_SLOT_HEIGHT_PT: Int = 38

    /** Files empty-state title/body gap. Source: `FilesPage.swift:98` (`VStack(spacing: 8)`). Confidence: exact. */
    public const val EMPTY_STATE_GAP_PT: Int = 8

    /** Files empty-state vertical padding. Source: `FilesPage.swift:107` (`.padding(.vertical, 24)`). Confidence: exact. */
    public const val EMPTY_STATE_PADDING_V_PT: Int = 24

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
