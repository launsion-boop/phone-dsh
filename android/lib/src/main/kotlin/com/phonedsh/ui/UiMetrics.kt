// The PR22 430 x 932 pt capture contract every Android screenshot is measured against.
// SPDX-License-Identifier: MIT
//
// PR22 replaces the older 402 pt official-UI yardstick: the authoritative
// design is `docs/design/ios-home-design-spec-no-overview.html` and
// `examples/probe-app/PhoneDSHProbe/HomeSpec.swift`, measured on a 430 x 932 pt
// iPhone Pro Max frame. This object is the single owner of that frame and of the
// shared page metrics that follow from it. It is NOT a second token store: the
// per-surface numbers live in [HomeMetrics], [ChatMetrics], [SessionsMetrics],
// [SettingsMetrics] and [ShellFilesMetrics].
//
// Sources:
//
//   * `HomeSpec.swift` — the page's own table (chrome 16, content 20, nav 44,
//     composer 104/56, tab 50, bubble r24, send 36).
//   * `docs/design/ios-home-design-spec-no-overview.html` — the 430 x 932 pt
//     canvas, 59 pt top / 34 pt bottom safe area, and the component geometry.
//
// Consumers:
//
//   * `android/tools/screenshot-capture.sh` reads the viewport constants out of
//     this file to size the emulator display, so the capture viewport has exactly
//     one definition.
//   * the instrumented capture harness pins its frame against them.
//   * a page lane reads the constant instead of re-typing the number.
package com.phonedsh.ui

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * The shared PR22 430 x 932 pt metrics and the viewport they are measured in.
 *
 * Every value is in points (dp on Android: the capture sets density 480, so
 * `1 pt == 3 px` and the 430 pt frame is 1290 px wide). The pixel numbers are
 * derived from the point numbers, never typed twice.
 *
 * Nothing here is a drawing value: a composable that reads [headerHeight] or
 * [contentColumnWidth] is either implementing a parity gap or measuring one, and
 * must say which in its own comment.
 */
public object UiMetrics {
    // ----------------------------------------------------------------- viewport

    /** Design/capture width of the PR22 reference, in points. */
    public const val BASELINE_WIDTH_PT: Int = 430

    /** Design/capture height of the PR22 reference, in points. */
    public const val BASELINE_HEIGHT_PT: Int = 932

    /** Device pixel ratio of the reference (`@3x`). */
    public const val BASELINE_DPR: Int = 3

    /** Reference PNG width: `430 pt x 3`. */
    public const val BASELINE_WIDTH_PX: Int = BASELINE_WIDTH_PT * BASELINE_DPR

    /** Reference PNG height: `932 pt x 3`. */
    public const val BASELINE_HEIGHT_PX: Int = BASELINE_HEIGHT_PT * BASELINE_DPR

    /** Android `wm density` that makes 1 dp equal 1 pt: `160 x 3`. */
    public const val BASELINE_DENSITY_DPI: Int = 160 * BASELINE_DPR

    // ------------------------------------------------- shared metrics (PR #13)

    /**
     * Floating nav row height: 44 pt (`HomeSpec.navButton`, `.nav { height: 44 }`).
     * It starts 8 pt below the top safe area; the safe area itself is
     * platform-owned and is not part of this content-frame number.
     */
    public const val HEADER_HEIGHT_PT: Int = 44

    /** The nav row is a single 44 pt row: title (22) + subtitle (20) fit inside it. */
    public const val HEADER_TITLE_ROW_PT: Int = 44

    /** No extra vertical padding inside the 44 pt nav row (the 8 pt is [HomeMetrics.NAV_TOP_PT]). */
    public const val HEADER_VERTICAL_PAD_PT: Int = 0

    /** Composer card width at 430 pt: `430 - 2 x 16`. */
    public const val COMPOSER_WIDTH_PT: Int = 398

    /** Open composer minimum height (`HomeSpec.composerOpenMinHeight = 104`). */
    public const val COMPOSER_HEIGHT_PT: Int = 104

    /** Closed composer height (`.composer.closed { height: 56 }`). */
    public const val COMPOSER_CLOSED_HEIGHT_PT: Int = 56

