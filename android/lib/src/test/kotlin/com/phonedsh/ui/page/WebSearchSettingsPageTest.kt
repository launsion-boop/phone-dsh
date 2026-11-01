// Web-search page: switch, backend choice, the reason a switch is held, four states.
// SPDX-License-Identifier: MIT
//
// The disabled-switch assertion is the point of the page: "no backend" must not
// look like "off". The test therefore checks the disabled semantics together
// with the reason line, and the pure state test pins the same invariant so the
// two can never drift.
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
class WebSearchSettingsPageTest {
    @get:Rule
    val compose = createComposeRule()

    private val backendA = WebSearchBackend(id = "a", name = "内置搜索", configured = FactState.YES)
    private val backendB = WebSearchBackend(id = "b", name = "自建搜索", configured = FactState.YES)

    private fun show(
        facts: WebSearchFacts,
        onToggle: (Boolean) -> Unit = {},
        onSelectBackend: (String) -> Unit = {},
        onRetry: (() -> Unit)? = null,
    ) {
        val state = WebSearchScreenState.from(facts)
        compose.setContent {
            PdshTheme {
                WebSearchSettingsPage(
                    state = state,
                    onToggle = onToggle,
                    onSelectBackend = onSelectBackend,
                    onToggleBackends = {},
                    onBack = {},
                    onRetry = onRetry,
                )
            }
        }
    }

    private fun showLive(facts: WebSearchFacts, onToggle: (Boolean) -> Unit = {}) {
        compose.setContent {
            var local by remember { mutableStateOf(WebSearchLocalState()) }
            PdshTheme {
                WebSearchSettingsPage(
                    state = WebSearchScreenState.from(facts, local),
                    onToggle = onToggle,
                    onSelectBackend = {},
                    onToggleBackends = { local = local.apply(WebSearchUiEvent.ToggleBackends) },
                    onBack = {},
                )
            }
        }
    }

    // ------------------------------------------------------------------ states

