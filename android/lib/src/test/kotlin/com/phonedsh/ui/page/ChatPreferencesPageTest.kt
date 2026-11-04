// ChatPreferencesPage: the four sections, the unread-value rule, the ranges and
// the pickers' contract labels.
// SPDX-License-Identifier: MIT
//
// Two layers, tested separately: `ChatPreferencesScreenState.from(facts)` is a
// pure projection (values, display strings, option lists, range checks) and the
// view is mounted to prove the literal labels the page-structure contract reads
// are actually on screen (外观 / 折叠时机 / 转录密度 / 完成) and that a picker
// reports the selected enum value back to the host.
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h900dp")
class ChatPreferencesPageTest {
    @get:Rule
    val compose = createComposeRule()

    private fun reported(writable: FactState = FactState.YES): ChatPreferencesScreenState =
        ChatPreferencesScreenState.from(
            ChatPreferencesFacts(
                appearance = SettingsAppearance.SYSTEM,
                textFontSize = 17,
                codeFontSize = 14,
                collapseTiming = CollapseTiming.COMPLETION,
                transcriptView = TranscriptViewMode.DETAILED,
                writable = writable,
            ),
        )

    private fun mount(
        state: ChatPreferencesScreenState,
        onSelectAppearance: (SettingsAppearance) -> Unit = {},
        onSelectCollapseTiming: (CollapseTiming) -> Unit = {},
        onSelectTranscriptView: (TranscriptViewMode) -> Unit = {},
        onSetTextFontSize: (Int) -> Unit = {},
        onSetCodeFontSize: (Int) -> Unit = {},
    ) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                ChatPreferencesPage(
                    state = state,
                    onSelectAppearance = onSelectAppearance,
                    onSelectCollapseTiming = onSelectCollapseTiming,
                    onSelectTranscriptView = onSelectTranscriptView,
                    onSetTextFontSize = onSetTextFontSize,
                    onSetCodeFontSize = onSetCodeFontSize,
                    onDone = {},
                )
            }
        }
        compose.waitForIdle()
    }

    @Test
    fun `an unreported host renders 未知 values and never a default`() {
        val state = ChatPreferencesScreenState.from(ChatPreferencesFacts(writable = FactState.NO))
        assertNull(state.appearance)
        assertNull(state.appearanceValue)
        assertNull(state.textFontSize)
        assertNull(state.textFontSizeValue)
        assertNull(state.codeFontSizeValue)
        assertNull(state.collapseTimingValue)
        assertNull(state.transcriptViewValue)
        assertFalse(state.enabled)
        assertFalse(state.canDecreaseText)
        assertFalse(state.canIncreaseText)
    }

    @Test
    fun `the option lists are the baseline's, in the baseline's order`() {
        val state = reported()
        assertEquals(
            listOf("跟随系统", "浅色", "深色"),
            state.appearanceOptions.map { it.label },
        )
        assertEquals(
            listOf("完成时", "下一条消息"),
            state.collapseTimingOptions.map { it.label },
        )
        assertEquals(
            listOf("紧凑", "标准", "详细", "完整"),
            state.transcriptViewOptions.map { it.label },
        )
        assertEquals(listOf("system", "light", "dark"), state.appearanceOptions.map { it.id })
    }

    @Test
    fun `the values are the page's words, not the settings tab's`() {
        val state = reported()
        assertEquals("跟随系统", state.appearanceValue)
        assertEquals("完成时", state.collapseTimingValue)
        assertEquals("详细", state.transcriptViewValue)
        assertEquals("17pt", state.textFontSizeValue)
        assertEquals("14pt", state.codeFontSizeValue)
    }

    @Test
    fun `the steppers stay inside the baseline's size ranges`() {
        val bottom = ChatPreferencesScreenState.from(
            ChatPreferencesFacts(textFontSize = 10, codeFontSize = 16, writable = FactState.YES),
        )
        assertFalse(bottom.canDecreaseText)
        assertTrue(bottom.canIncreaseText)
        assertTrue(bottom.canDecreaseCode)
        assertFalse(bottom.canIncreaseCode)

        val top = ChatPreferencesScreenState.from(
            ChatPreferencesFacts(textFontSize = 22, codeFontSize = 10, writable = FactState.YES),
        )
        assertTrue(top.canDecreaseText)
        assertFalse(top.canIncreaseText)
        assertFalse(top.canDecreaseCode)
        assertTrue(top.canIncreaseCode)
    }

    @Test
    fun `the facts project the settings snapshot`() {
        val facts = ChatPreferencesFacts.from(
            SettingsPreferences(
                appearance = SettingsAppearance.DARK,
                fontSizeConversation = 18,
                fontSizeCode = 13,
                transcriptView = TranscriptViewMode.VERBOSE,
                collapseTiming = CollapseTiming.NEXT_INPUT,
            ),
            writable = FactState.YES,
        )
        val state = ChatPreferencesScreenState.from(facts)
        assertEquals("深色", state.appearanceValue)
        assertEquals("完整", state.transcriptViewValue)
        assertEquals("下一条消息", state.collapseTimingValue)
        assertEquals("18pt", state.textFontSizeValue)
        assertEquals("13pt", state.codeFontSizeValue)
        assertTrue(state.enabled)
    }

    @Test
    fun `the four section titles and the four actions are on screen`() {
        mount(reported())
        listOf(
            UiStrings.CHAT_PREFERENCES_TITLE,
            UiStrings.CHAT_PREFERENCES_SECTION_APPEARANCE,
            UiStrings.CHAT_PREFERENCES_SECTION_FONT,
            UiStrings.CHAT_PREFERENCES_SECTION_COLLAPSE,
            UiStrings.CHAT_PREFERENCES_SECTION_TRANSCRIPT,
            UiStrings.CHAT_PREFERENCES_ROW_FONT_TEXT,
            UiStrings.CHAT_PREFERENCES_ROW_FONT_CODE,
            UiStrings.CHAT_PREFERENCES_ROW_COLLAPSE,
            UiStrings.CHAT_PREFERENCES_ROW_TRANSCRIPT,
            UiStrings.SETTINGS_DONE,
        ).forEach { text ->
            compose.onAllNodesWithText(text).onFirst().assertIsDisplayed()
        }
        // 外观 is both the section title and the row label (`ChatPreferencesPage.swift:14,23`).
        compose.onNodeWithTag(UiPageTags.CHAT_PREFERENCES_SECTION_PREFIX + "appearance")
            .assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.CHAT_PREFERENCES_ROW_PREFIX + "appearance")
            .assertIsDisplayed()
    }

    @Test
    fun `a picker opens its options and reports the choice`() {
        var picked: SettingsAppearance? = null
        mount(reported(), onSelectAppearance = { picked = it })
        val row = UiPageTags.CHAT_PREFERENCES_ROW_PREFIX + "appearance"
        compose.onNodeWithTag(UiPageTags.CHAT_PREFERENCES_LIST).performScrollToNode(hasTestTag(row))
        compose.onNodeWithTag(row).performClick()
        compose.onNodeWithTag(UiPageTags.CHAT_PREFERENCES_OPTION_PREFIX + "dark").performClick()
        compose.runOnIdle { assertEquals(SettingsAppearance.DARK, picked) }
    }

    @Test
    fun `a host that cannot write keeps the pickers closed and says why`() {
        mount(reported(writable = FactState.NO))
        val row = UiPageTags.CHAT_PREFERENCES_ROW_PREFIX + "appearance"
        compose.onNodeWithTag(UiPageTags.CHAT_PREFERENCES_LIST).performScrollToNode(hasTestTag(row))
        compose.onNodeWithTag(row).performClick()
        compose.onNodeWithTag(UiPageTags.CHAT_PREFERENCES_OPTION_PREFIX + "dark").assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.CHAT_PREFERENCES_LIST)
            .performScrollToNode(hasText(UiStrings.HOST_READ_ONLY_HINT))
        compose.onNodeWithText(UiStrings.HOST_READ_ONLY_HINT).assertIsDisplayed()
    }

    @Test
    fun `the 完成 action is the baseline's only chrome action`() {
        var done = false
        compose.setContent {
            PdshTheme(darkTheme = false) {
                ChatPreferencesPage(
                    state = reported(),
                    onSelectAppearance = {},
                    onSelectCollapseTiming = {},
                    onSelectTranscriptView = {},
                    onSetTextFontSize = {},
                    onSetCodeFontSize = {},
                    onDone = { done = true },
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.CHAT_PREFERENCES_DONE).performClick()
        compose.runOnIdle { assertTrue(done) }
    }
}
