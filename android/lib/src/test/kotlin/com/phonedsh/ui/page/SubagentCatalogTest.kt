// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.theme.PdshTheme
import androidx.compose.ui.unit.dp
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
}
