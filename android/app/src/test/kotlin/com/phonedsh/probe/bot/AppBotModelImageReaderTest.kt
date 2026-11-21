// SPDX-License-Identifier: MIT
package com.phonedsh.probe.bot

import com.phonedsh.bot.attachments.BotModelAttachmentRequest
import com.phonedsh.bot.attachments.BotModelImage
import com.phonedsh.bot.attachments.BotModelImageError
import com.phonedsh.bot.attachments.BotModelImageException
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The Android workspace seam: containment is the preview resolver's tested
 * boundary, while this test pins the P26 behaviour on top of it — one bounded
 * read, an explicit missing/source refusal, and page selection in the PDF
 * path. Decoding itself is injected so the test never needs a device.
 */
class AppBotModelImageReaderTest {
    private lateinit var workspace: Path
    private lateinit var outside: Path

    @Before
    fun setUp() {
        workspace = Files.createTempDirectory("pdsh-bot-image-workspace-")
        outside = Files.createTempDirectory("pdsh-bot-image-outside-")
    }

    @After
    fun tearDown() {
        deleteTree(workspace)
        deleteTree(outside)
    }

    @Test
    fun aMaterializedWorkspaceFileIsReadThroughTheContainmentResolver() = runBlocking {
        val codec = RecordingCodec()
        val reader = AppBotModelImageReader(workspace, codec = codec)
        val bytes = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0x01)
        Files.write(workspace.resolve("photo.jpg"), bytes)

        val image = reader.read(
            BotModelAttachmentRequest(
                path = "/dsh/workspace/photo.jpg",
                purpose = "看看这张照片",
            ),
        )

        assertEquals("photo.jpg", image.name)
        assertEquals(1, codec.calls.get())
        assertTrue(bytes.contentEquals(codec.lastBytes))
        assertEquals("photo.jpg", codec.lastName)
    }

    @Test
    fun aPathOutsideTheWorkspaceIsRefusedBeforeAnyRead() = runBlocking {
        val codec = RecordingCodec()
        val reader = AppBotModelImageReader(workspace, codec = codec)
        Files.write(outside.resolve("secret.jpg"), byteArrayOf(0xFF.toByte(), 0xD8.toByte()))

        val failure = failure {
            reader.read(
                BotModelAttachmentRequest(
                    path = "../${outside.fileName}/secret.jpg",
                    purpose = "看看",
                ),
            )
        }

        assertEquals(BotModelImageError.UNAVAILABLE, failure.error)
        assertEquals(0, codec.calls.get())
    }

    @Test
    fun aSymlinkThatLeavesTheWorkspaceIsRefused() = runBlocking {
        val codec = RecordingCodec()
        val reader = AppBotModelImageReader(workspace, codec = codec)
        val target = outside.resolve("linked.jpg")
        Files.write(target, byteArrayOf(0xFF.toByte(), 0xD8.toByte()))
        val link = workspace.resolve("link.jpg")
        val created = runCatching { Files.createSymbolicLink(link, target) }.isSuccess
        if (!created) return@runBlocking

        val failure = failure {
            reader.read(BotModelAttachmentRequest(path = "link.jpg", purpose = "看看"))
        }

        assertEquals(BotModelImageError.UNAVAILABLE, failure.error)
        assertEquals(0, codec.calls.get())
    }

    @Test
    fun aMissingWorkspaceFileIsImageUnavailable() = runBlocking {
        val codec = RecordingCodec()
        val reader = AppBotModelImageReader(workspace, codec = codec)

        val failure = failure {
            reader.read(BotModelAttachmentRequest(path = "missing.jpg", purpose = "看看"))
        }

        assertEquals(BotModelImageError.UNAVAILABLE, failure.error)
        assertEquals(0, codec.calls.get())
    }

    @Test
    fun fileIdAndPhotoIdAreHonestlyUnsupportedOnAndroid() = runBlocking {
        val codec = RecordingCodec()
        val reader = AppBotModelImageReader(workspace, codec = codec)

        val fileId = failure {
            reader.read(BotModelAttachmentRequest(fileId = "art_1", purpose = "看看"))
        }
        assertEquals(BotModelImageError.UNSUPPORTED, fileId.error)
        assertTrue(fileId.message.orEmpty().contains("fileId"))

        val photoId = failure {
            reader.read(BotModelAttachmentRequest(photoId = "asset/local", purpose = "看看"))
        }
        assertEquals(BotModelImageError.UNSUPPORTED, photoId.error)
        assertTrue(photoId.message.orEmpty().contains("photoId"))
        assertEquals(0, codec.calls.get())
    }

    @Test
    fun thePdfPageIsClampedToTheFrozenOneToEightRange() = runBlocking {
        val codec = RecordingCodec()
        val pdf = RecordingPdfRenderer()
        val reader = AppBotModelImageReader(workspace, codec = codec, pdfRenderer = pdf)
        Files.write(workspace.resolve("scan.pdf"), "%PDF-1.4".toByteArray())

        val image = reader.read(
            BotModelAttachmentRequest(
                path = "scan.pdf",
                page = 9,
                purpose = "看看第 9 页",
            ),
        )

        assertEquals("scan-p8.jpg", image.name)
        assertEquals(8, pdf.pages.single())
        assertEquals(0, codec.calls.get())
    }

    @Test
    fun theBoundedReadRefusesOversizedInputs() = runBlocking {
        val codec = RecordingCodec()
        val reader = AppBotModelImageReader(workspace, codec = codec, maxInputBytes = 3)
        Files.write(workspace.resolve("big.jpg"), byteArrayOf(1, 2, 3, 4))

        val failure = failure {
            reader.read(BotModelAttachmentRequest(path = "big.jpg", purpose = "看看"))
        }

        assertEquals(BotModelImageError.TOO_LARGE, failure.error)
        assertEquals(0, codec.calls.get())
    }

    private fun failure(block: suspend () -> Unit): BotModelImageException = runBlocking {
        try {
            block()
            throw AssertionError("expected the reader to fail")
        } catch (error: BotModelImageException) {
            error
        }
    }

    private class RecordingCodec : BotModelImageCodec {
        val calls = AtomicInteger()
        var lastBytes: ByteArray? = null
        var lastName: String? = null

        override fun prepare(data: ByteArray, name: String): BotModelImage {
            calls.incrementAndGet()
            lastBytes = data
            lastName = name
            return BotModelImage(
                data = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0x03),
                name = name,
                pixelWidth = 120,
                pixelHeight = 80,
            )
        }
    }

    private class RecordingPdfRenderer : BotModelPdfPageRenderer {
        val pages = ArrayList<Int>()

        override fun render(file: Path, page: Int): BotModelImage {
            pages += page
            return BotModelImage(
                data = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0x04),
                name = "${file.fileName?.toString()?.substringBeforeLast('.')}-p$page.jpg",
                pixelWidth = 100,
                pixelHeight = 140,
            )
        }
    }

    private fun deleteTree(root: Path) {
        if (!Files.exists(root)) return
        Files.walk(root).use { stream ->
            stream.sorted(Comparator.reverseOrder()).forEach { runCatching { Files.deleteIfExists(it) } }
        }
    }
}
