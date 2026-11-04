// Focused on-device visuals and the host-backed More menu selection.
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import android.graphics.Bitmap
import java.io.File
import java.io.FileOutputStream
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.page.CollapseTiming.COMPLETION
import com.phonedsh.ui.page.CollapseTiming.NEXT_INPUT
import com.phonedsh.ui.screenshot.ChatParitySamples
import com.phonedsh.ui.screenshot.ScreenshotActivity
import com.phonedsh.ui.state.ChatEmpty
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ChatPageVisualDeviceTest {
    @get:Rule
    val compose = createAndroidComposeRule<ScreenshotActivity>()

    @Test
    fun firstLaunchVisualMatchesProviderSourceAndComposerMetrics() {
        val state = ChatParitySamples.chatAssistant().copy(
            rows = emptyList(),
            empty = ChatEmpty.PROVIDER_SETUP,
            composer = ChatParitySamples.chatAssistant().composer.copy(draft = "", canSubmit = false),
        )
        compose.setContent {
            PdshTheme(darkTheme = false) {
                ChatPage(
                    state = state,
                    onDraftChange = {}, onSend = {}, onStop = {}, onToggleRow = {},
                    onApprove = {}, onDeny = {}, onDismissBanner = {}, onRetry = {},
                    onOpenSessions = {}, title = ChatParitySamples.TITLE,
                    onConfigureProvider = {},
                )
            }
        }
        compose.waitForIdle()

        val title = compose.onNodeWithText(UiStrings.PROVIDER_SETUP_TITLE).fetchSemanticsNode().boundsInRoot
        val action = compose.onNodeWithText(UiStrings.PROVIDER_SETUP_ACTION).fetchSemanticsNode().boundsInRoot
        val composer = compose.onNodeWithTag("pdsh.composer.card").fetchSemanticsNode().boundsInRoot
        val screen = compose.activity.resources.displayMetrics
        val density = screen.density
        saveCapture(
            "chat-provider-first-launch",
            """screen=${screen.widthPixels}x${screen.heightPixels}
density=$density
providerTitleBoundsPx=$title
providerActionLabelBoundsPx=$action
composerCardBoundsPx=$composer
""",
        )
        assertTrue("the setup title must precede its action", title.top < action.top)
        assertTrue("the setup action must remain above the composer", action.bottom < composer.top)
        assertEquals("the open composer should preserve the source's intrinsic 56pt text port plus controls", 116f, composer.height / density, 1.5f)
    }

    @Test
    fun unknownCollapseTimingHasDisabledChoicesAndNoSelectionMark() {
        mountMenu(collapseTiming = null, onSetCollapseTiming = null)
        compose.onNodeWithTag(MORE_MENU_TAG).performClick()
        val completion = compose.onNodeWithTag(collapseTimingTag(COMPLETION))
        val nextInput = compose.onNodeWithTag(collapseTimingTag(NEXT_INPUT))
        completion.assertIsDisplayed().assertIsNotEnabled()
        nextInput.assertIsDisplayed().assertIsNotEnabled()
        assertTrue(compose.onAllNodesWithContentDescription(SELECTED_MENU_ACCESSIBILITY).fetchSemanticsNodes().isEmpty())
    }

    @Test
    fun collapseTimingChoiceReportsToHostWithoutOptimisticSelection() {
        val writes = mutableListOf<CollapseTiming>()
        mountMenu(collapseTiming = NEXT_INPUT, onSetCollapseTiming = writes::add)
        compose.onNodeWithTag(MORE_MENU_TAG).performClick()
        compose.onNodeWithTag(collapseTimingTag(COMPLETION)).assertIsEnabled().performClick()
        compose.waitForIdle()
        assertEquals(listOf(COMPLETION), writes)

        // The page waits for a new host value. Reopening with the same host input
        // must still show NEXT_INPUT selected until the host reports the write.
        compose.onNodeWithTag(MORE_MENU_TAG).performClick()
        compose.onNodeWithTag(collapseTimingTag(COMPLETION)).assertIsEnabled()
        compose.onNodeWithTag(collapseTimingTag(NEXT_INPUT)).assertIsEnabled()
        val selected = compose.onAllNodesWithContentDescription(SELECTED_MENU_ACCESSIBILITY).fetchSemanticsNodes()
        assertEquals(1, selected.size)
        val nextInputBounds = compose.onNodeWithTag(collapseTimingTag(NEXT_INPUT)).fetchSemanticsNode().boundsInRoot
        val selectedBounds = selected.single().boundsInRoot
        assertTrue(selectedBounds.width > 0f)
        assertTrue("the checked icon belongs to the host-reported NEXT_INPUT row", nextInputBounds.contains(selectedBounds.center))
    }

    private fun mountMenu(collapseTiming: CollapseTiming?, onSetCollapseTiming: ((CollapseTiming) -> Unit)?) {
        val state = ChatParitySamples.chatAssistant().copy(
            rows = emptyList(),
            empty = ChatEmpty.PROVIDER_SETUP,
            composer = ChatParitySamples.chatAssistant().composer.copy(draft = "", canSubmit = false),
        )
        compose.setContent {
            PdshTheme(darkTheme = false) {
                ChatPage(
                    state = state,
                    onDraftChange = {}, onSend = {}, onStop = {}, onToggleRow = {},
                    onApprove = {}, onDeny = {}, onDismissBanner = {}, onRetry = {},
                    onOpenSessions = {}, title = ChatParitySamples.TITLE,
                    collapseTiming = collapseTiming,
                    onSetCollapseTiming = onSetCollapseTiming,
                )
            }
        }
        compose.waitForIdle()
    }

    private fun saveCapture(name: String, receipt: String) {
        val context = InstrumentationRegistry.getInstrumentation().context
        val directory = File(requireNotNull(context.getExternalFilesDir(null)), "chat-visual-evidence")
        check(directory.mkdirs() || directory.isDirectory)
        File(directory, "$name.txt").writeText(receipt)
        val bitmap: Bitmap = compose.onNodeWithTag(UiTags.CHAT_ROOT).captureToImage().asAndroidBitmap()
        FileOutputStream(File(directory, "$name.png")).use { output ->
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
        }
        bitmap.recycle()
    }

    private companion object {
        const val MORE_MENU_TAG = "pdsh.chat.header.menu"
        const val SELECTED_MENU_ACCESSIBILITY = "当前选择"
        fun collapseTimingTag(value: CollapseTiming): String = "pdsh.chat.header.collapse-timing.${value.id}"
    }
}
