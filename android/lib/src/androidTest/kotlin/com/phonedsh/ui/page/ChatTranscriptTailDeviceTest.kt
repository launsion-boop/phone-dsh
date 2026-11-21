// Tail-follow behavior on Android's real LazyColumn, including async image sizing.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.screenshot.ChatParitySamples
import com.phonedsh.ui.screenshot.ScreenshotActivity
import com.phonedsh.ui.state.ChatEmpty
import com.phonedsh.ui.state.ChatRow
import com.phonedsh.ui.state.ChatScreenState
import com.phonedsh.ui.surface.LocalMarkdownRemoteImageLoader
import com.phonedsh.ui.surface.MARKDOWN_IMAGE_LOADING_TAG
import com.phonedsh.ui.surface.MARKDOWN_IMAGE_TAG
import com.phonedsh.ui.surface.MarkdownImageSource
import com.phonedsh.ui.surface.MarkdownRemoteImageLoader
import com.phonedsh.ui.theme.PdshTheme
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class ChatTranscriptTailDeviceTest {
    @get:Rule
    val compose = createAndroidComposeRule<ScreenshotActivity>()

    @Test
    fun sameIdStreamingGrowthAtTailFollowsTheNewContent() {
        val state = mutableStateOf(chatState("session-A", longAssistant("streaming-tail", 180, "STREAM_TAIL_A")))
        mount(state)
        awaitTextAtTail("STREAM_TAIL_A")
        assertPillAbsent()

        val previous = state.value.rows.single() as ChatRow.Assistant
        compose.runOnIdle {
            state.value = state.value.copy(
                rows = listOf(previous.copy(text = previous.text + "\n\n" + longAssistant("", 80, "STREAM_TAIL_B").text)),
            )
        }
        awaitTextAtTail("STREAM_TAIL_B")
        assertPillAbsent()
    }

    @Test
    fun scrolledUpReaderStaysStableAcrossSameIdGrowthAndReturnLatestWorks() {
        val state = mutableStateOf(chatState("session-A", longAssistant("streaming-tail", 180, "AWAY_TAIL_A")))
        mount(state)
        awaitTextAtTail("AWAY_TAIL_A")

        scrollAwayUntilPill()
        val before = bodyBounds().top

        val previous = state.value.rows.single() as ChatRow.Assistant
        compose.runOnIdle {
            state.value = state.value.copy(
                rows = listOf(previous.copy(text = previous.text + "\n\n" + longAssistant("", 80, "AWAY_TAIL_B").text)),
            )
        }
        compose.waitForIdle()
        compose.onNodeWithTag(UiPageTags.CHAT_BACK_TO_LATEST).assertIsDisplayed()
        val after = bodyBounds().top
        assertTrue("same-id growth must not jump the reader's visible content", abs(after - before) <= 3f)

        compose.onNodeWithTag(UiPageTags.CHAT_BACK_TO_LATEST).performClick()
        awaitTextAtTail("AWAY_TAIL_B")
        assertPillAbsent()
    }

    @Test
    fun switchingSessionAfterReadingAwayOpensTheNewSessionAtItsTail() {
        val state = mutableStateOf(chatState("session-A", longAssistant("shared-row-id", 180, "SESSION_A_TAIL")))
        mount(state)
        awaitTextAtTail("SESSION_A_TAIL")
        scrollAwayUntilPill()

        compose.runOnIdle {
            state.value = chatState("session-B", longAssistant("shared-row-id", 120, "SESSION_B_TAIL"))
        }
        awaitTextAtTail("SESSION_B_TAIL")
        assertPillAbsent()
    }

    @Test
    fun asyncImageHeightGrowthKeepsFollowingReaderAtTheTail() {
        val requested = CompletableDeferred<Unit>()
        val imageBytes = CompletableDeferred<Bitmap?>()
        val loader = MarkdownRemoteImageLoader {
            requested.complete(Unit)
            imageBytes.await()
        }
        val markdown = "Image fixture before load.\n\n![loaded fixture](https://scripted.invalid/tall.png)"
        val state = mutableStateOf(chatState("session-image", ChatRow.Assistant("image-tail", markdown)))
        mount(state, loader = loader, imageSource = MarkdownImageSource())
        compose.waitUntil(5_000) {
            compose.onAllNodesWithTag(MARKDOWN_IMAGE_LOADING_TAG, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()
        }
        compose.waitUntil(5_000) { requested.isCompleted }
        val loading = compose.onNodeWithTag(MARKDOWN_IMAGE_LOADING_TAG, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        val bitmap = Bitmap.createBitmap(1800, 900, Bitmap.Config.ARGB_8888).apply {
            eraseColor(android.graphics.Color.MAGENTA)
        }
        imageBytes.complete(bitmap)
        compose.waitUntil(5_000) {
            compose.onAllNodesWithTag(MARKDOWN_IMAGE_TAG, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()
        }
        val loaded = compose.onNodeWithTag(MARKDOWN_IMAGE_TAG, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        assertTrue("the scripted image must change the measured row height", loaded.height > loading.height + 100f)
        awaitImageAtTail()
        assertPillAbsent()
    }

    private fun mount(
        state: MutableState<ChatScreenState>,
        loader: MarkdownRemoteImageLoader? = null,
        imageSource: MarkdownImageSource? = null,
    ) {
        compose.setContent {
            val content: @Composable () -> Unit = {
                PdshTheme(darkTheme = false) {
                    ChatPage(
                        state = state.value,
                        onDraftChange = {}, onSend = {}, onStop = {}, onToggleRow = {},
                        onApprove = {}, onDeny = {}, onDismissBanner = {}, onRetry = {},
                        onOpenSessions = {}, title = ChatParitySamples.TITLE,
                        imageSource = imageSource,
                    )
                }
            }
            if (loader == null) content()
            else CompositionLocalProvider(LocalMarkdownRemoteImageLoader provides loader) { content() }
        }
        compose.waitForIdle()
    }

    private fun chatState(session: String, row: ChatRow.Assistant): ChatScreenState =
        ChatParitySamples.chatAssistant().copy(
            sessionID = session,
            rows = listOf(row),
            expandedRowIds = emptySet(),
            empty = ChatEmpty.READY,
            composer = ChatParitySamples.chatAssistant().composer.copy(draft = "", canSubmit = false),
        )

    private fun longAssistant(id: String, repeat: Int, tail: String): ChatRow.Assistant = ChatRow.Assistant(
        id = id,
        text = "这是一条持续增长的同一条回答，用于验证长消息末尾的跟随位置。".repeat(repeat) + "\n\n" + tail,
        streaming = true,
    )

    private fun bodyBounds() = compose.onNodeWithTag(UiTags.BUBBLE, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot

    private fun awaitTextAtTail(text: String) {
        compose.waitUntil(10_000) {
            compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(text).assertIsDisplayed()
    }

    private fun awaitImageAtTail() {
        compose.waitUntil(5_000) {
            val images = compose.onAllNodesWithTag(MARKDOWN_IMAGE_TAG, useUnmergedTree = true).fetchSemanticsNodes()
            if (images.isEmpty()) return@waitUntil false
            val list = compose.onNodeWithTag(UiTags.CHAT_LIST).fetchSemanticsNode().boundsInRoot
            val image = images.last().boundsInRoot
            val gapDp = (list.bottom - image.bottom) / compose.activity.resources.displayMetrics.density
            abs(gapDp - 48f) <= 12f
        }
    }

    private fun waitForLatestPill() {
        compose.waitUntil(5_000) {
            compose.onAllNodesWithTag(UiPageTags.CHAT_BACK_TO_LATEST).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag(UiPageTags.CHAT_BACK_TO_LATEST).assertIsDisplayed()
    }

    private fun scrollAwayUntilPill() {
        repeat(10) {
            if (compose.onAllNodesWithTag(UiPageTags.CHAT_BACK_TO_LATEST).fetchSemanticsNodes().isNotEmpty()) return
            compose.onNodeWithTag(UiTags.CHAT_LIST).performTouchInput { swipeDown(durationMillis = 700) }
            compose.waitForIdle()
        }
        waitForLatestPill()
    }

    private fun assertPillAbsent() {
        assertEquals(
            0,
            compose.onAllNodesWithTag(UiPageTags.CHAT_BACK_TO_LATEST).fetchSemanticsNodes().size,
        )
    }
}
