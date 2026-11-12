// PR22 grouped settings index interactions.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.test.assertHasNoClickAction
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.disclosure.PdshDisclosureTags
import com.phonedsh.ui.state.EngineLifecycleFacts
import com.phonedsh.ui.state.EngineLifecycleStatus
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class SettingsPageTest {
    @get:Rule val compose = createComposeRule()

    private lateinit var originalLocale: java.util.Locale

    @Before
    fun useChineseSystemLocaleForNativeCopy() {
        originalLocale = java.util.Locale.getDefault()
        java.util.Locale.setDefault(java.util.Locale.SIMPLIFIED_CHINESE)
    }

    @After
    fun restoreSystemLocale() {
        java.util.Locale.setDefault(originalLocale)
    }

    private fun show(
        facts: SettingsFacts = SettingsFacts(preferences = SettingsPreferences(language = SettingsLanguage.ZH)),
        onNavigate: (SettingsDestination) -> Unit = {},
        onSelectPreference: ((SettingsPreferenceChoice) -> Unit)? = null,
        onRestartEngine: (() -> Unit)? = null,
        onBack: () -> Unit = {},
        onSelectDefaultPermission: ((PermissionTier) -> Unit)? = null,
        onSelectFontFamily: ((String, String) -> Unit)? = null,
        onToggleBackgroundKeepAlive: (Boolean) -> Unit = {},
        licenseEntries: List<AndroidLicenseNotice>? = null,
        onOpenAgentPresets: (() -> Unit)? = null,
        onOpenPhonePermissions: (() -> Unit)? = null,
        onOpenPluginsTools: (() -> Unit)? = null,
        onOpenFolders: (() -> Unit)? = null,
        onOpenArchivedSessions: (() -> Unit)? = null,
        tab: SettingsTab = SettingsTab.GENERAL,
        tabContent: (@Composable (SettingsTab) -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                SettingsPage(
                    state = SettingsScreenState.from(facts),
                    onNavigate = onNavigate,
                    onToggleBackgroundKeepAlive = onToggleBackgroundKeepAlive,
                    onSelectBusyEnterMode = {},
                    onBack = onBack,
                    onSelectPreference = onSelectPreference,
                    onSelectFontFamily = onSelectFontFamily,
                    onSelectDefaultPermission = onSelectDefaultPermission,
                    onRestartEngine = onRestartEngine,
                    onOpenAgentPresets = onOpenAgentPresets,
                    onOpenPhonePermissions = onOpenPhonePermissions,
                    onOpenPluginsTools = onOpenPluginsTools,
                    onOpenFolders = onOpenFolders,
                    onOpenArchivedSessions = onOpenArchivedSessions,
                    licenseEntries = licenseEntries,
                    tab = tab,
                    tabContent = tabContent,
                )
            }
        }
    }

    private fun scrollTo(label: String) {
        compose.onNodeWithTag(com.phonedsh.ui.UiTags.SETTINGS_LIST).performScrollToNode(hasText(label))
    }

    private fun scrollToTag(tag: String) {
        compose.onNodeWithTag(com.phonedsh.ui.UiTags.SETTINGS_LIST).performScrollToNode(androidx.compose.ui.test.hasTestTag(tag))
    }

    @Test
    fun `index has PR22 section inventory and no segmented tab shell`() {
        show()
        listOf("模型与智能体", "权限与隐私", "对话", "会话与文件", "引擎", "关于", "平台差异").forEach {
            scrollTo(it)
            compose.onNodeWithText(it).assertIsDisplayed()
        }
        listOf("模型服务", "Agent 预设", "插件与工具", "新会话默认权限", "手机权限", "网络访问", "MCP 与局域网设备",
            "外观", "语言", "字号", "工作过程", "快捷键", "文件夹", "已归档会话", "引擎状态",
            "运行状态", "关于 Phone DSH", "版本", UiStrings.ABOUT_LICENSES,
            UiStrings.SETTINGS_ROW_BACKGROUND, UiStrings.SETTINGS_ROW_EXPORT,
            UiStrings.SETTINGS_NOTIFICATIONS, UiStrings.SETTINGS_BATTERY, UiStrings.SETTINGS_BACK).forEach {
            scrollTo(it)
            compose.onNodeWithText(it).assertIsDisplayed()
        }
        compose.onNodeWithText("通用").assertDoesNotExist()
        scrollTo("手机权限")
        compose.onNodeWithText("手机权限").assertIsDisplayed()
    }

    @Test
    fun `saved English language selects the matching NativeText Settings copy`() {
        show(facts = SettingsFacts(
            preferences = SettingsPreferences(language = SettingsLanguage.EN),
        ))
        scrollTo(UiStrings.SETTINGS_SECTION_MODELS_AGENTS_EN)
        compose.onNodeWithText(UiStrings.SETTINGS_SECTION_MODELS_AGENTS_EN).assertIsDisplayed()
        scrollTo(UiStrings.SETTINGS_ROW_WORK_DETAILS_EN)
        compose.onNodeWithText(UiStrings.SETTINGS_ROW_WORK_DETAILS_EN).assertIsDisplayed()
        scrollTo(UiStrings.SETTINGS_ROW_ARCHIVED_SESSIONS_EN)
        compose.onNodeWithText(UiStrings.SETTINGS_ROW_ARCHIVED_SESSIONS_EN).assertIsDisplayed()
    }

    @Test
    fun `unreported preferences remain unset instead of selecting the first option`() {
        val state = SettingsScreenState.from(SettingsFacts())
        assertEquals(null, state.preferences.language)
        assertEquals(null, state.preferences.appearance)
        assertEquals(UiStrings.SETTINGS_PERMISSION_UNSET, state.row(SettingsScreenState.LANGUAGE_ROW_ID)?.value)
        assertEquals(UiStrings.SETTINGS_PERMISSION_UNSET, state.row(SettingsScreenState.APPEARANCE_ROW_ID)?.value)
        show(facts = SettingsFacts(), onSelectPreference = {})
        scrollTo("语言")
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "language")
            .assertTextContains(UiStrings.SETTINGS_PERMISSION_UNSET)
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "language").performClick()
        scrollToTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "language.option.system")
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "language.option.system").assertIsDisplayed()
        compose.onNodeWithContentDescription("已选择").assertDoesNotExist()
    }

    @Test
    fun `menu body expands through the shared disclosure and closes before writing`() {
        val writes = mutableListOf<SettingsPreferenceChoice>()
        show(
            facts = SettingsFacts(preferences = SettingsPreferences(
                appearance = SettingsAppearance.SYSTEM,
                language = SettingsLanguage.SYSTEM,
            )),
            onSelectPreference = { writes += it },
        )
        val rowTag = com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "appearance"
        val disclosureTag = rowTag + ".disclosure"
        scrollTo("外观")
        compose.onNodeWithTag(PdshDisclosureTags.body(disclosureTag)).assertDoesNotExist()
        compose.onNodeWithTag(rowTag).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag(PdshDisclosureTags.body(disclosureTag)).assertExists()
        val optionTag = com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "appearance.option.dark"
        scrollToTag(optionTag)
        compose.onNodeWithTag(optionTag).assertIsDisplayed()
        compose.onNodeWithTag(optionTag).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag(PdshDisclosureTags.body(disclosureTag)).assertDoesNotExist()
        assertEquals(
            listOf(SettingsPreferenceChoice(SettingsScreenState.APPEARANCE_ROW_ID, "dark")),
            writes,
        )
    }

    @Test
    fun `menu pickers write selected appearance and language values`() {
        val writes = mutableListOf<SettingsPreferenceChoice>()
        show(
            facts = SettingsFacts(preferences = SettingsPreferences(
                appearance = SettingsAppearance.SYSTEM,
                language = SettingsLanguage.SYSTEM,
            )),
            onSelectPreference = { writes += it },
        )
        scrollTo("外观")
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "appearance").performClick()
        // Scroll to the option itself: a row added above (蓝牙设备) can leave it below the fold.
        scrollToTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "appearance.option.dark")
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "appearance.option.dark").performClick()
        scrollTo("语言")
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "language").performClick()
        scrollToTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "language.option.en")
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "language.option.en").assertIsDisplayed()
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "language.option.en").performClick()
        assertEquals(
            listOf(
                SettingsPreferenceChoice(SettingsScreenState.APPEARANCE_ROW_ID, "dark"),
                SettingsPreferenceChoice(SettingsScreenState.LANGUAGE_ROW_ID, "en"),
            ),
            writes,
        )
    }

    @Test
    fun `host counts and permission summary are shown as supplied`() {
        show(
            facts = SettingsFacts(
                providerSetupRequired = true,
                folderCount = 3,
                archivedSessionCount = 2,
                phonePermissionSummary = "2 / 4 已允许",
                versionName = "0.1.0",
            ),
            onOpenPhonePermissions = {},
            onOpenFolders = {},
            onOpenArchivedSessions = {},
        )
        scrollTo("模型服务")
        compose.onNodeWithText("需要设置").assertIsDisplayed()
        scrollTo("2 / 4 已允许")
        compose.onNodeWithText("2 / 4 已允许").assertIsDisplayed()
        scrollTo("文件夹")
        compose.onNodeWithText("3", substring = false).assertIsDisplayed()
        scrollTo("已归档会话")
        compose.onNodeWithText("2", substring = false).assertIsDisplayed()
        scrollTo("版本")
        compose.onNodeWithText("0.1.0").assertIsDisplayed()
    }

    @Test
    // Legacy Robolectric text measures one dp per glyph; native metrics reproduce the device's value width.
    @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun `a long permission summary stays within half the row and leaves the title visible`() {
        val summary = "1 of 9 measured permissions available"
        show(
            facts = SettingsFacts(
                preferences = SettingsPreferences(language = SettingsLanguage.EN),
                phonePermissionSummary = summary,
            ),
            onOpenPhonePermissions = {},
        )
        scrollTo("Phone permissions")
        val rowTag = com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "phonePermissions"
        val row = compose.onNodeWithTag(rowTag, useUnmergedTree = true).getUnclippedBoundsInRoot()
        val value = compose.onNodeWithTag(
            com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_VALUE_PREFIX + "phonePermissions",
            useUnmergedTree = true,
        ).getUnclippedBoundsInRoot()
        val title = compose.onNodeWithText("Phone permissions", useUnmergedTree = true).getUnclippedBoundsInRoot()
        val rowWidth = row.right - row.left
        val rowHeight = row.bottom - row.top
        val valueWidth = value.right - value.left
        val titleWidth = title.right - title.left
        compose.onNodeWithTag(rowTag).assertTextContains(summary)
        compose.onNodeWithTag(rowTag).assertTextContains("Phone permissions")
        assertTrue(
            "trailing value $valueWidth must stay within half the $rowWidth row",
            valueWidth <= rowWidth * 0.5f + 1.dp,
        )
        assertTrue("title width $titleWidth collapsed", titleWidth >= 48.dp)
        assertTrue("row height $rowHeight is the unbounded-value blank row", rowHeight <= 96.dp)
    }

    @Test
    fun `engine restart is visible only when host reports it is required`() {
        show()
        scrollTo("引擎状态")
        compose.onNodeWithText("重新启动引擎").assertDoesNotExist()
    }

    @Test
    fun `required engine restart invokes the host and explains no auto-retry`() {
        var restartCount = 0
        show(
            facts = SettingsFacts(engineLifecycle = EngineLifecycleFacts(
                status = EngineLifecycleStatus.FAILED,
                statusLabel = "failed",
                needsReset = true,
            )),
            onRestartEngine = { restartCount += 1 },
        )
        scrollTo("重新启动引擎")
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "engineRestart").performClick()
        compose.onNodeWithText(UiStrings.SETTINGS_ENGINE_RESET_FOOTER).assertIsDisplayed()
        assertEquals(1, restartCount)
    }

    @Test
    fun `deep entry still renders the requested tab page`() {
        show(tab = SettingsTab.PRESETS, tabContent = { BasicText("preset-page") })
        compose.onNodeWithText("preset-page").assertIsDisplayed()
        compose.onNodeWithText("模型与智能体").assertDoesNotExist()
    }

    @Test
    fun `unwired host destinations and unknown Android facts are unavailable`() {
        show()
        scrollTo("不可用")
        val agentPresetsRow = com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "agentPresets"
        compose.onNodeWithTag(agentPresetsRow).assertIsDisplayed()
        compose.onNodeWithTag(agentPresetsRow).assertHasNoClickAction()
        scrollTo("文件夹")
        val foldersRow = com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "folders"
        compose.onNodeWithTag(foldersRow).assertHasNoClickAction()
        scrollTo(UiStrings.SETTINGS_ROW_BACKGROUND)
        val backgroundRow = com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "platform.backgroundKeepAlive"
        compose.onNodeWithTag(backgroundRow).assertHasNoClickAction()
        compose.onNodeWithTag(backgroundRow).assertTextContains(UiStrings.UNKNOWN)
    }

    @Test
    fun `background switch and platform facts dispatch real actions and preserve warning precedence`() {
        val backgroundWrites = mutableListOf<Boolean>()
        val navigated = mutableListOf<SettingsDestination>()
        show(
            facts = SettingsFacts(
                backgroundKeepAlive = FactState.YES,
                engineStarted = FactState.YES,
                networkConfigurationChanged = true,
                didSave = true,
                searchLaunchWarning = "provider warning",
                platform = SettingsPlatformFacts(
                    notifications = FactState.NO,
                    batteryExemption = FactState.YES,
                    predictiveBack = FactState.YES,
                ),
            ),
            onNavigate = { navigated += it },
            onToggleBackgroundKeepAlive = { backgroundWrites += it },
        )
        scrollTo("平台差异")
        scrollToTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "platform.backgroundKeepAlive")
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "platform.backgroundKeepAlive")
            .performClick()
        assertEquals(listOf(false), backgroundWrites)
        scrollTo(UiStrings.SETTINGS_NOTIFICATIONS)
        compose.onNodeWithText(UiStrings.SETTINGS_NOTIFICATIONS_DEGRADED).assertIsDisplayed()
        scrollTo("provider warning")
        compose.onNodeWithText("provider warning").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SETTINGS_FOOTER_RESTART).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.SETTINGS_FOOTER_SAVED).assertDoesNotExist()
        scrollTo(UiStrings.SETTINGS_ROW_EXPORT)
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "platform.exportDiagnostics").performClick()
        assertEquals(listOf(SettingsDestination.EXPORT_DIAGNOSTICS), navigated)
    }

    @Test
    fun `engine restart notice outranks saved notice when no warning exists`() {
        show(facts = SettingsFacts(
            engineStarted = FactState.YES,
            networkConfigurationChanged = true,
            didSave = true,
        ))
        scrollTo(UiStrings.SETTINGS_FOOTER_RESTART)
        compose.onNodeWithText(UiStrings.SETTINGS_FOOTER_RESTART).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SETTINGS_FOOTER_SAVED).assertDoesNotExist()
    }

    @Test
    fun `saved status is shown only when warning and restart notice are absent`() {
        show(facts = SettingsFacts(didSave = true))
        scrollTo(UiStrings.SETTINGS_FOOTER_SAVED)
        compose.onNodeWithText(UiStrings.SETTINGS_FOOTER_SAVED).assertIsDisplayed()
    }

    @Test
    fun `done and child back actions remain reachable`() {
        var done = 0
        show(onBack = { done += 1 })
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_DONE).performClick()
        assertEquals(1, done)
        scrollTo("字号")
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "fontSize").performClick()
        compose.onNodeWithTag("pdsh.settings.index.back").performClick()
        // Back returns to the index, which keeps its scroll position (as the
        // baseline's NavigationStack does); the first header may be above the
        // viewport once the list grows, so scroll to it instead of assuming it.
        scrollTo("模型与智能体")
        compose.onNodeWithText("模型与智能体").assertIsDisplayed()
    }
}
