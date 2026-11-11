// Compose behaviour for the shared context-menu wrapper (interaction.md §3).
// SPDX-License-Identifier: MIT
//
// The pure projection is pinned by [UiContextMenuContractTest]; these tests
// cover the JVM-observable interaction rules: long-press opening, the row's tap
// staying intact, filtered rows, close-on-selection, one action per open, share
// routing, info inertness and the anchored per-row popup.
package com.phonedsh.ui.menu

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHasNoClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.generated.TokenContextMenuWhen
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class PdshContextMenuTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `long press opens only the rows whose when is true`() {
        val state = ContextMenuRowState.of(TokenContextMenuWhen.FOLDERS_ENABLED to false)
        show("drawerFolder", state)

        longPressRow()
        val visible = ContextMenuModel.items("drawerFolder", state)
        assertTrue("the fixture must leave at least one visible row", visible.isNotEmpty())
        visible.forEach { item ->
            compose.onNodeWithText(item.label).assertIsDisplayed().assertIsEnabled()
        }
        ContextMenuModel.surface("drawerFolder").items
            .filterNot { state.shows(it.whenCondition) }
            .forEach { token ->
                compose.onNodeWithText(token.label).assertDoesNotExist()
            }
    }

    @Test
    fun `a tap still runs the row action and does not open a menu`() {
        var taps = 0
        show("drawerSession", allTrueState(), onClick = { taps++ })

        compose.onNodeWithTag(ROW).performClick()
        compose.waitForIdle()
        assertEquals("rule 1: a tap is the row's own action", 1, taps)
        compose.onNodeWithTag(ContextMenuTags.MENU).assertDoesNotExist()
    }

    @Test
    fun `choosing a row closes the menu and runs exactly one action per open`() {
        val received = mutableListOf<ContextMenuItem>()
        val state = allTrueState()
        show("drawerSession", state, onAction = { received += it })

        longPressRow()
        val item = ContextMenuModel.items("drawerSession", state).first()
        compose.onNodeWithText(item.label).performClick()
        compose.waitForIdle()

        assertEquals(listOf(item), received)
        compose.onNodeWithTag(ContextMenuTags.MENU).assertDoesNotExist()

        // Reopening starts a new one-action session.
        longPressRow()
        compose.onNodeWithText(item.label).performClick()
        compose.waitForIdle()
        assertEquals(listOf(item, item), received)
    }

    @Test
    fun `a share row goes to the caller's share callback`() {
        val actions = mutableListOf<ContextMenuItem>()
        val shares = mutableListOf<ContextMenuItem>()
        val state = allTrueState()
        show(
            "userBubble",
            state,
            onAction = { actions += it },
            onShare = { shares += it },
        )

        longPressRow()
        val share = ContextMenuModel.items("userBubble", state).single { it.isShare }
        compose.onNodeWithText(share.label).performClick()
        compose.waitForIdle()

        assertEquals(listOf(share), shares)
        assertTrue("a share row must not take the normal action path", actions.isEmpty())
        compose.onNodeWithTag(ContextMenuTags.MENU).assertDoesNotExist()
    }

    @Test
    fun `a share row falls back to onAction when no share callback is supplied`() {
        val actions = mutableListOf<ContextMenuItem>()
        val state = allTrueState()
        show("userBubble", state, onAction = { actions += it })

        longPressRow()
        val share = ContextMenuModel.items("userBubble", state).single { it.isShare }
        compose.onNodeWithText(share.label).performClick()
        compose.waitForIdle()

        assertEquals(listOf(share), actions)
    }

    @Test
    fun `the botRow info row is visible, non-clickable and never an action`() {
        var actions = 0
        val state = botState(lastBot = true, notLastBot = false)
        show("botRow", state, onAction = { actions++ })

        longPressRow()
        val info = ContextMenuModel.items("botRow", state).single { it.isInfo }
        compose.onNodeWithText(info.label)
            .assertIsDisplayed()
            .assertHasNoClickAction()
        assertEquals("an info row must not dispatch an action", 0, actions)
    }

    @Test
    fun `the divider is drawn before exactly the token rows that ask for it`() {
        val state = botState(lastBot = false, notLastBot = true)
        show("botRow", state)

        longPressRow()
        val expected = ContextMenuModel.items("botRow", state).count { it.dividerBefore }
        assertTrue("the fixture must include a divider", expected > 0)
        compose.onAllNodesWithTag(ContextMenuTags.DIVIDER).assertCountEquals(expected)
    }

    @Test
    fun `botRow's hidden state replaces the label with altLabel`() {
        val token = ContextMenuModel.surface("botRow").items.single { it.altLabel != null }
        val base = ContextMenuModel.items("botRow", allTrueState(botHidden = false))
            .single { it.order == altOrder() }
        val alternate = ContextMenuModel.items("botRow", allTrueState(botHidden = true))
            .single { it.order == altOrder() }
        assertEquals("the alternate label comes from the token table", token.altLabel, alternate.label)

        show("botRow", allTrueState(botHidden = true))
        longPressRow()
        compose.onNodeWithText(alternate.label).assertIsDisplayed()
        compose.onNodeWithText(base.label).assertDoesNotExist()
    }

    @Test
    fun `an all-hidden surface does not open an empty menu`() {
        val state = ContextMenuRowState.of(TokenContextMenuWhen.HAS_TEXT to false)
        show("userBubble", state)

        longPressRow()
        compose.onNodeWithTag(ContextMenuTags.MENU).assertDoesNotExist()
    }

    @Test
    fun `the popup belongs to the row that was long-pressed`() {
        val drawerState = allTrueState()
        val hostState = allTrueState()
        compose.setContent {
            PdshTheme(darkTheme = false) {
                Column {
                    PdshContextMenu(
                        surfaceId = "drawerFolder",
                        state = drawerState,
                        onAction = {},
                        modifier = Modifier.testTag("row.drawer"),
                    ) { Text("drawer row") }
                    PdshContextMenu(
                        surfaceId = "hostAddress",
                        state = hostState,
                        onAction = {},
                        modifier = Modifier.testTag("row.host"),
                    ) { Text("host row") }
                }
            }
        }

        compose.onNodeWithTag("row.host").performTouchInput { longClick() }
        ContextMenuModel.items("hostAddress", hostState).forEach { item ->
            compose.onNodeWithText(item.label).assertIsDisplayed()
        }
        ContextMenuModel.items("drawerFolder", drawerState).forEach { item ->
            compose.onNodeWithText(item.label).assertDoesNotExist()
        }
    }

    private fun show(
        surfaceId: String,
        state: ContextMenuRowState,
        onAction: (ContextMenuItem) -> Unit = {},
        onClick: (() -> Unit)? = null,
        onShare: ((ContextMenuItem) -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshContextMenu(
                    surfaceId = surfaceId,
                    state = state,
                    onAction = onAction,
                    modifier = Modifier.testTag(ROW),
                    onClick = onClick,
                    onShare = onShare,
                ) { Text("pressed row") }
            }
        }
    }

    private fun longPressRow() {
        compose.onNodeWithTag(ROW).performTouchInput { longClick() }
        compose.waitForIdle()
    }

    private fun botState(lastBot: Boolean, notLastBot: Boolean): ContextMenuRowState =
        ContextMenuRowState.of(
            TokenContextMenuWhen.ALWAYS to true,
            TokenContextMenuWhen.NOT_MAIN_BOT to true,
            TokenContextMenuWhen.NOT_LAST_BOT to notLastBot,
            TokenContextMenuWhen.LAST_BOT to lastBot,
        )

    private fun altOrder(): Int =
        ContextMenuModel.surface("botRow").items.indexOfFirst { it.altLabel != null }

    private fun allTrueState(botHidden: Boolean = false): ContextMenuRowState =
        ContextMenuRowState(
            TokenContextMenuWhen.entries.associateWith { true },
            botHidden = botHidden,
        )

    private companion object {
        private const val ROW: String = "pdsh.context-menu.test-row"
    }
}
