// The workspace read: the directory the preview lists, and what a listing means.
// SPDX-License-Identifier: MIT
//
// Two things are asserted here that nothing else can:
//
//   * the library's `"xl"` is the *app's* `WORKSPACE_DIRECTORY`, read out of
//     `ProbeEngineViewModel.kt` at test time. `:lib` cannot depend on `:app`, so the
//     constant is duplicated; this test is what makes the duplicate a checked fact
//     instead of a comment that rots.
//   * a listing distinguishes "no workspace reported" (`null`) from "a workspace
//     with no files" (an empty list). The files page renders those differently and
//     a regression here would silently turn 等待引擎连接… into 「还没有文件」.
package com.phonedsh.ui.surface.preview

import com.phonedsh.ui.SpecFixtures
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PreviewWorkspaceTest {

    @get:Rule
    val temporary = TemporaryFolder()

    @Test
    fun `the library's workspace directory is the app's`() {
        val appSource = readText(
            SpecFixtures.repoRoot.resolve(
                "android/app/src/main/kotlin/com/phonedsh/probe/ProbeEngineViewModel.kt",
            ),
        )
        // The declaration is `const val WORKSPACE_DIRECTORY = "xl"` (the type is
        // inferred), so the pattern accepts both spellings.
        val match = Regex("""const val WORKSPACE_DIRECTORY(?:: String)? = "([^"]+)"""")
            .find(appSource)
        assertTrue("the app's WORKSPACE_DIRECTORY declaration moved", match != null)
        assertEquals(
            "PreviewWorkspace.DIRECTORY must match :app's WORKSPACE_DIRECTORY",
            match!!.groupValues[1],
            PreviewWorkspace.DIRECTORY,
        )
    }

    @Test
    fun `the default root is the materialized workspace under the app files dir`() {
        val root = PreviewWorkspace.defaultRoot(java.io.File("/data/user/0/app/files"))
        assertEquals(
            "/data/user/0/app/files/xl/materialized/workspace",
            root.toString(),
        )
        assertEquals("xl", PreviewWorkspace.DIRECTORY)
        assertEquals("materialized", PreviewWorkspace.MATERIALIZED)
        assertEquals("workspace", PreviewWorkspace.WORKSPACE)
    }

    @Test
    fun `a workspace with no files lists as empty, not as unreported`() = runBlocking<Unit> {
        val root = temporary.newFolder("empty-workspace").toPath()
        val source = WorkspacePreviewSource(root)
        assertEquals(emptyList<Any>(), source.files())
    }

    @Test
    fun `a missing workspace reports nothing`() = runBlocking<Unit> {
        val absent = temporary.root.toPath().resolve("never-created")
        assertNull(WorkspacePreviewSource(absent).files())
        assertNull(WorkspacePreviewSource(null).files())
    }

    @Test
    fun `a listing walks the tree, sorts it, and measures each file`() = runBlocking<Unit> {
        val root = temporary.newFolder("tree").toPath()
        write(root, "z.txt", "zzz")
        write(root, "a.txt", "a")
        write(root, "src/Main.kt", "fun main() {}")
        val listing = WorkspacePreviewSource(root).files()
        assertEquals(
            listOf("a.txt", "src/Main.kt", "z.txt"),
            listing?.map { it.relativePath },
        )
        assertEquals(3L, listing?.first { it.relativePath == "z.txt" }?.size)
        assertEquals(
            "a nested path keeps its slash",
            "src/Main.kt",
            listing?.first { it.relativePath.endsWith("Main.kt") }?.relativePath,
        )
        listing?.forEach { assertEquals(it.relativePath, it.id) }
    }

    @Test
    fun `a symlink is not listed`() = runBlocking<Unit> {
        val root = temporary.newFolder("links").toPath()
        write(root, "real.txt", "real")
        Files.createSymbolicLink(root.resolve("alias.txt"), root.resolve("real.txt"))
        val listing = WorkspacePreviewSource(root).files()
        assertEquals(listOf("real.txt"), listing?.map { it.relativePath })
    }

    @Test
    fun `resolution goes through the resolver, not around it`() = runBlocking<Unit> {
        val root = temporary.newFolder("resolve").toPath()
        write(root, "notes.txt", "hello")
        val source = WorkspacePreviewSource(root)
        val resolved = source.resolve("./notes.txt")
        assertTrue(resolved is PreviewResolution.Resolved)
        assertTrue(source.resolve("../escape.txt") is PreviewResolution.Unresolved)
        assertTrue(source.readPage((resolved as PreviewResolution.Resolved).file, 0).text == "hello")
        assertTrue(source.looksLikeText(resolved.file))
        assertTrue(!source.looksLikeText(resolved.file.resolveSibling("missing.txt")))
    }


    /** `Files.readString` is Java 11 and absent from the Android SDK stubs. */
    private fun readText(path: Path): String = String(Files.readAllBytes(path), Charsets.UTF_8)

    /** `Files.writeString` is Java 11 and absent from the Android SDK stubs. */
    private fun writeText(path: Path, content: String) {
        Files.write(path, content.toByteArray(Charsets.UTF_8))
    }

    private fun write(root: Path, relative: String, content: String) {
        val target = root.resolve(relative)
        Files.createDirectories(target.parent)
        writeText(target, content)
    }
}
