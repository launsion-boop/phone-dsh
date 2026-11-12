// The Settings family's PR22 grouped-list chrome.
// SPDX-License-Identifier: MIT
//
// PR22 replaced the five-tab settings sheet with one grouped list in the
// phone's own settings shape (`SettingsPage.swift`). The page is
// `.homeGroupedList()`: inset-grouped white rows on the HomeSpec page,
// `defaultMinListRowHeight = 48`, 16 pt body labels, 15 pt placeholder values,
// 24 pt glyph in a 24 pt box with a 12 pt gap, and one `SettingsRowLabel`
// minimum of 32 pt. `HomeAppearance` draws the flat inline nav bar (44 pt,
// 17 pt semibold ink, no hairline).
//
// The `SEGMENTED_*` constants below are kept only because the still-unported
// five-tab `SettingsPage.kt` compiles against them; they describe a layout PR22
// no longer renders and must not be used by a new page. The grouped-list
// constants at the end are the PR22 values.
//
// Pixel evidence for the system-drawn group cards still comes from the 402 pt
// captures and is kept as `measured`; the source-stated minimums are `exact`.
//
// Confidence: see the vocabulary in `ChatMetrics.kt`.

package com.phonedsh.ui

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.phonedsh.ui.theme.generated.UiTokenData

/**
 * Current Settings chrome: navigation bar, segmented tab picker, inset-grouped
 * cards, rows, switch and chevron.
 *
 * Most rows are page-local measurements. The four token-backed rows
 * (`NAV_BAR_HEIGHT_PT`, `CARD_MARGIN_H_PT`, `ROW_HEIGHT_PT`,
 * `GROUPED_LIST_MIN_ROW_HEIGHT_PT`) read the reviewed `spec/ui/v1/tokens.json`
 * table directly; the remaining measured geometry has only PNG provenance.
 */
public object SettingsMetrics {
    /** 430pt PR22 workspace.png: 64pt text pill minus 32pt text => 16pt each side. Page-local, measured. */
    public const val WORKSPACE_TOOLBAR_TEXT_INSET_H_PT: Int = 16
    /** UIKit toolbar halo is unmeasured on Android; preserve zero elevation until a native comparison. Android-only platform adaptation. */
    public const val WORKSPACE_TOOLBAR_SHADOW_ELEVATION_PT: Int = 0

    /** SettingsPage.swift ArchivedSessionsPage: title/time VStack spacing 2. Page-local. */
    public const val ARCHIVE_TEXT_GAP_PT: Int = 2

    // --------------------------------------------------------------- nav bar

    /** Inline navigation bar height; resolves `geometry.navButton` (44, `pageHeaderMinHeight` alias). Source: `SettingsPage.swift:105` (`navigationBarTitleDisplayMode(.inline)`); PNG check: title ink centre at y=253 px with a 62 pt safe top → 44 pt bar. */
    public val NAV_BAR_HEIGHT_PT: Int get() = UiTokenData.geometryNavButton.value.toInt()

    // ------------------------------------------------------- segmented picker

    /** Segmented control height. Source: PNG check `settings-chat.png` track y=378..473 px → 96 px = 32.0 pt. Page-local, measured. Confidence: measured. */
    public const val SEGMENTED_HEIGHT_PT: Int = 32

    /**
     * Legacy segmented-control side inset: 16 pt.
     *
     * PR22 removed the five-tab segmented picker from the current
     * `SettingsPage.swift`, which now renders `.homeGroupedList()` with an inline
     * title (`SettingsPage.swift:105`); this value survives only because the
     * still-unported five-tab `SettingsPage.kt` compiles against it. The 16 pt
     * also matches the current grouped-card margin ([CARD_MARGIN_H_PT]), but that
     * is a different role. Historical evidence: `settings-chat.png` track
     * x=48..1157 px → 16.0..385.7 pt. Confidence: measured (historical), no
     * current Swift literal.
     */
    public const val SEGMENTED_INSET_H_PT: Int = 16

    /**
     * Segmented control vertical padding, bottom half.
     *
     * Historical five-tab picker: the old source literal was 10
     * (`.padding(.vertical, 10)`), and PR22 removed that control. The *rendered*
     * list starts at y=502 px = 167.33 pt, i.e. 9.33 pt below the track's bottom
     * edge at 158.0, and [FIRST_CARD_TOP_INSET_PT] is measured from that edge. The
     * baseline wins over the old source literal by 2 px: with 10 the whole sheet
     * below the picker sits 2 px low once the iOS safe area is applied, and a
     * 2 px offset re-rasterises every glyph in the comparison.
     * Page-local, measured (list background edge), not source.
     */
    public const val SEGMENTED_PADDING_V_PT: Float = 9.33f

