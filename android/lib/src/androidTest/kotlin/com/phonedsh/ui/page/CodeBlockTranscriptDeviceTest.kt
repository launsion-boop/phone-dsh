// Verifies code-block scrolling in the real ChatPage LazyColumn on an Android device.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import android.util.Log
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.click
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.geometry.Offset
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.page.ChatPage
import com.phonedsh.ui.screenshot.ChatParitySamples
import com.phonedsh.ui.screenshot.ScreenshotActivity
import com.phonedsh.ui.state.ChatEmpty
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.surface.CODE_BLOCK_TAG
import com.phonedsh.ui.surface.CODE_COPY_TAG
import com.phonedsh.ui.surface.CODE_EXPAND_TAG
import com.phonedsh.ui.surface.CODE_WRAP_TAG
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CodeBlockTranscriptDeviceTest {
    @get:Rule val compose = createAndroidComposeRule<ScreenshotActivity>()

    @Test
    fun shortCodeBlockMeasuresInsideChatTranscriptWithoutCrashing() {
        mount("let answer = 42")
        scrollTo(CODE_BLOCK_TAG)
        compose.onNodeWithTag(CODE_BLOCK_TAG).assertIsDisplayed()
        compose.onNodeWithTag(CODE_WRAP_TAG).assertIsDisplayed()
        compose.onNodeWithTag(CODE_COPY_TAG).assertIsDisplayed()
        compose.onNodeWithTag(CODE_EXPAND_TAG).assertDoesNotExist()
    }

    @Test
    fun longCodeBlockCollapsesExpandsWrapsAndCollapsesInChatTranscript() {
        val body = (1..80).joinToString("\n") { line -> "let value$line = $line" }
        mount(body)

        scrollTo(CODE_EXPAND_TAG)
        compose.onNodeWithTag(CODE_BLOCK_TAG).assertIsDisplayed()
        compose.onNodeWithTag(CODE_EXPAND_TAG).assertIsDisplayed()
        compose.onNodeWithTag(CODE_EXPAND_TAG).performTouchInput { click() }
        compose.onNodeWithText(UiStrings.CODE_COLLAPSE).assertIsDisplayed()
        compose.onNodeWithText("let value80 = 80", substring = true).assertExists()

        // Expanded content belongs to the transcript scroller. The controls remain
        // reachable while wrapping changes, with no nested unbounded vertical scroll.
        scrollTo(CODE_WRAP_TAG)
        compose.onNodeWithTag(CODE_WRAP_TAG).performScrollTo().assertIsDisplayed()
            .performTouchInput { click() }
        compose.onNodeWithContentDescription(UiStrings.CODE_WRAP_ON).assertExists()
        scrollTo(CODE_EXPAND_TAG)
        val footer = compose.onNodeWithTag(CODE_EXPAND_TAG).performScrollTo().assertIsDisplayed()
            .fetchSemanticsNode().boundsInRoot
        val root = compose.onRoot().fetchSemanticsNode().boundsInRoot
        val latestPill = compose.onNodeWithTag(UiPageTags.CHAT_BACK_TO_LATEST).fetchSemanticsNode().boundsInRoot
        val footerEdgeTapInRoot = Offset(x = footer.left + 24f, y = footer.center.y)
        Log.i("CodeBlockBoundsProof", "root=$root footer=$footer latestPill=$latestPill edgeTap=$footerEdgeTapInRoot")
        assertFalse(
            "the pointer target must stay outside the floating latest pill: root=$root footer=$footer latest=$latestPill tap=$footerEdgeTapInRoot",
            latestPill.contains(footerEdgeTapInRoot),
        )
        compose.onNodeWithTag(CODE_EXPAND_TAG)
            // The floating latest pill covers the centered label while this long
            // expanded row is at the viewport tail. Tap the exposed edge of the
            // real full-width collapse control, away from that overlapping pill.
            .performTouchInput { click(Offset(x = 24f, y = center.y)) }
        compose.waitForIdle()
        compose.onNodeWithText(UiStrings.CODE_EXPAND_ALL.format(80)).assertExists().performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag(CODE_EXPAND_TAG).assertIsDisplayed()
        compose.onNodeWithTag(CODE_BLOCK_TAG).assertIsDisplayed()
    }

    private fun mount(body: String) {
        val state = ChatParitySamples.chatAssistant().copy(
            rows = listOf(ChatRow.Assistant("row-code-device", "```swift\n$body\n```", closing = true)),
            empty = ChatEmpty.READY,
        )
        compose.setContent {
            PdshTheme {
                ChatPage(
                    state = state,
                    onDraftChange = {},
                    onSend = {},
                    onStop = {},
                    onToggleRow = {},
                    onApprove = {},
                    onDeny = {},
                    onDismissBanner = {},
                    onRetry = {},
                    onOpenSessions = {},
                    title = ChatParitySamples.TITLE,
                    onConfigureProvider = {},
                )
            }
        }
        compose.waitForIdle()
    }

    private fun scrollTo(tag: String) {
        compose.onNodeWithTag(UiTags.CHAT_LIST).performScrollToNode(hasTestTag(tag))
    }
}
