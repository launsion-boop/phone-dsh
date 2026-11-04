// 本 session 产物 over the real workspace: the source, the fact and the split.
// SPDX-License-Identifier: MIT
//
// The L81 lane's subject here is the seam, not the pixels:
//
//  * [WorkspaceSessionArtifactSource] lists the materialized workspace tree the
//    files page and the preview also read, and reads the first text page of one
//    file — so the artifacts page can show what a tool really wrote;
//  * [SessionArtifactsFacts] is the *attribution*: a path is 本 session only when
//    the host's turn measurement says so, and an unmeasured host claims nothing;
//  * the source never invents a file: a path outside the root is refused by the
//    same resolver the preview uses, and a root that is not there throws the
//    no-workspace read rather than answering "empty".
package com.phonedsh.ui.page

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.nio.file.Files
import java.nio.file.Path
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import kotlinx.coroutines.runBlocking

@RunWith(AndroidJUnit4::class)
class SessionArtifactsWorkspaceTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private fun workspace(): Path = temporary.newFolder("workspace").toPath()

    /** Writes one file under [root], creating the directories it names. */
    private fun write(root: Path, relativePath: String, text: String): Path {
        val file = root.resolve(relativePath)
        Files.createDirectories(file.parent)
        Files.write(file, text.toByteArray())
        return file
    }

    // ------------------------------------------------------------- the source

    @Test
    fun `the workspace source lists the tree with the path as its id`() = runBlocking {
        val root = workspace()
        write(root, "orders-summary.md", "# summary\namount total: 325.21\n")
        write(root, "sub/notes.txt", "hello\n")

        val source = WorkspaceSessionArtifactSource(root)
        val page = source.list(cursor = 0, limit = 50)

        assertEquals(listOf("orders-summary.md", "sub/notes.txt"), page.items.map { it.artifactId })
        assertEquals(listOf("orders-summary.md", "notes.txt"), page.items.map { it.name })
        assertEquals(0L, page.items.first().byteCount - Files.size(root.resolve("orders-summary.md")))
        assertNull("one page holds the whole small tree", page.nextCursor)
    }

    @Test
    fun `the workspace source pages with a cursor`() = runBlocking {
        val root = workspace()
        repeat(3) { index -> write(root, "f$index.txt", "x") }
        val source = WorkspaceSessionArtifactSource(root)

        val first = source.list(cursor = 0, limit = 2)
        assertEquals(2, first.items.size)
        assertEquals(2, first.nextCursor)
        val second = source.list(cursor = first.nextCursor!!, limit = 2)
        assertEquals(1, second.items.size)
        assertNull(second.nextCursor)
    }

    @Test
    fun `the workspace source reads the first text page and measures the window`() = runBlocking {
        val root = workspace()
        val text = "# orders\namount total: 325.21\n"
        write(root, "orders-summary.md", text)
        val source = WorkspaceSessionArtifactSource(root)

        val content = source.content("orders-summary.md")
        assertNotNull(content)
        assertTrue(content!!.text.contains("325.21"))
        assertEquals(text.toByteArray().size.toLong(), content.loadedBytes)
        assertEquals(text.toByteArray().size.toLong(), content.totalBytes)
        assertTrue("the file is still there", source.fileExists("orders-summary.md"))
    }

    @Test
    fun `a binary file has no text preview and the source says so`() = runBlocking {
        val root = workspace()
        Files.write(root.resolve("report.docx"), ByteArray(64) { it.toByte() })
        val source = WorkspaceSessionArtifactSource(root)

        assertNull(source.content("report.docx"))
        assertNotNull("the file is still addressable for sharing", source.fileFor("report.docx"))
    }

    @Test
    fun `a path that escapes the root is refused by the share and preview reads`() = runBlocking {
        val root = workspace()
        write(root, "inside.txt", "x")
        Files.write(temporary.root.toPath().resolve("outside.txt"), "secret".toByteArray())
        val source = WorkspaceSessionArtifactSource(root)

        assertNull(source.fileFor("../outside.txt"))
        assertNull(source.content("../outside.txt"))
        assertTrue(!source.fileExists("../outside.txt"))
    }

    @Test
    fun `a missing workspace is a read failure, never an empty listing`() = runBlocking {
        val source = WorkspaceSessionArtifactSource(temporary.root.toPath().resolve("absent"))
        val failure = runCatching { source.list(cursor = 0, limit = 50) }.exceptionOrNull()

        assertNotNull("no workspace is not an empty workspace", failure)
        assertTrue(failure is java.io.IOException)
        assertEquals(
            WorkspaceSessionArtifactSource.NO_WORKSPACE_REASON,
            (failure as java.io.IOException).message,
        )
    }

    // --------------------------------------------------------------- the split

    @Test
    fun `the fact attributes only the paths the host measured`() {
        val artifacts = listOf(
            SessionArtifactRef("orders-summary.md", "orders-summary.md", 78),
            SessionArtifactRef("orders.csv", "orders.csv", 120),
        )
        val state = SessionArtifactsScreenState.fromWorkspace(
            artifacts = artifacts,
            facts = SessionArtifactsFacts(writtenPaths = listOf("orders-summary.md")),
        )

        assertEquals(listOf("orders-summary.md"), state.assigned.map { it.artifactId })
        assertEquals(listOf("orders.csv"), state.unassigned.map { it.artifactId })
        assertTrue("the page still lists both", !state.sessionEmpty)
    }

    @Test
    fun `an unmeasured host claims nothing instead of guessing`() {
        val state = SessionArtifactsScreenState.fromWorkspace(
            artifacts = listOf(SessionArtifactRef("orders-summary.md", "orders-summary.md", 78)),
            facts = SessionArtifactsFacts(writtenPaths = null),
        )

        assertTrue("no measurement = no 本 session rows", state.assigned.isEmpty())
        assertEquals(1, state.unassigned.size)
        assertTrue(state.sessionEmpty)
    }

    @Test
    fun `a measured empty turn lists everything as 未归属`() {
        val state = SessionArtifactsScreenState.fromWorkspace(
            artifacts = listOf(SessionArtifactRef("old.md", "old.md", 1)),
            facts = SessionArtifactsFacts(writtenPaths = emptyList()),
        )

        assertTrue(state.assigned.isEmpty())
        assertEquals(listOf("old.md"), state.unassigned.map { it.artifactId })
    }

    // -------------------------------------------------------------- the preview

    @Test
    fun `a preview with text is a window on the file, not the whole of it`() {
        val artifact = SessionArtifactRef("orders-summary.md", "orders-summary.md", 78)
        val whole = SessionArtifactPreview(
            artifact = artifact,
            text = "x".repeat(78),
            loadedBytes = 78,
            totalBytes = 78,
        )
        val partial = whole.copy(loadedBytes = 10)

        assertTrue(whole.hasText)
        assertTrue(!whole.textTruncated)
        assertTrue(partial.textTruncated)
        assertTrue(!SessionArtifactPreview(artifact).hasText)
    }
}
