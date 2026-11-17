// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.screenshot.ScreenshotActivity
import com.phonedsh.ui.theme.PdshTheme
import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WebSearchAddressLifecycleDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<ScreenshotActivity>()

    @Test fun leavingAfterSwitchingModesCommitsTheCurrentNoKeyDraft() {
        val writes = mutableListOf<String>()
        var showing by mutableStateOf(true)
        var facts by mutableStateOf(WebSearchFacts(mode = WebSearchMode.FOLLOW_MODEL,
            hasCredential = FactState.NO, writable = FactState.YES))
        compose.setContent {
            SearchFixtureTheme("") {
                if (showing) WebSearchSettingsPage(state = WebSearchScreenState.from(facts), onToggle = {},
                    onSelectBackend = {}, onToggleBackends = {}, onBack = { showing = false },
                    onModeChange = { facts = facts.copy(mode = it) }, onCommitAddress = { writes += it })
            }
        }
        compose.onNodeWithText(UiStrings.WEB_SEARCH_MODE_API).performClick()
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_ADDRESS_FIELD).performTextInput("example.invalid")
        compose.onNodeWithContentDescription(UiStrings.BACK).performClick()
        compose.waitForIdle()
        assertTrue("leaving must commit the complete current draft", writes.contains("https://example.invalid"))
    }

    @Test fun oldHostWithoutAddressProjectionFailsClosed() {
        val fixture = JSONObject(InstrumentationRegistry.getInstrumentation().context.assets
            .open("web-search-address-lifecycle.json").bufferedReader().use { it.readText() })
        val cases = fixture.getJSONArray("aarCompatibility")
        val legacy = (0 until cases.length()).map { cases.getJSONObject(it) }.single { it.getString("id") == "old-client-no-provider" }
        assertFalse(legacy.getBoolean("addressEnabled"))
        assertFalse(legacy.getBoolean("keyEnabled"))
        val facts = WebSearchFacts(mode = WebSearchMode.SEARCH_API, hasCredential = FactState.YES, writable = FactState.YES)
        compose.setContent {
            PdshTheme {
                WebSearchSettingsPage(state = WebSearchScreenState.from(facts), onToggle = {}, onSelectBackend = {},
                    onToggleBackends = {}, onBack = {}, onModeChange = {}, onCommitAddress = {}, onCommitKey = {})
            }
        }
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_ADDRESS_FIELD).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_LIST).performScrollToNode(hasTestTag(UiPageTags.WEB_SEARCH_KEY_FIELD))
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_KEY_FIELD).assertIsNotEnabled()
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_LIST).performScrollToNode(hasText(UiStrings.WEB_SEARCH_SAVE_KEY))
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SAVE_KEY).assertIsNotEnabled()
    }

    @Test fun changedAddressCannotSendANewKeyToTheOldService() {
        val keyWrites = mutableListOf<String>()
        val addressWrites = mutableListOf<String>()
        val facts = WebSearchFacts(mode = WebSearchMode.SEARCH_API,
            hasCredential = FactState.YES, writable = FactState.YES)
        compose.setContent {
            SearchFixtureTheme("https://old.example.invalid") {
                WebSearchSettingsPage(state = WebSearchScreenState.from(facts), onToggle = {}, onSelectBackend = {},
                    onToggleBackends = {}, onBack = {}, onModeChange = {},
                    onCommitAddress = { addressWrites += it }, onCommitKey = { key -> keyWrites += key })
            }
        }
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_ADDRESS_FIELD).performTextClearance()
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_ADDRESS_FIELD).performTextInput("new.example.invalid")
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_LIST).performScrollToNode(hasTestTag(UiPageTags.WEB_SEARCH_KEY_FIELD))
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_KEY_FIELD).performTextInput("fixture-new-key")
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_LIST).performScrollToNode(hasText(UiStrings.WEB_SEARCH_SAVE_KEY))
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SAVE_KEY).performClick()
        assertTrue("no key may be handed off for the old confirmed address", keyWrites.isEmpty())
        assertTrue("the edited address should be submitted separately", addressWrites.contains("https://new.example.invalid"))
        compose.onNodeWithText("请先保存有效地址，再保存密钥。").assertIsDisplayed()
    }
}


@Composable
private fun SearchFixtureTheme(base: String, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalWebSearchSavedBase provides base) { PdshTheme(content = content) }
}
