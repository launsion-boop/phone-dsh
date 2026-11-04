// The four honest states and the bounded wait, driven without a clock or a device.
// SPDX-License-Identifier: MIT
//
// Every rule in `PreviewSurface.swift:97`–`:228` that can be stated as a value is
// asserted here:
//
//   rule 1  the first frame is loading (and *not* a missing-file sentence);
//   rule 2  twelve waits, then one answer — and a refusal never waits at all;
//   rule 3  重试 exists as a state transition, not only as a button;
//   rule 4  an unsupported kind states a reason per kind, and never claims a body.
package com.phonedsh.ui.surface.preview

import com.phonedsh.ui.UiStrings
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PreviewStateTest {

    private val file: Path = Path.of("/workspace/notes.txt")

    @Test
    fun `the first frame is loading, never a missing-file claim`() {
        val state = PreviewState("./notes.txt")
        assertEquals(PreviewStatus.LOADING, state.status)
        assertTrue(state.isFirstFrame)
        assertNull("the first frame carries no error", state.error)
        assertFalse("the first frame offers no share", state.canShare)
        assertEquals("notes.txt", state.normalizedPath)
    }

    @Test
    fun `two spellings of one path share their identity`() {
        assertEquals(
            PreviewState("notes.txt").normalizedPath,
            PreviewState("/dsh/workspace/./notes.txt").normalizedPath,
        )
        assertEquals(
            PreviewState("notes.txt").normalizedPath,
            PreviewState("file://notes.txt").normalizedPath,
        )
    }

    @Test
    fun `a text body becomes READY once its first page arrives`() {
        val page = PreviewTextPage(text = "hello", nextOffset = 5, eof = false, bytesKept = 5)
        val state = PreviewState("notes.txt")
            .textBody(file, sizeBytes = 11, kind = PreviewKind.TEXT)
            .appended(page)
        assertEquals(PreviewStatus.READY, state.status)
        assertEquals("hello", state.text)
        assertEquals(5L, state.loadedBytes)
        assertTrue(state.canLoadMore)
        assertTrue(state.canShare)
        assertTrue(state.isPaged)
        assertNull(state.unsupportedReason)
    }

    @Test
    fun `the last page ends the pager`() {
        val state = PreviewState("notes.txt")
            .textBody(file, sizeBytes = 5, kind = PreviewKind.TEXT)
            .appended(PreviewTextPage(text = "hello", nextOffset = 5, eof = true, bytesKept = 5))
        assertFalse(state.canLoadMore)
    }

    @Test
    fun `a page in flight is not offered twice`() {
        val state = PreviewState("notes.txt")
            .textBody(file, sizeBytes = 100, kind = PreviewKind.TEXT)
            .appended(PreviewTextPage(text = "a", nextOffset = 1, eof = false, bytesKept = 1))
            .readingPage()
        assertTrue(state.readingMore)
        assertFalse(state.canLoadMore)
    }

    @Test
    fun `a stalled page keeps the honest notice`() {
        val state = PreviewState("notes.txt")
            .textBody(file, sizeBytes = 100, kind = PreviewKind.TEXT)
            .appended(
                PreviewTextPage(text = "", nextOffset = 4096, eof = false, bytesKept = 0, stalled = true),
            )
        assertEquals(UiStrings.PREVIEW_NOTICE_BINARY, state.notice)
        assertEquals(PreviewStatus.READY, state.status)
    }

    @Test
    fun `a failure carries the reason and clears the body`() {
        val state = PreviewState("notes.txt")
            .textBody(file, sizeBytes = 5, kind = PreviewKind.TEXT)
            .appended(PreviewTextPage(text = "a", nextOffset = 1, eof = false, bytesKept = 1))
            .failed(UiStrings.PREVIEW_STILL_WRITING, attempts = 13)
        assertEquals(PreviewStatus.FAILED, state.status)
        assertTrue(state.isFailed)
        assertFalse(state.isFirstFrame)
        assertEquals("", state.text)
        assertEquals(13, state.attempts)
        assertEquals(UiStrings.PREVIEW_STILL_WRITING, state.error)
    }

    @Test
    fun `an unsupported kind states a reason for every kind that has none`() {
        // The mapping is per *file* since the L33 lane (`PreviewUnsupported.kt`):
        // one `WEB_MEDIA` row is three formats, so the representative path is part
        // of the expectation and not just the kind.
        val expected = listOf(
            Triple("slides.pptx", PreviewKind.OFFICE, UiStrings.PREVIEW_REASON_OFFICE),
            Triple("page.html", PreviewKind.HTML, UiStrings.PREVIEW_REASON_HTML_PAGE),
            Triple("cube.glb", PreviewKind.MODEL, UiStrings.PREVIEW_REASON_MODEL_VIEWER),
            Triple("clip.webm", PreviewKind.WEB_MEDIA, UiStrings.PREVIEW_REASON_WEB_MEDIA_VIDEO),
        )
        expected.forEach { (path, kind, reason) ->
            val state = PreviewState(path).unsupported(file, sizeBytes = 7, kind = kind)
            assertEquals(PreviewStatus.UNSUPPORTED, state.status)
            assertTrue(state.isUnsupported)
            assertEquals("$kind", reason, state.unsupportedReason)
            assertTrue("the card can share the file", state.canShare)
            assertEquals(7L, state.totalBytes)
        }
        // The two media kinds were promoted to renderers by the L32 lane
        // (`PreviewPlayback.kt`): they never reach this card, and if they ever did
        // they would have no missing capability to name.
        listOf(PreviewKind.VIDEO, PreviewKind.AUDIO).forEach { kind ->
            assertTrue("$kind is rendered now", kind.isRendered)
            assertEquals(
                "$kind has a renderer, so it has no reason to print",
                null,
                PreviewState("x").unsupported(file, 1, kind).unsupportedReason,
            )
        }
        // An unclassifiable file needs no capability sentence: nothing is missing but
        // a renderer for a format nobody knows.
        assertEquals(
            null,
            PreviewState("x").unsupported(file, 1, PreviewKind.UNSUPPORTED).unsupportedReason,
        )
        // A rendered kind never carries an unsupported reason.
        assertEquals(
            null,
            PreviewState("x").unsupported(file, 1, PreviewKind.TEXT).unsupportedReason,
        )
    }

    @Test
    fun `a media file is ready without a text page`() {
        listOf(
            "movie.mp4" to PreviewKind.VIDEO,
            "song.mp3" to PreviewKind.AUDIO,
        ).forEach { (path, kind) ->
            // The media bodies decode the file themselves; the page only needs the
            // resolved file and the measured size, exactly like image and PDF.
            val state = PreviewState(path).textBody(file, sizeBytes = 2048, kind = kind)
            assertEquals("$kind", PreviewStatus.READY, state.status)
            assertFalse("$kind has no paging window", state.isPaged)
            assertFalse(state.canLoadMore)
            assertTrue("the toolbar can share it", state.canShare)
            assertEquals(2048L, state.totalBytes)
            assertNull("$kind", state.unsupportedReason)
            assertNull("$kind", state.error)
        }
    }

    @Test
    fun `the bounded wait is twelve attempts and then the truth`() {
        // `:148`: `retryCount <= 12`, 500 ms apart, so ≈6 s in total.
        assertEquals(12, PreviewPolicy.RETRY_LIMIT)
        assertEquals(500L, PreviewPolicy.RETRY_DELAY_MS)
        for (attempt in 1..PreviewPolicy.RETRY_LIMIT) {
            assertEquals(
                "attempt $attempt still waits",
                PreviewPolicy.Step.Wait(PreviewPolicy.RETRY_DELAY_MS),
                PreviewPolicy.next(PreviewUnresolved.MISSING, attempt),
            )
        }
        assertEquals(
            PreviewPolicy.Step.Fail(UiStrings.PREVIEW_STILL_WRITING),
            PreviewPolicy.next(PreviewUnresolved.MISSING, PreviewPolicy.RETRY_LIMIT + 1),
        )
        // A workspace the host has not created yet waits the same way.
        assertEquals(
            PreviewPolicy.Step.Wait(PreviewPolicy.RETRY_DELAY_MS),
            PreviewPolicy.next(PreviewUnresolved.NO_WORKSPACE, 1),
        )
        assertEquals(
            PreviewPolicy.Step.Fail(UiStrings.PREVIEW_STILL_WRITING),
            PreviewPolicy.next(PreviewUnresolved.NO_WORKSPACE, PreviewPolicy.RETRY_LIMIT + 1),
        )
    }

    @Test
    fun `a refusal is final at once, never six seconds later`() {
        assertEquals(
            PreviewPolicy.Step.Fail(UiStrings.FILES_PREVIEW_UNSAFE),
            PreviewPolicy.next(PreviewUnresolved.REJECTED, 1),
        )
        assertEquals(
            PreviewPolicy.Step.Fail(UiStrings.PREVIEW_NOT_A_FILE),
            PreviewPolicy.next(PreviewUnresolved.NOT_A_FILE, 1),
        )
    }

    @Test
    fun `the retry ladder ends on the same message the baseline uses`() {
        // The sentence is the iOS one (`:158`), and it must not be the
        // missing-file sentence the old Android preview showed up front.
        val last = PreviewPolicy.next(PreviewUnresolved.MISSING, PreviewPolicy.RETRY_LIMIT + 1)
        assertEquals(
            UiStrings.PREVIEW_STILL_WRITING,
            (last as PreviewPolicy.Step.Fail).message,
        )
        assertFalse(last.message == UiStrings.FILES_PREVIEW_GONE)
        assertTrue(last.message.contains("还在写入"))
    }
}
