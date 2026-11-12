// PR #60 parity: the 我的 tab, the pushed 设置 page and the 发现 tab.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.activity.OnBackPressedDispatcherOwner
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.sheet.PdshSheetTags
import com.phonedsh.ui.sheet.SheetDetents
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.generated.TokenDetent
import com.phonedsh.ui.theme.generated.TokenDetentSetId
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class SettingsModesAndConnectorsTest {
    @get:Rule val compose = createComposeRule()

    private val zh = SettingsFacts(preferences = SettingsPreferences(language = SettingsLanguage.ZH))

    private fun showSettings(
        mode: SettingsPageMode,
        onNavigate: (SettingsDestination) -> Unit = {},
        onBack: () -> Unit = {},
        scheduleCount: Int? = null,
        tonoAccount: TonoAccountFacts? = null,
    ) {
        compose.setContent {
            PdshTheme {
                SettingsPage(
                    state = SettingsScreenState.from(zh).copy(scheduleCount = scheduleCount, tonoAccount = tonoAccount),
                    onNavigate = onNavigate,
                    onToggleBackgroundKeepAlive = {},
                    onSelectBusyEnterMode = {},
                    onBack = onBack,
                    onOpenPhonePermissions = {},
                    onOpenArchivedSessions = {},
                    mode = mode,
                )
            }
        }
    }

    private fun row(id: String) = UiPageTags.SETTINGS_INDEX_ROW_PREFIX + id

    private fun scrollTo(tag: String) {
        compose.onNodeWithTag(com.phonedsh.ui.UiTags.SETTINGS_LIST).performScrollToNode(hasTestTag(tag))
    }

    @Test
    fun `the me tab draws the profile, schedules, devices and settings rows without done`() {
        val opened = mutableListOf<SettingsDestination>()
        showSettings(SettingsPageMode.TAB, onNavigate = { opened += it }, scheduleCount = 3)

        compose.onNodeWithText("我的").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SETTINGS_DONE).assertDoesNotExist()
        compose.onNodeWithTag(row("me.profile")).performClick()
        compose.onNodeWithTag(row("me.schedules")).performClick()
        compose.onNodeWithText("3").assertIsDisplayed()
        compose.onNodeWithTag(row("me.devices")).performClick()
        scrollTo(row("me.settings"))
        compose.onNodeWithTag(row("me.settings")).performClick()
        assertEquals(
            listOf(
                SettingsDestination.RUNTIME_DETAILS,
                SettingsDestination.SCHEDULES,
                SettingsDestination.BLUETOOTH,
                SettingsDestination.MORE_SETTINGS,
            ),
            opened,
        )
        // The six titled groups belong to the sheet and the pushed 设置 page.
        compose.onNodeWithTag(UiPageTags.SETTINGS_INDEX_GROUP_PREFIX + "modelsAgents").assertDoesNotExist()
    }

    @Test
    fun `the me tab opens the account and says whether it is signed in`() {
        val opened = mutableListOf<SettingsDestination>()
        showSettings(SettingsPageMode.TAB, onNavigate = { opened += it }, tonoAccount = TonoAccountFacts(available = true))

        compose.onNodeWithText("未登录 · 点此登录").assertIsDisplayed()
        compose.onNodeWithTag(row("me.tonoAccount")).performClick()
        assertEquals(listOf(SettingsDestination.TONO_ACCOUNT), opened)
    }

    @Test
    fun `the me tab shows the signed-in phone tail`() {
        showSettings(SettingsPageMode.TAB, tonoAccount = TonoAccountFacts(available = true, signedIn = true, phoneHint = "1234"))

        compose.onNodeWithText("尾号 1234").assertIsDisplayed()
    }

    @Test
    fun `the pushed settings page has a back and leaves out the tab's rows`() {
        var backs = 0
        showSettings(SettingsPageMode.MORE, onBack = { backs += 1 })

        compose.onNodeWithText("设置").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SETTINGS_DONE).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.SETTINGS_MORE_BACK).performClick()
        assertEquals(1, backs)
        compose.onNodeWithTag(row("agentPresets")).assertIsDisplayed()
        compose.onNodeWithTag(row("modelProvider")).assertDoesNotExist()
        compose.onNodeWithTag(row("phonePermissions")).assertDoesNotExist()
        compose.onNodeWithTag(row("me.profile")).assertDoesNotExist()
    }

    @Test
    fun `the sheet keeps done and the full list`() {
        var backs = 0
        showSettings(SettingsPageMode.SHEET, onBack = { backs += 1 })

        compose.onNodeWithTag(UiPageTags.SETTINGS_DONE).performClick()
        assertEquals(1, backs)
        compose.onNodeWithTag(row("modelProvider")).assertIsDisplayed()
        compose.onNodeWithTag(row("me.profile")).assertDoesNotExist()
    }

    @Test
    fun `discover lists the connectors and pushes a setup page only after its sheet closes`() {
        val opened = mutableListOf<DiscoverConnector>()
        var plugins = 0
        compose.setContent {
            PdshTheme {
                ConnectorsPage(
                    onOpen = { opened += it },
                    onOpenPluginsTools = { plugins += 1 },
                    languageId = "zh",
                )
            }
        }
        compose.onNodeWithText("发现").assertIsDisplayed()
        compose.onNodeWithText("连接器").assertIsDisplayed()
        compose.onNodeWithText("更多").assertIsDisplayed()
        compose.onNodeWithTag(ConnectorsPageTags.PLUGINS_TOOLS).performClick()
        assertEquals(1, plugins)

        compose.onNodeWithTag(ConnectorsPageTags.ROW_PREFIX + "web_search").performClick()
        compose.onNodeWithText("设置网页搜索").assertIsDisplayed()
        assertEquals(emptyList<DiscoverConnector>(), opened)
        // The sheet is its own window; Robolectric does not route injected touches
        // into it, so the button is driven by its click action, as the daily-brief
        // sheet test does (`DailyBriefPageTest.kt:217`).
        compose.onNodeWithTag(ConnectorsPageTags.SHEET_ACTION)
            .performSemanticsAction(SemanticsActions.OnClick)
        // The push waits for the sheet's hide animation, which runs on the test clock.
        compose.waitUntil(timeoutMillis = 5_000) { opened.isNotEmpty() }
        assertEquals(listOf(DiscoverConnector.WEB_SEARCH), opened)
        compose.onNodeWithTag(ConnectorsPageTags.SHEET).assertDoesNotExist()
    }

    @Test
    fun `connector sheet uses the frozen chrome and detents and closes on system back`() {
        // The page id, not a local skipPartiallyExpanded choice: connectors is
        // the frozen medium+large site with the connector chrome. Scrim tap and
        // drag-down stay device-only (Robolectric does not route touches into the
        // sheet's own window).
        assertEquals(TokenDetentSetId.MEDIUM_LARGE, SheetDetents.forPage("connectors"))
        assertEquals(
            listOf(TokenDetent.MEDIUM, TokenDetent.LARGE),
            SheetDetents.detents(SheetDetents.forPage("connectors")),
        )

        compose.setContent {
            PdshTheme {
                ConnectorsPage(onOpen = {}, onOpenPluginsTools = {}, languageId = "zh")
            }
        }
        compose.onNodeWithTag(ConnectorsPageTags.ROW_PREFIX + "web_search").performClick()
        compose.onNodeWithTag(ConnectorsPageTags.SHEET).assertIsDisplayed()
        // SheetChrome.Connectors is the one preset with a visible grabber.
        compose.onNodeWithTag(PdshSheetTags.DRAG_HANDLE, useUnmergedTree = true).assertExists()

        pressBackAndSettle()

        compose.onNodeWithTag(ConnectorsPageTags.SHEET).assertDoesNotExist()
    }

    @Test
    fun `the example connector cannot connect`() {
        val opened = mutableListOf<DiscoverConnector>()
        compose.setContent {
            PdshTheme {
                ConnectorsPage(onOpen = { opened += it }, onOpenPluginsTools = {}, languageId = "zh")
            }
        }
        compose.onNodeWithTag(ConnectorsPageTags.ROW_PREFIX + "gmail").performClick()
        compose.onNodeWithText("即将支持").assertIsDisplayed()
        compose.onNodeWithTag(ConnectorsPageTags.SHEET_ACTION).assertIsNotEnabled()
        assertEquals(emptyList<DiscoverConnector>(), opened)
    }

    /**
     * Robolectric models the sheet as its own dialog; dispatch on that dialog's
     * owner exactly as the platform window would, then let the hide animation
     * finish on the test clock.
     */
    private fun pressBackAndSettle() {
        val dialog = ShadowDialog.getLatestDialog()
        (dialog as OnBackPressedDispatcherOwner).onBackPressedDispatcher.onBackPressed()
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
    }
}
