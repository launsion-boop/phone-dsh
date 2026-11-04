// The paged text read: 512 KiB pages that never split a UTF-8 scalar.
// SPDX-License-Identifier: MIT
//
// Mirror source: `PreviewSurface.swift:112` (`pageBytes`), `:187`–`:195`
// (`looksLikeText`) and `:197`–`:228` (`loadNextTextPage`) of iOS PR #15. The
// baseline replaced a 200-line / 256 KiB hard truncation with a real page window,
// and the two properties that made it work are the two this file owns:
//
//   1. **512 KiB per page**, read with `seek` + `read`, so a 200 MB log opens
//      instantly and `加载更多` appends the next window.
//   2. **A page boundary never splits a multi-byte scalar.** The baseline trims
//      bytes from the *end* of the page until it decodes (`while 解码失败
//      removeLast`), and the next page starts at `offset + kept`, so the trimmed
//      bytes are re-read rather than lost.
//
// The trim is "the longest valid UTF-8 prefix of the page". The baseline computes
// it by decoding the buffer once per removed byte; here a single `CharsetDecoder`
// pass reports the position of the first malformed byte, which is the same answer
// in one pass — a page of random bytes would otherwise cost 512 Ki decode attempts
// (`PreviewPagerTest` pins the equivalence and the speed).
//
// Two deviations, both documented at the call site and pinned by tests:
//
//   * **`eof` comes from the file, not from the trimmed buffer.** The baseline
//     derives it from `data.count < pageBytes` *after* trimming, so a page that
//     had to trim one scalar reports end-of-file early: a 1 MB file whose 512 KiB
//     boundary lands inside a multi-byte character silently loses its second half.
//     Comparing the bytes the file actually returned against the requested size is
//     the fact the reader has.
//   * **A page that starts inside a binary run cannot stall the reader.** The
//     baseline's loop would keep the same offset forever; here such a page is
//     marked ([PreviewTextPage.stalled]) and the next page steps past it, so a
//     `.txt` with a binary tail ends with an honest notice instead of a loop that
//     spins on 加载更多.
package com.phonedsh.ui.surface.preview

import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.file.Path

/**
 * One page of a file, as bytes and as text.
 *
 * @param text the decodable prefix of the page; the bytes that did not form a
 *   complete UTF-8 scalar at the tail are **not** included and are re-read by the
 *   next page.
 * @param nextOffset where the next page starts (`offset + bytesKept`).
 * @param eof true when this page reached the end of the file.
 * @param bytesKept how many bytes of this page became [text].
 * @param stalled true when the page *starts* with bytes that are not UTF-8; the
 *   page is then empty text and [nextOffset] steps past the read window so the
 *   reader always makes progress.
 */
public data class PreviewTextPage(
    public val text: String,
    public val nextOffset: Long,
    public val eof: Boolean,
    public val bytesKept: Int,
    public val stalled: Boolean = false,
)

/** The longest decodable UTF-8 prefix of a byte buffer. */
internal data class DecodedPrefix(public val bytesKept: Int, public val text: String)

/**
 * The page size and the byte reads of the preview face.
 *
 * Every function is blocking IO by design: the route calls them on
 * `Dispatchers.IO`, and keeping them synchronous is what makes them testable on the
 * JVM against a real temporary file instead of a mocked stream.
 */
public object PreviewPager {
    /** `PreviewSurface.swift:112`: 512 KiB, the baseline's one page size. */
    public const val PAGE_BYTES: Int = 512 * 1024

    /** `:190`: the sniff window (first 4 KiB). */
    public const val SNIFF_BYTES: Int = 4096

    /** `:192`–`:193`: at most 1 % of the sniff window may be control bytes. */
    private const val CONTROL_PERCENT: Int = 100

    /** `\t`, `\n` and `\r` are text; anything else below 0x20 is a control byte. */
    private const val CONTROLS_INVISIBLE_BELOW: Int = 0x09
    private const val CONTROLS_ALLOWED_UP_TO: Int = 0x0D
    private const val CONTROLS_INVISIBLE_FROM: Int = 0x20
    private const val BYTE_MASK: Int = 0xFF

