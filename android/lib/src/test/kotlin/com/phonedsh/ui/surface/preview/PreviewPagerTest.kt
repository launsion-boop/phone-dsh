// The 512 KiB page window, its UTF-8 boundary rule and the two deviations.
// SPDX-License-Identifier: MIT
//
// Three things the device cannot show and a JVM test can:
//
//   * a page boundary that lands inside a multi-byte scalar is trimmed and the
//     trimmed bytes are re-read by the next page (never lost, never replaced by
//     U+FFFD);
//   * `eof` comes from the file, not from the trimmed buffer — the baseline's
//     `data.count < pageBytes` loses the tail of a file whose page boundary straddles
//     a scalar, and this test is the one that would fail if that came back;
//   * a page that starts inside a binary run is marked and stepped over, so 加载更多
//     can never spin on the same offset.
package com.phonedsh.ui.surface.preview

import java.nio.file.Files
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PreviewPagerTest {

    @get:Rule
    val temporary = TemporaryFolder()

    private val page: Int = 4096

    @Test
    fun `a short file is one page and ends`() {
        val file = write("short.txt", "hello\nworld")
        val first = PreviewPager.readPage(file, 0, page)
        assertEquals("hello\nworld", first.text)
        assertTrue(first.eof)
        assertEquals(11L, first.nextOffset)
    }

    @Test
    fun `an empty file is an empty page at eof`() {
        val file = write("empty.txt", "")
        val first = PreviewPager.readPage(file, 0, page)
        assertEquals("", first.text)
        assertTrue(first.eof)
    }

    @Test
    fun `a file exactly one page long ends on the first page`() {
        val file = write("exact.txt", "a".repeat(page))
        assertTrue(PreviewPager.readPage(file, 0, page).eof)
    }

    @Test
    fun `pages are 512 KiB by default`() {
        assertEquals(512 * 1024, PreviewPager.PAGE_BYTES)
    }

    @Test
    fun `a page boundary inside a multi-byte scalar does not split it`() {
        // 512 'a' then a 3-byte scalar split across the boundary: the page keeps the
        // 'a's only, and the character arrives whole on the next page.
        val text = "a".repeat(page - 1) + "中" + "b"
        val file = write("boundary.txt", text)
        val first = PreviewPager.readPage(file, 0, page)
        assertEquals("a".repeat(page - 1), first.text)
        assertEquals((page - 1).toLong(), first.nextOffset)
        // The deviation: the buffer was trimmed by two bytes, the file still has
        // bytes, so this is *not* the end of the file.
        assertFalse(first.eof)
        val second = PreviewPager.readPage(file, first.nextOffset, page)
        assertEquals("中b", second.text)
        assertTrue(second.eof)
        assertEquals(text, first.text + second.text)
    }

    @Test
    fun `text longer than one page is appended page by page`() {
        val text = (0 until 12_000).joinToString("\n") { "line $it" }
        val file = write("long.log", text)
        val builder = StringBuilder()
        var offset = 0L
        var reads = 0
        while (true) {
            val next = PreviewPager.readPage(file, offset, page)
            builder.append(next.text)
            reads += 1
            if (next.eof) break
            offset = next.nextOffset
            assertTrue("paging did not advance", next.nextOffset > 0L)
            assertTrue("too many pages", reads < 500)
        }
        assertEquals(text, builder.toString())
        assertTrue("the file needs more than one page", reads > 1)
    }

    @Test
    fun `a page that starts inside a binary run is marked and stepped over`() {
        // A NUL-first byte, then enough ASCII to fill the window.
        val bytes = ByteArray(page * 2 + 16)
        // 0xFF is not a valid UTF-8 lead byte; NUL would have decoded as text.
        bytes[0] = 0xFF.toByte()
        for (index in 1 until bytes.size) bytes[index] = 'a'.code.toByte()
        val file = temporary.newFile("binary_tail.txt").toPath()
        Files.write(file, bytes)

        val first = PreviewPager.readPage(file, 0, page)
        assertEquals("", first.text)
        assertTrue(first.stalled)
        assertFalse(first.eof)
        // Progress is guaranteed even though no text was produced.
        assertEquals(page.toLong(), first.nextOffset)

        val second = PreviewPager.readPage(file, first.nextOffset, page)
        assertFalse(second.stalled)
        assertTrue(second.text.isNotEmpty())
    }

    @Test
    fun `reading past the end is an end-of-file, not an error`() {
        val file = write("truncated.txt", "abc")
        val beyond = PreviewPager.readPage(file, 10, page)
        assertEquals("", beyond.text)
        assertTrue(beyond.eof)
    }

    @Test
    fun `the sniff accepts UTF-8 text and refuses binary`() {
        val text = write("text.txt", "hello 中文 world\n")
        assertTrue(PreviewPager.looksLikeText(text))

        val binary = temporary.newFile("binary.bin").toPath()
        Files.write(binary, byteArrayOf(0x00, 0x01, 0x02, 0x03))
        assertFalse(PreviewPager.looksLikeText(binary))

        val latin1 = temporary.newFile("latin1.bin").toPath()
        Files.write(latin1, byteArrayOf(0xE4.toByte(), 0x20, 0x41))
        assertFalse("invalid UTF-8 is not text", PreviewPager.looksLikeText(latin1))

        val empty = write("empty.txt", "")
        assertFalse("the baseline requires a non-empty read", PreviewPager.looksLikeText(empty))
    }

    @Test
    fun `the sniff tolerates a scalar cut by the 4 KiB window`() {
        // A multi-byte scalar straddling the sniff window: Foundation's strict decode
        // would answer nil and call this file binary.
        val text = "a".repeat(PreviewPager.SNIFF_BYTES - 1) + "中"
        val file = write("straddle.txt", text)
        assertTrue(PreviewPager.looksLikeText(file))
    }

    @Test
    fun `the sniff refuses a file that is mostly control bytes`() {
        val bytes = ByteArray(PreviewPager.SNIFF_BYTES) { 0x01 }
        // One in ten is a printable 'a': still 90 % control.
        for (index in bytes.indices step 10) bytes[index] = 'a'.code.toByte()
        val file = temporary.newFile("control.bin").toPath()
        Files.write(file, bytes)
        assertFalse(PreviewPager.looksLikeText(file))
    }

    @Test
    fun `tabs and newlines are text, not control bytes`() {
        val bytes = "a\tb\nc\r\n".toByteArray()
        val file = temporary.newFile("tabs.txt").toPath()
        Files.write(file, bytes)
        assertTrue(PreviewPager.looksLikeText(file))
    }

    @Test
    fun `the longest valid prefix matches the remove-last loop it replaces`() {
        val cases = listOf(
            "".toByteArray(),
            "abc".toByteArray(),
            byteArrayOf(0xE4.toByte(), 0xB8.toByte()), // two of the three bytes of 中
            byteArrayOf('a'.code.toByte(), 0xFF.toByte(), 'b'.code.toByte()),
            byteArrayOf(0xFF.toByte(), 0xFF.toByte()),
        )
        cases.forEach { bytes ->
            val decoded = decodeLongestPrefix(bytes)
            // The reference: drop bytes from the end until the prefix decodes.
            var kept = bytes.size
            while (kept > 0 && decodeStrict(bytes.copyOf(kept)) == null) kept -= 1
            assertEquals("prefix length for ${bytes.size} bytes", kept, decoded.bytesKept)
            if (kept > 0) {
                assertEquals(decodeStrict(bytes.copyOf(kept)), decoded.text)
            }
        }
    }


    /** `Files.readString` is Java 11 and absent from the Android SDK stubs. */
    private fun readText(path: Path): String = String(Files.readAllBytes(path), Charsets.UTF_8)

    /** `Files.writeString` is Java 11 and absent from the Android SDK stubs. */
    private fun writeText(path: Path, content: String) {
        Files.write(path, content.toByteArray(Charsets.UTF_8))
    }

    private fun write(name: String, content: String): Path {
        val path = temporary.newFile(name).toPath()
        writeText(path, content)
        return path
    }
}
