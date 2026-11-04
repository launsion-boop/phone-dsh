// The Sessions family's PR22 geometry (full-screen HomeDrawer).
// SPDX-License-Identifier: MIT
//
// PR22 replaces the 320 pt drawer with the full-screen `HomeDrawer.swift`
// surface: a #F7F7F7 page, 44 pt global entries, a 40 pt folder header, 44 pt
// session rows, 12 pt row corners and a bottom settings bar. Authority is
// `HomeDrawer.swift` first; the system search field / empty-state CTA constants
// kept below are legacy measurements for the presentation HomeDrawer no longer
// renders, and their KDoc says so. The old `SessionsPage.swift` numbers are
// retained only where a still-compiling page reads the same constant.
//
// Confidence: see the vocabulary in `ChatMetrics.kt`.

package com.phonedsh.ui

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Drawer + session-list geometry.
 *
 * This is the iOS drawer, not the official web drawer: the two are different
 * surfaces (`UiMetrics` owns the official-web yardstick). A page that draws the
 * sessions drawer reads these values instead of re-typing them.
 */
public object SessionsMetrics {
    // ------------------------------------------------------------------ drawer

    /** HomeDrawer's owning SessionsDrawerPanel fixes 320pt (`NativeShell.swift:235,240`), including on a 430pt phone. */
    public const val DRAWER_WIDTH_PT: Int = 320

    /** Folder reading width inside the actual 320pt panel: 20pt content insets. */
    public const val DRAWER_CONTENT_WIDTH_PT: Int = 280

    /** NativeShell.swift:244-247 clips the modal panel's trailing corners to 22pt. */
    public const val DRAWER_PANEL_RADIUS_PT: Int = 22

    /** NativeShell.swift:131: one modal scrim at 28%, without additional platform dim. */
    public const val DRAWER_SCRIM_ALPHA: Float = 0.28f

    /** HomeDrawerRowStyle: HomeSpec.userBubble at 70% only while pressed. */
    public const val DRAWER_PRESS_ALPHA: Float = 0.7f

    /** Outer row-card inset inside the drawer. Source: `HomeDrawer.swift:140,278` (`.padding(.horizontal, 8)`). Confidence: exact. */
    public const val ROW_INSET_PT: Int = 8

    /** Global entry row (新会话 / 定时任务) height. Source: `HomeDrawer.swift:166` (`.frame(height: 44)`). Confidence: exact. */
    public const val DRAWER_ROW_HEIGHT_PT: Int = 44

    /** Entry-row icon slot. Source: `HomeDrawer.swift:150` (`.frame(width: 24, height: 24)`). Confidence: exact. */
    public const val DRAWER_ROW_ICON_SLOT_PT: Int = 24

    /** Entry-row icon/title gap. Source: `HomeDrawer.swift:148` (`HStack(spacing: 12)`). Confidence: exact. */
    public const val DRAWER_ROW_SPACING_PT: Int = 12

    /** Group-header chevron size. Source: `HomeDrawer.swift:307` (`.font(.system(size: 11, weight: .semibold))`). Confidence: exact. */
    public const val DRAWER_ROW_CHEVRON_REF_PT: Int = 11

    // ------------------------------------------------------------------- rows

    /** HomeDrawer session row height. Source: `HomeDrawer.swift:342` (`.frame(height: 44)`). Confidence: exact. */
    public const val SESSION_ROW_HEIGHT_PT: Int = 44

    /** Standalone SessionsPage row minimum height. Source: `SessionsPage.swift:589`. Confidence: exact. */
    public const val STANDALONE_SESSION_ROW_HEIGHT_PT: Int = 56

    /** Folder ("group") header height. Source: `HomeDrawer.swift:325` (`.frame(height: 40)`). Confidence: exact. */
    public const val WORKSPACE_ROW_HEIGHT_PT: Int = 40

    /** Action row height (新会话 / 定时任务 / retry). Source: `HomeDrawer.swift:166`. Confidence: exact. */
    public const val ACTION_ROW_HEIGHT_PT: Int = 44

