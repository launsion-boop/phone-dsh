// phone-dsh — :platform-android unit test: the on-demand Ubuntu rootfs store.
// SPDX-License-Identifier: MIT
//
// What these tests pin: a verified archive is the only thing that becomes the
// installed tree, a wrong SHA or a small disk installs nothing, the extractor
// cannot be steered outside its root (entry path, absolute path, symlink
// target, device node), a refused hardlink falls back to a copy, and delete
// removes both the tree and the cached tarball. Every fixture is generated in a
// temp directory; no network, SDK or device is used.

package com.phonedsh.platform.android

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.util.zip.GZIPOutputStream
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UbuntuRootfsStoreTest {
    private fun sha256(bytes: ByteArray): String =
        java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }

    private fun spec(
        bytes: ByteArray,
        sha: String = sha256(bytes),
        version: String = "24.04.5",
    ): UbuntuRootfsSpec = UbuntuRootfsSpec(
        version = version,
        url = "https://example.invalid/ubuntu-base.tar.gz",
        sha256 = sha,
        archiveBytes = bytes.size.toLong(),
        extractedBytes = bytes.size.toLong().coerceAtLeast(1L),
    )

    private fun store(
        root: Path,
        bytes: ByteArray,
        spec: UbuntuRootfsSpec = spec(bytes),
        available: Long = Long.MAX_VALUE,
        link: ((target: Path, source: Path) -> Unit)? = null,
    ): UbuntuRootfsStore = UbuntuRootfsStore(
        filesDir = root,
        spec = spec,
        download = RootfsDownload { ByteArrayInputStream(bytes) },
        availableBytes = { available },
        link = link ?: { target, source ->
            Files.createLink(target, source)
            Unit
        },
    )

    // ---------------------------------------------------------------- install
    @Test
    fun a_verified_archive_installs_atomically_with_marker_and_modes() = runBlocking {
        val root = Files.createTempDirectory("pdsh-rootfs-ok")
        try {
            val bytes = tarGz(
                TarEntry.dir("bin"),
                TarEntry.file("bin/uname", "#!/bin/sh\necho Linux\n", mode = 0b111_101_101),
                TarEntry.symlink("bin/sh", "/usr/bin/dash"),
                TarEntry.dir("usr"),
                TarEntry.dir("usr/bin"),
                TarEntry.file("usr/bin/dash", "dash\n"),
                TarEntry.file("usr/bin/perl", "perl\n"),
                TarEntry.hardlink("usr/bin/perl5.38.2", "usr/bin/perl"),
            )
            val store = store(root, bytes)
            val result = store.ensureInstalled()
            assertTrue("expected Ready, was $result", result is UbuntuRootfsResult.Ready)
            val ready = result as UbuntuRootfsResult.Ready
            assertEquals("24.04.5", ready.version)
            assertEquals(store.rootfsDir, ready.rootfs)
            assertEquals("24.04.5", store.installedVersion())
            assertTrue(Files.isRegularFile(store.rootfsDir.resolve("bin/uname")))
            assertTrue(Files.isExecutable(store.rootfsDir.resolve("bin/uname")))
            assertEquals(
                "perl\n",
                String(Files.readAllBytes(store.rootfsDir.resolve("usr/bin/perl5.38.2")), StandardCharsets.UTF_8),
            )
            // An absolute in-guest symlink is stored relative to the root so a
            // host read cannot leave the installation directory.
            val link = Files.readSymbolicLink(store.rootfsDir.resolve("bin/sh"))
            assertFalse(link.isAbsolute)
            assertTrue(Files.isRegularFile(store.rootfsDir.resolve("bin/sh")))
            // The second call is a cache hit and starts no download.
            var downloads = 0
            val cached = UbuntuRootfsStore(
                filesDir = root,
                spec = store.specForTest(),
                download = RootfsDownload {
                    downloads += 1
                    ByteArrayInputStream(bytes)
                },
            ).ensureInstalled()
            assertTrue(cached is UbuntuRootfsResult.Ready)
            assertEquals(0, downloads)
        } finally {
            deleteTree(root)
        }
    }

    @Test
    fun a_sha_mismatch_installs_nothing_and_removes_the_partial_download() = runBlocking {
        val root = Files.createTempDirectory("pdsh-rootfs-sha")
        try {
            val bytes = tarGz(TarEntry.dir("bin"), TarEntry.file("bin/uname", "x"))
            val store = store(root, bytes, spec = spec(bytes, sha = "0".repeat(64)))
            val result = store.ensureInstalled()
            assertTrue(result is UbuntuRootfsResult.Failed)
            assertEquals("sha256_mismatch", (result as UbuntuRootfsResult.Failed).reason)
            assertNull(store.installedVersion())
            assertFalse(Files.exists(store.rootfsDir))
            assertFalse(Files.exists(store.archiveFile))
            assertFalse(Files.exists(store.archiveFile.resolveSibling("${store.archiveFile.fileName}.part")))
        } finally {
            deleteTree(root)
        }
    }

    @Test
    fun a_small_disk_is_refused_before_a_download_starts() = runBlocking {
        val root = Files.createTempDirectory("pdsh-rootfs-disk")
        try {
            val bytes = tarGz(TarEntry.file("bin/uname", "x"))
            val store = store(root, bytes, available = 1024L)
            val result = store.ensureInstalled()
            assertEquals(
                "insufficient_disk_space",
                (result as UbuntuRootfsResult.Failed).reason,
            )
            assertFalse(Files.exists(store.archiveFile))
        } finally {
            deleteTree(root)
        }
    }

    // ---------------------------------------------------------------- safety
    @Test
    fun a_dotdot_entry_is_refused_and_nothing_is_written_outside() = runBlocking {
        val root = Files.createTempDirectory("pdsh-rootfs-dotdot")
        try {
            val escape = root.parent.resolve("pdsh-rootfs-escape.txt")
            Files.deleteIfExists(escape)
            val bytes = tarGz(
                TarEntry.dir("bin"),
                TarEntry.file("bin/uname", "x"),
                TarEntry.file("../pdsh-rootfs-escape.txt", "owned\n"),
            )
            val result = store(root, bytes).ensureInstalled()
            assertEquals("unsafe_path", (result as UbuntuRootfsResult.Failed).reason)
            assertFalse(Files.exists(escape))
            assertFalse(Files.exists(root.resolve("rootfs").resolve("24.04.5")))
            assertNoPartialTree(root.resolve("rootfs"))
        } finally {
            deleteTree(root)
        }
    }

    @Test
    fun an_absolute_entry_path_is_refused() = runBlocking {
        val root = Files.createTempDirectory("pdsh-rootfs-absolute")
        try {
            val bytes = tarGz(
                TarEntry.dir("bin"),
                TarEntry.file("bin/uname", "x"),
                TarEntry.file("/etc/passwd", "root::0:0\n"),
            )
            val result = store(root, bytes).ensureInstalled()
            assertEquals("unsafe_path", (result as UbuntuRootfsResult.Failed).reason)
            assertFalse(Files.exists(root.resolve("rootfs").resolve("24.04.5")))
            assertNoPartialTree(root.resolve("rootfs"))
        } finally {
            deleteTree(root)
        }
    }

    @Test
    fun a_symlink_that_resolves_outside_the_root_is_refused() = runBlocking {
        val root = Files.createTempDirectory("pdsh-rootfs-symlink")
        try {
            val bytes = tarGz(
                TarEntry.dir("bin"),
                TarEntry.file("bin/uname", "x"),
                TarEntry.symlink("escape", "../../outside"),
            )
            val result = store(root, bytes).ensureInstalled()
            assertEquals("unsafe_path", (result as UbuntuRootfsResult.Failed).reason)
            assertFalse(Files.exists(root.resolve("rootfs").resolve("24.04.5")))
            assertNoPartialTree(root.resolve("rootfs"))
        } finally {
            deleteTree(root)
        }
    }

    @Test
    fun a_device_node_entry_is_refused_rather_than_skipped() = runBlocking {
        val root = Files.createTempDirectory("pdsh-rootfs-device")
        try {
            val bytes = tarGz(
                TarEntry.dir("bin"),
                TarEntry.file("bin/uname", "x"),
                TarEntry(name = "dev/null", type = '3'),
            )
            val result = store(root, bytes).ensureInstalled()
            assertEquals("unsupported_entry", (result as UbuntuRootfsResult.Failed).reason)
            assertFalse(Files.exists(root.resolve("rootfs").resolve("24.04.5")))
            assertNoPartialTree(root.resolve("rootfs"))
        } finally {
            deleteTree(root)
        }
    }

    // --------------------------------------------------------------- hardlink
    @Test
    fun a_refused_hardlink_falls_back_to_a_byte_copy() = runBlocking {
        val root = Files.createTempDirectory("pdsh-rootfs-link")
        try {
            val bytes = tarGz(
                TarEntry.dir("bin"),
                TarEntry.file("bin/uname", "x"),
                TarEntry.dir("usr"),
                TarEntry.dir("usr/bin"),
                TarEntry.file("usr/bin/perl", "perl bytes\n"),
                TarEntry.hardlink("usr/bin/perl5.38.2", "usr/bin/perl"),
            )
            val store = store(root, bytes, link = { _, _ -> throw IOException("link refused") })
            val result = store.ensureInstalled()
            assertTrue("expected Ready, was $result", result is UbuntuRootfsResult.Ready)
            assertEquals(
                "perl bytes\n",
                String(Files.readAllBytes(store.rootfsDir.resolve("usr/bin/perl5.38.2")), StandardCharsets.UTF_8),
            )
        } finally {
            deleteTree(root)
        }
    }

    // ----------------------------------------------------------------- delete
    @Test
    fun delete_removes_the_installed_tree_and_cached_archive() = runBlocking {
        val root = Files.createTempDirectory("pdsh-rootfs-delete")
        try {
            val bytes = tarGz(TarEntry.dir("bin"), TarEntry.file("bin/uname", "x"))
            val store = store(root, bytes)
            assertTrue(store.ensureInstalled() is UbuntuRootfsResult.Ready)
            store.delete()
            assertNull(store.installedVersion())
            assertFalse(Files.exists(store.rootfsDir))
            assertFalse(Files.exists(store.archiveFile))
        } finally {
            deleteTree(root)
        }
    }

    /** No half-extracted `.partial` directory survives a refused archive. */
    private fun assertNoPartialTree(parent: Path) {
        if (!Files.isDirectory(parent)) return
        Files.list(parent).use { stream ->
            val partials = stream.filter { it.fileName.toString().endsWith(".partial") }.toList()
            assertTrue("a partial tree survived: $partials", partials.isEmpty())
        }
    }

    // ---- fixture helpers -------------------------------------------------

    private fun UbuntuRootfsStore.specForTest(): UbuntuRootfsSpec = UbuntuRootfsSpec(
        version = "24.04.5",
        url = "https://example.invalid/ubuntu-base.tar.gz",
        sha256 = java.security.MessageDigest.getInstance("SHA-256")
            .digest(Files.readAllBytes(archiveFile))
            .joinToString("") { "%02x".format(it) },
        archiveBytes = Files.size(archiveFile),
        extractedBytes = 1L,
    )

    private data class TarEntry(
        val name: String,
        val type: Char = '0',
        val data: ByteArray = ByteArray(0),
        val linkName: String = "",
        val mode: Int = 0b111_101_101,
    ) {
        companion object {
            fun dir(name: String): TarEntry = TarEntry(name = name, type = '5', mode = 0b111_101_101)
            fun file(name: String, data: String, mode: Int = 0b111_101_101): TarEntry =
                TarEntry(name = name, data = data.toByteArray(StandardCharsets.UTF_8), mode = mode)
            fun symlink(name: String, target: String): TarEntry =
                TarEntry(name = name, type = '2', linkName = target)
            fun hardlink(name: String, target: String): TarEntry =
                TarEntry(name = name, type = '1', linkName = target)
        }
    }

    private fun tarGz(vararg entries: TarEntry): ByteArray {
        val raw = ByteArrayOutputStream()
        for (entry in entries) {
            raw.write(tarHeader(entry))
            if (entry.data.isNotEmpty()) {
                raw.write(entry.data)
                val padding = (512 - (entry.data.size % 512)) % 512
                raw.write(ByteArray(padding))
            }
        }
        raw.write(ByteArray(1024))
        val compressed = ByteArrayOutputStream()
        GZIPOutputStream(compressed).use { it.write(raw.toByteArray()) }
        return compressed.toByteArray()
    }

    private fun tarHeader(entry: TarEntry): ByteArray {
        val header = ByteArray(512)
        writeAscii(header, 0, entry.name, 100)
        writeOctal(header, 100, entry.mode.toLong(), 8)
        writeOctal(header, 108, 0, 8)
        writeOctal(header, 116, 0, 8)
        writeOctal(header, 124, entry.data.size.toLong(), 12)
        writeOctal(header, 136, 0, 12)
        writeAscii(header, 148, "        ", 8)
        header[156] = entry.type.code.toByte()
        writeAscii(header, 157, entry.linkName, 100)
        writeAscii(header, 257, "ustar", 5)
        header[262] = 0
        writeAscii(header, 263, "00", 2)
        writeAscii(header, 265, "root", 32)
        writeAscii(header, 297, "root", 32)
        writeOctal(header, 329, 0, 8)
        writeOctal(header, 337, 0, 8)
        writeAscii(header, 345, "", 155)
        var sum = 0L
        for (byte in header) sum += byte.toInt() and 0xFF
        writeAscii(header, 148, "%06o".format(sum) + "\u0000 ", 8)
        return header
    }

    private fun writeAscii(target: ByteArray, offset: Int, value: String, length: Int) {
        val bytes = value.toByteArray(StandardCharsets.UTF_8)
        bytes.copyInto(target, offset, 0, minOf(bytes.size, length))
    }

    private fun writeOctal(target: ByteArray, offset: Int, value: Long, length: Int) {
        writeAscii(target, offset, "%0${length - 1}o".format(value), length)
    }

}
