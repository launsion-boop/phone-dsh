// SPDX-License-Identifier: MIT
package com.phonedsh.ui.surface

import android.graphics.Bitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.surface.preview.PreviewPathResolver
import com.phonedsh.ui.surface.preview.PreviewUnresolved
import com.phonedsh.ui.surface.preview.WorkspacePreviewSource
import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URI
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import kotlinx.coroutines.runBlocking

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class MarkdownImageTest {
    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun `a standalone image paragraph preserves source alt and title while inline alt remains text`() {
        val standalone = MarkdownParser.parse("![diagram](https://images.example/diagram.png \"topology\")").single()
            as MarkdownBlock.Image
        assertEquals("https://images.example/diagram.png", standalone.source)
        assertEquals("diagram", standalone.alt)
        assertEquals("topology", standalone.title)

        val inline = MarkdownParser.parse("before ![diagram](https://images.example/diagram.png) after").single()
            as MarkdownBlock.Paragraph
        assertEquals("before diagram after", inline.inlines.joinToString("") { part ->
            when (part) {
                is MarkdownInline.Text -> part.text
                is MarkdownInline.Image -> part.alt
                else -> error("unexpected inline: $part")
            }
        })
    }

    @Test
    fun `local image routing keeps workspace and session identity under safe PreviewFileSource roots`() {
        val workspace = WorkspacePreviewSource(temporary.newFolder("workspace").toPath())
        val session = WorkspacePreviewSource(temporary.newFolder("session-A").toPath())
        val source = MarkdownImageSource(workspaceFiles = workspace, sessionFilesById = mapOf("session-A" to session))

        val relative = resolveMarkdownLocalImageRequest("images/diagram.png", source)
        assertSame(workspace, relative?.files)
        assertEquals("images/diagram.png", relative?.relativePath)
        val fileUri = resolveMarkdownLocalImageRequest("file:///dsh/workspace/images/diagram.png", source)
        assertSame(workspace, fileUri?.files)
        assertEquals("file:///dsh/workspace/images/diagram.png", fileUri?.relativePath)
        val sandbox = resolveMarkdownLocalImageRequest("sandbox:images/diagram.png", source)
        assertSame(workspace, sandbox?.files)

        val sessionUri = "dsh-resource://file/session/session-A/dsh/workspace/images/diagram.png"
        val sessionPath = resolveMarkdownLocalImageRequest(sessionUri, source)
        assertSame(session, sessionPath?.files)
        assertEquals("images/diagram.png", sessionPath?.relativePath)
        assertNull(resolveMarkdownLocalImageRequest(
            "dsh-resource://file/session/another-session/dsh/workspace/images/diagram.png",
            source,
        ))
        assertNull(resolveMarkdownLocalImageRequest("dsh-resource://file/absolute/etc/passwd", source))
        assertNull(resolveMarkdownLocalImageRequest("../outside.png", source))

        val unresolved = runBlocking { workspace.resolve("../outside.png") }
        assertEquals(PreviewUnresolved.REJECTED, (unresolved as com.phonedsh.ui.surface.preview.PreviewResolution.Unresolved).reason)
    }

    @Test
    fun `local bitmap load reads only a file resolved by PreviewFileSource`() = runBlocking {
        val root = temporary.newFolder("images").toPath()
        val imageFile = root.resolve("photo.png")
        Files.write(imageFile, pngFixture())
        val bitmap = loadMarkdownImage(
            source = "photo.png",
            imageSource = MarkdownImageSource(workspaceFiles = WorkspacePreviewSource(root)),
            remoteLoader = MarkdownRemoteImageLoader { error("local source must not invoke remote loader") },
        )
        assertNotNull(bitmap)
        assertEquals(8, bitmap!!.width)
        assertEquals(4, bitmap.height)

        val escaped = loadMarkdownImage(
            source = "../photo.png",
            imageSource = MarkdownImageSource(workspaceFiles = WorkspacePreviewSource(root)),
            remoteLoader = MarkdownRemoteImageLoader { error("unsafe local source must not invoke remote loader") },
        )
        assertNull(escaped)
    }

    @Test
    fun `bounded HTTP loader fetches a local scripted PNG without auth headers`() = runBlocking {
        val response = pngFixture()
        val fixture = LocalImageHttpFixture(status = 200, body = response)
        val bitmap = BoundedMarkdownRemoteImageLoader.load(fixture.uri)
        fixture.finish()
        assertNotNull(bitmap)
        assertEquals(8, bitmap!!.width)
        assertEquals(4, bitmap.height)
        val requestHeaders = fixture.requestHeaders.orEmpty()
        assertFalse(requestHeaders.any { it.startsWith("authorization:", ignoreCase = true) })
        assertFalse(requestHeaders.any { it.startsWith("cookie:", ignoreCase = true) })
    }

    @Test
    fun `remote 404 and oversized response resolve to unavailable`() = runBlocking {
        val missing = LocalImageHttpFixture(status = 404, body = byteArrayOf())
        assertNull(BoundedMarkdownRemoteImageLoader.load(missing.uri))
        missing.finish()

        val oversized = LocalImageHttpFixture(status = 200, body = byteArrayOf(), declaredLength = 8L * 1024L * 1024L + 1L)
        assertNull(BoundedMarkdownRemoteImageLoader.load(oversized.uri))
        oversized.finish()
    }

    private fun pngFixture(): ByteArray {
        val bitmap = Bitmap.createBitmap(8, 4, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.MAGENTA)
        return ByteArrayOutputStream().use { output ->
            assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
            output.toByteArray()
        }.also { bitmap.recycle() }
    }

    private class LocalImageHttpFixture(
        private val status: Int,
        private val body: ByteArray,
        private val declaredLength: Long = body.size.toLong(),
    ) {
        private val server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        private val executor = Executors.newSingleThreadExecutor()
        @Volatile var requestHeaders: List<String>? = null
            private set
        val uri: URI = URI("http://127.0.0.1:${server.localPort}/fixture.png")

        init {
            executor.submit {
                server.accept().use { socket ->
                    socket.soTimeout = 5_000
                    val reader = BufferedReader(InputStreamReader(socket.getInputStream(), StandardCharsets.US_ASCII))
                    val headers = mutableListOf<String>()
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (line.isEmpty()) break
                        headers += line
                    }
                    requestHeaders = headers
                    val reason = if (status == 200) "OK" else "Not Found"
                    val output = socket.getOutputStream()
                    output.write("HTTP/1.1 $status $reason\r\n".toByteArray(StandardCharsets.US_ASCII))
                    output.write("Content-Type: image/png\r\n".toByteArray(StandardCharsets.US_ASCII))
                    output.write("Content-Length: $declaredLength\r\n".toByteArray(StandardCharsets.US_ASCII))
                    output.write("Connection: close\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
                    if (status == 200 && body.isNotEmpty()) output.write(body)
                    output.flush()
                }
            }
        }

        fun finish() {
            server.close()
            executor.shutdown()
            assertTrue("scripted HTTP fixture did not finish", executor.awaitTermination(5, TimeUnit.SECONDS))
        }
    }
}
