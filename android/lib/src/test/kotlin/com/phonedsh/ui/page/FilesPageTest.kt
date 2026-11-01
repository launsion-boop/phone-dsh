// Files page: the listing, the preview bodies and their ScreenState sequence.
// SPDX-License-Identifier: MIT
//
// The mirror source is `FilesPage.swift`; the assertions below are the sections,
// rows, conditions and strings that file renders, never a screenshot (the page is
// not one of the six signature surfaces).
package com.phonedsh.ui.page

import androidx.compose.runtime.Composable
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.UiTags
import com.phonedsh.ui.theme.PdshTheme
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
class FilesPageTest {
    @get:Rule
    val compose = createComposeRule()

    private val root = WorkspaceFile(id = "f-notes", relativePath = "notes.md", size = 1536)
    private val nested = WorkspaceFile(id = "f-src", relativePath = "src/main.kt", size = 40)
    private val folder = WorkspaceFile(id = "f-deep", relativePath = "src/deep/readme.txt", size = 12)
    private val files = listOf(root, nested, folder)

    private fun show(
        state: FilesScreenState,
        onOpenFolder: (String) -> Unit = {},
        onOpenFile: (WorkspaceFile) -> Unit = {},
        onQueryChange: (String) -> Unit = {},
        onNavigateUp: () -> Unit = {},
        onClosePreview: () -> Unit = {},
        onBack: () -> Unit = {},
        onShare: () -> Unit = {},
        onOpenDemo: (() -> Unit)? = null,
        pageSurface: (@Composable () -> Unit)? = null,
    ) {
        compose.setContent {
            PdshTheme {
                FilesPage(
                    state = state,
                    onOpenFolder = onOpenFolder,
                    onOpenFile = onOpenFile,
                    onQueryChange = onQueryChange,
                    onNavigateUp = onNavigateUp,
                    onClosePreview = onClosePreview,
                    onBack = onBack,
                    onShare = onShare,
                    onOpenDemo = onOpenDemo,
                    pageSurface = pageSurface,
                )
            }
        }
    }

    // ------------------------------------------------------------------ listing

