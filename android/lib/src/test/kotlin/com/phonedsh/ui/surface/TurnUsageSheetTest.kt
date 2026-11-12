// The turn-tail usage control and its medium sheet, from the real composables.
// SPDX-License-Identifier: MIT
//
// `spec/ui/v1/pages/chat.json` `sheet-913` names `NativeTurnUsageDetails`; the
// detent site is `spec/ui/v1/tokens.json#interaction.sheet.pageDetents[id=turnUsage]`.
// The values assert the iOS `NativeTurnUsageDetails` projection, including the
// "missing cache bucket omits its row" branches.
package com.phonedsh.ui.surface

import androidx.activity.OnBackPressedDispatcherOwner
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.agentcore.JsonNumber
import com.phonedsh.agentcore.JsonObject
import com.phonedsh.agentcore.JsonString
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.page.ChatRowItem
import com.phonedsh.ui.projection.UiStateKind
import com.phonedsh.ui.projection.UiStateNode
import com.phonedsh.ui.sheet.SheetDetents
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.state.ChatScreenState
import com.phonedsh.ui.state.TurnUsage
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.generated.TokenDetent
import com.phonedsh.ui.theme.generated.TokenDetentSetId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w430dp-h932dp")
class TurnUsageSheetTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `a turn tail without usage shows no usage control`() {
        showTail(usage = null)
        compose.onNodeWithTag(UiTags.CHAT_TURN_USAGE).assertDoesNotExist()
    }

    @Test
    fun `the usage control opens the medium turnUsage sheet with the projected rows`() {
        showTail(usage = fullUsage())
        compose.onNodeWithText("用量 440 tok").assertIsDisplayed()
        compose.onNodeWithTag(UiTags.CHAT_TURN_USAGE).performClick()
        compose.waitForIdle()

        compose.onNodeWithTag(UiTags.TURN_USAGE_SHEET).assertExists()
        compose.onNodeWithText(UiStrings.TURN_USAGE_TITLE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.TURN_USAGE_CACHE_HIT).assertIsDisplayed()
        compose.onNodeWithText("75%").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.TURN_USAGE_UNCACHED_INPUT).assertIsDisplayed()
        compose.onNodeWithText("100 tok").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.TURN_USAGE_CACHE_READ).assertIsDisplayed()
        compose.onNodeWithText("300 tok").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.TURN_USAGE_CACHE_WRITE).assertIsDisplayed()
        compose.onNodeWithText("0 tok").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.TURN_USAGE_OUTPUT).assertIsDisplayed()
        compose.onNodeWithText("40 tok").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.TURN_USAGE_REASONING).assertIsDisplayed()
        compose.onNodeWithText("25 tok").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.TURN_USAGE_TOTAL).assertIsDisplayed()
        compose.onNodeWithText("440 tok").assertIsDisplayed()
    }

    @Test
    fun `the turnUsage page id is the frozen medium-only detent`() {
        val setId = SheetDetents.forPage(TURN_USAGE_PAGE_ID)
        assertEquals(TokenDetentSetId.MEDIUM, setId)
        assertEquals(listOf(TokenDetent.MEDIUM), SheetDetents.detents(setId))
        assertFalse(SheetDetents.skipPartiallyExpanded(setId))
    }

    @Test
    fun `token and percentage formats mirror the iOS helpers`() {
        assertEquals("999", formatTurnUsageCompactTokens(999))
        assertEquals("1.0K", formatTurnUsageCompactTokens(1_000))
        assertEquals("198K", formatTurnUsageCompactTokens(198_000))
        assertEquals("1.0M", formatTurnUsageCompactTokens(1_000_000))
        assertEquals("100", formatTurnUsagePercent(99.96))
        assertEquals("75", formatTurnUsagePercent(75.0))
        assertEquals("31", formatTurnUsagePercent(31.25))
        assertEquals("9.9", formatTurnUsagePercent(9.94))
    }

    @Test
    fun `absent cache buckets omit their rows like the iOS if let branches`() {
        showTail(usage = TurnUsage(inputTokens = 12, outputTokens = 34))
        compose.onNodeWithTag(UiTags.CHAT_TURN_USAGE).performClick()
        compose.waitForIdle()

        compose.onNodeWithText(UiStrings.TURN_USAGE_CACHE_HIT).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.TURN_USAGE_CACHE_READ).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.TURN_USAGE_CACHE_WRITE).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.TURN_USAGE_REASONING).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.TURN_USAGE_UNCACHED_INPUT).assertIsDisplayed()
        compose.onNodeWithText("12 tok").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.TURN_USAGE_OUTPUT).assertIsDisplayed()
        compose.onNodeWithText("34 tok").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.TURN_USAGE_TOTAL).assertIsDisplayed()
        compose.onNodeWithText("46 tok").assertIsDisplayed()
    }

    @Test
    fun `system back closes the sheet and leaves the tail control usable`() {
        showTail(usage = fullUsage())
        compose.onNodeWithTag(UiTags.CHAT_TURN_USAGE).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag(UiTags.TURN_USAGE_SHEET).assertExists()

        val dialog = ShadowDialog.getLatestDialog() as OnBackPressedDispatcherOwner
        dialog.onBackPressedDispatcher.onBackPressed()
        compose.mainClock.advanceTimeBy(2_000)
        compose.waitForIdle()
        compose.onNodeWithTag(UiTags.TURN_USAGE_SHEET).assertDoesNotExist()

        compose.onNodeWithTag(UiTags.CHAT_TURN_USAGE).performClick()
        compose.waitForIdle()
        compose.onNodeWithTag(UiTags.TURN_USAGE_SHEET).assertExists()
    }

    @Test
    fun `the ChatScreenState projection carries every usage bucket`() {
        val state = ChatScreenState.from(
            listOf(
                base(UiStateKind.ROOT, "root", "root", "-"),
                base(UiStateKind.SESSION, "session/s1", "root", "-"),
                base(UiStateKind.TURN, "session/s1/turn/turn-0001", "session/s1", "turn-0001"),
                base(
                    UiStateKind.BUBBLE,
                    "session/s1/turn/turn-0001/event/1/assistant-message",
                    "session/s1/turn/turn-0001",
                    "turn-0001",
                    text = "Done",
                    props = JsonObject(
                        mapOf(
                            "role" to JsonString("assistant"),
                            "usage" to JsonObject(
                                mapOf(
                                    "inputTokens" to JsonNumber("100"),
                                    "outputTokens" to JsonNumber("40"),
                                    "cacheReadTokens" to JsonNumber("300"),
                                    "cacheWriteTokens" to JsonNumber("0"),
                                    "reasoningTokens" to JsonNumber("25"),
                                ),
                            ),
                        ),
                    ),
                ),
                base(
                    UiStateKind.STATUS,
                    "session/s1/turn/turn-0001/event/2/turn-end",
                    "session/s1/turn/turn-0001",
                    "turn-0001",
                    text = "completed",
                    props = JsonObject(mapOf("reason" to JsonString("completed"))),
                ),
            ),
        )
        val usage = state.rows.filterIsInstance<ChatRow.TurnTail>().single().usage
        assertNotNull(usage)
        assertEquals(100L, usage?.inputTokens)
        assertEquals(40L, usage?.outputTokens)
        assertEquals(300L, usage?.cacheReadTokens)
        assertEquals(0L, usage?.cacheWriteTokens)
        assertEquals(25L, usage?.reasoningTokens)
        assertEquals(440L, usage?.totalTokens)
        assertEquals(75.0, usage?.cacheHitPercent ?: 0.0, 1e-9)
    }

    private fun fullUsage(): TurnUsage = TurnUsage(
        inputTokens = 100,
        outputTokens = 40,
        cacheReadTokens = 300,
        cacheWriteTokens = 0,
        reasoningTokens = 25,
    )

    private fun showTail(usage: TurnUsage?) {
        compose.setContent {
            PdshTheme(darkTheme = false) {
                ChatRowItem(
                    row = ChatRow.TurnTail(
                        id = "turn-tail/t1",
                        turnID = "t1",
                        assistantText = "Done",
                        usage = usage,
                    ),
                    expandedRowIds = emptySet(),
                    onToggleRow = {},
                )
            }
        }
        compose.waitForIdle()
    }

    private fun base(
        kind: UiStateKind,
        nodeID: String,
        parentID: String,
        turnID: String,
        text: String? = null,
        props: JsonObject = JsonObject(emptyMap()),
    ): UiStateNode = UiStateNode(
        kind = kind,
        nodeID = nodeID,
        parentID = parentID,
        sessionID = "s1",
        turnID = turnID,
        seq = 0,
        text = text,
        props = props,
    )
}
