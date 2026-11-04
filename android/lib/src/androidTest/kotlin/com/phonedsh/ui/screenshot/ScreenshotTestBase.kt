// The shared instrumented screenshot harness: fixed frame, frozen clock, real pixels.
// SPDX-License-Identifier: MIT
//
// Why this pipeline and not Robolectric: `captureToImage()` on a device is a
// PixelCopy of the real window region, so the bitmap carries the platform's own
// glyph raster (Minikin/HarfBuzz + the system font) and the platform's own
// `fontScale` multiplication. The Robolectric path had fake font metrics: the
// same text box measured 35 px at fontScale 1 and at fontScale 2, and could never
// catch a type-scale regression. `FontScaleProbeTest` is the counter-experiment
// that fails if this ever silently goes back to fake metrics.
//
// Fixed conditions (asserted before every capture, not assumed): fontScale 1.0,
// locale en-US, light theme, system bars hidden, white harness backdrop, virtual
// clock frozen at +1000 ms. The *frame* is a [ScreenshotProfile]: `gate` keeps the
// 11 historical baselines (1080x2400 px, 420 dpi / 2.625) and `ios-parity` is the
// official golden's contract (1206x2622 px, 480 dpi / 3.0 = 402x874 pt @ 3x).
// A run on a differently configured device fails loudly instead of writing a
// baseline nobody can compare against.
package com.phonedsh.ui.screenshot

import android.graphics.Bitmap
import android.graphics.drawable.ColorDrawable
import android.util.Log
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.theme.PdshTheme
import java.io.File
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.runner.RunWith

/** The device conditions that are the same in every [ScreenshotProfile]. */
object FixedConditions {
    const val FONT_SCALE: Float = 1.0f
    const val LOCALE_LANGUAGE: String = "en"
    const val LOCALE_TAG: String = "en-US"
    const val THEME: String = "light"
}

/**
 * Base for every screenshot test: pins the window, asserts the fixed conditions,
 * freezes the animation clock, writes PNGs plus a metrics line per capture.
 *
 * The subclass calls [setCapturedContent] exactly once and then [capture].
 */
@RunWith(AndroidJUnit4::class)
abstract class ScreenshotTestBase {
    @get:Rule
    val compose = createAndroidComposeRule<ScreenshotActivity>()

    /** The frame this suite runs in; chosen on the command line, never by guess. */
    protected open val profile: ScreenshotProfile = ScreenshotProfile.active()

    /**
     * Profiles this suite is allowed to run in.
     *
     * The gate suites use the historical frame; a parity run that also captured
     * them would put `page-chat.png`-style names into the 27-state directory. The
     * parity suite overrides this, so each direction fails loudly.
     */
    protected open val allowedProfiles: Set<ScreenshotProfile> = setOf(ScreenshotProfile.GATE)

    /** The font-scale probe runs at more than one scale; everything else is pinned. */
    protected open val expectedFontScale: Float? = FixedConditions.FONT_SCALE