    /** Open composer radius (`HomeSpec.composerOpenRadius = 24`). */
    public const val COMPOSER_RADIUS_PT: Int = 24

    /** Closed composer radius (`.composer.closed { border-radius: 28px }`). */
    public const val COMPOSER_CLOSED_RADIUS_PT: Int = 28

    /**
     * Reading content column at 430 pt: `430 - 2 x 20` (`HomeSpec.contentInset`).
     */
    public const val CONTENT_COLUMN_WIDTH_PT: Int = 390

    /** Composer-to-screen inset, both sides: `(430 - 398) / 2`. */
    public const val COMPOSER_OUTER_MARGIN_PT: Int =
        (BASELINE_WIDTH_PT - COMPOSER_WIDTH_PT) / 2

    /** Content-column inset, both sides: `(430 - 390) / 2`. */
    public const val CONTENT_COLUMN_INSET_PT: Int =
        (BASELINE_WIDTH_PT - CONTENT_COLUMN_WIDTH_PT) / 2

    /** Collapsed process row height (`HomeSpec.processRowHeight = 24`). */
    public const val TOOL_ROW_HEIGHT_PT: Int = 24

    /** Block gap between transcript blocks (`HomeSpec.blockGap = 20`). */
    public const val FLOW_GAP_PT: Int = 20

    /** Gap after a response row (`HomeSpec.blockGap = 20`; the old 12 is gone). */
    public const val FLOW_GAP_RESPONSE_PT: Int = 20

    /** Gap after a turn-process control row (`HomeSpec.blockGap = 20`). */
    public const val FLOW_GAP_TURN_PROCESS_PT: Int = 20

    /** Paragraph gap after a user bubble / between paragraphs (`16`). */
    public const val PARAGRAPH_GAP_PT: Int = 16

    /** Process row to its opened card (`HomeSpec.disclosureGap = 8`). */
    public const val DISCLOSURE_GAP_PT: Int = 8

    /** Tab bar content height above the bottom safe area (`HomeSpec.tabBarHeight = 50`). */
    public const val TAB_BAR_HEIGHT_PT: Int = 50

    // ------------------------------------------------------------ dp accessors

    /** [HEADER_HEIGHT_PT] as a Compose length. */
    public val headerHeight: Dp get() = HEADER_HEIGHT_PT.dp

    /** [COMPOSER_WIDTH_PT] as a Compose length. */
    public val composerWidth: Dp get() = COMPOSER_WIDTH_PT.dp

    /** [COMPOSER_HEIGHT_PT] as a Compose length. */
    public val composerHeight: Dp get() = COMPOSER_HEIGHT_PT.dp

    /** [COMPOSER_CLOSED_HEIGHT_PT] as a Compose length. */
    public val composerClosedHeight: Dp get() = COMPOSER_CLOSED_HEIGHT_PT.dp

    /** [CONTENT_COLUMN_WIDTH_PT] as a Compose length. */
    public val contentColumnWidth: Dp get() = CONTENT_COLUMN_WIDTH_PT.dp

    /** [TOOL_ROW_HEIGHT_PT] as a Compose length. */
    public val toolRowHeight: Dp get() = TOOL_ROW_HEIGHT_PT.dp

    /** [FLOW_GAP_PT] as a Compose length. */
    public val flowGap: Dp get() = FLOW_GAP_PT.dp

    /** [FLOW_GAP_RESPONSE_PT] as a Compose length. */
    public val flowGapResponse: Dp get() = FLOW_GAP_RESPONSE_PT.dp

    /**
     * True when a capture is the contract frame: 1290 x 2796 px at 480 dpi.
     *
     * A capture at any other size is not comparable to the golden and must not be
     * written into the parity baseline directory.
     */
    public fun matchesBaselineFrame(widthPx: Int, heightPx: Int, densityDpi: Int): Boolean =
        widthPx == BASELINE_WIDTH_PX &&
            heightPx == BASELINE_HEIGHT_PX &&
            densityDpi == BASELINE_DENSITY_DPI
}
