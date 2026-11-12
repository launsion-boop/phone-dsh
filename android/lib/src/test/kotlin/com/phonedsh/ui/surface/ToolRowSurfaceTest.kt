// Signature surface 2/6: the tool row (JVM + Robolectric).
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.surface

import android.provider.Settings
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.disclosure.DisclosureKind
import com.phonedsh.ui.disclosure.DisclosureMotion
import com.phonedsh.ui.disclosure.PdshDisclosureTags
import com.phonedsh.ui.theme.PdshTheme
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import kotlin.math.roundToLong

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class ToolRowSurfaceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `collapsed row shows title and summary and hides the detail`() {
        compose.setContent {
            PdshTheme {
                ToolRow(
                    title = "exec",
                    summary = "uid=1000",
                    state = ToolRowState.OK,
                    expanded = false,
                    onToggle = {},
                    detail = { ToolDetailCard(banner = "exec", body = "uid=1000\n") },
                )
            }
        }
        compose.onNodeWithTag(UiTags.TOOL_ROW).assertIsDisplayed()
        compose.onNodeWithText("exec").assertIsDisplayed()
        compose.onNodeWithText("uid=1000").assertIsDisplayed()
        compose.onNodeWithTag(UiTags.TOOL_ROW_DETAIL).assertDoesNotExist()
    }

    @Test
    fun `expanding reveals the terminal card and reports its state`() {
        var expanded by mutableStateOf(false)
        compose.setContent {
            PdshTheme {
                ToolRow(
                    title = "exec",
                    summary = "uid=1000",
                    state = ToolRowState.OK,
                    expanded = expanded,
                    onToggle = { expanded = !expanded },
                    detail = { ToolDetailCard(banner = "exec", body = "uid=1000") },
                )
            }
        }
        compose.onNodeWithTag(UiTags.TOOL_ROW)
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, UiStrings.TOOL_OK))
        compose.onNodeWithTag(UiTags.TOOL_ROW).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag(UiTags.TOOL_ROW_DETAIL).assertIsDisplayed()
        compose.onNodeWithTag(TOOL_ROW_CHEVRON_TAG, useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithTag(TOOL_ROW_CATEGORY_ICON_TAG, useUnmergedTree = true).assertDoesNotExist()
    }

    @Test
    fun `the expanded row hides its summary unless the source enables it`() {
        compose.setContent {
            PdshTheme {
                ToolRow(
                    title = "exec",
                    summary = "short summary",
                    state = ToolRowState.OK,
                    expanded = true,
                    onToggle = {},
                    detail = { androidx.compose.foundation.text.BasicText("detail body") },
                )
            }
        }
        compose.onNodeWithTag(UiTags.TOOL_ROW).assertIsDisplayed()
        compose.onNodeWithText("detail body").assertIsDisplayed()
        compose.onNodeWithText("short summary").assertDoesNotExist()
        compose.onNodeWithTag(TOOL_ROW_CHEVRON_TAG, useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithTag(UiTags.TOOL_ROW)
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.ContentDescription, listOf("exec · ${UiStrings.TOOL_OK}")))
    }

    @Test
    fun `a list-card row uses compact dimensions and its requested category icon`() {
        compose.setContent {
            PdshTheme {
                ToolRow(
                    title = "read",
                    summary = "2 files",
                    state = ToolRowState.OK,
                    expanded = false,
                    onToggle = {},
                    detail = { androidx.compose.foundation.text.BasicText("file detail") },
                    inListCard = true,
                    categoryIcon = com.phonedsh.ui.icon.PdshIcon.READ,
                )
            }
        }
        val row = compose.onNodeWithTag(UiTags.TOOL_ROW).fetchSemanticsNode().boundsInRoot
        val iconBox = compose.onNodeWithTag(
            TOOL_ROW_CATEGORY_ICON_TAG,
            useUnmergedTree = true,
        ).fetchSemanticsNode().boundsInRoot
        val icon = compose.onNodeWithTag(
            "$TOOL_ROW_CATEGORY_ICON_TAG.read",
            useUnmergedTree = true,
        ).fetchSemanticsNode().boundsInRoot
        val titleNode = compose.onNodeWithText("read", useUnmergedTree = true).fetchSemanticsNode()
        val titleLayouts = mutableListOf<TextLayoutResult>()
        titleNode.config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action?.invoke(titleLayouts)
        val titleStyle = titleLayouts.single().layoutInput.style
        assertEquals(22f, row.height, 0.5f)
        assertEquals(16f, iconBox.width, 0.5f)
        assertEquals(16f, iconBox.height, 0.5f)
        assertEquals(14f, icon.width, 0.5f)
        assertEquals(14f, icon.height, 0.5f)
        assertEquals(8f, titleNode.boundsInRoot.left - iconBox.right, 0.5f)
        assertEquals(14f, titleStyle.fontSize.value, 0f)
        assertEquals(22f, titleStyle.lineHeight.value, 0f)
    }

    @Test
    fun `expanding samples motion disclosure and keeps the tapped row fixed`() {
        Settings.Global.putFloat(
            ApplicationProvider.getApplicationContext<android.content.Context>().contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        )
        var expanded by mutableStateOf(false)
        compose.setContent {
            PdshTheme {
                ToolRow(
                    title = "exec",
                    summary = "uid=1000",
                    state = ToolRowState.OK,
                    expanded = expanded,
                    onToggle = { expanded = !expanded },
                    detail = {
                        androidx.compose.foundation.layout.Box(
                            Modifier.fillMaxWidth().height(120.dp).testTag(DETAIL_PROBE),
                        )
                    },
                )
            }
        }
        val durationMs = DisclosureMotion.specFor(DisclosureKind.BODY, reducedMotion = false).durationMs
        val headerTag = PdshDisclosureTags.header(TOOL_ROW_DISCLOSURE_TAG)
        val bodyTag = PdshDisclosureTags.body(TOOL_ROW_DISCLOSURE_TAG)
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
        assertTrue("the detail body started animating (height=$early)", early > 0.2f)
        compose.mainClock.advanceTimeBy((durationMs / 2.0).roundToLong())
        val mid = bodyHeight(bodyTag)
        assertTrue("the body is mid-motion at the half sample (height=$mid)", mid > 0.2f)
        compose.mainClock.advanceTimeBy(durationMs + 40L)
        compose.mainClock.advanceTimeByFrame()
        val end = bodyHeight(bodyTag)
        assertTrue("the body settles taller than the half sample ($mid -> $end)", end > mid)
        assertEquals(
            "rule 6: the tapped header does not move",
            before,
            compose.onNodeWithTag(headerTag).fetchSemanticsNode().boundsInRoot.top,
            0.5f,
        )
        compose.onNodeWithTag(DETAIL_PROBE).assertIsDisplayed()
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

    @Test
    fun `a row without detail cannot be expanded`() {
        compose.setContent {
            PdshTheme {
                ToolRow(
                    title = "read",
                    summary = "",
                    state = ToolRowState.RUNNING,
                    expanded = false,
                    onToggle = {},
                    detail = null,
                )
            }
        }
        compose.onNodeWithTag(UiTags.TOOL_ROW).assertIsNotEnabled()
        compose.onNodeWithTag(UiTags.TOOL_ROW)
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, UiStrings.TOOL_RUNNING))
    }

    @Test
    fun `the toggle callback is invoked once per tap`() {
        var taps = 0
        compose.setContent {
            PdshTheme {
                ToolRow(
                    title = "exec",
                    summary = "ok",
                    state = ToolRowState.OK,
                    expanded = false,
                    onToggle = { taps += 1 },
                    detail = { ToolDetailCard(banner = "exec", body = "ok") },
                )
            }
        }
        compose.onNodeWithTag(UiTags.TOOL_ROW).performClick()
        assertEquals(1, taps)
    }

    @Test
    fun `an error state remains announced and its detail stays readable`() {
        compose.setContent {
            PdshTheme {
                ToolRow(
                    title = "运行命令",
                    summary = "permission denied",
                    state = ToolRowState.ERROR,
                    expanded = true,
                    onToggle = {},
                    detail = {
                        ToolDetailCard(
                            banner = "运行命令",
                            body = "permission denied: /workspace/output",
                            isError = true,
                        )
                    },
                    showsSummaryWhenExpanded = true,
                )
            }
        }
        compose.onNodeWithTag(UiTags.TOOL_ROW)
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, UiStrings.TOOL_ERROR))
        compose.onNodeWithText("permission denied: /workspace/output").assertIsDisplayed()
    }

    private companion object {
        const val DETAIL_PROBE: String = "pdsh.surface.tool-row.test-detail"
    }
}
