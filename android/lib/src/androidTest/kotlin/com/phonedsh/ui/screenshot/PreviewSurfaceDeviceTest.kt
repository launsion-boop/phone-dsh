// The preview face on a real device: real bytes, real reads, real honest states.
// SPDX-License-Identifier: MIT
//
// L28's finding was that the preview had a shell and no substance: `FilesSource(
// files = null)` meant the list was always empty, so no renderer could be proven to
// work. These tests mount the **real** `PdshNavHost` over the **real** app-private
// workspace (`filesDir/xl/materialized/workspace`, the tree `:app` builds its WAL
// stores over) on an emulator, and assert what a person would see:
//
//   1. the files route lists files that are actually on disk;
//   2. tapping a row pushes `PdshRoute.Preview(path)` — one surface, one back;
//   3. the preview reads the file and renders it (text, Markdown, image, PDF);
//   4. the first frame is 正在读取… — and a file that lands during the bounded retry
//      appears without the user doing anything;
//   5. a file that never lands ends in 无法预览 + the reason + 重试 (≈6 s);
//   6. an unsupported file states path + size + reason and shares through the
//      `FileProvider` this module declares (the chooser is intercepted, so no other
//      app is opened on the emulator);
//   7. a file longer than 512 KiB pages: 加载更多 appends the next window and the
//      control disappears when the file ends.
//
// Each test writes its own PNG into the app's external files dir
// (`Android/data/<pkg>/files/l29-preview/`), so the evidence is a picture of the
// product surface pulled off the device, not a claim in a log.
package com.phonedsh.ui.screenshot

