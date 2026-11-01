// Signature surface 6/6: the fail-loud banner (JVM + Robolectric).
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.surface

import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.SemanticsProperties
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class FailLoudBannerSurfaceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `a turn failure shows its message with retry and dismiss`() {
        compose.setContent {
            PdshTheme {
                FailLoudBanner(
                    kind = FailLoudKind.TURN,
                    message = "模型服务连接中断",
                    onRetry = {},
                    onDismiss = {},
                )
            }
        }
        compose.onNodeWithTag(UiTags.FAIL_LOUD_BANNER).assertIsDisplayed()
        compose.onNodeWithText("模型服务连接中断").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.RETRY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.DISMISS).assertIsDisplayed()
    }

    @Test
    fun `retry and dismiss are the two gestures`() {
        var retries = 0
        var dismissals = 0
        compose.setContent {
            PdshTheme {
                FailLoudBanner(
                    kind = FailLoudKind.TURN,
                    message = "turn failed",
                    onRetry = { retries += 1 },
                    onDismiss = { dismissals += 1 },
                )
            }
        }
        compose.onNodeWithTag(UiTags.BANNER_RETRY).performClick()
        compose.onNodeWithTag(UiTags.BANNER_DISMISS).performClick()
        assertEquals(1, retries)
        assertEquals(1, dismissals)
    }

    @Test
    fun `a send failure keeps the draft line and offers only dismiss`() {
        compose.setContent {
            PdshTheme {
                FailLoudBanner(kind = FailLoudKind.SEND, message = "发送被拒", onDismiss = {})
            }
        }
        compose.onNodeWithText(UiStrings.SEND_FAILED).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.BANNER_RETRY).assertDoesNotExist()
        compose.onNodeWithTag(UiTags.BANNER_DISMISS).assertIsDisplayed()
    }

    @Test
    fun `the banner is an assertive live region`() {
        compose.setContent {
            PdshTheme {
                FailLoudBanner(kind = FailLoudKind.TOOL, message = "permission denied", onRetry = {})
            }
        }
        // Semantics: the failure must be announced, not only drawn.
        compose.onNodeWithTag(UiTags.FAIL_LOUD_BANNER)
            .assert(
                SemanticsMatcher.expectValue(
                    SemanticsProperties.LiveRegion,
                    LiveRegionMode.Assertive,
                ),
            )
    }
}
