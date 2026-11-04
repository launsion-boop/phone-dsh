// The drawer's rows and geometry, asserted on the JVM.
// SPDX-License-Identifier: MIT
//
// The pre-PR22 public app-map drawer remains compatible. The product root uses
// HomeDrawer, whose source-based tests are separate. This compatibility drawer: a row that compiles but has no route,
// or a route no row names, is exactly the "routing-reachable, touch-unreachable"
// bug L1/L2/L5 reported. These tests tap every row of the real [PdshDrawer] and
// assert the route it hands back; the geometry assertions pin the iOS numbers
// this lane aligns to (320 panel / 288 content / 48 row / 22 icon slot).
//
// `NativeShell.swift:97` (320), `SessionsPage.swift:594` (288), `:422` (22),
// `:432` (48). The values are read from [LegacyDrawerMetrics], never re-typed here.
package com.phonedsh.ui.nav

import androidx.compose.ui.test.assertHeightIsEqualTo
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.height
import androidx.compose.ui.unit.width
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class PdshDrawerTest {

    @get:Rule
    val compose = createComposeRule()

    private val entries = listOf(
        PdshDrawerEntry("对话", PdshDrawerIcon.CHAT, PdshRoute.Chat),
        PdshDrawerEntry("会话", PdshDrawerIcon.SESSIONS, PdshRoute.Sessions),
        PdshDrawerEntry("工作文件夹", PdshDrawerIcon.FOLDER, PdshRoute.WorkspaceFolders),
        PdshDrawerEntry("命令", PdshDrawerIcon.TERMINAL, PdshRoute.Tools),
        PdshDrawerEntry("设备连接", PdshDrawerIcon.DEVICE, PdshRoute.DeviceConnection),
        PdshDrawerEntry("DSH 页面", PdshDrawerIcon.WEB, PdshRoute.WebSurface),
    )

    private val footer = listOf(
        PdshDrawerEntry("定时任务", PdshDrawerIcon.CLOCK, PdshRoute.Automation),
        PdshDrawerEntry("设置", PdshDrawerIcon.SETTINGS, PdshRoute.Settings),
    )

    private fun show(
        onSelect: (PdshRoute) -> Unit = {},
        onDismiss: () -> Unit = {},
    ) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshDrawer(
                    entries = entries,
                    footerEntries = footer,
                    onSelect = onSelect,
                    onDismiss = onDismiss,
                )
            }
        }
        compose.waitForIdle()
    }

    @Test
    fun `every app-map row hands back its route`() {
        var selected: PdshRoute? = null
        show(onSelect = { selected = it })
        entries.forEach { entry ->
            selected = null
            compose.onNodeWithTag(PdshDrawerTags.ROW_PREFIX + entry.label).performClick()
            compose.runOnIdle {
                assertEquals(entry.route, selected)
            }
        }
    }

    @Test
    fun `the footer rows hand back their routes too`() {
        var selected: PdshRoute? = null
        show(onSelect = { selected = it })
        footer.forEach { entry ->
            selected = null
            compose.onNodeWithTag(PdshDrawerTags.ROW_PREFIX + entry.label).performClick()
            compose.runOnIdle {
                assertEquals(entry.route, selected)
            }
        }
    }

    @Test
    fun `the panel is the iOS 320 pt wide`() {
        show()
        compose.onNodeWithTag(PdshDrawerTags.PANEL)
            .assertWidthIsEqualTo(LegacyDrawerMetrics.drawerWidth)
        // 320 - 16 - 16 = 288, the baseline's measured content width.
        assertEquals(
            LegacyDrawerMetrics.DRAWER_CONTENT_WIDTH_PT,
            LegacyDrawerMetrics.DRAWER_WIDTH_PT - 2 * LegacyDrawerMetrics.ROW_INSET_PT,
        )
    }

    @Test
    fun `a row is 48 pt tall and starts at the 16 pt inset`() {
        show()
        val row = compose.onNodeWithTag(PdshDrawerTags.ROW_PREFIX + "对话")
        row.assertHeightIsEqualTo(LegacyDrawerMetrics.drawerRowHeight)
        // The row merges its descendants (it is one button), so the glyph slot
        // and the title are only addressable in the unmerged tree.
        val icon = compose.onNodeWithTag(PdshDrawerTags.ICON_PREFIX + "对话", useUnmergedTree = true)
            .getUnclippedBoundsInRoot()
        // The row's own 16 pt inset, then the 22 pt slot.
        assertEquals(16f, icon.left.value, 0.5f)
        assertEquals(22f, icon.width.value, 0.5f)
        assertEquals(22f, icon.height.value, 0.5f)
    }

    @Test
    fun `the title starts after the 22 pt slot and the 10 pt gap`() {
        show()
        val label = compose.onNodeWithText("对话", useUnmergedTree = true).getUnclippedBoundsInRoot()
        // 16 (row inset) + 22 (slot) + 10 (gap) = 48.
        assertEquals(48f, label.left.value, 0.5f)
    }

    @Test
    fun `the scrim strip closes the drawer without navigating`() {
        var selected: PdshRoute? = null
        var dismissed = false
        show(onSelect = { selected = it }, onDismiss = { dismissed = true })
        compose.onNodeWithTag(PdshDrawerTags.SCRIM).performClick()
        compose.runOnIdle {
            assertEquals(true, dismissed)
            assertEquals(null, selected)
        }
    }

    @Test
    fun `every row the host needs is present`() {
        show()
        val expected = listOf(
            "对话", "会话", "工作文件夹", "命令", "设备连接", "DSH 页面",
            "定时任务", "设置",
        )
        expected.forEach { label ->
            compose.onNodeWithTag(PdshDrawerTags.ROW_PREFIX + label).assertExists()
        }
        // 48 dp rows: the panel's rows are its own height, not a page's.
        compose.onNodeWithTag(PdshDrawerTags.ROW_PREFIX + "设置")
            .assertHeightIsEqualTo(48.dp)
    }
}
