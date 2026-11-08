// 网页搜索's five writes reach the host through the real router.
// SPDX-License-Identifier: MIT
//
// The page arms a write only when the host reports `writable = YES` *and* the route
// hands it the callback (`WebSearchSettingsPage`). Before this lane the route passed
// none of the five, so a writable host still drew disabled controls. These tests
// mount `PdshNavHost` on the route and prove each gesture becomes its action, and
// that the key action never prints the key.
package com.phonedsh.ui.nav

import androidx.compose.foundation.text.BasicText
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.FactState
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.page.WebSearchFacts
import com.phonedsh.ui.page.WebSearchMode
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class WebSearchRouteWiringTest {
    @get:Rule
    val compose = createComposeRule()

    private val actions = mutableListOf<PdshHostAction>()

    private fun mount(webSearch: WebSearchFacts) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Home, PdshRoute.WebSearch)),
                    facts = PdshNavFacts(webSearch = webSearch),
                    onNavigate = {},
                    onBack = {},
                    onHome = {},
                    onHostAction = { actions += it },
                    home = { BasicText(text = "home") },
                    webSurface = {},
                )
            }
        }
        compose.waitForIdle()
    }

    private fun scrollTo(text: String) {
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_LIST).performScrollToNode(hasText(text))
    }

    private fun scrollToTag(tag: String) {
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_LIST).performScrollToNode(hasTestTag(tag))
    }

    @Test
    fun `picking 自己填一个 asks the host to switch the mode`() {
        mount(WebSearchFacts(mode = WebSearchMode.FOLLOW_MODEL, writable = FactState.YES))
        compose.onNodeWithText(UiStrings.WEB_SEARCH_MODE_API).performSemanticsAction(SemanticsActions.OnClick)
        assertEquals(listOf<PdshHostAction>(PdshHostAction.SetWebSearchMode(WebSearchMode.SEARCH_API)), actions)
    }

    @Test
    fun `the address and the key reach the host and the key never prints`() {
        mount(WebSearchFacts(mode = WebSearchMode.SEARCH_API, hasCredential = FactState.NO, writable = FactState.YES))
        scrollToTag(UiPageTags.WEB_SEARCH_ADDRESS_FIELD)
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_ADDRESS_FIELD).performTextInput(" https://pdsh.tonoai.cn/v1/web ")
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_ADDRESS_FIELD).performImeAction()
        assertTrue(actions.contains(PdshHostAction.CommitWebSearchAddress("https://pdsh.tonoai.cn/v1/web")))

        val secret = "sk-" + "route" + "-wiring-0042"
        scrollToTag(UiPageTags.WEB_SEARCH_KEY_FIELD)
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_KEY_FIELD).performTextInput(secret)
        scrollTo(UiStrings.WEB_SEARCH_SAVE_KEY)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_SAVE_KEY).performSemanticsAction(SemanticsActions.OnClick)
        val keyAction = actions.filterIsInstance<PdshHostAction.CommitWebSearchKey>().single()
        assertEquals(secret, keyAction.key)
        assertFalse("toString must not print the key", keyAction.toString().contains(secret))
        assertFalse("the wire label is token-free", keyAction.wire.contains(secret))
    }

    @Test
    fun `clear and remove reach the host after their confirmations`() {
        mount(
            WebSearchFacts(
                mode = WebSearchMode.SEARCH_API,
                hasCredential = FactState.YES,
                keyTail = "0042",
                writable = FactState.YES,
            ),
        )
        scrollTo(UiStrings.WEB_SEARCH_CLEAR_KEY)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_CLEAR_KEY).performSemanticsAction(SemanticsActions.OnClick)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_CLEAR).performSemanticsAction(SemanticsActions.OnClick)
        assertEquals(PdshHostAction.ClearWebSearchKey, actions.last())

        scrollTo(UiStrings.WEB_SEARCH_DELETE_SERVICE)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_DELETE_SERVICE).performSemanticsAction(SemanticsActions.OnClick)
        compose.onNodeWithText(UiStrings.WEB_SEARCH_DELETE).performSemanticsAction(SemanticsActions.OnClick)
        assertEquals(PdshHostAction.RemoveWebSearchConfiguration, actions.last())
    }
}