    /** Standalone session row content inset. Source: `SessionsPage.swift:588` (`.padding(.horizontal, 8)`). Confidence: exact. */
    public const val SESSION_ROW_INNER_INSET_PT: Int = 8

    /** Standalone session glyph box. Source: `SessionsPage.swift:559` (`.frame(width: 17, height: 17)`). Confidence: exact. */
    public const val SESSION_GLYPH_BOX_PT: Int = 17

    /** Standalone session bubble glyph size. Source: `SessionsPage.swift:557`. Confidence: exact. */
    public const val SESSION_GLYPH_SIZE_PT: Int = 15

    /** Standalone session row glyph-to-title gap. Source: `SessionsPage.swift:555`. Confidence: exact. */
    public const val SESSION_GLYPH_GAP_PT: Int = 10

    /** Standalone session title-to-metadata gap. Source: `SessionsPage.swift:560`. Confidence: exact. */
    public const val SESSION_TEXT_GAP_PT: Int = 3

    /** Standalone session metadata font size. Source: `SessionsPage.swift:577`. Confidence: exact. */
    public const val SESSION_METADATA_SIZE_PT: Int = 13

    /** Gaps within the relative-time/status row. Source: `SessionsPage.swift:562`. Confidence: exact. */
    public const val SESSION_METADATA_GAP_PT: Int = 5

    /** Gap between the running dot and status label. Source: `SessionsPage.swift:568`. Confidence: exact. */
    public const val SESSION_STATUS_DOT_GAP_PT: Int = 4

    /** Current-session checkmark font size. Source: `SessionsPage.swift:584`. Confidence: exact. */
    public const val SESSION_SELECTED_CHECK_SIZE_PT: Int = 20

    /** Current-session checkmark spacer. Source: `SessionsPage.swift:581`. Confidence: exact. */
    public const val SESSION_SELECTED_CHECK_GAP_PT: Int = 4

    /** Press feedback corner radius. Source: `SessionsPage.swift:553`. Confidence: exact. */
    public const val SESSION_ROW_PRESS_RADIUS_PT: Int = 12

    /** Standalone session running dot diameter. Source: `SessionsPage.swift:571`. Confidence: exact. */
    public const val SESSION_RUNNING_DOT_PT: Int = 6

    /** Folder chevron slot. Source: `HomeDrawer.swift:308` (`.frame(width: 12)`). Confidence: exact. */
    public const val WORKSPACE_CHEVRON_SLOT_PT: Int = 12

    /** Folder title gap after the chevron. Source: `HomeDrawer.swift:305` (`HStack(spacing: 8)`). Confidence: exact. */
    public const val WORKSPACE_TITLE_GAP_PT: Int = 8

    /** Folder count gap. Source: `HomeDrawer.swift:305` (same 8 pt stack). Confidence: exact. */
    public const val WORKSPACE_COUNT_GAP_PT: Int = 8

    /** Folder "+" hit box. Source: `HomeDrawer.swift:213` (`.frame(width: 36, height: 36)`). Confidence: exact. */
    public const val WORKSPACE_MENU_WIDTH_PT: Int = 36

    // -------------------------------------------------------------- separators

    /** Hand-drawn row separator length. Source: `SessionsPage.swift:157` and `:596` (`.frame(width: 288, height: 0.5)`). Confidence: exact. */
    public const val SEPARATOR_WIDTH_PT: Int = 288

    /** Hand-drawn row separator thickness. Source: `SessionsPage.swift:157`, `:596`. Confidence: exact. */
    public const val SEPARATOR_HEIGHT_PT: Float = 0.5f

    /** Separator leading origin: the row inset, so the line runs 16 -> 304 in a 320 pt drawer. Source: `SessionsPage.swift:590,593-597`. PNG check: `darkfinal-sessions-many-light.png` row 1346 has the hairline at x=48..911 px → 16..303.7 pt. Confidence: exact (source), measured (render). */
    public const val SEPARATOR_INSET_PT: Int = 16

