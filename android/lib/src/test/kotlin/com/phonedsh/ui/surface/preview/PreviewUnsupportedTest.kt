// The honest reasons, per file, and the set the architecture still owes.
// SPDX-License-Identifier: MIT
//
// Why this file exists at all: the unsupported card is the one place the App says
// "I cannot do this". Two different facts can produce that sentence — a missing
// page container (HTML, glTF) or a missing platform gap (Office, OGV's Theora
// decoder) — and a card that answers both of them
// with one sentence, or with the name of an internal class, is the same lie as
// "the file is gone".
//
// Two things are pinned here and nowhere else:
//
//   1. [PreviewKind.needsWebPreview] is **exactly** { HTML, MODEL }. That set is
//      the L33 lane's architecture decision (the single-WebView invariant stays);
//      a future lane that opens an isolated page renderer flips these two answers
//      and nothing else, and this test is where the change becomes visible.
//   2. No sentence names an implementation the reader cannot act on. A person
//      cannot "get a second WebView"; they can share the file to another app.
package com.phonedsh.ui.surface.preview

import com.phonedsh.ui.UiStrings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PreviewUnsupportedTest {

    @Test
    fun `the page-renderer set is exactly html and gltf`() {
        assertEquals(
            setOf(PreviewKind.HTML, PreviewKind.MODEL),
            PreviewKind.values().filter { it.needsWebPreview }.toSet(),
        )
        // A kind that already has a body cannot also be waiting for a page
        // container; if it ever were, the card and the toolbar would disagree.
        assertTrue(
            "a rendered kind is not waiting for a page renderer",
            PreviewKind.values().none { it.needsWebPreview && it.isRendered },
        )
        // …and the architecture is not the reason for the other unsupported kinds.
        assertFalse(
            "Office is a platform gap, not the WebView decision",
            PreviewKind.OFFICE.needsWebPreview,
        )
        assertFalse(
            "OGV is a missing decoder, not the WebView decision",
            PreviewKind.WEB_MEDIA.needsWebPreview,
        )
    }

    @Test
    fun `a media file gets the reason its own format deserves`() {
        // `gif` and `webm` are rendered now (first frame / the platform decoder), so
        // only the format this host genuinely cannot decode still has a sentence.
        val ogv = unsupportedReasonFor(PreviewKind.WEB_MEDIA, "clip.OGV")
        assertEquals(UiStrings.PREVIEW_REASON_WEB_MEDIA_OGV, ogv)
        // One format, one fact: this host has no Theora decoder.
        assertEquals(UiStrings.PREVIEW_REASON_WEB_MEDIA_OGV, ogv)
    }

    @Test
    fun `every path the classifier calls web media has a sentence`() {
        // `gif` and `webm` moved to IMAGE / VIDEO, so webMedia is OGV alone here.
        listOf("clip.ogv", "nested/dir/clip.OGV").forEach { path ->
            assertEquals(path, PreviewKind.WEB_MEDIA, previewKindOf(path))
            val reason = unsupportedReasonFor(PreviewKind.WEB_MEDIA, path)
            assertTrue(path, !reason.isNullOrBlank())
        }
    }

    @Test
    fun `a reason names a capability the reader can act on`() {
        val forbidden = listOf("WebView", "webview", "只允许一个", "第二个", "HTML 预览需要")
        val reasons = allReasons()
        assertEquals("every unsupported kind is covered", 4, reasons.size)
        reasons.forEach { reason ->
            forbidden.forEach { word ->
                assertFalse("『$reason』 must not name $word", reason.contains(word))
            }
            assertTrue("『$reason』 is a finished sentence", reason.endsWith("。"))
            assertTrue("『$reason』 is one line", !reason.contains('\n'))
        }
    }

    @Test
    fun `a rendered kind and an unclassifiable file have no reason`() {
        PreviewKind.values().filter { it.isRendered }.forEach { kind ->
            assertNull("$kind draws a body, so it needs no excuse", unsupportedReasonFor(kind, "x.mp4"))
        }
        assertNull(
            "a format nobody can classify has no capability to name",
            unsupportedReasonFor(PreviewKind.UNSUPPORTED, "archive.zip"),
        )
    }

    @Test
    fun `the extension rule agrees with the classifier's routing`() {
        assertEquals("gif", previewExtensionOf("anim.GIF"))
        assertEquals("gif", previewExtensionOf("a/b/anim.gif"))
        assertEquals("", previewExtensionOf(".env"))
        assertEquals("", previewExtensionOf("dir.d/file"))
        assertEquals("", previewExtensionOf("noext"))
        assertEquals("", previewExtensionOf("trailing."))
        // `gif` and `webm` are rendered now, so WEB_MEDIA is OGV alone and its
        // sentence must never answer for a format the classifier routed elsewhere.
        listOf("a.ogv").forEach { path ->
            assertEquals(path, PreviewKind.WEB_MEDIA, previewKindOf(path))
            assertTrue(path, previewExtensionOf(path) == "ogv")
        }
    }

    /** Every sentence the unsupported card can print, one per kind (WEB_MEDIA ×3). */
    private fun allReasons(): List<String> = buildList {
        // `gif` and `webm` render now, so they contribute no sentence.
        listOf("slides.pptx", "page.html", "cube.gltf", "clip.ogv")
            .forEach { path ->
                unsupportedReasonFor(previewKindOf(path), path)?.let { add(it) }
            }
    }
}
