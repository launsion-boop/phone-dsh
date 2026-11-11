// The Sessions family's PR22 geometry (HomeDrawer inside the 320 pt panel).
// SPDX-License-Identifier: MIT
//
// PR22 renders the session list with `HomeDrawer.swift` inside the 320 pt
// `SessionsDrawerPanel` (`NativeShell.swift:112` still defines `drawerWidth`):
// a #F7F7F7 page, a 52 pt full-width 新会话 capsule, a 40 pt folder header,
// 44 pt session rows, 12 pt row corners and the grouped folder/session list.
// Authority is `HomeDrawer.swift` first; the system search field / empty-state
// CTA constants kept below are legacy measurements for the standalone
// presentation HomeDrawer no longer renders, and their KDoc says so. The old
// `SessionsPage.swift` numbers are retained only where a still-compiling page
// reads the same constant.
//
// Confidence: see the vocabulary in `ChatMetrics.kt`.

package com.phonedsh.ui

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.theme.generated.UiTokenData

/**
 * Drawer + session-list geometry.
 *
 * This is the iOS drawer, not the official web drawer: the two are different
 * surfaces (`UiMetrics` owns the official-web yardstick). A page that draws the
 * sessions drawer reads these values instead of re-typing them.
 */
public object SessionsMetrics {
    // ------------------------------------------------------------------ drawer

    /** HomeDrawer panel width; resolves `geometry.drawerWidth` (no local copy). */
    public val DRAWER_WIDTH_PT: Int get() = UiTokenData.drawer.width.value.toInt()

    /** Folder reading width inside the actual 320pt panel: 20pt content insets. Page-local: derived from the panel width, not a token. */
    public const val DRAWER_CONTENT_WIDTH_PT: Int = 280

    /** Panel trailing radius; resolves `radius.drawerTrailing`. */
    public val DRAWER_PANEL_RADIUS_PT: Int get() = UiTokenData.drawer.panelTrailingRadius.value.toInt()

    /** Scrim opacity; resolves `interaction.drawer.scrimMaxOpacity`. */
    public val DRAWER_SCRIM_ALPHA: Float get() = UiTokenData.drawer.scrimMaxOpacity

    /** Outer row-card inset inside the drawer. Source: `HomeDrawer.swift:461` (`.padding(.horizontal, 8)`). Confidence: exact. */
    public const val ROW_INSET_PT: Int = 8

    /** Legacy pre-PR22 entry-row icon/title gap; the PR22 新会话 pill uses 10 (`HomeDrawer.swift:199`) and the folder header 8 (`HomeDrawer.swift:499`). Kept as a legacy measurement for the old standalone drawer. Confidence: legacy. */
    public const val DRAWER_ROW_SPACING_PT: Int = 12

    /** Group-header chevron size. Source: `HomeDrawer.swift:501` (`.font(.system(size: 11, weight: .semibold))`). Confidence: exact. */
    public const val DRAWER_ROW_CHEVRON_REF_PT: Int = 11

    // ------------------------------------------------------------------- rows

    /** HomeDrawer session row height. Source: `HomeDrawer.swift:559` (`.frame(height: 44)`). Confidence: exact. */
    public const val SESSION_ROW_HEIGHT_PT: Int = 44

    /** Standalone SessionsPage row minimum height. Source: `SessionsPage.swift:607` (`.frame(minHeight: 56)`). Confidence: exact. */
    public const val STANDALONE_SESSION_ROW_HEIGHT_PT: Int = 56

    /** Folder ("group") header height. Source: `HomeDrawer.swift:521` (`.frame(height: 40)`). Confidence: exact. */
    public const val WORKSPACE_ROW_HEIGHT_PT: Int = 40

    /** Standalone session row content inset. Source: `SessionsPage.swift:606` (`.padding(.horizontal, 8)`). Confidence: exact. */
    public const val SESSION_ROW_INNER_INSET_PT: Int = 8

    /** Standalone session glyph box. Source: `SessionsPage.swift:577` (`.frame(width: 17, height: 17)`). Confidence: exact. */
    public const val SESSION_GLYPH_BOX_PT: Int = 17

    /** Standalone session bubble glyph size. Source: `SessionsPage.swift:575` (`.font(.system(size: 15))`). Confidence: exact. */
    public const val SESSION_GLYPH_SIZE_PT: Int = 15

    /** Standalone session row glyph-to-title gap. Source: `SessionsPage.swift:573` (`HStack(spacing: 10)`). Confidence: exact. */
    public const val SESSION_GLYPH_GAP_PT: Int = 10

    /** Standalone session title-to-metadata gap. Source: `SessionsPage.swift:578` (`VStack(alignment: .leading, spacing: 3)`). Confidence: exact. */
    public const val SESSION_TEXT_GAP_PT: Int = 3

    /** Standalone session metadata font size; resolves `typography.secondary` (13). Source: `SessionsPage.swift:595` (`.font(.system(size: 13))`). */
    public val SESSION_METADATA_SIZE_PT: Int get() = UiTokenData.typeSecondary.baseSize.toInt()

    /** Gaps within the relative-time/status row. Source: `SessionsPage.swift:580` (`HStack(spacing: 5)`). Confidence: exact. */
    public const val SESSION_METADATA_GAP_PT: Int = 5

    /** Gap between the running dot and status label. Source: `SessionsPage.swift:586` (`HStack(spacing: 4)`). Confidence: exact. */
    public const val SESSION_STATUS_DOT_GAP_PT: Int = 4

    /** Current-session checkmark font size. Source: `SessionsPage.swift:602` (`.font(.system(size: 20, weight: .regular))`). Confidence: exact. */
    public const val SESSION_SELECTED_CHECK_SIZE_PT: Int = 20