    @Test
    fun `no backend disables the switch and says why`() {
        val facts = WebSearchFacts(enabled = FactState.NO, backends = emptyList())
        val state = WebSearchScreenState.from(facts)
        assertFalse(state.toggleEnabled)
        assertNotNull(state.reason)
        assertTrue(state.isEmpty)
        show(facts)
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_LIST).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_TOGGLE).assertIsDisplayed().assertIsNotEnabled()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_OFF).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_REASON).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_REASON_NO_BACKENDS).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_EMPTY_HINT).assertIsDisplayed()
    }

    @Test
    fun `a configured backend shows an enabled switch and selection`() {
        var toggled: Boolean? = null
        var selected: String? = null
        val facts = WebSearchFacts(
            enabled = FactState.YES,
            backends = listOf(backendA, backendB),
            selectedBackendId = "a",
        )
        val state = WebSearchScreenState.from(facts)
        assertTrue(state.toggleEnabled)
        assertNull(state.reason)
        compose.setContent {
            PdshTheme {
                WebSearchSettingsPage(
                    state = state,
                    onToggle = { toggled = it },
                    onSelectBackend = { selected = it },
                    onToggleBackends = {},
                    onBack = {},
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_TOGGLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_ON).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.WEB_SEARCH_BACKEND_ROW_PREFIX + "b"))
        compose.onNodeWithText("自建搜索").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SELECTED).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_BACKEND_ROW_PREFIX + "b").performClick()
        assertEquals("b", selected)
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_TOGGLE).performClick()
        assertEquals(false, toggled)
    }

    @Test
    fun `a failed read replaces stale facts with the failure line and retries`() {
        var retried = 0
        show(
            WebSearchFacts(
                enabled = FactState.YES,
                backends = listOf(backendA),
                selectedBackendId = "a",
                failure = WebSearchFailureReason.BACKENDS_UNREADABLE,
            ),
            onRetry = { retried += 1 },
        )
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_FAILURE_BACKENDS).assertIsDisplayed()
        // A failure is not drawn as a switch whose position we no longer trust.
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_TOGGLE).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_LIST).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        assertEquals(1, retried)
    }

    @Test
    fun `no snapshot is unknown, not an off switch`() {
        show(WebSearchFacts(enabled = FactState.UNKNOWN, backends = null))
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_UNKNOWN_STATE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_UNKNOWN_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_TOGGLE).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_LIST).assertDoesNotExist()
    }

    @Test
    fun `an unreadable backend and switch render 未知 and hold the switch`() {
        val facts = WebSearchFacts(
            enabled = FactState.UNKNOWN,
            backends = listOf(WebSearchBackend(id = "b", name = "自建搜索", configured = FactState.UNKNOWN)),
            selectedBackendId = "b",
        )
        val state = WebSearchScreenState.from(facts)
        assertEquals(UiStrings.UNKNOWN, state.toggleValue)
        assertEquals(UiStrings.WEB_SEARCH_REASON_BACKEND_UNKNOWN, state.reason)
        assertFalse(state.toggleEnabled)
        show(facts)
        // Locate the lazy backend row before asserting its copy.
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.WEB_SEARCH_BACKEND_ROW_PREFIX + "b"))
        // Two 未知s: the held switch and the backend's unreadable state.
        compose.onAllNodesWithText(UiStrings.UNKNOWN).assertCountEquals(2)
        compose.onNodeWithText(UiStrings.SETTINGS_UNKNOWN_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_TOGGLE).assertIsNotEnabled()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_REASON_BACKEND_UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SEARCH_ON).assertDoesNotExist()
    }

    @Test
    fun `a selected but unconfigured backend keeps the switch off`() {
        val facts = WebSearchFacts(
            enabled = FactState.NO,
            backends = listOf(WebSearchBackend(id = "a", name = "内置搜索", configured = FactState.NO)),
            selectedBackendId = "a",
        )
        val state = WebSearchScreenState.from(facts)
        assertFalse(state.toggleEnabled)
        assertEquals(UiStrings.WEB_SEARCH_REASON_BACKEND_UNCONFIGURED, state.reason)
    }

    @Test
    fun `a configured backend with an unknown switch state still holds it`() {
        val facts = WebSearchFacts(
            enabled = FactState.UNKNOWN,
            backends = listOf(backendA),
            selectedBackendId = "a",
        )
        val state = WebSearchScreenState.from(facts)
        assertFalse(state.toggleEnabled)
        assertEquals(UiStrings.WEB_SEARCH_REASON_TOGGLE_UNKNOWN, state.reason)
        assertEquals(UiStrings.UNKNOWN, state.toggleValue)
    }

    // --------------------------------------------------------------- sequence

    @Test
    fun `the backend fold sequence is a pure function of the script`() {
        val facts = WebSearchFacts(
            enabled = FactState.YES,
            backends = listOf(backendA, backendB),
            selectedBackendId = "a",
        )
        val script = listOf(
            WebSearchUiEvent.ToggleBackends,
            WebSearchUiEvent.ToggleBackends,
            WebSearchUiEvent.ToggleBackends,
        )
        var local = WebSearchLocalState()
        val states = buildList {
            add(WebSearchScreenState.from(facts, local))
            script.forEach { event ->
                local = local.apply(event)
                add(WebSearchScreenState.from(facts, local))
            }
        }
        assertEquals(listOf(true, false, true, false), states.map { it.backendsExpanded })
        // The switch and the rows are facts, not folds: they never move.
        assertEquals(1, states.map { it.toggleValue }.distinct().size)
        assertEquals(1, states.map { it.backends }.distinct().size)

        var replay = WebSearchLocalState()
        val replayed = buildList {
            add(WebSearchScreenState.from(facts, replay))
            script.forEach { event ->
                replay = replay.apply(event)
                add(WebSearchScreenState.from(facts, replay))
            }
        }
        assertEquals(states, replayed)
    }

    @Test
    fun `the live fold hides the backend rows`() {
        showLive(
            WebSearchFacts(enabled = FactState.YES, backends = listOf(backendA), selectedBackendId = "a"),
        )
        compose.onNodeWithText("内置搜索").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_BACKENDS_SECTION).performClick()
        compose.onNodeWithText("内置搜索").assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_TOGGLE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WEB_SEARCH_BACKENDS_SECTION).performClick()
        compose.onNodeWithText("内置搜索").assertIsDisplayed()
    }
}
