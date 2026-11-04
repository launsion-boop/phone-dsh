// Device interaction proof for source-backed composer metric detail sheets.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.screenshot.ChatParitySamples
import com.phonedsh.ui.screenshot.ScreenshotActivity
import com.phonedsh.ui.state.ComposerStatsMode
import com.phonedsh.ui.state.ContextBreakdown
import com.phonedsh.ui.state.ContextPressure
import com.phonedsh.ui.state.SessionStats
import com.phonedsh.ui.state.SessionTokenUsage
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SessionMetricsDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<ScreenshotActivity>()

    @Test
    fun detailChipsOpenTheirOwnMediumSheetAndDoneReturnsToComposer() {
        mount(ComposerStatsMode.DETAILED)
        listOf(
            Triple("activity", "会话统计", "模型用时"),
            Triple("usage", "Token 用量", "未缓存输入"),
            Triple("context", "上下文", "估算用量 / 容量"),
        ).forEach { (id, title, row) ->
            compose.onNodeWithTag("pdsh.composer.metrics.$id").assertIsDisplayed().performClick()
            compose.onNodeWithText(title).assertIsDisplayed()
            compose.onNodeWithText(row).assertIsDisplayed()
            val titleTop = compose.onNodeWithText(title).fetchSemanticsNode().boundsInRoot.top
            val height = compose.activity.resources.displayMetrics.heightPixels.toFloat()
            assertTrue("the metric detail uses the source's medium presentation", titleTop > height * 0.35f)
            compose.onNodeWithTag("pdsh.composer.metrics.done").performClick()
            compose.waitForIdle()
            compose.onNodeWithTag("pdsh.composer.metrics.done").assertDoesNotExist()
        }
    }

    @Test
    fun compactPresentationShowsHostSpeedAndCacheWithoutDetailActions() {
        mount(ComposerStatsMode.COMPACT)
        compose.onNodeWithTag("pdsh.composer.metrics.compact").assertIsDisplayed()
        compose.onNodeWithText("50 tok/s").assertIsDisplayed()
        compose.onNodeWithTag("pdsh.composer.metrics.activity").assertDoesNotExist()
        compose.onNodeWithTag("pdsh.composer.metrics.usage").assertDoesNotExist()
        compose.onNodeWithTag("pdsh.composer.metrics.context").assertDoesNotExist()
    }

    private fun mount(mode: ComposerStatsMode) {
        val state = ChatParitySamples.chatAssistant().copy(
            sessionStats = SessionStats(2, 8, 12_000.0, 2_000.0, 800.0, 4, 60_000.0, 3_000),
            tokenUsage = SessionTokenUsage(2_400, 1_000, 3_500, 600),
            contextPressure = ContextPressure(6_000, 8_000, 32_000),
            contextBreakdown = ContextBreakdown(1_000, 2_000, 5_000),
            composerStatsMode = mode,
        )
        compose.setContent {
            PdshTheme(darkTheme = false) {
                ChatPage(
                    state = state, onDraftChange = {}, onSend = {}, onStop = {},
                    onToggleRow = {}, onApprove = {}, onDeny = {}, onDismissBanner = {},
                    onRetry = {}, onOpenSessions = {}, title = ChatParitySamples.TITLE,
                )
            }
        }
        compose.waitForIdle()
    }
}
