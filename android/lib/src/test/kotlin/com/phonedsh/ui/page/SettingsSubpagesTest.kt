// Compose interactions for settings-owned child pages.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertHeightIsEqualTo
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class SettingsSubpagesTest {
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

    private fun openSettings(
        facts: SettingsFacts,
        onSelectPreference: ((SettingsPreferenceChoice) -> Unit)? = null,
        onSelectBusy: ((BusyEnterMode) -> Unit)? = null,
        onToggleDeveloperTools: ((Boolean) -> Unit)? = null,
        onSelectFontFamily: ((String, String) -> Unit)? = null,
        licenseEntries: List<AndroidLicenseNotice>? = null,
        onSelectDefaultPermission: ((PermissionTier) -> Unit)? = null,
    ) {
        val hostFacts = if (onSelectDefaultPermission != null) facts.copy(
            defaultPermissionAvailableTiers = PermissionTier.entries.toSet(),
            defaultPermissionWritable = true,
        ) else facts
        compose.setContent {
            PdshTheme {
                SettingsPage(
                    state = SettingsScreenState.from(hostFacts),
                    onNavigate = {},
                    onToggleBackgroundKeepAlive = {},
                    onSelectBusyEnterMode = onSelectBusy ?: {},
                    onSelectPreference = onSelectPreference,
                    onSelectFontFamily = onSelectFontFamily,
                    onToggleDeveloperTools = onToggleDeveloperTools,
                    onSelectDefaultPermission = onSelectDefaultPermission,
                    licenseEntries = licenseEntries,
                    onBack = {},
                )
            }
        }
    }

    private fun scrollRoot(label: String) {
        compose.onNodeWithTag(com.phonedsh.ui.UiTags.SETTINGS_LIST).performScrollToNode(hasText(label))
    }

    @Test
    fun `font-size controls emit changes for all persisted roles and clamp at host ranges`() {
        val changes = mutableListOf<SettingsPreferenceChoice>()
        openSettings(
            facts = SettingsFacts(preferences = SettingsPreferences(
                fontSizeConversation = 17,
                fontSizeCode = 14,
                fontSizeTerminal = 13,
            )),
            onSelectPreference = { changes += it },
        )
        scrollRoot("字号")
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "fontSize").performClick()
        compose.onNodeWithTag("${SettingsScreenState.TEXT_FONT_SIZE_ROW_ID}.increase").performClick()
        compose.onNodeWithTag("${SettingsScreenState.CODE_FONT_SIZE_ROW_ID}.decrease").performClick()
        compose.onNodeWithTag("${SettingsScreenState.TERMINAL_FONT_SIZE_ROW_ID}.increase").performClick()
        assertEquals(
            listOf(
                SettingsPreferenceChoice(SettingsScreenState.TEXT_FONT_SIZE_ROW_ID, "18"),
                SettingsPreferenceChoice(SettingsScreenState.CODE_FONT_SIZE_ROW_ID, "13"),
                SettingsPreferenceChoice(SettingsScreenState.TERMINAL_FONT_SIZE_ROW_ID, "14"),
            ),
            changes,
        )
        compose.onNodeWithTag("${SettingsScreenState.TEXT_FONT_SIZE_ROW_ID}.fontFamily").assertIsDisplayed()
        compose.onNodeWithTag(SettingsScreenState.TEXT_FONT_SIZE_ROW_ID)
            .assertHeightIsEqualTo(com.phonedsh.ui.HomeMetrics.DEFAULT_MIN_LIST_ROW_HEIGHT_PT.dp)
        compose.onNodeWithTag("${SettingsScreenState.TEXT_FONT_SIZE_ROW_ID}.stepper.pill")
            .assertWidthIsEqualTo(com.phonedsh.ui.SettingsMetrics.FONT_STEPPER_WIDTH_PT.dp)
            .assertHeightIsEqualTo(com.phonedsh.ui.SettingsMetrics.FONT_STEPPER_HEIGHT_PT.dp)
        compose.onNodeWithTag("${SettingsScreenState.TEXT_FONT_SIZE_ROW_ID}.decrease")
            .assertWidthIsEqualTo(com.phonedsh.ui.SettingsMetrics.FONT_STEPPER_WIDTH_PT.dp / 2f)
            .assertHeightIsEqualTo(com.phonedsh.ui.HomeMetrics.DEFAULT_MIN_LIST_ROW_HEIGHT_PT.dp)
        compose.onNodeWithTag("${SettingsScreenState.TEXT_FONT_SIZE_ROW_ID}.increase")
            .assertWidthIsEqualTo(com.phonedsh.ui.SettingsMetrics.FONT_STEPPER_WIDTH_PT.dp / 2f)
            .assertHeightIsEqualTo(com.phonedsh.ui.HomeMetrics.DEFAULT_MIN_LIST_ROW_HEIGHT_PT.dp)
    }

    @Test
    fun `font size remains unavailable when host has not reported stored values`() {
        openSettings(facts = SettingsFacts())
        scrollRoot("字号")
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "fontSize").performClick()
        compose.onNodeWithText("会话内容").assertIsDisplayed()
        compose.onNodeWithTag(SettingsScreenState.TEXT_FONT_SIZE_ROW_ID).assertIsDisplayed()
        compose.onNodeWithTag("${SettingsScreenState.TEXT_FONT_SIZE_ROW_ID}.fontFamily").assertTextContains(UiStrings.UNAVAILABLE)
        compose.onNodeWithTag("${SettingsScreenState.TEXT_FONT_SIZE_ROW_ID}.fontFamily.input").assertTextContains("字体（留空使用系统默认）")
        compose.onNodeWithTag("${SettingsScreenState.TEXT_FONT_SIZE_ROW_ID}.increase").assertDoesNotExist()
    }

    @Test
    fun `font family field edits only when host reports a value and writer`() {
        val writes = mutableListOf<Pair<String, String>>()
        openSettings(
            facts = SettingsFacts(preferences = SettingsPreferences(fontFamilyConversation = "IBM Plex Mono")),
            onSelectFontFamily = { rowId, family -> writes += rowId to family },
        )
        scrollRoot("字号")
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "fontSize").performClick()
        val field = compose.onNodeWithTag("${SettingsScreenState.TEXT_FONT_SIZE_ROW_ID}.fontFamily.input")
        field.performTextClearance()
        field.performTextInput("Fira Code")
        assertEquals(
            listOf(
                SettingsScreenState.TEXT_FONT_SIZE_ROW_ID to "",
                SettingsScreenState.TEXT_FONT_SIZE_ROW_ID to "Fira Code",
            ),
            writes,
        )
    }

    @Test
    fun `conversation page writes process pickers and busy-send mode`() {
        val changes = mutableListOf<SettingsPreferenceChoice>()
        val busy = mutableListOf<BusyEnterMode>()
        val devTools = mutableListOf<Boolean>()
        openSettings(
            facts = SettingsFacts(
                busyEnterMode = BusyEnterMode.QUEUE,
                preferences = SettingsPreferences(
                    transcriptView = TranscriptViewMode.STANDARD,
                    collapseTiming = CollapseTiming.COMPLETION,
                    developerTools = FactState.YES,
                    performanceUsage = PerformanceUsage.COMPACT,
                ),
            ),
            onSelectPreference = { changes += it },
            onSelectBusy = { busy += it },
            onToggleDeveloperTools = { devTools += it },
        )
        scrollRoot("工作过程")
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "workDetails").performClick()
        compose.onNodeWithTag(SettingsScreenState.DEVELOPER_TOOLS_ROW_ID).performClick()
        compose.onNodeWithTag(SettingsScreenState.TRANSCRIPT_VIEW_ROW_ID).performClick()
        compose.onNodeWithTag("${SettingsScreenState.TRANSCRIPT_VIEW_ROW_ID}.option.verbose").performClick()
        compose.onNodeWithTag(SettingsScreenState.COLLAPSE_TIMING_ROW_ID).performClick()
        compose.onNodeWithTag("${SettingsScreenState.COLLAPSE_TIMING_ROW_ID}.option.nextInput").performClick()
        compose.onNodeWithTag(SettingsScreenState.BUSY_ENTER_ROW_ID).performClick()
        compose.onNodeWithTag("${SettingsScreenState.BUSY_ENTER_ROW_ID}.option.steer").performClick()
        compose.onNodeWithTag(SettingsScreenState.PERFORMANCE_ROW_ID).performClick()
        compose.onNodeWithTag("${SettingsScreenState.PERFORMANCE_ROW_ID}.option.detailed").performClick()
        assertEquals(
            listOf(
                SettingsPreferenceChoice(SettingsScreenState.TRANSCRIPT_VIEW_ROW_ID, "verbose"),
                SettingsPreferenceChoice(SettingsScreenState.COLLAPSE_TIMING_ROW_ID, "nextInput"),
                SettingsPreferenceChoice(SettingsScreenState.PERFORMANCE_ROW_ID, "detailed"),
            ),
            changes,
        )
        assertEquals(listOf(BusyEnterMode.STEER), busy)
        assertEquals(listOf(false), devTools)
    }

    @Test
    fun `permission defaults preserve selected state and use explicit writer`() {
        val picked = mutableListOf<PermissionTier>()
        openSettings(
            facts = SettingsFacts(defaultPermissionTier = PermissionTier.VIEW_ONLY),
            onSelectDefaultPermission = { picked += it },
        )
        scrollRoot("新会话默认权限")
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "permissionDefaults").performClick()
        compose.onNodeWithContentDescription("已选择").assertIsDisplayed()
        compose.onNodeWithTag(PERMISSION_DEFAULTS_OPTION_PREFIX + PermissionTier.WORKSPACE_WRITE.name).performClick()
        assertEquals(listOf(PermissionTier.WORKSPACE_WRITE), picked)
        compose.onNodeWithTag(PERMISSION_DEFAULTS_NOTE_TAG).assertIsDisplayed()
    }

    @Test
    fun `licenses remain unavailable without a host catalog and exclude iOS dependencies`() {
        openSettings(facts = SettingsFacts())
        scrollRoot("开源许可")
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "licenses").performClick()
        compose.onNodeWithText(UiStrings.UNAVAILABLE).assertIsDisplayed()
        compose.onNodeWithText("许可信息暂不可用。", substring = true).assertIsDisplayed()
        compose.onNodeWithText("SwiftTerm").assertDoesNotExist()
        compose.onNodeWithText("swift-nio").assertDoesNotExist()
    }
    @Test
    fun `host supplied license notices are rendered without rewriting their legal text`() {
        openSettings(
            facts = SettingsFacts(),
            licenseEntries = listOf(AndroidLicenseNotice("Test Runtime", "Test License", "Host-provided legal notice.")),
        )
        scrollRoot("开源许可")
        compose.onNodeWithTag(com.phonedsh.ui.page.UiPageTags.SETTINGS_INDEX_ROW_PREFIX + "licenses").performClick()
        compose.onNodeWithText("Test Runtime").assertIsDisplayed()
        compose.onNodeWithText("Test License").assertIsDisplayed()
        compose.onNodeWithText("Host-provided legal notice.").assertIsDisplayed()
    }
}