    /** Segmented control track corner radius. The track is a capsule; PNG corner fit at the top edge is consistent with half the 32 pt height. Source: `settings-chat.png` (top-edge corner fit). Page-local, measured. Confidence: inferred (capsule = height / 2). */
    public const val SEGMENTED_RADIUS_PT: Int = 16

    /** Gap from the 44 pt bar to the track's top edge, measured. Source: `settings-chat.png`: bar bottom 62 + 44 = 106 pt = 318 px, track top 378 px → 60 px = 20 pt. The page declares 10 pt of vertical padding, so the other 10 pt is the navigation content inset the system adds; a page that lays out its own bar must add both. Page-local, measured (the 20), inferred (the split). */
    public const val SEGMENTED_TOP_GAP_PT: Int = 20

    // ------------------------------------------------------------ grouped list

    /** Group card side margin; resolves `geometry.chromeInset` (16). Source: PNG check card white starts at x=48 px and ends at 1157 px → 16.0..385.7 pt on the 402 pt screen. */
    public val CARD_MARGIN_H_PT: Int get() = UiTokenData.geometryChromeInset.value.toInt()

    /**
     * Group card corner radius, measured.
     *
     * Source: `settings-chat.png` first card: top edge y=606 px, left edge x=48 px. The
     * left boundary follows x=81 at y=620, x=56 at y=650 and reaches 48 at
     * y≈676; a circular fit through those points gives r≈77-79 px = 26 pt. The
     * top edge begins ~95 px in from the left, which is the signature of
     * SwiftUI's **continuous** corner style, so treat 26 as the nominal radius,
     * not a circular arc. Page-local, measured.
     */
    public const val CARD_RADIUS_PT: Int = 26

    /**
     * Vertical gap between two cards: 35.0 pt.
     *
     * Source: `docs/receipts/ios-baseline-screens/ios-settings.png`, the PNG the
     * parity sheet lays beside the Android capture. Card 1's last white row is
     * y=919 px and card 2's first white row is y=1025 px, so the empty band
     * between the two cards is 105 px = 35.0 pt; the same 105 px band repeats
     * three times (920→1024, 1653→1757, 2386→2490).
     *
     * The previous 38.67 pt cited "card 1 bottom y=914 px, card 2 top y=1030 px"
     * (116 px). Those rows are not card edges in the cited file and 116 px is not
     * the gap that file draws; the Android render then carried the 3.67 pt error
     * into every successive card. Page-local, measured (four bands).
     *
     * Parity note (W3 settings root): the iOS fixture puts 57 pt between the last
     * row of one group and the first row of the next. That band is the system
     * section header plus the grouped list's section spacing; neither is declared
     * in `SettingsPage.swift` or `tokens.json`, so the 57 pt is a contract gap.
     * This 35 pt remains the measured card-to-card band used by the pixel suite.
     */
    public const val SECTION_GAP_PT: Float = 35f

    /** Top inset from the list's top edge to the first card. Source: PNG check grouped list background starts y=502 px, card 1 top y=606 px → 104 px = 34.7 pt. Page-local, measured. */
    public const val FIRST_CARD_TOP_INSET_PT: Float = 34.67f

    /**
     * Top inset from a *grouped sub-page's* bar bottom to its first card: 45.0 pt.
     *
     * Source: `ios-settings-about.png` — the inline bar ends at the safe top 62 +
     * 44 = 106 pt and the single card's top edge is y=453 px = 151.0 pt, so the
     * gap is 45.0 pt. It is larger than [FIRST_CARD_TOP_INSET_PT] (34.67) because
     * the general tab's list starts *below its segmented picker*, where SwiftUI
     * has already consumed part of the navigation content inset; a pushed page's
     * `List` starts directly under the bar and keeps the whole inset.
     * Page-local, measured (one page, one card, 135 px).
     */
    public const val SUB_PAGE_GROUPED_TOP_INSET_PT: Float = 45f

