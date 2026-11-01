// Context row acceptance: Harness event -> UiState node -> ChatScreenState -> screen.
// SPDX-License-Identifier: MIT
//
// The row model (`ChatRow.Context`), the grouped renderer (`ContextGroupRow`)
// and the source-name translation table existed before this test, but nothing
// produced the row: `UiStateKind` had no context kind, so the projection could
// never emit one. Every other test handed `ChatScreenState` a hand-built row
// list, which is why the gap stayed green. This test starts where the product
// starts — at the Harness events — and only asserts on what the renderer laid
// out, so deleting the projection's context branch turns it red.
package com.phonedsh.ui.state

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.agentcore.HarnessEvent
import com.phonedsh.agentcore.HarnessKind
import com.phonedsh.agentcore.HarnessTurnEnd
import com.phonedsh.ui.JsonSchemaLite
import com.phonedsh.ui.SpecFixtures
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.ChatRowList
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.projection.UiStateKind
import com.phonedsh.ui.projection.UiStateProjector
import com.phonedsh.ui.projection.encodeCanonical
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * End-to-end: the harness stream the DSH mapper produces for a turn with two
 * injected context blocks must reach the screen as one folded context row.
 *
 * The source field is the only classifier input (iOS
 * `DSHMessageSourceClassifier`): `user` is a bubble, `file` and `user-approval`
 * are context, and `unknown` — the adapter's "no source" marker — must stay a
 * bubble rather than inventing provenance.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class ContextEndToEndTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `injected context blocks arrive as one context row on screen`() {
        val nodes = UiStateProjector.project(events())

        // The pinned sequence is the projection's own bytes; regenerating it is a
        // review event (the new nodes are the two `context` slots).
        assertEquals(
            "pinned UiState sequence",
            SpecFixtures.pinnedUiState("context-blocks.jsonl"),
            nodes.encodeCanonical(),
        )
        assertEquals(
            "one context node per injected block",
            2,
            nodes.count { it.kind == UiStateKind.CONTEXT },
        )
        assertEquals(
            "the person's message is still a bubble",
            1,
            nodes.count { it.kind == UiStateKind.BUBBLE && it.props.string("role") == "user" },
        )
        // The new kind must be legal under the real schema, not only under the
        // projector's own enum: this is the check that would have caught the
        // schema still carrying eleven kinds.
        nodes.forEachIndexed { index, node ->
            val problems = JsonSchemaLite.validate(SpecFixtures.uiStateSchema, node.toJsonObject(), "context[$index]")
            assertTrue("context node $index violates the schema: $problems", problems.isEmpty())
            if (node.kind == UiStateKind.CONTEXT) {
                assertEquals("a context row has no pixel surface", "none", node.surface.wire)
            }
        }

        val state = ChatScreenState.from(nodes)
        val context = state.rows.filterIsInstance<ChatRow.Context>().single()
        assertEquals("both blocks fold into one row", 2, context.entries.size)
        assertEquals("file", context.entries[0].source)
        assertEquals("user-approval", context.entries[1].source)
        assertEquals("the row is anchored on its first block", nodes.first { it.kind == UiStateKind.CONTEXT }.nodeID, context.id)
        // The fold keeps the transcript order: the blocks sit between the
        // person's message and the answer, never at the tail.
        assertTrue("the context row follows the user row", state.rows[1] is ChatRow.Context)

        show(state)

        // 1. The row is on screen, with its folded count.
        compose.onNodeWithTag(UiPageTags.CHAT_ROW_CONTEXT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONTEXT_GROUP).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONTEXT_GROUP_COUNT.format(2)).assertIsDisplayed()
        // A two-block group hides the source name until it is expanded (iOS rule).
        compose.onAllNodesWithText(UiStrings.CONTEXT_SOURCE_APPROVAL).assertCountEquals(0)

        // 2. Expanding shows each block's translated source and its text.
        compose.onNodeWithTag(UiPageTags.CHAT_ROW_CONTEXT).performClick()
        compose.onNodeWithText(UiStrings.CONTEXT_SOURCE_APPROVAL).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONTEXT_SOURCE_FILES).assertIsDisplayed()
        compose.onNodeWithText("approved exec").assertIsDisplayed()
        compose.onNodeWithText("workspace/notes/a.md\nworkspace/notes/b.md").assertIsDisplayed()
    }

    @Test
    fun `a plain or unknown-source user message never becomes context`() {
        val nodes = UiStateProjector.project(
            listOf(
                harness(HarnessKind.TurnStarted(turnId = "turn-0001"), null),
                harness(HarnessKind.UserMessage("typed by the person", "user"), 1),
                harness(HarnessKind.UserMessage("a fixture without a source", "unknown"), 2),
                harness(HarnessKind.TurnEnded(turnId = "turn-0001", reason = HarnessTurnEnd.Completed), 3),
            ),
        )
        assertTrue(
            "no injected source, so no context node",
            nodes.none { it.kind == UiStateKind.CONTEXT },
        )
        val state = ChatScreenState.from(nodes)
        assertTrue(
            "both messages stay in the transcript as user rows",
            state.rows.filterIsInstance<ChatRow.User>().size == 2,
        )
        assertTrue(
            "no context row is invented",
            state.rows.none { it is ChatRow.Context },
        )
    }

    @Test
    fun `a single context block shows its translated source without expanding`() {
        val nodes = UiStateProjector.project(
            listOf(
                harness(HarnessKind.TurnStarted(turnId = "turn-0001"), null),
                harness(HarnessKind.UserMessage("approved exec", "user-approval"), 1),
                harness(HarnessKind.TurnEnded(turnId = "turn-0001", reason = HarnessTurnEnd.Completed), 2),
            ),
        )
        show(ChatScreenState.from(nodes))
        compose.onNodeWithTag(UiPageTags.CHAT_ROW_CONTEXT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONTEXT_GROUP).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.CONTEXT_GROUP_COUNT.format(1)).assertIsDisplayed()
        // iOS shows the translated source on the collapsed line exactly when the
        // group holds one block whose source name it can translate.
        compose.onNodeWithText(UiStrings.CONTEXT_SOURCE_APPROVAL).assertIsDisplayed()
    }

    /** The DSH `user_message` stream of one turn: a prompt, two injected blocks, an answer. */
    private fun events(): List<HarnessEvent> = listOf(
        harness(HarnessKind.TurnStarted(turnId = "turn-0001"), null),
        harness(HarnessKind.UserMessage("Summarize the notes", "user"), 1),
        harness(HarnessKind.UserMessage("workspace/notes/a.md\nworkspace/notes/b.md", "file"), 2),
        harness(HarnessKind.UserMessage("approved exec", "user-approval"), 3),
        harness(HarnessKind.AssistantMessage("Done."), 4),
        harness(HarnessKind.TurnEnded(turnId = "turn-0001", reason = HarnessTurnEnd.Completed), 5),
    )

    private fun harness(kind: HarnessKind, seq: Long?): HarnessEvent = HarnessEvent(
        sessionId = "sess-006",
        timeMs = 0L,
        seq = seq,
        kind = kind,
    )

    /** Renders the real page list, so the assertion covers the renderer the page uses. */
    private fun show(state: ChatScreenState) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                var expanded by remember { mutableStateOf(emptySet<String>()) }
                ChatRowList(
                    rows = state.rows,
                    expandedRowIds = expanded,
                    onToggleRow = { expanded = expanded + it },
                )
            }
        }
    }
}
