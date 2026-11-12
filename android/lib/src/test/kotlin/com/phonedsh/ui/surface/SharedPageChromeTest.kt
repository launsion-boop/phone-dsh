// Shared secondary-page chrome: rendered controls, not source-shape checks.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.surface

import androidx.compose.ui.unit.dp

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.testTag
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.HomeMetrics
import com.phonedsh.ui.disclosure.PdshDisclosureTags
import com.phonedsh.ui.page.InfoRow
import com.phonedsh.ui.page.PageFrame
import com.phonedsh.ui.theme.LocalUiTokens
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w430dp-h932dp")
class SharedPageChromeTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private fun renderActivity(): Bitmap {
        val view = compose.activity.window.decorView
        view.measure(
            View.MeasureSpec.makeMeasureSpec(view.width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(view.height, View.MeasureSpec.EXACTLY),
        )
        view.layout(0, 0, view.measuredWidth, view.measuredHeight)
        return Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888).also { bitmap ->
            view.draw(Canvas(bitmap))
        }
    }

    private fun Bitmap.count(color: Int): Int {
        var count = 0
        for (y in 0 until height) for (x in 0 until width) {
            if (getPixel(x, y) == color) count += 1
        }
        return count
    }

    @Test
    fun `page frame paints the HomeSpec page and renders the secondary heading`() {
        compose.setContent {
            PdshTheme {
                PageFrame(title = "二级页面", rootTag = "page-frame") {}
            }
        }
        compose.onNodeWithText("二级页面").assertIsDisplayed()
        val image = renderActivity()
        assertTrue("rendered page contains the HomeSpec fill", image.count(Color(0xFFF7F7F7).toArgb()) > 100)
    }

    @Test
    fun `segmented picker tracks selected state and delivers the selected callback`() {
        var selected by mutableIntStateOf(0)
        val clicks = mutableListOf<Int>()
        compose.setContent {
            PdshTheme {
                SettingsSegmentedPicker(
                    labels = listOf("一般", "模型"),
                    selected = selected,
                    onSelect = { index -> clicks += index; selected = index },
                    modifier = Modifier.fillMaxWidth(),
                    tag = "segments",
                )
            }
        }
        compose.waitForIdle()
        compose.onNodeWithTag("segments-segment-0").assert(
            SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, UiStrings.EXPANDED),
        )
        compose.onNodeWithTag("segments-segment-1").assert(
            SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, UiStrings.COLLAPSED),
        )
        compose.onNodeWithText("模型").performClick()
        assertEquals(listOf(1), clicks)
        compose.onNodeWithTag("segments-segment-0").assert(
            SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, UiStrings.COLLAPSED),
        )
        compose.onNodeWithTag("segments-segment-1").assert(
            SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, UiStrings.EXPANDED),
        )
    }

    @Test
    fun `disabled page row is rendered but cannot invoke its callback`() {
        var callbacks = 0
        compose.setContent {
            PdshTheme {
                Box(Modifier.fillMaxSize()) {
                    InfoRow(
                        title = "未启用",
                        value = null,
                        enabled = false,
                        onClick = { callbacks += 1 },
                        modifier = Modifier.testTag("disabled-row"),
                    )
                }
            }
        }
        compose.onNodeWithText("未启用").assertIsDisplayed()
        compose.onNodeWithText("未启用").assertIsNotEnabled()
        val rowHeightDp = compose.onNodeWithTag("disabled-row")
            .fetchSemanticsNode().boundsInRoot.height / compose.activity.resources.displayMetrics.density
        assertEquals(HomeMetrics.DEFAULT_MIN_LIST_ROW_HEIGHT_PT, rowHeightDp, 0.01f)
        compose.onNodeWithText("未启用").performClick()
        assertEquals(0, callbacks)
    }

    @Test
    fun `sheet frame draws no page-content grabber and labels close as cancel`() {
        var cancels = 0
        compose.setContent {
            PdshTheme {
                SettingsSubPageFrame(
                    title = "设置",
                    onBack = { cancels += 1 },
                    showSheetHandle = true,
                    content = {},
                )
            }
        }
        // interaction.md §2 rule 4: only homeSheetChrome() and Connectors own a
        // grabber; page content inside the sheet must not draw a second one.
        compose.onNodeWithTag("settings-sheet-drag-handle").assertDoesNotExist()
        compose.onNodeWithContentDescription(UiStrings.CANCEL).performClick()
        assertEquals(1, cancels)
    }

    @Test
    fun `section header chevron is the shared disclosure mark and toggles once`() {
        var expanded by mutableStateOf(false)
        var toggles = 0
        compose.setContent {
            PdshTheme {
                SettingsSectionHeader(
                    title = "规则",
                    expanded = expanded,
                    onToggle = { toggles += 1; expanded = !expanded },
                    tag = "section-header",
                )
            }
        }
        compose.onNodeWithTag(PdshDisclosureTags.chevron("section-header"), useUnmergedTree = true).assertExists()
        compose.onNodeWithTag("section-header").performClick()
        assertEquals(1, toggles)
        compose.waitForIdle()
        compose.onNodeWithTag("section-header").assert(
            SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, UiStrings.EXPANDED),
        )
    }

    @Test
    fun `floating page capsule keeps its action and disabled state`() {
        var calls = 0
        var enabled by mutableStateOf(true)
        compose.setContent {
            PdshTheme {
                val tokens = LocalUiTokens.current
                PageBarCapsule(
                    description = "打开文件",
                    onClick = { calls += 1 },
                    insetH = com.phonedsh.ui.SettingsMetrics.WORKSPACE_TOOLBAR_TEXT_INSET_H_PT.dp,
                    elevation = com.phonedsh.ui.SettingsMetrics.WORKSPACE_TOOLBAR_SHADOW_ELEVATION_PT.dp,
                    enabled = enabled,
                    tag = "page-capsule",
                )
            }
        }
        compose.onNodeWithTag("page-capsule").assertIsDisplayed().performClick()
        assertEquals(1, calls)
        enabled = false
        compose.waitForIdle()
        compose.onNodeWithTag("page-capsule").assertIsNotEnabled().performClick()
        assertEquals(1, calls)
    }

    @Test
    fun `HomeSpec primary action uses the generated height and preserves disabled callback state`() {
        var calls = 0
        var enabled by mutableStateOf(true)
        compose.setContent {
            PdshTheme {
                HomePrimaryAction(
                    label = "启动引擎",
                    onClick = { calls += 1 },
                    enabled = enabled,
                    tag = "home-primary",
                )
            }
        }
        compose.onNodeWithTag("home-primary").assertIsDisplayed().performClick()
        val heightDp = compose.onNodeWithTag("home-primary")
            .fetchSemanticsNode().boundsInRoot.height / compose.activity.resources.displayMetrics.density
        assertEquals(HomeMetrics.homePrimaryButtonHeight.value, heightDp, 0.01f)
        assertEquals(1, calls)

        enabled = false
        compose.waitForIdle()
        compose.onNodeWithTag("home-primary").assertIsNotEnabled().performClick()
        assertEquals(1, calls)
    }
}