    /**
     * Reads one page starting at [offset].
     *
     * @throws IOException when the file cannot be opened, seeked or read; the
     *   caller turns that into `读取文件失败：<reason>` (the baseline's `:224`).
     */
    public fun readPage(
        file: Path,
        offset: Long,
        pageBytes: Int = PAGE_BYTES,
    ): PreviewTextPage {
        require(offset >= 0) { "a page offset is never negative" }
        require(pageBytes > 0) { "a page is never empty" }
        RandomAccessFile(file.toFile(), "r").use { handle ->
            val length = handle.length()
            if (offset >= length) {
                // A file truncated between two pages: the offset is now past the
                // end, which is an end-of-file, not an error.
                return PreviewTextPage(text = "", nextOffset = length, eof = true, bytesKept = 0)
            }
            handle.seek(offset)
            val raw = ByteArray(minOf(pageBytes.toLong(), length - offset).toInt())
            var read = 0
            while (read < raw.size) {
                val got = handle.read(raw, read, raw.size - read)
                if (got < 0) break
                read += got
            }
            val page = if (read == raw.size) raw else raw.copyOf(read)
            val decoded = decodeLongestPrefix(page)
            val stalled = decoded.bytesKept == 0 && page.isNotEmpty()
            // `eof` is about the file, not about the trimmed buffer (see header).
            val eof = offset + read >= length
            return PreviewTextPage(
                text = decoded.text,
                nextOffset = offset + if (stalled) read else decoded.bytesKept,
                eof = eof,
                bytesKept = if (stalled) 0 else decoded.bytesKept,
                stalled = stalled,
            )
        }
    }

    /**
     * The baseline's `looksLikeText`: is the head of this file UTF-8 text?
     *
     * The rules are the baseline's three (`:190`–`:193`): a non-empty read, no NUL
     * byte, valid UTF-8, and fewer than 1 % control characters. One refinement: the
     * 4 KiB window can end in the middle of a scalar, which would make Foundation's
     * `String(data:encoding:)` answer `nil` and mis-classify a perfectly good text
     * file as binary; the window is decoded to its longest valid prefix first, and
     * only the tail is dropped.
     */
    public fun looksLikeText(file: Path, sniffBytes: Int = SNIFF_BYTES): Boolean {
        val head = readHead(file, sniffBytes) ?: return false
        if (head.isEmpty()) return false
        if (head.any { it.toInt() == 0 }) return false
        val decoded = decodeLongestPrefix(head)
        // `:191`: the whole window must decode; a file whose *first* bytes are
        // already invalid is not text (the tail-trim above is the only leniency).
        if (decoded.bytesKept == 0) return false
        val prefix = if (decoded.bytesKept == head.size) head else head.copyOf(decoded.bytesKept)
        val controls = prefix.count { byte ->
            val value = byte.toInt() and BYTE_MASK
            value < CONTROLS_INVISIBLE_BELOW ||
                (value > CONTROLS_ALLOWED_UP_TO && value < CONTROLS_INVISIBLE_FROM)
        }
        return controls * CONTROL_PERCENT <= prefix.size
    }

    /** The first [sniffBytes] of the file, or `null` when it cannot be read. */
    private fun readHead(file: Path, sniffBytes: Int): ByteArray? = try {
        RandomAccessFile(file.toFile(), "r").use { handle ->
            val buffer = ByteArray(sniffBytes)
            var read = 0
            while (read < sniffBytes) {
                val got = handle.read(buffer, read, sniffBytes - read)
                if (got < 0) break
                read += got
            }
            buffer.copyOf(read)
        }
    } catch (_: IOException) {
        null
    }
}

/**
 * Decodes the longest prefix of [bytes] that is complete UTF-8.
 *
 * One `CharsetDecoder` pass: on a malformed sequence it reports the input position
 * of the offending byte, and everything before it is the answer. This is exactly
 * the value the baseline's `removeLast` loop converges on, computed in `O(n)`
 * instead of `O(n²)`.
 */
internal fun decodeLongestPrefix(bytes: ByteArray): DecodedPrefix {
    if (bytes.isEmpty()) return DecodedPrefix(0, "")
    val decoder = Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
    val input = ByteBuffer.wrap(bytes)
    // UTF-8 never produces more chars than bytes, so this buffer cannot overflow.
    val output = CharBuffer.allocate(bytes.size + 1)
    return try {
        val result = decoder.decode(input, output, true)
        if (result.isError) {
            output.flip()
            DecodedPrefix(input.position(), output.toString())
        } else {
            decoder.flush(output)
            output.flip()
            DecodedPrefix(bytes.size, output.toString())
        }
    } catch (_: CharacterCodingException) {
        DecodedPrefix(0, "")
    }
}
