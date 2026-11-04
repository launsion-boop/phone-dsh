// SessionArtifactPreviewPage: the preview subpage of `SessionArtifactsPage.swift:296`–`:319`.
// SPDX-License-Identifier: MIT
//
// The subpage is `private` in `SessionArtifactsPage.kt` (the baseline's own
// `private struct`, `:296`), so every test drives it through the page the way the
// route does: a `SessionArtifactsScreenState` whose `preview` carries the row that
// was opened.
//
// What is asserted, in this order:
//  1. the subpage replaces the list: the artifact's own name becomes the title, the
//     baseline's fallback body shows (`:304`–`:305`), and 分享 is the only action;
//  2. 分享 is not a dead control: tapping it starts a *real* `Intent.ACTION_SEND`
//     chooser, and the intent carries either the file (`EXTRA_STREAM`, granted read
//     access) or — for a store with no content uri — the artifact's descriptor;
//  3. the two intent shapes are asserted directly, without a screen, so the payload
//     is pinned even if the composition changes.
package com.phonedsh.ui.page

import android.app.Application
import android.content.Intent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.domain.connector.DeviceToolState
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h640dp")
class SessionArtifactPreviewPageTest {
    @get:Rule
    val compose = createComposeRule()

    private val docx = SessionArtifactRef("art_weekly_doc", "weekly-report.docx", 48_120)

    /** The evidence that puts [docx] in 本 session (a successful producing call). */
    private val evidence = listOf(
        SessionArtifactEvidence(
            toolName = "doc.write",
            argumentsJson = "{}",
            outputText = "{\"fileId\":\"art_weekly_doc\"}",
            text = "",
            state = DeviceToolState.OK,
        ),
    )

    private fun showPreview(
        preview: SessionArtifactPreview,
        onClosePreview: () -> Unit = {},
    ) {
        compose.setContent {
            var local by remember {
                mutableStateOf(SessionArtifactsLocalState(preview = preview))
            }
            PdshTheme {
                SessionArtifactsPage(
                    state = SessionArtifactsScreenState.from(
                        artifacts = listOf(docx),
                        evidence = evidence,
                        local = local,
                    ),
                    onOpen = {},
                    onDone = {},
                    onClosePreview = {
                        onClosePreview()
                        local = SessionArtifactsLocalState()
                    },
                )
            }
        }
    }

    // ------------------------------------------------------------- structure