    // ------------------------------------------------------------------- search

    /**
     * Search field height, measured.
     *
     * Source: `darkfinal-sessions-light.png`: the white capsule spans y=350..482 px at
     * x=600 (a vertical scan; the field is white-on-white, so the shadow start
     * at y=483 and the white run are the edge evidence) → 132 px / 3 = 44.0 pt.
     * The corner is a capsule: at y=352 the white run starts at x=102 px, at
     * y=400 at x=50 px, which fits radius 66 px = 22 pt.
     *
     * Caveat: the real drawer hides the navigation bar (`NativeShell.swift:291`),
     * so this field only exists in the standalone presentation. There is no
     * search field in the shipped drawer screenshot (`darkfinal-drawer-light.png`).
     * Confidence: measured.
     */
    public const val SEARCH_HEIGHT_PT: Int = 44

    /** Search capsule radius: half the 44 pt height. Source: the same fit as [SEARCH_HEIGHT_PT] (top-corner arc). Confidence: measured. */
    public const val SEARCH_RADIUS_PT: Int = 22

    /** Search field side inset, measured: white run x=48..1157 px on the 402 pt page → 16.0..385.7 pt, so 370 pt wide. Source: `darkfinal-sessions-light.png`. Confidence: measured. */
    public const val SEARCH_INSET_PT: Int = 16

    /** Search field width at 402 pt: 402 - 2 x 16. Derived from [SEARCH_INSET_PT]. Source: arithmetic on the two measured edges. Confidence: inferred. */
    public const val SEARCH_WIDTH_PT: Int = 370

    /** Search placeholder text size, measured: ink box 46 px tall (y=551..596) in `darkpass-files-light.png`, CJK ink ≈ 0.9 x size → 17 pt. Reference only; Android uses `LocalUiType`. Source: `darkpass-files-light.png`. Confidence: measured. */
    public const val SEARCH_TEXT_REF_PT: Int = 17

    // --------------------------------------------------------------------- CTA

    /** Empty-state CTA height. Source: `SessionsPage.swift:223` (`.frame(height: 50)`). PNG check: `darkfinal-sessions-light.png` blue box y=1046..1195 px → 150 px = 50.0 pt. Confidence: exact (source), measured (render). */
    public const val CTA_HEIGHT_PT: Int = 50

    /** Empty-state CTA corner radius. Source: `SessionsPage.swift:225` (`RoundedRectangle(cornerRadius: 12)`). PNG check: corner fit r≈36 px = 12 pt. Confidence: exact (source), measured (render). */
    public const val CTA_RADIUS_PT: Int = 12

    /** Empty-state CTA width at 402 pt: the list row inset leaves 402 - 32. Source: PNG check x=48..1157 px → 370.0 pt. Confidence: measured. */
    public const val CTA_WIDTH_PT: Int = 370

    /** Empty-state top gap between the title block and the CTA. Source: `SessionsPage.swift:228` (`.padding(.top, 24)`). Confidence: exact. */
    public const val EMPTY_STATE_CTA_TOP_PT: Int = 24

    /** Empty-state bottom padding. Source: `SessionsPage.swift:232` (`.padding(.bottom, 8)`). Confidence: exact. */
    public const val EMPTY_STATE_BOTTOM_PT: Int = 8

    // -------------------------------------------------------------------- toast

    /** Archived toast height. Source: `HomeDrawer.swift:61` (`.frame(height: 30)`). Confidence: exact. */
    public const val TOAST_HEIGHT_PT: Int = 30

    /** Archived toast is a capsule. Source: `HomeDrawer.swift:62` (`Capsule()`). Confidence: exact. */
    public const val TOAST_RADIUS_PT: Int = TOAST_HEIGHT_PT / 2

    /** Archived toast top offset: safe area + navTop + 8. Source: `HomeDrawer.swift:65` (`.padding(.top, topInset + 8)`); the safe area is platform-owned. Confidence: exact. */
    public const val TOAST_TOP_OFFSET_PT: Int = 8

