// phone-dsh — :engine / com.phonedsh.engine: WorkerAssets on the JVM.
// SPDX-License-Identifier: MIT
//
// The copy, the version stamp, the staging/swap and the progress reporting are
// plain file work, so they are tested here against a temp directory with a fake
// WorkerAssetSource. Only the APK asset listing (ApkWorkerAssetSource) needs a
// device and is covered by the instrumented test.

package com.phonedsh.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.CopyOnWriteArrayList

class WorkerAssetsTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private val logger = RecordingEngineLogger()

    @Test
    fun copiesTheBundleOnceAndReusesItWhileTheStampHolds() {
        val bundle = bundle("index.html" to "<html>v1</html>", "boot.js" to "console.log(1)")
        val filesDir = temporary.newFolder("files")
        val source = DirectoryAssetSource(bundle, "stamp-1")
        val assets = WorkerAssets(source, filesDir, logger)
        val progress = CopyOnWriteArrayList<WorkerAssetProgress>()

        val first = assets.materialize { progress += it }

        assertTrue(first.copied)
        assertEquals(2, first.files)
        assertEquals(
            ("<html>v1</html>".toByteArray() + "console.log(1)".toByteArray()).size.toLong(),
            first.bytes,
        )
        assertEquals("<html>v1</html>", File(first.directory.toFile(), "index.html").readText())
        assertEquals(listOf(1, 2), progress.map { it.filesCopied })
        assertEquals(2, source.opened.size)
        assertEquals("stamp-1", File(filesDir, WorkerAssets.VERSION_FILE).readText().trim())
        assertTrue(logger.contains("worker assets: copying 2 files"))
        assertTrue(logger.contains("worker assets: ready"))

        val second = assets.materialize()

        assertFalse(second.copied)
        assertEquals(2, second.files)
        assertEquals(2, source.opened.size) // no asset was read again
        assertTrue(logger.contains("worker assets: reusing worker"))
    }

    @Test
    fun recopiesFromScratchWhenTheStampChanges() {
        val bundle = bundle("index.html" to "v1", "boot.js" to "one")
        val filesDir = temporary.newFolder("files")
        WorkerAssets(DirectoryAssetSource(bundle, "stamp-1"), filesDir, logger).materialize()

        // A stale extra file from the previous bundle must not survive the swap.
        File(filesDir, "worker/stale.txt").writeText("old")
        File(bundle, "index.html").writeText("v2")
        val second = WorkerAssets(DirectoryAssetSource(bundle, "stamp-2"), filesDir, logger).materialize()

        assertTrue(second.copied)
        assertEquals("v2", File(second.directory.toFile(), "index.html").readText())
        assertFalse(File(filesDir, "worker/stale.txt").exists())
        assertEquals("stamp-2", File(filesDir, WorkerAssets.VERSION_FILE).readText().trim())
    }

    @Test
    fun aFailedCopyKeepsThePreviousBundleAndRetriesNextTime() {
        val bundle = bundle("index.html" to "v1", "boot.js" to "one")
        val filesDir = temporary.newFolder("files")
        WorkerAssets(DirectoryAssetSource(bundle, "stamp-1"), filesDir, logger).materialize()

        val failing = DirectoryAssetSource(bundle, "stamp-2", failOn = setOf("boot.js"))
        val failure = runCatching { WorkerAssets(failing, filesDir, logger).materialize() }.exceptionOrNull()

        assertTrue("expected the copy to fail", failure is IOException)
        assertEquals("v1", File(filesDir, "worker/index.html").readText())
        assertEquals("stamp-1", File(filesDir, WorkerAssets.VERSION_FILE).readText().trim())
        // No half-written staging directory is left behind.
        val leftovers = filesDir.listFiles().orEmpty().filter { it.name.startsWith(WorkerAssets.STAGING_PREFIX) }
        assertEquals(emptyList<File>(), leftovers)
        assertTrue(logger.contains("worker assets: copy failed, previous bundle kept"))

        // The previous stamp still matches, so the next start reuses the old copy
        // instead of failing again while the APK is unchanged.
        val reused = WorkerAssets(DirectoryAssetSource(bundle, "stamp-1"), filesDir, logger).materialize()
        assertFalse(reused.copied)
        assertEquals("v1", File(reused.directory.toFile(), "index.html").readText())
    }

    @Test
    fun rejectsABundleWithoutItsEntryPoint() {
        val bundle = bundle("boot.js" to "one")
        val filesDir = temporary.newFolder("files")
        val assets = WorkerAssets(DirectoryAssetSource(bundle, "stamp-1"), filesDir, logger)

        val failure = runCatching { assets.materialize() }.exceptionOrNull()

        assertTrue(failure is IOException)
        assertTrue(failure!!.message!!.contains("index.html"))
        assertFalse(File(filesDir, "worker").exists())
        assertFalse(File(filesDir, WorkerAssets.VERSION_FILE).exists())
    }

    @Test
    fun rejectsUnsafeAssetPaths() {
        val bundle = bundle("index.html" to "v1")
        val filesDir = temporary.newFolder("files")
        val escaping = object : WorkerAssetSource {
            override val versionStamp: String = "evil"
            override fun listAssets(): List<String> = listOf("../escaped.html")
            override fun open(assetPath: String): InputStream = File(bundle, "index.html").inputStream()
        }

        val failure = runCatching { WorkerAssets(escaping, filesDir, logger).materialize() }.exceptionOrNull()

        assertTrue(failure is IllegalArgumentException)
        assertFalse(File(temporary.root, "escaped.html").exists())
    }

    @Test
    fun removesAStaleStagingDirectoryBeforeCopying() {
        val bundle = bundle("index.html" to "v1")
        val filesDir = temporary.newFolder("files")
        val staging = File(filesDir, "${WorkerAssets.STAGING_PREFIX}42")
        check(staging.mkdirs()) { "cannot create $staging" }
        val stale = File(staging, "dead.txt")
        stale.writeText("dead")

        WorkerAssets(DirectoryAssetSource(bundle, "stamp-1"), filesDir, logger).materialize()

        assertFalse(staging.exists())
        assertTrue(logger.contains("worker assets: removed stale worker.staging-42"))
    }

    @Test
    fun copiesNestedDirectories() {
        val bundle = bundle(
            "index.html" to "root",
            "lazy/a.tar.gz" to "archive",
            "web/assets/app.js" to "js",
        )
        val filesDir = temporary.newFolder("files")

        val result = WorkerAssets(DirectoryAssetSource(bundle, "stamp-1"), filesDir, logger).materialize()

        assertTrue(result.copied)
        assertEquals(3, result.files)
        assertEquals("archive", File(result.directory.toFile(), "lazy/a.tar.gz").readText())
        assertEquals("js", File(result.directory.toFile(), "web/assets/app.js").readText())
    }

    /** Writes `relativePath to content` pairs under a fresh temp directory. */
    private fun bundle(vararg entries: Pair<String, String>): File {
        val root = temporary.newFolder()
        for ((relativePath, content) in entries) {
            val file = File(root, relativePath)
            file.parentFile?.mkdirs()
            file.writeText(content)
        }
        return root
    }

    /** A [WorkerAssetSource] over a temp directory; counts reads, can fail on purpose. */
    private class DirectoryAssetSource(
        private val root: File,
        override val versionStamp: String,
        private val failOn: Set<String> = emptySet(),
    ) : WorkerAssetSource {
        val opened = CopyOnWriteArrayList<String>()

        override fun listAssets(): List<String> = root.walkTopDown()
            .filter { it.isFile }
            .map { it.relativeTo(root).invariantSeparatorsPath }
            .sorted()
            .toList()

        override fun open(assetPath: String): InputStream {
            opened += assetPath
            if (assetPath in failOn) throw IOException("synthetic failure for $assetPath")
            return File(root, assetPath).inputStream()
        }
    }
}
