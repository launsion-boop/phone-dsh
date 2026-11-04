// The preview's safety boundary, item by item against `PreviewSurface.swift:37`.
// SPDX-License-Identifier: MIT
//
// The three properties this file exists for are the three an audit must be able to
// read off a green test rather than off a comment:
//
//   * a `..` segment is refused **before** the disk is touched, in any spelling —
//     including a percent-encoded one (`%2E%2E`) and one that would stay inside the
//     root (`a/../b`);
//   * containment is checked twice — lexically and again after symlink resolution —
//     so a link planted inside the workspace cannot hand out a file outside it;
//   * only a regular file resolves; a directory is its own answer.
package com.phonedsh.ui.surface.preview

import java.nio.file.Files
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PreviewPathResolverTest {

    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var root: Path

    @Before
    fun setUp() {
        root = temporary.newFolder("workspace").toPath()
    }

    // ------------------------------------------------------------------ normalize

    @Test
    fun `normalize strips the four prefixes, decodes and trims`() {
        assertEquals("notes.txt", PreviewPathResolver.normalize("notes.txt"))
        assertEquals("notes.txt", PreviewPathResolver.normalize("  notes.txt\n"))
        assertEquals("notes.txt", PreviewPathResolver.normalize("file://notes.txt"))
        assertEquals("notes.txt", PreviewPathResolver.normalize("sandbox:notes.txt"))
        assertEquals(
            "src/Main.kt",
            PreviewPathResolver.normalize("/dsh/workspace/src/Main.kt"),
        )
        assertEquals("src/Main.kt", PreviewPathResolver.normalize("./src/Main.kt"))
        assertEquals("src/Main.kt", PreviewPathResolver.normalize("/src/Main.kt/"))
        assertEquals("中文.md", PreviewPathResolver.normalize("%E4%B8%AD%E6%96%87.md"))
        // `+` is a literal plus in a path; URLDecoder would have eaten it.
        assertEquals("a+b.txt", PreviewPathResolver.normalize("a+b.txt"))
    }

    @Test
    fun `normalize is idempotent and NFC-normalized`() {
        val nfd = "e\u0301.txt" // e + combining acute
        assertEquals("é.txt", PreviewPathResolver.normalize(nfd))
        val once = PreviewPathResolver.normalize("file:///dsh/workspace/./a/b.txt")
        assertEquals(once, PreviewPathResolver.normalize(once))
        assertEquals("a/b.txt", once)
    }

    @Test
    fun `a malformed percent escape keeps the input`() {
        assertEquals("100%.txt", PreviewPathResolver.normalize("100%.txt"))
        assertEquals("%zz.txt", PreviewPathResolver.normalize("%zz.txt"))
    }

    // -------------------------------------------------------------------- resolve

    @Test
    fun `a regular file inside the root resolves with its measured size`() {
        write("notes.txt", "hello")
        val resolved = PreviewPathResolver.resolve(root, "notes.txt")
        assertTrue("expected a resolved file, got $resolved", resolved is PreviewResolution.Resolved)
        resolved as PreviewResolution.Resolved
        assertEquals("notes.txt", resolved.relativePath)
        assertEquals(5L, resolved.sizeBytes)
        assertEquals("hello", readText(resolved.file))
    }

    @Test
    fun `a nested file resolves through its directories`() {
        write("src/main/Main.kt", "fun main() {}")
        val resolved = PreviewPathResolver.resolve(root, "/dsh/workspace/src/main/Main.kt")
        assertTrue(resolved is PreviewResolution.Resolved)
        assertEquals("src/main/Main.kt", resolved.relativePath)
    }

    @Test
    fun `a missing file is retryable, not a refusal`() {
        val resolution = PreviewPathResolver.resolve(root, "later.txt")
        assertEquals(
            PreviewResolution.Unresolved("later.txt", PreviewUnresolved.MISSING),
            resolution,
        )
        assertTrue(PreviewUnresolved.MISSING.isRetryable)
    }

    @Test
    fun `a directory is its own answer`() {
        Files.createDirectories(root.resolve("folder"))
        val resolution = PreviewPathResolver.resolve(root, "folder")
        assertEquals(
            PreviewResolution.Unresolved("folder", PreviewUnresolved.NOT_A_FILE),
            resolution,
        )
        assertTrue(!PreviewUnresolved.NOT_A_FILE.isRetryable)
    }

    @Test
    fun `an empty path is refused`() {
        assertEquals(
            PreviewResolution.Unresolved("", PreviewUnresolved.REJECTED),
            PreviewPathResolver.resolve(root, "   "),
        )
    }

    @Test
    fun `a parent segment is refused in every spelling, before the disk is touched`() {
        write("inside.txt", "ok")
        write("sub/child.txt", "child")
        // Even a `..` that would stay inside the root is refused, exactly like
        // `PreviewSurface.swift:49` (`path.split(separator: "/").contains("..")`).
        assertEquals(
            PreviewResolution.Unresolved("sub/../inside.txt", PreviewUnresolved.REJECTED),
            PreviewPathResolver.resolve(root, "sub/../inside.txt"),
        )
        assertEquals(
            PreviewResolution.Unresolved("../outside.txt", PreviewUnresolved.REJECTED),
            PreviewPathResolver.resolve(root, "../outside.txt"),
        )
        // A percent-encoded parent segment decoded into the same refusal.
        assertEquals(
            PreviewResolution.Unresolved("../outside.txt", PreviewUnresolved.REJECTED),
            PreviewPathResolver.resolve(root, "%2E%2E/outside.txt"),
        )
        // And an escape with a deep tail.
        assertTrue(
            PreviewPathResolver.resolve(root, "a/b/../../../etc/passwd") is
                PreviewResolution.Unresolved,
        )
    }

    @Test
    fun `an absolute-spelled path is trimmed into the workspace, never the device root`() {
        val resolution = PreviewPathResolver.resolve(root, "/etc/passwd")
        // Same rule as Foundation: the leading `/` is trimmed, so the request becomes
        // a workspace-relative path and simply is not there.
        assertEquals("etc/passwd", resolution.relativePath)
        assertEquals(
            PreviewResolution.Unresolved("etc/passwd", PreviewUnresolved.MISSING),
            resolution,
        )
    }

    @Test
    fun `a symlink that escapes the root is refused after resolution`() {
        val outside = temporary.newFolder("outside").toPath()
        writeText(outside.resolve("secret.txt"), "secret")
        val link = root.resolve("escape.txt")
        Files.createSymbolicLink(link, outside.resolve("secret.txt"))
        // The lexical path has no `..` and starts with the root; only the resolved
        // comparison catches it (`PreviewSurface.swift:52`).
        assertEquals(
            PreviewResolution.Unresolved("escape.txt", PreviewUnresolved.REJECTED),
            PreviewPathResolver.resolve(root, "escape.txt"),
        )
    }

    @Test
    fun `a symlinked directory that escapes the root is refused too`() {
        val outside = temporary.newFolder("outside-dir").toPath()
        writeText(outside.resolve("secret.txt"), "secret")
        Files.createSymbolicLink(root.resolve("dirlink"), outside)
        assertEquals(
            PreviewResolution.Unresolved("dirlink/secret.txt", PreviewUnresolved.REJECTED),
            PreviewPathResolver.resolve(root, "dirlink/secret.txt"),
        )
    }

    @Test
    fun `a symlink that stays inside the root resolves to its target`() {
        write("real.txt", "content")
        Files.createSymbolicLink(root.resolve("alias.txt"), root.resolve("real.txt"))
        val resolution = PreviewPathResolver.resolve(root, "alias.txt")
        assertTrue(resolution is PreviewResolution.Resolved)
        resolution as PreviewResolution.Resolved
        assertEquals("alias.txt", resolution.relativePath)
        assertEquals(root.toRealPath().resolve("real.txt"), resolution.file)
    }

    @Test
    fun `a sibling directory with a shared name prefix is not inside the root`() {
        val evil = temporary.newFolder("workspace-evil").toPath()
        writeText(evil.resolve("secret.txt"), "secret")
        Files.createSymbolicLink(root.resolve("evil"), evil)
        // `root` + "-evil" shares a string prefix but not a path prefix.
        assertEquals(
            PreviewResolution.Unresolved("evil/secret.txt", PreviewUnresolved.REJECTED),
            PreviewPathResolver.resolve(root, "evil/secret.txt"),
        )
    }

    @Test
    fun `an NFD spelling finds an NFC file`() {
        write("café.txt", "ok")
        val resolution = PreviewPathResolver.resolve(root, "cafe\u0301.txt")
        assertTrue(resolution is PreviewResolution.Resolved)
        assertEquals("café.txt", resolution.relativePath)
    }

    @Test
    fun `a host with no workspace root says so instead of failing later`() {
        assertEquals(
            PreviewResolution.Unresolved("notes.txt", PreviewUnresolved.NO_WORKSPACE),
            PreviewPathResolver.resolve(null, "notes.txt"),
        )
        // A root that does not exist *yet* is the same answer, and it is retryable:
        // the host creates `materialized/workspace` on boot.
        val absent = root.resolve("not-created")
        assertEquals(
            PreviewResolution.Unresolved("notes.txt", PreviewUnresolved.NO_WORKSPACE),
            PreviewPathResolver.resolve(absent, "notes.txt"),
        )
        assertTrue(PreviewUnresolved.NO_WORKSPACE.isRetryable)
    }


    /** `Files.readString` is Java 11 and absent from the Android SDK stubs. */
    private fun readText(path: Path): String = String(Files.readAllBytes(path), Charsets.UTF_8)

    /** `Files.writeString` is Java 11 and absent from the Android SDK stubs. */
    private fun writeText(path: Path, content: String) {
        Files.write(path, content.toByteArray(Charsets.UTF_8))
    }

    private fun write(relative: String, content: String): Path {
        val target = root.resolve(relative)
        Files.createDirectories(target.parent)
        writeText(target, content)
        return target
    }
}
