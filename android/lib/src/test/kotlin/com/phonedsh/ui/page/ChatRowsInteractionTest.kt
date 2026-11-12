// Page adoption of the shared context menu and disclosure (interaction.md §3, §7).
// SPDX-License-Identifier: MIT
//
// These tests drive the real page rows (`ChatRowItem`) rather than the shared
// components, so they fail if a row stops using `PdshContextMenu` /
// `PdshDisclosure`: the item list is recomputed from the frozen token table and
// the body motion is sampled through `mainClock.autoAdvance = false`.
package com.phonedsh.ui.page

import android.content.ClipboardManager
import android.content.Context
import android.provider.Settings
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.disclosure.DisclosureMotion
import com.phonedsh.ui.disclosure.DisclosureKind
import com.phonedsh.ui.disclosure.PdshDisclosureTags
import com.phonedsh.ui.menu.ContextMenuModel
import com.phonedsh.ui.menu.ContextMenuRowState
import com.phonedsh.ui.menu.ContextMenuTags
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.state.ChatTurnState
import com.phonedsh.ui.state.ContextEntry
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.generated.TokenContextMenuWhen
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import kotlin.math.roundToLong

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class ChatRowsInteractionTest {
    @get:Rule
    val compose = createComposeRule()

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private val bodyDurationMs: Int
        get() = DisclosureMotion.specFor(DisclosureKind.BODY, reducedMotion = false).durationMs

    @Before
    fun animate() {
        // The disclosure reads the platform animator scale; these tests time the
        // contract motion, so make sure a previous test's snap setting is gone.
        Settings.Global.putFloat(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        )
    }

    @After
    fun restoreAnimatorScale() {
        Settings.Global.putFloat(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        )
    }

    // -----------------------------------------------------------------------
    // §3 context menus
    // -----------------------------------------------------------------------

    @Test
    fun `a real user bubble long-press opens exactly the frozen surface items`() {
        val row = ChatRow.User(id = "user/1", text = "a real bubble")
        compose.setContent {
            PdshTheme {
                ChatRowItem(row = row, expandedRowIds = emptySet(), onToggleRow = {})
            }
        }

        longPressBubble()
        assertMenuEquals(USER_BUBBLE_SURFACE, userState(hasText = true))
    }

    @Test
    fun `a real assistant body long-press opens exactly the frozen surface items`() {
        val row = ChatRow.Assistant(id = "answer/1", text = "the whole answer")
        compose.setContent {
            PdshTheme {
                ChatRowItem(row = row, expandedRowIds = emptySet(), onToggleRow = {})
            }
        }

        compose.onNodeWithText("the whole answer").performTouchInput { longClick() }
        compose.waitForIdle()
        assertMenuEquals(ASSISTANT_BODY_SURFACE, userState(hasText = true))
    }

    @Test
    fun `the share item is absent without text`() {
        val row = ChatRow.User(id = "user/empty", text = "")
        compose.setContent {
            PdshTheme {
                ChatRowItem(row = row, expandedRowIds = emptySet(), onToggleRow = {})
            }
        }

        val state = userState(hasText = false)
        assertTrue(
            "rule 2: no item is shown when hasText is false",
            ContextMenuModel.items(USER_BUBBLE_SURFACE, state).isEmpty(),
        )
        longPressBubble()
        compose.onNodeWithTag(ContextMenuTags.MENU).assertDoesNotExist()
    }

    @Test
    fun `choosing share closes the menu and hands the text to the host callback`() {
        val row = ChatRow.User(id = "user/share", text = "share this")
        val shared = mutableListOf<String>()
        compose.setContent {
            PdshTheme {
                ChatRowItem(
                    row = row,
                    expandedRowIds = emptySet(),
                    onToggleRow = {},
                    onShareText = { text -> shared += text },
                )
            }
        }

        longPressBubble()
        val share = ContextMenuModel.items(USER_BUBBLE_SURFACE, userState(hasText = true)).single { it.isShare }
        compose.onNodeWithText(share.label).performClick()
        compose.waitForIdle()

        assertEquals(listOf("share this"), shared)
        compose.onNodeWithTag(ContextMenuTags.MENU).assertDoesNotExist()
    }

    @Test
    fun `choosing copy closes the menu before writing the clipboard`() {
        val row = ChatRow.User(id = "user/copy", text = "copy this")
        compose.setContent {
            PdshTheme {
                ChatRowItem(row = row, expandedRowIds = emptySet(), onToggleRow = {})
            }
        }

        longPressBubble()
        val copy = ContextMenuModel.items(USER_BUBBLE_SURFACE, userState(hasText = true)).single { !it.isShare }
        compose.onNodeWithText(copy.label).performClick()
        compose.waitForIdle()

        compose.onNodeWithTag(ContextMenuTags.MENU).assertDoesNotExist()
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        assertEquals("copy this", clipboard.primaryClip?.getItemAt(0)?.text?.toString())
    }

    // -----------------------------------------------------------------------
    // §7 disclosure
    // -----------------------------------------------------------------------

    @Test
    fun `the turn-process body follows motion disclosure while its header stays put`() {
        val row = ChatRow.TurnProcess(
            id = "turn-process/t1",
            turnID = "t1",
            outcome = ChatTurnState.COMPLETED,
            foldable = true,
            expanded = false,
            entries = listOf(ChatRow.Thinking("think/1", "private reasoning", false)),
            closingAssistant = ChatRow.Assistant("answer/1", "final answer"),
        )
        var open by mutableStateOf(false)
        compose.setContent {
            PdshTheme {
                ChatRowItem(
                    row = row.copy(expanded = open),
                    expandedRowIds = if (open) setOf(row.id) else emptySet(),
                    onToggleRow = { open = !open },
                )
            }
        }
        assertBodyMotion(
            headerTag = PdshDisclosureTags.header(TURN_PROCESS_DISCLOSURE_TAG),
            bodyTag = PdshDisclosureTags.body(TURN_PROCESS_DISCLOSURE_TAG),
        )
        // The final answer is not part of the folding body (iOS keeps it visible).
        compose.onNodeWithText("final answer").assertIsDisplayed()
        compose.onNodeWithTag(TURN_PROCESS_CHEVRON_TAG, useUnmergedTree = true).assertIsDisplayed()
    }

    @Test
    fun `the context-group body follows motion disclosure while its header stays put`() {
        val row = ChatRow.Context(
            id = "context/1",
            entries = listOf(
                ContextEntry(source = "file", text = "workspace/notes/a.md"),
                ContextEntry(source = "user-approval", text = "approved exec"),
            ),
        )
        var open by mutableStateOf(false)
        compose.setContent {
            PdshTheme {
                ChatRowItem(
                    row = row,
                    expandedRowIds = if (open) setOf(row.id) else emptySet(),
                    onToggleRow = { open = !open },
                )
            }
        }
        assertBodyMotion(
            headerTag = PdshDisclosureTags.header(CONTEXT_GROUP_DISCLOSURE_TAG),
            bodyTag = PdshDisclosureTags.body(CONTEXT_GROUP_DISCLOSURE_TAG),
        )
        compose.onNodeWithTag(CONTEXT_GROUP_CHEVRON_TAG, useUnmergedTree = true).assertIsDisplayed()
    }

    /**
     * Samples the disclosure body at 0 / half / full and asserts:
     * rule 4 (one body animation of the contract duration), rule 5 (no snap
     * while animations are on) and rule 6 (the tapped header does not move).
     */
    private fun assertBodyMotion(headerTag: String, bodyTag: String) {
        compose.mainClock.autoAdvance = false
        val headerBefore = compose.onNodeWithTag(headerTag).fetchSemanticsNode().boundsInRoot
        compose.onNodeWithTag(bodyTag).assertDoesNotExist()

        compose.onNodeWithTag(headerTag).performClick()
        compose.mainClock.advanceTimeByFrame()

        // The first composed frame can still be at zero height; probe a few
        // frames so the sample is inside the motion rather than before it.
        var attempts = 0
        while (attempts < 12 && runCatching { bodyHeight(bodyTag) }.getOrDefault(0f) <= 0.2f) {
            compose.mainClock.advanceTimeByFrame()
            attempts++
        }
        val early = bodyHeight(bodyTag)
        assertTrue("the body started animating (height=$early)", early > 0.2f)
        compose.mainClock.advanceTimeBy((bodyDurationMs / 2.0).roundToLong())
        val mid = bodyHeight(bodyTag)
        assertTrue("rule 4: the body is mid-motion at the half sample (height=$mid)", mid > 0.2f)
        compose.mainClock.advanceTimeBy(bodyDurationMs + 40L)
        compose.mainClock.advanceTimeByFrame()
        val end = bodyHeight(bodyTag)
        assertTrue("the body settles taller than the half sample ($mid -> $end)", end > mid)
        assertEquals(
            "rule 6: the tapped header does not move during or after the motion",
            headerBefore.top,
            compose.onNodeWithTag(headerTag).fetchSemanticsNode().boundsInRoot.top,
            0.5f,
        )
    }

    private fun bodyHeight(tag: String): Float =
        compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot.height / compose.density.density

    private fun longPressBubble() {
        compose.onNodeWithTag(UiTags.BUBBLE).performTouchInput { longClick() }
        compose.waitForIdle()
    }

    private fun assertMenuEquals(surfaceId: String, state: ContextMenuRowState) {
        val expected = ContextMenuModel.items(surfaceId, state)
        assertTrue("the fixture must have at least one visible item", expected.isNotEmpty())
        expected.forEach { item ->
            compose.onNodeWithText(item.label).assertIsDisplayed()
            compose.onNodeWithTag(ContextMenuTags.itemTag(surfaceId, item.order)).assertIsDisplayed()
        }
        // Rule 2: a hidden item is absent, not disabled.
        ContextMenuModel.surface(surfaceId).items.forEachIndexed { order, token ->
            if (!state.shows(token.whenCondition)) {
                compose.onNodeWithTag(ContextMenuTags.itemTag(surfaceId, order)).assertDoesNotExist()
            }
        }
    }

    private fun userState(hasText: Boolean): ContextMenuRowState =
        ContextMenuRowState.of(TokenContextMenuWhen.HAS_TEXT to hasText)
}