    // ---------------------------------------------------- PR22 home drawer extras

    /** White entry card corner radius. Source: `HomeDrawer.swift:499` (`HomeDrawerRowStyle(radius: 12)`). Confidence: exact. */
    public const val DRAWER_CARD_RADIUS_PT: Int = 12

    /** Entry/folder row icon size. Source: `HomeDrawer.swift:150,312` (18 pt system glyph in a 24/20 box). Confidence: exact. */
    public const val DRAWER_ROW_GLYPH_REF_PT: Int = 18

    /** Folder header icon slot. Source: `HomeDrawer.swift:313` (`.frame(width: 20)`). Confidence: exact. */
    public const val DRAWER_FOLDER_ICON_SLOT_PT: Int = 20

    /** Settings bar row control. Source: `HomeDrawer.swift:382-384` (`.frame(width: 36, height: 36)`). Confidence: exact. */
    public const val DRAWER_SETTINGS_CONTROL_PT: Int = 36

    /** Settings bar engine dot. Source: `HomeDrawer.swift:391` (`.frame(width: 7, height: 7)`). Confidence: exact. */
    public const val DRAWER_ENGINE_DOT_PT: Int = 7

    // ------------------------------------------------------------ dp accessors

    /** [DRAWER_WIDTH_PT] as a Compose length. */
    public val drawerWidth: Dp get() = DRAWER_WIDTH_PT.dp

    /** [DRAWER_CONTENT_WIDTH_PT] as a Compose length. */
    public val drawerContentWidth: Dp get() = DRAWER_CONTENT_WIDTH_PT.dp

    /** [ROW_INSET_PT] as a Compose length. */
    public val rowInset: Dp get() = ROW_INSET_PT.dp

    /** [DRAWER_ROW_HEIGHT_PT] as a Compose length (the 定时任务 / 设置 furniture rows). */
    public val drawerRowHeight: Dp get() = DRAWER_ROW_HEIGHT_PT.dp

    /** [DRAWER_ROW_ICON_SLOT_PT] as a Compose length. */
    public val drawerRowIconSlot: Dp get() = DRAWER_ROW_ICON_SLOT_PT.dp

    /** [DRAWER_ROW_SPACING_PT] as a Compose length. */
    public val drawerRowSpacing: Dp get() = DRAWER_ROW_SPACING_PT.dp

    /** [DRAWER_ROW_CHEVRON_REF_PT] as a Compose length. */
    public val drawerRowChevron: Dp get() = DRAWER_ROW_CHEVRON_REF_PT.dp

    /** [SESSION_ROW_HEIGHT_PT] as a Compose length. */
    public val sessionRowHeight: Dp get() = SESSION_ROW_HEIGHT_PT.dp
    public val standaloneSessionRowHeight: Dp get() = STANDALONE_SESSION_ROW_HEIGHT_PT.dp

    /** [WORKSPACE_ROW_HEIGHT_PT] as a Compose length. */
    public val workspaceRowHeight: Dp get() = WORKSPACE_ROW_HEIGHT_PT.dp

    /** [SEPARATOR_WIDTH_PT] as a Compose length. */
    public val separatorWidth: Dp get() = SEPARATOR_WIDTH_PT.dp

    /** [SEPARATOR_HEIGHT_PT] as a Compose length. */
    public val separatorHeight: Dp get() = SEPARATOR_HEIGHT_PT.dp

    /** [SEARCH_HEIGHT_PT] as a Compose length. */
    public val searchHeight: Dp get() = SEARCH_HEIGHT_PT.dp

    /** [SEARCH_RADIUS_PT] as a Compose length. */
    public val searchRadius: Dp get() = SEARCH_RADIUS_PT.dp

    /** [CTA_HEIGHT_PT] as a Compose length. */
    public val ctaHeight: Dp get() = CTA_HEIGHT_PT.dp

    /** [CTA_RADIUS_PT] as a Compose length. */
    public val ctaRadius: Dp get() = CTA_RADIUS_PT.dp
}