    /**
     * The row text's optical offset: 1 pt up, for labels and values only.
     *
     * iOS `List` rows and Compose rows both centre a 20.33 pt line box inside the
     * 52.33 pt row, but the CJK ink does not land in the same place: at 17 pt the
     * iOS ink box is 15.0 pt tall and centred (e.g. 权限 220.67..235.67 in a row
     * that ends at 254.33), while the Android ink is 15.67-16.0 pt and its centre
     * sits 1.0 pt lower (221.33..237.0). Measured on six rows of
     * `ios-settings.png`; the value ink sits 0.84 pt lower, so one offset serves
     * both. Controls are *not* shifted: the switch (iOS 703.0..730.7, Android
     * 702.0..731.3) and the chevrons are already centred.
     *
     * It is an optical correction, not a layout length: it does not change the
     * row's height or its neighbours, which is why it is applied as a draw offset.
     * Android-only glyph-metric correction, measured (ink boxes), and it buys the
     * glyph overlap that a pixel comparison needs.
     */
    public const val ROW_TEXT_OPTICAL_OFFSET_PT: Float = -1f

    /**
     * The iOS screen's safe-area top: 62.0 pt.
     *
     * Source: the calibration above pins the inline bar to 62..106 pt (the title's
     * ink centre at 84.35 pt against a 44 pt bar), and the card tops corroborate
     * it once the picker's bottom padding is the rendered 9.33 rather than the
     * source's 10: 62 + 44 + 20 + 32 + 9.33 + 34.67 = 202.0 exactly.
     *
     * L79 uses it only in the parity capture harness: the harness hides the
     * Android system bars (a capture condition), so `statusBarsPadding()` inside
     * the pages collapses to 0 and every page sits one safe-area higher than the
     * device screenshot it is laid beside. The harness reserves this band so both
     * panels share an absolute y. It is **not** a page inset: on a device that
     * shows the system bars the page gets the band from the platform.
     * Android-only capture harness value; the platform owns the inset on device.
     */
    public const val PARITY_SAFE_AREA_TOP_PT: Float = 62f

    /**
     * One grouped row's rendered height.
     *
     * Resolves `geometry.defaultMinListRowHeight` (48). PR22's
     * `HomeSpec.homeGroupedList()` sets
     * `.environment(\.defaultMinListRowHeight, 48)` (`HomeSpec.swift:207`), so 48
     * is the source-owned minimum. The old 402 pt capture measured 52.33 pt for
     * the pre-PR22 17 pt list; that render is superseded.
     *
     * Parity note (W3 settings root): the iOS fixture measures these rows at
     * 62 pt (`docs/parity/bench.md` § settings-root), not 48. `SettingsPage.swift:459`
     * gives the row content a 32 pt minimum; the other 30 pt is the system
     * `List` row's vertical padding, which no Swift literal or `tokens.json`
     * entry declares. The 62 pt row and the 57 pt group gap (see
     * [SECTION_GAP_PT]) are therefore a contract gap, not a value this page may
     * hard-code; 48 stays the token-owned minimum until the contract carries them.
     */
    public val ROW_HEIGHT_PT: Float get() = UiTokenData.geometryDefaultMinListRowHeight.value

    /** Row content leading inset inside the card. Source: PNG check label glyph starts x=98 px; card starts x=48 px → 16.7 pt (16 pt inset plus ~0.7 pt glyph bearing). Page-local: PNG-only provenance; tokenising it needs a provenance-tier change (`docs/parity/metrics-classification.md` §6 item 7). */
    public const val ROW_CONTENT_INSET_PT: Int = 16

    /** Row separator thickness. Source: PNG check the hairline at y=760 occupies y=760..762 px → 3 px = 1.0 pt (iOS 26's grouped-list separator is thicker than the old flat list's 1 px). Page-local: measured 1 pt, not the 0.5 pt `stroke.hairline` role. */
    public const val SEPARATOR_HEIGHT_PT: Float = 1f

    /** Row separator horizontal inset inside the card. Source: PNG check hairline x=96..1109 px, card x=48..1157 px → 16.0 pt on both sides. Page-local, measured. */
    public const val SEPARATOR_INSET_PT: Int = 16

    // ------------------------------------------------------- row trailing items

    /** Chevron glyph width. Source: PNG check x=1083..1101 px → 19 px = 6.3 pt. Page-local, measured. */
    public const val CHEVRON_WIDTH_PT: Float = 6.33f

    /** Chevron glyph height. Source: PNG check y=668..701 px → 34 px = 11.3 pt. Page-local, measured. */
    public const val CHEVRON_HEIGHT_PT: Float = 11.33f

