// WebSurfacePage: the four states, the full-screen live surface and the details sequence.
// SPDX-License-Identifier: MIT
//
// The unknown test locates the detail row with `performScrollToNode` before it
// asserts that no "已加载" was invented: the fallback chrome is a lazy list, so
// an absence assertion against an uncomposed item would pass for the wrong
// reason.
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
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
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
class WebSurfacePageTest {
    @get:Rule
    val compose = createComposeRule()

    private fun liveFacts(): WebSurfaceFacts = WebSurfaceFacts(
        snapshot = WebSurfaceSnapshot(
            engine = FactState.YES,
            webViewAttached = FactState.YES,
            pageLoaded = FactState.YES,
            pageUrl = "http://127.0.0.1:41234/static/web/index.html",
            statusLine = "正在准备本地 DSH…",
            nativeFallback = FactState.YES,
        ),
    )

    private fun preparingFacts(): WebSurfaceFacts = WebSurfaceFacts(
        snapshot = WebSurfaceSnapshot(
            engine = FactState.YES,
            webViewAttached = FactState.YES,
            pageLoaded = FactState.NO,
            pageUrl = "http://127.0.0.1:41234/static/web/index.html",
            statusLine = "正在准备本地 DSH…",
            nativeFallback = FactState.YES,
        ),
    )

