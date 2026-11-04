// Verifies modal pointer behavior on Android's real Compose window.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertWidthIsEqualTo
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.click
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.screenshot.ScreenshotActivity
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import androidx.compose.ui.unit.dp

@RunWith(AndroidJUnit4::class)
class SubagentCatalogDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<ScreenshotActivity>()

    @Test
    fun idleWorkerTapForwardsItsIdentityAndKeepsTheSheetOpenOnHostFailure() {
        var openedWorker: String? = null
        var dismissCount = 0
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
                    currentWorkerSessionId = "worker-parent",
                    onDismiss = { dismissCount++ },
                    onOpen = { entry ->
                        openedWorker = entry.workerSessionId
                        "History read failed; current chat was kept"
                    },
                )
            }
        }

        compose.onNodeWithTag(SUBAGENT_CATALOG_SHEET_TAG).assertIsDisplayed()
            .assertHeightIsAtLeast(600.dp)
        compose.onNodeWithTag(SUBAGENT_CATALOG_CARD_TAG).assertWidthIsEqualTo(336.dp)
        compose.onNodeWithContentDescription("Read the source · 可继续 · 当前未运行")
            .performTouchInput { click() }
        compose.waitUntil(5_000) { openedWorker != null }
        compose.onNodeWithText("History read failed; current chat was kept").assertIsDisplayed()
        assertEquals("worker-child", openedWorker)
        assertEquals(0, dismissCount)
    }

    @Test
    fun unknownOrRunningWorkerRowsDoNotForwardNativeTouches() {
        var openedWorker: String? = null
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
                    onOpen = { entry -> openedWorker = entry.workerSessionId; null },
                )
            }
        }

        val unconfirmed = compose.onNodeWithContentDescription("Not confirmed · 可继续 · 未确认会话")
        unconfirmed.assertIsNotEnabled().performTouchInput { click() }
        val running = compose.onNodeWithContentDescription("Running · 可继续 · 正在运行")
        running.assertIsNotEnabled().performTouchInput { click() }
        assertEquals(null, openedWorker)
    }
}
