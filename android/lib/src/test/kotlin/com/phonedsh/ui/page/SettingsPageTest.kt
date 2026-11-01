// Settings page: the mirrored index (three groups, thirteen rows) and its sub-page.
// SPDX-License-Identifier: MIT
//
// Authority: `examples/probe-app/PhoneDSHProbe/SettingsPage.swift`. These tests
// pin the three rendered groups, the row order, the baseline's wording for an
// unset value, the one conditional footer, every navigation target, the two
// write gestures, and the 新会话默认权限 sub-page.
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHasNoClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class SettingsPageTest {
    @get:Rule
    val compose = createComposeRule()

    private fun show(
        facts: SettingsFacts = SettingsFacts(),
        onNavigate: (SettingsDestination) -> Unit = {},
        onToggleBackground: (Boolean) -> Unit = {},
        onSelectMode: (BusyEnterMode) -> Unit = {},
        onBack: () -> Unit = {},
    ) {
        val state = SettingsScreenState.from(facts)
        compose.setContent {
            PdshTheme {
                SettingsPage(
                    state = state,
                    onNavigate = onNavigate,
                    onToggleBackgroundKeepAlive = onToggleBackground,
                    onSelectBusyEnterMode = onSelectMode,
                    onBack = onBack,
                )
            }
        }
    }

    /** The index scrolls: a row below the fold is only composed once it is near. */
    private fun scrollTo(text: String) {
        compose.onNodeWithTag(UiTags.SETTINGS_LIST).performScrollToNode(hasText(text))
    }

    /**
     * The baseline's body is `List { mainGroup; toolsGroup; aboutGroup }`: three
     * groups, thirteen rows, in this order. The appendix is the Android-only
     * fourth group and comes last.
     */
    @Test
    fun `the index keeps the baseline's three groups, its thirteen rows and the §1 runtime row`() {
        val state = SettingsScreenState.from(SettingsFacts())
        assertEquals(
            listOf(
                SettingsScreenState.MAIN_SECTION_ID,
                SettingsScreenState.TOOLS_SECTION_ID,
                SettingsScreenState.ABOUT_SECTION_ID,
                SettingsScreenState.PLATFORM_SECTION_ID,
            ),
            state.sections.map { it.id },
        )
        // The titles are fixed copy in the page (not snapshot data): the three
        // group headers and no header for the first group.
        assertEquals(
            listOf(
                SettingsScreenState.PERMISSION_ROW_ID,
                SettingsScreenState.ASK_ROW_ID,
                SettingsScreenState.MODEL_ROW_ID,
                SettingsScreenState.MCP_ROW_ID,
                SettingsScreenState.BACKGROUND_ROW_ID,
            ),
            state.sections[0].rows.map { it.id },
        )
        assertEquals(
            listOf(
                SettingsScreenState.WEB_SEARCH_ROW_ID,
                SettingsScreenState.NETWORK_ROW_ID,
                SettingsScreenState.PLUGINS_ROW_ID,
                SettingsScreenState.COMMAND_ROW_ID,
                SettingsScreenState.RUNTIME_ROW_ID,
                SettingsScreenState.BUSY_ENTER_ROW_ID,
            ),
            state.sections[1].rows.map { it.id },
        )
        assertEquals(
            listOf(
                SettingsScreenState.VERSION_ROW_ID,
                SettingsScreenState.LICENSES_ROW_ID,
                SettingsScreenState.EXPORT_ROW_ID,
            ),
            state.sections[2].rows.map { it.id },
        )
        // The thirteen rendered titles, in the baseline's order.
        assertEquals(
            listOf(
                "权限", "写之前", "模型服务", "MCP", "后台运行",
                "网页搜索", "网络访问", "插件与模型", "命令", "运行时详情", "发送消息时",
                "版本", "开源许可", "导出诊断",
            ),
            (state.sections[0].rows + state.sections[1].rows + state.sections[2].rows).map { it.title },
        )
        show()
        compose.onNodeWithTag(UiPageTags.SETTINGS_SECTION_PREFIX + SettingsScreenState.TOOLS_SECTION_ID)
            .assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SETTINGS_GROUP_TOOLS).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SETTINGS_SECTION_PREFIX + SettingsScreenState.ABOUT_SECTION_ID)
            .assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ABOUT).assertIsDisplayed()
        // The first group is untitled, so it has no header node at all.
        compose.onNodeWithTag(UiPageTags.SETTINGS_SECTION_PREFIX + SettingsScreenState.MAIN_SECTION_ID)
            .assertDoesNotExist()
        listOf(
            "权限", "写之前", "模型服务", "MCP", "后台运行",
            "网页搜索", "网络访问", "插件与模型", "命令", "运行时详情", "发送消息时",
            "版本", "开源许可", "导出诊断",
        )
            .forEach { compose.onNodeWithText(it).assertIsDisplayed() }
    }

    /**
     * A host that reported nothing still sees every row: the baseline's own
     * wording for "there is none" (未设置 / 未配置) and 未知 where the baseline has
     * no "none" branch. Nothing may become a plausible default.
     */
    @Test
    fun `an empty snapshot renders the baseline's unset wording, never a default`() {
        val state = SettingsScreenState.from(SettingsFacts())
        val rows = state.sections.flatMap { it.rows }.associateBy { it.id }
        assertEquals(UiStrings.SETTINGS_PERMISSION_UNSET, rows.getValue(SettingsScreenState.PERMISSION_ROW_ID).value)
        assertEquals(UiStrings.SETTINGS_PERMISSION_UNSET, rows.getValue(SettingsScreenState.ASK_ROW_ID).value)
        assertEquals(UiStrings.NOT_CONFIGURED, rows.getValue(SettingsScreenState.MODEL_ROW_ID).value)
        assertEquals(UiStrings.NOT_CONFIGURED, rows.getValue(SettingsScreenState.MCP_ROW_ID).value)
        assertEquals(UiStrings.UNKNOWN, rows.getValue(SettingsScreenState.NETWORK_ROW_ID).value)
        assertEquals(UiStrings.UNKNOWN, rows.getValue(SettingsScreenState.BUSY_ENTER_ROW_ID).value)
        assertEquals(UiStrings.UNKNOWN, rows.getValue(SettingsScreenState.VERSION_ROW_ID).value)
        assertEquals(UiStrings.SEARCH_SUMMARY_UNREADABLE, rows.getValue(SettingsScreenState.WEB_SEARCH_ROW_ID).value)
        // 权限 and 写之前 both say 未设置; 模型服务 and MCP both say 未配置.
        show()
        compose.onAllNodesWithText(UiStrings.SETTINGS_PERMISSION_UNSET).assertCountEquals(2)
        compose.onAllNodesWithText(UiStrings.NOT_CONFIGURED).assertCountEquals(2)
    }

    /** 权限 is the tier; 写之前 only reports whether that tier asks before writing. */
    @Test
    fun `the permission tier drives both permission rows`() {
        val cases = listOf(
            Triple(PermissionTier.VIEW_ONLY, UiStrings.PERMISSION_TIER_VIEW_ONLY, UiStrings.SETTINGS_ASK_EVERY_TIME),
            Triple(PermissionTier.WORKSPACE_WRITE, UiStrings.PERMISSION_TIER_WORKSPACE_WRITE, UiStrings.SETTINGS_ASK_EVERY_TIME),
            Triple(PermissionTier.FULL_ACCESS, UiStrings.PERMISSION_TIER_FULL_ACCESS, UiStrings.SETTINGS_ASK_NO_MORE),
        )
        cases.forEach { (tier, permission, ask) ->
            val state = SettingsScreenState.from(SettingsFacts(defaultPermissionTier = tier))
            val rows = state.sections.flatMap { it.rows }.associateBy { it.id }
            assertEquals(permission, rows.getValue(SettingsScreenState.PERMISSION_ROW_ID).value)
            assertEquals(ask, rows.getValue(SettingsScreenState.ASK_ROW_ID).value)
        }
        show(SettingsFacts(defaultPermissionTier = PermissionTier.FULL_ACCESS))
        compose.onNodeWithText(UiStrings.PERMISSION_TIER_FULL_ACCESS).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SETTINGS_ASK_NO_MORE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SETTINGS_ASK_EVERY_TIME).assertDoesNotExist()
    }

    /** Counts come from the host; the baseline collapses "none" and "unread" for MCP only. */
    @Test
    fun `counts come from the host and never from a fabricated zero`() {
        fun mcp(count: Int?): String? = SettingsScreenState.from(SettingsFacts(mcpServerCount = count))
            .sections.flatMap { it.rows }
            .single { it.id == SettingsScreenState.MCP_ROW_ID }
            .value

        assertEquals("3 个服务器", mcp(3))
        assertEquals(UiStrings.NOT_CONFIGURED, mcp(0))
        assertEquals(UiStrings.NOT_CONFIGURED, mcp(null))

        fun network(count: Int?): String? = SettingsScreenState.from(SettingsFacts(egressAddressCount = count))
            .sections.flatMap { it.rows }
            .single { it.id == SettingsScreenState.NETWORK_ROW_ID }
            .value

        assertEquals("4 个地址", network(4))
        assertEquals("0 个地址", network(0))
        // The baseline has no "unread" branch for the list; 未知 is this port's honest one.
        assertEquals(UiStrings.UNKNOWN, network(null))
        show(SettingsFacts(egressAddressCount = 4, mcpServerCount = 3))
        compose.onNodeWithText("4 个地址").assertIsDisplayed()
        compose.onNodeWithText("3 个服务器").assertIsDisplayed()
    }

    /**
     * 后台运行 is a measured position: an unread switch is 未知 and renders no
     * control, because a switch drawn "off" would state a position nobody read.
     */
    @Test
    fun `an unread background switch is 未知 and has no control`() {
        val unknown = SettingsScreenState.from(SettingsFacts(backgroundKeepAlive = FactState.UNKNOWN))
            .sections.flatMap { it.rows }
            .single { it.id == SettingsScreenState.BACKGROUND_ROW_ID }
        assertEquals(SettingsRowKind.VALUE, unknown.kind)
        assertEquals(UiStrings.UNKNOWN, unknown.value)

        val on = SettingsScreenState.from(SettingsFacts(backgroundKeepAlive = FactState.YES))
            .sections.flatMap { it.rows }
            .single { it.id == SettingsScreenState.BACKGROUND_ROW_ID }
        assertEquals(SettingsRowKind.TOGGLE, on.kind)
        assertTrue(on.checked)
        assertEquals(UiStrings.SETTINGS_BACKGROUND_ON, on.value)

        show(SettingsFacts(backgroundKeepAlive = FactState.UNKNOWN))
        // No switch node at all: the row says 未知 in words instead.
        compose.onNodeWithTag(UiPageTags.SETTINGS_ROW_TOGGLE).assertDoesNotExist()
    }

    /** The one footer line, with the baseline's precedence and its one condition. */
    @Test
    fun `the tools footer honours the baseline's precedence`() {
        fun footer(facts: SettingsFacts): String? =
            SettingsScreenState.from(facts).sections.single { it.id == SettingsScreenState.TOOLS_SECTION_ID }.footer

        assertEquals(
            "搜索会重启引擎",
            footer(SettingsFacts(searchLaunchWarning = "搜索会重启引擎")),
        )
        // A warning outranks both other branches.
        assertEquals(
            "搜索会重启引擎",
            footer(
                SettingsFacts(
                    searchLaunchWarning = "搜索会重启引擎",
                    engineStarted = FactState.YES,
                    networkConfigurationChanged = true,
                    didSave = true,
                ),
            ),
        )
        assertEquals(
            UiStrings.SETTINGS_FOOTER_RESTART,
            footer(SettingsFacts(engineStarted = FactState.YES, networkConfigurationChanged = true)),
        )
        // The baseline requires a running engine for the restart line.
        assertNull(footer(SettingsFacts(engineStarted = FactState.NO, networkConfigurationChanged = true)))
        assertNull(footer(SettingsFacts(engineStarted = FactState.UNKNOWN, networkConfigurationChanged = true)))
        assertEquals(UiStrings.SETTINGS_FOOTER_SAVED, footer(SettingsFacts(didSave = true)))
        assertNull(footer(SettingsFacts()))

        show(SettingsFacts(engineStarted = FactState.YES, networkConfigurationChanged = true))
        compose.onNodeWithTag(UiPageTags.SETTINGS_FOOTER_PREFIX + SettingsScreenState.TOOLS_SECTION_ID)
            .assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SETTINGS_FOOTER_RESTART).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SETTINGS_FOOTER_SAVED).assertDoesNotExist()
    }

    /** With no footer source the baseline renders no footer line at all. */
    @Test
    fun `a clean tools group renders no footer line`() {
        show(SettingsFacts())
        compose.onNodeWithTag(UiPageTags.SETTINGS_FOOTER_PREFIX + SettingsScreenState.TOOLS_SECTION_ID)
            .assertDoesNotExist()
        compose.onNodeWithText(UiStrings.SETTINGS_FOOTER_RESTART).assertDoesNotExist()
    }

    /** Every navigation row opens its destination; the plain rows open nothing. */
    @Test
    fun `every navigation row reports its destination`() {
        val opened = mutableListOf<SettingsDestination>()
        show(onNavigate = { opened += it })
        val expected = listOf(
            "权限" to SettingsDestination.PERMISSION_DEFAULTS,
            "模型服务" to SettingsDestination.MODEL_PROVIDER,
            "MCP" to SettingsDestination.MCP,
            "网页搜索" to SettingsDestination.WEB_SEARCH,
            "网络访问" to SettingsDestination.EGRESS,
            "插件与模型" to SettingsDestination.PLUGIN_CONFIGURATION,
            "命令" to SettingsDestination.COMMAND,
            "运行时详情" to SettingsDestination.RUNTIME_DETAILS,
            "导出诊断" to SettingsDestination.EXPORT_DIAGNOSTICS,
        )
        expected.forEach { (label, destination) ->
            compose.onNodeWithText(label).performClick()
            assertEquals("tapping $label", destination, opened.last())
        }
        assertEquals(expected.map { it.second }, opened)
        // 写之前 and 版本 are read-only rows: tapping them reports nothing.
        compose.onNodeWithText("写之前").assertHasNoClickAction()
        compose.onNodeWithText("版本").assertHasNoClickAction()
        assertEquals(expected.size, opened.size)
    }

    /**
     * 开源许可 has no Android page to open: the iOS list names SwiftTerm and
     * swift-nio, neither of which this app ships. The row explains that instead of
     * navigating nowhere.
     */
    @Test
    fun `the licenses row explains itself instead of navigating`() {
        val opened = mutableListOf<SettingsDestination>()
        show(onNavigate = { opened += it })
        scrollTo(UiStrings.ABOUT_LICENSES)
        compose.onNodeWithText(UiStrings.SETTINGS_LICENSES_ANDROID_ONLY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ABOUT_LICENSES).performClick()
        assertTrue(opened.isEmpty())
    }

    /** The switch reports the next position, not the current one. */
    @Test
    fun `the background row reports the flip`() {
        val flips = mutableListOf<Boolean>()
        show(SettingsFacts(backgroundKeepAlive = FactState.NO), onToggleBackground = { flips += it })
        compose.onNodeWithTag(UiPageTags.SETTINGS_ROW_TOGGLE).performClick()
        assertEquals(listOf(true), flips)
    }

    /** The menu carries the baseline's two modes and reports the pick. */
    @Test
    fun `the send-while-running menu reports the picked mode`() {
        val picked = mutableListOf<BusyEnterMode>()
        show(SettingsFacts(busyEnterMode = BusyEnterMode.QUEUE), onSelectMode = { picked += it })
        compose.onNodeWithText(UiStrings.SETTINGS_ROW_SEND).performClick()
        // The selected entry repeats the row's own value, so the count is two.
        compose.onAllNodesWithText(UiStrings.BUSY_ENTER_QUEUE).assertCountEquals(2)
        compose.onNodeWithText(UiStrings.BUSY_ENTER_STEER).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SETTINGS_ROW_OPTION_PREFIX + BusyEnterMode.STEER.id).performClick()
        assertEquals(listOf(BusyEnterMode.STEER), picked)
    }

    /**
     * The appendix keeps all three platform facts on every render: an unread
     * fact is 未知, and a denied one is inked as a degradation.
     */
    @Test
    fun `the platform appendix keeps its three facts`() {
        val unknown = SettingsScreenState.from(SettingsFacts())
            .sections.single { it.id == SettingsScreenState.PLATFORM_SECTION_ID }
        assertEquals(
            listOf(
                SettingsScreenState.NOTIFICATIONS_ROW_ID,
                SettingsScreenState.BATTERY_ROW_ID,
                SettingsScreenState.BACK_ROW_ID,
            ),
            unknown.rows.map { it.id },
        )
        assertEquals(List(3) { PageTone.UNKNOWN }, unknown.rows.map { it.tone })

        show(
            SettingsFacts(
                platform = SettingsPlatformFacts(
                    notifications = FactState.NO,
                    batteryExemption = FactState.YES,
                    predictiveBack = FactState.YES,
                ),
            ),
        )
        scrollTo(UiStrings.SETTINGS_NOTIFICATIONS)
        compose.onNodeWithText(UiStrings.SETTINGS_NOTIFICATIONS_DEGRADED).assertIsDisplayed()
        scrollTo(UiStrings.SETTINGS_BATTERY)
        compose.onNodeWithText(UiStrings.SETTINGS_BATTERY_EXEMPT).assertIsDisplayed()
        scrollTo(UiStrings.SETTINGS_BACK)
        compose.onNodeWithText(UiStrings.SETTINGS_BACK_PREDICTIVE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SETTINGS_NOTIFICATIONS_ON).assertDoesNotExist()
    }

    /** The baseline sheet's chrome action is 完成, not a back chevron. */
    @Test
    fun `the done action leaves the page`() {
        var backs = 0
        show(onBack = { backs += 1 })
        compose.onNodeWithTag(UiPageTags.SETTINGS_DONE).performClick()
        assertEquals(1, backs)
    }

    // -----------------------------------------------------------------------
    // 新会话默认权限: the 权限 row's inline sub-page
    // -----------------------------------------------------------------------

    private fun showPermissionDefaults(
        selected: PermissionTier? = null,
        onSelect: (PermissionTier) -> Unit = {},
        onBack: () -> Unit = {},
    ) {
        val state = PermissionDefaultsState.from(selected)
        compose.setContent {
            PdshTheme {
                PermissionDefaultsPage(state = state, onSelect = onSelect, onBack = onBack)
            }
        }
    }

    @Test
    fun `the permission sub-page keeps the baseline's note and three presets`() {
        val state = PermissionDefaultsState.from(null)
        assertEquals(UiStrings.PERMISSION_DEFAULTS_NOTE, state.note)
        assertEquals(
            listOf(
                UiStrings.PERMISSION_TIER_VIEW_ONLY,
                UiStrings.PERMISSION_TIER_WORKSPACE_WRITE,
                UiStrings.PERMISSION_TIER_FULL_ACCESS,
            ),
            state.options.map { it.title },
        )
        assertEquals(listOf(false, false, false), state.options.map { it.selected })
        showPermissionDefaults()
        compose.onNodeWithText(UiStrings.PERMISSION_DEFAULTS_TITLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.PERMISSION_DEFAULTS_NOTE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.PERMISSION_DEFAULTS_NOTE).assertIsDisplayed()
    }

    @Test
    fun `the current preset is marked and a tap reports the new one`() {
        val picked = mutableListOf<PermissionTier>()
        val state = PermissionDefaultsState.from(PermissionTier.FULL_ACCESS)
        assertEquals(listOf(false, false, true), state.options.map { it.selected })
        showPermissionDefaults(selected = PermissionTier.FULL_ACCESS, onSelect = { picked += it })
        // One checkmark, on 完全权限.
        compose.onAllNodesWithText("✓").assertCountEquals(1)
        compose.onNodeWithText(UiStrings.PERMISSION_TIER_VIEW_ONLY).performClick()
        assertEquals(listOf(PermissionTier.VIEW_ONLY), picked)
    }

    @Test
    fun `the permission sub-page's back affordance leaves it`() {
        var backs = 0
        showPermissionDefaults(onBack = { backs += 1 })
        compose.onNodeWithContentDescription(UiStrings.BACK).performClick()
        assertEquals(1, backs)
    }
}