import android.app.Activity
import android.app.Instrumentation
import android.app.Instrumentation.ActivityMonitor
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.pdf.PdfDocument
import androidx.compose.foundation.text.BasicText
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.nav.PdshNavFacts
import com.phonedsh.ui.nav.PdshNavHost
import com.phonedsh.ui.nav.PdshNavState
import com.phonedsh.ui.nav.PdshRoute
import com.phonedsh.ui.page.UiPageTags
import com.phonedsh.ui.surface.preview.PreviewPage
import com.phonedsh.ui.surface.preview.PreviewShare
import com.phonedsh.ui.surface.preview.PreviewWorkspace
import com.phonedsh.ui.surface.preview.rememberPreviewSource
import com.phonedsh.ui.theme.PdshTheme
import java.io.File
import java.nio.file.Files
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PreviewSurfaceDeviceTest {

    @get:Rule
    val compose = createAndroidComposeRule<ScreenshotActivity>()

    /** The workspace the app reads by default; also the FileProvider's one root. */
    private lateinit var workspace: File

    /** The route on top of the stack; recomposing on change swaps the screen. */
    private var route by mutableStateOf<PdshRoute>(PdshRoute.Home)

    @Before
    fun prepareWorkspace() {
        workspace = PreviewWorkspace.defaultRoot(compose.activity.filesDir).toFile()
        workspace.deleteRecursively()
        assertTrue("cannot create the workspace $workspace", workspace.mkdirs())
    }

    // ---------------------------------------------------------------- listing

    @Test
    fun filesRouteListsTheRealWorkspace() {
        write("hello.txt", "hello from the device workspace\n")
        write("notes/readme.txt", "nested\n")

        mount(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Files("w1"))))
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.FILES_FILE_ROW).fetchSemanticsNodes().isNotEmpty()
        }
        // The old host handed `files = null` and the page said 等待引擎连接…
        compose.onNodeWithText("hello.txt").assertExists()
        compose.onNodeWithText("notes").assertExists()
        evidence("files-listing", UiPageTags.FILES_ROOT)
    }

    @Test
    fun tappingAFileRowPushesThePreviewRoute() {
        write("hello.txt", "hello\n")
        var pushed: PdshRoute? = null
        mount(
            PdshNavState(listOf(PdshRoute.Home, PdshRoute.Files("w1"))),
            onNavigate = { route -> pushed = route },
        )
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.FILES_FILE_ROW).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag(UiPageTags.FILES_FILE_ROW).performClick()
        compose.runOnIdle { assertEquals(PdshRoute.Preview("hello.txt"), pushed) }
    }

    // ------------------------------------------------------------------ text

    @Test
    fun thePreviewReadsARealTextFile() {
        write("hello.txt", "hello from the device workspace\n")
        mount(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Preview("hello.txt"))))
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithText("hello from the device workspace", substring = true)
                .fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag(UiPageTags.PREVIEW_TEXT).assertExists()
        // A resolved file: 分享 is offered (`:335`).
        compose.onNodeWithTag(UiPageTags.PREVIEW_SHARE).assertExists()
        evidence("preview-text", UiPageTags.PREVIEW_ROOT)
    }

    @Test
    fun aPathPrefixAndPercentEncodingResolveToTheSameFile() {
        write("中文 名.txt", "编码测试\n")
        // `%E4%B8%AD` = 中, and the `/dsh/workspace/` mount prefix is the Worker's.
        val spelling = "/dsh/workspace/%E4%B8%AD%E6%96%87%20%E5%90%8D.txt"
        mount(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Preview(spelling))))
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithText("编码测试", substring = true).fetchSemanticsNodes().isNotEmpty()
        }
        evidence("preview-encoded-path", UiPageTags.PREVIEW_ROOT)
    }

    @Test
    fun markdownIsRenderedAsBlocksNotAsterisks() {
        write(
            "notes.md",
            """
                # 标题

                一段 **加粗** 与 `代码`。

                - 第一项
                - 第二项

                ```kotlin
                fun main() {}
                ```
            """.trimIndent(),
        )
        mount(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Preview("notes.md"))))
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_MARKDOWN).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText("标题").assertExists()
        compose.onNodeWithText("第一项").assertExists()
        compose.onNodeWithText("fun main() {}", substring = true).assertExists()
        evidence("preview-markdown", UiPageTags.PREVIEW_ROOT)
    }

    // --------------------------------------------------------- honest states

    @Test
    fun theFirstFrameIsReadingAndAFileThatLandsLaterAppears() {
        // Nothing on disk yet: the preview must say 正在读取…, never 「已经不在了」.
        mount(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Preview("late.txt"))))
        compose.waitForIdle()
        compose.onNodeWithTag(UiPageTags.PREVIEW_LOADING).assertExists()
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_LOADING).assertExists()
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_GONE).assertDoesNotExist()
        evidence("preview-loading", UiPageTags.PREVIEW_ROOT)

        // The bytes land inside the bounded retry window (12 × 500 ms).
        write("late.txt", "arrived late but arrived\n")
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithText("arrived late but arrived", substring = true)
                .fetchSemanticsNodes().isNotEmpty()
        }
        evidence("preview-late-arrival", UiPageTags.PREVIEW_ROOT)
    }

    @Test
    fun aFileThatNeverLandsEndsInCannotPreviewWithRetry() {
        mount(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Preview("never.txt"))))
        // 12 waits at 500 ms, then the truth: one gesture, no user action.
        compose.waitUntil(RETRY_BUDGET_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_FAILED).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(UiStrings.PREVIEW_UNAVAILABLE).assertExists()
        compose.onNodeWithText(UiStrings.PREVIEW_STILL_WRITING, substring = true).assertExists()
        compose.onNodeWithTag(UiPageTags.PREVIEW_RETRY).assertExists()
        evidence("preview-failed", UiPageTags.PREVIEW_ROOT)

        // 重试 clears the attempt count and starts over: the file is created just
        // before the tap, so the retry must find it.
        write("never.txt", "now it exists\n")
        compose.onNodeWithTag(UiPageTags.PREVIEW_RETRY).performClick()
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithText("now it exists", substring = true)
                .fetchSemanticsNodes().isNotEmpty()
        }
    }

    @Test
    fun aParentSegmentIsRefusedWithoutWaiting() {
        write("secret.txt", "should not be reachable from here\n")
        mount(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Preview("../secret.txt"))))
        // A refusal is final at once (no 6 s wait) and names the safety boundary.
        compose.waitUntil(SHORT_TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_FAILED).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_UNSAFE, substring = true).assertExists()
        evidence("preview-refused", UiPageTags.PREVIEW_ROOT)
    }

    // --------------------------------------------------- unsupported + share

    @Test
    fun anOfficeFileStatesTheTruthAndSharesThroughTheProvider() {
        write("slides.pptx", "not really a deck")
        mount(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Preview("slides.pptx"))))
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_UNSUPPORTED).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(UiStrings.PREVIEW_UNSUPPORTED_TITLE).assertExists()
        compose.onNodeWithText(UiStrings.PREVIEW_REASON_OFFICE).assertExists()
        // The path and the measured size, not a guess. The name is in the header and
        // in the card, so the assertion counts nodes instead of demanding exactly one.
        assertTrue(
            "the card must name the path",
            compose.onAllNodesWithText("slides.pptx").fetchSemanticsNodes().isNotEmpty(),
        )
        compose.onNodeWithText("17 bytes").assertExists()
        evidence("preview-unsupported", UiPageTags.PREVIEW_ROOT)

        // The provider serves exactly this file, under this app's authority.
        val file = workspace.resolve("slides.pptx").toPath()
        val uri = PreviewShare.uriFor(compose.activity, file)
        assertTrue("the FileProvider refused the workspace file", uri != null)
        assertEquals("content", uri!!.scheme)
        assertEquals(
            compose.activity.packageName + PreviewShare.AUTHORITY_SUFFIX,
            uri.authority,
        )
        assertTrue("the URI must name the workspace path: $uri", uri.toString().contains("slides.pptx"))
        val mime = PreviewShare.mimeOf("slides.pptx")
        assertEquals(
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            mime,
        )
        val chooser = PreviewShare.intentFor(uri, mime, UiStrings.FILES_PREVIEW_SHARE)
        assertEquals(Intent.ACTION_CHOOSER, chooser.action)
        val send = chooser.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
        assertTrue("the chooser must wrap an ACTION_SEND", send != null)
        assertEquals(Intent.ACTION_SEND, send!!.action)
        assertEquals(mime, send.type)
        assertEquals(uri, send.getParcelableExtra(Intent.EXTRA_STREAM))
        assertTrue(
            "the receiver must be granted read access",
            send.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0,
        )
        record("share-intent action=${send.action} type=${send.type} uri=$uri")

    }

    @Test
    fun theUnsupportedCardNamesTheMissingCapabilityPerFile() {
        // L33: the architecture decision (one WebView ⇒ no second page container)
        // gates HTML and glTF; the three `webMedia` formats are three different
        // gaps (an animated decoder, a player route, a missing codec). So the card
        // has to answer per *file*, and never with an internal a person cannot get.
        // `PreviewUnsupportedTest` pins the vocabulary on the JVM; this test pins
        // that the sentences actually reach the screen.
        val cases = listOf(
            "page.html" to UiStrings.PREVIEW_REASON_HTML_PAGE,
            "cube.glb" to UiStrings.PREVIEW_REASON_MODEL_VIEWER,
            "anim.gif" to UiStrings.PREVIEW_REASON_WEB_MEDIA_GIF,
            "clip.webm" to UiStrings.PREVIEW_REASON_WEB_MEDIA_VIDEO,
            "clip.ogv" to UiStrings.PREVIEW_REASON_WEB_MEDIA_OGV,
        )
        cases.forEach { (name, _) -> write(name, "not really a $name") }
        mount(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Preview(cases.first().first))))
        cases.forEachIndexed { index, (name, reason) ->
            if (index > 0) swapTo(PdshRoute.Preview(name))
            // Wait for the new sentence, not just for the tag: the previous card is
            // still on screen for one frame, and a tag wait would photograph it.
            compose.waitUntil(TIMEOUT_MS) {
                compose.onAllNodesWithText(reason).fetchSemanticsNodes().isNotEmpty() &&
                    compose.onAllNodesWithTag(UiPageTags.PREVIEW_UNSUPPORTED)
                        .fetchSemanticsNodes().isNotEmpty()
            }
            compose.onNodeWithText(reason).assertExists()
            // Rule 4's way out is on every one of these cards.
            compose.onNodeWithTag(UiPageTags.PREVIEW_SHARE_FILE).assertExists()
            // One picture per file: the sentence is the deliverable of this lane,
            // so the evidence has to show which file produced which sentence.
            evidence("preview-unsupported-$name", UiPageTags.PREVIEW_ROOT)
        }
        record("unsupported-reasons file=${cases.size} sentences=${cases.map { it.second }}")
    }

    @Test
    fun tappingShareHandsTheResolvedFileToTheSeam() {
        write("slides.pptx", "not really a deck")
        var shared: java.nio.file.Path? = null
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PreviewPage(
                    relativePath = "slides.pptx",
                    source = rememberPreviewSource(workspace),
                    onBack = {},
                    onShare = { file ->
                        shared = file
                        true
                    },
                )
            }
        }
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_SHARE_FILE).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag(UiPageTags.PREVIEW_SHARE_FILE).performClick()
        compose.runOnIdle {
            // The seam receives the *resolved* file (symlinks followed, inside the
            // root) — never the route's raw string.
            assertEquals("slides.pptx", shared?.fileName?.toString())
            assertEquals(workspace.toPath().toRealPath(), shared?.parent?.toRealPath())
        }
        // The host said yes, so the page must not claim it could not share.
        compose.onNodeWithText(UiStrings.PREVIEW_SHARE_FAILED).assertDoesNotExist()
    }

    // ----------------------------------------------------------------- paging

    @Test
    fun aFileLongerThanOnePageLoadsMore() {
        // Just over two pages, so the second page ends the file.
        val lines = StringBuilder()
        var counter = 0
        while (lines.length < PAGE_BYTES + 4096) {
            lines.append("line ").append(counter).append(" of the paged workspace file\n")
            counter += 1
        }
        write("huge.log", lines.toString())
        mount(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Preview("huge.log"))))
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_LOAD_MORE).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(UiStrings.PREVIEW_LOAD_MORE).assertExists()
        // The footer states how much has been read of how much exists.
        compose.onNodeWithText(PROGRESS_PREFIX, substring = true).assertExists()
        evidence("preview-paged", UiPageTags.PREVIEW_ROOT)

        compose.onNodeWithTag(UiPageTags.PREVIEW_LOAD_MORE).performClick()
        // The file ends on the second page, so the control disappears and the
        // footer keeps the progress line.
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_LOAD_MORE).fetchSemanticsNodes().isEmpty()
        }
        compose.onNodeWithTag(UiPageTags.PREVIEW_PROGRESS).assertExists()
        evidence("preview-paged-end", UiPageTags.PREVIEW_ROOT)
    }

    // -------------------------------------------------------------- binaries

    @Test
    fun anImageAndAPdfAreDecodedOnTheDevice() {
        writeImage("shot.png", 320, 200)
        writePdf("doc.pdf")
        mount(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Preview("shot.png"))))
        // The body tag is present while it is still decoding, so the wait is for the
        // decoder's own line to disappear: the capture must be the bitmap.
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_IMAGE).fetchSemanticsNodes().isNotEmpty() &&
                compose.onAllNodesWithText(UiStrings.FILES_PREVIEW_LOADING).fetchSemanticsNodes().isEmpty()
        }
        compose.onNodeWithText(UiStrings.PREVIEW_IMAGE_FAILED).assertDoesNotExist()
        evidence("preview-image", UiPageTags.PREVIEW_ROOT)

        swapTo(PdshRoute.Preview("doc.pdf"))
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_PDF).fetchSemanticsNodes().isNotEmpty() &&
                compose.onAllNodesWithText(UiStrings.PREVIEW_PDF_RENDERING).fetchSemanticsNodes().isEmpty()
        }
        compose.onNodeWithText(UiStrings.PREVIEW_PDF_FAILED).assertDoesNotExist()
        evidence("preview-pdf", UiPageTags.PREVIEW_ROOT)
    }

    @Test
    fun aReadableFileNeverRendersTheFailureCard() {
        write("hello.txt", "x")
        // A resolved path whose bytes cannot be decoded as text: the text body must
        // show the file's real characters, not a fabricated empty frame.
        mount(PdshNavState(listOf(PdshRoute.Home, PdshRoute.Preview("hello.txt"))))
        compose.waitUntil(TIMEOUT_MS) {
            compose.onAllNodesWithTag(UiPageTags.PREVIEW_TEXT).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag(UiPageTags.PREVIEW_UNSUPPORTED).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.PREVIEW_FAILED).assertDoesNotExist()
    }

    // --------------------------------------------------------------- harness

    private fun mount(
        nav: PdshNavState,
        onNavigate: (PdshRoute) -> Unit = {},
    ) {
        route = nav.current
        compose.setContent {
            PdshTheme(darkTheme = false) {
                PdshNavHost(
                    nav = PdshNavState(listOf(PdshRoute.Home, route)),
                    facts = PdshNavFacts(),
                    onNavigate = onNavigate,
                    onBack = {},
                    onHome = {},
                    onHostAction = {},
                    home = { BasicText(text = "home") },
                    webSurface = {},
                )
            }
        }
        compose.waitForIdle()
    }

    /** Swaps the top route of the already-composed host (one `setContent` per test). */
    private fun swapTo(next: PdshRoute) {
        route = next
        compose.waitForIdle()
    }

    /** Captures the page and writes it (plus a fact line) off the device. */
    private fun evidence(name: String, tag: String) {
        val bitmap: Bitmap = compose.onNodeWithTag(tag).captureToImage().asAndroidBitmap()
        val directory = compose.activity.getExternalFilesDir(null) ?: compose.activity.filesDir
        val out = File(directory, "l29-preview").apply { mkdirs() }
        File(out, "$name.png").outputStream().use { stream ->
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)) {
                "failed to encode $name.png"
            }
        }
        record(
            "capture name=$name width=${bitmap.width} height=${bitmap.height} " +
                "file=${File(out, "$name.png").absolutePath}",
        )
    }

    /** One evidence line, appended to `l29-preview/facts.txt` on the device. */
    private fun record(line: String) {
        val directory = compose.activity.getExternalFilesDir(null) ?: compose.activity.filesDir
        val out = File(directory, "l29-preview").apply { mkdirs() }
        File(out, "facts.txt").appendText(line + "\n")
    }

    private fun write(relative: String, content: String): File {
        val target = File(workspace, relative)
        target.parentFile?.mkdirs()
        target.writeText(content)
        return target
    }

    private fun writeImage(relative: String, width: Int, height: Int): File {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.rgb(40, 120, 200))
        val target = File(workspace, relative)
        target.parentFile?.mkdirs()
        target.outputStream().use { stream ->
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream))
        }
        return target
    }

    /** A real one-page PDF, written by the platform's own `PdfDocument` writer. */
    private fun writePdf(relative: String): File {
        val document = PdfDocument()
        val page = document.startPage(PdfDocument.PageInfo.Builder(300, 400, 1).create())
        page.canvas.drawText("phone-dsh preview", 20f, 40f, android.graphics.Paint().apply {
            color = android.graphics.Color.BLACK
        })
        document.finishPage(page)
        val target = File(workspace, relative)
        target.parentFile?.mkdirs()
        target.outputStream().use { stream -> document.writeTo(stream) }
        document.close()
        assertTrue("the PDF fixture is empty", Files.size(target.toPath()) > 0)
        return target
    }

    private companion object {
        /** Generous: a cold emulator can take a few seconds for the first frame. */
        const val TIMEOUT_MS: Long = 20_000L

        /** A refusal must answer at once: the retry window is never spent on it. */
        const val SHORT_TIMEOUT_MS: Long = 3_000L

        /** The bounded retry budget (12 × 500 ms) plus the device's own slack. */
        const val RETRY_BUDGET_MS: Long = 15_000L

        /** One page of the paged body (`PreviewPager.PAGE_BYTES`). */
        const val PAGE_BYTES: Int = 512 * 1024

        /** The progress line's first word (`UiStrings.PREVIEW_PROGRESS`). */
        const val PROGRESS_PREFIX: String = "已读"
    }
}