    @Test
    fun `the preview replaces the list and shows the baseline's fallback body`() {
        showPreview(SessionArtifactPreview(docx))

        compose.onNodeWithTag(UiPageTags.ARTIFACTS_PREVIEW_ROOT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.ARTIFACTS_PREVIEW_NAME).assertIsDisplayed()
        // The name is both the frame's title and the body's first line.
        compose.onAllNodesWithText(docx.name).onFirst().assertIsDisplayed()
        // `ContentUnavailableView("此文件无法预览", …, "可通过系统分享用其他应用打开。")`
        // (`:304`–`:305`), plus the one platform fact iOS does not need.
        compose.onNodeWithTag(UiPageTags.ARTIFACTS_PREVIEW_FALLBACK).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ARTIFACTS_NO_PREVIEW).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ARTIFACTS_NO_PREVIEW_HINT).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ARTIFACTS_PREVIEW_PLATFORM_NOTE).assertIsDisplayed()
        // The list's own rows and the sheet's 完成 give way to the subpage.
        compose.onNodeWithTag(UiPageTags.ARTIFACTS_LIST).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.DEVICE_DONE).assertDoesNotExist()
        // `.toolbar { ShareLink … }` (`:310`).
        compose.onNodeWithTag(UiPageTags.ARTIFACTS_PREVIEW_SHARE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.ARTIFACTS_PREVIEW_SHARE).assertIsDisplayed()
    }

    @Test
    fun `the preview's back control returns to the list`() {
        var closed = 0
        showPreview(SessionArtifactPreview(docx), onClosePreview = { closed += 1 })

        // The page frame's back glyph is the baseline's NavigationStack pop.
        compose.onNodeWithText(PAGE_BACK_GLYPH).performClick()
        assertEquals(1, closed)
        compose.runOnIdle {
            compose.onNodeWithText(UiStrings.DEVICE_DONE).assertIsDisplayed()
        }
    }

    // ------------------------------------------------------- the text preview

    @Test
    fun `the host's text is the body instead of the fallback`() {
        val text = "# orders\nrows: 3\namount total: 325.21\n"
        val artifact = SessionArtifactRef("orders-summary.md", "orders-summary.md", 78)
        showPreview(
            SessionArtifactPreview(
                artifact = artifact,
                text = text,
                loadedBytes = 78,
                totalBytes = 78,
            ),
        )

        compose.onNodeWithTag(UiPageTags.ARTIFACTS_PREVIEW_ROOT).assertIsDisplayed()
        // The body is the file: the fallback body must not be drawn for a file the
        // host really read, and the artifact's own line is still the content.
        compose.onNodeWithTag(UiPageTags.ARTIFACTS_PREVIEW_FALLBACK).assertDoesNotExist()
        compose.onNodeWithText(UiStrings.ARTIFACTS_NO_PREVIEW).assertDoesNotExist()
        compose.onNode(
            hasText("amount total: 325.21", substring = true),
            useUnmergedTree = true,
        ).assertIsDisplayed()
        // 分享 stays the preview's one action.
        compose.onNodeWithTag(UiPageTags.ARTIFACTS_PREVIEW_SHARE).assertIsDisplayed()
    }

    @Test
    fun `a partial read says how much of the file is on screen`() {
        val artifact = SessionArtifactRef("long.md", "long.md", 4_096)
        showPreview(
            SessionArtifactPreview(
                artifact = artifact,
                text = "first page",
                loadedBytes = 512,
                totalBytes = 4_096,
            ),
        )

        compose.onNodeWithText(
            UiStrings.PREVIEW_PROGRESS.format(
                formatFileSize(512),
                formatFileSize(4_096),
            ),
        ).assertIsDisplayed()
    }

    @Test
    fun `a host share callback answers for itself and its refusal is drawn`() {
        var shared: SessionArtifactPreview? = null
        compose.setContent {
            PdshTheme {
                SessionArtifactsPage(
                    state = SessionArtifactsScreenState.from(
                        artifacts = listOf(docx),
                        evidence = evidence,
                        local = SessionArtifactsLocalState(preview = SessionArtifactPreview(docx)),
                    ),
                    onOpen = {},
                    onDone = {},
                    onClosePreview = {},
                    onShare = { preview ->
                        shared = preview
                        false
                    },
                )
            }
        }

        compose.onNodeWithTag(UiPageTags.ARTIFACTS_PREVIEW_SHARE).performClick()
        compose.waitForIdle()

        assertEquals("the host owns the share", docx, shared?.artifact)
        // A refused share is a fact on screen, not a silent tap.
        compose.onNodeWithText(UiStrings.PREVIEW_SHARE_FAILED).assertIsDisplayed()
    }

    // -------------------------------------------------------------- the share

    @Test
    fun `分享 starts a real ACTION_SEND chooser`() {
        showPreview(SessionArtifactPreview(docx))

        compose.onNodeWithTag(UiPageTags.ARTIFACTS_PREVIEW_SHARE).performClick()
        compose.waitForIdle()

        val application = ApplicationProvider.getApplicationContext<Application>()
        val started = shadowOf(application).nextStartedActivity
        assertNotNull("分享 must start an activity, not swallow the tap", started)
        assertEquals(Intent.ACTION_CHOOSER, started.action)
        assertEquals(
            UiStrings.ARTIFACTS_PREVIEW_SHARE_CHOOSER,
            started.getCharSequenceExtra(Intent.EXTRA_TITLE)?.toString(),
        )
        val send = sendIntentOf(started)
        assertNotNull("the chooser must wrap the real send", send)
        assertEquals(Intent.ACTION_SEND, send!!.action)
        assertEquals("text/plain", send.type)
        assertEquals(docx.name, send.getStringExtra(Intent.EXTRA_SUBJECT))
        assertTrue(
            "the descriptor names the artifact the row opened",
            send.getStringExtra(Intent.EXTRA_TEXT)!!.contains(docx.name) &&
                send.getStringExtra(Intent.EXTRA_TEXT)!!.contains(docx.artifactId),
        )
        assertNull("a store with no file uri attaches no stream", send.getParcelableExtra(Intent.EXTRA_STREAM))
    }

    // ------------------------------------------------------------ the payload

    @Test
    fun `a content uri rides in EXTRA_STREAM with read access and its own mime type`() {
        val send = sessionArtifactShareIntent(
            SessionArtifactPreview(docx, contentUri = "content://com.phonedsh.probe/artifacts/art_weekly_doc"),
        )

        assertEquals(Intent.ACTION_SEND, send.action)
        assertEquals(
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            send.type,
        )
        assertEquals(
            "content://com.phonedsh.probe/artifacts/art_weekly_doc",
            send.getParcelableExtra<android.os.Parcelable>(Intent.EXTRA_STREAM)?.toString(),
        )
        assertTrue(
            "the receiving app needs read access to the uri",
            send.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0,
        )
        assertEquals(docx.name, send.getStringExtra(Intent.EXTRA_SUBJECT))
    }

    @Test
    fun `the mime table knows the produced types and guesses nothing else`() {
        assertEquals("application/pdf", artifactMimeType("旧草稿.pdf"))
        assertEquals("text/markdown", artifactMimeType("notes.md"))
        assertEquals(
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            artifactMimeType("budget.XLSX"),
        )
        assertEquals("*/*", artifactMimeType("archive.weird"))
        assertEquals("*/*", artifactMimeType("no-extension"))
    }

    /** The `ACTION_SEND` inside an `ACTION_CHOOSER`, on every API the test runs at. */
    private fun sendIntentOf(chooser: Intent): Intent? =
        chooser.getParcelableExtra(Intent.EXTRA_INTENT)
}
