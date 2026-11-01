// phone-dsh — :engine / com.phonedsh.engine: the zip bundle source on the JVM.
// SPDX-License-Identifier: MIT
//
// This test is the evidence for the packaging workaround: AGP's asset merge would
// gunzip `image.tar.gz` and drop the suffix, so the bundle ships as one zip asset.
// Here a zip is built exactly like `packageWorkerBundle` builds it, and the test
// asserts entry names and bytes come back unchanged.

package com.phonedsh.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class ZipWorkerAssetSourceTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private fun bundleZip(vararg entries: Pair<String, ByteArray>): File {
        val archive = File(temporary.newFolder(), "worker-bundle.zip")
        ZipOutputStream(archive.outputStream()).use { zip ->
            for ((name, content) in entries) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(content)
                zip.closeEntry()
            }
        }
        return archive
    }

    @Test
    fun keepsTheGzNamesAndBytesTheApkAssetPipelineWouldMangle() {
        // `image.tar.gz` here is a real gzip stream; AGP would have gunzipped it to
        // `image.tar` with different bytes. The zip keeps both name and bytes.
        val gzipped = gzip("image-tarball-bytes")
        val source = ZipWorkerAssetSource(
            bundleZip(
                "index.html" to "<html/>".toByteArray(),
                "image.tar.gz" to gzipped,
                "lazy/abc.tar.gz" to gzip("lazy-bytes"),
            ),
            "stamp-1",
        )

        val names = source.listAssets()
        assertEquals(listOf("image.tar.gz", "index.html", "lazy/abc.tar.gz"), names)
        assertEquals(gzipped.toList(), source.open("image.tar.gz").use { it.readBytes().toList() })
        assertEquals("stamp-1", source.versionStamp)

        source.close()
        assertFalse(source.isOpen)
    }

    @Test
    fun reportsAMissingEntryAsIoFailure() {
        val source = ZipWorkerAssetSource(bundleZip("index.html" to "page".toByteArray()), "stamp-1")
        val failure = runCatching { source.open("nope.js") }.exceptionOrNull()
        assertTrue(failure is IOException)
        source.close()
    }

    @Test
    fun materializesTheZipIntoTheWorkerDirectory() {
        val filesDir = temporary.newFolder("files")
        val logger = RecordingEngineLogger()
        val source = ZipWorkerAssetSource(
            bundleZip(
                "index.html" to "page-v1".toByteArray(),
                "lazy/x.tar.gz" to gzip("x"),
            ),
            "stamp-1",
        )

        val result = WorkerAssets(source, filesDir, logger).materialize()

        assertTrue(result.copied)
        assertEquals(2, result.files)
        assertEquals("page-v1", File(result.directory.toFile(), "index.html").readText())
        assertTrue(File(result.directory.toFile(), "lazy/x.tar.gz").length() > 0)
        assertFalse("the source closes the zip after materializing", source.isOpen)
    }

    private fun gzip(text: String): ByteArray {
        val sink = java.io.ByteArrayOutputStream()
        java.util.zip.GZIPOutputStream(sink).use { it.write(text.toByteArray()) }
        return sink.toByteArray()
    }
}
