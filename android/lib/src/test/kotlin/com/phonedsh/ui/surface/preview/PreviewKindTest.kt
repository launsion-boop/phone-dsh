// The eleven kinds, and the agreement with the files page's older classifier.
// SPDX-License-Identifier: MIT
//
// `PreviewKind` is a transcription of `PreviewSurface.swift:75`–`:103`. Two Android
// facts are pinned here as well:
//
//   * the `.svg` decision (unsupported, even though it is an image to a browser);
//   * the agreement with `FilesPage.classifyFileKind` on the kinds the two
//     classifiers share, so merging the two surfaces later cannot silently change
//     which body a path gets.
package com.phonedsh.ui.surface.preview

import com.phonedsh.ui.page.FileKind
import com.phonedsh.ui.page.classifyFileKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PreviewKindTest {

    @Test
    fun `the baseline extension table maps to the eleven kinds`() {
        val table = mapOf(
            "notes.md" to PreviewKind.MARKDOWN,
            "README.markdown" to PreviewKind.MARKDOWN,
            "page.html" to PreviewKind.HTML,
            "page.htm" to PreviewKind.HTML,
            "cube.glb" to PreviewKind.MODEL,
            "cube.gltf" to PreviewKind.MODEL,
            "anim.gif" to PreviewKind.IMAGE,
            "clip.webm" to PreviewKind.VIDEO,
            "clip.ogv" to PreviewKind.WEB_MEDIA,
            "shot.png" to PreviewKind.IMAGE,
            "shot.jpg" to PreviewKind.IMAGE,
            "shot.jpeg" to PreviewKind.IMAGE,
            "shot.webp" to PreviewKind.IMAGE,
            "shot.heic" to PreviewKind.IMAGE,
            "shot.heif" to PreviewKind.IMAGE,
            "shot.bmp" to PreviewKind.IMAGE,
            "shot.tiff" to PreviewKind.IMAGE,
            "doc.pdf" to PreviewKind.PDF,
            "doc.doc" to PreviewKind.OFFICE,
            "doc.docx" to PreviewKind.OFFICE,
            "sheet.xlsx" to PreviewKind.OFFICE,
            "deck.pptx" to PreviewKind.OFFICE,
            "rich.rtf" to PreviewKind.OFFICE,
            "book.epub" to PreviewKind.OFFICE,
            "movie.mp4" to PreviewKind.VIDEO,
            "movie.mov" to PreviewKind.VIDEO,
            "movie.m4v" to PreviewKind.VIDEO,
            "song.mp3" to PreviewKind.AUDIO,
            "song.m4a" to PreviewKind.AUDIO,
            "song.wav" to PreviewKind.AUDIO,
            "song.aac" to PreviewKind.AUDIO,
            "song.flac" to PreviewKind.AUDIO,
            "notes.txt" to PreviewKind.TEXT,
            "app.log" to PreviewKind.TEXT,
            "data.json" to PreviewKind.TEXT,
            "data.jsonl" to PreviewKind.TEXT,
            "conf.yaml" to PreviewKind.TEXT,
            "conf.yml" to PreviewKind.TEXT,
            "doc.xml" to PreviewKind.TEXT,
            "conf.toml" to PreviewKind.TEXT,
            "conf.ini" to PreviewKind.TEXT,
            "table.csv" to PreviewKind.TEXT,
            "table.tsv" to PreviewKind.TEXT,
            "post.mdx" to PreviewKind.TEXT,
            "Main.kt" to PreviewKind.TEXT,
            "build.gradle" to PreviewKind.TEXT,
            "query.sql" to PreviewKind.TEXT,
            "fix.patch" to PreviewKind.TEXT,
            "fix.diff" to PreviewKind.TEXT,
            "Info.plist" to PreviewKind.TEXT,
            "page.css" to PreviewKind.TEXT,
            "run.sh" to PreviewKind.TEXT,
            "Main.swift" to PreviewKind.TEXT,
            "Main.java" to PreviewKind.TEXT,
            "main.go" to PreviewKind.TEXT,
            "main.rs" to PreviewKind.TEXT,
            "main.py" to PreviewKind.TEXT,
            "main.ts" to PreviewKind.TEXT,
            "main.tsx" to PreviewKind.TEXT,
        )
        table.forEach { (path, kind) ->
            assertEquals(path, kind, previewKindOf(path))
        }
    }

    @Test
    fun `the extension is matched case-insensitively`() {
        assertEquals(PreviewKind.MARKDOWN, previewKindOf("README.MD"))
        assertEquals(PreviewKind.IMAGE, previewKindOf("SHOT.PNG"))
        assertEquals(PreviewKind.TEXT, previewKindOf("Main.KT"))
    }

    @Test
    fun `svg, archives and a dotfile are unclassified`() {
        // The baseline's own decision (`PreviewSurface.swift:83`): `.svg` is not an
        // image to the preview, even though the iOS page scheme serves it.
        assertEquals(PreviewKind.UNSUPPORTED, previewKindOf("logo.svg"))
        assertEquals(PreviewKind.UNSUPPORTED, previewKindOf("bundle.zip"))
        assertEquals(PreviewKind.UNSUPPORTED, previewKindOf("no-extension"))
        assertEquals(PreviewKind.UNSUPPORTED, previewKindOf(".env"))
        assertEquals(PreviewKind.UNSUPPORTED, previewKindOf("trailing."))
        assertEquals(PreviewKind.UNSUPPORTED, previewKindOf("archive.tar.gz"))
    }

    @Test
    fun `the sniff only upgrades an unclassified path`() {
        assertEquals(PreviewKind.TEXT, previewKindOf("no-extension", sniffedAsText = true))
        assertEquals(PreviewKind.TEXT, previewKindOf(".env", sniffedAsText = true))
        // A Markdown file whose bytes happen to be binary stays Markdown: the
        // baseline sniffs only inside the unsupported branch.
        assertEquals(PreviewKind.MARKDOWN, previewKindOf("notes.md", sniffedAsText = true))
        assertEquals(PreviewKind.IMAGE, previewKindOf("shot.png", sniffedAsText = true))
        assertEquals(
            PreviewKind.UNSUPPORTED,
            previewKindOf("logo.svg", sniffedAsText = false),
        )
    }

    @Test
    fun `six kinds have a renderer on this host`() {
        val rendered = PreviewKind.entries.filter { it.isRendered }.toSet()
        assertEquals(
            setOf(
                PreviewKind.TEXT,
                PreviewKind.MARKDOWN,
                PreviewKind.IMAGE,
                PreviewKind.PDF,
                // L32: the pair L29 §10 Q4 left open, drawn by one `MediaPlayer`.
                PreviewKind.VIDEO,
                PreviewKind.AUDIO,
            ),
            rendered,
        )
        listOf(
            PreviewKind.HTML,
            PreviewKind.OFFICE,
            PreviewKind.MODEL,
            PreviewKind.WEB_MEDIA,
            PreviewKind.UNSUPPORTED,
        ).forEach { kind ->
            assertFalse("$kind must not claim a renderer", kind.isRendered)
        }
    }

    @Test
    fun `video and audio are exactly PR15's extension sets`() {
        // The two sets this lane renders, spelled out so a future edit cannot quietly
        // absorb `webm`/`ogv`: PR15 routes those through the WebView page
        // (`PreviewSurface.swift:444`), not through the player, and this host still has
        // no second WebView.
        listOf("mp4", "mov", "m4v").forEach { extension ->
            assertEquals(".$extension", PreviewKind.VIDEO, previewKindOf("clip.$extension"))
        }
        listOf("mp3", "m4a", "wav", "aac", "flac").forEach { extension ->
            assertEquals(".$extension", PreviewKind.AUDIO, previewKindOf("song.$extension"))
        }
        // webMedia stays webMedia: it is another lane's architecture decision.
        assertEquals(PreviewKind.VIDEO, previewKindOf("clip.webm"))
        assertEquals(PreviewKind.WEB_MEDIA, previewKindOf("clip.ogv"))
    }

    @Test
    fun `the two Android classifiers agree on the kinds they share`() {
        val paths = listOf(
            "notes.md", "notes.markdown", "page.html", "page.htm", "notes.txt",
            "app.log", "data.json", "table.csv", "Main.kt", "build.gradle",
            "shot.png", "doc.pdf", "bundle.zip", "no-extension", "notes.swift",
        )
        paths.forEach { path ->
            val old = classifyFileKind(path)
            val new = previewKindOf(path)
            val expected = when (old) {
                FileKind.HTML -> PreviewKind.HTML
                FileKind.MARKDOWN -> PreviewKind.MARKDOWN
                FileKind.TEXT -> PreviewKind.TEXT
                // The old classifier sends everything else to Quick Look; the new one
                // is more specific, and "more specific than Quick Look" is exactly the
                // change this lane adds.
                FileKind.EXTERNAL -> null
            }
            if (expected != null) {
                assertEquals("$path: files page vs preview", expected, new)
            }
        }
    }

    @Test
    fun `a path in a sub-directory keeps its extension classification`() {
        assertEquals(PreviewKind.MARKDOWN, previewKindOf("docs/guide/intro.md"))
        assertEquals(PreviewKind.TEXT, previewKindOf("/dsh/workspace/a/b/c.txt"))
        assertTrue(previewKindOf("a/b/README").let { it == PreviewKind.UNSUPPORTED })
    }
}
