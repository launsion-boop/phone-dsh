// NativeShortcutsPage: the six commands, the three fixed rows, 恢复全部默认 and
// the unread-store rule.
// SPDX-License-Identifier: MIT
//
// The binding display is the baseline's `NativeShortcut.display` (⌃⌥⇧⌘ order,
// then the key), so the defaults table is asserted value by value: a mirror that
// printed the wrong modifier order would still look plausible on screen.
package com.phonedsh.ui.page

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
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
class NativeShortcutsPageTest {
    @get:Rule
    val compose = createComposeRule()

    private fun mount(
        state: NativeShortcutsScreenState,
        onResetAll: () -> Unit = {},
        onBack: () -> Unit = {},
    ) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                NativeShortcutsPage(state = state, onResetAll = onResetAll, onBack = onBack)
            }
        }
        compose.waitForIdle()
    }

    @Test
    fun `an unread store renders 未知 and never the defaults`() {
        val state = NativeShortcutsScreenState.from(NativeShortcutsFacts())
        assertFalse(state.storeKnown)
        assertFalse(state.canResetAll)
        assertTrue(state.commands.all { it.value == null })
        assertEquals(ChatShortcutAction.entries, state.commands.map { it.action })
        // The three fixed rows are literal copy, not preferences: always reported.
        assertEquals(
            listOf("⇧↩", "↩", "⌘↩"),
            state.fixed.map { it.keys },
        )
    }

    @Test
    fun `an empty override map shows the baseline's defaults and disables the reset`() {
        val state = NativeShortcutsScreenState.from(
            NativeShortcutsFacts(overrides = emptyMap(), writable = FactState.YES),
        )
        assertTrue(state.storeKnown)
        assertFalse(state.canResetAll)
        assertEquals(
            listOf("↩", "⌘↩", "esc", "⌘,", "⌘/", "⌘↓"),
            state.commands.map { it.value },
        )
        assertTrue(state.commands.none { it.overridden })
    }

    @Test
    fun `an override wins and enables the reset only when the host can write`() {
        val overrides = mapOf(
            ChatShortcutAction.SEND to ChatShortcut(key = "a", command = true),
        )
        val writable = NativeShortcutsScreenState.from(
            NativeShortcutsFacts(overrides = overrides, writable = FactState.YES),
        )
        assertTrue(writable.canResetAll)
        val send = writable.commands.first { it.action == ChatShortcutAction.SEND }
        assertEquals("⌘A", send.value)
        assertTrue(send.overridden)

        val readOnly = NativeShortcutsScreenState.from(
            NativeShortcutsFacts(overrides = overrides, writable = FactState.NO),
        )
        assertFalse(readOnly.canResetAll)
    }

    @Test
    fun `the display orders the modifiers control, option, shift, command`() {
        val chord = ChatShortcut(
            key = "/",
            command = true,
            option = true,
            shift = true,
            control = true,
        )
        assertEquals("⌃⌥⇧⌘/", chord.display)
    }

    @Test
    fun `both section titles and the fixed rows are on screen`() {
        mount(NativeShortcutsScreenState.from(NativeShortcutsFacts(overrides = emptyMap())))
        compose.onNodeWithText(UiStrings.SHORTCUTS_TITLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.SHORTCUTS_SECTION_COMMANDS).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SHORTCUTS_LIST)
            .performScrollToNode(hasText(UiStrings.SHORTCUTS_SECTION_FIXED))
        compose.onNodeWithText(UiStrings.SHORTCUTS_SECTION_FIXED).assertIsDisplayed()
        listOf(
            UiStrings.SHORTCUTS_FIXED_NEW_LINE,
            UiStrings.SHORTCUTS_FIXED_SEND,
            UiStrings.SHORTCUTS_ACTION_ALTERNATE,
            UiStrings.SHORTCUTS_RESET_ALL,
        ).forEach { text ->
            compose.onNodeWithTag(UiPageTags.SHORTCUTS_LIST).performScrollToNode(hasText(text))
            compose.onAllNodesWithText(text).onFirst().assertIsDisplayed()
        }
    }

    @Test
    fun `恢复全部默认 is disabled without an override and fires with one`() {
        var state by mutableStateOf(
            NativeShortcutsScreenState.from(
                NativeShortcutsFacts(overrides = emptyMap(), writable = FactState.YES),
            ),
        )
        var reset = false
        compose.setContent {
            PdshTheme(darkTheme = false) {
                NativeShortcutsPage(
                    state = state,
                    onResetAll = { reset = true },
                    onBack = {},
                )
            }
        }
        compose.onNodeWithTag(UiPageTags.SHORTCUTS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.SHORTCUTS_RESET))
        compose.onNodeWithTag(UiPageTags.SHORTCUTS_RESET).assertIsNotEnabled()

        // The host now reports one override: the same page must offer the reset.
        compose.runOnIdle {
            state = NativeShortcutsScreenState.from(
                NativeShortcutsFacts(
                    overrides = mapOf(
                        ChatShortcutAction.STOP to ChatShortcut(key = "escape", control = true),
                    ),
                    writable = FactState.YES,
                ),
            )
        }
        compose.waitForIdle()
        compose.onNodeWithTag(UiPageTags.SHORTCUTS_LIST)
            .performScrollToNode(hasTestTag(UiPageTags.SHORTCUTS_RESET))
        compose.onNodeWithTag(UiPageTags.SHORTCUTS_RESET).assertIsEnabled().performClick()
        compose.runOnIdle { assertTrue(reset) }
    }

    @Test
    fun `the back chevron pops the page`() {
        var back = false
        mount(
            NativeShortcutsScreenState.from(NativeShortcutsFacts()),
            onBack = { back = true },
        )
        compose.onNodeWithTag(UiPageTags.SHORTCUTS_BACK).performClick()
        compose.runOnIdle { assertTrue(back) }
    }

    @Test
    fun `the unread store footnote is not the read store's`() {
        val unread = NativeShortcutsScreenState.from(NativeShortcutsFacts())
        assertNull(unread.commands.first().value)
        assertFalse(unread.storeKnown)
        mount(unread)
        // The hint is the first card's last row, inside the first window.
        compose.onNodeWithText(UiStrings.SHORTCUTS_UNKNOWN_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.SHORTCUTS_HINT).assertIsDisplayed()
    }
}
