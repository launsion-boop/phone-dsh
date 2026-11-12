// Signature surface 3/6: the thinking pill (JVM + Robolectric).
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.surface

import android.provider.Settings
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
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.disclosure.DisclosureKind
import com.phonedsh.ui.disclosure.DisclosureMotion
import com.phonedsh.ui.disclosure.PdshDisclosureTags
import com.phonedsh.ui.theme.PdshTheme
import org.junit.After
import org.junit.Rule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import kotlin.math.roundToLong

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
    fun `partial reasoning is disclosed only from an explicit host fact`() {
        var truncated by mutableStateOf<Boolean?>(null)
        compose.setContent {
            PdshTheme {
                ThinkingPill("preview", false, true, {}, detail = "actual excerpt", detailTruncated = truncated)
            }
        }
        compose.onNodeWithText("仅显示部分思考内容").assertDoesNotExist()
        truncated = true
        compose.onNodeWithText("仅显示部分思考内容").assertIsDisplayed()
        truncated = false
        compose.onNodeWithText("仅显示部分思考内容").assertDoesNotExist()
    }

    @Test
    fun `expanding renders the full reasoning as compact markdown`() {
        var expanded by mutableStateOf(false)
        compose.setContent {
            PdshTheme {
                ThinkingPill(
                    summary = "summary line",
                    streaming = false,
                    expanded = expanded,
                    onToggle = { expanded = !expanded },
                    detail = "summary line\n\n**full reasoning body**\n\n- retain the list",
                )
            }
        }
        compose.onNodeWithText("full reasoning body", substring = true).assertDoesNotExist()
        compose.onNodeWithTag(UiTags.THINKING_PILL).performClick()
        compose.waitForIdle()
        compose.onNodeWithText("full reasoning body", substring = true).assertIsDisplayed()
        compose.onNodeWithText("retain the list").assertIsDisplayed()
        compose.onNodeWithTag(MARKDOWN_BODY_TAG).assertIsDisplayed()
        compose.onNodeWithTag(THINKING_CHEVRON_TAG, useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithTag(THINKING_CATEGORY_ICON_TAG, useUnmergedTree = true).assertDoesNotExist()
        assertEquals(
            listOf(UiStrings.THINKING),
            compose.onNodeWithTag(UiTags.THINKING_PILL).fetchSemanticsNode()
                .config[SemanticsProperties.ContentDescription],
        )
    }

    @Test
    fun `expanded compact markdown keeps workspace and scoped resource callbacks`() {
        var openedFile: String? = null
        var openedResource: String? = null
        val resource = "dsh-resource://file/session/session-A/dsh/workspace/notes.md"
        var expanded by mutableStateOf(false)
        compose.setContent {
            PdshTheme {
                ThinkingPill(
                    summary = "summary",
                    streaming = false,
                    expanded = expanded,
                    onToggle = { expanded = !expanded },
                    detail = "[workspace](docs/WORK.md)\n\n[session]($resource)",
                    onOpenFile = { openedFile = it },
                    onOpenResource = { openedResource = it },
                )
            }
        }
        compose.onNodeWithTag(UiTags.THINKING_PILL).performClick()
        compose.onNodeWithText("workspace").performClick()
        compose.onNodeWithText("session").performClick()
        assertEquals("docs/WORK.md", openedFile)
        assertEquals(resource, openedResource)
    }

    @Test
    fun `an actual one-line full source remains expandable when it matches the summary`() {
        var expanded by mutableStateOf(false)
        compose.setContent {
            PdshTheme {
                ThinkingPill(
                    summary = "one-line full source",
                    streaming = false,
                    expanded = expanded,
                    onToggle = { expanded = !expanded },
                    detail = "one-line full source",
                )
            }
        }
        compose.onNodeWithTag(UiTags.THINKING_PILL).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.THINKING_PILL).performClick()
        compose.waitForIdle()
        assertEquals(true, expanded)
        compose.onNodeWithTag(MARKDOWN_BODY_TAG).assertIsDisplayed()
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

    @Test
    fun `expanding samples motion disclosure and keeps the tapped pill fixed`() {
        Settings.Global.putFloat(
            ApplicationProvider.getApplicationContext<android.content.Context>().contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        )
        var expanded by mutableStateOf(false)
        compose.setContent {
            PdshTheme {
                ThinkingPill(
                    summary = "summary line",
                    streaming = false,
                    expanded = expanded,
                    onToggle = { expanded = !expanded },
                    detail = "reasoning paragraph\n\nsecond reasoning paragraph\n\nthird reasoning paragraph",
                )
            }
        }
        val durationMs = DisclosureMotion.specFor(DisclosureKind.BODY, reducedMotion = false).durationMs
        val headerTag = PdshDisclosureTags.header(THINKING_PILL_DISCLOSURE_TAG)
        val bodyTag = PdshDisclosureTags.body(THINKING_PILL_DISCLOSURE_TAG)
        compose.mainClock.autoAdvance = false
        val before = compose.onNodeWithTag(headerTag).fetchSemanticsNode().boundsInRoot.top
        compose.onNodeWithTag(bodyTag).assertDoesNotExist()

        compose.onNodeWithTag(headerTag).performClick()
        compose.mainClock.advanceTimeByFrame()
        var attempts = 0
        while (attempts < 12 && runCatching { bodyHeight(bodyTag) }.getOrDefault(0f) <= 0.2f) {
            compose.mainClock.advanceTimeByFrame()
            attempts++
        }
        val early = bodyHeight(bodyTag)
        assertTrue("the reasoning body started animating (height=$early)", early > 0.2f)
        compose.mainClock.advanceTimeBy((durationMs / 2.0).roundToLong())
        val mid = bodyHeight(bodyTag)
        assertTrue("the body is mid-motion at the half sample (height=$mid)", mid > 0.2f)
        compose.mainClock.advanceTimeBy(durationMs + 40L)
        compose.mainClock.advanceTimeByFrame()
        val end = bodyHeight(bodyTag)
        assertTrue("the body settles taller than the half sample ($mid -> $end)", end > mid)
        assertEquals(
            "rule 6: the tapped pill does not move",
            before,
            compose.onNodeWithTag(headerTag).fetchSemanticsNode().boundsInRoot.top,
            0.5f,
        )
    }

    private fun bodyHeight(tag: String): Float =
        compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot.height / compose.density.density

    @After
    fun restoreAnimatorScale() {
        Settings.Global.putFloat(
            ApplicationProvider.getApplicationContext<android.content.Context>().contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        )
    }
}