    /** Current-session checkmark spacer. Source: `SessionsPage.swift:599` (`Spacer(minLength: 4)`). Confidence: exact. */
    public const val SESSION_SELECTED_CHECK_GAP_PT: Int = 4

    /** Press feedback corner radius. Source: `SessionsPage.swift:675` (`RoundedRectangle(cornerRadius: 12)`). Confidence: exact. */
    public const val SESSION_ROW_PRESS_RADIUS_PT: Int = 12

    /** Standalone session running dot diameter. Source: `SessionsPage.swift:589` (`.frame(width: 6, height: 6)`). Confidence: exact. */
    public const val SESSION_RUNNING_DOT_PT: Int = 6

    /** Folder chevron slot. Source: `HomeDrawer.swift:504` (`.frame(width: 12)`). Confidence: exact. */
    public const val WORKSPACE_CHEVRON_SLOT_PT: Int = 12

    /** Folder title gap after the chevron. Source: `HomeDrawer.swift:499` (`HStack(spacing: 8)`). Confidence: exact. */
    public const val WORKSPACE_TITLE_GAP_PT: Int = 8

    /** Folder count gap. Source: `HomeDrawer.swift:499` (same 8 pt stack). Confidence: exact. */
    public const val WORKSPACE_COUNT_GAP_PT: Int = 8

    /** Folder "+" hit box. Source: `HomeDrawer.swift:325` (`.frame(width: 36, height: 36)`). Confidence: exact. */
    public const val WORKSPACE_MENU_WIDTH_PT: Int = 36

    // -------------------------------------------------------------- separators

    /** Hand-drawn row separator length. Source: `SessionsPage.swift:183` and `:623` (`.frame(width: 288, height: 0.5)`). Confidence: exact. */
    public const val SEPARATOR_WIDTH_PT: Int = 288

    /** Hand-drawn row separator thickness; resolves `stroke.hairline` (0.5). Source: `SessionsPage.swift:183`, `:623`. */
    public val SEPARATOR_HEIGHT_PT: Float get() = UiTokenData.strokeHairline.value

    /** Separator leading origin: the row inset, so the line runs 16 -> 304 in a 320 pt drawer. Source: `SessionsPage.swift:188,617` (`leading: 16`). PNG check: `darkfinal-sessions-many-light.png` row 1346 has the hairline at x=48..911 px → 16..303.7 pt. Confidence: exact (source), measured (render). */
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
     * Caveat: the shell that hosts the real drawer hides the navigation bar
     * (`NativeShell.swift:262`), so this field only exists in the standalone
     * presentation. There is no search field in the shipped drawer screenshot
     * (`darkfinal-drawer-light.png`).
     * Page-local: PNG-measured system control, no Swift literal to cite (see
     * `docs/parity/metrics-classification.md` §6 item 7).
     * Confidence: measured.
     */
    public const val SEARCH_HEIGHT_PT: Int = 44

    /** Search capsule radius: half the 44 pt height. Source: the same fit as [SEARCH_HEIGHT_PT] (top-corner arc). Page-local, measured. Confidence: measured. */
    public const val SEARCH_RADIUS_PT: Int = 22

    /** Search field side inset, measured: white run x=48..1157 px on the 402 pt page → 16.0..385.7 pt, so 370 pt wide. Source: `darkfinal-sessions-light.png`. Page-local, measured. Confidence: measured. */
    public const val SEARCH_INSET_PT: Int = 16

    // --------------------------------------------------------------------- CTA

    /** Empty-state CTA height; resolves `geometry.homePrimaryButtonHeight` (50). Source: `SessionsPage.swift:249` (`.frame(height: 50)`). PNG check: `darkfinal-sessions-light.png` blue box y=1046..1195 px → 150 px = 50.0 pt. */
    public val CTA_HEIGHT_PT: Int get() = UiTokenData.geometryHomePrimaryButtonHeight.value.toInt()

    /** Empty-state CTA corner radius. Source: `SessionsPage.swift:251` (`RoundedRectangle(cornerRadius: 12)`). PNG check: corner fit r≈36 px = 12 pt. Confidence: exact (source), measured (render). */
    public const val CTA_RADIUS_PT: Int = 12

    /** Empty-state bottom padding. Source: `SessionsPage.swift:258` (`.padding(.bottom, 8)`). Confidence: exact. */
    public const val EMPTY_STATE_BOTTOM_PT: Int = 8

    // -------------------------------------------------------------------- toast

    /** Archived toast height. Source: `HomeDrawer.swift:90` (`.frame(height: 30)`). Confidence: exact. */
    public const val TOAST_HEIGHT_PT: Int = 30

    // ---------------------------------------------------- PR22 home drawer extras

    /** White entry card corner radius; resolves `radius.card` (12). Source: `HomeDrawer.swift:524` (`HomeDrawerRowStyle(radius: 12)`). */
    public val DRAWER_CARD_RADIUS_PT: Int get() = UiTokenData.radiusCard.value.toInt()

    // ------------------------------------------------------------ dp accessors

    /** [DRAWER_WIDTH_PT] as a Compose length, read from the generated token. */
    public val drawerWidth: Dp get() = UiTokenData.drawer.width.value.dp

    /** [DRAWER_CONTENT_WIDTH_PT] as a Compose length. */
    public val drawerContentWidth: Dp get() = DRAWER_CONTENT_WIDTH_PT.dp

    /** [ROW_INSET_PT] as a Compose length. */
    public val rowInset: Dp get() = ROW_INSET_PT.dp

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