    @Before
    fun pinTheWindow() {
        assertTrue(
            "${javaClass.simpleName} does not run in profile '${profile.id}'; " +
                "allowed: ${allowedProfiles.map { it.id }}",
            profile in allowedProfiles,
        )
        profile.verify()
        // Views may only be touched on the main thread; @Before runs on the
        // instrumentation thread.
        compose.runOnUiThread {
            val window = compose.activity.window
            // Edge-to-edge with the bars hidden: the capture is exactly the display
            // size, and no status/navigation inset can shift with a system update.
            WindowCompat.setDecorFitsSystemWindows(window, false)
            WindowInsetsControllerCompat(window, window.decorView).apply {
                hide(WindowInsetsCompat.Type.systemBars())
                systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
            // `colors.background` is tier: unmeasured and the harness must not
            // invent a token, so the backdrop is a fixed capture condition, not a
            // product colour. Pure white also makes "no ink" unambiguous.
            window.setBackgroundDrawable(ColorDrawable(android.graphics.Color.WHITE))
            window.decorView.setBackgroundColor(android.graphics.Color.WHITE)
        }
        assertFixedConditions()
    }

    /**
     * Sets the captured tree.
     *
     * @param widthDp fixed frame width for a surface snapshot; `null` fills the
     *   whole profile frame (1080x2400 in `gate`, 1206x2622 in `ios-parity`).
     * @param heightDp fixed frame height; required with [widthDp].
     * @param content the composable under test.
     */
    protected fun setCapturedContent(
        widthDp: Int? = null,
        heightDp: Int? = null,
        content: @Composable () -> Unit,
    ) {
        // Freeze the animation clock *before* the first composition so every run
        // stops finite animations at the same virtual instant.
        compose.mainClock.autoAdvance = false
        compose.setContent {
            PdshTheme(darkTheme = false) {
                val frame = if (widthDp != null) {
                    Modifier.requiredSize(widthDp.dp, requireNotNull(heightDp).dp)
                } else {
                    Modifier.fillMaxSize()
                }
                Box(modifier = frame.background(Color.White).testTag(CAPTURE_TAG)) {
                    content()
                }
            }
        }
        compose.mainClock.advanceTimeBy(SETTLE_MS)
        compose.waitForIdle()
    }

    /**
     * Captures the frame and writes `<name>.png` plus a metrics line.
     *
     * @param name stable baseline name (also the file name).
     * @param textBoxHeightPx the measured text layout height, recorded only by the
     *   font-scale probe where the number itself is the evidence.
     */
    protected fun capture(name: String, textBoxHeightPx: Float? = null): Bitmap {
        val node = compose.onNodeWithTag(CAPTURE_TAG)
        val bitmap = node.captureToImage().asAndroidBitmap()
        val dir = ScreenshotStore.outputDir(compose.activity, profile)
        check(dir.isDirectory || dir.mkdirs()) { "cannot create the capture directory $dir" }
        File(dir, "$name.png").outputStream().use { out ->
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) {
                "failed to encode $name.png"
            }
        }
        val line = metricsLine(name, bitmap, textBoxHeightPx)
        File(dir, "metrics.txt").appendText(line + "\n")
        Log.i(TAG, line)
        return bitmap
    }

    private fun metricsLine(name: String, bitmap: Bitmap, textBoxHeightPx: Float?): String {
        val activity = compose.activity
        val metrics = activity.resources.displayMetrics
        val config = activity.resources.configuration
        @Suppress("DEPRECATION")
        val scaledDensity = metrics.scaledDensity
        return "name=$name image=$name.png profile=${profile.id} " +
            "width=${bitmap.width} height=${bitmap.height} " +
            "dpi=${metrics.densityDpi} density=${metrics.density} " +
            "fontScale=${config.fontScale} scaledDensity=$scaledDensity " +
            "locale=${localeTag(config)} theme=${FixedConditions.THEME} " +
            "textBoxHeightPx=${textBoxHeightPx?.toString() ?: "-"}"
    }

    private fun localeTag(config: android.content.res.Configuration): String {
        val locale: Locale = config.locales[0]
        return locale.toLanguageTag()
    }

    private fun assertFixedConditions() {
        val activity = compose.activity
        val metrics = activity.resources.displayMetrics
        val config = activity.resources.configuration
        assertEquals("profile ${profile.id}: display width", profile.widthPx, metrics.widthPixels)
        assertEquals("profile ${profile.id}: display height", profile.heightPx, metrics.heightPixels)
        assertEquals("profile ${profile.id}: density dpi", profile.densityDpi, metrics.densityDpi)
        assertEquals("profile ${profile.id}: density", profile.density, metrics.density, 0.0001f)
        expectedFontScale?.let {
            assertEquals("font scale", it, config.fontScale, 0.0001f)
        }
        assertEquals(
            "locale language",
            FixedConditions.LOCALE_LANGUAGE,
            config.locales[0].language,
        )
        Log.i(
            TAG,
            "fixed-conditions profile=${profile.id} " +
                "display=${metrics.widthPixels}x${metrics.heightPixels} " +
                "dpi=${metrics.densityDpi} density=${metrics.density} " +
                "fontScale=${config.fontScale} locale=${localeTag(config)} " +
                "theme=${FixedConditions.THEME}",
        )
    }

    private companion object {
        const val TAG = "PdshScreenshot"

        /** The stable tag of the captured frame; also the node `captureToImage` reads. */
        const val CAPTURE_TAG = "pdsh-screenshot-frame"

        /**
         * Virtual milliseconds advanced before capturing. Long enough for the
         * 220 ms disclosure animations to finish and for layout to settle, short
         * enough that no finite animation can still be mid-flight.
         */
        const val SETTLE_MS = 1_000L
    }
}