    private fun show(
        state: WebSurfaceScreenState,
        onRetry: (() -> Unit)? = null,
        onOpenModelSettings: (() -> Unit)? = null,
        onNativeRecovery: (() -> Unit)? = null,
        onToggleDetails: (() -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                WebSurfacePage(
                    state = state,
                    surface = {},
                    onRetry = onRetry,
                    onOpenModelSettings = onOpenModelSettings,
                    onNativeRecovery = onNativeRecovery,
                    onToggleDetails = onToggleDetails,
                )
            }
        }
    }

    private fun showLive(facts: WebSurfaceFacts) {
        compose.setContent {
            var local by remember { mutableStateOf(WebSurfaceLocalState()) }
            PdshTheme {
                WebSurfacePage(
                    state = WebSurfaceScreenState.from(facts, local),
                    surface = {},
                    onToggleDetails = {
                        local = local.apply(WebSurfaceUiEvent.ToggleDetails)
                    },
                )
            }
        }
    }

    // ------------------------------------------------------------------ states

    @Test
    fun `a live surface is the only full-screen state and carries no fallback chrome`() {
        val state = WebSurfaceScreenState.from(liveFacts())
        assertEquals(WebSurfaceStatus.READY, state.status)
        assertTrue(state.live)
        assertFalse(state.preparing)
        assertEquals(FactState.YES, state.engine)
        assertEquals(
            UiStrings.WEB_SURFACE_ENGINE_READY,
            state.rows.first { it.id == WebSurfaceScreenState.ENGINE_ROW_ID }.value,
        )
        assertEquals(
            UiStrings.WEB_SURFACE_ATTACHED,
            state.rows.first { it.id == WebSurfaceScreenState.WEBVIEW_ROW_ID }.value,
        )
        assertEquals(
            UiStrings.WEB_SURFACE_PAGE_LOADED,
            state.rows.first { it.id == WebSurfaceScreenState.PAGE_ROW_ID }.value,
        )
        assertFalse(state.hasUnmeasuredValues)
        show(state)

        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_ROOT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_SURFACE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_LIST).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_EMPTY).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_UNKNOWN).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_FAILURE).assertDoesNotExist()
    }

    @Test
    fun `an empty snapshot shows the empty state and never a surface`() {
        val state = WebSurfaceScreenState.from(
            WebSurfaceFacts(snapshot = WebSurfaceSnapshot()),
        )
        assertEquals(WebSurfaceStatus.EMPTY, state.status)
        assertTrue(state.isEmpty)
        assertFalse(state.live)
        assertTrue(state.rows.isEmpty())
        show(state)

        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_LIST).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_EMPTY).assertIsDisplayed()
        assertTrue(
            compose.onAllNodesWithText(UiStrings.WEB_SURFACE_EMPTY_HINT)
                .fetchSemanticsNodes()
                .isNotEmpty(),
        )
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_SURFACE).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_UNKNOWN).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.WEB_SURFACE_PAGE_LOADED).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.WEB_SURFACE_ATTACHED).assertDoesNotExist()
    }

    @Test
    fun `a failed page wins and offers retry, model settings and native recovery`() {
        val state = WebSurfaceScreenState.from(
            liveFacts().copy(snapshot = liveFacts().snapshot?.copy(failure = "WebView 崩溃")),
        )
        assertEquals(WebSurfaceStatus.FAILED, state.status)
        assertTrue(state.isFailed)
        assertFalse(state.live)
        assertTrue(state.rows.isEmpty())
        var retried = 0
        var model = 0
        var recovery = 0
        show(
            state,
            onRetry = { retried += 1 },
            onOpenModelSettings = { model += 1 },
            onNativeRecovery = { recovery += 1 },
        )

        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_FAILURE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.WEB_SURFACE_FAILED_HINT).assertIsDisplayed()
        assertTrue(
            compose.onAllNodesWithText("WebView 崩溃").fetchSemanticsNodes().isNotEmpty(),
        )
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_SURFACE).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_EMPTY).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_RETRY).performClick()
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_MODEL_SETTINGS).performClick()
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_NATIVE_RECOVERY).performClick()
        assertEquals(1, retried)
        assertEquals(1, model)
        assertEquals(1, recovery)
    }

    @Test
    fun `an unreported snapshot is unknown after the detail is composed`() {
        val state = WebSurfaceScreenState.from(WebSurfaceFacts())
        assertEquals(WebSurfaceStatus.UNKNOWN, state.status)
        assertTrue(state.isUnknown)
        assertTrue(state.rows.isEmpty())
        assertFalse(state.live)
        show(state)

        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.WEB_SURFACE_UNKNOWN_DETAIL))
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_UNKNOWN_DETAIL).assertIsDisplayed()
        assertTrue(
            compose.onAllNodesWithText(UiStrings.WEB_SURFACE_UNKNOWN_HINT)
                .fetchSemanticsNodes()
                .isNotEmpty(),
        )
        compose.onNodeWithText(UiStrings.WEB_SURFACE_UNKNOWN_DETAIL).assertIsDisplayed()
        assertTrue(
            compose.onAllNodesWithText(UiStrings.WEB_SURFACE_UNKNOWN_STATE)
                .fetchSemanticsNodes()
                .isNotEmpty(),
        )
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_EMPTY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.WEB_SURFACE_EMPTY).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.WEB_SURFACE_PAGE_LOADED).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.WEB_SURFACE_ATTACHED).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_SURFACE).assertDoesNotExist()
    }

    @Test
    fun `a preparing snapshot shows the startup panel and opens its details`() {
        val state = WebSurfaceScreenState.from(preparingFacts())
        assertEquals(WebSurfaceStatus.READY, state.status)
        assertFalse(state.live)
        assertTrue(state.preparing)
        assertEquals(UiStrings.WEB_SURFACE_PAGE_LOADING, state.rows
            .first { it.id == WebSurfaceScreenState.PAGE_ROW_ID }.value)
        showLive(preparingFacts())

        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_PANEL).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_PREPARING).assertIsDisplayed()
        compose.onNodeWithText("正在准备本地 DSH…").assertIsDisplayed()
        compose.onNodeWithTag(
            UiPageTags.WEB_SURFACE_ROW_PREFIX + WebSurfaceScreenState.PAGE_ROW_ID,
        ).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_DETAILS_TOGGLE).performClick()
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_LIST)
            .performScrollToNode(
                hasTestTag(
                    UiPageTags.WEB_SURFACE_ROW_PREFIX + WebSurfaceScreenState.PAGE_ROW_ID,
                ),
            )
        compose.onNodeWithText(UiStrings.WEB_SURFACE_PAGE_LOADING).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.WEB_SURFACE_DETAILS_TOGGLE))
        compose.onNodeWithTag(UiPageTags.WEB_SURFACE_DETAILS_TOGGLE).performClick()
        compose.onNodeWithText(UiStrings.WEB_SURFACE_PAGE_LOADING).assertDoesNotExist()
    }

    @Test
    fun `the details sequence is a pure function of the script`() {
        val facts = preparingFacts()
        val script = listOf(
            WebSurfaceUiEvent.ToggleDetails,
            WebSurfaceUiEvent.ToggleDetails,
            WebSurfaceUiEvent.ToggleDetails,
        )

        fun run(): List<WebSurfaceScreenState> {
            var local = WebSurfaceLocalState()
            return buildList {
                add(WebSurfaceScreenState.from(facts, local))
                script.forEach { event ->
                    local = local.apply(event)
                    add(WebSurfaceScreenState.from(facts, local))
                }
            }
        }

        val states = run()
        assertEquals(
            listOf(false, true, false, true),
            states.map { it.detailsExpanded },
        )
        assertEquals(
            listOf("collapsed", "details", "collapsed", "details"),
            states.map { state ->
                if (state.detailsExpanded) "details" else "collapsed"
            },
        )
        // Replaying the same script yields exactly the same sequence (purity).
        assertEquals(states.map { it.signature() }, run().map { it.signature() })
    }
}
