// Regression proof for the composer stats hit area (real-device issue 8).
// SPDX-License-Identifier: MIT
//
// The device hierarchy reported each clickable stat node about 14 dp above the
// text it paints: the tap target wrapped an earlier layout node, so tapping the
// glyphs missed while tapping above them opened the sheet. These assertions use
// the rendered page (not a mock): every detail pill's node must contain all of
// its text children, meet the 48 dp touch minimum, and open its own sheet when
// the text centre itself is tapped.
package com.phonedsh.ui.surface

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.click
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.state.ComposerStatsMode
import com.phonedsh.ui.state.ContextBreakdown
import com.phonedsh.ui.state.ContextPressure
import com.phonedsh.ui.state.SessionStats
import com.phonedsh.ui.state.SessionTokenUsage
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w430dp-h932dp")
class ComposerStatsHitTargetTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `every detail pill contains its drawn labels and meets the 48 dp target`() {
        show()
        val labels = mapOf(
            "activity" to listOf("2 轮 4 步", "· 25 tok/s"),
            "usage" to listOf("210 tok"),
            "context" to listOf("90%"),
        )
        labels.forEach { (id, texts) ->
            val pill = compose.onNodeWithTag("pdsh.composer.metrics.$id").getUnclippedBoundsInRoot()
            assertTrue(
                "$id pill height ${pill.bottom - pill.top} must reach the 48 dp touch minimum",
                (pill.bottom - pill.top).value >= 48f,
            )
            assertTrue(
                "$id pill width ${pill.right - pill.left} must reach the 48 dp touch minimum",
                (pill.right - pill.left).value >= 48f,
            )
            texts.forEach { text ->
                val label = compose.onNodeWithText(text, substring = true, useUnmergedTree = true)
                    .getUnclippedBoundsInRoot()
                assertTrue(
                    "$id pill $pill must contain its label '$text' at $label",
                    pill.left <= label.left && pill.top <= label.top &&
                        pill.right >= label.right && pill.bottom >= label.bottom,
                )
            }
        }
    }

    @Test
    fun `tapping the activity label centre opens its session detail`() {
        show()
        tapLabel("2 轮 4 步")
        compose.onNodeWithText("会话统计").assertIsDisplayed()
    }

    @Test
    fun `tapping the usage label centre opens its token detail`() {
        show()
        tapLabel("210 tok")
        compose.onNodeWithText("Token 用量").assertIsDisplayed()
        compose.onNodeWithText("未缓存输入").assertIsDisplayed()
    }

    @Test
    fun `tapping the context label centre opens its context detail`() {
        show()
        tapLabel("90%")
        compose.onNodeWithText("上下文").assertIsDisplayed()
        compose.onNodeWithText("估算用量 / 容量").assertIsDisplayed()
    }

    private fun tapLabel(label: String) {
        compose.onNodeWithText(label, substring = true, useUnmergedTree = true)
            .performTouchInput { click(center) }
        compose.waitForIdle()
    }

    private fun show() {
        compose.setContent {
            PdshTheme {
                Composer(
                    text = "",
                    onTextChange = {},
                    placeholder = UiStrings.COMPOSER_PLACEHOLDER_IDLE,
                    mode = ComposerMode.SEND,
                    enabled = true,
                    canSubmit = false,
                    running = false,
                    onSend = {},
                    onStop = {},
                    sessionStats = SessionStats(2, 4, 1200.0, 0.0, 600.0, 2, 2000.0, 50),
                    tokenUsage = SessionTokenUsage(100, 20, 80, 10),
                    contextPressure = ContextPressure(800, 900, 1000),
                    contextBreakdown = ContextBreakdown(30, 40, 800),
                    statsMode = ComposerStatsMode.DETAILED,
                )
            }
        }
    }
}
