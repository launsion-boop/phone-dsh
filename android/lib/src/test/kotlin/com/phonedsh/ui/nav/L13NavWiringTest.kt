// The L13 lane's router edges: each new route must render its page.
// SPDX-License-Identifier: MIT
//
// Why this test exists: a route can compile and still be wired to the wrong
// `when` branch (or to a page that never mounts). These three cases mount the
// real [PdshNavHost] and assert the page's own top-level copy is on screen, the
// same shape `PdshReachabilityTest` uses for the sessions route.
//
// The facts are the default `PdshNavFacts()`: this host reads no chat preference,
// no shortcut store and no settings document, so the pages must render their
// honest unread face — 未知 / 读取不到 / the read-only line — and the assertions
// pin exactly that, not a fabricated default.
package com.phonedsh.ui.nav

import androidx.compose.foundation.text.BasicText
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h900dp")
class L13NavWiringTest {

    @get:Rule
    val compose = createComposeRule()

    /** Mounts the real router on the JVM host, one route deep. */
    private fun mount(route: PdshRoute) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Home, route)),
                    facts = PdshNavFacts(),
                    onNavigate = {},
                    onBack = {},
                    onHome = {},
                    onHostAction = {},
                    home = { BasicText(text = "home") },
                    webSurface = {},
                )
            }
        }
        compose.waitForIdle()
    }

    @Test
    fun `the shortcuts route renders the host's unread shortcut reference`() {
        mount(PdshRoute.Shortcuts)
        compose.onNodeWithText(UiStrings.SHORTCUTS_TITLE).assertIsDisplayed()
        compose.onAllNodesWithText(UiStrings.SHORTCUTS_SECTION_COMMANDS).onFirst().assertIsDisplayed()
        // No store: the defaults are not claimed.
        compose.onAllNodesWithText(UiStrings.UNKNOWN).onFirst().assertIsDisplayed()
    }

    @Test
    fun `the chat preferences route renders the read-only preference sheet`() {
        mount(PdshRoute.ChatPreferences)
        compose.onNodeWithText(UiStrings.CHAT_PREFERENCES_TITLE).assertIsDisplayed()
        // The read-only line is the list's last card; scroll it into the window.
        compose.onNodeWithTag(UiPageTags.CHAT_PREFERENCES_LIST)
            .performScrollToNode(hasText(UiStrings.HOST_READ_ONLY_HINT))
        compose.onAllNodesWithText(UiStrings.HOST_READ_ONLY_HINT).onFirst().assertIsDisplayed()
    }

    @Test
    fun `the settings document route renders the unknown document state`() {
        mount(PdshRoute.SettingsDocument)
        compose.onNodeWithText(UiStrings.SETTINGS_DOCUMENT_TITLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SETTINGS_DOCUMENT_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SETTINGS_DONE).assertIsDisplayed()
    }
}
