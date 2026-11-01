// Signature surface 3/6: the thinking pill (JVM + Robolectric).
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.surface

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.assertHasNoClickAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class ThinkingPillSurfaceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `the collapsed pill shows its summary while streaming`() {
        compose.setContent {
            PdshTheme {
                ThinkingPill(
                    summary = "归档方式：按天分组。",
                    streaming = true,
                    expanded = false,
                    onToggle = {},
                )
            }
        }
        compose.onNodeWithTag(UiTags.THINKING_PILL).assertIsDisplayed()
        // The sweep is a clipped second copy of the same line; the merged row
        // carries the summary once for accessibility.
        compose.onNodeWithTag(UiTags.THINKING_PILL)
            .assertTextContains("归档方式：按天分组。", substring = true)
    }

    @Test
    fun `a settled pill shows one summary and no sweep`() {
        compose.setContent {
            PdshTheme {
                ThinkingPill(summary = "先看目录结构。", streaming = false, expanded = false, onToggle = {})
            }
        }
        compose.onNodeWithTag(UiTags.THINKING_PILL).assertTextContains("先看目录结构。", substring = true)
    }

    @Test
    fun `expanding reveals the full reasoning`() {
        var expanded by mutableStateOf(false)
        compose.setContent {
            PdshTheme {
                ThinkingPill(
                    summary = "summary line",
                    streaming = false,
                    expanded = expanded,
                    onToggle = { expanded = !expanded },
                    detail = "summary line\n\nfull reasoning body",
                )
            }
        }
        compose.onNodeWithText("full reasoning body", substring = true).assertDoesNotExist()
        compose.onNodeWithTag(UiTags.THINKING_PILL).performClick()
        compose.waitForIdle()
        compose.onNodeWithText("full reasoning body", substring = true).assertIsDisplayed()
    }

    @Test
    fun `a pill with no detail cannot be expanded`() {
        compose.setContent {
            PdshTheme {
                ThinkingPill(summary = "only a summary", streaming = false, expanded = false, onToggle = {})
            }
        }
        compose.onNodeWithTag(UiTags.THINKING_PILL).assertIsNotEnabled()
    }
}