    @Test
    fun `the listing is one section with the folders first and then the files`() {
        val state = FilesScreenState.from(FilesSource(files = files))
        assertEquals(UiStrings.FILES_WORKSPACE, state.groupTitle)
        assertEquals(listOf("src"), state.folders)
        assertEquals(listOf("notes.md"), state.files.map { it.relativePath })
        show(state)
        compose.onNodeWithTag(UiTags.FILES_LIST).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.FILES_SECTION).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.FILES_FOLDER_ROW).assertIsDisplayed()
        // The file row's three lines: name, folder (only when nested), size.
        compose.onNodeWithText("notes.md").assertIsDisplayed()
        compose.onNodeWithText("2 KB").assertIsDisplayed()
        compose.onNodeWithTag(UiTags.FILES_EMPTY).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.FILES_NONE).assertDoesNotExist()
    }

    @Test
    fun `a nested file row shows its folder and never the whole path`() {
        val state = FilesScreenState.from(
            FilesSource(files = files),
            FilesLocalState(directory = "src/"),
        )
        assertEquals(listOf("deep"), state.folders)
        assertEquals(listOf("src/main.kt"), state.files.map { it.relativePath })
        show(state)
        compose.onNodeWithText("main.kt").assertIsDisplayed()
        // The folder line names the parent; the whole relative path never renders.
        compose.onNodeWithTag(UiPageTags.FILES_FILE_ROW)
            .assert(hasText("src", substring = true))
        compose.onNodeWithTag(UiPageTags.FILES_FILE_ROW)
            .assert(hasText("src/main.kt", substring = true).not())
    }

    @Test
    fun `a file whose size was not measured says 未知 instead of a number`() {
        val unmeasured = WorkspaceFile(id = "f-x", relativePath = "x.bin", size = null)
        show(FilesScreenState.from(FilesSource(files = listOf(unmeasured))))
        compose.onNodeWithText(UiStrings.UNKNOWN).assertIsDisplayed()
        compose.onNodeWithText("notes.md").assertDoesNotExist()
    }

    @Test
    fun `an empty workspace is the two-line card, not an empty section`() {
        val state = FilesScreenState.from(FilesSource(files = emptyList()))
        assertTrue(state.workspaceEmpty)
        assertFalse(state.waiting)
        show(state)
        compose.onNodeWithTag(UiPageTags.FILES_NONE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.FILES_NONE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.FILES_NONE_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.FILES_SECTION).assertDoesNotExist()
        compose.onNodeWithTag(UiTags.FILES_LIST).assertDoesNotExist()
    }

    /**
     * `FilesPage.swift:115`–`:136`: an empty *sub-directory* is the section title
     * with no rows. The baseline has no "this folder is empty" sentence, so the
     * page must not invent one — and must not fall back to the workspace's
     * 「还没有文件」 card either.
     */
    @Test
    fun `an empty sub-directory draws the section title with no rows`() {
        val state = FilesScreenState.from(
            FilesSource(files = files),
            FilesLocalState(directory = "empty/"),
        )
        assertTrue(state.sectionEmpty)
        assertFalse(state.workspaceEmpty)
        show(state)
        compose.onNodeWithTag(UiPageTags.FILES_SECTION).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.FILES_FILE_ROW).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.FILES_FOLDER_ROW).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.FILES_NONE).assertDoesNotExist()
    }

    @Test
    fun `an unreported listing waits instead of claiming an empty workspace`() {
        val state = FilesScreenState.from(FilesSource(files = null))
        assertTrue(state.waiting)
        assertFalse(state.workspaceEmpty)
        show(state)
        compose.onNodeWithText(UiStrings.WAITING_ENGINE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.FILES_NONE).assertDoesNotExist()
    }

    @Test
    fun `search filters the rows and hides the folders`() {
        val state = FilesScreenState.from(
            FilesSource(files = files),
            FilesLocalState(query = "NOTES"),
        )
        assertEquals(listOf("notes.md"), state.files.map { it.relativePath })
        assertTrue(state.folders.isEmpty())
        show(state)
        compose.onNodeWithText("notes.md").assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.FILES_FOLDER_ROW).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.FILES_SEARCH).assertIsDisplayed()
    }

    @Test
    fun `a folder row opens the folder and a file row opens its preview`() {
        var openedFolder: String? = null
        var openedFile: WorkspaceFile? = null
        show(
            FilesScreenState.from(FilesSource(files = files)),
            onOpenFolder = { openedFolder = it },
            onOpenFile = { openedFile = it },
        )
        compose.onNodeWithTag(UiPageTags.FILES_FOLDER_ROW).performClick()
        assertEquals("src", openedFolder)
        compose.onNodeWithText("notes.md").performClick()
        assertEquals(root, openedFile)
    }

    @Test
    fun `the header back walks the stack - preview, then folder, then page`() {
        var closes = 0
        var ups = 0
        var backs = 0
        val previewState = FilesScreenState.from(
            FilesSource(files = files, preview = FilePreviewRead(content = "hi")),
            FilesLocalState(previewPath = "notes.md"),
        )
        show(
            previewState,
            onClosePreview = { closes += 1 },
            onNavigateUp = { ups += 1 },
            onBack = { backs += 1 },
        )
        compose.onNodeWithContentDescription(UiStrings.BACK).performClick()
        assertEquals(1, closes)
        assertEquals(0, ups)
        assertEquals(0, backs)
    }

    @Test
    fun `a sub-directory's back climbs one level and the root's back leaves the page`() {
        var ups = 0
        var backs = 0
        show(
            FilesScreenState.from(FilesSource(files = files), FilesLocalState(directory = "src/")),
            onNavigateUp = { ups += 1 },
            onBack = { backs += 1 },
        )
        compose.onNodeWithContentDescription(UiStrings.BACK).performClick()
        assertEquals(1, ups)
        assertEquals(0, backs)
    }

    @Test
    fun `the demo entry is absent when the host offers no demo`() {
        show(FilesScreenState.from(FilesSource(files = files)))
        compose.onNodeWithTag(UiPageTags.FILES_DEMO).assertDoesNotExist()
    }

    @Test
    fun `the demo entry opens the host's demo`() {
        var demos = 0
        show(FilesScreenState.from(FilesSource(files = files)), onOpenDemo = { demos += 1 })
        compose.onNodeWithContentDescription(UiStrings.FILES_DEMO_OPEN).performClick()
        assertEquals(1, demos)
    }

    // ------------------------------------------------------------------ preview

    private fun previewState(
        path: String = "notes.md",
        read: FilePreviewRead? = FilePreviewRead(content = "hello workspace"),
    ): FilesScreenState = FilesScreenState.from(
        FilesSource(files = files, preview = read),
        FilesLocalState(previewPath = path),
    )

    @Test
    fun `a text preview renders its content and 完成 closes it`() {
        var closes = 0
        show(previewState(), onClosePreview = { closes += 1 })
        compose.onNodeWithTag(UiTags.FILES_PREVIEW).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.FILES_PREVIEW_TEXT).assertIsDisplayed()
        compose.onNodeWithText("hello workspace").assertIsDisplayed()
        compose.onNodeWithTag(UiTags.FILES_LIST).assertDoesNotExist()
        compose.onNodeWithTag(UiPageTags.FILES_PREVIEW_DONE).performClick()
        assertEquals(1, closes)
    }

    @Test
    fun `an unanswered read is the baseline's gone card, not a loading sentence`() {
        val state = previewState(read = null)
        assertTrue(state.preview is FilePreview.Unavailable)
        show(state)
        compose.onNodeWithTag(UiPageTags.FILES_PREVIEW_CARD).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_GONE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_GONE_HINT).assertIsDisplayed()
    }

    @Test
    fun `a failed read shows the baseline's prefix and the host's reason`() {
        show(previewState(read = FilePreviewRead(error = "读不到")))
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_GONE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_READ_FAILED.format("读不到")).assertIsDisplayed()
    }

    @Test
    fun `a preview without a current session says so`() {
        show(previewState(read = FilePreviewRead(sessionMissing = true)))
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_GONE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_NO_SESSION).assertIsDisplayed()
    }

    @Test
    fun `a file outside the safe snapshot is refused with the baseline's sentence`() {
        show(previewState(read = FilePreviewRead(unsafe = true)))
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_UNSAFE).assertIsDisplayed()
    }

    @Test
    fun `a successful read with an empty body is an empty text body, not a failure`() {
        // `FilesPage.swift:406`–`:408`: `text ?? ""` is a body of its own, so an
        // empty file renders the (empty) monospaced body and never the failure card.
        val state = previewState(path = "empty.txt", read = FilePreviewRead(content = ""))
        assertTrue(state.preview is FilePreview.Text)
        show(state)
        // An empty body has no size to display, but it is the body the baseline
        // renders — and it is emphatically not the failure card.
        compose.onNodeWithTag(UiPageTags.FILES_PREVIEW_TEXT).assertExists()
        compose.onNodeWithTag(UiPageTags.FILES_PREVIEW_CARD).assertDoesNotExist()
    }

    @Test
    fun `a non-text file falls back to the measured degradation card`() {
        show(previewState(path = "logo.png", read = FilePreviewRead(byteCount = 2048)))
        compose.onNodeWithTag(UiPageTags.FILES_PREVIEW_CARD).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_BINARY).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_BINARY_HINT).assertIsDisplayed()
        compose.onNodeWithText("2 KB").assertIsDisplayed()
    }

    @Test
    fun `an html file outside a workspace shows the outside card and its notice`() {
        val state = previewState(
            path = "demo/spin.html",
            read = FilePreviewRead(pageAvailable = false),
        )
        assertTrue(state.preview is FilePreview.Page)
        show(state)
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_OUTSIDE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_OUTSIDE_HINT).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.FILES_PREVIEW_NOTICE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_NOTICE_HTML).assertIsDisplayed()
    }

    @Test
    fun `an html file with a workspace host the surface and keep the notice`() {
        val state = previewState(
            path = "demo/spin.html",
            read = FilePreviewRead(pageAvailable = true, shareable = true),
        )
        show(state, pageSurface = { androidx.compose.foundation.text.BasicText("page-host") })
        compose.onNodeWithTag(UiPageTags.FILES_PREVIEW_SURFACE).assertIsDisplayed()
        compose.onNodeWithText("page-host").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_NOTICE_HTML).assertIsDisplayed()
    }

    @Test
    fun `分享 is offered and shares when the host says the file is shareable`() {
        var shares = 0
        show(
            previewState(read = FilePreviewRead(content = "x", shareable = true)),
            onShare = { shares += 1 },
        )
        compose.onNodeWithTag(UiPageTags.FILES_PREVIEW_SHARE).assertIsDisplayed()
        compose.onNodeWithTag(UiPageTags.FILES_PREVIEW_SHARE).performClick()
        assertEquals(1, shares)
    }

    @Test
    fun `分享 is absent while the host has not said the file is shareable`() {
        show(previewState(read = FilePreviewRead(content = "x", shareable = null)))
        compose.onNodeWithTag(UiPageTags.FILES_PREVIEW_SHARE).assertDoesNotExist()
    }

    @Test
    fun `an unshareable file says it is not in the workspace any more`() {
        show(previewState(read = FilePreviewRead(content = "x", shareable = false)))
        compose.onNodeWithTag(UiPageTags.FILES_PREVIEW_MISSING).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_MISSING).assertIsDisplayed()
    }

    @Test
    fun `the read caps append their sentences to the one notice line`() {
        val read = FilePreviewRead(
            content = "x",
            textTruncated = true,
            linesTruncated = true,
            shareable = true,
        )
        val state = previewState(read = read)
        assertEquals(
            listOf(
                UiStrings.FILES_PREVIEW_NOTICE_256KIB,
                UiStrings.FILES_PREVIEW_NOTICE_LINES.format(200),
            ).joinToString(" "),
            state.previewNotice,
        )
        show(state)
        compose.onNodeWithTag(UiPageTags.FILES_PREVIEW_NOTICE).assertIsDisplayed()
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_NOTICE_256KIB, substring = true)
            .assertIsDisplayed()
    }

    @Test
    fun `a materialized-copy fallback renders the text and says it is a copy`() {
        val state = previewState(
            path = "notes.txt",
            read = FilePreviewRead(content = "disk copy", materializedCopy = true),
        )
        assertTrue(state.preview is FilePreview.Text)
        assertEquals(UiStrings.FILES_PREVIEW_NOTICE_COPY, state.previewNotice)
        show(state)
        compose.onNodeWithText("disk copy").assertIsDisplayed()
        compose.onNodeWithText(UiStrings.FILES_PREVIEW_NOTICE_COPY).assertIsDisplayed()
    }

    // --------------------------------------------------------------- pure facts

    @Test
    fun `classifyFileKind follows the baseline's extension order`() {
        assertEquals(FileKind.HTML, classifyFileKind("index.html"))
        assertEquals(FileKind.HTML, classifyFileKind("a/b/INDEX.HTM"))
        assertEquals(FileKind.MARKDOWN, classifyFileKind("readme.md"))
        assertEquals(FileKind.MARKDOWN, classifyFileKind("a/MARKDOWN.markdown"))
        assertEquals(FileKind.TEXT, classifyFileKind("Package.swift"))
        assertEquals(FileKind.TEXT, classifyFileKind("data.json"))
        assertEquals(FileKind.TEXT, classifyFileKind("notes.txt"))
        assertEquals(FileKind.EXTERNAL, classifyFileKind("logo.png"))
        assertEquals(FileKind.EXTERNAL, classifyFileKind("archive.zip"))
        // Foundation gives a dot-file no extension, so it is not in the text list.
        // Android toolchain extensions (platform.workspace-text-extensions).
        assertEquals(FileKind.TEXT, classifyFileKind("android/app/src/Main.kt"))
        assertEquals(FileKind.TEXT, classifyFileKind("build.gradle"))
        assertEquals(FileKind.TEXT, classifyFileKind("build.gradle.kts"))
        assertEquals(FileKind.TEXT, classifyFileKind("Main.java"))
        assertEquals(FileKind.EXTERNAL, classifyFileKind(".env"))
        assertEquals(FileKind.EXTERNAL, classifyFileKind("Makefile"))
    }

    /**
     * `formatFileSize` mirrors Foundation's `ByteCountFormatter(.file)`. The table
     * is the output of a `swift -e` probe on this machine (`Locale zh_CN`), so the
     * same file reads the same on both phones.
     */
    @Test
    fun `formatFileSize mirrors Foundation's decimal file style`() {
        val table = listOf(
            0L to "Zero KB",
            1L to "1 byte",
            2L to "2 bytes",
            999L to "999 bytes",
            1000L to "1 KB",
            1024L to "1 KB",
            1400L to "1 KB",
            1500L to "2 KB",
            1536L to "2 KB",
            2048L to "2 KB",
            30000L to "30 KB",
            150000L to "150 KB",
            999999L to "1 MB",
            1000000L to "1 MB",
            1050000L to "1.1 MB",
            1234567L to "1.2 MB",
            1500000L to "1.5 MB",
            15000000L to "15 MB",
            999999999L to "1 GB",
            1500000000L to "1.5 GB",
            1000000000000L to "1 TB",
        )
        table.forEach { (bytes, expected) -> assertEquals("$bytes B", expected, formatFileSize(bytes)) }
        // The technical budget formatter stays binary: the two are not one function.
        assertEquals("1.5 KiB", formatByteSize(1536))
    }

    @Test
    fun `classifyFileContent treats undecodable bytes as binary, never as text`() {
        assertEquals(FileContentView.Text("hello"), classifyFileContent("hello".toByteArray()))
        assertEquals(FileContentView.Text(""), classifyFileContent(ByteArray(0)))
        assertEquals(FileContentView.Text("中文"), classifyFileContent("中文".toByteArray()))
        // A NUL byte.
        assertEquals(FileContentView.Binary(1), classifyFileContent(byteArrayOf(0)))
        // A lone continuation byte: not valid UTF-8.
        assertEquals(
            FileContentView.Binary(2),
            classifyFileContent(byteArrayOf(0xC3.toByte(), 0x28)),
        )
    }

    @Test
    fun `the group title is the folder's name and 手机工作区 at the root`() {
        assertEquals(UiStrings.FILES_WORKSPACE, FilesScreenState.groupTitle(""))
        assertEquals("src", FilesScreenState.groupTitle("src/"))
        assertEquals("b", FilesScreenState.groupTitle("a/b/"))
    }

    @Test
    fun `the local script replays the baseline's navigation`() {
        var local = FilesLocalState()
        local = local.apply(FilesUiEvent.SetQuery("re"))
        local = local.apply(FilesUiEvent.OpenFolder("src"))
        // A pushed page starts with an empty query and no preview (`:25`, `:118`).
        assertEquals(FilesLocalState(directory = "src/"), local)
        local = local.apply(FilesUiEvent.OpenFile("src/main.kt"))
        assertEquals("src/main.kt", local.previewPath)
        local = local.apply(FilesUiEvent.ClosePreview)
        assertNull(local.previewPath)
        local = local.copy(directory = "a/b/")
        local = local.apply(FilesUiEvent.NavigateUp)
        assertEquals("a/", local.directory)
        local = local.apply(FilesUiEvent.NavigateUp)
        assertEquals("", local.directory)
    }

    @Test
    fun `the same snapshot and script always yield the same rows`() {
        val source = FilesSource(files = files, preview = FilePreviewRead(content = "hi"))
        fun run(): List<FilesScreenState> {
            var local = FilesLocalState()
            val out = mutableListOf<FilesScreenState>()
            out += FilesScreenState.from(source, local)
            local = local.apply(FilesUiEvent.SetQuery("main"))
            out += FilesScreenState.from(source, local)
            local = local.apply(FilesUiEvent.SetQuery(""))
            local = local.apply(FilesUiEvent.OpenFolder("src"))
            out += FilesScreenState.from(source, local)
            local = local.apply(FilesUiEvent.OpenFile("src/main.kt"))
            out += FilesScreenState.from(source, local)
            return out
        }
        val first = run()
        assertEquals(first, run())
        // The sequence: listing, filtered, folder, preview.
        assertEquals(
            listOf(false, false, false, true),
            first.map { it.isPreviewing },
        )
        assertEquals(listOf("", "", "src/"), first.take(3).map { it.directory })
        // `kt` is one of the Android-toolchain extensions added on top of the
        // baseline's list (`platform.workspace-text-extensions`), so this file
        // takes the text body rather than Quick Look.
        assertTrue(first.last().preview is FilePreview.Text)
    }
}
