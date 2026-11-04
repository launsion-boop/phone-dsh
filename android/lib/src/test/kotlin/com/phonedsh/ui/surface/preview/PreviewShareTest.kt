// The share path's pure half: which MIME type another app is offered.
// SPDX-License-Identifier: MIT
//
// The `content://` half (`FileProvider` + the chooser) needs a device and is proven
// by `PreviewShareDeviceTest`; this test pins the table that decides *which app can
// even see the file*. It is deliberately independent of `previewKindOf`: a `.docx`
// must be offered as a Word document even though this host has no renderer for it,
// and an unknown extension must be offered as `application/octet-stream` rather than
// guessed into a type the receiving app would refuse.
package com.phonedsh.ui.surface.preview

import org.junit.Assert.assertEquals
import org.junit.Test

class PreviewShareTest {

    @Test
    fun `each kind is offered under a type another app can claim`() {
        val table = mapOf(
            "notes.txt" to "text/plain",
            "notes.md" to "text/markdown",
            "page.html" to "text/html",
            "data.json" to "application/json",
            "conf.yml" to "application/x-yaml",
            "Main.kt" to "text/x-kotlin",
            "doc.pdf" to "application/pdf",
            "shot.png" to "image/png",
            "shot.jpg" to "image/jpeg",
            "shot.webp" to "image/webp",
            "anim.gif" to "image/gif",
            "movie.mp4" to "video/mp4",
            "song.wav" to "audio/wav",
            "cube.glb" to "model/gltf-binary",
            "cube.gltf" to "model/gltf+json",
            "report.docx" to
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "sheet.xlsx" to
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "deck.pptx" to
                "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "rich.rtf" to "application/rtf",
            "archive.tar.gz" to "application/octet-stream",
            "no-extension" to "application/octet-stream",
            "logo.svg" to "image/svg+xml",
        )
        table.forEach { (name, mime) ->
            assertEquals(name, mime, PreviewShare.mimeOf(name))
        }
    }

    @Test
    fun `the extension is matched case-insensitively and ignores directories`() {
        assertEquals("application/pdf", PreviewShare.mimeOf("docs/DOC.PDF"))
        assertEquals("image/png", PreviewShare.mimeOf("a/b/c/Shot.PNG"))
        assertEquals("application/octet-stream", PreviewShare.mimeOf("/a/b/README"))
    }

    @Test
    fun `the provider authority is the package plus the manifest suffix`() {
        // The manifest declares `${applicationId}.pdsh.preview`; this is the one
        // suffix both sides share, so a rename has to happen in two places at once.
        assertEquals(".pdsh.preview", PreviewShare.AUTHORITY_SUFFIX)
    }
}