    /** Slot from the value's right edge to the chevron's right edge ("值右缘 20.7"). Source: PNG check value right 1039 px, chevron right 1101 px → 62 px = 20.7 pt. Page-local, measured. */
    public const val VALUE_CHEVRON_SLOT_PT: Float = 20.67f

    /** Distance from the card's trailing edge to the value's right edge: 18.67 + 20.67. Source: arithmetic on the two measured edges; PNG check 1157-1039 = 118 px = 39.3 pt. Page-local, measured. */
    public const val VALUE_TRAILING_INSET_PT: Float = 39.33f
    /** A *menu* row's trailing inset: 17.6 pt from the card edge to the up-down chevron's right edge (`ios-settings.png` 语言 chevron ink 359.3..367.7, card right 385.3). Page-local, measured. */
    public const val MENU_TRAILING_INSET_PT: Float = 17.6f

    /** A *menu* row's glyph slot: 16.0 pt between the value's right edge (351.7) and the chevron's (367.7). Page-local, measured. */
    public const val MENU_CHEVRON_SLOT_PT: Float = 16f

    /** Switch width. Source: PNG check green track x=927..1115 px → 189 px = 63.0 pt. Page-local, measured. */
    public const val SWITCH_WIDTH_PT: Int = 63

    /** Switch height. Source: PNG check green track y=2104..2192 px → 89 px = 29.7 pt. Page-local, measured. */
    public const val SWITCH_HEIGHT_PT: Float = 29.67f

    /** Switch trailing inset inside the card. Source: PNG check card right 1157 px, switch right 1115 px → 42 px = 14.0 pt. Page-local, measured. */
    public const val SWITCH_TRAILING_INSET_PT: Int = 14

    // ------------------------------------------------ PR22 grouped-list values

    /** Settings page grouped-list minimum row height; resolves `geometry.defaultMinListRowHeight` (48). Source: `HomeSpec.swift:207` (`.environment(\.defaultMinListRowHeight, 48)`). */
    public val GROUPED_LIST_MIN_ROW_HEIGHT_PT: Int get() = UiTokenData.geometryDefaultMinListRowHeight.value.toInt()

    // Native component metrics required by the scoped C/D/F consumers.

    /** Native Stepper painted bounds. Source: PR22 `settings-font-runtime.png`, 1290x2796 at 3x (gray fill 279px plus antialiasing). Page-local, measured. */
    public const val FONT_STEPPER_WIDTH_PT: Int = 94

    /** Native Stepper painted height: 96px / 3 in the same reference. Page-local, measured. */
    public const val FONT_STEPPER_HEIGHT_PT: Int = 32

    /** Plus/minus painted glyph extent in the same native Stepper capture. Page-local, measured (rounded). */
    public const val FONT_STEPPER_GLYPH_PT: Int = 14

    /** Plus/minus stroke in the same 3x capture. Page-local, measured (rounded). */
    public const val FONT_STEPPER_STROKE_PT: Int = 2

    /** Separator painted height inside the native Stepper. Page-local, measured (rounded). */
    public const val FONT_STEPPER_SEPARATOR_HEIGHT_PT: Int = 24

    // ------------------------------------------------------------ dp accessors

    /** [NAV_BAR_HEIGHT_PT] as a Compose length. */
    public val navBarHeight: Dp get() = NAV_BAR_HEIGHT_PT.dp

    /** [SEGMENTED_HEIGHT_PT] as a Compose length. */
    public val segmentedHeight: Dp get() = SEGMENTED_HEIGHT_PT.dp

    /** [SEGMENTED_INSET_H_PT] as a Compose length. */
    public val segmentedInset: Dp get() = SEGMENTED_INSET_H_PT.dp

    /** [CARD_MARGIN_H_PT] as a Compose length. */
    public val cardMargin: Dp get() = CARD_MARGIN_H_PT.dp

    /** [CARD_RADIUS_PT] as a Compose length. */
    public val cardRadius: Dp get() = CARD_RADIUS_PT.dp

    /** [ROW_HEIGHT_PT] as a Compose length. */
    public val rowHeight: Dp get() = ROW_HEIGHT_PT.dp

    /** [SEPARATOR_INSET_PT] as a Compose length. */
    public val separatorInset: Dp get() = SEPARATOR_INSET_PT.dp

    /** [SWITCH_WIDTH_PT] as a Compose length. */
    public val switchWidth: Dp get() = SWITCH_WIDTH_PT.dp

    /** [SWITCH_HEIGHT_PT] as a Compose length. */
    public val switchHeight: Dp get() = SWITCH_HEIGHT_PT.dp
}
