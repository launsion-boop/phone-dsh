// The font-scale probe: proof that this screenshot chain captures real text.
// SPDX-License-Identifier: MIT
//
// The rejected pipeline was Robolectric with fake font metrics: the same text box
// measured 35 px at `fontScale` 1 and at 2, so it could never catch a type-scale
// regression. This probe is the counter-experiment and must keep failing loudly
// if the chain regresses to a fake renderer:
//
//   * it renders ONE body-style line, no other ink, on a white window;
//   * it records the measured layout height of that line (`boundsInRoot.height`,
//     the "text box height" the rejected pipeline reported as 35 px);
//   * it writes `fontscale-probe.png` at the current system `fontScale`;
//   * `android/tools/screenshot-capture.sh` runs it at `font_scale=1.0` and at
//     `font_scale=2.0` and requires both the box height and the rasterized ink
//     height in the PNG to grow. Equal heights mean the renderer is fake.
package com.phonedsh.ui.screenshot

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.LocalUiType
import org.junit.Test
import org.junit.runner.RunWith

private const val PROBE_TAG = "fontscale-probe-text"

/** One body-style line; short enough not to wrap at `fontScale` 2. */
private const val PROBE_TEXT = "PDSH 像素基线"

@RunWith(AndroidJUnit4::class)
class FontScaleProbeTest : ScreenshotTestBase() {
    /** The probe is the one capture allowed to run at a non-baseline font scale. */
    override val expectedFontScale: Float? = null

    @Test
    fun probeCapturesRealFontMetrics() {
        var compositionFontScale = 0f
        setCapturedContent {
            compositionFontScale = LocalDensity.current.fontScale
            Box(modifier = Modifier.fillMaxSize().padding(24.dp)) {
                BasicText(
                    text = PROBE_TEXT,
                    style = LocalUiType.current.body.copy(color = LocalUiTokens.current.colors.primary),
                    modifier = Modifier.testTag(PROBE_TAG),
                )
            }
        }
        val textBoxHeight = compose.onNodeWithTag(PROBE_TAG).fetchSemanticsNode().boundsInRoot.height
        check(compositionFontScale > 0f) { "the composition did not see a font scale" }
        check(textBoxHeight > 0f) { "the probe text has no measured height" }
        capture("fontscale-probe", textBoxHeightPx = textBoxHeight)
    }
}
