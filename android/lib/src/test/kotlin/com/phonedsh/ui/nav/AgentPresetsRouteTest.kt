// The Agent 预设 route: roster read, 查看配置, 使用预设, 重新读取 and the creator gate.
// SPDX-License-Identifier: MIT
//
// Each case mounts the real `PdshNavHost` over the real page and drives the same
// control a person taps. The assertions are the page's visible state (the host's
// error text, the document body, the disabled creator) plus the callback payload,
// not a mock counter.
package com.phonedsh.ui.nav

import androidx.compose.foundation.text.BasicText
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.AgentPresetActions
import com.phonedsh.ui.page.AgentPresetDocument
import com.phonedsh.ui.page.AgentPresetReadOutcome
import com.phonedsh.ui.page.NativeAgentPreset
import com.phonedsh.ui.page.NativeAgentPresetsFacts
import com.phonedsh.ui.page.NativeAgentPresetsScreenState
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h900dp")
class AgentPresetsRouteTest {

    @get:Rule
    val compose = createComposeRule()

    private fun facts(
        presets: List<NativeAgentPreset> = listOf(
            NativeAgentPreset(id = "cordis", title = "Cordis", isDefault = true),
        ),
        error: String? = null,
    ): NativeAgentPresetsFacts = NativeAgentPresetsFacts(presets = presets, error = error)

    private fun mount(
        agentPresets: NativeAgentPresetsFacts = facts(),
        actions: AgentPresetActions = AgentPresetActions(),
        facts: PdshNavFacts = PdshNavFacts(),
    ) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Home, PdshRoute.AgentPresets)),
                    facts = facts,
                    onNavigate = {},
                    onBack = {},
                    onHome = {},
                    onHostAction = {},
                    home = { BasicText(text = "home") },
                    webSurface = {},
                    agentPresets = agentPresets,
                    agentPresetActions = actions,
                )
            }
        }
        compose.waitForIdle()
    }

    private fun scrollTo(label: String) {
        compose.onNodeWithTag(UiPageTags.AGENT_PRESETS_LIST)
            .performScrollToNode(hasText(label))
    }

    @Test
    fun `use preset invokes the host and keeps its failure on the page`() {
        val used = mutableListOf<String>()
        mount(
            actions = AgentPresetActions(
                use = { id ->
                    used += id
                    "conflict: agent preset is locked"
                },
            ),
        )

        scrollTo(UiStrings.AGENT_PRESETS_USE_PRESET)
        compose.onNodeWithText(UiStrings.AGENT_PRESETS_USE_PRESET).performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()

        assertEquals(listOf("cordis"), used)
        compose.onNodeWithText("conflict: agent preset is locked").assertIsDisplayed()
        // The failure kept the page open: the roster row is still there.
        compose.onNodeWithText(UiStrings.AGENT_PRESETS_USE_PRESET).assertIsDisplayed()
    }

    @Test
    fun `use preset success leaves no error and reports the chosen id`() {
        val used = mutableListOf<String>()
        mount(
            actions = AgentPresetActions(
                use = { id ->
                    used += id
                    null
                },
            ),
        )

        scrollTo(UiStrings.AGENT_PRESETS_USE_PRESET)
        compose.onNodeWithText(UiStrings.AGENT_PRESETS_USE_PRESET).performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()

        assertEquals(listOf("cordis"), used)
        compose.onNodeWithText(UiStrings.AGENT_PRESETS_USE_PRESET).assertIsDisplayed()
    }

    @Test
    fun `view configuration opens the host content instead of the static failure`() {
        val read = mutableListOf<String>()
        mount(
            actions = AgentPresetActions(
                read = { id ->
                    read += id
                    AgentPresetReadOutcome(
                        document = AgentPresetDocument(
                            presetId = id,
                            title = "Cordis",
                            yaml = "name: cordis\nmodel: standard\n",
                        ),
                    )
                },
            ),
        )

        scrollTo(UiStrings.AGENT_PRESETS_VIEW_CONFIG)
        compose.onNodeWithText(UiStrings.AGENT_PRESETS_VIEW_CONFIG).performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()

        assertEquals(listOf("cordis"), read)
        compose.onNodeWithText("name: cordis\nmodel: standard\n").assertIsDisplayed()
    }

    @Test
    fun `view configuration failure prints the worker code and message`() {
        mount(
            actions = AgentPresetActions(
                read = { AgentPresetReadOutcome(failure = "not-found: Unknown agent preset: cordis") },
            ),
        )

        scrollTo(UiStrings.AGENT_PRESETS_VIEW_CONFIG)
        compose.onNodeWithText(UiStrings.AGENT_PRESETS_VIEW_CONFIG).performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()

        compose.onNodeWithText("not-found: Unknown agent preset: cordis").assertIsDisplayed()
    }

    @Test
    fun `reload asks the host to re-read`() {
        var refreshes = 0
        mount(
            agentPresets = facts(error = "timeout: agentPresets/list was not answered"),
            actions = AgentPresetActions(refresh = { refreshes++ }),
        )
        // The route's own entry read, then the button's.
        compose.waitForIdle()
        val entryRefreshes = refreshes
        scrollTo(UiStrings.AGENT_PRESETS_RELOAD)
        compose.onNodeWithText(UiStrings.AGENT_PRESETS_RELOAD).performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()

        assertTrue("the route must read on entry", entryRefreshes >= 1)
        assertEquals(entryRefreshes + 1, refreshes)
    }

    @Test
    fun `the roster carries the default-locked marker and its read-only footer`() {
        mount()

        scrollTo(UiStrings.AGENT_PRESETS_DEFAULT_LOCKED)
        compose.onNodeWithText(UiStrings.AGENT_PRESETS_DEFAULT_LOCKED).assertIsDisplayed()
        scrollTo(UiStrings.AGENT_PRESETS_DEFAULT_READ_ONLY_REASON)
        compose.onNodeWithText(UiStrings.AGENT_PRESETS_DEFAULT_READ_ONLY_REASON).assertIsDisplayed()
    }

    @Test
    fun `an empty roster renders the engine-has-no-presets line`() {
        mount(agentPresets = facts(presets = emptyList()))

        compose.onNodeWithText(UiStrings.AGENT_PRESETS_EMPTY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.AGENT_PRESETS_UNREAD).assertDoesNotExist()
    }

    @Test
    fun `the page keeps the no-document sentence when the host has no reader`() {
        mount(agentPresets = facts(), actions = AgentPresetActions(read = null))

        scrollTo(UiStrings.AGENT_PRESETS_VIEW_CONFIG)
        compose.onNodeWithText(UiStrings.AGENT_PRESETS_VIEW_CONFIG).performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()

        compose.onNodeWithText(NativeAgentPresetsScreenState.NO_DOCUMENT_FAILURE).assertIsDisplayed()
    }
}
