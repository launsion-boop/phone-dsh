// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.menu.ContextMenuModel
import com.phonedsh.ui.menu.ContextMenuRowState
import com.phonedsh.ui.menu.ContextMenuTags
import com.phonedsh.ui.sheet.PdshSheetTags
import com.phonedsh.ui.sheet.SheetDetents
import com.phonedsh.ui.theme.PdshTheme
import com.phonedsh.ui.theme.generated.TokenContextMenuWhen
import com.phonedsh.ui.theme.generated.TokenDetentSetId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class SubagentCatalogTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun `verified projection row exposes enabled accessible open action`() {
        var opened: String? = null
        val entry = ChatSubagentEntry(
            workerSessionId = "worker-child",
            label = "Read the source",
            mode = ChatSubagentEntry.MODE_CONTINUABLE,
            parentSessionId = "worker-parent",
            running = false,
            workerSessionKnown = true,
        )
        compose.setContent {
            PdshTheme {
                SubagentCatalogDialog(
                    entries = listOf(entry),
                    currentWorkerSessionId = "worker-parent",
                    onDismiss = {},
                    onOpen = { row -> opened = row.workerSessionId; "keep open for assertion" },
                )
            }
        }
        assertTrue(entry.canOpen)
        compose.onNodeWithTag(SUBAGENT_CATALOG_CARD_TAG).assertWidthIsEqualTo(336.dp)
        compose.onNodeWithText("Read the source").assertIsDisplayed()
        compose.onNodeWithText("可继续").assertIsDisplayed()
        compose.onNodeWithText("当前未运行").assertIsDisplayed()
        compose.onNodeWithContentDescription("Read the source · 可继续 · 当前未运行")
            .assertHasClickAction()
            .assertIsEnabled()
        assertNull(opened)
    }

    @Test
    fun `unconfirmed or running Worker identities remain visible but cannot open`() {
        compose.setContent {
            PdshTheme {
                SubagentCatalogDialog(
                    entries = listOf(
                        ChatSubagentEntry(
                            workerSessionId = "worker-unknown",
                            label = "Not confirmed",
                            mode = ChatSubagentEntry.MODE_CONTINUABLE,
                            running = null,
                            workerSessionKnown = null,
                        ),
                        ChatSubagentEntry(
                            workerSessionId = "worker-running",
                            label = "Running",
                            mode = ChatSubagentEntry.MODE_CONTINUABLE,
                            running = true,
                            workerSessionKnown = true,
                        ),
                    ),
                    currentWorkerSessionId = null,
                    onDismiss = {},
                    onOpen = { "unexpected" },
                )
            }
        }
        compose.onNodeWithText("Not confirmed").assertIsDisplayed()
        compose.onNodeWithText("未确认会话").assertIsDisplayed()
        compose.onNodeWithContentDescription("Not confirmed · 可继续 · 未确认会话").assertIsNotEnabled()
        compose.onNodeWithText("正在运行").assertIsDisplayed()
        compose.onNodeWithContentDescription("Running · 可继续 · 正在运行").assertIsNotEnabled()
    }

    @Test
    fun `the catalog sheet uses the chat page id detents and catalog chrome`() {
        val setId = SheetDetents.forPage(SUBAGENT_CATALOG_CHAT_PAGE_ID)
        assertEquals(TokenDetentSetId.MEDIUM_LARGE, setId)
        assertFalse(
            "medium+large keeps the platform partial anchor",
            SheetDetents.skipPartiallyExpanded(setId),
        )
        compose.setContent {
            PdshTheme {
                SubagentCatalogDialog(
                    entries = listOf(
                        ChatSubagentEntry(
                            workerSessionId = "worker-child",
                            label = "Read the source",
                            mode = ChatSubagentEntry.MODE_CONTINUABLE,
                            running = false,
                            workerSessionKnown = true,
                        ),
                    ),
                    currentWorkerSessionId = null,
                    onDismiss = {},
                    onOpen = { "keep open for assertion" },
                )
            }
        }
        compose.waitForIdle()
        compose.onNodeWithTag(SUBAGENT_CATALOG_SHEET_TAG).assertExists()
        compose.onNodeWithTag(SUBAGENT_CATALOG_CARD_TAG).assertWidthIsEqualTo(336.dp)
        // SheetChrome.SubagentCatalog: the grabber is explicitly hidden.
        compose.onNodeWithTag(PdshSheetTags.DRAG_HANDLE, useUnmergedTree = true).assertDoesNotExist()
    }

    @Test
    fun `long pressing a row opens only the subagentRow action Android owns`() {
        var opened = false
        compose.setContent {
            PdshTheme {
                SubagentCatalogDialog(
                    entries = listOf(
                        ChatSubagentEntry(
                            workerSessionId = "worker-child",
                            label = "Read the source",
                            mode = ChatSubagentEntry.MODE_CONTINUABLE,
                            running = false,
                            workerSessionKnown = true,
                        ),
                    ),
                    currentWorkerSessionId = null,
                    onDismiss = {},
                    onOpen = { opened = true; "keep open for assertion" },
                )
            }
        }
        val visible = ContextMenuModel.items(
            "subagentRow",
            ContextMenuRowState.of(
                TokenContextMenuWhen.NOT_EXTERNAL to true,
                TokenContextMenuWhen.HAS_ASIDE to false,
            ),
        )
        assertEquals("Android has the open action but no aside destination", 1, visible.size)
        // Robolectric does not route touches into the modal sheet's dialog window;
        // the row's own long-click semantics is the same gesture callback rule 1 uses.
        compose.onNodeWithContentDescription("Read the source · 可继续 · 当前未运行")
            .performSemanticsAction(SemanticsActions.OnLongClick)
        // The sheet's popup lives in its own window; existence is the JVM-observable
        // part, visibility of that window is platform chrome.
        compose.onNodeWithText(visible.single().label).assertExists()
        compose.onNodeWithText("在侧边栏打开").assertDoesNotExist()
        compose.onNodeWithText(visible.single().label).performClick()
        compose.waitForIdle()
        assertTrue(opened)
        compose.onNodeWithTag(ContextMenuTags.MENU).assertDoesNotExist()
    }
}
