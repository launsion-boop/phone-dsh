// ExportPage: the baseline open-writes behaviour, the report and the preview.
// SPDX-License-Identifier: MIT
//
// `spec/ui/v1/README.md` §3.1 rule 3: the export page has no harness event anchor,
// so the host snapshot is the UiState-side input and the same snapshot sequence
// must replay to the same ScreenState sequence.
//
// The first test is the one this lane restored: the baseline writes in
// `.onAppear`, so opening the page must call the write side effect once before
// any tap. The visible 写报告 button stays as the "write again" action.
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
class ExportPageTest {
    @get:Rule
    val compose = createComposeRule()

    private val fileName: String = "report-2026-10-31.json"

    private fun previewText(lines: Int): String = (1..lines).joinToString("\n") { "line $it" }

    private fun measuredSnapshot(): ExportSnapshot = ExportSnapshot(
        reportStatus = "已测量",
        environment = "android/robolectric",
        device = "Pixel 8",
        formatVersion = "1",
        written = FactState.YES,
        fileName = fileName,
        preview = previewText(3),
    )

    private fun show(
        state: ExportScreenState,
        onWrite: () -> Unit = {},
        onOpen: (() -> Unit)? = {},
        onShare: (() -> Unit)? = null,
        onRetry: (() -> Unit)? = null,
        onDismissFailure: (() -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                ExportPage(
                    state = state,
                    onBack = {},
                    onWrite = onWrite,
                    onOpen = onOpen,
                    onShare = onShare,
                    onRetry = onRetry,
                    onDismissFailure = onDismissFailure,
                )
            }
        }
    }

    /** Scroll one tagged row into the viewport before asserting it is displayed. */
    private fun scrollTo(tag: String) {
        compose.onNodeWithTag(UiPageTags.EXPORT_LIST).performScrollToNode(hasTestTag(tag))
        compose.onNodeWithTag(tag).assertIsDisplayed()
    }

    private fun textShown(text: String): Boolean =
        compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()

    private fun textContained(text: String): Boolean =
        compose.onAllNodesWithText(text, substring = true).fetchSemanticsNodes().isNotEmpty()

    // --------------------------------------------------------------- baseline

    @Test
    fun `opening the page writes once before any tap`() {
        var opened = 0
        var written = 0
        show(
            ExportScreenState.from(ExportFacts(snapshot = measuredSnapshot())),
            onWrite = { written += 1 },
            onOpen = { opened += 1 },
        )
        compose.waitForIdle()
        assertEquals(1, opened)
        assertEquals(0, written)

        scrollTo(UiPageTags.EXPORT_WRITE)
        compose.onNodeWithTag(UiPageTags.EXPORT_WRITE).performClick()
        assertEquals(1, opened)
        assertEquals(1, written)
    }

    @Test
    fun `a measured report shows the facts the file the actions and the preview`() {
        val state = ExportScreenState.from(ExportFacts(snapshot = measuredSnapshot()))
        assertEquals(ExportStatus.READY, state.status)
        assertEquals(3, state.previewLines.size)
        assertTrue(state.canShare)
        var shared = 0
        show(state, onShare = { shared += 1 })

        scrollTo(UiPageTags.EXPORT_STATUS)
        assertTrue(textShown("已测量"))
        scrollTo(UiPageTags.EXPORT_ENVIRONMENT)
        assertTrue(textShown("android/robolectric"))
        scrollTo(UiPageTags.EXPORT_DEVICE)
        assertTrue(textShown("Pixel 8"))
        scrollTo(UiPageTags.EXPORT_FORMAT_VERSION)
        assertTrue(textShown("1"))
        scrollTo(UiPageTags.EXPORT_FILE)
        assertTrue(textShown(fileName))
        assertTrue(textShown(UiStrings.EXPORT_PREVIEW_NOTE))
        scrollTo(UiPageTags.EXPORT_PREVIEW_TEXT)
        assertTrue(textContained("line 1"))
        scrollTo(UiPageTags.EXPORT_SHARE)
        compose.onNodeWithTag(UiPageTags.EXPORT_SHARE).performClick()
        assertEquals(1, shared)
    }

    @Test
    fun `a long preview is truncated in the state and says how many lines are left`() {
        val state = ExportScreenState.from(
            ExportFacts(
                snapshot = measuredSnapshot().copy(
                    preview = previewText(85),
                    written = FactState.NO,
                    fileName = null,
                    writeError = "磁盘写入失败",
                ),
            ),
        )
        assertEquals(80, state.previewLines.size)
        assertEquals(5, state.hiddenLines)
        assertFalse(state.canShare)
        show(state)

        compose.onNodeWithTag(UiPageTags.EXPORT_SHARE).assertDoesNotExist()
        scrollTo(UiPageTags.EXPORT_FILE)
        assertTrue(textShown(UiStrings.EXPORT_FILE_NOT_WRITTEN))
        scrollTo(UiPageTags.EXPORT_WRITE_FAILED)
        assertTrue(textShown("磁盘写入失败"))
        scrollTo(UiPageTags.EXPORT_PREVIEW_TEXT)
        assertTrue(textContained("line 80"))
        assertFalse(textContained("line 81"))
        compose.onNodeWithTag(UiPageTags.EXPORT_PREVIEW_MORE).assertExists()
        assertTrue(textShown(UiStrings.EXPORT_PREVIEW_MORE.format(5)))
    }

    @Test
    fun `an unreported report keeps the baseline rows and never invents a file`() {
        val state = ExportScreenState.from(ExportFacts())
        assertEquals(ExportStatus.UNKNOWN, state.status)
        assertFalse(state.canShare)
        show(state)

        scrollTo(UiPageTags.EXPORT_STATUS)
        assertTrue(textShown(UiStrings.UNKNOWN))
        scrollTo(UiPageTags.EXPORT_FILE)
        assertTrue(textShown(UiStrings.UNKNOWN))
        scrollTo(UiPageTags.EXPORT_WRITE)
        scrollTo(UiPageTags.EXPORT_PREVIEW)
        assertTrue(textShown(UiStrings.UNKNOWN))
        compose.onNodeWithTag(UiPageTags.EXPORT_PREVIEW_TEXT).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.EXPORT_SHARE).assertDoesNotExist()
        assertFalse(textShown(fileName))
    }

    @Test
    fun `a failed read adds the fail-loud line and offers a retry`() {
        val state = ExportScreenState.from(
            ExportFacts(snapshot = measuredSnapshot(), failure = "读取失败：报告目录不可读"),
        )
        assertEquals(ExportStatus.FAILED, state.status)
        var retried = 0
        var dismissed = 0
        show(state, onRetry = { retried += 1 }, onDismissFailure = { dismissed += 1 })

        compose.onNodeWithTag(UiPageTags.EXPORT_FAILURE).assertIsDisplayed()
        assertTrue(textShown("读取失败：报告目录不可读"))
        compose.onNodeWithText(UiStrings.RETRY).performClick()
        compose.onNodeWithContentDescription(UiStrings.DISMISS).performClick()
        assertEquals(1, retried)
        assertEquals(1, dismissed)
    }

    @Test
    fun `the screen state sequence is a pure function of the facts script`() {
        val script = listOf(
            ExportFacts(),
            ExportFacts(snapshot = ExportSnapshot()),
            ExportFacts(snapshot = measuredSnapshot()),
            ExportFacts(snapshot = measuredSnapshot().copy(preview = previewText(85))),
            ExportFacts(snapshot = measuredSnapshot(), failure = "读取失败"),
            ExportFacts(),
        )

        fun run(): List<ExportScreenState> = script.map { ExportScreenState.from(it) }

        val states = run()
        assertEquals(
            listOf(
                ExportStatus.UNKNOWN,
                ExportStatus.EMPTY,
                ExportStatus.READY,
                ExportStatus.READY,
                ExportStatus.FAILED,
                ExportStatus.UNKNOWN,
            ),
            states.map { it.status },
        )
        assertEquals(80, states[3].previewLines.size)
        assertEquals(5, states[3].hiddenLines)
        assertEquals(states.map { it.signature() }, run().map { it.signature() })
        assertEquals(states.map { it.hasUnmeasuredValues }, run().map { it.hasUnmeasuredValues })
    }
}
