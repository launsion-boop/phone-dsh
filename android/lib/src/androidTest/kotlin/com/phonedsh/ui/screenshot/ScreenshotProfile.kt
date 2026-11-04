// The two capture profiles: the self-regression gate and the 402 pt parity run.
// SPDX-License-Identifier: MIT
//
// A profile is the frame a suite is allowed to run in. The gate profile keeps the
// 11 historical baselines byte-comparable (1080 x 2400 @ 420 dpi); the parity
// profile is the official golden's contract (402 x 874 pt @ 3x = 1206 x 2622 px
// @ 480 dpi) and exists so an Android capture can be put side by side with the
// iOS baseline without rescaling either side.
//
// Both are asserted, never assumed: a device pinned to the wrong size fails the
// first capture with the expected/actual numbers instead of writing a baseline
// nobody can compare against.
package com.phonedsh.ui.screenshot

import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.ui.UiMetrics
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue

/** The one device configuration a suite may be captured under. */
enum class ScreenshotProfile(
    /** Stable id; also the capture directory name and the `profile=` metrics field. */
    val id: String,
    val widthPx: Int,
    val heightPx: Int,
    val densityDpi: Int,
    val density: Float,
    /** What the profile exists to prove, printed in the conditions receipt. */
    val purpose: String,
) {
    /** The historical 11-baseline gate; `page-*` / `surface-*` / `fontscale-probe`. */
    GATE(
        id = "gate",
        widthPx = 1080,
        heightPx = 2400,
        densityDpi = 420,
        density = 2.625f,
        purpose = "self-regression gate (Android vs its own previous commit)",
    ),

    /**
     * Android-only captures: states that have no iOS counterpart and therefore no
     * parity claim — a self-regression baseline, nothing more.
     *
     * The frame is the gate frame on purpose: these suites were written and
     * reviewed against 1080 x 2400 @ 420 dpi (`captureFullScreen()` even reads the
     * real window), and the profile exists to keep their pixels out of the 11
     * historical gate baselines, not to change what they render. The baseline
     * directory is `screenshots/android-only/` (the script owns that mapping).
     */
    ANDROID_ONLY(
        id = "android-only",
        widthPx = 1080,
        heightPx = 2400,
        densityDpi = 420,
        density = 2.625f,
        purpose = "Android-only self-regression captures (no iOS baseline, no parity claim)",
    ),

    /**
     * The iOS-comparable profile: same state names, same 402 x 874 @3 viewport.
     *
     * The numbers come from [UiMetrics], which owns the contract; nothing here is
     * re-typed.
     */
    IOS_PARITY(
        id = "ios-parity",
        widthPx = UiMetrics.BASELINE_WIDTH_PX,
        heightPx = UiMetrics.BASELINE_HEIGHT_PX,
        densityDpi = UiMetrics.BASELINE_DENSITY_DPI,
        density = UiMetrics.BASELINE_DPR.toFloat(),
        purpose = "same-frame capture against the iOS baseline (no pixel diff to iOS)",
    ),
    ;

    /** Frame width in dp; 1206 px at density 3 is 402 dp. */
    val widthDp: Int get() = (widthPx / density).toInt()

    /** Frame height in dp; 2622 px at density 3 is 874 dp. */
    val heightDp: Int get() = (heightPx / density).toInt()

    /**
     * Fails when this entry's pixels and dp disagree, i.e. when the frame is not
     * the viewport it claims to be.
     *
     * The integer-dp round trip only holds for a frame that *is* an integer dp
     * viewport. `gate` is a pixel frame (1080 px at 2.625 = 411.43 dp); `ios-parity`
     * is a point frame (402 pt x 3 = 1206 px) and is checked exactly.
     */
    fun verify() {
        assertEquals("$id: densityDpi must be density x 160", density * 160f, densityDpi.toFloat(), 0.001f)
        if (this == IOS_PARITY) {
            assertEquals(
                "$id: widthPx must be widthDp x density",
                widthDp * density,
                widthPx.toFloat(),
                0.001f,
            )
            assertEquals(
                "$id: heightPx must be heightDp x density",
                heightDp * density,
                heightPx.toFloat(),
                0.001f,
            )
            assertTrue(
                "$id must be the UiMetrics contract ($UiMetricsLayout)",
                UiMetrics.matchesBaselineFrame(widthPx, heightPx, densityDpi),
            )
            assertEquals("$id width", UiMetrics.BASELINE_WIDTH_PT, widthDp)
            assertEquals("$id height", UiMetrics.BASELINE_HEIGHT_PT, heightDp)
        }
    }

    companion object {
        /** The `am instrument -e` argument naming the profile; absent means [GATE]. */
        const val ARGUMENT: String = "pdsh.screenshot.profile"

        /** The profile this run was started with. */
        fun active(): ScreenshotProfile {
            val raw = InstrumentationRegistry.getArguments().getString(ARGUMENT)
            if (raw.isNullOrEmpty()) return GATE
            return fromId(raw)
        }

        /** Resolves an id; an unknown id is a typo in the harness, not a fallback. */
        fun fromId(raw: String): ScreenshotProfile =
            ScreenshotProfile.entries.firstOrNull { it.id == raw }
                ?: throw IllegalArgumentException(
                    "unknown screenshot profile '$raw'; expected one of " +
                        "${ScreenshotProfile.entries.map { it.id }} " +
                        "(pass it with: am instrument -e $ARGUMENT <id>)",
                )

        /** Human-readable contract string, for failure messages. */
        private val UiMetricsLayout: String
            get() = "${UiMetrics.BASELINE_WIDTH_PT} x ${UiMetrics.BASELINE_HEIGHT_PT} pt @ " +
                "${UiMetrics.BASELINE_DPR}x = ${UiMetrics.BASELINE_WIDTH_PX} x " +
                "${UiMetrics.BASELINE_HEIGHT_PX} px @ ${UiMetrics.BASELINE_DENSITY_DPI} dpi"
    }
}
